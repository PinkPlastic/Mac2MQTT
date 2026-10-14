#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.1.0"
DIST_DIR="$DIR/dist"

echo "=== Packaging StateBeacon v$VERSION ==="
mkdir -p "$DIST_DIR"

# 1. Build Application Bundle
echo "1. Building StateBeacon.app..."
"$DIR/bundle.sh"

# 2. Build DMG
echo "2. Building StateBeacon.dmg..."
"$DIR/create_dmg.sh"

# 3. Copy DMG to dist
cp "$DIR/StateBeacon.dmg" "$DIST_DIR/StateBeacon-v$VERSION.dmg"
cp "$DIR/StateBeacon.dmg" "$DIST_DIR/StateBeacon.dmg"

# 4. Create ZIP archive
echo "3. Creating StateBeacon-v$VERSION.zip..."
cd "$DIR"
rm -f "$DIST_DIR/StateBeacon-v$VERSION.zip"
ditto -c -k --keepParent "$DIR/StateBeacon.app" "$DIST_DIR/StateBeacon-v$VERSION.zip"

# 5. Generate SHA256 Checksums
echo "4. Generating SHA256 Checksums..."
cd "$DIST_DIR"
shasum -a 256 "StateBeacon-v$VERSION.dmg" "StateBeacon.dmg" "StateBeacon-v$VERSION.zip" > "$DIST_DIR/SHA256SUMS.txt"

# 6. Generate Release Notes
cat << 'EOF' > "$DIST_DIR/RELEASE_NOTES.md"
# StateBeacon v1.0.0 (Initial Release)

Native macOS menu bar agent that sends hardware sensors, Focus mode status, and controls to Home Assistant via MQTT auto-discovery.

### Highlights
- **Native Swift & AppKit**: Sub-15MB idle footprint, <0.2% CPU load.
- **Home Assistant MQTT Discovery**: Auto-registers 25 sensors and remote controls with zero YAML configuration required.
- **25 Sensors & Controls**:
  - **System & Activity**: Frontmost application, user active/idle status, CPU usage %, Memory usage %, connected display counts, and primary display ID.
  - **Audio & Video**: Microphone in-use detection, active input device name, audio playback detection, active audio output name, webcam in-use detection, active webcam device name.
  - **Battery & Power**: Battery level percentage, charging status, battery state, AC vs battery power source.
  - **Network Presence**: Wi-Fi SSID, Wi-Fi BSSID, active network interface type.
  - **Focus Mode**: Focus mode active state and named profile detection (Work, Personal, Do Not Disturb, etc.).
  - **Remote Controls**: Mute Audio switch, Lock Screen button, Sleep Mac button.
- **Granular Sensor Control**: Enable or disable any of the 25 sensors individually.
- **Permission-Aware**: Focus mode (Full Disk Access) and Wi-Fi SSID (Location Services) are gracefully gated until authorized, auto-activating seamlessly upon permission approval.
- **Drag-and-Drop DMG**: Packaged in a visual DMG installer with direct `/Applications` shortcut.

### Installation
1. Download **`StateBeacon.dmg`** below.
2. Open the disk image and drag **StateBeacon** into **Applications**.
3. Launch StateBeacon from Applications or Spotlight.
4. Click the antenna menu bar icon to configure your MQTT broker connection and sensors.

### Checksums (SHA-256)
```text
EOF

cat "$DIST_DIR/SHA256SUMS.txt" >> "$DIST_DIR/RELEASE_NOTES.md"

cat << 'EOF' >> "$DIST_DIR/RELEASE_NOTES.md"
```
EOF

echo "=== Packaging Complete ==="
ls -lh "$DIST_DIR"
