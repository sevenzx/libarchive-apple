#!/bin/sh
set -eu

REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_LOCK=${LIBARCHIVE_APPLE_SOURCE_LOCK:-"$REPOSITORY_ROOT/sources.lock.json"}
LOCK_TOOL="$REPOSITORY_ROOT/scripts/source_lock.py"
LIBARCHIVE_VERSION=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field libarchive.version)
LIBARCHIVE_URL=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field libarchive.url)
LIBARCHIVE_SHA256=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field libarchive.sha256)
XZ_VERSION=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field xz.version)
XZ_URL=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field xz.url)
XZ_SHA256=$(python3 "$LOCK_TOOL" --lock "$SOURCE_LOCK" --field xz.sha256)

BUILD_ROOT=${LIBARCHIVE_APPLE_BUILD_ROOT:-"$REPOSITORY_ROOT/.build/libarchive-$LIBARCHIVE_VERSION"}
DOWNLOAD_ROOT=${LIBARCHIVE_APPLE_DOWNLOAD_ROOT:-"$BUILD_ROOT/downloads"}
SOURCE_ROOT="$BUILD_ROOT/sources"
LIBARCHIVE_SOURCE="$SOURCE_ROOT/libarchive-$LIBARCHIVE_VERSION"
XZ_SOURCE="$SOURCE_ROOT/xz-$XZ_VERSION"
OUTPUT_ROOT=${LIBARCHIVE_APPLE_OUTPUT_ROOT:-"$REPOSITORY_ROOT/dist"}
XCFRAMEWORK_PATH="$OUTPUT_ROOT/LibraArchive.xcframework"
MODULEMAP_PATH="$REPOSITORY_ROOT/scripts/libarchive.modulemap"
SCRIPT_SHA256=$(shasum -a 256 "$REPOSITORY_ROOT/scripts/build.sh" | awk '{ print $1 }')
MODULEMAP_SHA256=$(shasum -a 256 "$MODULEMAP_PATH" | awk '{ print $1 }')
SHIM_SHA256=$(shasum -a 256 "$REPOSITORY_ROOT/src/archive_apple.c" | awk '{ print $1 }')
ASSEMBLER_SHA256=$(shasum -a 256 "$REPOSITORY_ROOT/scripts/assemble.py" | awk '{ print $1 }')
NOTICES_SHA256=$(shasum -a 256 "$REPOSITORY_ROOT/scripts/source_notices.py" | awk '{ print $1 }')
HEADER_SHA256=$(shasum -a 256 "$REPOSITORY_ROOT/include/archive_apple.h" | awk '{ print $1 }')
LOCK_SHA256=$(shasum -a 256 "$SOURCE_LOCK" | awk '{ print $1 }')
XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ')
SDK_VERSIONS="iphoneos=$(xcrun --sdk iphoneos --show-sdk-version),iphonesimulator=$(xcrun --sdk iphonesimulator --show-sdk-version),macosx=$(xcrun --sdk macosx --show-sdk-version)"
TOOLCHAIN_SHA256=$(printf '%s\n' "$XCODE_VERSION" "$SDK_VERSIONS" "$(xcrun --sdk macosx --find clang)" | shasum -a 256 | awk '{ print $1 }')
CACHE_SHA256=$(printf '%s\n' "$SCRIPT_SHA256" "$MODULEMAP_SHA256" "$SHIM_SHA256" "$HEADER_SHA256" "$ASSEMBLER_SHA256" "$NOTICES_SHA256" "$LOCK_SHA256" "$TOOLCHAIN_SHA256" | shasum -a 256 | awk '{ print $1 }')
CONFIGURATION_ROOT="$BUILD_ROOT/apple-static-v2-$CACHE_SHA256"
INSTALL_ROOT="$CONFIGURATION_ROOT/install"
JOBS=${LIBARCHIVE_APPLE_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || printf 4)}
case "$JOBS" in ""|*[!0-9]*|0) echo "Build jobs must be a positive integer" >&2; exit 2;; esac
STAMP_CONTENT="libarchive=$LIBARCHIVE_VERSION $LIBARCHIVE_SHA256
xz=$XZ_VERSION $XZ_SHA256
recipe=$SCRIPT_SHA256
modulemap=$MODULEMAP_SHA256
shim=$SHIM_SHA256
assembler=$ASSEMBLER_SHA256
notices=$NOTICES_SHA256
header=$HEADER_SHA256
source-lock=$LOCK_SHA256
toolchain=$TOOLCHAIN_SHA256
xcode=$XCODE_VERSION
sdk=$SDK_VERSIONS
shim-abi=1
platforms=ios17-arm64,ios17-simulator-arm64-x86_64,macos14-arm64-x86_64"

if [ -f "$XCFRAMEWORK_PATH/Info.plist" ] &&
    [ -f "$XCFRAMEWORK_PATH/.libarchive-apple-source-lock" ] &&
    [ "$(cat "$XCFRAMEWORK_PATH/.libarchive-apple-source-lock")" = "$STAMP_CONTENT" ]; then
    echo "Using pinned $XCFRAMEWORK_PATH"
    exit 0
fi

for TOOL in python3 curl shasum tar make xcrun xcodebuild; do
    command -v "$TOOL" >/dev/null 2>&1 || {
        echo "Missing build tool: $TOOL" >&2
        exit 1
    }
done

prepare_source() {
    SOURCE_NAME=$1
    SOURCE_URL=$2
    SOURCE_SHA256=$3
    ARCHIVE_PATH="$DOWNLOAD_ROOT/$SOURCE_NAME.tar.gz"
    mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT"
    if [ ! -f "$ARCHIVE_PATH" ]; then
        curl --fail --location --retry 2 --silent --show-error \
            "$SOURCE_URL" --output "$ARCHIVE_PATH.partial"
        ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE_PATH.partial" | awk '{ print $1 }')
        [ "$ACTUAL_SHA256" = "$SOURCE_SHA256" ] || {
            echo "Unexpected downloaded $SOURCE_NAME checksum: $ACTUAL_SHA256" >&2
            exit 1
        }
        mv "$ARCHIVE_PATH.partial" "$ARCHIVE_PATH"
    fi
    ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')
    [ "$ACTUAL_SHA256" = "$SOURCE_SHA256" ] || {
        echo "Unexpected cached $SOURCE_NAME checksum: $ACTUAL_SHA256" >&2
        exit 1
    }
    # Re-extract the verified archive so edits to a cached source cannot enter a build.
    rm -rf "$SOURCE_ROOT/$SOURCE_NAME"
    tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_ROOT"
}

require_config() {
    CONFIG_PATH=$1
    FEATURE=$2
    grep -qx "#define $FEATURE 1" "$CONFIG_PATH" || {
        echo "Required archive capability missing: $FEATURE ($CONFIG_PATH)" >&2
        exit 1
    }
}

build_slice() (
    SLICE_NAME=$1
    SDK_NAME=$2
    ARCH_NAME=$3
    HOST_NAME=$4
    MINIMUM_FLAG=$5
    SLICE_INSTALL="$INSTALL_ROOT/$SLICE_NAME"
    SLICE_LIBRARY="$SLICE_INSTALL/lib/libLibraArchive.a"
    if [ -f "$SLICE_LIBRARY" ] && [ -f "$SLICE_INSTALL/include/archive.h" ]; then
        cp "$MODULEMAP_PATH" "$SLICE_INSTALL/include/module.modulemap"
    cp "$REPOSITORY_ROOT/include/archive_apple.h" "$SLICE_INSTALL/include/archive_apple.h"
        return
    fi

    SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
    CLANG_PATH=$(xcrun --sdk "$SDK_NAME" --find clang)
    AR_PATH=$(xcrun --sdk "$SDK_NAME" --find ar)
    RANLIB_PATH=$(xcrun --sdk "$SDK_NAME" --find ranlib)
    XZ_BUILD="$CONFIGURATION_ROOT/build-xz-$SLICE_NAME"
    XZ_INSTALL="$INSTALL_ROOT/xz-$SLICE_NAME"
    ARCHIVE_BUILD="$CONFIGURATION_ROOT/build-archive-$SLICE_NAME"
    ARCH_FLAGS="-arch $ARCH_NAME -isysroot $SDK_PATH $MINIMUM_FLAG"
    mkdir -p "$XZ_BUILD" "$XZ_INSTALL" "$ARCHIVE_BUILD" "$SLICE_INSTALL/lib" "$SLICE_INSTALL/include"

    echo "Building liblzma $XZ_VERSION for $SLICE_NAME"
    (
        cd "$XZ_BUILD"
        CC="$CLANG_PATH" CPP="$CLANG_PATH -E $ARCH_FLAGS" AR="$AR_PATH" RANLIB="$RANLIB_PATH" \
        CFLAGS="$ARCH_FLAGS -O2 -g -fPIC" LDFLAGS="$ARCH_FLAGS" \
        PKG_CONFIG=false \
        "$XZ_SOURCE/configure" \
            --host="$HOST_NAME" --prefix="$XZ_INSTALL" \
            --enable-static --disable-shared --enable-pic \
            --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
            --disable-lzma-links --disable-scripts --disable-doc --disable-nls \
            --disable-microlzma --disable-lzip-decoder --disable-rpath
        make -C src/liblzma -j"$JOBS"
        make -C src/liblzma install
    )

    echo "Building libarchive $LIBARCHIVE_VERSION for $SLICE_NAME"
    (
        cd "$ARCHIVE_BUILD"
        CC="$CLANG_PATH" CPP="$CLANG_PATH -E $ARCH_FLAGS" AR="$AR_PATH" RANLIB="$RANLIB_PATH" \
        CFLAGS="$ARCH_FLAGS -O2 -g -fPIC" LDFLAGS="$ARCH_FLAGS" \
        CPPFLAGS="-I$XZ_INSTALL/include" \
        LIBS="$SDK_PATH/usr/lib/libz.tbd $SDK_PATH/usr/lib/libbz2.tbd $SDK_PATH/usr/lib/libiconv.tbd" \
        LZMA_PC_CFLAGS="-I$XZ_INSTALL/include" LZMA_PC_LIBS="$XZ_INSTALL/lib/liblzma.a" \
        PKG_CONFIG=false ac_cv_func_fork=no ac_cv_func_vfork=no \
        ac_cv_func_posix_spawn=no ac_cv_func_posix_spawnp=no \
        "$LIBARCHIVE_SOURCE/configure" \
            --host="$HOST_NAME" --prefix="$SLICE_INSTALL" \
            --enable-static --disable-shared --enable-pic \
            --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
            --disable-acl --disable-xattr --disable-rpath --disable-posix-regex-lib \
            --with-zlib --with-bz2lib --with-iconv --without-libiconv-prefix --with-lzma \
            --without-libb2 --without-lz4 --without-zstd --without-lzo2 \
            --without-openssl --without-nettle --without-mbedtls --without-cng \
            --without-xml2 --without-expat
        require_config "$ARCHIVE_BUILD/config.h" HAVE_LIBZ
        require_config "$ARCHIVE_BUILD/config.h" HAVE_LIBBZ2
        require_config "$ARCHIVE_BUILD/config.h" HAVE_LIBLZMA
        require_config "$ARCHIVE_BUILD/config.h" HAVE_ICONV
        make -j"$JOBS" libarchive.la
        make install-includeHEADERS
    )

    # Compile private-layout access with this slice's exact source and config.
    "$CLANG_PATH" $ARCH_FLAGS -O2 -g -fPIC -std=c11 -Wall -Wextra -Werror \
        -DHAVE_CONFIG_H -I"$ARCHIVE_BUILD" -I"$LIBARCHIVE_SOURCE/libarchive" \
        -I"$REPOSITORY_ROOT/include" -c "$REPOSITORY_ROOT/src/archive_apple.c" \
        -o "$ARCHIVE_BUILD/archive_apple.o"

    # Upstream libtool versions differ in handling nested static dependencies.
    # Let Apple's archiver assemble the actual compiled objects consistently.
    python3 "$REPOSITORY_ROOT/scripts/assemble.py" "$ARCHIVE_BUILD" \
        "$XZ_INSTALL/lib/liblzma.a" "$ARCHIVE_BUILD/archive_apple.o" "$SLICE_LIBRARY.partial"
    mv "$SLICE_LIBRARY.partial" "$SLICE_LIBRARY"
    cp "$MODULEMAP_PATH" "$SLICE_INSTALL/include/module.modulemap"
    cp "$REPOSITORY_ROOT/include/archive_apple.h" "$SLICE_INSTALL/include/archive_apple.h"
)

make_universal_slice() {
    UNIVERSAL_NAME=$1
    FIRST_SLICE=$2
    SECOND_SLICE=$3
    UNIVERSAL_ROOT="$INSTALL_ROOT/$UNIVERSAL_NAME"
    mkdir -p "$UNIVERSAL_ROOT/lib" "$UNIVERSAL_ROOT/include"
    cmp "$INSTALL_ROOT/$FIRST_SLICE/include/archive.h" "$INSTALL_ROOT/$SECOND_SLICE/include/archive.h"
    cmp "$INSTALL_ROOT/$FIRST_SLICE/include/archive_entry.h" "$INSTALL_ROOT/$SECOND_SLICE/include/archive_entry.h"
    xcrun lipo -create \
        "$INSTALL_ROOT/$FIRST_SLICE/lib/libLibraArchive.a" \
        "$INSTALL_ROOT/$SECOND_SLICE/lib/libLibraArchive.a" \
        -output "$UNIVERSAL_ROOT/lib/libLibraArchive.a"
    cp "$INSTALL_ROOT/$FIRST_SLICE/include/archive.h" "$UNIVERSAL_ROOT/include/"
    cp "$INSTALL_ROOT/$FIRST_SLICE/include/archive_entry.h" "$UNIVERSAL_ROOT/include/"
    cp "$MODULEMAP_PATH" "$UNIVERSAL_ROOT/include/module.modulemap"
    cp "$REPOSITORY_ROOT/include/archive_apple.h" "$UNIVERSAL_ROOT/include/archive_apple.h"
}

prepare_source "libarchive-$LIBARCHIVE_VERSION" "$LIBARCHIVE_URL" "$LIBARCHIVE_SHA256"
prepare_source "xz-$XZ_VERSION" "$XZ_URL" "$XZ_SHA256"
build_slice "ios-arm64" "iphoneos" "arm64" "aarch64-apple-darwin" "-mios-version-min=17.0"
build_slice "simulator-arm64" "iphonesimulator" "arm64" "aarch64-apple-darwin" "-mios-simulator-version-min=17.0"
build_slice "simulator-x86_64" "iphonesimulator" "x86_64" "x86_64-apple-darwin" "-mios-simulator-version-min=17.0"
build_slice "macos-arm64" "macosx" "arm64" "aarch64-apple-darwin" "-mmacosx-version-min=14.0"
build_slice "macos-x86_64" "macosx" "x86_64" "x86_64-apple-darwin" "-mmacosx-version-min=14.0"
make_universal_slice "simulator-universal" "simulator-arm64" "simulator-x86_64"
make_universal_slice "macos-universal" "macos-arm64" "macos-x86_64"

mkdir -p "$OUTPUT_ROOT"
STAGED_PATH="$CONFIGURATION_ROOT/LibraArchive.xcframework"
rm -rf "$STAGED_PATH"
xcodebuild -create-xcframework \
    -library "$INSTALL_ROOT/ios-arm64/lib/libLibraArchive.a" -headers "$INSTALL_ROOT/ios-arm64/include" \
    -library "$INSTALL_ROOT/simulator-universal/lib/libLibraArchive.a" -headers "$INSTALL_ROOT/simulator-universal/include" \
    -library "$INSTALL_ROOT/macos-universal/lib/libLibraArchive.a" -headers "$INSTALL_ROOT/macos-universal/include" \
    -output "$STAGED_PATH"
printf '%s\n' "$STAMP_CONTENT" > "$STAGED_PATH/.libarchive-apple-source-lock"
cp "$SOURCE_LOCK" "$STAGED_PATH/sources.lock.json"
mkdir -p "$STAGED_PATH/Licenses"
cp "$LIBARCHIVE_SOURCE/COPYING" "$STAGED_PATH/Licenses/libarchive-COPYING.txt"
cp "$XZ_SOURCE/COPYING" "$STAGED_PATH/Licenses/xz-COPYING.txt"
cp "$XZ_SOURCE/COPYING.0BSD" "$STAGED_PATH/Licenses/liblzma-0BSD.txt"
python3 "$REPOSITORY_ROOT/scripts/source_notices.py" "$LIBARCHIVE_SOURCE/libarchive" "$STAGED_PATH/Licenses/libarchive-source-notices.txt"

# Move only a complete XCFramework into place; restore the old one if replacement fails.
PREVIOUS_PATH="$OUTPUT_ROOT/.LibarchiveApple.previous-$$.xcframework"
restore_previous() {
    if [ -d "$PREVIOUS_PATH" ]; then
        if [ ! -d "$XCFRAMEWORK_PATH" ]; then
            mv "$PREVIOUS_PATH" "$XCFRAMEWORK_PATH"
        else
            rm -rf "$PREVIOUS_PATH"
        fi
    fi
}
trap restore_previous EXIT HUP INT TERM
if [ -d "$XCFRAMEWORK_PATH" ]; then
    mv "$XCFRAMEWORK_PATH" "$PREVIOUS_PATH"
fi
mv "$STAGED_PATH" "$XCFRAMEWORK_PATH"
restore_previous
trap - EXIT HUP INT TERM
echo "Created $XCFRAMEWORK_PATH"
