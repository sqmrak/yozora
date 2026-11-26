#!/usr/bin/env bash
set -euo pipefail

yozora_root="$(cd "$(dirname "$0")/.." && pwd)"
yozora_mode="${1:-webcore}"
[[ "${yozora_mode}" == graphics || "${yozora_mode}" == webcore ]] || { echo 'yozora: expected graphics or webcore' >&2; exit 1; }
yozora_deps="${YOZORA_CORE_DEPS:-${yozora_root}/build/core/deps}"
yozora_web="${YOZORA_WEB_DEPS:-${yozora_deps}}"
yozora_text="${YOZORA_TEXT_DEPS:-${yozora_deps}}"
# cloop is the verified interpreter. llint runs the assembler interpreter from the binary on both slices and
# needs no executable memory, but nothing of it has run on a device yet
yozora_interpreter="${YOZORA_INTERPRETER:-cloop}"
case "${yozora_interpreter}" in
    cloop) yozora_cloop=ON; yozora_default_build="${yozora_root}/build/core/webcore-ios" ;;
    llint) yozora_cloop=OFF; yozora_default_build="${yozora_root}/build/core/webcore-ios-llint" ;;
    *) echo 'yozora: YOZORA_INTERPRETER must be cloop or llint' >&2; exit 1 ;;
esac
# the armv7 baseline and regexp jit run pages on a real phone (tests/jit_device.sh for the script tests), ios
# 5 is not run. a phone that refuses the executable mapping runs the assembler interpreter of the same binary.
# YOZORA_ARMV7_JIT=0 builds the c-loop
yozora_armv7_jit="${YOZORA_ARMV7_JIT:-1}"
case "${yozora_armv7_jit}" in
    0) ;;
    1) yozora_default_build="${yozora_root}/build/core/webcore-ios-jit" ;;
    *) echo 'yozora: YOZORA_ARMV7_JIT must be 0 or 1' >&2; exit 1 ;;
esac
# webgl runs over the system OpenGL ES (core/webgl), webassembly is the JSC interpreter and jit tiers. a tree
# keeps the value it was configured with, so a switch needs its own YOZORA_WEBCORE_IOS_BUILD (the webgl trees
# are build/core/webcore-ios-jit-gl)
yozora_webgl="${YOZORA_WEBGL:-ON}"
# empty: the slice decides (arm64 uses the webassembly of javascriptcore, which the optimizing compiler needs, armv7 has an engine of its own)
yozora_wasm_choice="${YOZORA_WASM:-}"
[[ "${yozora_webgl}" == ON || "${yozora_webgl}" == OFF ]] || { echo 'yozora: YOZORA_WEBGL must be ON or OFF' >&2; exit 1; }
[[ -z "${yozora_wasm_choice}" || "${yozora_wasm_choice}" == ON || "${yozora_wasm_choice}" == OFF ]] || { echo 'yozora: YOZORA_WASM must be ON or OFF' >&2; exit 1; }
yozora_build="${YOZORA_WEBCORE_IOS_BUILD:-${yozora_default_build}}"
yozora_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["directory"])' "${yozora_root}/core/source.json")"
yozora_source="${YOZORA_WEBKIT_SRC:-${YOZORA_CORE_SOURCES:-${yozora_root}/build/sources}/${yozora_version}}"
yozora_llvm="${YOZORA_LLVM_SRC:-${YOZORA_CORE_SOURCES:-${yozora_root}/build/sources}/llvm-project-23.1.1}"
yozora_jobs="${YOZORA_CORE_JOBS:-2}"
[[ "${yozora_jobs}" =~ ^[1-8]$ ]] || { echo 'yozora: YOZORA_CORE_JOBS must be between 1 and 8' >&2; exit 1; }
export YOZORA_TC="${YOZORA_TC:?run through meow, which sets YOZORA_TC}"
export YOZORA_CORE_CC="$(command -v "${YOZORA_CORE_CC:-clang}")"
export YOZORA_CORE_CXX="$(command -v "${YOZORA_CORE_CXX:-clang++}")"
export YOZORA_CORE_AR="$(command -v "${YOZORA_CORE_AR:-llvm-ar}")"
export YOZORA_CORE_RANLIB="$(command -v "${YOZORA_CORE_RANLIB:-llvm-ranlib}")"
yozora_gems="${YOZORA_CORE_GEMS:-${yozora_root}/build/deps/ruby}"
if [[ -d "${yozora_gems}" ]]; then
    export GEM_PATH="${yozora_gems}${GEM_PATH:+:${GEM_PATH}}"
fi
yozora_ruby="$(command -v "${YOZORA_CORE_RUBY:-ruby}")"
"${yozora_ruby}" -rerb -ryaml -rjson -e ''
yozora_gperf="${YOZORA_GPERF:-${YOZORA_CORE_TOOLS:-${yozora_deps}/host/tools}/bin/gperf}"
[[ -x "${yozora_gperf}" ]] || { echo 'yozora: build host gperf with meow build core-tools' >&2; exit 1; }
python3 -B "${yozora_root}/scripts/fetch_darwin_sources.py"
python3 -B "${yozora_root}/scripts/fetch_network_sources.py"
for yozora_patch in webkit-ios webkit-yozora webkit-yozora-ios webkit-yozora-dns webkit-yozora-gcm webkit-yozora-jit webkit-yozora-metal; do
    python3 -B "${yozora_root}/scripts/apply_core_patches.py" "${yozora_source}" "${yozora_patch}"
done
# YOZORA_SLICES limits the build to one slice, the universal archives need both
yozora_slices="${YOZORA_SLICES:-armv7 arm64}"
[[ "${yozora_slices}" == "armv7 arm64" || "${yozora_slices}" == armv7 || "${yozora_slices}" == arm64 ]] || { echo 'yozora: YOZORA_SLICES must be armv7, arm64 or "armv7 arm64"' >&2; exit 1; }
for YOZORA_SLICE in ${yozora_slices}; do
    export YOZORA_SLICE
    export YOZORA_SLICE_MIN=7.0
    [[ "${YOZORA_SLICE}" != armv7 ]] || export YOZORA_SLICE_MIN=5.0
    if [[ "${YOZORA_SLICE}" == armv7 ]]; then
        export YOZORA_SLICE_SDK="${YOZORA_SDK_V7:-${yozora_deps}/sdk/iPhoneOS-armv7.sdk}"
    else
        export YOZORA_SLICE_SDK="${YOZORA_SDK_V64:-${yozora_deps}/sdk/iPhoneOS-arm64.sdk}"
    fi
    export YOZORA_SLICE_DEPS="${yozora_deps}/${YOZORA_SLICE}"
    yozora_runtime="${YOZORA_SLICE_DEPS}/runtime"
    yozora_icu="${YOZORA_SLICE_DEPS}/icu"
    yozora_prefix="${yozora_web}/${YOZORA_SLICE}/web"
    for yozora_input in "${yozora_runtime}/lib/libc++.a" "${yozora_icu}/lib/libicuuc.a" \
        "${yozora_text}/${YOZORA_SLICE}/text/lib/libharfbuzz.a" "${yozora_prefix}/yozora-inputs.json"; do
        [[ -f "${yozora_input}" ]] || { echo "yozora: missing ${yozora_input}, build core, text and web dependencies first" >&2; exit 1; }
    done
    bash "${yozora_root}/scripts/check_text_woff2.sh" "${yozora_text}/${YOZORA_SLICE}/text"
    export PKG_CONFIG_PATH=""
    export PKG_CONFIG_LIBDIR="${yozora_prefix}/lib/pkgconfig:${yozora_icu}/lib/pkgconfig:${yozora_text}/${YOZORA_SLICE}/text/lib/pkgconfig"
    yozora_flags="-B \"${YOZORA_TC}\" -mlinker-version=253 -nostdinc++ -isystem \"${yozora_runtime}/include/c++/v1\" -nostdlib++ -faligned-allocation -DYOZORA_DARWIN=1 -I\"${yozora_root}/core/darwin\""
    # both slices compile baseline and DFG, YOZORA_ARMV7_JIT=0 keeps the armv7 c-loop. FTL is built for arm64 only (it does not exist on
    # 32 bit) and the core allows it at run time on phones with 1.7 GB of memory or more, see yozora_memory_limits_for
    yozora_js_options="-DENABLE_C_LOOP=${yozora_cloop} -DENABLE_JIT=OFF"
    if [[ "${YOZORA_SLICE}" == armv7 && "${yozora_armv7_jit}" == 1 ]]; then
        yozora_js_options="-DENABLE_C_LOOP=OFF -DENABLE_JIT=ON -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF"
    fi
    if [[ -n "${yozora_wasm_choice}" ]]; then
        yozora_wasm="${yozora_wasm_choice}"
    elif [[ "${YOZORA_SLICE}" == arm64 ]]; then
        yozora_wasm=ON
    else
        yozora_wasm=OFF
    fi
    if [[ "${YOZORA_SLICE}" == arm64 ]]; then
        yozora_js_options="-DENABLE_C_LOOP=OFF -DENABLE_JIT=ON -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=ON"
        # the optimizing compiler (B3) is written together with the webassembly jits and does not build without them, and they are on with it
        if [[ "${yozora_wasm}" == ON ]]; then
            yozora_js_options="${yozora_js_options} -DENABLE_WEBASSEMBLY_BBQJIT=ON -DENABLE_WEBASSEMBLY_OMGJIT=ON"
        fi
        yozora_flags="${yozora_flags} -mcpu=apple-a7"
    fi
    # a cmake tree keeps the absolute path it was configured under and cannot be moved: after the project moved, cmake fails or a new tree
    # is built from nothing, so say it here
    yozora_cache="${yozora_build}/${YOZORA_SLICE}/CMakeCache.txt"
    if [[ -f "${yozora_cache}" ]]; then
        yozora_recorded="$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "${yozora_cache}")"
        [[ "${yozora_recorded}" == "${yozora_build}/${YOZORA_SLICE}" ]] || {
            echo "yozora: ${yozora_cache} was configured for ${yozora_recorded}, a cmake tree cannot be moved" >&2
            echo "yozora: point YOZORA_WEBCORE_IOS_BUILD at a tree made under this path, or at a new directory (a full build)" >&2
            exit 1
        }
        # the same goes for the sources: a tree made for another WebKit version or source directory is not reused
        yozora_home="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "${yozora_cache}")"
        [[ "${yozora_home}" == "${yozora_source}" ]] || {
            echo "yozora: ${yozora_cache} was configured for the sources in ${yozora_home}, not ${yozora_source}" >&2
            echo "yozora: point YOZORA_WEBCORE_IOS_BUILD at a new directory (a full build) when the WebKit version changes" >&2
            exit 1
        }
    fi
    cmake -S "${yozora_source}" -B "${yozora_build}/${YOZORA_SLICE}" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${yozora_root}/core/IOSToolchain.cmake" -DPORT=Yozora -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="${yozora_flags}" \
        -DCMAKE_CXX_STANDARD_LIBRARIES="\"${yozora_runtime}/lib/libc++.a\" \"${yozora_runtime}/lib/libc++abi.a\"" \
        -DCMAKE_PROJECT_INCLUDE="${yozora_root}/core/WebCoreIOSProbe.cmake" \
        -DYOZORA_LLVM_SRC="${yozora_llvm}" -DYOZORA_DARWIN_ROOT="${yozora_root}/core/darwin" -DYOZORA_WEBCORE_ROOT="${yozora_root}/core/webcore" \
        -DYOZORA_ICU_ROOT="${yozora_icu}" -DRuby_EXECUTABLE="${yozora_ruby}" -DGPERF_EXECUTABLE="${yozora_gperf}" \
        -DCMAKE_PREFIX_PATH="${yozora_prefix};${yozora_text}/${YOZORA_SLICE}/text;${yozora_icu}" \
        -DOPENSSL_USE_STATIC_LIBS=ON -DOPENSSL_ROOT_DIR="${yozora_prefix}" \
        -DZLIB_LIBRARY_RELEASE="${yozora_prefix}/lib/libz.a" -DZLIB_LIBRARY="${yozora_prefix}/lib/libz.a" -DZLIB_INCLUDE_DIR="${yozora_prefix}/include" \
        -DLIBXML2_LIBRARY="${yozora_prefix}/lib/libxml2.a" -DLIBXML2_INCLUDE_DIR="${yozora_prefix}/include/libxml2" \
        -DSQLite3_LIBRARY="${yozora_prefix}/lib/libsqlite3.a" -DSQLite3_INCLUDE_DIR="${yozora_prefix}/include" \
        ${yozora_js_options} -DENABLE_VIDEO=ON -DENABLE_MEDIA_SOURCE=ON -DENABLE_OFFSCREEN_CANVAS=ON -DENABLE_WEBGL=${yozora_webgl} -DUSE_JPEGXL=ON -DENABLE_WEBASSEMBLY=${yozora_wasm} -DENABLE_SAMPLING_PROFILER=OFF \
        -DUSE_SYSTEM_MALLOC=ON -DUSE_HEADER_MAPS=OFF -DUSE_THIN_ARCHIVES=OFF \
        -DENABLE_UNIFIED_BUILDS=ON -DWEBKIT_MAX_BUNDLE_SIZE=8
    cmake --build "${yozora_build}/${YOZORA_SLICE}" --target yozora-skia --parallel "${yozora_jobs}"
    if [[ "${yozora_mode}" == webcore ]]; then
        # meow compiles and links the app itself (YOZORA_BUILD_APP=0): cmake builds only the libraries the app links,
        # and scripts/export_link_line.py then writes the link line cmake computed for the Yozora target
        if [[ "${YOZORA_BUILD_APP:-1}" == 0 ]]; then
            cmake --build "${yozora_build}/${YOZORA_SLICE}" --target yozora-page yozora-js YozoraCore WebCore JavaScriptCore WTF bmalloc PAL Skia --parallel "${yozora_jobs}"
        else
            cmake --build "${yozora_build}/${YOZORA_SLICE}" --target yozora-page yozora-js Yozora --parallel "${yozora_jobs}"
        fi
    fi
done
[[ "${yozora_slices}" == "armv7 arm64" ]] || exit 0
mkdir -p "${yozora_build}/universal"
yozora_libraries=(Skia)
yozora_probes=(yozora-skia)
if [[ "${yozora_mode}" == webcore ]]; then
    yozora_libraries+=(WebCore JavaScriptCore WTF bmalloc)
    yozora_probes+=(yozora-page yozora-js)
fi
for yozora_library in "${yozora_libraries[@]}"; do
    yozora_output="${yozora_build}/universal/lib${yozora_library}.a"
    "${YOZORA_LIPO:-${YOZORA_TC}/lipo}" -create "${yozora_build}/armv7/lib/lib${yozora_library}.a" \
        "${yozora_build}/arm64/lib/lib${yozora_library}.a" -output "${yozora_output}"
    "${YOZORA_LIPO:-${YOZORA_TC}/lipo}" "${yozora_output}" -verify_arch armv7 arm64
    "${YOZORA_LIPO:-${YOZORA_TC}/lipo}" -info "${yozora_output}"
    chmod 644 "${yozora_output}"
done
for yozora_probe in "${yozora_probes[@]}"; do
    "${YOZORA_LIPO:-${YOZORA_TC}/lipo}" -create "${yozora_build}/armv7/bin/${yozora_probe}" \
        "${yozora_build}/arm64/bin/${yozora_probe}" -output "${yozora_build}/${yozora_probe}"
    "${YOZORA_LIPO:-${YOZORA_TC}/lipo}" "${yozora_build}/${yozora_probe}" -verify_arch armv7 arm64
    python3 -B "${yozora_root}/scripts/verify_core_ios.py" "${YOZORA_OTOOL:-${YOZORA_TC}/otool}" \
        "${yozora_build}/${yozora_probe}" "${YOZORA_NM:-${YOZORA_TC}/nm}"
done
