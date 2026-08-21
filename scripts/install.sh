#!/bin/bash
# ==============================================================================
# SSDEjector 1-Click Installer for macOS (Apple Silicon & Intel)
# ==============================================================================

set -e

SSD_NAME="${1:-Mac_EXT}"
SSD_MOUNT_PATH="/Volumes/${SSD_NAME}"
USER_HOME="$HOME"
CURRENT_USER="$(whoami)"
USER_UID="$(id -u)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "======================================================="
echo "   ⚡ Installing SSDEjector 9.1.0 for volume: ${SSD_NAME}"
echo "   Target user: ${CURRENT_USER} (UID: ${USER_UID})"
echo "======================================================="

mkdir -p "${USER_HOME}/bin"
mkdir -p "${USER_HOME}/.local/bin"
mkdir -p "${USER_HOME}/Applications/SSDEjector.app/Contents/MacOS"
mkdir -p "${USER_HOME}/Applications/SSDEjector.app/Contents/Resources"
mkdir -p "${USER_HOME}/Library/LaunchAgents"
mkdir -p "${USER_HOME}/Library/Logs"

# Build or copy bundle
if [ -f "${ROOT_DIR}/src/main.swift" ]; then
    swiftc -O "${ROOT_DIR}/src/main.swift" -o "${USER_HOME}/Applications/SSDEjector.app/Contents/MacOS/SSDEjector"
    swiftc -O "${ROOT_DIR}/src/play_speaker_chime.swift" -o "${USER_HOME}/bin/play_speaker_chime"
elif [ -f "${SCRIPT_DIR}/../build/SSDEjector.app/Contents/MacOS/SSDEjector" ]; then
    cp -R "${SCRIPT_DIR}/../build/SSDEjector.app" "${USER_HOME}/Applications/"
fi

# Copy resources
if [ -d "${ROOT_DIR}/assets" ]; then
    cp -f "${ROOT_DIR}/assets/"*.icns "${USER_HOME}/Applications/SSDEjector.app/Contents/Resources/" 2>/dev/null || true
    cp -f "${ROOT_DIR}/assets/"*.png "${USER_HOME}/Applications/SSDEjector.app/Contents/Resources/" 2>/dev/null || true
fi

# Info.plist
cat << PLIST_EOF > "${USER_HOME}/Applications/SSDEjector.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SSDEjector</string>
    <key>CFBundleIdentifier</key>
    <string>com.${CURRENT_USER}.ssdejector</string>
    <key>CFBundleName</key>
    <string>SSDEjector</string>
    <key>CFBundleDisplayName</key>
    <string>SSDEjector</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>9.1.0</string>
    <key>CFBundleVersion</key>
    <string>9.1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

# Physical key mapping wrapper
cat << WRAPPER_EOF > "${USER_HOME}/bin/start_f4_ejector.sh"
#!/bin/bash
hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x0C00000221,"HIDKeyboardModifierMappingDst":0x070000003D}]}' 2>/dev/null
export SSD_NAME="${SSD_NAME}"
exec "${USER_HOME}/Applications/SSDEjector.app/Contents/MacOS/SSDEjector"
WRAPPER_EOF
chmod +x "${USER_HOME}/bin/start_f4_ejector.sh"

# CLI eject helper
cat << EJECT_CLI_EOF > "${USER_HOME}/bin/ssd_ejector.sh"
#!/bin/bash
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\$PATH"
SSD_MOUNT="${SSD_MOUNT_PATH}"

play_full_volume_chime() {
    if [ -x "${USER_HOME}/bin/play_speaker_chime" ]; then
        "${USER_HOME}/bin/play_speaker_chime" &
    else
        afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
    fi
}

if [ ! -d "\$SSD_MOUNT" ]; then
    osascript -e 'display notification "External SSD (${SSD_NAME}) is not mounted." with title "SSD Ejector"' 2>/dev/null &
    exit 0
fi

diskutil eject "\$SSD_MOUNT" 2>/dev/null || diskutil unmount force "\$SSD_MOUNT" 2>/dev/null

if [ ! -d "\$SSD_MOUNT" ]; then
    osascript -e 'display notification "External SSD (${SSD_NAME}) safely ejected." with title "SSD Ejected" subtitle "Safe to disconnect."' 2>/dev/null &
    play_full_volume_chime
fi
EJECT_CLI_EOF
chmod +x "${USER_HOME}/bin/ssd_ejector.sh"
ln -sf "${USER_HOME}/bin/ssd_ejector.sh" "${USER_HOME}/.local/bin/eject-ssd"

# LaunchAgent Plist
cat << PLIST_AGENT_EOF > "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.${CURRENT_USER}.f4ejector</string>
    <key>ProgramArguments</key>
    <array>
        <string>${USER_HOME}/bin/start_f4_ejector.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${USER_HOME}/Library/Logs/f4_ejector.log</string>
    <key>StandardErrorPath</key>
    <string>${USER_HOME}/Library/Logs/f4_ejector.err</string>
</dict>
</plist>
PLIST_AGENT_EOF

# Register and launch
echo "Registering LaunchAgent..."
killall -9 SSDEjector 2>/dev/null || true
launchctl bootout gui/${USER_UID} "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist" 2>/dev/null || true
launchctl bootstrap gui/${USER_UID} "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist" 2>/dev/null || launchctl load "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist"

echo ""
echo "======================================================="
echo "   ✅ SSDEjector 9.1.0 Installed and Running Successfully!"
echo "   - Double-tap F4 to eject anytime."
echo "   - Real-time streaming sync HUD & active data protection active."
echo "   - Chime is always routed to built-in MacBook speakers at 100%."
echo "   - Battery sleep saver & auto-remount active."
echo "======================================================="
