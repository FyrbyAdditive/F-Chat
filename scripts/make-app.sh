#!/usr/bin/env bash
# Build F-Chat.app via xcodebuild (REQUIRED for MLX — `swift build` from the
# CLI cannot compile Metal shaders). xcodebuild produces the `mlx-swift_Cmlx`
# resource bundle containing `default.metallib`, plus the per-target SPM
# resource bundles. We assemble them into a proper macOS .app at build/F-Chat.app.

set -euo pipefail

CONFIG="Release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="Debug"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
APP_DIR="$ROOT/build/F-Chat.app"

# The Qwen3 weights are stored split (GitHub LFS caps at 2 GiB/file).
# Reassemble into a single safetensors before the build so the resource
# bundle includes the complete file.
echo "==> assemble-qwen3-model.sh"
"$ROOT/scripts/assemble-qwen3-model.sh"

echo "==> fetch-python.sh (vendored CPython for skill code execution)"
"$ROOT/scripts/fetch-python.sh"

echo "==> xcodebuild -scheme FChat -configuration $CONFIG"
xcodebuild \
    -scheme FChat \
    -destination "generic/platform=macOS" \
    -configuration "$CONFIG" \
    -skipMacroValidation \
    -derivedDataPath "$DERIVED" \
    build >"$DERIVED/build.log" 2>&1 \
    || { echo "xcodebuild failed; see $DERIVED/build.log"; tail -40 "$DERIVED/build.log"; exit 1; }

EXEC="$PRODUCTS/FChat"
if [[ ! -x "$EXEC" ]]; then
    echo "error: FChat binary not found at $EXEC" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC" "$APP_DIR/Contents/MacOS/FChat"

# The app icon lives in the FChatApp resource sources but macOS expects it
# at the top of Contents/Resources/. Copy it there explicitly so Dock /
# Finder / Spotlight can find it via the CFBundleIconFile lookup below.
ICON_SRC="$ROOT/Sources/FChatApp/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Copy every SPM resource bundle xcodebuild produced into Resources/. This
# includes our own per-module bundles (F-Chat_FChatRAG.bundle with the
# Qwen3 model, F-Chat_FChatCore.bundle with the tokenizer files, etc.)
# AND third-party bundles (mlx-swift_Cmlx.bundle with default.metallib,
# swift-transformers_Hub.bundle, GRDB_GRDB.bundle, etc.).
for bundle in "$PRODUCTS"/*.bundle; do
    if [[ -e "$bundle" ]]; then
        cp -R "$bundle" "$APP_DIR/Contents/Resources/"
    fi
done

# Bundle the vendored relocatable CPython so Agent Skills' `.py` helpers run
# via the sandboxed `run_code` tool regardless of whether the user's Mac has a
# system python3. CodeSandbox resolves it at
# Contents/Resources/python3/bin/python3.
VENDORED_PY="$ROOT/vendor/python3"
if [[ -x "$VENDORED_PY/bin/python3" ]]; then
    echo "==> bundling vendored python3"
    cp -R "$VENDORED_PY" "$APP_DIR/Contents/Resources/python3"
else
    echo "warning: vendored python3 not found at $VENDORED_PY; skills' python scripts won't run in the built app" >&2
fi

# Promote the FChatApp bundle's per-locale Localizable.strings to the app's
# top-level Contents/Resources/<locale>.lproj/ so SwiftUI's default
# `Text("...")` lookup — which consults Bundle.main — finds them. SwiftPM
# emits xcstrings output only inside the module's resource bundle
# (Bundle.module), so without this promotion the catalog is on disk but
# unreachable for any view that doesn't pass `bundle: .module`. This is
# the load-bearing piece of the localization fix; without it the existing
# Swedish translations never reach the user.
APP_BUNDLE_RES="$APP_DIR/Contents/Resources/F-Chat_FChatApp.bundle/Contents/Resources"
if [[ -d "$APP_BUNDLE_RES" ]]; then
    shopt -s nullglob
    for lproj in "$APP_BUNDLE_RES"/*.lproj; do
        locale="$(basename "$lproj" .lproj)"
        dest="$APP_DIR/Contents/Resources/$locale.lproj"
        mkdir -p "$dest"
        for f in "$lproj"/Localizable.strings "$lproj"/Localizable.stringsdict; do
            if [[ -e "$f" ]]; then
                cp "$f" "$dest/"
            fi
        done
    done
    shopt -u nullglob
fi

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>F-Chat</string>
    <key>CFBundleExecutable</key>
    <string>FChat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.fyrbyadditive.fchat</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>sv</string>
        <string>da</string>
    </array>
    <key>CFBundleName</key>
    <string>F-Chat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.fyrbyadditive.fchat.oauth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>fchat</string>
            </array>
        </dict>
    </array>
    <key>CFBundleVersion</key>
    <string>0.4.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

# --- Code signing -----------------------------------------------------------
# Sign with a stable identity so macOS Keychain "Always Allow" grants persist.
# An unsigned / linker-adhoc bundle changes code identity every build, so the
# Keychain ACL never matches and the Providers page re-prompts on every launch.
# Developer ID + hardened runtime also makes the app notarization-ready.
# Override the identity with FCHAT_CODESIGN_IDENTITY (use "-" for stable ad-hoc).
SIGN_ID="${FCHAT_CODESIGN_IDENTITY:-Developer ID Application: Timothy Ellis (QS865LKS7W)}"
ENTITLEMENTS="$ROOT/scripts/FChat.entitlements"

sign_one() {
    # Sign a single Mach-O with hardened runtime; tolerate non-Mach-O / failures
    # on nested files (we re-verify the whole bundle at the end).
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$1" >/dev/null 2>&1 || true
}

if [[ "$SIGN_ID" == "-" ]] || security find-identity -v -p codesigning | grep -q "${SIGN_ID%% (*}"; then
    echo "==> codesign ($SIGN_ID)"
    # 1) Nested Mach-O inside the vendored Python tree (dylibs, .so, bin/*), inside-out.
    if [[ -d "$APP_DIR/Contents/Resources/python3" ]]; then
        while IFS= read -r -d '' f; do
            if file "$f" | grep -q 'Mach-O'; then sign_one "$f"; fi
        done < <(find "$APP_DIR/Contents/Resources/python3" \
                    \( -name '*.dylib' -o -name '*.so' -o -path '*/bin/*' \) -type f -print0)
    fi
    # 2) Any dylibs shipped in the SPM resource bundles.
    while IFS= read -r -d '' f; do
        sign_one "$f"
    done < <(find "$APP_DIR/Contents/Resources" -name '*.dylib' -type f -print0)
    # 3) Main executable, then the app bundle (outermost last) with entitlements.
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_DIR/Contents/MacOS/FChat"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" \
        || { echo "error: codesign verification failed" >&2; exit 1; }
else
    echo "warning: signing identity '$SIGN_ID' not found; leaving app UNSIGNED." >&2
    echo "         The Keychain will re-prompt on every launch until the app is signed." >&2
    echo "         Set FCHAT_CODESIGN_IDENTITY to a valid identity, or '-' for ad-hoc." >&2
fi

# --- Notarization (opt-in) --------------------------------------------------
# Submit the signed app to Apple's notary service and staple the ticket, so
# other Macs run it without a Gatekeeper warning. Off by default (it needs the
# network + Apple credentials and takes a minute); enable with FCHAT_NOTARIZE=1.
#
# One-time credential setup (stores an App Store Connect API key in the login
# keychain under the profile name below):
#   xcrun notarytool store-credentials FChat \
#       --key /path/to/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
# (Or use --apple-id/--team-id/--password with an app-specific password.)
# Override the profile name with FCHAT_NOTARY_PROFILE.
if [[ "${FCHAT_NOTARIZE:-0}" == "1" ]]; then
    NOTARY_PROFILE="${FCHAT_NOTARY_PROFILE:-FChat}"
    ZIP="$ROOT/build/F-Chat.zip"
    echo "==> notarize (profile: $NOTARY_PROFILE)"
    # notarytool needs a zip (or dmg/pkg); ditto preserves the bundle + signature.
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    if xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "==> staple ticket"
        xcrun stapler staple "$APP_DIR" \
            || { echo "error: stapler failed" >&2; exit 1; }
        # Gatekeeper should now accept it for execution.
        spctl -a -vvv -t exec "$APP_DIR" 2>&1 | head -3 || true
        rm -f "$ZIP"
        echo "==> notarized + stapled"
    else
        echo "error: notarization failed. Inspect the log with:" >&2
        echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        echo "  (run 'xcrun notarytool history --keychain-profile $NOTARY_PROFILE' for the id)" >&2
        exit 1
    fi
fi

echo "==> built $APP_DIR"
echo "    open $APP_DIR    # to launch"
