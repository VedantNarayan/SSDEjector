#!/bin/bash
set -e
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${PROJECT_DIR}/dist/SSDEjector.app"

echo "🔨 Compiling SSDEjector..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

swiftc -O "${PROJECT_DIR}/src/main.swift" -o "${APP_BUNDLE}/Contents/MacOS/SSDEjector"
swiftc -O "${PROJECT_DIR}/src/play_speaker_chime.swift" -o "${PROJECT_DIR}/bin/play_speaker_chime"

cp "${PROJECT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "${PROJECT_DIR}/assets/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "✅ Build Complete: ${APP_BUNDLE}"
