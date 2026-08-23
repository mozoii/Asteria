#!/usr/bin/env bash
# Bootstrap Asteria from a fresh clone: generate the project, build, and
# ad-hoc sign the app so it launches on this Mac.
# Usage: ./bootstrap.sh [--release] [--test] [--project] [--doctor]
set -euo pipefail

RELEASE=0
TEST=0
PROJECT_ONLY=0
DOCTOR=0
for flag in "$@"; do
    case "$flag" in
        --release) RELEASE=1 ;;
        --test) TEST=1 ;;
        --project) PROJECT_ONLY=1 ;;
        --doctor) DOCTOR=1 ;;
        *)
            echo "error: unknown option '$flag'" >&2
            echo "usage: ./bootstrap.sh [--release] [--test] [--project] [--doctor]" >&2
            exit 64
            ;;
    esac
done

die() {
    echo "error: $*" >&2
    exit 1
}

# Verify the machine can build Asteria and resolve the Xcode toolchain, so
# environment problems fail fast with an actionable message instead of a
# deep xcodebuild error.
preflight() {
    if [ "$(uname -s)" != "Darwin" ]; then
        die "Asteria builds on macOS only; this machine is $(uname -s)."
    fi
    if [ "$(uname -m)" != "arm64" ]; then
        die "Asteria is Apple Silicon (arm64) only; this machine is $(uname -m)."
    fi

    local os_version major
    os_version="$(sw_vers -productVersion)"
    major="${os_version%%.*}"
    case "$major" in
        ''|*[!0-9]*) die "could not parse the macOS version from sw_vers ('$os_version')." ;;
    esac
    if [ "$major" -lt 26 ]; then
        die "Asteria requires macOS 26 or later; this Mac runs $os_version."
    fi

    if [ -n "${DEVELOPER_DIR:-}" ]; then
        [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ] || die "Xcode toolchain not found at $DEVELOPER_DIR. Install Xcode, or point DEVELOPER_DIR at its Contents/Developer directory."
    else
        # Xcode installs (including ones managed by the `xcodes` CLI) land in
        # /Applications, possibly with a versioned name.
        local candidate
        for candidate in /Applications/Xcode*.app; do
            if [ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]; then
                DEVELOPER_DIR="$candidate/Contents/Developer"
                break
            fi
        done
        if [ -z "$DEVELOPER_DIR" ]; then
            local selected
            selected="$(xcode-select -p 2>/dev/null || true)"
            if [ -n "$selected" ] && [ -x "$selected/usr/bin/xcodebuild" ]; then
                DEVELOPER_DIR="$selected"
            fi
        fi
        [ -n "$DEVELOPER_DIR" ] || die "Xcode not found. Install Xcode 26, or set DEVELOPER_DIR to its Contents/Developer directory."
        if [ -t 0 ]; then
            local answer
            printf 'Found Xcode at %s. Use it? [Y/n] ' "$DEVELOPER_DIR"
            read -r answer || answer="y"
            case "$answer" in
                [nN]*) die "aborted; re-run with DEVELOPER_DIR set to choose the Xcode toolchain." ;;
            esac
        else
            echo "==> Found Xcode at $DEVELOPER_DIR"
        fi
    fi
    export DEVELOPER_DIR

    # Package.swift needs swift-tools-version 6.2, which ships with Xcode 26.
    # DEVELOPER_DIR is exported above, so the /usr/bin shim targets that toolchain.
    local swift_version
    swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -n1)"
    [ -n "$swift_version" ] || die "could not determine the Swift version from $DEVELOPER_DIR; is this a full Xcode install?"
    if [ "$(printf '%s\n6.2\n' "$swift_version" | sort -V | head -n1)" != "6.2" ]; then
        die "Swift 6.2 or newer is required (found $swift_version); install Xcode 26 or point DEVELOPER_DIR at it."
    fi

    echo "==> Preflight: macOS $os_version on $(uname -m), Swift $swift_version, Xcode at $DEVELOPER_DIR"
}

preflight

XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to generate the Xcode project." >&2
    echo "  fix: brew install xcodegen" >&2
    exit 1
fi

cd "$(dirname "$0")"

echo "==> Generating Xcode project"
xcodegen generate

if [ "$DOCTOR" -eq 1 ]; then
    echo "==> Doctor: environment OK, Xcode project generated."
    exit 0
fi

if [ "$PROJECT_ONLY" -eq 1 ]; then
    echo "==> Done. Xcode project generated."
    exit 0
fi

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
