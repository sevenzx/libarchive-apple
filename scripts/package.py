#!/usr/bin/env python3
"""Package a verified XCFramework and record the exact producer/source/toolchain."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile
from source_lock import load

def sha256(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", default="sources.lock.json")
    parser.add_argument("--output", default="dist")
    parser.add_argument("--revision", default="1")
    args = parser.parse_args()
    if not re.fullmatch(r"[1-9][0-9]{0,5}", args.revision):
        raise SystemExit("Revision must be a positive integer of up to six digits")
    root = Path(__file__).resolve().parents[1]
    lock = load(args.lock)
    output = Path(args.output)
    framework = output / "LibraArchive.xcframework"
    if load(framework / "sources.lock.json") != lock:
        raise SystemExit("Selected source lock does not match the built XCFramework")
    stamp = dict(line.split("=", 1) for line in
                 (framework / ".libarchive-apple-source-lock").read_text().splitlines() if "=" in line)
    native_files = {
        "recipe": root / "scripts/build.sh",
        "modulemap": root / "scripts/libarchive.modulemap",
        "shim": root / "src/archive_apple.c",
        "header": root / "include/archive_apple.h",
        "assembler": root / "scripts/assemble.py",
        "notices": root / "scripts/source_notices.py",
        "source-lock": framework / "sources.lock.json",
    }
    if any(stamp.get(key) != sha256(path) for key, path in native_files.items()):
        raise SystemExit("Compiled recipe changed; rebuild before packaging")
    with (framework / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {"ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"}
    if {item["LibraryIdentifier"] for item in info["AvailableLibraries"]} != expected:
        raise SystemExit("XCFramework does not contain the required slices")
    archive = output / "LibraArchive.xcframework.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(framework.rglob("*")):
            if path.is_symlink():
                raise SystemExit("Unexpected symlink inside static XCFramework")
            if not path.is_file():
                continue
            item = zipfile.ZipInfo(str(path.relative_to(output)), date_time=(2000, 1, 1, 0, 0, 0))
            item.external_attr = 0o100644 << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(item, path.read_bytes(), compresslevel=9)
    source_lock_path = output / "sources.lock.json"
    source_lock_path.write_bytes((framework / "sources.lock.json").read_bytes())
    try:
        commit = command("git", "-C", str(root), "rev-parse", "HEAD")
        dirty = bool(command("git", "-C", str(root), "status", "--porcelain"))
    except subprocess.CalledProcessError:
        commit, dirty = "uncommitted", True
    tag = f"libarchive-{lock['libarchive']['version']}-xz-{lock['xz']['version']}-r{args.revision}"
    metadata = {
        "schemaVersion": 1, "releaseTag": tag, "shimABI": 1,
        "sources": lock, "sourceLockSHA256": sha256(source_lock_path),
        "artifact": {"name": archive.name, "sha256": sha256(archive)},
        "recipe": {
            "commit": commit, "dirty": dirty,
            "files": {str(path.relative_to(root)): sha256(path) for path in [
                root / "scripts/build.sh", root / "src/archive_apple.c",
                root / "include/archive_apple.h", root / "scripts/libarchive.modulemap",
                root / "scripts/assemble.py", root / "scripts/source_notices.py",
                root / "scripts/source_lock.py", root / "scripts/verify.sh",
                root / "scripts/package.py"
            ]},
        },
        "toolchain": {
            "xcode": command("xcodebuild", "-version"),
            "sdks": {sdk: command("xcrun", "--sdk", sdk, "--show-sdk-version")
                     for sdk in ["iphoneos", "iphonesimulator", "macosx"]},
        },
        "slices": info["AvailableLibraries"],
    }
    metadata_path = output / "artifact.json"
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    names = [archive.name, metadata_path.name, source_lock_path.name]
    (output / "SHA256SUMS").write_text("".join(f"{sha256(output / name)}  {name}\n" for name in names))
    print(tag)

if __name__ == "__main__":
    main()
