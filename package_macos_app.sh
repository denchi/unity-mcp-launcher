#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-v0.1.4}"
APP_NAME="Unity MCP Launcher"
APP_BUNDLE="${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_BUNDLE}"
STAGE_DIR="${DIST_DIR}/dmg_stage"
DMG_PATH="${DIST_DIR}/UnityMCPLauncher-${VERSION}.dmg"

cd "${ROOT_DIR}"

rm -rf "${DIST_DIR}"
swift build -c release

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp ".build/release/UnityMCPHubApp" "${APP_DIR}/Contents/MacOS/UnityMCPHubApp"
chmod +x "${APP_DIR}/Contents/MacOS/UnityMCPHubApp"

rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "hub_service/" "${APP_DIR}/Contents/Resources/hub_service/"
rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "hub_mcp_gateway/" "${APP_DIR}/Contents/Resources/hub_mcp_gateway/"
cp "README.md" "${APP_DIR}/Contents/Resources/README.md"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>UnityMCPHubApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.denchi.unity-mcp-launcher</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_DIR}"

mkdir -p "${STAGE_DIR}"
cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_BUNDLE}"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGE_DIR}"

echo "Created app bundle: ${APP_DIR}"
echo "Created DMG: ${DMG_PATH}"
