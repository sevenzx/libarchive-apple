#!/bin/sh
set -eu
REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_ROOT=${LIBARCHIVE_APPLE_OUTPUT_ROOT:-"$REPOSITORY_ROOT/dist"}
XCFRAMEWORK="$OUTPUT_ROOT/LibraArchive.xcframework"
MACOS="$XCFRAMEWORK/macos-arm64_x86_64"
mkdir -p "$OUTPUT_ROOT"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -I"$MACOS/Headers" "$REPOSITORY_ROOT/tests/smoke.c" \
    "$MACOS/libLibraArchive.a" -lz -lbz2 -liconv -o "$OUTPUT_ROOT/archive-smoke"
"$OUTPUT_ROOT/archive-smoke" "$REPOSITORY_ROOT/tests/fixtures/rar4-compressed.rar" \
    "$REPOSITORY_ROOT/tests/fixtures/rar5-compressed.rar"
xcrun swiftc -I"$MACOS/Headers" "$REPOSITORY_ROOT/tests/import.swift" \
    "$MACOS/libLibraArchive.a" -o "$OUTPUT_ROOT/swift-import"
"$OUTPUT_ROOT/swift-import"
# Prove UTF-8 conversion works without the locale files unavailable on iOS.
sandbox-exec -p '(version 1)(allow default)(deny file-read* (subpath "/usr/share/locale"))' \
    "$OUTPUT_ROOT/archive-smoke" "$REPOSITORY_ROOT/tests/fixtures/rar4-compressed.rar" \
    "$REPOSITORY_ROOT/tests/fixtures/rar5-compressed.rar"
# Link each non-host target against its actual SDK, rather than only inspecting lipo.
for TARGET in device simulator-arm64 simulator-x86_64; do
    case "$TARGET" in
        device) SDK=iphoneos; ARCH=arm64; MIN=-mios-version-min=17.0; SLICE=ios-arm64;;
        simulator-arm64) SDK=iphonesimulator; ARCH=arm64; MIN=-mios-simulator-version-min=17.0; SLICE=ios-arm64_x86_64-simulator;;
        simulator-x86_64) SDK=iphonesimulator; ARCH=x86_64; MIN=-mios-simulator-version-min=17.0; SLICE=ios-arm64_x86_64-simulator;;
    esac
    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    xcrun --sdk "$SDK" clang -arch "$ARCH" -isysroot "$SDK_PATH" "$MIN" \
        -I"$XCFRAMEWORK/$SLICE/Headers" "$REPOSITORY_ROOT/tests/smoke.c" \
        "$XCFRAMEWORK/$SLICE/libLibraArchive.a" -lz -lbz2 -liconv \
        -o "$OUTPUT_ROOT/link-$TARGET"
done
