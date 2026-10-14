import Foundation

public final class HADiscovery: @unchecked Sendable {
    private let client: MQTTClient
    private let config: AppConfig
    private let baseTopic: String
    private let statusTopic: String

    public init(client: MQTTClient, config: AppConfig) {
        self.client = client
        self.config = config
        self.baseTopic = "homeassistant/device/\(config.deviceId)"
        self.statusTopic = "\(baseTopic)/status"
    }

    public func publishDiscoveryAndSubscribe() {
        let deviceDict: [String: Any] = [
            "identifiers": [config.deviceId],
            "name": config.deviceName,
            "model": "Mac (\(ProcessInfo.processInfo.operatingSystemVersionString))",
            "manufacturer": "Apple",
            "sw_version": "1.1.0"
        ]

        let stateTopic = "\(baseTopic)/state"

        func publishEntity(domain: String, objectId: String, payload: [String: Any]) {
            let topic = "homeassistant/\(domain)/\(config.deviceId)/\(objectId)/config"
            guard config.isSensorEnabled(objectId) && PreferencesWindowController.isSensorPermitted(objectId) else {
                // Remove disabled/unpermitted entity from Home Assistant
                client.publish(topic: topic, payload: Data(), retain: true, qos: 1)
                return
            }

            var fullPayload = payload
            fullPayload["device"] = deviceDict
            fullPayload["availability"] = [
                ["topic": statusTopic]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: fullPayload, options: []) {
                client.publish(topic: topic, payload: data, retain: true, qos: 1)
            }
        }

        // Cleanup obsolete/duplicate entities from prior versions in Home Assistant
        let obsoleteTopics = [
            "homeassistant/sensor/\(config.deviceId)/display_count/config",
            "homeassistant/binary_sensor/\(config.deviceId)/battery_charging/config",
            "homeassistant/sensor/\(config.deviceId)/battery_level/config",
            "homeassistant/binary_sensor/\(config.deviceId)/user_active/config",
            "homeassistant/binary_sensor/\(config.deviceId)/audio_input_in_use/config",
            "homeassistant/sensor/\(config.deviceId)/active_audio_input/config",
            "homeassistant/binary_sensor/\(config.deviceId)/audio_output_in_use/config",
            "homeassistant/sensor/\(config.deviceId)/active_audio_output/config"
        ]
        for topic in obsoleteTopics {
            client.publish(topic: topic, payload: Data(), retain: true, qos: 1)
        }

        // 1. Binary Sensors
        publishEntity(domain: "binary_sensor", objectId: "active", payload: [
            "name": "Active",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_user_active }}",
            "payload_on": true,
            "payload_off": false,
            "icon": "mdi:monitor",
            "unique_id": "\(config.deviceId)_active"
        ])

        publishEntity(domain: "binary_sensor", objectId: "audio_muted", payload: [
            "name": "Audio Muted",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_audio_muted }}",
            "payload_on": true,
            "payload_off": false,
            "icon": "mdi:volume-mute",
            "unique_id": "\(config.deviceId)_audio_muted"
        ])

        publishEntity(domain: "binary_sensor", objectId: "camera_in_use", payload: [
            "name": "Camera In Use",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_camera_in_use }}",
            "payload_on": true,
            "payload_off": false,
            "icon": "mdi:camera",
            "unique_id": "\(config.deviceId)_camera_in_use"
        ])

        publishEntity(domain: "binary_sensor", objectId: "focus", payload: [
            "name": "Focus",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_focus_active }}",
            "payload_on": true,
            "payload_off": false,
            "icon": "mdi:moon-waning-crescent",
            "unique_id": "\(config.deviceId)_focus"
        ])

        publishEntity(domain: "sensor", objectId: "focus_mode", payload: [
            "name": "Focus Mode",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.focus_mode }}",
            "icon": "mdi:moon-waning-crescent",
            "unique_id": "\(config.deviceId)_focus_mode"
        ])

        publishEntity(domain: "binary_sensor", objectId: "internal_battery_charging", payload: [
            "name": "Battery Charging",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_charging }}",
            "payload_on": true,
            "payload_off": false,
            "device_class": "battery_charging",
            "unique_id": "\(config.deviceId)_internal_battery_charging"
        ])

        // 2. Standard Sensors
        publishEntity(domain: "sensor", objectId: "frontmost_app", payload: [
            "name": "Frontmost App",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.frontmost_app }}",
            "icon": "mdi:application",
            "unique_id": "\(config.deviceId)_frontmost_app"
        ])

        publishEntity(domain: "sensor", objectId: "idle_time", payload: [
            "name": "Idle Seconds",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.idle_seconds }}",
            "unit_of_measurement": "s",
            "state_class": "measurement",
            "icon": "mdi:timer-outline",
            "unique_id": "\(config.deviceId)_idle_time"
        ])

        publishEntity(domain: "sensor", objectId: "audio_output", payload: [
            "name": "Audio Output",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.active_audio_output }}",
            "json_attributes_topic": stateTopic,
            "json_attributes_template": "{{ {'in_use': value_json.is_audio_output_in_use, 'volume': value_json.current_volume, 'muted': value_json.is_audio_muted} | to_json }}",
            "icon": "mdi:headphones",
            "unique_id": "\(config.deviceId)_audio_output"
        ])

        publishEntity(domain: "sensor", objectId: "audio_input", payload: [
            "name": "Audio Input",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.active_audio_input }}",
            "json_attributes_topic": stateTopic,
            "json_attributes_template": "{{ {'in_use': value_json.is_mic_in_use} | to_json }}",
            "icon": "mdi:microphone-outline",
            "unique_id": "\(config.deviceId)_audio_input"
        ])

        publishEntity(domain: "sensor", objectId: "active_camera", payload: [
            "name": "Active Camera",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.active_camera }}",
            "icon": "mdi:webcam",
            "unique_id": "\(config.deviceId)_active_camera"
        ])

        publishEntity(domain: "sensor", objectId: "internal_battery_level", payload: [
            "name": "Internal Battery Level",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.battery_level }}",
            "unit_of_measurement": "%",
            "device_class": "battery",
            "state_class": "measurement",
            "unique_id": "\(config.deviceId)_internal_battery_level"
        ])

        publishEntity(domain: "sensor", objectId: "internal_battery_state", payload: [
            "name": "Internal Battery State",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.battery_state }}",
            "icon": "mdi:battery-heart",
            "unique_id": "\(config.deviceId)_internal_battery_state"
        ])

        publishEntity(domain: "sensor", objectId: "power_source", payload: [
            "name": "Power Source",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.power_source }}",
            "icon": "mdi:power-plug",
            "unique_id": "\(config.deviceId)_power_source"
        ])

        publishEntity(domain: "sensor", objectId: "displays", payload: [
            "name": "Displays",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.display_count }}",
            "icon": "mdi:monitor-multiple",
            "unique_id": "\(config.deviceId)_displays"
        ])

        publishEntity(domain: "sensor", objectId: "primary_display_id", payload: [
            "name": "Primary Display ID",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.primary_display_id }}",
            "icon": "mdi:monitor-star",
            "unique_id": "\(config.deviceId)_primary_display_id"
        ])

        publishEntity(domain: "sensor", objectId: "connection_type", payload: [
            "name": "Connection Type",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.connection_type }}",
            "icon": "mdi:network",
            "unique_id": "\(config.deviceId)_connection_type"
        ])

        publishEntity(domain: "sensor", objectId: "wifi_ssid", payload: [
            "name": "Wi-Fi SSID",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.wifi_ssid }}",
            "icon": "mdi:wifi",
            "unique_id": "\(config.deviceId)_wifi_ssid"
        ])

        publishEntity(domain: "sensor", objectId: "bssid", payload: [
            "name": "BSSID",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.wifi_bssid }}",
            "icon": "mdi:access-point",
            "unique_id": "\(config.deviceId)_bssid"
        ])

        publishEntity(domain: "sensor", objectId: "last_update_trigger", payload: [
            "name": "Last Update Trigger",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.last_update_trigger }}",
            "icon": "mdi:update",
            "unique_id": "\(config.deviceId)_last_update_trigger"
        ])

        publishEntity(domain: "sensor", objectId: "app_version", payload: [
            "name": "App Version",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.app_version }}",
            "icon": "mdi:tag-outline",
            "unique_id": "\(config.deviceId)_app_version"
        ])

        publishEntity(domain: "sensor", objectId: "cpu_usage", payload: [
            "name": "CPU Usage",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.cpu_usage }}",
            "unit_of_measurement": "%",
            "state_class": "measurement",
            "icon": "mdi:cpu-64-bit",
            "unique_id": "\(config.deviceId)_cpu_usage"
        ])

        publishEntity(domain: "sensor", objectId: "memory_usage", payload: [
            "name": "Memory Usage",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.memory_usage }}",
            "unit_of_measurement": "%",
            "state_class": "measurement",
            "icon": "mdi:memory",
            "unique_id": "\(config.deviceId)_memory_usage"
        ])

        // Phase 1 HASS.Agent Parity Sensors
        publishEntity(domain: "sensor", objectId: "last_boot", payload: [
            "name": "Last Boot",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.last_boot }}",
            "device_class": "timestamp",
            "icon": "mdi:clock-time-three-outline",
            "unique_id": "\(config.deviceId)_last_boot"
        ])

        publishEntity(domain: "sensor", objectId: "last_active", payload: [
            "name": "Last Active",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.last_active }}",
            "device_class": "timestamp",
            "icon": "mdi:clock-time-three-outline",
            "unique_id": "\(config.deviceId)_last_active"
        ])

        publishEntity(domain: "sensor", objectId: "session_state", payload: [
            "name": "Session State",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.session_state }}",
            "icon": "mdi:lock",
            "unique_id": "\(config.deviceId)_session_state"
        ])

        publishEntity(domain: "sensor", objectId: "last_system_state_change", payload: [
            "name": "Last System State Change",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.last_system_state_change }}",
            "icon": "mdi:cog",
            "unique_id": "\(config.deviceId)_last_system_state_change"
        ])

        publishEntity(domain: "sensor", objectId: "logged_user", payload: [
            "name": "Logged User",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.logged_user }}",
            "icon": "mdi:account",
            "unique_id": "\(config.deviceId)_logged_user"
        ])

        publishEntity(domain: "sensor", objectId: "logged_users", payload: [
            "name": "Logged Users",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.logged_users }}",
            "icon": "mdi:account-group",
            "unique_id": "\(config.deviceId)_logged_users"
        ])

        publishEntity(domain: "sensor", objectId: "current_volume", payload: [
            "name": "Current Volume",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.current_volume }}",
            "unit_of_measurement": "%",
            "state_class": "measurement",
            "icon": "mdi:volume-medium",
            "unique_id": "\(config.deviceId)_current_volume"
        ])

        publishEntity(domain: "sensor", objectId: "accent_color", payload: [
            "name": "Accent Color",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.accent_color }}",
            "icon": "mdi:palette",
            "unique_id": "\(config.deviceId)_accent_color"
        ])

        publishEntity(domain: "sensor", objectId: "monitor_power_state", payload: [
            "name": "Monitor Power State",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.monitor_power_state }}",
            "icon": "mdi:monitor",
            "unique_id": "\(config.deviceId)_monitor_power_state"
        ])

        publishEntity(domain: "sensor", objectId: "current_clock_speed", payload: [
            "name": "Current Clock Speed",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.current_clock_speed }}",
            "unit_of_measurement": "MHz",
            "device_class": "frequency",
            "state_class": "measurement",
            "icon": "mdi:speedometer",
            "unique_id": "\(config.deviceId)_current_clock_speed"
        ])

        // Phase 2 HASS.Agent Parity Sensors
        publishEntity(domain: "sensor", objectId: "bluetooth_devices", payload: [
            "name": "Bluetooth Devices",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.bluetooth_devices }}",
            "json_attributes_topic": stateTopic,
            "json_attributes_template": "{{ value_json.bluetooth_devices_list }}",
            "state_class": "measurement",
            "icon": "mdi:bluetooth",
            "unique_id": "\(config.deviceId)_bluetooth_devices"
        ])

        publishEntity(domain: "sensor", objectId: "bluetooth_le_devices", payload: [
            "name": "Bluetooth LE Devices",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.bluetooth_le_devices }}",
            "json_attributes_topic": stateTopic,
            "json_attributes_template": "{{ value_json.bluetooth_le_devices_list }}",
            "state_class": "measurement",
            "icon": "mdi:bluetooth-connect",
            "unique_id": "\(config.deviceId)_bluetooth_le_devices"
        ])

        publishEntity(domain: "sensor", objectId: "internal_device", payload: [
            "name": "Thermal State",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.thermal_state }}",
            "icon": "mdi:thermometer-alert",
            "unique_id": "\(config.deviceId)_internal_device"
        ])

        publishEntity(domain: "sensor", objectId: "gpu_load", payload: [
            "name": "GPU Load",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.gpu_load }}",
            "unit_of_measurement": "%",
            "state_class": "measurement",
            "icon": "mdi:expansion-card",
            "unique_id": "\(config.deviceId)_gpu_load"
        ])

        publishEntity(domain: "sensor", objectId: "geo_location", payload: [
            "name": "Geo Location",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.geo_location }}",
            "icon": "mdi:earth",
            "unique_id": "\(config.deviceId)_geo_location"
        ])

        publishEntity(domain: "sensor", objectId: "active_window", payload: [
            "name": "Active Window",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.active_window }}",
            "icon": "mdi:window-maximize",
            "unique_id": "\(config.deviceId)_active_window"
        ])

        // 3. Remote Commands
        publishEntity(domain: "button", objectId: "sleep", payload: [
            "name": "Sleep Mac",
            "command_topic": "\(baseTopic)/command/sleep",
            "payload_press": "PRESS",
            "icon": "mdi:power-sleep",
            "unique_id": "\(config.deviceId)_btn_sleep"
        ])

        publishEntity(domain: "button", objectId: "lock_screen", payload: [
            "name": "Lock Screen",
            "command_topic": "\(baseTopic)/command/lock_screen",
            "payload_press": "PRESS",
            "icon": "mdi:lock",
            "unique_id": "\(config.deviceId)_btn_lock"
        ])

        publishEntity(domain: "switch", objectId: "mute_audio", payload: [
            "name": "Mute Audio",
            "state_topic": stateTopic,
            "value_template": "{{ value_json.is_audio_muted }}",
            "command_topic": "\(baseTopic)/command/mute_audio",
            "payload_on": "ON",
            "payload_off": "OFF",
            "state_on": true,
            "state_off": false,
            "icon": "mdi:volume-mute",
            "unique_id": "\(config.deviceId)_sw_mute"
        ])

        // Subscribe to command topics
        client.subscribe(topic: "\(baseTopic)/command/+")

        // Send Status Online
        client.publishString(topic: statusTopic, string: "online", retain: true, qos: 1)
    }

    public func publishState(snapshot: SensorSnapshot) {
        let stateTopic = "\(baseTopic)/state"
        let stateDict: [String: Any] = [
            "frontmost_app": snapshot.frontmostApp,
            "is_user_active": snapshot.isUserActive,
            "idle_seconds": snapshot.idleSeconds,
            "battery_level": snapshot.batteryLevel,
            "is_charging": snapshot.isCharging,
            "battery_state": snapshot.batteryState,
            "power_source": snapshot.powerSource,
            "is_mic_in_use": snapshot.isMicInUse,
            "is_audio_output_in_use": snapshot.isAudioOutputInUse,
            "is_camera_in_use": snapshot.isCameraInUse,
            "active_audio_output": snapshot.activeAudioOutput,
            "active_audio_input": snapshot.activeAudioInput,
            "active_camera": snapshot.activeCamera,
            "display_count": snapshot.displayCount,
            "primary_display_id": snapshot.primaryDisplayId,
            "wifi_ssid": snapshot.wifiSSID,
            "wifi_bssid": snapshot.wifiBSSID,
            "connection_type": snapshot.connectionType,
            "focus_mode": snapshot.focusMode,
            "is_focus_active": snapshot.isFocusActive,
            "cpu_usage": round(snapshot.cpuUsagePercent * 10) / 10.0,
            "memory_usage": round(snapshot.memoryUsagePercent * 10) / 10.0,
            "is_audio_muted": snapshot.isAudioMuted,
            "last_update_trigger": snapshot.lastUpdateTrigger,
            "app_version": snapshot.appVersion,
            "last_boot": snapshot.lastBoot,
            "last_active": snapshot.lastActive,
            "session_state": snapshot.sessionState,
            "last_system_state_change": snapshot.lastSystemStateChange,
            "logged_user": snapshot.loggedUser,
            "logged_users": snapshot.loggedUsers,
            "current_volume": snapshot.currentVolume,
            "accent_color": snapshot.accentColor,
            "monitor_power_state": snapshot.monitorPowerState,
            "current_clock_speed": snapshot.currentClockSpeed,
            "bluetooth_devices": snapshot.bluetoothDevicesCount,
            "bluetooth_devices_list": snapshot.bluetoothDevicesJson,
            "bluetooth_le_devices": snapshot.bluetoothLeDevicesCount,
            "bluetooth_le_devices_list": snapshot.bluetoothLeDevicesJson,
            "thermal_state": snapshot.thermalState,
            "gpu_load": round(snapshot.gpuUsagePercent * 10) / 10.0,
            "geo_location": snapshot.geoLocation,
            "active_window": snapshot.activeWindowTitle
        ]

        if let data = try? JSONSerialization.data(withJSONObject: stateDict, options: []) {
            client.publish(topic: stateTopic, payload: data, retain: false, qos: 0)
        }
    }

    public func handleCommand(topic: String, message: String) {
        if topic.hasSuffix("/command/sleep") {
            guard config.isSensorEnabled("sleep") else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            try? process.run()
        } else if topic.hasSuffix("/command/lock_screen") {
            guard config.isSensorEnabled("lock_screen") else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        } else if topic.hasSuffix("/command/mute_audio") {
            guard config.isSensorEnabled("mute_audio") else { return }
            let mute = (message.uppercased() == "ON" || message == "true" || message == "1")
            let script = "set volume output muted \(mute)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }
}
