#!/bin/bash
# Packages ExeStart.app (SwiftUI) and the `exestart` CLI into dist/.
#   ./scripts/build-app.sh            # release build
#   ./scripts/build-app.sh --install  # also copy the app to ~/Applications and the CLI to ~/.local/bin
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
DIST="dist"
APP="$DIST/ExeStart.app"

swift build -c release --product ExeStartApp
swift build -c release --product exestart
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ExeStartApp" "$APP/Contents/MacOS/ExeStart"
cp "$BIN/exestart" "$APP/Contents/Resources/exestart"
cp "$BIN/exestart" "$DIST/exestart"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ExeStart</string>
  <key>CFBundleDisplayName</key><string>ExeStart</string>
  <key>CFBundleIdentifier</key><string>app.exestart.ExeStart</string>
  <key>CFBundleExecutable</key><string>ExeStart</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Program</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>exe</string><string>msi</string><string>bat</string><string>lnk</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it run on this Mac.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✔ $APP"
echo "✔ $DIST/exestart"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$HOME/Applications/ExeStart.app"
  cp -R "$APP" "$HOME/Applications/"
  cp "$DIST/exestart" "$HOME/.local/bin/exestart"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$HOME/Applications/ExeStart.app" || true
  echo "✔ Installed ~/Applications/ExeStart.app and ~/.local/bin/exestart"
  [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "  Add to your PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
