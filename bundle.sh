#!/bin/bash
# Bundle Indigo3 as a proper macOS .app
set -e

APP_NAME="Indigo3"
BUILD_DIR=".build/arm64-apple-macosx/debug"
BUNDLE_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build first
swift build

# Create bundle structure
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"

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
    <string>Indigo3</string>
    <key>CFBundleDisplayName</key>
    <string>Indigo3</string>
    <key>CFBundleIdentifier</key>
    <string>com.jonasjohansson.indigo3</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>Indigo3</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Indigo3 can capture from camera sources</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Indigo3 discovers NDI sources on the local network</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ndi._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "✓ Bundled: $BUNDLE_DIR"
echo "  Run with: open $BUNDLE_DIR"
