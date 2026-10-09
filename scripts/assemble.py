#!/usr/bin/env python3
"""Assemble Apple static archives from compiled libarchive objects, not nested archives."""
import argparse
from pathlib import Path
import re
import subprocess

def object_paths(build_root):
    build_root = Path(build_root).resolve()
    objects = []
    for metadata in sorted((build_root / "libarchive").glob("*.lo")):
        content = metadata.read_text()
        choices = []
        for kind in ("non_pic_object", "pic_object"):
            match = re.search(rf"^{kind}='([^']+)'$", content, re.M)
            if match and match[1] != "none":
                choices.append((metadata.parent / match[1]).resolve())
        path = next((candidate for candidate in choices if candidate.is_file()), None)
        if path is None or not path.is_relative_to(build_root):
            raise ValueError(f"Invalid compiled object metadata: {metadata.name}")
        objects.append(path)
    if not objects:
        raise ValueError("No compiled libarchive objects")
    return objects

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root")
    parser.add_argument("lzma_archive")
    parser.add_argument("shim_object")
    parser.add_argument("output")
    args = parser.parse_args()
    objects = object_paths(args.build_root)
    subprocess.run([
        "xcrun", "libtool", "-static", "-o", args.output,
        *map(str, objects), args.lzma_archive, args.shim_object,
    ], check=True)
    symbols = subprocess.check_output(["xcrun", "nm", "-gU", args.output], text=True)
    for name in ("archive_read_new", "archive_write_new", "archive_version_number",
                 "archive_apple_read_new_utf8", "archive_apple_write_new_utf8", "lzma_code"):
        if not re.search(rf"\bT _{name}$", symbols, re.M):
            raise SystemExit(f"Required static archive symbol missing: {name}")
    print(f"Assembled {len(objects)} libarchive objects with liblzma and UTF-8 shim.")

if __name__ == "__main__":
    main()

