#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="4.0.0"
DMG_NAME="SSDEjector-v${VERSION}-macOS.dmg"
DIST_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${PROJECT_ROOT}/build"
DMG_STAGING="${BUILD_DIR}/dmg_staging"

# 1. Build app if needed
if [ ! -d "${BUILD_DIR}/SSDEjector.app" ]; then
    "${PROJECT_ROOT}/scripts/build.sh"
fi

echo "📦 Packaging DMG: ${DMG_NAME}..."

rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
mkdir -p "${DIST_DIR}"

# 2. Copy SSDEjector.app to staging
cp -R "${BUILD_DIR}/SSDEjector.app" "${DMG_STAGING}/"

# 3. Create Applications symlink for drag-and-drop installation
ln -s /Applications "${DMG_STAGING}/Applications"

# 4. Copy 1-click CLI installer into DMG
cp "${PROJECT_ROOT}/scripts/install.sh" "${DMG_STAGING}/Install.command"
chmod +x "${DMG_STAGING}/Install.command"

# 5. Create DMG disk image using hdiutil
rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create -volname "SSDEjector" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DIST_DIR}/${DMG_NAME}"

echo "✅ DMG Created at: ${DIST_DIR}/${DMG_NAME}"
