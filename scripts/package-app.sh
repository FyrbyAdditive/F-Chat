#!/usr/bin/env bash
# Package the already-built F-Chat.app into distributable .zip and .dmg.
#
# Run AFTER scripts/make-app.sh (ideally FCHAT_NOTARIZE=1 so the app is
# notarized + stapled). This stage is deliberately separate so packaging can be
# re-run without rebuilding. Both artifacts preserve the app's code signature
# and stapled notarization ticket (ditto and hdiutil keep xattrs/resource forks).
#
# Output (under build/, which is gitignored):
#   build/F-Chat-<version>.zip
#   build/F-Chat-<version>.dmg
#
# Options:
#   --sign-dmg   codesign the .dmg with the Developer ID identity
#   --notarize   submit the .dmg to the notary service + staple it
#                (implies --sign-dmg; needs the FChat keychain profile,
#                 or set FCHAT_NOTARY_PROFILE)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_DIR="$ROOT/build/F-Chat.app"
SIGN_DMG=false
NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        --sign-dmg) SIGN_DMG=true ;;
        --notarize) SIGN_DMG=true; NOTARIZE=true ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- Preconditions ----------------------------------------------------------
if [[ ! -d "$APP_DIR" ]]; then
    echo "error: $APP_DIR not found — run ./scripts/make-app.sh first." >&2
    exit 1
fi
if ! codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
    echo "warning: $APP_DIR is not validly signed; packaging anyway." >&2
fi
if xcrun stapler validate "$APP_DIR" >/dev/null 2>&1; then
    echo "==> app is notarized + stapled"
else
    echo "warning: app is NOT stapled — distributable, but recipients may see a" >&2
    echo "         Gatekeeper prompt. Rebuild with FCHAT_NOTARIZE=1 to staple." >&2
fi

# Version drives the artifact filenames.
VERSION="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$ROOT/Sources/FChatCore/FChatCore.swift" | head -1 | tr -d '"')"
VERSION="${VERSION:-0.0.0}"
ZIP_OUT="$ROOT/build/F-Chat-$VERSION.zip"
DMG_OUT="$ROOT/build/F-Chat-$VERSION.dmg"
SIGN_ID="${FCHAT_CODESIGN_IDENTITY:-Developer ID Application: Timothy Ellis (QS865LKS7W)}"

# --- ZIP --------------------------------------------------------------------
# ditto --keepParent preserves the .app wrapper, signature, and staple.
echo "==> zip  -> $(basename "$ZIP_OUT")"
rm -f "$ZIP_OUT"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_OUT"

# --- DMG --------------------------------------------------------------------
# Build a small read-only compressed disk image with the app + an /Applications
# symlink so the user can drag-to-install. Stage in a temp dir so only the app
# and the symlink land in the image.
echo "==> dmg  -> $(basename "$DMG_OUT")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP_DIR" "$STAGE/F-Chat.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create \
    -volname "F-Chat $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_OUT" >/dev/null

# --- Optional: sign + notarize the .dmg -------------------------------------
if $SIGN_DMG; then
    if security find-identity -v -p codesigning | grep -q "${SIGN_ID%% (*}"; then
        echo "==> codesign dmg ($SIGN_ID)"
        codesign --force --timestamp --sign "$SIGN_ID" "$DMG_OUT"
    else
        echo "warning: signing identity '$SIGN_ID' not found; dmg left unsigned." >&2
    fi
fi

if $NOTARIZE; then
    PROFILE="${FCHAT_NOTARY_PROFILE:-FChat}"
    echo "==> notarize dmg (profile: $PROFILE)"
    if xcrun notarytool submit "$DMG_OUT" --keychain-profile "$PROFILE" --wait; then
        xcrun stapler staple "$DMG_OUT" \
            || { echo "error: stapling the dmg failed" >&2; exit 1; }
        spctl -a -vvv -t open --context context:primary-signature "$DMG_OUT" 2>&1 | head -3 || true
        echo "==> dmg notarized + stapled"
    else
        echo "error: dmg notarization failed; see notarytool log." >&2
        exit 1
    fi
fi

echo
echo "==> packaged:"
ls -lh "$ZIP_OUT" "$DMG_OUT" | awk '{print "    " $5 "  " $NF}'
