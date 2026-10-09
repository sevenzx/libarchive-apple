#!/usr/bin/env python3
"""Resolve stable upstream releases into a validated, immutable source lock."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request

REPOSITORIES = {"libarchive": "libarchive/libarchive", "xz": "tukaani-project/xz"}
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")

def validate_version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError("Version must be an explicit stable major.minor.patch")
    if any(int(part) >= 1000 for part in value.split(".")):
        raise ValueError("Version components must be below 1000")
    return value

def validate(lock):
    if set(lock) != {"schemaVersion", "libarchive", "xz"} or lock["schemaVersion"] != 1:
        raise ValueError("Unsupported source lock schema")
    for name, repository in REPOSITORIES.items():
        source = lock[name]
        if set(source) != {"version", "url", "sha256"}:
            raise ValueError("Source needs version, official URL and SHA-256")
        version = validate_version(source["version"])
        expected = f"https://github.com/{repository}/releases/download/v{version}/{name}-{version}.tar.gz"
        if source["url"] != expected:
            raise ValueError(f"{name}: source must be the official tagged release archive")
        if not isinstance(source["sha256"], str) or not SHA256.fullmatch(source["sha256"]):
            raise ValueError(f"{name}: invalid source SHA-256")
    return lock

def load(path):
    return validate(json.loads(Path(path).read_text()))

def source_from_release(name, version, release):
    validate_version(version)
    if release.get("tag_name") != f"v{version}" or release.get("draft") or release.get("prerelease"):
        raise ValueError(f"{name}: expected the selected stable release")
    filename = f"{name}-{version}.tar.gz"
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == filename]
    if len(assets) != 1:
        raise ValueError(f"{name}: missing or ambiguous release archive")
    digest = assets[0].get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        raise ValueError(f"{name}: upstream asset has no SHA-256 digest; use a reviewed source lock")
    source = {"version": version, "url": assets[0]["browser_download_url"], "sha256": digest[7:]}
    candidate = {"schemaVersion": 1, name: source}
    # Validate this source using a valid placeholder for the other component.
    other = "xz" if name == "libarchive" else "libarchive"
    candidate[other] = {
        "version": "1.0.0",
        "url": f"https://github.com/{REPOSITORIES[other]}/releases/download/v1.0.0/{other}-1.0.0.tar.gz",
        "sha256": "0" * 64,
    }
    validate(candidate)
    return source

def resolve_source(name, version):
    validate_version(version)
    # gh uses the platform's trust/auth configuration. Keep urllib as a TLS-
    # verified fallback; never bypass certificate verification.
    endpoint = f"repos/{REPOSITORIES[name]}/releases/tags/v{version}"
    if shutil.which("gh"):
        for attempt in range(3):
            result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                return source_from_release(name, version, json.loads(result.stdout))
            if not any(marker in result.stderr for marker in ("EOF", "error connecting", "TLS handshake timeout")):
                break
            if attempt < 2:
                time.sleep(attempt + 1)
        raise ValueError(f"{name}: official release lookup failed: {result.stderr.strip()}")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "libarchive-apple"}
    token = os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"https://api.github.com/{endpoint}",
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    return source_from_release(name, version, release)

def write_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as temporary:
        temporary.write(json.dumps(validate(value), indent=2) + "\n")
        temporary_path = Path(temporary.name)
    temporary_path.replace(path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", default="sources.lock.json")
    parser.add_argument("--libarchive-version")
    parser.add_argument("--xz-version")
    parser.add_argument("--output")
    parser.add_argument("--field", choices=[
        f"{name}.{field}" for name in REPOSITORIES for field in ("version", "url", "sha256")
    ])
    args = parser.parse_args()
    lock = load(args.lock)
    if args.field:
        name, field = args.field.split(".")
        print(lock[name][field])
        return
    for name in REPOSITORIES:
        version = getattr(args, f"{name}_version")
        if version:
            lock[name] = resolve_source(name, version)
    if args.output:
        write_atomic(args.output, lock)
    else:
        print(json.dumps(validate(lock), indent=2))

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(f"Source lock failed: {error}")
