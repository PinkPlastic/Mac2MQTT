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
# StateBeacon v1.1.0

Native macOS menu bar agent that sends system telemetry, Focus mode state, and controls to Home Assistant via MQTT auto-discovery.

### Highlights
- **Full HASS.Agent Sensor Parity**: Expands from 25 to 41 native hardware, peripheral, session, and privacy entities, achieving feature parity with Windows HASS.Agent on macOS.
- **41 Sensors & Controls**:
  - **System & Activity**: Frontmost application, active window title, user active/idle status, idle seconds, CPU usage %, memory usage %, CPU clock speed (MHz), connected display counts, primary display ID, monitor power state, session lock state, last system state change, logged user, logged users list, last active timestamp, last boot timestamp, system accent color, and StateBeacon version.
  - **Peripherals & Hardware**: Live GPU core utilization percentage, macOS thermal pressure state (Nominal, Fair, Serious, Critical), Bluetooth Classic connected device count and device list attributes, and Bluetooth Low Energy (LE) device count and device list attributes.
  - **Audio & Video**: Audio input device name and streaming in-use state, audio output device name and playback status, master audio volume percentage, audio muted state, webcam in-use detection, and active webcam device name.
  - **Battery & Power**: Battery level percentage, charging status, battery state, and AC vs battery power source.
  - **Network & Presence**: Wi-Fi SSID, Wi-Fi BSSID, active network connection type, and GPS geolocation coordinates (latitude, longitude, altitude).
  - **Focus Mode**: Focus mode active state and named profile detection (Work, Personal, Do Not Disturb, etc.).
  - **Remote Controls**: Mute Audio switch, Lock Screen button, and Sleep Mac button.
- **Instant AX Window Observer**: Detects focused window title changes in real time (<50 ms) using native Accessibility (AX) observer hooks and NSWorkspace workspace activation events.
- **Performance & Footprint Optimization**: Reduced idle memory footprint to ~14.4MB RAM and <0.1% CPU via conditional polling, plist mtime caching, and static memoization.
- **Comprehensive Permissions Hub**: Dedicated Preferences UI with live status indicators and one-click authorization workflows for Accessibility (AX), Bluetooth, Location Services, and Full Disk Access.
- **Home Assistant Entity Pruning**: Unchecking sensors in Preferences automatically removes unused entities from the Home Assistant registry via empty retained discovery payloads.
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
