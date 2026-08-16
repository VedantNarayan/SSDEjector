#!/bin/bash
set -e

CURRENT_USER="$(whoami)"
USER_UID="$(id -u)"
USER_HOME="$HOME"

echo "Uninstalling SSDEjector..."
launchctl bootout gui/${USER_UID} "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist" 2>/dev/null || true
launchctl unload "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist" 2>/dev/null || true
rm -f "${USER_HOME}/Library/LaunchAgents/com.${CURRENT_USER}.f4ejector.plist"

killall -9 SSDEjector 2>/dev/null || true
hidutil property --set '{"UserKeyMapping":[]}' 2>/dev/null || true

rm -rf "${USER_HOME}/Applications/SSDEjector.app"
rm -f "${USER_HOME}/bin/ssd_ejector.sh"
rm -f "${USER_HOME}/bin/start_f4_ejector.sh"
rm -f "${USER_HOME}/bin/play_speaker_chime"
rm -f "${USER_HOME}/.local/bin/eject-ssd"
rm -f "${USER_HOME}/Library/Logs/f4_ejector.*"
rm -f "${USER_HOME}/Library/Logs/ssdejector.log"

echo "✅ SSDEjector uninstalled cleanly."
