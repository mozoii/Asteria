#!/usr/bin/env bash
# Bootstrap Asteria from a fresh clone: generate the project, build, and sign.
# Signing uses a stable self-signed identity (created on first run) so every
# rebuild shares one code signature and keeps keychain access.
# Usage: ./bootstrap.sh [--release] [--test] [--project] [--doctor]
#                       [--ios | --ios-simulator] [--test-ios]
set -euo pipefail

# Stable code-signing identity, provisioned once in the login keychain.
SIGNING_IDENTITY="Asteria Development (Self-Signed)"

USAGE="usage: ./bootstrap.sh [--release] [--test] [--project] [--doctor] [--ios | --ios-simulator] [--test-ios]"

RELEASE=0
TEST=0
PROJECT_ONLY=0
DOCTOR=0
IOS=0
IOS_SIMULATOR=0
TEST_IOS=0
for flag in "$@"; do
    case "$flag" in
        --release) RELEASE=1 ;;
        --test) TEST=1 ;;
        --project) PROJECT_ONLY=1 ;;
        --doctor) DOCTOR=1 ;;
        --ios) IOS=1 ;;
        --ios-simulator) IOS=1; IOS_SIMULATOR=1 ;;
        --test-ios) TEST_IOS=1 ;;
        *)
            echo "error: unknown option '$flag'" >&2
            echo "$USAGE" >&2
            exit 64
            ;;
    esac
done

die() {
    echo "error: $*" >&2
    exit 1
}

# Create the stable identity once. Rebuilds then share one code signature, so the
# keychain's signature-based ACL keeps granting access without loosening it.
provision_signing_identity() {
    # find-identity misses self-signed certs, so gate on the certificate.
    # find-certificate -a exits 0 even on no match, so gate on its output.
    if security find-certificate -a -c "$SIGNING_IDENTITY" \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -q .; then
        echo "==> Signing identity '$SIGNING_IDENTITY' already present"
        return 0
    fi

    echo "==> Creating self-signed signing identity '$SIGNING_IDENTITY' in the login keychain"
    local tmp
    tmp="$(mktemp -d)"
    if ! openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -days 3650 -nodes -subj "/CN=$SIGNING_IDENTITY/O=Asteria" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null; then
        rm -rf "$tmp" && die "could not generate the code-signing key/certificate (openssl)."
    fi
    if ! openssl pkcs12 -export -legacy -out "$tmp/id.p12" \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$SIGNING_IDENTITY" -passout pass:keychain 2>/dev/null; then
        rm -rf "$tmp" && die "could not export the code-signing identity (openssl)."
    fi
    # Trust codesign to use the key — the system one, and the selected toolchain's too.
    local trusts=("/usr/bin/codesign")
    [ -n "${DEVELOPER_DIR:-}" ] && trusts+=("$DEVELOPER_DIR/usr/bin/codesign")
    local imported=0 tool
    for tool in "${trusts[@]}"; do
        [ -x "$tool" ] || continue
        security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
            -P keychain -T "$tool" 2>/dev/null && imported=1
    done
    if [ "$imported" -ne 1 ]; then
        rm -rf "$tmp" && die "could not import the code-signing identity; unlock your login keychain and retry."
    fi
    rm -rf "$tmp"
    echo "==> Signing identity ready. If macOS asks to use the key once, choose 'Always Allow'."
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

# The iOS target reads ASTERIA_DEVELOPMENT_TEAM from a gitignored Local.xcconfig, and xcodegen refuses to
# generate when a referenced config file is missing. Seed it from the example on a fresh clone.
if [ ! -f Local.xcconfig ]; then
    echo "==> Creating Local.xcconfig from Local.xcconfig.example"
    cp Local.xcconfig.example Local.xcconfig
fi

# An explicit team wins over whatever is in the file, so CI and one-off builds need no edit.
if [ -n "${ASTERIA_DEVELOPMENT_TEAM:-}" ]; then
    echo "==> Using DEVELOPMENT_TEAM=$ASTERIA_DEVELOPMENT_TEAM from the environment"
    printf 'ASTERIA_DEVELOPMENT_TEAM = %s\n' "$ASTERIA_DEVELOPMENT_TEAM" > Local.xcconfig
fi

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

# The same suite against the iOS simulator. Suites that need real hardware (Metal, MetalFX, a video
# decoder, a writable keychain) carry availability traits and skip there rather than failing.
if [ "$TEST_IOS" -eq 1 ]; then
    SIM_ID="$(xcrun simctl list devices available --json 2>/dev/null \
        | /usr/bin/python3 -c 'import json,sys
data = json.load(sys.stdin)["devices"]
for runtime, devices in sorted(data.items()):
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit
' 2>/dev/null || true)"
    if [ -z "$SIM_ID" ]; then
        echo "error: no iOS simulator is installed, so the iOS test run cannot start." >&2
        echo "  fix: Xcode → Settings → Components, and install an iOS Simulator runtime." >&2
        exit 1
    fi
    echo "==> Running AsteriaKit test suite on iOS simulator $SIM_ID"
    # Run from the package, not Asteria.xcodeproj, and use the -Package scheme: the plain AsteriaKit
    # scheme builds only the library product and has no test action.
    (cd AsteriaKit && "$XCODEBUILD" -scheme AsteriaKit-Package \
        -destination "platform=iOS Simulator,id=$SIM_ID" \
        -derivedDataPath "$PWD/../.build/xcode-ios-tests" test)
    exit 0
fi


SCHEME=Debug
CONFIGURATION=Debug
if [ "$RELEASE" -eq 1 ]; then
    SCHEME=Release
    CONFIGURATION=Release
fi

# iOS builds take the parallel scheme and skip the Mac signing step entirely: iOS devices only run
# Apple-issued signatures, so provisioning is Xcode's automatic-signing job, not this script's.
if [ "$IOS" -eq 1 ]; then
    IOS_SCHEME="$SCHEME-iOS"
    if [ "$IOS_SIMULATOR" -eq 1 ]; then
        DESTINATION="generic/platform=iOS Simulator"
    else
        DESTINATION="generic/platform=iOS"
    fi
    echo "==> Building scheme $IOS_SCHEME for $DESTINATION"
    IOS_ARGS=(-project Asteria.xcodeproj -scheme "$IOS_SCHEME" -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" -derivedDataPath .build/xcode-ios)
    if [ "$IOS_SIMULATOR" -eq 0 ]; then
        IOS_ARGS+=(-allowProvisioningUpdates)
    fi
    if ! "$XCODEBUILD" "${IOS_ARGS[@]}" build; then
        echo "error: the iOS build failed." >&2
        echo "  If it stopped on code signing, set your Apple Developer team:" >&2
        echo "    ASTERIA_DEVELOPMENT_TEAM=XXXXXXXXXX ./bootstrap.sh --ios" >&2
        echo "  or open Asteria.xcodeproj and pick a team under AsteriaMobile →" >&2
        echo "  Signing & Capabilities. A free personal team is enough." >&2
        exit 1
    fi
    echo "==> Done. iOS app built at .build/xcode-ios/Build/Products/"
    exit 0
fi

provision_signing_identity

echo "==> Building scheme $SCHEME"
"$XCODEBUILD" -project Asteria.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -derivedDataPath .build/xcode build

APP=".build/xcode/Build/Products/$CONFIGURATION/Asteria.app"
if [ ! -d "$APP" ]; then
    echo "error: expected app bundle not found at $APP" >&2
    exit 1
fi

# xcodebuild already signed the bundle and everything nested in it with $SIGNING_IDENTITY,
# including the entitlements and the hardened runtime. Re-signing here would drop both, so this
# only checks the result.
echo "==> Verifying the signature on $APP"
codesign --verify --strict --deep "$APP"
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
case "$SIGNATURE" in
    *"Authority=$SIGNING_IDENTITY"*) ;;
    *) die "$APP is not signed with '$SIGNING_IDENTITY'; delete .build and re-run ./bootstrap.sh." ;;
esac

if [ "$TEST" -eq 1 ]; then
    echo "==> Running AsteriaKit test suite"
    CLANG_MODULE_CACHE_PATH=/private/tmp/asteria-clang-module-cache \
        swift test --disable-sandbox --package-path AsteriaKit
fi

echo "==> Done. Signed app ready to run: $APP"
