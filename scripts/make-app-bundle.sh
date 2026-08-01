#!/bin/bash
# make-app-bundle.sh
# Builds DeployHawk in release mode and packages it into a proper .app bundle
# so UNUserNotificationCenter (native notifications) and SMAppService work.
#
# Usage: ./scripts/make-app-bundle.sh [output-dir]
#   output-dir defaults to ./dist

set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
APP="$OUT_DIR/DeployHawk.app"

echo "▸ Building release binary..."
swift build -c release

echo "▸ Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/DeployHawk "$APP/Contents/MacOS/DeployHawk"
if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp assets/menubar-rocket.png "$APP/Contents/Resources/menubar-rocket.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DeployHawk</string>
    <key>CFBundleIdentifier</key>
    <string>com.deployhawk.app</string>
    <key>CFBundleName</key>
    <string>DeployHawk</string>
    <key>CFBundleDisplayName</key>
    <string>DeployHawk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS treats the bundle as a stable identity
# (required for notification permission to persist across rebuilds)
codesign --force --deep --sign - "$APP"

# Install to /Applications: Notification Center resolves icons through the
# LaunchServices registration, so the app needs a stable path.
INSTALL_APP="/Applications/DeployHawk.app"
rm -rf "$INSTALL_APP"
ditto "$APP" "$INSTALL_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP"

echo "✅ Done: $INSTALL_APP (build artifact: $APP)"
echo "   Launch with: open $INSTALL_APP"
