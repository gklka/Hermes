#!/bin/sh
# Builds the Go core (Core/) as a static C archive for every architecture Xcode
# asks for, and lipos them into Core/build/libmmcore.a + libmmcore.h.
set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:$PATH"

ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE="$ROOT/Core"
OUT="$CORE/build"
mkdir -p "$OUT"

export CGO_ENABLED=1
export GOOS=darwin
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
BUILD_ARCHS="${ARCHS:-$(uname -m)}"

cd "$CORE"
LIBS=""
FIRST=""
for arch in $BUILD_ARCHS; do
	case "$arch" in
		arm64) goarch=arm64 ;;
		x86_64) goarch=amd64 ;;
		*) echo "unsupported arch $arch" >&2; exit 1 ;;
	esac
	mkdir -p "$OUT/$arch"
	# Xcode's path contains a space ("Xcode 27.1.app"), which cgo can't handle in CC/CFLAGS,
	# so go through xcrun and let it pick the SDK instead of passing absolute paths.
	GOARCH=$goarch \
	CC="xcrun --sdk macosx clang" \
	CGO_CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET -O2" \
	CGO_LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
		go build -buildmode=c-archive -trimpath -o "$OUT/$arch/libmmcore.a" .
	LIBS="$LIBS $OUT/$arch/libmmcore.a"
	[ -z "$FIRST" ] && FIRST="$arch"
done

# shellcheck disable=SC2086
lipo -create $LIBS -output "$OUT/libmmcore.a"
cp "$OUT/$FIRST/libmmcore.h" "$OUT/libmmcore.h"
