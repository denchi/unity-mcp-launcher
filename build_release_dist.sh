#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-v0.1.4}"
PKG="UnityMCPLauncher-${VERSION}-macos"

cd "${ROOT_DIR}"

rm -rf dist
swift build -c release

mkdir -p "dist/${PKG}"
cp ".build/release/UnityMCPHubApp" "dist/${PKG}/"
rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" hub_service/ "dist/${PKG}/hub_service/"
rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" hub_mcp_gateway/ "dist/${PKG}/hub_mcp_gateway/"
cp README.md "dist/${PKG}/"

(
  cd dist
  zip -r "${PKG}.zip" "${PKG}"
)

echo "Created: ${ROOT_DIR}/dist/${PKG}.zip"
