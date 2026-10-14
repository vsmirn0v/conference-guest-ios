#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app="$root/.build/screen-sharing-geometry/WindowGeometryProbe.app"
mkdir -p "$app/Contents/MacOS"
xcrun --sdk macosx clang -fobjc-arc -fblocks -mmacosx-version-min=14.4 \
  -I "$root/RockNRoll" -framework AppKit -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
  "$root/Experiments/ScreenSharing/WindowGeometryProbe.m" "$root/RockNRoll/MacScreenCaptureBridge.m" \
  -o "$app/Contents/MacOS/WindowGeometryProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.vsmirn0v.windowgeometryprobe</string>
<key>CFBundleName</key><string>Window Geometry Probe</string>
<key>CFBundleExecutable</key><string>WindowGeometryProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
