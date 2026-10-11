# Mac2MQTT 📡

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-purple.svg)]()
[![Binary Size](https://img.shields.io/badge/bundle%20size-1.5%20MB-brightgreen.svg)]()
[![DMG Size](https://img.shields.io/badge/installer-428%20KB-success.svg)]()
[![Integration](https://img.shields.io/badge/Home%20Assistant-MQTT%20Discovery-orange.svg)](https://www.home-assistant.io/integrations/mqtt/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An ultra-lightweight, native macOS menu bar agent that publishes Mac hardware telemetry, Focus mode, privacy state, and remote controls to **Home Assistant via MQTT Auto-Discovery** — the macOS counterpart to Windows' **HASS.Agent 2**.

Unlike the official Catalyst companion app, **Mac2MQTT has zero webview or WebKit overhead**, runs purely as an accessory background agent (no Dock icon, no window popups on login), and pushes hardware state changes to Home Assistant in real time.

---

## 🚀 Key Features

* **Instant Event Engine**: Kernel-level vnode file watchers and Darwin notifications stream Focus Mode, frontmost app, and display changes to Home Assistant within **< 50ms** (zero polling delay).
* **Audio & Camera Privacy Detection**: CoreAudio hardware device listeners capture active microphone and webcam streaming state instantly (ideal for "On Air" studio lighting automations).
* **Remote Control Endpoints**: Remotely Sleep Mac (`button`), Lock Screen (`button`), or Mute System Audio (`switch`) directly from Home Assistant.
* **Per-Sensor Customization & Entity Pruning**: Check or uncheck any sensor in the Preferences checklist. Unchecked sensors publish empty discovery payloads, automatically purging unused entities from Home Assistant.
* **Pure Native Swift & Low Footprint**: ~25–45 MB RAM footprint and < 0.1% idle CPU. The entire compressed DMG installer is just **428 KB**.
* **Clean Menu Bar Citizen**: Runs strictly in accessory mode (`.accessory`). The Dock icon is automatically dismissed whenever preferences windows are closed.

---

## 📊 Comparison: Mac2MQTT vs. Alternatives

| Feature / Metric | **Mac2MQTT (macOS)** | **Official HA Companion (macOS)** | **HASS.Agent 2 (Windows)** |
| :--- | :--- | :--- | :--- |
| **Platform** | macOS 13+ (Ventura, Sonoma, Sequoia) | macOS 11+ (Intel / Apple Silicon) | Windows 10 & 11 (x64 / ARM64) |
| **Tech Stack** | **Pure Native Swift (AppKit + Darwin)** | Mac Catalyst (iOS UIKit + WebKit) | .NET 8 / C# (WPF + Win32) |
| **Installer Size (.dmg)**| **~428 KB** | ~120 MB – 180 MB | ~60 MB – 95 MB (.msi) |
| **Memory Footprint (RAM)**| **~25 MB – 45 MB** | ~250 MB – 650 MB (WebKit processes) | ~75 MB – 140 MB |
| **Primary Protocol** | **MQTT Auto-Discovery (Local Broker)**| HTTP Webhooks API | MQTT Discovery + Local REST |
| **Focus Mode Latency** | **< 50 ms (Instant Kernel vnode)** | 30s – 120s (Polling) | Windows Focus Assist API |
| **Dock / Window Presence**| **Silent Menu Bar Agent (No Dock Icon)**| Standard Application (Dock Icon) | System Tray Agent |
| **Audio Input / Output Names**| **Exact Hardware Names** | Not Supported | Exact Endpoint Names |
| **Unchecked Sensor Pruning**| **Yes (Unpublished from HA registry)** | No (Static discovery) | Configurable |

> For a detailed technical analysis, see the [Competitive Breakdown Analysis](docs/index.html).

---

## 📡 Sensor & Control Reference

All entities are automatically registered under a single consolidated Device in Home Assistant (**Settings → Devices & Services → MQTT**):

### 🎧 Audio & Camera Privacy
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Microphone In-Use** | `binary_sensor` | Active microphone stream detection |
| **Active Microphone Name** | `sensor` | Connected input device (e.g. *MacBook Pro Microphone*, *Blue Yeti*) |
| **Camera In-Use** | `binary_sensor` | Active camera / webcam stream detection |
| **Active Camera Name** | `sensor` | Connected camera name (e.g. *FaceTime HD Camera*, *Logitech Brio*) |
| **Audio Output In-Use** | `binary_sensor` | Audio playback detection |
| **Active Audio Output Name**| `sensor` | Connected output device (e.g. *AirPods Pro*, *External Headphones*) |

### 💻 System & Presence
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Frontmost App** | `sensor` | Currently focused application name |
| **User Active** | `binary_sensor` | `true` if mouse/keyboard active within the last 2 minutes |
| **Idle Seconds** | `sensor` | Seconds since last user hardware input |
| **CPU Usage** | `sensor` | Real-time processor load percentage (%) |
| **Memory Usage** | `sensor` | System RAM usage percentage (%) |
| **Connected Displays** | `sensor` | Count of active external and built-in screens |
| **Primary Display ID** | `sensor` | Display identifier for the main monitor |
| **App Version** | `sensor` | Current installed Mac2MQTT release version |

### 📶 Network & Wi-Fi
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Wi-Fi SSID** | `sensor` | Connected Wi-Fi network name |
| **Wi-Fi BSSID** | `sensor` | Connected Access Point MAC address |
| **Connection Type** | `sensor` | Network interface type (*Wi-Fi* or *Ethernet*) |

### 🌙 Focus Mode (Do Not Disturb)
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Focus Mode Active** | `binary_sensor` | `true` when any Focus mode is active |
| **Focus Mode Name** | `sensor` | Current Focus profile (*Work*, *Personal*, *Sleep*, *Do Not Disturb*, *Off*) |

### 🔋 Battery & Power
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Battery Level** | `sensor` | Internal battery percentage (%) |
| **Battery Charging** | `binary_sensor` | `true` when plugged in and charging |
| **Battery State** | `sensor` | Current state (*Charging*, *Discharging*, *AC Power*) |
| **Power Source** | `sensor` | *AC Power* vs *Battery* |

### ⚡ Remote Controls (Home Assistant Actions)
| Entity | Type | Action / Trigger |
| :--- | :--- | :--- |
| **Sleep Mac** | `button` | Remotely puts Mac to sleep via `pmset sleepnow` |
| **Lock Screen** | `button` | Remotely turns off display and locks screen |
| **Mute Audio** | `switch` | Remotely toggles system output volume mute on/off |

---

## 🛠️ Installation & Setup

### 1. Download & Install
Download the latest `Mac2MQTT.dmg` from [Releases](https://github.com/PinkPlastic/Mac2MQTT/releases), open the DMG, and drag **Mac2MQTT** into your **Applications** folder.

### 2. Permissions (One-Time Setup)
Upon first launch, open **Preferences → Permissions**:
1. **Full Disk Access**: Click **Open Settings** and toggle `Mac2MQTT` to `ON`. (Required for zero-latency Focus mode tracking).
2. **Location Services**: Click **Grant Permission** to allow reading your local Wi-Fi SSID.

### 3. Configure MQTT Connection
In **Preferences → Connection**:
1. Enter your MQTT Broker IP/Hostname (e.g. `192.168.1.50` or `homeassistant.local`) and Port (`1883`).
2. Enter your MQTT Username and Password (if applicable).
3. Click **Done**.

Your Mac will immediately discover into Home Assistant!

---

## 🏗️ Building from Source

Requirements: macOS 13+, Xcode 15+ (or Command Line Tools), Swift 5.9+.

```bash
# Clone the repository
git clone https://github.com/PinkPlastic/Mac2MQTT.git
cd Mac2MQTT

# Build and package the application bundle
./bundle.sh

# Build the release DMG installer
./create_dmg.sh
```

The resulting `Mac2MQTT.dmg` will be created in the project root.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
