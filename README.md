<div align="center">

# ⚡ SSDEjector for macOS

**Instant, Zero-Friction External SSD Management for Apple Silicon & Intel Macs.**

[![Platform](https://img.shields.io/badge/Platform-macOS%2012.0%2B%20(Sonoma%20%7C%20Sequoia%20%7C%20Tahoe)-black?style=for-the-badge&logo=apple)](https://apple.com)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(M1%2FM2%2FM3%2FM4)%20%26%20Intel-blue?style=for-the-badge&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Language-Swift%206.0-orange?style=for-the-badge&logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/badge/Release-v4.0.0-purple?style=for-the-badge)](https://github.com/VedantNarayan/SSDEjector/releases)

<p align="center">
  <b>Double-Tap F4 to Eject</b> • <b>Battery Sleep-Saver</b> • <b>100% Volume Built-in Speaker Chime</b> • <b>Native Modal Lock Inspector</b> • <b>Ultra-Compact Menu Bar HUD</b>
</p>

</div>

---

## 💡 Why SSDEjector?

Managing permanently connected external SSDs (e.g., NVMe drives in USB enclosures used for extra storage) on modern MacBooks comes with subtle pain points:

1. **Slow / Stuck Ejections**: Ejecting from Finder often hangs for 10–20 seconds when background applications (IDEs, games, Wine, DaVinci Resolve) hold open file descriptors.
2. **Overnight Sleep Battery Drain**: USB 2.0 / NVMe bridge controllers do not negotiate PCIe ASPM low-power states, continuously pulling **1.5W of power all night** (~12% battery loss over 7 hours).
3. **Audio Routing Friction**: You want an audible confirmation that your drive is safe to disconnect, but if Bluetooth headphones or AirPods are connected, standard system beeps are muffled in your pocket/case.
4. **Accessibility Permission Friction**: Traditional hotkey utilities require intrusive TCC Accessibility permissions and repeatedly break after macOS updates.

**SSDEjector solves all of these problems natively in Swift with zero third-party dependencies.**

---

## ✨ Features

```mermaid
graph TD
    A[Double-Tap F4 Key] --> B{Is SSD Busy?}
    B -->|Idle (< 0.1s)| C[Instant Safe Eject]
    B -->|Apps Holding Files| D[Native NSAlert Dialog]
    D -->|Quit Apps & Eject| E[Kill PIDs + Force Eject]
    D -->|Force Eject| F[Force Unmount]
    D -->|Cancel| G[Abort]
    C --> H[CoreAudio Physical Speaker Override]
    E --> H
    F --> H
    H --> I[Play 100% Glass Chime on MacBook Speakers]
    I --> J[Instantly Restore Previous Bluetooth Audio & Volume]
```

### 1. ⚡ Instant Double-Tap F4 Ejection
* Double-tap your physical **F4 / Spotlight key** to safely unmount your external SSD in **< 0.1 seconds**.
* Powered by **Carbon Global Hotkeys** (`RegisterEventHotKey`) — **Zero Accessibility / TCC permissions required**.
* Built-in **hardware debouncing (80ms – 550ms)** prevents electrical key bounce from causing accidental triggers.

### 2. 🔋 Battery Sleep-Saver (Eliminates Overnight Drain)
* **Auto-Unmount on Sleep**: When your MacBook lid closes or the system goes to sleep (`NSWorkspace.willSleepNotification`), SSDEjector automatically flushes buffers (`sync`) and unmounts the volume.
* **Low-Power USB Mode**: macOS puts the USB port into deep hardware suspend, dropping power draw from **1.5W down to ~0.05W** (saving 10–12% battery overnight).
* **Silent Auto-Remount on Wake**: The moment you open the laptop lid (`NSWorkspace.didWakeNotification`), the drive silently remounts in **~0.1 seconds**.

### 3. 🔊 CoreAudio Built-in Speaker Hardware Override
* Uses low-level **CoreAudio HAL APIs** (`kAudioDeviceTransportTypeBuiltIn`) to route the ejection confirmation chime directly to your **physical MacBook Air/Pro laptop speakers at 100% volume**.
* Even if **Bluetooth earphones (AirPods, OnePlus Nord Buds, Sony WH-1000XM), HDMI monitors, or external DACs** are connected, you will always hear the chime loud and clear from the laptop.
* Seamlessly restores your previous audio device and volume level the instant the chime finishes (~0.85s).

### 4. 🛑 Native Modal Lock Inspector (`NSAlert`)
* If an application (CrossOver, Steam, DaVinci Resolve, PyCharm, or Wine) is locking files, a native Cocoa dialog pops up right in front of your active screen.
* Cleanly parses Windows paths (`Z:\...`), backslashes, and POSIX handles.
* Offers **[Quit Apps & Eject]**, **[Force Eject]**, and **[Cancel]**.

### 5. 🖥️ Minimal Menu Bar Status HUD
* Ultra-compact single indicator dot (**`🟢`** when mounted / **`⚪`** when ejected) taking only **~14px** of horizontal space.
* Dropdown menu includes storage capacity info, **`⚡ Mount SSD Now`** toggle, and active lock inspector.

---

## 🚀 Installation

### Option 1: Download Pre-built DMG (Recommended)
1. Download the latest `SSDEjector-v4.0.0-macOS.dmg` from [Releases](https://github.com/VedantNarayan/SSDEjector/releases).
2. Open the DMG and double-click **`Install.command`** (or drag `SSDEjector.app` to Applications).

### Option 2: 1-Line Terminal Install
Run in Terminal:
```bash
curl -fsSL https://raw.githubusercontent.com/VedantNarayan/SSDEjector/main/scripts/install.sh | bash
```

### Option 3: Custom Drive Name
If your external SSD has a custom volume label (e.g. `Samsung_T7`, `MyPassport`):
```bash
./scripts/install.sh "Samsung_T7"
```

---

## 🛠️ Building From Source

### Prerequisites
* macOS 12.0+ (Monterey, Ventura, Sonoma, Sequoia, Tahoe)
* Apple Command Line Tools (`xcode-select --install`) or Xcode

### Build & Package DMG
```bash
# Clone the repository
git clone https://github.com/VedantNarayan/SSDEjector.git
cd SSDEjector

# Compile application
./scripts/build.sh

# Create release DMG
./scripts/build_dmg.sh
```

---

## ⚙️ Configuration & Architecture

| Component | Technology | Purpose |
| :--- | :--- | :--- |
| **Hotkey Listener** | Carbon Event API (`kVK_F4`) | Zero-permission global hotkey registration |
| **Audio Routing** | CoreAudio HAL (`AudioObjectGetPropertyData`) | Physical hardware speaker output override |
| **Power Management** | `NSWorkspace.notificationCenter` | Sleep auto-unmount & wake auto-remount |
| **Lock Detection** | Kernel `fuser` + Regex PID Parser | Real-time active file descriptor inspection |
| **Background Supervisor** | macOS `launchd` LaunchAgent | Automatic login launch & instant crash recovery |

---

## 🗑️ Uninstallation

To completely remove SSDEjector and restore default keyboard mappings:
```bash
./scripts/uninstall.sh
```

---

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

---

<div align="center">
  Developed by <b><a href="https://github.com/VedantNarayan">Vedant Narayan</a></b>
</div>
