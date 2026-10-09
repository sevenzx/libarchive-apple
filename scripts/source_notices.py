#!/usr/bin/env python3
"""Preserve upstream leading notices for all libarchive implementation files."""
from pathlib import Path
import re
import sys

source, destination = map(Path, sys.argv[1:])
parts = []
for path in sorted(source.rglob("*")):
    if path.suffix not in {".c", ".h"}:
        continue
    content = path.read_text(errors="strict")
    match = re.match(r"\s*(?:(?:/\*.*?\*/)\s*)+", content, flags=re.S)
    if match:
        parts.append(str(path.relative_to(source.parent)) + "\n" + match.group().strip())
destination.write_text("\n\n".join(parts) + "\n")

