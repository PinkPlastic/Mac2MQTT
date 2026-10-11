# Mac2MQTT

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-purple.svg)]()
[![Integration](https://img.shields.io/badge/Home%20Assistant-MQTT%20Discovery-orange.svg)](https://www.home-assistant.io/integrations/mqtt/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Native macOS menu bar agent that sends system telemetry, Focus mode state, and controls to Home Assistant via MQTT auto-discovery.

Built in pure Swift with AppKit and Darwin APIs, Mac2MQTT runs as an accessory process without a Dock icon, web views, or WebKit overhead.

---

## Key Features

* **Event-Driven Updates**: Uses kernel vnode file watchers and Darwin notifications to dispatch Focus Mode, frontmost app, and display changes to Home Assistant in under 50 ms.
* **Audio and Camera Detection**: Uses CoreAudio and CoreMediaIO hardware listeners to report active microphone and webcam streaming state.
* **Remote Control Endpoints**: Provides Home Assistant entities to sleep the Mac (`button`), lock the screen (`button`), or toggle system audio mute (`switch`).
* **Entity Pruning**: Unchecking sensors in Preferences sends empty discovery payloads, removing unused entities from the Home Assistant registry.
* **Low Resource Usage**: Uses 25 MB to 45 MB of RAM and under 0.1% idle CPU.
* **Accessory Mode**: Runs exclusively from the menu bar (`.accessory`); dismisses the Dock icon when preferences are closed.

---

## Comparison

| Feature / Metric | Mac2MQTT (macOS) | Official HA Companion (macOS) | HASS.Agent 2 (Windows) |
| :--- | :--- | :--- | :--- |
| **Platform** | macOS 13+ (Ventura, Sonoma, Sequoia) | macOS 11+ (Intel / Apple Silicon) | Windows 10 & 11 (x64 / ARM64) |
| **Tech Stack** | Native Swift (AppKit + Darwin) | Mac Catalyst (iOS UIKit + WebKit) | .NET 8 / C# (WPF + Win32) |
| **Installer Size** | < 1 MB DMG | 120 MB - 180 MB | 60 MB - 95 MB (.msi) |
| **Memory (RAM)** | 25 MB - 45 MB | 250 MB - 650 MB (WebKit processes) | 75 MB - 140 MB |
| **Primary Protocol** | Direct MQTT socket (TCP/TLS) | HTTP Webhooks API | MQTT Discovery + Local REST |
| **Focus Mode Latency** | < 50 ms (Kernel vnode) | 30s - 120s (Polling) | Windows Focus Assist API |
| **UI Mode** | Menu bar daemon (No dock icon) | Application (Dock icon) | System tray icon |
| **Device Names** | Hardware endpoint names | Not supported | Exact endpoint names |
| **Entity Pruning** | Yes (Removed from registry) | No (Static discovery) | Configurable |

---

## Supported Sensors and Controls

All entities register under a single consolidated Device in Home Assistant (**Settings -> Devices & Services -> MQTT**):

### Audio and Camera
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Microphone In-Use** | `binary_sensor` | Active microphone stream detection |
| **Active Microphone Name** | `sensor` | Connected input device (e.g. *MacBook Pro Microphone*, *Blue Yeti*) |
| **Camera In-Use** | `binary_sensor` | Active camera / webcam stream detection |
| **Active Camera Name** | `sensor` | Connected camera name (e.g. *FaceTime HD Camera*, *Logitech Brio*) |
| **Audio Output In-Use** | `binary_sensor` | Active audio playback detection |
| **Active Audio Output Name** | `sensor` | Connected output device (e.g. *AirPods Pro*, *External Headphones*) |

### System and Presence
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Frontmost App** | `sensor` | Currently focused application name |
| **User Active** | `binary_sensor` | `true` if mouse or keyboard active within the last 2 minutes |
| **Idle Seconds** | `sensor` | Seconds since last user hardware input |
| **CPU Usage** | `sensor` | Processor load percentage (%) |
| **Memory Usage** | `sensor` | System RAM usage percentage (%) |
| **Connected Displays** | `sensor` | Count of active external and built-in screens |
| **Primary Display ID** | `sensor` | Display identifier for the main monitor |
| **App Version** | `sensor` | Installed Mac2MQTT version |

### Network and Wi-Fi
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Wi-Fi SSID** | `sensor` | Connected Wi-Fi network name |
| **Wi-Fi BSSID** | `sensor` | Access Point MAC address |
| **Connection Type** | `sensor` | Network interface type (*Wi-Fi* or *Ethernet*) |

### Focus Mode (Do Not Disturb)
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Focus Mode Active** | `binary_sensor` | `true` when any Focus mode is active |
| **Focus Mode Name** | `sensor` | Current Focus profile (*Work*, *Personal*, *Sleep*, *Off*) |

### Battery and Power
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Battery Level** | `sensor` | Internal battery percentage (%) |
| **Battery Charging** | `binary_sensor` | `true` when plugged in and charging |
| **Battery State** | `sensor` | Charging, Discharging, or AC Power |
| **Power Source** | `sensor` | AC Power vs. Battery |

### Remote Controls
| Entity | Type | Action / Trigger |
| :--- | :--- | :--- |
| **Sleep Mac** | `button` | Puts Mac to sleep via `pmset sleepnow` |
| **Lock Screen** | `button` | Locks screen and sleeps displays |
| **Mute Audio** | `switch` | Toggles system output volume mute on/off |

---

## Installation and Setup

### 1. Download and Install
Download `Mac2MQTT.dmg` from [Releases](https://github.com/PinkPlastic/Mac2MQTT/releases), open the disk image, and drag **Mac2MQTT** into your **Applications** folder.

### 2. Permissions (Initial Launch)
Open **Preferences -> Permissions**:
1. **Full Disk Access**: Click **Open Settings** and enable `Mac2MQTT` to allow Focus mode tracking.
2. **Location Services**: Click **Grant Permission** to allow reading local Wi-Fi SSID.

### 3. Configure MQTT Connection
In **Preferences -> Connection**:
1. Enter your MQTT Broker host (e.g. `192.168.1.50` or `homeassistant.local`) and Port (`1883` or `8883` for TLS).
2. Enter your MQTT credentials (if authentication is enabled).
3. Click **Done**.

Home Assistant will detect the device and entities automatically.

---

## Building from Source

Requirements: macOS 13+, Xcode 15+ (or Command Line Tools), Swift 5.9+.

```bash
# Clone the repository
git clone https://github.com/PinkPlastic/Mac2MQTT.git
cd Mac2MQTT

# Build the application bundle
./bundle.sh

# Build the release DMG installer
./create_dmg.sh
```

---

## License

This project is licensed under the [MIT License](LICENSE).
