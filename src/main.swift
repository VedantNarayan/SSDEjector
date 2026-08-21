import Cocoa
import Carbon
import Foundation
import UserNotifications

// ==============================================================================
// SSDEjector - Native macOS SSD Management & Universal Storage Orchestrator
// Pure Storage Isolation Engine - Zero Audio Interventions (v9.3.0)
// Copyright (c) 2026 Vedant Narayan. Released under the MIT License.
// ==============================================================================

struct TrackedFolder: Codable {
    var localPath: String
    var mode: String // "mirror" (Local Buffer), "spillover" (Auto-Reclaim), or "offload" (Direct SSD)
}

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
        logDebug("*** TRUE DOUBLE-PRESS DETECTED -> TRIGGERING FAST ASYNC EJECT ***")
        gLastF4PressTime = 0
        DispatchQueue.global(qos: .userInteractive).async {
            gAppDelegate?.handleEjectRequested()
        }
    } else {
        gLastF4PressTime = now
    }

    return noErr
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var connectedIcon: NSImage?
    private var disconnectedIcon: NSImage?

    private var ssdMountPath: String = "/Volumes/Mac_EXT"
    private var ssdName: String = "Mac_EXT"
    private var ssdVolumeUUID: String = ""
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var maintenanceTimer: Timer?
    private var wasAutoUnmountedForSleep = false

    private let systemDaemons = Set([
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
        "mdsync", "fseventsd", "quicklookd", "diskarbitrationd", "revisiond",
        "backupd", "fileproviderd", "deleted", "storebench"
    ])

    private let criticalSyncDaemons = Set([
        "rsync", "cp", "mv", "tar", "ditto", "qemu-img", "hdiutil", "dd",
        "qemu-system-aarch64", "fsck_hfs", "fsck_apfs"
    ])

    private let ejectLock = NSLock()
    private var isEjecting = false
    private let syncLock = NSLock()
    private var isSyncing = false
    private var activeSyncProcess: Process?
    private var pendingEjectOnSyncComplete = false
    private var currentSyncStatusString = ""

    private weak var liveProgressIndicator: NSProgressIndicator?
    private weak var liveStatsLabel: NSTextField?
    private weak var liveTaskLabel: NSTextField?
    private weak var liveAutoEjectButton: NSButton?

    private var configURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssdejector_folders.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        gAppDelegate = self
        loadConfiguration()
        logDebug("SSDEjector 9.3.0 (Pure Storage Isolation Engine) initialized.")

        applyHidutilMapping()
        loadIcons()
        setupMenuBar()
        setupVolumeNotifications()
        setupSleepWakePowerSaver()
        setupCarbonF4HotKey()
        updateStatus()

        if FileManager.default.fileExists(atPath: ssdMountPath) {
            syncAllTrackedFolders()
        }

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            applyHidutilMapping()
            self?.updateStatus()
        }
    }

    private func loadIcons() {
        let resPath = Bundle.main.resourcePath ?? ""
        let assetsPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/SSDEjector/assets"

        let connPath = FileManager.default.fileExists(atPath: "\(resPath)/menubar_connected@2x.png") ?
            "\(resPath)/menubar_connected@2x.png" : (FileManager.default.fileExists(atPath: "\(assetsPath)/menubar_connected@2x.png") ?
            "\(assetsPath)/menubar_connected@2x.png" : "\(assetsPath)/menubar_connected.png")

        let disconnPath = FileManager.default.fileExists(atPath: "\(resPath)/menubar_disconnected@2x.png") ?
            "\(resPath)/menubar_disconnected@2x.png" : (FileManager.default.fileExists(atPath: "\(assetsPath)/menubar_disconnected@2x.png") ?
            "\(assetsPath)/menubar_disconnected@2x.png" : "\(assetsPath)/menubar_disconnected.png")

        if let img = NSImage(contentsOfFile: connPath) {
            img.isTemplate = false
            img.size = NSSize(width: 24, height: 22)
            self.connectedIcon = img
        }

        if let img = NSImage(contentsOfFile: disconnPath) {
            img.isTemplate = false
            img.size = NSSize(width: 24, height: 22)
            self.disconnectedIcon = img
        }
    }

    private func loadConfiguration() {
        if let customName = ProcessInfo.processInfo.environment["SSD_NAME"] {
            self.ssdName = customName
            self.ssdMountPath = "/Volumes/\(customName)"
        }
        detectVolumeUUID()

        if !FileManager.default.fileExists(atPath: configURL.path) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let defaults = [
                TrackedFolder(localPath: "\(home)/Documents/Priyanka Fashionvilla", mode: "offload"),
                TrackedFolder(localPath: "\(home)/Documents/PsyMetric", mode: "offload")
            ]
            saveTrackedFolders(defaults)
        }
    }

    private func getTrackedFolders() -> [TrackedFolder] {
        guard let data = try? Data(contentsOf: configURL),
              let list = try? JSONDecoder().decode([TrackedFolder].self, from: data) else {
            return []
        }
        return list
    }

    private func saveTrackedFolders(_ list: [TrackedFolder]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: configURL, options: .atomic)
        }
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

    // MARK: - Real-Time Live Rsync Execution with Streaming Updates
    private func runRsyncWithLiveProgress(localPath: String, remotePath: String, folderName: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        proc.arguments = ["-av", "--progress", "\(localPath)/", "\(remotePath)/"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let regexPattern = #"^\s*([0-9,]+)\s+([0-9]+)%\s+([0-9.]+[A-Za-z/]+)\s+([0-9:]+)"#
        let regex = try? NSRegularExpression(pattern: regexPattern)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }

            let lines = str.components(separatedBy: "\r")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = regex?.firstMatch(in: trimmed, range: range) {
                    if let rPct = Range(match.range(at: 2), in: trimmed),
                       let rSpeed = Range(match.range(at: 3), in: trimmed),
                       let rEta = Range(match.range(at: 4), in: trimmed) {

                        let pctInt = Int(trimmed[rPct]) ?? 0
                        let speedStr = String(trimmed[rSpeed])
                        let etaRaw = String(trimmed[rEta])
                        let pctDouble = Double(pctInt) / 100.0

                        DispatchQueue.main.async {
                            guard let self = self else { return }

                            self.currentSyncStatusString = " 🔄 \(folderName) (\(pctInt)% • ~\(etaRaw))"
                            self.updateStatus()

                            if let indicator = self.liveProgressIndicator {
                                indicator.isIndeterminate = false
                                indicator.doubleValue = pctDouble
                            }
                            if let sLabel = self.liveStatsLabel {
                                sLabel.stringValue = "📊 Progress: \(pctInt)%  •  ⏳ ~\(etaRaw) remaining"
                            }
                            if let tLabel = self.liveTaskLabel {
                                tLabel.stringValue = "📁 Syncing: \(folderName)  •  ⚡ \(speedStr)"
                            }
                            if let btn = self.liveAutoEjectButton {
                                btn.title = "⏳ Auto-Eject When Done (~\(etaRaw))"
                            }
                        }
                    }
                }
            }
        }

        syncLock.lock()
        activeSyncProcess = proc
        syncLock.unlock()

        do {
            try proc.run()
            proc.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil

            syncLock.lock()
            activeSyncProcess = nil
            syncLock.unlock()

            return proc.terminationStatus == 0
        } catch {
            syncLock.lock()
            activeSyncProcess = nil
            syncLock.unlock()
            return false
        }
    }

    // MARK: - 3-Tier Multi-Directory Storage Engine
    func syncAllTrackedFolders() {
        syncLock.lock()
        if isSyncing {
            syncLock.unlock()
            return
        }
        isSyncing = true
        syncLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer {
                self.syncLock.lock()
                self.isSyncing = false
                let shouldAutoEject = self.pendingEjectOnSyncComplete
                self.pendingEjectOnSyncComplete = false
                self.syncLock.unlock()

                DispatchQueue.main.async {
                    self.currentSyncStatusString = ""
                    self.updateStatus()

                    if shouldAutoEject {
                        logDebug("Auto-eject triggered after sync completion.")
                        self.showNotification(title: "⚡ Sync Complete", subtitle: "All files synchronized. Safely unmounting \(self.ssdName)...")
                        DispatchQueue.global(qos: .userInteractive).async {
                            self.handleEjectRequested()
                        }
                    }
                }
            }

            guard FileManager.default.fileExists(atPath: self.ssdMountPath) else { return }
            let folders = self.getTrackedFolders()

            for item in folders {
                self.ejectLock.lock()
                let ejectPending = self.isEjecting
                self.ejectLock.unlock()
                if ejectPending {
                    logDebug("Sync loop aborted due to pending eject.")
                    break
                }

                let localPath = (item.localPath as NSString).expandingTildeInPath
                let folderName = (localPath as NSString).lastPathComponent
                let remotePath = "\(self.ssdMountPath)/Documents_Archive/\(folderName)"

                try? FileManager.default.createDirectory(atPath: remotePath, withIntermediateDirectories: true)

                if item.mode == "mirror" {
                    if FileManager.default.fileExists(atPath: localPath) {
                        _ = self.runRsyncWithLiveProgress(localPath: localPath, remotePath: remotePath, folderName: folderName)
                    }
                } else if item.mode == "spillover" {
                    let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: localPath)) != nil
                    if !isSymlink {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) && isDir.boolValue {
                            _ = self.runRsyncWithLiveProgress(localPath: localPath, remotePath: remotePath, folderName: folderName)
                            _ = try? FileManager.default.removeItem(atPath: localPath)
                            _ = try? FileManager.default.createSymbolicLink(atPath: localPath, withDestinationPath: remotePath)
                        }
                    }
                } else if item.mode == "offload" {
                    let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: localPath)) != nil
                    if !isSymlink {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) && isDir.boolValue {
                            _ = self.runCommandWithTimeout("/usr/bin/rsync", ["-av", "--remove-source-files", "\(localPath)/", "\(remotePath)/"], timeout: 4.0)
                            _ = try? FileManager.default.removeItem(atPath: localPath)
                        }
                        _ = try? FileManager.default.createSymbolicLink(atPath: localPath, withDestinationPath: remotePath)
                    }
                }
            }
        }
    }

    private func handleDriveDisconnected() {
        let folders = getTrackedFolders()
        for item in folders where item.mode == "spillover" {
            let localPath = (item.localPath as NSString).expandingTildeInPath
            let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: localPath)) != nil
            if isSymlink {
                try? FileManager.default.removeItem(atPath: localPath)
                try? FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: true)
                logDebug("[Spillover] Disconnected -> Converted \(localPath) to real local folder for offline saving.")
            }
        }
    }

    // MARK: - GUI Folder Manager Window
    @objc func openFolderManager() {
        NSApp.activate(ignoringOtherApps: true)

        let folders = getTrackedFolders()
        var folderListText = ""
        for (idx, f) in folders.enumerated() {
            var modeDesc = ""
            if f.mode == "mirror" {
                modeDesc = "⚡ Local Buffer + Mirror Sync (Dual Copy)"
            } else if f.mode == "spillover" {
                modeDesc = "🧹 Spillover + Auto-Reclaim (Zero Internal Waste)"
            } else {
                modeDesc = "💾 Direct SSD Storage (Symlink)"
            }

            let folderName = (f.localPath as NSString).lastPathComponent
            folderListText += "\(idx + 1). 📁 \(folderName)\n    Path: \(f.localPath)\n    Mode: \(modeDesc)\n\n"
        }

        if folderListText.isEmpty {
            folderListText = "No custom folders tracked yet.\nClick 'Add Folder to Sync' below to track any folder on your Mac!"
        }

        let alert = NSAlert()
        alert.messageText = "📁 Manage Synced Folders"
        alert.informativeText = "Tracked Folders on this Mac:\n\n" + folderListText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "➕ Add Folder to Sync...")
        alert.addButton(withTitle: "⚡ Sync All Now")
        alert.addButton(withTitle: "➖ Remove a Folder...")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            promptAddFolder()
        } else if response == .alertSecondButtonReturn {
            syncAllTrackedFolders()
            showNotification(title: "⚡ Sync Triggered", subtitle: "Synchronizing all tracked folders with \(ssdName)...")
        } else if response == .alertThirdButtonReturn {
            promptRemoveFolder()
        }
    }

    private func promptAddFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Any Folder to Sync with External SSD"
        openPanel.showsHiddenFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            let selectedPath = selectedURL.path
            let folderName = selectedURL.lastPathComponent

            let modeAlert = NSAlert()
            modeAlert.messageText = "Choose Storage Mode for '\(folderName)'"
            modeAlert.informativeText = """
            Select how you want SSDEjector to manage this folder:

            1. ⚡ Local Buffer + Mirror Sync (Dual Copy):
               • Keeps folder permanently on internal Mac (0 broken links when offline, permanent in Finder sidebar).
               • Automatically mirrors all files to External SSD when connected.

            2. 🧹 Spillover + Auto-Reclaim (Zero Internal Waste):
               • Saves locally when offline (0 errors when traveling).
               • When SSD connects, moves files to SSD and FREES UP 100% internal space!

            3. 💾 Direct Storage Offload (Max Free Space):
               • Stores 100% on External SSD from day one.
               • Uses 0 GB of internal storage.
            """
            modeAlert.alertStyle = .informational
            modeAlert.addButton(withTitle: "⚡ Local Buffer + Mirror Sync")
            modeAlert.addButton(withTitle: "🧹 Spillover & Reclaim Space")
            modeAlert.addButton(withTitle: "💾 Direct Storage Offload")
            modeAlert.addButton(withTitle: "Cancel")

            let modeResponse = modeAlert.runModal()
            var chosenMode = "mirror"
            if modeResponse == .alertFirstButtonReturn {
                chosenMode = "mirror"
            } else if modeResponse == .alertSecondButtonReturn {
                chosenMode = "spillover"
            } else if modeResponse == .alertThirdButtonReturn {
                chosenMode = "offload"
            } else {
                return
            }

            var current = getTrackedFolders()
            current.removeAll { $0.localPath == selectedPath }
            current.append(TrackedFolder(localPath: selectedPath, mode: chosenMode))
            saveTrackedFolders(current)

            syncAllTrackedFolders()
            showNotification(title: "Folder Added to Sync", subtitle: "'\(folderName)' is now configured with \(chosenMode) mode.")
            openFolderManager()
        }
    }

    private func promptRemoveFolder() {
        let folders = getTrackedFolders()
        guard !folders.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Select Folder to Remove from Sync"
        alert.informativeText = "Choose which folder you want to stop tracking:"
        alert.alertStyle = .warning

        for f in folders {
            let name = (f.localPath as NSString).lastPathComponent
            alert.addButton(withTitle: name)
        }
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        let selectedIndex = resp.rawValue - 1000
        if selectedIndex >= 0 && selectedIndex < folders.count {
            let removed = folders[selectedIndex]
            var updated = folders
            updated.remove(at: selectedIndex)
            saveTrackedFolders(updated)
            showNotification(title: "Folder Removed", subtitle: "Stopped tracking '\((removed.localPath as NSString).lastPathComponent)'.")
            openFolderManager()
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
                logDebug("[BatterySaver] System sleeping -> Fast auto-unmounting \(self.ssdName)...")
                self.wasAutoUnmountedForSleep = true
                _ = self.runCommandWithTimeout("/bin/sync", [], timeout: 1.0)
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", "force", self.ssdMountPath], timeout: 3.0)
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
                        _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["mount", self.ssdVolumeUUID], timeout: 4.0)
                    } else {
                        _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["mount", self.ssdMountPath], timeout: 4.0)
                    }
                    DispatchQueue.main.async {
                        self.updateStatus()
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
        updateStatus()
    }

    private func updateStatus() {
        let isMounted = FileManager.default.fileExists(atPath: ssdMountPath)
        if isMounted && ssdVolumeUUID.isEmpty {
            detectVolumeUUID()
        }
        if let button = statusItem.button {
            button.image = isMounted ? connectedIcon : disconnectedIcon
            button.imageScaling = .scaleProportionallyUpOrDown

            if isEjecting {
                button.title = " ⏏️ Ejecting..."
                button.imagePosition = .imageLeft
            } else if !currentSyncStatusString.isEmpty {
                button.title = currentSyncStatusString
                button.imagePosition = .imageLeft
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
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

            if isSyncing {
                let syncItem = NSMenuItem(title: "🔄 Sync Active (\(currentSyncStatusString.trimmingCharacters(in: .whitespaces)))", action: nil, keyEquivalent: "")
                syncItem.isEnabled = false
                menu.addItem(syncItem)
            }

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

        let manageFoldersItem = NSMenuItem(title: "📁 Manage Synced Folders...", action: #selector(openFolderManager), keyEquivalent: "f")
        manageFoldersItem.target = self
        menu.addItem(manageFoldersItem)

        let syncNowItem = NSMenuItem(title: "⚡ Sync Folders Now", action: #selector(menuSyncNowClicked), keyEquivalent: "s")
        syncNowItem.target = self
        menu.addItem(syncNowItem)

        let inspectItem = NSMenuItem(title: "🔍 Check Active Locks...", action: #selector(inspectLocks), keyEquivalent: "")
        inspectItem.target = self
        menu.addItem(inspectItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit SSDEjector", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuSyncNowClicked() {
        syncAllTrackedFolders()
        showNotification(title: "⚡ Sync Started", subtitle: "Synchronizing all tracked folders to \(ssdName)...")
    }

    @objc private func menuMountClicked() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            if !self.ssdVolumeUUID.isEmpty {
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["mount", self.ssdVolumeUUID], timeout: 4.0)
            } else {
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["mount", self.ssdMountPath], timeout: 4.0)
            }
            DispatchQueue.main.async {
                self.updateStatus()
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
            if let path = notif.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL, path.path.contains(self.ssdName) {
                self.updateStatus()
                self.syncAllTrackedFolders()
                self.showNotification(title: "⚡ SSD Connected", subtitle: "\(self.ssdName) is mounted.")
            }
        }

        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleDriveDisconnected()
            self?.updateStatus()
        }
    }

    @objc private func menuEjectClicked() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.handleEjectRequested()
        }
    }

    // MARK: - Zero-Delay Fast Ejection Pipeline (<0.3s)
    func handleEjectRequested() {
        ejectLock.lock()
        if isEjecting {
            ejectLock.unlock()
            logDebug("Eject already in progress. Skipping duplicate request.")
            return
        }
        isEjecting = true
        ejectLock.unlock()

        DispatchQueue.main.async {
            self.updateStatus()
        }

        defer {
            ejectLock.lock()
            isEjecting = false
            ejectLock.unlock()
            DispatchQueue.main.async {
                self.updateStatus()
            }
        }

        if !FileManager.default.fileExists(atPath: ssdMountPath) {
            showNotification(title: "SSDEjector", subtitle: "\(ssdName) is already unmounted.")
            return
        }

        syncLock.lock()
        if let proc = activeSyncProcess, proc.isRunning {
            logDebug("Internal background sync active during eject. Terminating immediately...")
            proc.terminate()
            activeSyncProcess = nil
        }
        syncLock.unlock()

        _ = runCommandWithTimeout("/bin/sync", [], timeout: 1.0)

        let (ejectSuccess, ejectOutput) = runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", ssdMountPath], timeout: 1.5)

        if ejectSuccess || !FileManager.default.fileExists(atPath: ssdMountPath) {
            logDebug("Direct unmount completed cleanly in <0.2s!")
            _ = runCommandWithTimeout("/usr/sbin/diskutil", ["eject", ssdMountPath], timeout: 2.0)
            handleEjectSuccess()
            return
        }

        let allBlockingPIDs = getFastBlockingPIDs(ejectOutput: ejectOutput)

        var criticalSyncPIDs: [String] = []
        var regularUserAppPIDs: [String] = []
        var regularUserAppDescriptions: [String] = []

        for pid in allBlockingPIDs {
            let procPath = getProcessPath(pid: pid)
            let cleanName = getCleanProcessName(procPath: procPath, pid: pid)
            let baseName = procPath.components(separatedBy: "/").last ?? cleanName

            if systemDaemons.contains(cleanName) || systemDaemons.contains(baseName) {
                logDebug("Smart Bypass: PID \(pid) is system daemon (\(cleanName)). Skipping user prompt.")
            } else if criticalSyncDaemons.contains(cleanName) || criticalSyncDaemons.contains(baseName) {
                criticalSyncPIDs.append(pid)
            } else {
                regularUserAppPIDs.append(pid)
                regularUserAppDescriptions.append("• \(cleanName) (PID: \(pid))")
            }
        }

        if criticalSyncPIDs.isEmpty && regularUserAppPIDs.isEmpty {
            logDebug("Only system daemons active on SSD. Executing instant force-unmount (<0.3s)...")
            let (forceSuccess, _) = runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", "force", ssdMountPath], timeout: 4.0)
            _ = runCommandWithTimeout("/usr/sbin/diskutil", ["eject", ssdMountPath], timeout: 2.0)

            if forceSuccess || !FileManager.default.fileExists(atPath: ssdMountPath) {
                handleEjectSuccess()
            } else {
                showNotification(title: "Eject Failed", subtitle: "System processes are still accessing \(ssdName).")
            }
            return
        }

        DispatchQueue.main.async {
            self.presentEjectModal(criticalSyncPIDs: criticalSyncPIDs, regularUserAppPIDs: regularUserAppPIDs, regularUserAppDescriptions: regularUserAppDescriptions)
        }
    }

    private func presentEjectModal(criticalSyncPIDs: [String], regularUserAppPIDs: [String], regularUserAppDescriptions: [String]) {
        NSApp.activate(ignoringOtherApps: true)

        if !criticalSyncPIDs.isEmpty {
            logDebug("Critical data sync active (\(criticalSyncPIDs)). Displaying Real-Time Live Visual Card...")

            let alert = NSAlert()
            alert.messageText = "🛡️ Active Data Sync in Progress"
            alert.informativeText = "Writing files to '\(ssdName)' in background. Force eject is paused to prevent corrupted files."
            alert.alertStyle = .informational

            let cardView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 95))

            let taskLabel = NSTextField(frame: NSRect(x: 4, y: 70, width: 332, height: 20))
            taskLabel.stringValue = "📁 Syncing: Active Data  •  ⚡ Live Transfer"
            taskLabel.isEditable = false
            taskLabel.isBordered = false
            taskLabel.backgroundColor = .clear
            taskLabel.font = NSFont.boldSystemFont(ofSize: 12)
            cardView.addSubview(taskLabel)
            self.liveTaskLabel = taskLabel

            let progressIndicator = NSProgressIndicator(frame: NSRect(x: 4, y: 46, width: 332, height: 16))
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0.0
            progressIndicator.maxValue = 1.0
            progressIndicator.doubleValue = 0.40
            cardView.addSubview(progressIndicator)
            self.liveProgressIndicator = progressIndicator

            let statsLabel = NSTextField(frame: NSRect(x: 4, y: 22, width: 332, height: 18))
            statsLabel.stringValue = "📊 Live transfer in progress..."
            statsLabel.isEditable = false
            statsLabel.isBordered = false
            statsLabel.backgroundColor = .clear
            statsLabel.textColor = .secondaryLabelColor
            statsLabel.font = NSFont.systemFont(ofSize: 11)
            cardView.addSubview(statsLabel)
            self.liveStatsLabel = statsLabel

            let badgeLabel = NSTextField(frame: NSRect(x: 4, y: 0, width: 332, height: 18))
            badgeLabel.stringValue = "🔒 Safe Auto-Eject will unmount drive automatically when done."
            badgeLabel.isEditable = false
            badgeLabel.isBordered = false
            badgeLabel.backgroundColor = .clear
            badgeLabel.textColor = .systemGreen
            badgeLabel.font = NSFont.boldSystemFont(ofSize: 10.5)
            cardView.addSubview(badgeLabel)

            alert.accessoryView = cardView

            alert.addButton(withTitle: "⏳ Auto-Eject When Done")
            alert.addButton(withTitle: "🛑 Stop & Eject Now")
            alert.addButton(withTitle: "Cancel")

            if let btn = alert.buttons.first {
                self.liveAutoEjectButton = btn
            }

            let response = alert.runModal()

            self.liveTaskLabel = nil
            self.liveProgressIndicator = nil
            self.liveStatsLabel = nil
            self.liveAutoEjectButton = nil

            if response == .alertFirstButtonReturn {
                logDebug("User chose Auto-Eject When Done.")
                self.syncLock.lock()
                self.pendingEjectOnSyncComplete = true
                self.syncLock.unlock()
                self.showNotification(title: "⏳ Auto-Eject Armed", subtitle: "SSDEjector will automatically eject \(self.ssdName) as soon as transfer finishes.")
                return
            } else if response == .alertSecondButtonReturn {
                logDebug("User chose Stop & Eject Now.")
                DispatchQueue.global(qos: .userInteractive).async {
                    for pid in criticalSyncPIDs {
                        _ = self.runCommandWithTimeout("/bin/kill", ["-15", pid], timeout: 0.5)
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                    for pid in criticalSyncPIDs {
                        _ = self.runCommandWithTimeout("/bin/kill", ["-9", pid], timeout: 0.5)
                    }
                    _ = self.runCommandWithTimeout("/bin/sync", [], timeout: 1.0)
                    _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", "force", self.ssdMountPath], timeout: 4.0)
                    _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["eject", self.ssdMountPath], timeout: 2.0)

                    if !FileManager.default.fileExists(atPath: self.ssdMountPath) {
                        self.handleEjectSuccess()
                    } else {
                        self.showNotification(title: "Eject Failed", subtitle: "Could not unmount drive cleanly.")
                    }
                }
                return
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Active Applications Using SSD"
        alert.informativeText = "The external SSD (\(ssdName)) is currently being used by:\n\n" +
            regularUserAppDescriptions.joined(separator: "\n") +
            "\n\nWould you like to close these applications and eject?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Apps & Eject")
        alert.addButton(withTitle: "Force Eject")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            logDebug("User selected Quit Apps & Eject. Terminating User PIDs: \(regularUserAppPIDs)")
            DispatchQueue.global(qos: .userInteractive).async {
                for pid in regularUserAppPIDs {
                    _ = self.runCommandWithTimeout("/bin/kill", ["-15", pid], timeout: 0.5)
                }
                Thread.sleep(forTimeInterval: 0.2)
                for pid in regularUserAppPIDs {
                    _ = self.runCommandWithTimeout("/bin/kill", ["-9", pid], timeout: 0.5)
                }
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", "force", self.ssdMountPath], timeout: 4.0)
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["eject", self.ssdMountPath], timeout: 2.0)

                if !FileManager.default.fileExists(atPath: self.ssdMountPath) {
                    self.handleEjectSuccess()
                } else {
                    self.showNotification(title: "Eject Failed", subtitle: "Could not unmount drive after terminating apps.")
                }
            }
        } else if response == .alertSecondButtonReturn {
            logDebug("User selected Force Eject.")
            DispatchQueue.global(qos: .userInteractive).async {
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["unmount", "force", self.ssdMountPath], timeout: 4.0)
                _ = self.runCommandWithTimeout("/usr/sbin/diskutil", ["eject", self.ssdMountPath], timeout: 2.0)
                if !FileManager.default.fileExists(atPath: self.ssdMountPath) {
                    self.handleEjectSuccess()
                }
            }
        }
    }

    private func handleEjectSuccess() {
        handleDriveDisconnected()
        showNotification(title: "SSD Ejected Safely", subtitle: "\(ssdName) is safe to disconnect.")
        DispatchQueue.main.async {
            self.updateStatus()
        }
    }

    private func getFastBlockingPIDs(ejectOutput: String) -> [String] {
        var pids = Set<String>()

        let regex = try? NSRegularExpression(pattern: #"(?:dissented by PID|PID:?)\s*(\d+)"#, options: .caseInsensitive)
        let matches = regex?.matches(in: ejectOutput, range: NSRange(ejectOutput.startIndex..., in: ejectOutput)) ?? []
        for m in matches {
            if let r = Range(m.range(at: 1), in: ejectOutput) {
                let p = String(ejectOutput[r])
                if p != "1" && p != String(ProcessInfo.processInfo.processIdentifier) {
                    pids.insert(p)
                }
            }
        }

        if pids.isEmpty {
            let (_, lsofOut) = runCommandWithTimeout("/usr/sbin/lsof", ["-t", ssdMountPath], timeout: 0.8)
            let lsofLines = lsofOut.components(separatedBy: "\n")
            for line in lsofLines {
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && clean != "1" && clean != String(ProcessInfo.processInfo.processIdentifier) {
                    pids.insert(clean)
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
        let (_, out) = runCommandWithTimeout("/bin/ps", ["-p", pid, "-o", "comm="], timeout: 0.5)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCommandWithTimeout(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> (Bool, String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return (false, "")
        }

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()

        DispatchQueue.global(qos: .utility).async {
            proc.waitUntilExit()
            dispatchGroup.leave()
        }

        let result = dispatchGroup.wait(timeout: .now() + timeout)
        if result == .timedOut {
            logDebug("Command \(launchPath) \(arguments) timed out after \(timeout)s. Terminating...")
            proc.terminate()
            return (false, "timed_out")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, out)
    }

    @objc private func openInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ssdMountPath)
    }

    @objc private func inspectLocks() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.handleEjectRequested()
        }
    }

    private func showNotification(title: String, subtitle: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = subtitle
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
