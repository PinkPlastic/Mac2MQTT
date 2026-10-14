# StateBeacon

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/architecture-Universal%20(Apple%20Silicon%20%2F%20Intel)-purple.svg)]()
[![Integration](https://img.shields.io/badge/Home%20Assistant-MQTT%20Discovery-orange.svg)](https://www.home-assistant.io/integrations/mqtt/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Native macOS menu bar agent that sends system telemetry, Focus mode state, and controls to Home Assistant via either **MQTT Discovery (LAN)** or native **Home Assistant Webhook (WAN / Brokerless)**.

Built in pure Swift with AppKit and Darwin APIs, StateBeacon runs as an accessory process without a Dock icon, web views, or WebKit overhead.

---

## Key Features

* **Dual Connection Modes**: Choose between high-performance local **MQTT Discovery** (LAN) or native **Home Assistant Webhooks (WAN)** with zero broker required (works through Nabu Casa, Cloudflare Tunnels, and reverse proxies).
* **Event-Driven Updates**: Uses kernel vnode file watchers and Darwin notifications to dispatch Focus Mode, frontmost app, and display changes to Home Assistant in under 50 ms.
* **Audio and Camera Detection**: Uses CoreAudio and CoreMediaIO hardware listeners to report active microphone and webcam streaming state.
* **Remote Control Endpoints**: Provides Home Assistant controls to sleep the Mac (`button`), lock the screen (`button`), or toggle system audio mute (`switch`), receiving commands in real time over MQTT or persistent WebSocket.
* **Entity Pruning**: Unchecking sensors in Preferences prunes or disables them in Home Assistant, keeping your entity registry clean.
* **Low Resource Usage**: Uses 25 MB to 45 MB of RAM and under 0.1% idle CPU.
* **Accessory Mode**: Runs exclusively from the menu bar (`.accessory`); dismisses the Dock icon when preferences are closed.

---

## Comparison

| Feature / Metric | StateBeacon (macOS) | Legacy mac2mqtt (Go) | Official HA Companion (macOS) | HASS.Agent 2 (Windows) |
| :--- | :--- | :--- | :--- | :--- |
| **Platform** | macOS 13+ (Ventura, Sonoma, Sequoia, Golden Gate) | macOS (Intel / Apple Silicon) | macOS 11+ (Intel / Apple Silicon) | Windows 10 & 11 (x64 / ARM64) |
| **Tech Stack** | Native Swift (AppKit + Darwin) | Go (Headless CLI daemon) | Mac Catalyst (iOS UIKit + WebKit) | .NET 8 / C# (WPF + Win32) |
| **UI Mode** | Menu bar daemon (No dock icon) | None (Terminal / LaunchAgent) | Application (Dock icon) | System tray icon |
| **Installer Size** | < 1 MB DMG | Source / manual binary | 120 MB - 180 MB | 60 MB - 95 MB (.msi) |
| **Memory (RAM)** | 25 MB - 45 MB | Unbounded (Known memory leaks) | 250 MB - 650 MB (WebKit processes) | 75 MB - 140 MB |
| **Dependencies** | Zero (Pure native APIs) | Requires npm, BetterDisplay CLI | Zero | Zero |
| **Primary Protocol** | **Dual**: MQTT (TCP/TLS) + HA Webhook (WAN) | MQTT socket (YAML config) | HTTP Webhooks API | MQTT Discovery + Local REST |
| **Sensor Depth** | 41 hardware, peripheral & privacy entities | 4 to 7 basic sensors | Fixed mobile sensors | 30+ sensors & controls |
| **Hardware Privacy** | CoreAudio / CoreMediaIO listeners | Not supported | AVFoundation polling | Windows Privacy Registry |
| **Focus Mode Latency** | < 50 ms (Kernel vnode) | Not supported | 30s - 120s (Polling) | Windows Focus Assist API |
| **Frontmost App** | Immediate (NSWorkspace event) | Not supported | Delayed polling | Immediate hook |
| **Permissions (TCC)** | Status checks + auto-activation | None (Silent failures) | System prompt | Windows UAC |
| **Entity Pruning** | Yes (Removed from registry) | No (Orphaned entities) | No (Static discovery) | Configurable |

---

## Supported Sensors and Controls

All entities register under a single consolidated Device in Home Assistant (**Settings -> Devices & Services -> MQTT**):

### Audio and Video
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Audio Input** | `sensor` | Connected microphone name & streaming in-use attribute |
| **Audio Output** | `sensor` | Connected audio output device, volume & playback status |
| **Master Volume** | `sensor` | Default output volume percentage (0–100%) |
| **Audio Muted** | `binary_sensor` | Indicates whether macOS master output volume is muted |
| **Camera In-Use** | `binary_sensor` | Active camera / webcam stream detection |
| **Active Camera Name** | `sensor` | Connected camera name (e.g. *FaceTime HD Camera*, *Logitech Brio*) |

### Peripherals and Hardware (Phase 2 Parity)
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Active Window Title** | `sensor` | Focused application window title |
| **GPU Load** | `sensor` | Live GPU core utilization percentage (%) |
| **Thermal State** | `sensor` | macOS thermal pressure (*Nominal*, *Fair*, *Serious*, *Critical*) |
| **Bluetooth Devices** | `sensor` | Count of connected Bluetooth Classic devices + JSON attributes |
| **Bluetooth LE Devices** | `sensor` | Count of connected Bluetooth Low Energy devices + JSON attributes |

### System, Session and Presence
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Frontmost App** | `sensor` | Currently focused application name |
| **User Active** | `binary_sensor` | `true` if mouse or keyboard active within the last 2 minutes |
| **Idle Seconds** | `sensor` | Seconds since last user hardware input |
| **Last Active** | `sensor` | Timestamp of last user hardware interaction |
| **Last Boot** | `sensor` | Timestamp when the macOS system last booted |
| **Session State** | `sensor` | Current session lock status (*Locked* or *Unlocked*) |
| **Last System State Change** | `sensor` | Most recent system event (*Suspend*, *Resume*, *SessionLock*, *SessionUnlock*) |
| **Logged User** | `sensor` | Currently active console username |
| **Logged Users** | `sensor` | JSON list of all active logged-in user accounts |
| **Monitor Power State** | `sensor` | Display sleep/wake status (*PowerOn* vs. *DisplaySleep*) |
| **Accent Color** | `sensor` | System UI accent color hex code (e.g. `#007AFF`) |
| **CPU Clock Speed** | `sensor` | Processor clock frequency in MHz |
| **CPU Usage** | `sensor` | Processor load percentage (%) |
| **Memory Usage** | `sensor` | System RAM usage percentage (%) |
| **Connected Displays** | `sensor` | Count of active external and built-in screens |
| **Primary Display ID** | `sensor` | Display identifier for the main monitor |
| **App Version** | `sensor` | Installed StateBeacon version |

### Network, Location and Wi-Fi
| Entity | Type | Description |
| :--- | :--- | :--- |
| **Wi-Fi SSID** | `sensor` | Connected Wi-Fi network name |
| **Wi-Fi BSSID** | `sensor` | Access Point MAC address |
| **Connection Type** | `sensor` | Network interface type (*Wi-Fi* or *Ethernet*) |
| **Geo Location** | `sensor` | Current GPS coordinates (*latitude,longitude,altitude*) |

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
Download `StateBeacon.dmg` from [Releases](https://github.com/PinkPlastic/StateBeacon/releases), open the disk image, and drag **StateBeacon** into your **Applications** folder.

### 2. Permissions (Initial Launch)
Open **Preferences -> Permissions**:
1. **Full Disk Access**: Click **Open Settings** and enable `StateBeacon` to allow Focus mode tracking.
2. **Location Services**: Click **Grant Permission** to allow reading local Wi-Fi SSID.

### 3. Choose Connection Mode
Open **Preferences -> Connection** and select your preferred communication protocol:

#### Option A: Home Assistant Webhook (WAN / Brokerless)
*Works seamlessly from anywhere without port forwarding, extra VPNs, or self-hosted brokers (supports Nabu Casa Cloud, Cloudflare Tunnels, and direct HTTPS).*
1. Select **Home Assistant Webhook (WAN)**.
2. Enter your **Home Assistant URL** (e.g. `https://my-ha.ui.nabu.casa` or `https://ha.mydomain.com`).
3. Generate a **Long-Lived Access Token** in Home Assistant (**Profile -> Long-Lived Access Tokens**) and paste it into the field.
4. Click **Register & Test Connection**. StateBeacon automatically provisions the device and sensors in Home Assistant and saves your assigned `webhook_id`.
5. Keep **Enable Remote Commands via WebSocket** checked if you want real-time sleep, lock, and mute controls from Home Assistant over WAN.

#### Option B: MQTT Broker (LAN)
*Ultra-low latency (<10 ms), lightweight raw TCP/TLS socket over your local home network.*
1. Select **MQTT Broker (LAN)**.
2. Enter your MQTT Broker host (e.g. `192.168.1.50` or `homeassistant.local`) and Port (`1883` or `8883` for TLS).
3. Enter your MQTT credentials (if authentication is enabled).
4. Click **Done**.

---

### Remote Controls via WAN / Webhook
When using the Home Assistant Webhook mode with WebSocket enabled:
1. **Auto-Provisioned Native Scripts**: StateBeacon automatically provisions native Home Assistant scripts linked directly under the Mac's Device page in Home Assistant (**Related** card):
   - `script.statebeacon_<device_id>_sleep`: Sleep Mac
   - `script.statebeacon_<device_id>_lock_screen`: Lock Screen & Display
   - `script.statebeacon_<device_id>_mute_audio`: Toggle Mute System Audio
   These scripts can be triggered via standard Home Assistant dashboard button cards, voice assistants, or automations with zero manual YAML setup.

2. **Custom Event Automation**:
```yaml
action: event.fire
data:
  event_type: statebeacon_command
  event_data:
    command: "sleep"        # or lock_screen, mute_audio, unmute
    device_id: "mac_my_mac" # target identifier
```

3. **Native Mobile App Notify Command:**
```yaml
action: notify.mobile_app_my_mac
data:
  message: "command_sleep"  # or command_lock, command_mute, command_unmute
```

## Building from Source

Requirements: macOS 13+, Xcode 15+ (or Command Line Tools), Swift 5.9+.

```bash
# Clone the repository
git clone https://github.com/PinkPlastic/StateBeacon.git
cd StateBeacon

# Build the application bundle
./bundle.sh

# Build the release DMG installer
./create_dmg.sh
```

---

## License

This project is licensed under the [MIT License](LICENSE).
