#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$DIR/Mac2MQTT.app"
DMG_NAME="Mac2MQTT.dmg"
DMG_PATH="$DIR/$DMG_NAME"
VOL_NAME="Mac2MQTT"

# Ensure Mac2MQTT.app exists, or build it first
if [ ! -d "$APP_PATH" ]; then
    echo "Mac2MQTT.app not found. Running bundle.sh first..."
    "$DIR/bundle.sh"
fi

STAGING_DIR="/tmp/mac2mqtt_dmg_staging_$$"
echo "Preparing staging directory at $STAGING_DIR..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "Copying Mac2MQTT.app..."
cp -R "$APP_PATH" "$STAGING_DIR/Mac2MQTT.app"

echo "Creating Applications folder symlink..."
ln -s /Applications "$STAGING_DIR/Applications"

# Set volume icon if available
if [ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
    if command -v SetFile &> /dev/null; then
        SetFile -c icnC "$STAGING_DIR/.VolumeIcon.icns" 2>/dev/null || true
        SetFile -a C "$STAGING_DIR" 2>/dev/null || true
    fi
fi

echo "Building compressed DMG ($DMG_NAME)..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "DMG created successfully: $DMG_PATH"
ls -lh "$DMG_PATH"
