import Cocoa
import Carbon
import CoreAudio
import AudioToolbox
import Foundation

// ==============================================================================
// SSDEjector - Native macOS SSD Management & Instant Ejector
// Includes Auto-Spillover Offline Storage & Reconnect Auto-Sync
// Copyright (c) 2026 Vedant Narayan. Released under the MIT License.
// ==============================================================================

func logDebug(_ msg: String) {
    let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let logFile = logDir.appendingPathComponent("ssdejector.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }
}

private var gLastF4PressTime: UInt64 = 0
private let gMinDebounceMs: UInt64 = 80
private let gMaxDoublePressMs: UInt64 = 550
private weak var gAppDelegate: AppDelegate?

func applyHidutilMapping() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = [
        "property",
        "--set",
        "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":0x0C00000221,\"HIDKeyboardModifierMappingDst\":0x070000003D}]}"
    ]
    try? process.run()
    process.waitUntilExit()
}

func carbonHotKeyCallback(nextHandler: EventHandlerCallRef?, theEvent: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
    let diff = now - gLastF4PressTime

    if diff < gMinDebounceMs && gLastF4PressTime > 0 {
        return noErr
    }

    logDebug("Physical F4 press detected. Time diff: \(diff) ms")

    if diff >= gMinDebounceMs && diff <= gMaxDoublePressMs && gLastF4PressTime > 0 {
        logDebug("*** TRUE DOUBLE-PRESS DETECTED -> TRIGGERING EJECT ***")
        gLastF4PressTime = 0
        DispatchQueue.main.async {
            gAppDelegate?.handleEjectRequested()
        }
    } else {
        gLastF4PressTime = now
    }

    return noErr
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var ssdMountPath: String = "/Volumes/Mac_EXT"
    private var ssdName: String = "Mac_EXT"
    private var ssdVolumeUUID: String = ""
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var maintenanceTimer: Timer?
    private var wasAutoUnmountedForSleep = false

    private let spilloverFolders = [
        ("Documents/Screenshots", "Documents_Archive/Screenshots"),
        ("Documents/Priyanka Fashionvilla", "Documents_Archive/Priyanka Fashionvilla"),
        ("Documents/PsyMetric", "Documents_Archive/PsyMetric")
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        gAppDelegate = self
        loadConfiguration()
        logDebug("SSDEjector initialized for target volume: \(ssdName)")

        applyHidutilMapping()
        setupMenuBar()
        setupVolumeNotifications()
        setupSleepWakePowerSaver()
        setupCarbonF4HotKey()
        updateStatus()

        // If currently mounted, ensure sync and symlinks are active
        if FileManager.default.fileExists(atPath: ssdMountPath) {
            syncLocalSpilloverFolders()
        }

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            applyHidutilMapping()
            self?.updateStatus()
        }
    }

    private func loadConfiguration() {
        if let customName = ProcessInfo.processInfo.environment["SSD_NAME"] {
            self.ssdName = customName
            self.ssdMountPath = "/Volumes/\(customName)"
        }
        detectVolumeUUID()
    }

    private func detectVolumeUUID() {
        if FileManager.default.fileExists(atPath: ssdMountPath) {
            do {
                let values = try URL(fileURLWithPath: ssdMountPath).resourceValues(forKeys: [.volumeUUIDStringKey])
                if let uuid = values.volumeUUIDString {
                    self.ssdVolumeUUID = uuid
                }
            } catch {}
        }
    }

    // MARK: - Smart Spillover & Auto-Sync Engine
    private func syncLocalSpilloverFolders() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var totalSyncedFiles = 0

            for (relLocal, relExt) in self.spilloverFolders {
                let localPath = "\(home)/\(relLocal)"
                let extPath = "\(self.ssdMountPath)/\(relExt)"

                // Ensure external target directory exists
                _ = self.runCommand("/bin/mkdir", ["-p", extPath])

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) {
                    let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: localPath)) != nil
                    if !isSymlink && isDir.boolValue {
                        logDebug("Found local offline files in \(relLocal). Moving to external SSD...")
                        let (success, out) = self.runCommand("/usr/bin/rsync", ["-av", "--remove-source-files", "\(localPath)/", "\(extPath)/"])
                        if success {
                            let fileCount = out.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasSuffix("/") }.count
                            totalSyncedFiles += fileCount
                            try? FileManager.default.removeItem(atPath: localPath)
                            try? FileManager.default.createSymbolicLink(atPath: localPath, withDestinationPath: extPath)
                            logDebug("Replaced \(relLocal) with transparent symlink to external SSD.")
                        }
                    }
                } else {
                    // Path doesn't exist, create symlink directly
                    try? FileManager.default.createSymbolicLink(atPath: localPath, withDestinationPath: extPath)
                }
            }

            if totalSyncedFiles > 0 {
                DispatchQueue.main.async {
                    self.showNotification(title: "⚡ Storage Auto-Synced", subtitle: "Moved \(totalSyncedFiles) offline files directly to \(self.ssdName).")
                }
            }
        }
    }

    private func handleDriveDisconnected() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (relLocal, _) in self.spilloverFolders {
            let localPath = "\(home)/\(relLocal)"
            let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: localPath)) != nil
            if isSymlink {
                try? FileManager.default.removeItem(atPath: localPath)
                try? FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: true)
                logDebug("SSD Disconnected -> Converted \(relLocal) to local folder for offline saving.")
            }
        }
    }

    private func setupCarbonF4HotKey() {
        if eventHandlerRef != nil {
            RemoveEventHandler(eventHandlerRef)
            eventHandlerRef = nil
        }
        if hotKeyRef != nil {
            UnregisterEventHotKey(hotKeyRef)
            hotKeyRef = nil
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x53534445), id: 1)
        _ = RegisterEventHotKey(
            UInt32(kVK_F4),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func setupSleepWakePowerSaver() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.ssdMountPath) {
                logDebug("[BatterySaver] System sleeping -> Auto-unmounting \(self.ssdName)...")
                self.wasAutoUnmountedForSleep = true
                _ = self.runCommand("/bin/sync", [])
                _ = self.runCommand("/usr/sbin/diskutil", ["unmount", self.ssdMountPath])
                self.updateStatus()
            }
        }

        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            logDebug("[BatterySaver] System woke up -> Restoring keymap and auto-remounting...")
            applyHidutilMapping()
            self.setupCarbonF4HotKey()

            if self.wasAutoUnmountedForSleep {
                self.wasAutoUnmountedForSleep = false
                DispatchQueue.global(qos: .userInteractive).async {
                    if !self.ssdVolumeUUID.isEmpty {
                        _ = self.runCommand("/usr/sbin/diskutil", ["mount", self.ssdVolumeUUID])
                    } else {
                        _ = self.runCommand("/usr/sbin/diskutil", ["mount", self.ssdMountPath])
                    }
                    DispatchQueue.main.async {
                        self.updateStatus()
                        self.syncLocalSpilloverFolders()
                    }
                }
            } else {
                self.updateStatus()
            }
        }

        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            applyHidutilMapping()
            self?.updateStatus()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🟢"
        }
        rebuildMenu(isMounted: FileManager.default.fileExists(atPath: ssdMountPath))
    }

    private func updateStatus() {
        let isMounted = FileManager.default.fileExists(atPath: ssdMountPath)
        if isMounted && ssdVolumeUUID.isEmpty {
            detectVolumeUUID()
        }
        if let button = statusItem.button {
            button.title = isMounted ? "🟢" : "⚪"
        }
        rebuildMenu(isMounted: isMounted)
    }

    private func rebuildMenu(isMounted: Bool) {
        let menu = NSMenu()

        if isMounted {
            let spaceInfo = getStorageInfo()
            let infoItem = NSMenuItem(title: "💾 \(ssdName): \(spaceInfo)", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            menu.addItem(NSMenuItem.separator())

            let ejectItem = NSMenuItem(title: "⏏️ Eject SSD (Double-Tap F4)", action: #selector(menuEjectClicked), keyEquivalent: "")
            ejectItem.target = self
            menu.addItem(ejectItem)

            let openItem = NSMenuItem(title: "📂 Open in Finder", action: #selector(openInFinder), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)
        } else {
            let disconnectedItem = NSMenuItem(title: "⚪ \(ssdName) is Disconnected / Ejected", action: nil, keyEquivalent: "")
            disconnectedItem.isEnabled = false
            menu.addItem(disconnectedItem)

            let mountItem = NSMenuItem(title: "⚡ Mount SSD Now", action: #selector(menuMountClicked), keyEquivalent: "m")
            mountItem.target = self
            menu.addItem(mountItem)

            let safeItem = NSMenuItem(title: "✓ Safe to unplug", action: nil, keyEquivalent: "")
            safeItem.isEnabled = false
            menu.addItem(safeItem)
        }

        menu.addItem(NSMenuItem.separator())
        let inspectItem = NSMenuItem(title: "🔍 Check Active Locks...", action: #selector(inspectLocks), keyEquivalent: "")
        inspectItem.target = self
        menu.addItem(inspectItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit SSDEjector", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuMountClicked() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            if !self.ssdVolumeUUID.isEmpty {
                _ = self.runCommand("/usr/sbin/diskutil", ["mount", self.ssdVolumeUUID])
            } else {
                _ = self.runCommand("/usr/sbin/diskutil", ["mount", self.ssdMountPath])
            }
            DispatchQueue.main.async {
                self.updateStatus()
                self.syncLocalSpilloverFolders()
            }
        }
    }

    private func getStorageInfo() -> String {
        do {
            let values = try URL(fileURLWithPath: ssdMountPath).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            if let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
                let freeGB = Double(free) / 1_000_000_000.0
                let totalGB = Double(total) / 1_000_000_000.0
                return String(format: "%.1f GB free / %.0f GB", freeGB, totalGB)
            }
        } catch {}
        return "Mounted"
    }

    private func setupVolumeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notif in
            guard let self = self else { return }
            if let path = notif.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL, path.path == self.ssdMountPath {
                self.updateStatus()
                self.syncLocalSpilloverFolders()
                NSSound(named: "Blow")?.play()
                self.showNotification(title: "⚡ SSD Connected", subtitle: "\(self.ssdName) is mounted and auto-synced.")
            }
        }

        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notif in
            guard let self = self else { return }
            self.handleDriveDisconnected()
            self.updateStatus()
        }
    }

    @objc private func menuEjectClicked() {
        handleEjectRequested()
    }

    func handleEjectRequested() {
        if !FileManager.default.fileExists(atPath: ssdMountPath) {
            showNotification(title: "SSDEjector", subtitle: "\(ssdName) is already unmounted.")
            return
        }

        logDebug("Attempting direct diskutil eject for \(ssdMountPath)...")
        let (ejectSuccess, ejectOutput) = runCommand("/usr/sbin/diskutil", ["eject", ssdMountPath])

        if ejectSuccess || !FileManager.default.fileExists(atPath: ssdMountPath) {
            logDebug("Direct eject succeeded!")
            handleEjectSuccess()
            return
        }

        logDebug("Direct eject failed. Finding blocking PIDs...")
        let blockingPIDs = getBlockingPIDs(ejectOutput: ejectOutput)
        logDebug("Found blocking PIDs: \(blockingPIDs)")

        if blockingPIDs.isEmpty {
            let (forceSuccess, _) = runCommand("/usr/sbin/diskutil", ["unmount", "force", ssdMountPath])
            if forceSuccess || !FileManager.default.fileExists(atPath: ssdMountPath) {
                handleEjectSuccess()
            } else {
                showNotification(title: "Eject Failed", subtitle: "System processes are still accessing \(ssdName).")
            }
            return
        }

        var appDescriptions: [String] = []
        for pid in blockingPIDs {
            let procPath = getProcessPath(pid: pid)
            let cleanName = getCleanProcessName(procPath: procPath, pid: pid)
            appDescriptions.append("• \(cleanName) (PID: \(pid))")
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Active Applications Using SSD"
        alert.informativeText = "The external SSD (\(ssdName)) is currently being used by:\n\n" +
            appDescriptions.joined(separator: "\n") +
            "\n\nWould you like to close these applications and eject?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Apps & Eject")
        alert.addButton(withTitle: "Force Eject")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            logDebug("User selected Quit Apps & Eject. Terminating PIDs: \(blockingPIDs)")
            for pid in blockingPIDs {
                _ = runCommand("/bin/kill", ["-15", pid])
            }
            Thread.sleep(forTimeInterval: 0.4)
            for pid in blockingPIDs {
                _ = runCommand("/bin/kill", ["-9", pid])
            }
            Thread.sleep(forTimeInterval: 0.2)
            _ = runCommand("/usr/sbin/diskutil", ["unmount", "force", ssdMountPath])
            _ = runCommand("/usr/sbin/diskutil", ["eject", ssdMountPath])

            if !FileManager.default.fileExists(atPath: ssdMountPath) {
                handleEjectSuccess()
            } else {
                showNotification(title: "Eject Failed", subtitle: "Could not unmount drive after terminating apps.")
            }
        } else if response == .alertSecondButtonReturn {
            logDebug("User selected Force Eject.")
            _ = runCommand("/usr/sbin/diskutil", ["unmount", "force", ssdMountPath])
            if !FileManager.default.fileExists(atPath: ssdMountPath) {
                handleEjectSuccess()
            }
        }
    }

    private func handleEjectSuccess() {
        handleDriveDisconnected()
        showNotification(title: "SSD Ejected Safely", subtitle: "\(ssdName) is safe to disconnect.")
        playSpeakerChime()
        updateStatus()
    }

    private func playSpeakerChime() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let chimeBinary = "\(homeDir)/bin/play_speaker_chime"
        if FileManager.default.fileExists(atPath: chimeBinary) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: chimeBinary)
            try? process.run()
        } else {
            NSSound(named: "Glass")?.play()
        }
    }

    private func getBlockingPIDs(ejectOutput: String) -> [String] {
        var pids = Set<String>()

        let (_, fuserOut) = runCommand("/usr/bin/fuser", ["-c", ssdMountPath])
        let regex = try? NSRegularExpression(pattern: "\\b\\d+\\b")
        let matches = regex?.matches(in: fuserOut, range: NSRange(fuserOut.startIndex..., in: fuserOut)) ?? []
        for m in matches {
            if let r = Range(m.range, in: fuserOut) {
                let p = String(fuserOut[r])
                if p != "1" && p != String(ProcessInfo.processInfo.processIdentifier) {
                    pids.insert(p)
                }
            }
        }

        let dissMatches = regex?.matches(in: ejectOutput, range: NSRange(ejectOutput.startIndex..., in: ejectOutput)) ?? []
        for m in dissMatches {
            if let r = Range(m.range, in: ejectOutput) {
                let p = String(ejectOutput[r])
                if p != "1" && p != String(ProcessInfo.processInfo.processIdentifier) {
                    pids.insert(p)
                }
            }
        }

        return Array(pids)
    }

    private func getCleanProcessName(procPath: String, pid: String) -> String {
        if procPath.contains(".app/") {
            return procPath.components(separatedBy: ".app/").first?.components(separatedBy: "/").last ?? procPath
        }
        if procPath.contains("\\") {
            return procPath.components(separatedBy: "\\").last ?? procPath
        }
        if procPath.contains("/") {
            return procPath.components(separatedBy: "/").last ?? procPath
        }
        return procPath.isEmpty ? "Process \(pid)" : procPath
    }

    private func getProcessPath(pid: String) -> String {
        let (_, out) = runCommand("/bin/ps", ["-p", pid, "-o", "comm="])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCommand(_ launchPath: String, _ arguments: [String]) -> (Bool, String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus == 0, out)
        } catch {
            return (false, "")
        }
    }

    @objc private func openInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ssdMountPath)
    }

    @objc private func inspectLocks() {
        handleEjectRequested()
    }

    private func showNotification(title: String, subtitle: String) {
        let script = "display notification \"\(subtitle)\" with title \"\(title)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
