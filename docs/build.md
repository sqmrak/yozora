# build

## host

```bash
meow test
meow build yozora-fat yozora-store-fat
```

[meow](https://github.com/sqmrak/meow), a c99 compiler, python 3.12 and sqlite headers. `meow test` builds every c test in `tests/` with `-Wall -Wextra -Werror -pedantic` under asan and ubsan and runs them with the python tests for sources, patches and scripts. everything is in `meow.toml`: `meow list` shows it, `meow plan NAME` prints the commands and what is stale, `meow why NAME` says what made a step stale.

## webkit on the host

```bash
meow build core-fetch
meow build core-host
meow build core-web-host
build/core/host/bin/yozora-js tests/js/features.js
```

cmake 3.20, ninja, c++23, icu 70.1 or newer, ruby, perl. the host build is the one that runs `yozora-render`, the headless page runner behind most of the core tests. a full webcore build takes about 25 minutes with `-j 4` and needs about 8 GB of ram.

a build tree keeps the absolute path it was configured in. after the source tree moves, configure a new tree, an old one cannot compile.

## ios

```bash
meow build            # core-fetch, core-tools, core-deps, text-deps, web-deps, WebKit, the app, both ipas
meow build ipa        # one ipa with both slices
meow build app --slice arm64
```

- meow orders the dependency steps and skips what is built: `core-deps`, `text-deps` and `web-deps` run only while their outputs are missing, `meow clean NAME` then `meow build NAME` forces one. the older probes keep their names: `core-fat`, `webcore-fat` (the cmake build of the whole port, the Yozora executable included), `runtime-fat`, `graphics-fat`, `memory-fat`
- WebKit builds through cmake and ninja in the steps `webcore-armv7` and `webcore-arm64` (`scripts/build_webcore_ios.sh` with `YOZORA_BUILD_APP=0`). cmake owns the library graph; `scripts/export_link_line.py` writes the link line it computed for the Yozora target to `build/<slice>/link.rsp`, and meow compiles the objective-c sources, links with that file, strips and signs. a change to one `app/*.m` rebuilds one object and the link
- armv7 links against a legacy sdk, arm64 against a patched sdk that has the private symbols, each slice has its own staging directory and objects are never shared between slices
- the arm64 binary carries the sdk version `YOZORA_SDK_V64_VERSION` (16.5, the headers the patched sdk was made from) through `-Wl,-sdk_version`: ld 253 reads the version from the digits of the sdk directory name, and `iPhoneOS-arm64.sdk` gave 64.0
- meow signs each slice and the joined file with `ldid` and the entitlements of `tools/yozora-jit.entitlements`, reading the signature back
- the release checks (`release-armv7`, `release-arm64`, `release-universal`) run before packaging: the slices, the deployment target, a signature, only system dylibs. the ipa is read back after it is written
- `meow build ipa-armv7` and `meow build ipa-arm64` write one slice each
- the icons, interface glyphs and launch images sit flat in the bundle and are listed one by one in the ipa tables, because meow places a tree under a name and not at the root; `tests/test_bundle_inputs.py` fails when a file is added to those folders and not listed

outputs `build/ios/libyozora.a`, `build/ios/yozora-store`, `build/ipa/Yozora-armv7.ipa`, `build/ipa/Yozora-arm64.ipa` and `build/ipa/Yozora.ipa`.

```bash
meow build deb        # build/ipa/Yozora-v2.0.0-stable.deb
```

the deb is cut from the checked universal ipa by `scripts/build_deb.sh` (`YOZORA_DEB_IPA`, `YOZORA_DEB_OUT` and `YOZORA_DEB_STAGE` move its paths). the package is served from github, which refuses a file over 100 MiB, and 1.4.0 was 570 KB over. two steps bring it under: the pictures of the bundle are recoded with `oxipng` (`-o6 --zopfli --strip safe`, no pixel changes, about 340 KB after gzip) and the executable loses its symbol table (`strip`, then `ldid -S` with `tools/yozora-jit.entitlements`, 667 KB after gzip; the map under the uuid of the binary is what a crash report is read with, so the report still resolves). the executable of the deb is thereby not the one of the ipa byte for byte, only its symbols and signature differ. `Architecture: all`, gzip members, the bundle in `/var/jb/Applications/Yozora.app` with root ownership, files 644 and the binary 755. a rootless jailbreak registers that path with its uicache, on a rootful one `postinst` moves the bundle to `/Applications` (a copy would keep two bundles of 100 MB) and marks it with `.yozora-rootful-move`, `postrm` removes only a bundle that carries the mark. the script stops when the version of `packaging/DEBIAN/control` is not the one in the plist of the ipa.

## variables

nothing is read from a fixed path, every root can be set:

- toolchain: meow finds it (`meow doctor` lists what it found; `MEOW_TC` and `MEOW_SDK_*` set it by hand) and hands it to the scripts as `YOZORA_TC`. `YOZORA_TC` set in the environment wins, `YOZORA_CRT_V7`
- sdks: `YOZORA_SDK_V7`, `YOZORA_SDK_V64`
- compilers: `YOZORA_CORE_CC`, `YOZORA_CORE_CXX`, `YOZORA_CORE_AR`, `YOZORA_CORE_RANLIB`, flags in `YOZORA_CORE_CFLAGS_RELEASE`, `YOZORA_CORE_CXXFLAGS_RELEASE`, `YOZORA_CORE_LINK_FLAGS`
- trees: `YOZORA_CORE_BUILD`, `YOZORA_CORE_IOS_BUILD`, `YOZORA_WEBCORE_BUILD`, `YOZORA_WEBCORE_IOS_BUILD`, `YOZORA_TEXT_BUILD`, `YOZORA_WEB_DEPS_BUILD`, `YOZORA_TOOLS_BUILD`
- sources and caches: `YOZORA_WEBKIT_SRC`, `YOZORA_CORE_SOURCES`, `YOZORA_CORE_CACHE`, `YOZORA_WEB_CACHE`, `YOZORA_ICU_SRC`, `YOZORA_LLVM_SRC`, `YOZORA_FREETYPE_SRC`, `YOZORA_HARFBUZZ_SRC`, `YOZORA_SQLITE_SRC`
- jobs: `YOZORA_CORE_JOBS` (1 to 8, the compile jobs of ninja; a heavy bundle of webcore or javascriptcore peaks near 1.5 GB, so 8 jobs want about 8 GB free), `YOZORA_FETCH_JOBS`
- the webcore tree meow links the app against: `YOZORA_WEBCORE_IOS_BUILD` (`build/core/webcore-ios-jit-fresh` by default, the one configured under this path; a tree configured under another path is refused with a message, since cmake trees cannot move. a change in the sources of the engine rebuilds what ninja finds changed in that tree and nothing else (an armv7 relink after a few changed files took 12 seconds); unified builds compile up to 8 sources together, so one edited webkit file recompiles its bundle)
- features: `YOZORA_WASM` (keeps the webassembly of javascriptcore on arm64), `YOZORA_ARMV7_JIT=0` (builds the c loop instead of the jit)

a script that needs one of them and does not find it stops with the name.

## other targets

steps, run by name with `meow build NAME`: `runtime-host`, `text-host`, `web-deps-host`, `graphics-host`, `raster-host`, `fonts-host`, `memory-host`, `platform-host`, `page-host`, `webcore-host`, `page-adapter-sanitize`, `webcore-patches-test`, `jit-probe`. the proxy and the wasm tests are host tests: `meow test proxy`, `meow test wasm`.

## inputs

every archive is fetched once and checked by sha-256 against `core/*.json` before it is unpacked, a patch is applied only when the file has the hash recorded before it. see [webkit](webkit.md).

## emoji font

`app/fonts/AppleColorEmoji.ttf` is generated, not committed (see `app/NOTICE-Emoji.txt`). `tools/make_emoji_font.py` writes it from an emoji pack and a data table, `tests/test_emoji_font.py` checks it. the ipa build requires it. both need fonttools and pillow.

## assets

- `tools/make_icons.py SOURCE.png OUTPUT_DIR`: app icons with rounded corners
- `tools/make_home_art.py`: the cut out sticker and the wordmark mask of the start page
- `tools/make_launch_images.py`: launch images for every iphone and ipad screen and the `UILaunchImages` entries
- `tools/make_ui_icons.py`: interface glyph masks from `tools/material-symbols` and the marks of the search engines from `tools/logos`, needs `rsvg-convert` and pillow

## the webcore tree

cmake keeps the absolute path it was configured under, and the directory of the sources it was configured for. a tree cannot move, and a tree made for one WebKit directory cannot be pointed at another. `scripts/build_webcore_ios.sh` reads `CMAKE_CACHEFILE_DIR` and `CMAKE_HOME_DIRECTORY` of `<tree>/<slice>/CMakeCache.txt` before it calls cmake and stops with a message when either differs, so a wrong tree fails at once and is never rebuilt from nothing by accident.

- `meow.toml` names the tree in `WEB` (`build/core/webcore-ios-jit-fresh`, overridden by `YOZORA_WEBCORE_IOS_BUILD`) and the two webcore steps hand it to the script. `scripts/export_link_line.py` reads the same tree for the link line of the app
- inside a tree ninja decides what is stale, so a change in a webkit or `core/` source rebuilds the objects that depend on it and the archives. one armv7 relink after a few changed files took 12 seconds, `meow build ipa-armv7` end to end 25 seconds. unified builds compile up to 8 sources together (`WEBKIT_MAX_BUNDLE_SIZE=8`), so one edited webkit file recompiles its bundle
- the step runs when meow finds its inputs changed, which is cheap: it ends in "no work to do" when ninja has nothing to do
- a slice is made by naming it: `YOZORA_SLICES=armv7` or `arm64` (the script builds both when it is unset), each slice has its own subdirectory of the tree. a tree for the second slice is a full build

## updating webkit

a new version is a change of pins and of patches, then one of two ways to build it.

1. `core/source.json`: `version`, `archive`, `url`, `directory`, `size` and `sha256` of the tarball (webkitgtk.org publishes the sums beside the release, `webkitgtk-X.Y.Z.tar.xz.sums`) and `upstream_commit`, the commit the tag `webkitgtk-X.Y.Z` of the WebKit repository points at. `YozoraWebKitVersion` of `app/Info.plist` is the version the about screen shows: it has to be the same string, `tests/test_core_source.py` fails when it is not `scripts/fetch_core.py` refuses an archive whose size or hash differs
2. `core/darwin-sources.json` and `core/network-sources.json` list files that are not in the tarball and come from the WebKit repository at `upstream_commit`: path, size, sha-256. fetch every file at the new commit, compare, and write the new commit and any changed hashes. 2.54.1 to 2.54.3 changed none of the 90 files
3. the patches. `webkit-ios`, `webkit-yozora`, `webkit-yozora-ios`, `webkit-yozora-dns` and `webkit-yozora-gcm` are applied in that order to the new tree with `patch --fuzz=0`. a file that upstream changed under a hunk fails the dry run: rebase that hunk by hand on a copy of the pristine file, write the diff of the two files back into the patch and run the five groups again. `python3 scripts/record_patch_hashes.py TREE` applies the five groups in order to a pristine tree (the sources and the fetched files of step 2 in it) and rewrites `core/patches/sources.json` with the hash of every file before and after each group; a group that does not apply stops it with the output of patch and leaves `sources.json` alone. from 2.54.1 to 2.54.3 two files of `webkit-ios` and thirteen of `webkit-yozora` had to move their hashes, and the changes of the new version are in [webkit](webkit.md)
4. check it the way a clean machine does it: a new `YOZORA_CORE_SOURCES` directory, `scripts/fetch_core.py`, `scripts/fetch_darwin_sources.py`, `scripts/fetch_network_sources.py`, then `scripts/apply_core_patches.py DIR GROUP` for the five groups, which verifies every hash

building it:

- new directory, new tree: `meow build` makes a tree for `build/sources/webkitgtk-X.Y.Z` and builds all of webcore, the cost of a first build of that slice
- keeping the tree: `python3 scripts/sync_core_source.py OLD NEW --apply` copies into the old, already patched directory only the files whose content differs from the new patched one, adds the new ones and removes the ones that are gone; the rest keep their time stamps. then `YOZORA_WEBKIT_SRC=OLD meow build ipa-armv7` builds what ninja finds changed. without `--apply` the script only reports (2.54.1 to 2.54.3: 2750 files changed, about 430 of them in WebCore, JavaScriptCore and WTF, 45 added, 46 removed). the new tree is the verified one, and the old tree stays the one cmake was configured for

## the engine flags of a build

- `-O3`, `-mthumb` on armv7, `-std=c++23`, neon on (`__ARM_NEON`, the vectorizer uses `vld1` and `vadd` on armv7)
- bundles of directories pages seldom run are built with `-Os` (`yozora_size_optimize_cold_bundles` in `core/WebCoreIOSProbe.cmake`): in WebCore `Modules`, `inspector`, `accessibility`, `automation`, `plugins`, `history`, `bridge`, `crypto`, `contentextensions`, `fileapi`, `worklets`, `xml` and `mathml`, 141 bundles. WebCore is split into several cmake targets, the function walks all of them. the unified bundles are named after their directory (`UnifiedSource-inspector-3.cpp`), so a bundle is cold or hot as a whole. the flag comes after `-O3` on the command line and wins. clang refuses a precompiled header made at another optimization level (`OptimizationLevel differs in precompiled file`), so these bundles skip the prefix header (`SKIP_PRECOMPILE_HEADERS`)
- javascriptcore stays at `-O3`: its patched jit headers (`InlineCacheCompiler.h` names `CCallHelpers`) lean on the prefix header, which a bundle without it does not have
- no link time optimization. the libraries are compiled by the host clang (23), the app is linked by the old ld64 of the toolchain with `libLTO` 11, which cannot read the bitcode of clang 23 (`ignoring file ... unsupported file format`), and `ld64.lld` of this host has no `-arch armv7`

## the c files built into the app

some of the c code is used by the app only and is compiled with it (`meow.toml`, the lists of `app`, `app-armv7`, `app-arm64`) instead of into `libYozoraCore`, which needs a webkit build:

- `core/yozora_blur.c`: the lightness of the start page photo, see [core](core.md) and [ui](ui.md)
- `core/yozora_divdc3.c`: `___divdc3` of compiler-rt (division of complex doubles). libSystem exports it for armv7 only (`libSystem.B.tbd` lists it for `armv7-ios` and `armv7s-ios`), the toolchain has no libclang_rt for ios, and the web audio filters of WebCore (`Biquad`, `IIRFilter`) divide complex numbers, so an arm64 link failed with `Undefined symbols: ___divdc3`. it is also a source of the `yozora-page` probe in `core/WebCoreIOSProbe.cmake`. the file is empty on armv7. `tests/test_divdc3.c` (`meow test test-divdc3`) checks it against the compiler's division for finite values and against the answers of compiler-rt for nan, infinity and zero; the file gave the same bits as `compiler-rt/lib/builtins/divdc3.c` of llvm 23.1.1 on 528561 inputs, all combinations of nan, infinity and zero among them
