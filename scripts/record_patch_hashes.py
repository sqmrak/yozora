"""applies the webkit patch groups in order to a pristine tree and records the hash of every file before and after each group

usage: record_patch_hashes.py SOURCE [GROUP ...]
SOURCE is a freshly unpacked tree with the files of core/darwin-sources.json and core/network-sources.json fetched into it. the groups default to
webkit-ios, webkit-yozora, webkit-yozora-ios, webkit-yozora-dns and webkit-yozora-gcm, the order the build applies them in. a group whose dry run
fails (upstream changed a file under a hunk) stops the run with the output of patch and leaves core/patches/sources.json as it was: rebase the
hunk, then start again from a new tree. after a good run `apply_core_patches.py` accepts the groups on a new tree, check that with a clean extraction
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
GROUPS = ["webkit-ios", "webkit-yozora", "webkit-yozora-ios", "webkit-yozora-dns", "webkit-yozora-gcm", "webkit-yozora-jit", "webkit-yozora-metal"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() or path.is_symlink() else None


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: record_patch_hashes.py SOURCE [GROUP ...]")
    tree = Path(sys.argv[1]).resolve()
    names = sys.argv[2:] or GROUPS
    metadata_path = ROOT / "core/patches/sources.json"
    groups = json.loads(metadata_path.read_text())
    for name in names:
        items = groups[name]
        patch = ROOT / "core/patches" / (name + ".patch")
        before = {item["path"]: digest(tree / item["path"]) for item in items}
        command = ["patch", "--batch", "--fuzz=0", "--no-backup-if-mismatch", "-p1", "-d", str(tree), "-i", str(patch)]
        dry = subprocess.run(command + ["--dry-run"], capture_output=True, text=True)
        if dry.returncode:
            sys.stderr.write(dry.stdout[-4000:] + dry.stderr[-1000:])
            raise SystemExit(f"yozora: group {name} does not apply, sources.json is unchanged")
        subprocess.run(command, check=True, capture_output=True)
        moved = []
        for item in items:
            now_before, now_after = before[item["path"]], digest(tree / item["path"])
            if now_before != item["before"] or now_after != item["after"]:
                moved.append(item["path"])
            item["before"], item["after"] = now_before, now_after
        print(f"{name}: applied, {len(items)} files, {len(moved)} hashes moved")
        for path in moved:
            print("   ", path)
    metadata_path.write_text(json.dumps(groups, indent=2) + "\n")


if __name__ == "__main__":
    main()
