#!/bin/zsh
# Builds Whiskr Flow, assembles "Whiskr Flow.app", signs it, and installs it to ~/Applications.
#
# Usage: scripts/build-app.sh [--no-install] [--open]
#
# xcodebuild (not `swift build`) is required so MLX's Metal shaders get compiled into
# mlx-swift_Cmlx.bundle/default.metallib.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME="Whiskr Flow"
BUNDLE_ID="com.jesseboyes.whiskrflow"
VERSION="0.1.0"
INSTALL_DIR="$HOME/Applications"
DERIVED="$ROOT/build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$ROOT/build/$APP_NAME.app"

INSTALL=1; OPEN=0
for arg in "$@"; do
  case $arg in
    --no-install) INSTALL=0 ;;
    --open) OPEN=1 ;;
  esac
done

echo "▸ Building (Release)…"
xcodebuild -scheme WhiskrFlow -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -x "$PRODUCTS/WhiskrFlow" ]] || { echo "Build failed"; exit 1; }

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/WhiskrFlow" "$APP/Contents/MacOS/WhiskrFlow"
for b in "$PRODUCTS"/*.bundle(N); do
  cp -R "$b" "$APP/Contents/Resources/"
done
[[ -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" || -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ]] \
  || echo "⚠️  default.metallib not found in mlx-swift_Cmlx.bundle — the LLM will fail to run"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>WhiskrFlow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Whiskr Flow listens while you hold the dictation key and turns your speech into text. Audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

echo "▸ Signing…"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "⚠️  No Apple Development identity found; ad-hoc signing (permissions will reset on every rebuild)."
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

if (( INSTALL )); then
  echo "▸ Installing to $INSTALL_DIR…"
  mkdir -p "$INSTALL_DIR"
  pkill -x WhiskrFlow 2>/dev/null && sleep 0.5 || true
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  APP="$INSTALL_DIR/$APP_NAME.app"
fi

echo "✓ $APP"
(( OPEN )) && open "$APP"
exit 0
