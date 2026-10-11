#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$DIR/Mac2MQTT.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building release binary..."
swift build -c release

echo "Packaging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$DIR/.build/release/Mac2MQTT" "$MACOS_DIR/Mac2MQTT"
chmod +x "$MACOS_DIR/Mac2MQTT"

if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Mac2MQTT</string>
    <key>CFBundleIdentifier</key>
    <string>com.rufus.Mac2MQTT</string>
    <key>CFBundleName</key>
    <string>Mac2MQTT</string>
    <key>CFBundleDisplayName</key>
    <string>Mac2MQTT</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Mac2MQTT monitors active camera state for Home Assistant automations.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mac2MQTT monitors active microphone state for Home Assistant automations.</string>
    <key>NSFocusStatusUsageDescription</key>
    <string>Mac2MQTT syncs your Mac's Focus mode state with Home Assistant.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Mac2MQTT reads Wi-Fi SSID and BSSID for Home Assistant network presence.</string>
    <key>NSLocationUsageDescription</key>
    <string>Mac2MQTT reads Wi-Fi SSID and BSSID for Home Assistant network presence.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Signing application bundle with ad-hoc signature..."
codesign --force --deep --sign - "$APP_DIR"

INSTALL_DIR="/Applications/Mac2MQTT.app"
echo "Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

echo "Registering with LaunchServices and Spotlight..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR" || true
mdimport "$INSTALL_DIR" || true
touch "$INSTALL_DIR"

echo "Done! Application installed and registered at: $INSTALL_DIR"
