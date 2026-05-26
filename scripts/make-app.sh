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
    <string>app.fyrby.fchat</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>F-Chat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>0.3.0</string>
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

echo "==> built $APP_DIR"
echo "    open $APP_DIR    # to launch"
