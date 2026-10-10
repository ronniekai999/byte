#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

APP_NAME="Byte"
BUNDLE_ID="com.ronnie.byte"
BIN="Byte"
APP_DIR="${APP_NAME}.app"
ICONSET="Byte.iconset"

echo "> Building release binary..."
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

echo "> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${BIN}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

ICON_KEY=""
if command -v iconutil >/dev/null 2>&1 && [ -d "${ICONSET}" ]; then
  echo "> Building app icon..."
  iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/${APP_NAME}.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>${APP_NAME}</string>"
  echo "  icon installed"
else
  echo "> Skipping icon (iconutil or ${ICONSET} not found)"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
${ICON_KEY}
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo ""
echo "[OK] Built ${APP_DIR}"
echo "   Next:"
echo "   1. mv \"${APP_DIR}\" /Applications/"
echo "   2. Launch Byte, click the gear, toggle 'Launch at login'"
echo "      (or add it manually: System Settings -> General -> Login Items)"
echo "   (Unsigned, so on first launch: right-click Byte -> Open, or run"
echo "    'xattr -dr com.apple.quarantine /Applications/${APP_DIR}')"
echo ""
echo "   If the icon doesn't refresh in Finder/Dock, run:"
echo "   touch \"/Applications/${APP_DIR}\" && killall Finder Dock"
