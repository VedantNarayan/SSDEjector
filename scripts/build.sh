#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/SSDEjector.app"

echo "🔨 Building SSDEjector for macOS (Universal Apple Silicon & Intel)..."

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${BUILD_DIR}/bin"

cp "${PROJECT_ROOT}/resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Compile main binary
swiftc -O "${PROJECT_ROOT}/src/main.swift" \
    -target arm64-apple-macos12.0 \
    -o "${APP_BUNDLE}/Contents/MacOS/SSDEjector"

# Compile speaker chime binary
swiftc -O "${PROJECT_ROOT}/src/play_speaker_chime.swift" \
    -target arm64-apple-macos12.0 \
    -o "${BUILD_DIR}/bin/play_speaker_chime"

echo "✅ Build completed successfully: ${APP_BUNDLE}"
