#!/bin/sh
# Builds MuZip.app (app/MuZip/build/MuZip.app): the Swift package's MuZip executable in an app bundle, with the icon and logo
# from Resources/ (made from docs/logo-*.svg), signed ad hoc so
# macOS can remember its permissions (Messages automation, Full Disk Access for SMS replies, Accessibility for WhatsApp).
#   app/MuZip/make_app.sh && open app/MuZip/build/MuZip.app
set -e
cd "$(dirname "$0")"
swift build -c release --product MuZip
APP=build/MuZip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MuZip "$APP/Contents/MacOS/MuZip"
cp Resources/MuZip.icns Resources/logo-light.png Resources/logo-dark.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MuZip</string>
  <key>CFBundleDisplayName</key><string>MuZip</string>
  <key>CFBundleIdentifier</key><string>app.muzip.mac</string>
  <key>CFBundleIconFile</key><string>MuZip</string>
  <key>CFBundleExecutable</key><string>MuZip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MuZip sends your question and close-ups as texts through Messages or WhatsApp.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "built $APP"
