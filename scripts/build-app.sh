#!/bin/zsh
# Builds Bardic, assembles "Bardic.app", signs it, and installs it to ~/Applications.
#
# Usage: scripts/build-app.sh [--no-install] [--open] [--dmg] [--notarize]
#
#   --dmg        also package build/Bardic-<version>.dmg for sharing
#   --notarize   submit the DMG to Apple and staple the ticket (implies --dmg). Needs a
#                "Developer ID Application" certificate and a notarytool keychain profile:
#                  xcrun notarytool store-credentials bardic-notary --apple-id … --team-id …
#
# Environment overrides: SIGN_IDENTITY, BUNDLE_ID, VERSION (default: the VERSION file), NOTARY_PROFILE.
#
# xcodebuild (not `swift build`) is required so MLX's Metal shaders get compiled into
# mlx-swift_Cmlx.bundle/default.metallib.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_NAME="Bardic"
BUNDLE_ID="${BUNDLE_ID:-com.jesseboyes.bardic}"
VERSION="${VERSION:-$(<"$ROOT/VERSION")}"
NOTARY_PROFILE="${NOTARY_PROFILE:-bardic-notary}"
ENTITLEMENTS="$ROOT/scripts/Bardic.entitlements"
INSTALL_DIR="$HOME/Applications"
DERIVED="$ROOT/build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/${APP_NAME// /-}-$VERSION.dmg"

INSTALL=1; OPEN=0; MAKE_DMG=0; NOTARIZE=0
for arg in "$@"; do
  case $arg in
    --no-install) INSTALL=0 ;;
    --open) OPEN=1 ;;
    --dmg) MAKE_DMG=1 ;;
    --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

echo "▸ Building (Release)…"
xcodebuild -scheme Bardic -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -x "$PRODUCTS/Bardic" ]] || { echo "Build failed"; exit 1; }

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Bardic" "$APP/Contents/MacOS/Bardic"
for b in "$PRODUCTS"/*.bundle(N); do
  cp -R "$b" "$APP/Contents/Resources/"
done
[[ -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" || -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ]] \
  || echo "⚠️  default.metallib not found in mlx-swift_Cmlx.bundle — the LLM will fail to run"
cp "$ROOT/scripts/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The app ships compiled copies of its Swift packages; their licenses require these notices to go with it.
ACK="$APP/Contents/Resources/Acknowledgements.txt"
{
  echo "Bardic $VERSION"
  echo
  cat "$ROOT/LICENSE"
  echo
  echo "Cleanup model: Qwen 2.5 (Alibaba Cloud) is downloaded by the app from Hugging Face, not bundled."
  echo "Qwen is licensed under the Qwen RESEARCH LICENSE AGREEMENT, Copyright (c) Alibaba Cloud. All Rights"
  echo "Reserved. That license is non-commercial, so Bardic is free."
  echo
  echo "This app includes the following open-source packages."
  for pkg in "$DERIVED"/SourcePackages/checkouts/*(/N); do
    for f in "$pkg"/(LICENSE|NOTICE|NOTICES|COPYING)*(.N); do
      echo
      echo "================================================================================"
      echo "${pkg:t}: ${f:t}"
      echo "================================================================================"
      cat "$f"
    done
  done
} > "$ACK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Bardic</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Bardic listens while you hold the dictation key and turns your speech into text. Audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

echo "▸ Signing…"
# Prefer Developer ID (runs on other Macs once notarized), then Apple Development (this Mac only).
find_identity() { security find-identity -p codesigning -v | awk -F'"' -v kind="$1" '$0 ~ kind {print $2; exit}' }
IDENTITY="${SIGN_IDENTITY:-$(find_identity "Developer ID Application")}"
IDENTITY="${IDENTITY:-$(find_identity "Apple Development")}"
if [[ -z "$IDENTITY" ]]; then
  echo "⚠️  No signing identity found; ad-hoc signing (permissions will reset on every rebuild)."
  IDENTITY="-"
fi
echo "  identity: $IDENTITY"
SIGN_ARGS=(--force --deep --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")
# Notarization requires a secure timestamp; skip it otherwise so offline builds still work.
[[ "$IDENTITY" == "Developer ID Application"* ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if (( NOTARIZE )) && [[ "$IDENTITY" != "Developer ID Application"* ]]; then
  echo "✗ --notarize needs a \"Developer ID Application\" certificate (Apple Developer Program)."
  exit 1
fi

if (( MAKE_DMG )); then
  echo "▸ Packaging $(basename "$DMG")…"
  STAGE="$ROOT/build/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$ROOT/scripts/dmg/Read Me First.txt" "$STAGE/"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
  rm -rf "$STAGE"
  if [[ "$IDENTITY" != "-" ]]; then
    DMG_ARGS=(--force --sign "$IDENTITY")
    [[ "$IDENTITY" == "Developer ID Application"* ]] && DMG_ARGS+=(--timestamp)
    codesign "${DMG_ARGS[@]}" "$DMG"
  fi

  if (( NOTARIZE )); then
    echo "▸ Notarizing (usually a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
  fi
  echo "✓ $DMG"
fi

if (( INSTALL )); then
  echo "▸ Installing to $INSTALL_DIR…"
  mkdir -p "$INSTALL_DIR"
  pkill -x Bardic 2>/dev/null && sleep 0.5 || true
  # Replace the build from before the rename, so two copies don't both listen for the hotkey.
  if [[ -d "$INSTALL_DIR/Whiskr Flow.app" ]]; then
    echo "  removing the old Whiskr Flow.app"
    pkill -x WhiskrFlow 2>/dev/null && sleep 0.5 || true
    rm -rf "$INSTALL_DIR/Whiskr Flow.app"
  fi
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  APP="$INSTALL_DIR/$APP_NAME.app"
fi

echo "✓ $APP"
(( OPEN )) && open "$APP"
exit 0
