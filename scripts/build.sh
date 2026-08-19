#!/bin/bash
set -e
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${PROJECT_DIR}/build/SSDEjector.app"

echo "🔨 Compiling SSDEjector 9.0.0..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${PROJECT_DIR}/bin"
mkdir -p "${PROJECT_DIR}/dist"

swiftc -O "${PROJECT_DIR}/src/main.swift" -o "${APP_BUNDLE}/Contents/MacOS/SSDEjector"
swiftc -O "${PROJECT_DIR}/src/play_speaker_chime.swift" -o "${PROJECT_DIR}/bin/play_speaker_chime"

cp "${PROJECT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

if [ -d "${PROJECT_DIR}/assets" ]; then
    cp -f "${PROJECT_DIR}/assets/"*.icns "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
    cp -f "${PROJECT_DIR}/assets/"*.png "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
fi

# Mirror to dist/
rm -rf "${PROJECT_DIR}/dist/SSDEjector.app"
cp -R "${APP_BUNDLE}" "${PROJECT_DIR}/dist/"

echo "✅ Build Complete: ${APP_BUNDLE}"
