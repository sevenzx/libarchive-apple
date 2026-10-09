# libarchive-apple

Build official libarchive and liblzma into a source-locked static XCFramework
for iOS 17 device arm64, iOS 17 simulator arm64/x86_64 and macOS 14 arm64/x86_64
(package tests). The build exposes the `libarchive` Clang module, with SDK
zlib, bzip2 and iconv linkage. It includes a small UTF-8 constructor shim;
no upstream source patch, private Apple API or process locale mutation is used.

## Upgrade from GitHub Actions

Open **Actions → Build libarchive Apple → Run workflow** on the default branch.

1. Enter an explicit stable `libarchive_version`, such as `3.8.9`.
2. Leave `xz_version` blank to preserve the currently locked liblzma version,
   or enter an explicit new XZ version.
3. Set `revision` to a new positive integer when rebuilding an existing version pair.
4. Enable `publish` to create a Release after all build verification passes.
   Leave it off to build a candidate for inspection.

The resolver reads the selected official GitHub Release and its source archive's
SHA-256 digest. Downloads must match that independently supplied digest. It rejects
prereleases, moving selectors such as `latest`, unexpected repositories, malformed
versions and assets without a published digest. Older releases without a digest
need a reviewed edit to `sources.lock.json`; a download's own hash is not accepted
as independent verification.

New releases use `libarchive-<version>-xz-<version>-r<revision>`. Existing releases
are never overwritten. Dispatching a candidate does not change the repository's
default source lock or any application's dependency.

To make a version the new repository default, resolve and commit its source lock:

```sh
python3 scripts/source_lock.py --libarchive-version 3.8.9 --output sources.lock.json
```

A push to `main` or a pull request builds the locked versions without publishing.

## Local build

Requires Xcode command-line tools, Python 3.11+, system make, curl and shasum.
No Homebrew library or moving package dependency is used.

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
sh scripts/build.sh
sh scripts/verify.sh
python3 scripts/package.py
```

Override the source lock with `LIBARCHIVE_APPLE_SOURCE_LOCK=/absolute/path/lock.json`.
`LIBARCHIVE_APPLE_BUILD_JOBS`, `LIBARCHIVE_APPLE_DOWNLOAD_ROOT`,
`LIBARCHIVE_APPLE_BUILD_ROOT` and `LIBARCHIVE_APPLE_OUTPUT_ROOT` control local
resource use and output paths. If overriding the output root, also pass the
same path to `package.py --output`.
Pass the selected source lock to `package.py --lock` as well. Packaging refuses
to label a binary with a different source lock and preserves existing archives
when this check fails.

All slices finish before atomically replacing the XCFramework. Cache identity
includes source locks, recipe, module map, shim, public header, Xcode and SDKs.
The cache is a build optimization; publishing always follows verification.

## Release contents and application integration

- `LibraArchive.xcframework.zip`: static Apple slices and upstream licenses/notices.
- `artifact.json`: source versions/digests, artifact SHA-256, recipe commit,
  dirty-state flag, shim ABI and Xcode/SDK provenance.
- `sources.lock.json`: the exact source locks used for this build.
- `SHA256SUMS`: archive and metadata checksums.

Consumers pin a versioned release URL and its archive checksum. SwiftPM supports
`binaryTarget(name: "libarchive", url: ..., checksum: ...)`; a verified download
may also be installed at an existing local binary target path.

The public `archive_apple.h` provides `archive_apple_read_new_utf8()` and
`archive_apple_write_new_utf8()`. Each returns a normal libarchive object released
with `archive_read_free` or `archive_write_free`; use
`archive_entry_pathname()` to obtain the already-normalized UTF-8 pathname.
For writes, provide native UTF-8 pathname bytes with `archive_entry_set_pathname()`
and select ZIP `hdrcharset=UTF-8`, matching the shim's conversion contract.
The constructors preserve the caller's locale and work without system locale
files. `archive_apple_shim_abi()` reports the wrapper contract, currently 1.

A consumer with its own version-pinned private-header adapter should migrate
that adapter once to these constructors. The private-layout code now compiles
inside the binary using each slice's exact upstream headers and `config.h`.
Changes to referenced fields fail compilation; changed conversion behavior must
pass the Unicode/unavailable-locale regression. This removes the need to copy
private headers or hardcode every new upstream version in application code.

The build verifies ZIP stored/deflated CRC, C-locale Unicode ZIP/7z roundtrips,
RAR4/RAR5 compressed fixtures and iOS device/simulator link probes. It does not
replace application archive safety rules, full application regression or physical
device validation. The application still owns input format admission, bounds,
unsafe path/link rejection, atomic import and explicit file selection.

Register formats and filters explicitly. These containers use
`archive_read_support_filter_none()` plus the selected ZIP/RAR/RAR5/7z format
registrations. External-process filters are disabled; the all-filter convenience
registration is outside this artifact's supported contract.

## Licenses

Upstream libarchive BSD-style/file-specific notices and liblzma 0BSD notices are
bundled under `LibraArchive.xcframework/Licenses`. XZ's broader `COPYING` is included
for context; this build bundles liblzma, not the XZ command-line tools.
