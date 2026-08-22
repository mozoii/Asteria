#!/usr/bin/env bash
# Bootstrap Asteria from a fresh clone: generate the project, build, and
# ad-hoc sign the app so it launches on this Mac.
# Usage: ./bootstrap.sh [--release] [--test]
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

RELEASE=0
TEST=0
for flag in "$@"; do
    case "$flag" in
        --release) RELEASE=1 ;;
        --test) TEST=1 ;;
        *)
            echo "error: unknown option '$flag'" >&2
            echo "usage: ./bootstrap.sh [--release] [--test]" >&2
            exit 64
            ;;
    esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to generate the Xcode project." >&2
    echo "  fix: brew install xcodegen" >&2
    exit 1
fi

XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
if [ ! -x "$XCODEBUILD" ]; then
    echo "error: Xcode toolchain not found at $DEVELOPER_DIR." >&2
    echo "  fix: install Xcode, or point DEVELOPER_DIR at its Contents/Developer directory." >&2
    exit 1
fi

cd "$(dirname "$0")"

echo "==> Generating Xcode project"
xcodegen generate

SCHEME=Debug
CONFIGURATION=Debug
if [ "$RELEASE" -eq 1 ]; then
    SCHEME=Release
    CONFIGURATION=Release
fi

echo "==> Building scheme $SCHEME"
"$XCODEBUILD" -project Asteria.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -derivedDataPath .build/xcode build

APP=".build/xcode/Build/Products/$CONFIGURATION/Asteria.app"
if [ ! -d "$APP" ]; then
    echo "error: expected app bundle not found at $APP" >&2
    exit 1
fi

echo "==> Ad-hoc signing $APP"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

if [ "$TEST" -eq 1 ]; then
    echo "==> Running AsteriaKit test suite"
    CLANG_MODULE_CACHE_PATH=/private/tmp/asteria-clang-module-cache \
        swift test --disable-sandbox --package-path AsteriaKit
fi

echo "==> Done. Signed app ready to run: $APP"
