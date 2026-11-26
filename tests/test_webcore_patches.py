import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# the order the build applies them in: each group starts from the files the one before left
CHAIN = ("webkit-ios", "webkit-yozora", "webkit-yozora-ios", "webkit-yozora-dns", "webkit-yozora-gcm", "webkit-yozora-jit", "webkit-yozora-metal")


def main():
    pin = json.loads((ROOT / "core/source.json").read_text())
    archive = (Path(sys.argv[1]) if len(sys.argv) == 2 else
               Path(os.environ.get("YOZORA_CORE_CACHE", ROOT / "build/cache")) / pin["archive"])
    load_script("fetch_core").verify_archive(archive, pin)
    patches = load_script("apply_core_patches")
    metadata = json.loads((ROOT / "core/patches/sources.json").read_text())
    for name in CHAIN:
        assert name in metadata, name
    supplemental = {}
    for manifest in ("network-sources.json", "darwin-sources.json"):
        supplemental.update({item["path"]: item["sha256"] for item in json.loads((ROOT / "core" / manifest).read_text())["files"]})
    with tempfile.TemporaryDirectory(prefix="yozora-webcore-patches-") as directory:
        source = Path(directory)
        touched = set()
        missing = []
        with tarfile.open(archive) as upstream:
            for name in CHAIN:
                for item in metadata[name]:
                    path = source / item["path"]
                    if item["path"] in touched or item["before"] is None:
                        continue
                    path.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        member = upstream.getmember(pin["directory"] + "/" + item["path"])
                    except KeyError:
                        # the curl and darwin sources are not in the release archive, they come from the two
                        # manifests in core/. a copy of an earlier fetch stands in only while it is still the
                        # pinned file, a patched one is not
                        fetched = ROOT / "build/sources" / pin["directory"] / item["path"]
                        if item["path"] in supplemental and fetched.is_file() and patches.digest(fetched) == supplemental[item["path"]]:
                            path.write_bytes(fetched.read_bytes())
                        else:
                            missing.append(item["path"])
                        continue
                    assert member.isfile() and 0 < member.size <= 4 * 1024 * 1024, member
                    with upstream.extractfile(member) as stream:
                        path.write_bytes(stream.read(member.size))
                touched.update(item["path"] for item in metadata[name])
        if missing:
            # a pinned fetch reaches the network, so it is asked for and never done by accident
            if os.environ.get("YOZORA_PATCH_TEST_FETCH") != "1":
                print(f"WebCore patches: skipped, {len(missing)} supplemental sources are not here unpatched (YOZORA_PATCH_TEST_FETCH=1 fetches them), the full build checks the chain")
                return
            env = {**os.environ, "YOZORA_WEBKIT_SRC": str(source)}
            for script in ("fetch_network_sources.py", "fetch_darwin_sources.py"):
                subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / script)], check=True, env=env, stdout=subprocess.DEVNULL)
            assert all((source / path).is_file() for path in missing), missing
        for name in CHAIN:
            patches.apply(source, name)
            patches.apply(source, name)
    print(f"WebCore patches: {len(CHAIN)} groups applied in order and repeated on clean pinned sources")


if __name__ == "__main__":
    main()
