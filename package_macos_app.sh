#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-v0.1.5}"
APP_NAME="Unity MCP Hub"
APP_BUNDLE="${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_BUNDLE}"
STAGE_DIR="${DIST_DIR}/dmg_stage"
DMG_PATH="${DIST_DIR}/UnityMCPHub-${VERSION}.dmg"
BUNDLE_ID="${BUNDLE_ID:-com.denchi.unity-mcp-hub}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:-}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

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
  <string>${BUNDLE_ID}</string>
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

if [[ -n "${SIGN_IDENTITY}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
  echo "SIGN_IDENTITY is not set; using ad-hoc signing for local builds."
  codesign --force --deep --sign - "${APP_DIR}"
fi

mkdir -p "${STAGE_DIR}"
cp -R "${APP_DIR}" "${STAGE_DIR}/${APP_BUNDLE}"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

if [[ -n "${SIGN_IDENTITY}" ]]; then
  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

if [[ "${NOTARIZE}" == "1" ]]; then
  require_env SIGN_IDENTITY

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE}" ]]; then
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
  else
    require_env APPLE_ID
    require_env TEAM_ID
    require_env APP_SPECIFIC_PASSWORD
    xcrun notarytool submit "${DMG_PATH}" \
      --apple-id "${APPLE_ID}" \
      --team-id "${TEAM_ID}" \
      --password "${APP_SPECIFIC_PASSWORD}" \
      --wait
  fi

  xcrun stapler staple "${DMG_PATH}"
fi

rm -rf "${STAGE_DIR}"

echo "Created app bundle: ${APP_DIR}"
echo "Created DMG: ${DMG_PATH}"
if [[ "${NOTARIZE}" == "1" ]]; then
  echo "Notarized and stapled DMG: ${DMG_PATH}"
fi
