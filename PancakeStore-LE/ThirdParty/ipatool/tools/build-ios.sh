#!/bin/sh
set -eu

# Build a standalone executable for jailbroken arm64 devices running iOS 15+.
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-ipatool-ios-arm64}
VERSION=${VERSION:-dev}

for TOOL in ldid cmake; do
  command -v "$TOOL" >/dev/null 2>&1 || {
    echo "$TOOL is required; install it with 'brew install ldid cmake'." >&2
    exit 1
  }
done

SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos --find clang)
export SDKROOT CC
export IPHONEOS_DEPLOYMENT_TARGET=15.0
export GOOS=ios GOARCH=arm64 CGO_ENABLED=1

BUILD_DIR=$(mktemp -d /tmp/ipatool-ios.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

# Keep the API version in sync with internal/sap/unicorn/artifact.go.
sh "$ROOT/tools/prepare-unicorn-tci.sh" "$BUILD_DIR"
ARCHFLAGS='-arch arm64' cmake -S "$BUILD_DIR/unicorn-2.1.4" -B "$BUILD_DIR/build" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_C_FLAGS='-target arm64-apple-ios15.0' -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DBUILD_SHARED_LIBS=OFF -DUNICORN_LEGACY_STATIC_ARCHIVE=ON -DUNICORN_ARCH=aarch64 -DUNICORN_INTERPRETER=ON -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF
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
if ! grep -q '^UNICORN_ARCH:STRING=aarch64$' "$BUILD_DIR/build/CMakeCache.txt"; then
  echo "Unicorn was not configured with the AArch64 guest backend." >&2
  exit 1
fi
if ! grep -q -- '-DUNICORN_HAS_ARM64' "$BUILD_DIR/build/compile_commands.json"; then
  echo "Unicorn compile commands do not enable UNICORN_HAS_ARM64." >&2
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

# purego resolves the statically linked Unicorn API through dlsym.
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -Wl,-force_load,$BUILD_DIR/build/libunicorn.a -Wl,-export_dynamic"
cd "$ROOT"
go build -ldflags="-X github.com/majd/ipatool/v2/cmd.version=$VERSION" -o "$OUTPUT" .
ldid -S"$ROOT/resources/ios-entitlements.plist" "$OUTPUT"
