#!/bin/bash
# Bundle Wendigo as a proper macOS .app and install to /Applications
set -e

APP_NAME="Wendigo"
BUNDLE_DIR="/Applications/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build release
swift build -c release

# Create bundle structure
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy binary
cp ".build/release/$APP_NAME" "$MACOS/$APP_NAME"

# Copy icon if exists
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Copy NDI runtime library
NDI_LIB="/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"
if [ -f "$NDI_LIB" ]; then
  cp "$NDI_LIB" "$MACOS/libndi.dylib"
  install_name_tool -change "@rpath/libndi.dylib" "@executable_path/libndi.dylib" "$MACOS/$APP_NAME" 2>/dev/null || true
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Wendigo</string>
    <key>CFBundleDisplayName</key>
    <string>Wendigo</string>
    <key>CFBundleIdentifier</key>
    <string>com.jonasjohansson.wendigo</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>Wendigo</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Wendigo can capture from camera sources</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Wendigo discovers NDI sources on the local network</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ndi._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "Installed $APP_NAME.app to /Applications"
echo "Run with: open /Applications/$APP_NAME.app"
