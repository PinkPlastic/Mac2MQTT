import Testing
import Foundation
@testable import StateBeacon

@Suite("StateBeacon Sensor & Configuration Tests")
struct StateBeaconTests {
    @Test("Phase 1 Sensor Snapshot Collection")
    func testSensorSnapshotPhase1() async throws {
        let manager = SensorManager()
        let snapshot = manager.collectSnapshot(trigger: "UnitTest")

        // 1. Last Boot & Last Active ISO 8601 timestamps
        #expect(!snapshot.lastBoot.isEmpty)
        #expect(snapshot.lastBoot.contains("T"))
        #expect(!snapshot.lastActive.isEmpty)
        #expect(snapshot.lastActive.contains("T"))

        // 2. Session State & System State Change
        #expect(snapshot.sessionState == "Locked" || snapshot.sessionState == "Unlocked")
        #expect(!snapshot.lastSystemStateChange.isEmpty)

        // 3. User Detection
        #expect(!snapshot.loggedUser.isEmpty)
        #expect(!snapshot.loggedUsers.isEmpty)
        #expect(snapshot.loggedUsers.contains(snapshot.loggedUser))

        // 4. Audio Volume
        #expect(snapshot.currentVolume >= 0 && snapshot.currentVolume <= 100)

        // 5. Accent Color Hex
        #expect(snapshot.accentColor.hasPrefix("#"))
        #expect(snapshot.accentColor.count == 7)

        // 6. Monitor Power State
        #expect(snapshot.monitorPowerState == "PowerOn" || snapshot.monitorPowerState == "DisplaySleep")

        // 7. Clock Speed
        #expect(snapshot.currentClockSpeed > 0)
    }

    @Test("Phase 2 Sensor Snapshot Collection")
    func testSensorSnapshotPhase2() async throws {
        let manager = SensorManager()
        let snapshot = manager.collectSnapshot(trigger: "UnitTestPhase2")

        // 1. GPU Utilization
        #expect(snapshot.gpuUsagePercent >= 0.0 && snapshot.gpuUsagePercent <= 100.0)

        // 2. Thermal State
        let validStates = ["Nominal", "Fair", "Serious", "Critical"]
        #expect(validStates.contains(snapshot.thermalState))

        // 3. Bluetooth Classic & LE
        #expect(snapshot.bluetoothDevicesCount >= 0)
        #expect(snapshot.bluetoothDevicesJson.hasPrefix("["))
        #expect(snapshot.bluetoothLeDevicesCount >= 0)
        #expect(snapshot.bluetoothLeDevicesJson.hasPrefix("["))

        // 4. Active Window Title
        #expect(!snapshot.activeWindowTitle.isEmpty)

        // 5. Geolocation
        #expect(!snapshot.geoLocation.isEmpty)
    }

    @Test("Available Sensors Registry")
    func testAvailableSensorsList() async throws {
        let sensors = PreferencesWindowController.availableSensors
        #expect(sensors.count == 41)

        let paritySensorIds = [
            // Phase 1
            "last_boot", "last_active", "session_state", "last_system_state_change",
            "logged_user", "logged_users", "current_volume", "accent_color",
            "monitor_power_state", "current_clock_speed",
            // Phase 2
            "active_window", "gpu_load", "internal_device",
            "bluetooth_devices", "bluetooth_le_devices", "geo_location",
            // Consolidated & New
            "audio_input", "audio_output", "idle_time", "audio_muted"
        ]

        for id in paritySensorIds {
            #expect(sensors.contains { $0.id == id }, "Missing sensor definition: \(id)")
        }

        // Verify duplicates are removed
        #expect(!sensors.contains { $0.id == "audio_input_in_use" })
        #expect(!sensors.contains { $0.id == "audio_output_in_use" })

        // Verify required permissions
        let btClassic = sensors.first { $0.id == "bluetooth_devices" }
        #expect(btClassic?.requiredPermission == .bluetooth)
        let btLe = sensors.first { $0.id == "bluetooth_le_devices" }
        #expect(btLe?.requiredPermission == .bluetooth)
        let geo = sensors.first { $0.id == "geo_location" }
        #expect(geo?.requiredPermission == .location)
        let activeWin = sensors.first { $0.id == "active_window" }
        #expect(activeWin?.requiredPermission == .accessibility)
    }

    @Test("Sensor Enable / Disable Configuration")
    func testSensorToggles() async throws {
        var config = AppConfig.defaultConfig
        #expect(config.isSensorEnabled("last_boot") == true)
        #expect(config.isSensorEnabled("gpu_load") == true)

        config.setSensorEnabled("last_boot", enabled: false)
        #expect(config.isSensorEnabled("last_boot") == false)

        config.setSensorEnabled("last_boot", enabled: true)
        #expect(config.isSensorEnabled("last_boot") == true)

        config.setSensorEnabled("gpu_load", enabled: false)
        #expect(config.isSensorEnabled("gpu_load") == false)
    }
}
