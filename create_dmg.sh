#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$DIR/StateBeacon.app"
DMG_NAME="StateBeacon.dmg"
DMG_PATH="$DIR/$DMG_NAME"
TEMP_DMG="/tmp/statebeacon_rw_$$.dmg"
VOL_NAME="StateBeacon"
MOUNT_POINT="/Volumes/$VOL_NAME"

# 1. Ensure StateBeacon.app is freshly bundled
if [ ! -d "$APP_PATH" ]; then
    echo "StateBeacon.app not found. Running bundle.sh..."
    "$DIR/bundle.sh"
fi

# 2. Generate 540x360 pixel-perfect light gray background image
BG_IMAGE="$DIR/Resources/dmg_background.png"
echo "Generating pixel-perfect 540x360 light gray DMG background image..."
swift -e '
import AppKit
let width: CGFloat = 540
let height: CGFloat = 360
let size = NSSize(width: width, height: height)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// 1. Sleek light gray gradient (native macOS light aesthetic)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    NSColor(red: 0.965, green: 0.97, blue: 0.98, alpha: 1.0).cgColor,
    NSColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1.0).cgColor
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

// 2. Subtle border
ctx.setStrokeColor(NSColor(white: 0.0, alpha: 0.06).cgColor)
ctx.setLineWidth(1.0)
ctx.stroke(CGRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1))

// 3. Vibrant Apple-blue guidance arrow in center (between icons at y = 175)
let arrowPath = CGMutablePath()
let startX: CGFloat = 215
let endX: CGFloat = 325
let centerY: CGFloat = 175
let head: CGFloat = 12

arrowPath.move(to: CGPoint(x: startX, y: centerY))
arrowPath.addLine(to: CGPoint(x: endX, y: centerY))
arrowPath.move(to: CGPoint(x: endX - head, y: centerY + head * 0.75))
arrowPath.addLine(to: CGPoint(x: endX, y: centerY))
arrowPath.addLine(to: CGPoint(x: endX - head, y: centerY - head * 0.75))

ctx.addPath(arrowPath)
ctx.setStrokeColor(NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92).cgColor)
ctx.setLineWidth(4.0)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// 4. Header title
let title = "StateBeacon"
let titleFont = NSFont.systemFont(ofSize: 17, weight: .bold)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor(white: 0.16, alpha: 0.95)
]
let titleSize = (title as NSString).size(withAttributes: titleAttrs)
(title as NSString).draw(at: CGPoint(x: (width - titleSize.width) / 2, y: 308), withAttributes: titleAttrs)

// 5. Header subline: "Live Sensor Reporting for macOS"
let sub = "Live Sensor Reporting for macOS"
let subFont = NSFont.systemFont(ofSize: 11, weight: .medium)
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: subFont,
    .foregroundColor: NSColor(white: 0.42, alpha: 0.9)
]
let subSize = (sub as NSString).size(withAttributes: subAttrs)
(sub as NSString).draw(at: CGPoint(x: (width - subSize.width) / 2, y: 288), withAttributes: subAttrs)

// 6. Bottom instruction text
let text = "Drag to Applications to install"
let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
let textAttrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(white: 0.38, alpha: 0.95)
]
let textSize = (text as NSString).size(withAttributes: textAttrs)
(text as NSString).draw(at: CGPoint(x: (width - textSize.width) / 2, y: 46), withAttributes: textAttrs)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError() }
try! png.write(to: URL(fileURLWithPath: "'"$BG_IMAGE"'"))
'

# 3. Create a temporary read-write disk image
echo "Creating temporary read-write disk image..."
rm -f "$TEMP_DMG"
hdiutil create -megabytes 30 -volname "$VOL_NAME" -fs HFS+ "$TEMP_DMG"

# 4. Mount the temporary disk image
echo "Mounting disk image..."
# Detach if previously mounted
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
hdiutil attach "$TEMP_DMG" -noautoopen -mountpoint "$MOUNT_POINT"

# 5. Populate volume
echo "Copying files to $MOUNT_POINT..."
cp -R "$APP_PATH" "$MOUNT_POINT/StateBeacon.app"
ln -s /Applications "$MOUNT_POINT/Applications"

mkdir -p "$MOUNT_POINT/.background"
cp "$BG_IMAGE" "$MOUNT_POINT/.background/background.png"

# Volume icon
if [ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
    if command -v SetFile &> /dev/null; then
        SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
        SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
    fi
fi

# 6. Configure Finder layout via AppleScript
echo "Configuring Finder window layout (128px icons, bounds, background)..."
osascript << EOF || true
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 150, 840, 510}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "StateBeacon.app" of container window to {130, 180}
        set position of item "Applications" of container window to {410, 180}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# 7. Unmount the temporary volume
echo "Detaching temporary volume..."
sync
hdiutil detach "$MOUNT_POINT" -force || true
sleep 1

# 8. Convert to compressed read-only UDZO image
echo "Building final compressed DMG ($DMG_NAME)..."
rm -f "$DMG_PATH"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TEMP_DMG"

echo "Done! Sleek DMG installer ready at: $DMG_PATH"
ls -lh "$DMG_PATH"
