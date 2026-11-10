#!/bin/zsh
# Builds ByteMeter.app (universal: Apple Silicon + Intel).
#   ./build.sh           → build/ByteMeter.app
#   ./build.sh install   → also installs to /Applications and launches it
#   ./build.sh dmg       → also creates build/ByteMeter-<version>.dmg
set -e
cd "$(dirname "$0")"
VERSION=1.0
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/ByteMeter"
APP=build/ByteMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ByteMeter</string>
  <key>CFBundleDisplayName</key><string>ByteMeter</string>
  <key>CFBundleIdentifier</key><string>local.bytemeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ByteMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ "$1" == "install" ]]; then
  # Quit gracefully so the running copy saves its data first.
  osascript -e 'quit app id "local.bytemeter"' 2>/dev/null || true
  # One-time cleanup of the app's previous name (its data is migrated on first launch).
  if [[ -d /Applications/DataKullanim.app ]]; then
    osascript -e 'quit app id "local.datakullanim"' 2>/dev/null || true
    sleep 1; pkill -x DataKullanim || true
    rm -rf /Applications/DataKullanim.app
  fi
  sleep 1; pkill -x ByteMeter || true
  rm -rf /Applications/ByteMeter.app
  cp -R "$APP" /Applications/
  open /Applications/ByteMeter.app
  echo "Installed: /Applications/ByteMeter.app"
fi

if [[ "$1" == "dmg" ]]; then
  DMG="build/ByteMeter-$VERSION.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "ByteMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  shasum -a 256 "$DMG"
  echo "DMG: $DMG"
fi
