#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IPATOOL="$ROOT/ThirdParty/ipatool"
OUTPUT="$ROOT/GoBridge"
VERSION=ios-bridge

for TOOL in cmake curl go; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "$TOOL is required." >&2
    exit 1
  }
done

SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang)
BUILD_DIR=$(mktemp -d /tmp/pancake-ipatool.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM
mkdir -p "$OUTPUT"

# Prepare the pinned Unicorn 2.1.4 TCI interpreter source.
sh "$IPATOOL/tools/prepare-unicorn-tci.sh" "$BUILD_DIR"
cmake -S "$BUILD_DIR/unicorn-2.1.4" -B "$BUILD_DIR/build" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 \
  -DCMAKE_C_FLAGS='-target arm64-apple-ios16.4' \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_LEGACY_STATIC_ARCHIVE=ON \
  -DUNICORN_ARCH=aarch64 \
  -DUNICORN_INTERPRETER=ON \
  -DUNICORN_BUILD_TESTS=OFF \
  -DUNICORN_INSTALL=OFF
# CMAKE_OSX_ARCHITECTURES selects the iOS host CPU; UNICORN_ARCH selects
# the emulated guest CPU. The Anisette runtime calls UC_ARCH_ARM64, so the
# AArch64 backend must be enabled explicitly in the static library.
if ! grep -q '^UNICORN_ARCH:STRING=aarch64$' "$BUILD_DIR/build/CMakeCache.txt"; then
  echo "Unicorn was not configured with the AArch64 guest backend." >&2
  exit 1
fi
if ! grep -q -- '-DUNICORN_HAS_ARM64' "$BUILD_DIR/build/compile_commands.json"; then
  echo "Unicorn compile commands do not enable UNICORN_HAS_ARM64." >&2
  exit 1
fi

cmake --build "$BUILD_DIR/build" --parallel "$(sysctl -n hw.ncpu)"

UNIVERSAL="$BUILD_DIR/build/libunicorn.a"
if [ ! -s "$UNIVERSAL" ]; then
  echo "Unicorn static library was not produced." >&2
  exit 1
fi
if ! ar -t "$UNIVERSAL" | grep -q 'translate-a64'; then
  echo "Unicorn static archive is missing the AArch64 translator object." >&2
  exit 1
fi
if ! grep -q '^UNICORN_INTERPRETER:BOOL=ON$' "$BUILD_DIR/build/CMakeCache.txt"; then
  echo "Unicorn was not configured for TCI interpreter mode." >&2
  exit 1
fi
if ! grep -q '^CONFIG_TCG_INTERPRETER=y$' "$BUILD_DIR/build/config-host.mak"; then
  echo "Unicorn QEMU configuration does not enable the TCI interpreter." >&2
  exit 1
fi
if ! ar -t "$UNIVERSAL" | grep -Eq '(^|/)tci(\.c)?\.o$'; then
  echo "Unicorn static archive is missing the TCI interpreter object." >&2
  exit 1
fi

export SDKROOT CC
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1
export IPHONEOS_DEPLOYMENT_TARGET=16.4
export CGO_CFLAGS="-target arm64-apple-ios16.4 -isysroot $SDKROOT"
export CGO_LDFLAGS="-target arm64-apple-ios16.4 -isysroot $SDKROOT"
export GOFLAGS="-buildvcs=false"

cd "$IPATOOL"
go env GOOS GOARCH CGO_ENABLED
go build -trimpath -buildmode=c-archive -o "$OUTPUT/libPancakeIPATool.a" ./bridge/ios
cp "$UNIVERSAL" "$OUTPUT/libunicorn.a"
test -s "$OUTPUT/libPancakeIPATool.a"
test -s "$OUTPUT/libPancakeIPATool.h"
test -s "$OUTPUT/libunicorn.a"
echo "[*] Built PancakeStore ipatool c-archive and Unicorn for iOS arm64."
