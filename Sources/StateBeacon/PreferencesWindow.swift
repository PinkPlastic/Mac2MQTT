import AppKit
import CoreLocation
import CoreBluetooth

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PreferencesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let chars = event.charactersIgnoringModifiers?.lowercased()
            switch chars {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
                }
                if let fieldEditor = self.firstResponder as? NSTextView {
                    fieldEditor.paste(self)
                    return true
                }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) {
                    return true
                }
                if let fieldEditor = self.firstResponder as? NSTextView {
                    fieldEditor.copy(self)
                    return true
                }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) {
                    return true
                }
                if let fieldEditor = self.firstResponder as? NSTextView {
                    fieldEditor.cut(self)
                    return true
                }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) {
                    return true
                }
                if let fieldEditor = self.firstResponder as? NSTextView {
                    fieldEditor.selectAll(self)
                    return true
                }
            case "z":
                if event.modifierFlags.contains(.shift) {
                    if let undoManager = self.undoManager, undoManager.canRedo {
                        undoManager.redo()
                        return true
                    }
                } else {
                    if let undoManager = self.undoManager, undoManager.canUndo {
                        undoManager.undo()
                        return true
                    }
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    public enum Tab: Int {
        case connection = 0
        case sensors = 1
        case permissions = 2
    }

    public enum RequiredPermission: String, Sendable {
        case none
        case fullDiskAccess
        case location
        case bluetooth
        case accessibility
    }

    public struct SensorDefinition: Sendable {
        public let id: String
        public let name: String
        public let category: String
        public let desc: String
        public let requiredPermission: RequiredPermission

        public init(id: String, name: String, category: String, desc: String, requiredPermission: RequiredPermission = .none) {
            self.id = id
            self.name = name
            self.category = category
            self.desc = desc
            self.requiredPermission = requiredPermission
        }
    }

    nonisolated public static let availableSensors: [SensorDefinition] = [
        // System & Activity
        SensorDefinition(id: "frontmost_app", name: "Frontmost Application", category: "System & Activity", desc: "Current foreground app name"),
        SensorDefinition(id: "active_window", name: "Active Window Title", category: "System & Activity", desc: "Title of the currently focused application window", requiredPermission: .accessibility),
        SensorDefinition(id: "active", name: "User Active / Idle", category: "System & Activity", desc: "User presence detection (Active / Idle)"),
        SensorDefinition(id: "idle_time", name: "User Idle Time (s)", category: "System & Activity", desc: "Seconds since last keyboard or mouse interaction"),
        SensorDefinition(id: "cpu_usage", name: "CPU Usage (%)", category: "System & Activity", desc: "Overall CPU load percentage"),
        SensorDefinition(id: "memory_usage", name: "Memory Usage (%)", category: "System & Activity", desc: "RAM usage percentage"),
        SensorDefinition(id: "current_clock_speed", name: "CPU Clock Speed (MHz)", category: "System & Activity", desc: "Processor core frequency in MHz"),
        SensorDefinition(id: "displays", name: "Displays Count", category: "System & Activity", desc: "Total connected displays"),
        SensorDefinition(id: "primary_display_id", name: "Primary Display ID", category: "System & Activity", desc: "Main display identifier"),
        SensorDefinition(id: "monitor_power_state", name: "Monitor Power State", category: "System & Activity", desc: "Display sleep/wake status: PowerOn or DisplaySleep"),
        SensorDefinition(id: "session_state", name: "Session Lock State", category: "System & Activity", desc: "Session lock state: Locked or Unlocked"),
        SensorDefinition(id: "last_system_state_change", name: "Last System State Change", category: "System & Activity", desc: "Last power/session event (Suspend, Resume, Lock, Unlock)"),
        SensorDefinition(id: "logged_user", name: "Logged User", category: "System & Activity", desc: "Currently active console user"),
        SensorDefinition(id: "logged_users", name: "Logged Users List", category: "System & Activity", desc: "JSON array of all logged-in user accounts"),
        SensorDefinition(id: "last_active", name: "Last Active Time", category: "System & Activity", desc: "Timestamp of last detected user interaction"),
        SensorDefinition(id: "last_boot", name: "Last Boot Time", category: "System & Activity", desc: "Moment the system last booted (timestamp)"),
        SensorDefinition(id: "accent_color", name: "System Accent Color", category: "System & Activity", desc: "macOS UI accent color in hex (#RRGGBB)"),
        SensorDefinition(id: "app_version", name: "StateBeacon Version", category: "System & Activity", desc: "Client app release version"),

        // Peripherals & Hardware
        SensorDefinition(id: "gpu_load", name: "GPU Usage (%)", category: "Peripherals & Hardware", desc: "Live GPU core utilization percentage"),
        SensorDefinition(id: "internal_device", name: "Thermal Pressure State", category: "Peripherals & Hardware", desc: "System thermal pressure: Nominal, Fair, Serious, Critical"),
        SensorDefinition(id: "bluetooth_devices", name: "Bluetooth Devices", category: "Peripherals & Hardware", desc: "Count of paired and connected Bluetooth Classic devices", requiredPermission: .bluetooth),
        SensorDefinition(id: "bluetooth_le_devices", name: "Bluetooth LE Devices", category: "Peripherals & Hardware", desc: "Count of connected Bluetooth Low Energy devices", requiredPermission: .bluetooth),

        // Audio & Video
        SensorDefinition(id: "audio_input", name: "Audio Input (Microphone)", category: "Audio & Video", desc: "Connected microphone name and streaming in-use state"),
        SensorDefinition(id: "audio_output", name: "Audio Output", category: "Audio & Video", desc: "Connected audio output device and playback state"),
        SensorDefinition(id: "current_volume", name: "Master Audio Volume (%)", category: "Audio & Video", desc: "Default output audio volume level"),
        SensorDefinition(id: "audio_muted", name: "Audio Muted", category: "Audio & Video", desc: "Indicates whether macOS system output audio is currently muted"),
        SensorDefinition(id: "camera_in_use", name: "Camera In-Use", category: "Audio & Video", desc: "Detects active webcam usage"),
        SensorDefinition(id: "active_camera", name: "Active Camera Name", category: "Audio & Video", desc: "Name of the active webcam device"),

        // Battery & Power
        SensorDefinition(id: "internal_battery_level", name: "Battery Level (%)", category: "Battery & Power", desc: "Current battery percentage"),
        SensorDefinition(id: "internal_battery_charging", name: "Battery Charging", category: "Battery & Power", desc: "Indicates whether the battery is currently charging"),
        SensorDefinition(id: "internal_battery_state", name: "Battery State", category: "Battery & Power", desc: "Charging, Discharging, AC Power"),
        SensorDefinition(id: "power_source", name: "Power Source", category: "Battery & Power", desc: "AC Power or Battery"),

        // Network
        SensorDefinition(id: "wifi_ssid", name: "Wi-Fi SSID", category: "Network", desc: "Connected Wi-Fi network name", requiredPermission: .location),
        SensorDefinition(id: "bssid", name: "Wi-Fi BSSID", category: "Network", desc: "Access Point MAC address", requiredPermission: .location),
        SensorDefinition(id: "connection_type", name: "Connection Type", category: "Network", desc: "Wi-Fi or Ethernet"),
        SensorDefinition(id: "geo_location", name: "Geolocation Coordinates", category: "Network", desc: "GPS coordinates (latitude, longitude, altitude)", requiredPermission: .location),

        // Focus Mode
        SensorDefinition(id: "focus", name: "Focus Mode Active", category: "Focus Mode", desc: "Indicates whether Focus or Do Not Disturb is active", requiredPermission: .fullDiskAccess),
        SensorDefinition(id: "focus_mode", name: "Focus Mode Name", category: "Focus Mode", desc: "Current Focus mode: Work, DND, etc.", requiredPermission: .fullDiskAccess),

        // Remote Controls
        SensorDefinition(id: "mute_audio", name: "Mute Audio Switch", category: "Remote Controls", desc: "Allows Home Assistant to mute Mac audio"),
        SensorDefinition(id: "lock_screen", name: "Lock Screen Button", category: "Remote Controls", desc: "Button to immediately sleep displays and lock screen"),
        SensorDefinition(id: "sleep", name: "Sleep Mac Button", category: "Remote Controls", desc: "Button to put Mac to sleep")
    ]

    private var config: AppConfig
    private var window: NSWindow?
    private let onSave: (AppConfig) -> Void

    // Navigation
    private var segmentedControl: NSSegmentedControl!
    private var tabContainerView: NSView!
    private var connectionView: NSView?
    private var sensorsView: NSView?
    private var permissionsView: NSView?

    // Connection Controls
    private var connectionModeSegment: NSSegmentedControl!
    private var mqttContainerView: NSView!
    private var webhookContainerView: NSView!

    // MQTT Fields
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var tlsCheckbox: NSButton!
    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!

    // Webhook Fields
    private var haURLField: NSTextField!
    private var haTokenField: NSSecureTextField!
    private var haWebhookIdField: NSTextField!
    private var haWebSocketCheckbox: NSButton!
    private var haTestButton: NSButton!
    private var haStatusLabel: NSTextField!

    // Shared Device Fields
    private var deviceNameField: NSTextField!
    private var deviceIdField: NSTextField!
    private var intervalField: NSTextField!

    // Sensors Controls
    private var sensorCheckboxes: [String: NSButton] = [:]
    private var sensorSummaryLabel: NSTextField!

    // Permissions Controls
    private var fdaBadgeLabel: NSTextField!
    private var fdaActionButton: NSButton!
    private var locBadgeLabel: NSTextField!
    private var locActionButton: NSButton!
    private var btBadgeLabel: NSTextField!
    private var btActionButton: NSButton!
    private var axBadgeLabel: NSTextField!
    private var axActionButton: NSButton!
    private var liveTimer: Timer?
    private let locationManager = CLLocationManager()
    private var bluetoothManager: CBCentralManager?

    public init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        super.init()
    }

    // MARK: - Permissions Utilities

    nonisolated public static func checkFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let assertionsPath = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json").path
        if FileManager.default.isReadableFile(atPath: assertionsPath) {
            return true
        }
        let dndDir = home.appendingPathComponent("Library/DoNotDisturb/DB").path
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dndDir), !contents.isEmpty {
            return true
        }
        return false
    }

    nonisolated public static func checkLocationPermission() -> CLAuthorizationStatus {
        return CLLocationManager().authorizationStatus
    }

    nonisolated public static func checkBluetoothPermission() -> CBManagerAuthorization {
        return CBManager.authorization
    }

    nonisolated public static func checkAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated public static func isPermissionGranted(for permission: RequiredPermission) -> Bool {
        switch permission {
        case .none:
            return true
        case .fullDiskAccess:
            return checkFullDiskAccess()
        case .location:
            return checkLocationPermission() == .authorizedAlways
        case .bluetooth:
            return checkBluetoothPermission() == .allowedAlways
        case .accessibility:
            return checkAccessibilityPermission()
        }
    }

    nonisolated public static func isSensorPermitted(_ sensorId: String) -> Bool {
        guard let def = availableSensors.first(where: { $0.id == sensorId }) else { return true }
        return isPermissionGranted(for: def.requiredPermission)
    }

    nonisolated public static func isAllPermissionsGranted() -> Bool {
        let fda = checkFullDiskAccess()
        let loc = checkLocationPermission() == .authorizedAlways
        let bt = checkBluetoothPermission() == .allowedAlways
        let ax = checkAccessibilityPermission()
        return fda && loc && bt && ax
    }

    public static func relaunchApp() {
        let bundleUrl = Bundle.main.bundleURL
        let appPath: String
        if bundleUrl.pathExtension == "app" {
            appPath = bundleUrl.path
        } else if FileManager.default.fileExists(atPath: "/Applications/StateBeacon.app") {
            appPath = "/Applications/StateBeacon.app"
        } else {
            appPath = bundleUrl.path
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /bin/sleep 0.2; /usr/bin/open -n \"\(appPath)\""
        let command = "nohup /bin/sh -c '\(script)' >/dev/null 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()

        NSApp.terminate(nil)
        exit(0)
    }

    // MARK: - Window Presentation

    public func show(tab: Tab = .connection) {
        self.config = AppConfig.load()

        if let existing = window {
            segmentedControl.selectedSegment = tab.rawValue
            switchTab(to: tab)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshPermissionsUI()
            return
        }

        let width: CGFloat = 580
        let height: CGFloat = 580
        let win = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "StateBeacon Preferences"
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        win.contentView = contentView

        // Top Segmented Bar
        segmentedControl = NSSegmentedControl(labels: ["Connection", "Sensors", "Permissions"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged))
        segmentedControl.frame = NSRect(x: (width - 320) / 2, y: height - 44, width: 320, height: 26)
        segmentedControl.segmentStyle = .texturedRounded
        if let img = NSImage(systemSymbolName: "network", accessibilityDescription: nil) {
            segmentedControl.setImage(img, forSegment: 0)
        }
        if let img = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil) {
            segmentedControl.setImage(img, forSegment: 1)
        }
        if let img = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil) {
            segmentedControl.setImage(img, forSegment: 2)
        }
        segmentedControl.selectedSegment = tab.rawValue
        contentView.addSubview(segmentedControl)

        let divider = NSBox(frame: NSRect(x: 0, y: height - 54, width: width, height: 1))
        divider.boxType = .separator
        contentView.addSubview(divider)

        // Tab Content Container
        tabContainerView = NSView(frame: NSRect(x: 0, y: 48, width: width, height: height - 102))
        contentView.addSubview(tabContainerView)

        // Bottom Divider & Bar
        let bottomDivider = NSBox(frame: NSRect(x: 0, y: 46, width: width, height: 1))
        bottomDivider.boxType = .separator
        contentView.addSubview(bottomDivider)

        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaultsClicked))
        resetBtn.frame = NSRect(x: 20, y: 10, width: 130, height: 28)
        resetBtn.bezelStyle = .rounded
        resetBtn.font = NSFont.systemFont(ofSize: 11)
        contentView.addSubview(resetBtn)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.frame = NSRect(x: width - 96, y: 10, width: 82, height: 28)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        contentView.addSubview(doneButton)

        self.window = win

        // Switch to requested tab
        switchTab(to: tab)

        // Make visible and elevate policy
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        startLivePolling()
        refreshPermissionsUI()
    }

    @objc private func segmentChanged() {
        if let tab = Tab(rawValue: segmentedControl.selectedSegment) {
            switchTab(to: tab)
        }
    }

    private func switchTab(to tab: Tab) {
        tabContainerView.subviews.forEach { $0.removeFromSuperview() }
        let bounds = tabContainerView.bounds

        switch tab {
        case .connection:
            let view = connectionView ?? makeConnectionTabView(width: bounds.width, height: bounds.height)
            connectionView = view
            view.frame = bounds
            tabContainerView.addSubview(view)
        case .sensors:
            let view = sensorsView ?? makeSensorsTabView(width: bounds.width, height: bounds.height)
            sensorsView = view
            view.frame = bounds
            tabContainerView.addSubview(view)
            updateSensorsPermissionState()
        case .permissions:
            let view = permissionsView ?? makePermissionsTabView(width: bounds.width, height: bounds.height)
            permissionsView = view
            view.frame = bounds
            tabContainerView.addSubview(view)
            refreshPermissionsUI()
        }
    }

    // MARK: - Tab 1: Connection Settings

    private func makeConnectionTabView(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        func makeLabel(text: String, y: CGFloat, width lblWidth: CGFloat = 135) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 10, y: y, width: lblWidth, height: 20)
            label.alignment = .right
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }

        func attachEditContextMenu(to view: NSView) {
            let menu = NSMenu()
            menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            view.menu = menu
        }

        func makeInput(value: String, y: CGFloat, width fieldWidth: CGFloat, placeholder: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 155, y: y, width: fieldWidth, height: 22)
            field.placeholderString = placeholder
            field.font = NSFont.systemFont(ofSize: 12)
            attachEditContextMenu(to: field)
            return field
        }

        var curY = height - 16

        // Connection Mode Segmented Control at Top
        connectionModeSegment = NSSegmentedControl(
            labels: ["MQTT Broker (LAN)", "Home Assistant Webhook (WAN)"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(connectionModeChanged)
        )
        connectionModeSegment.frame = NSRect(x: (width - 390) / 2, y: curY - 26, width: 390, height: 26)
        connectionModeSegment.segmentStyle = .texturedRounded
        connectionModeSegment.selectedSegment = (config.connectionMode == .mqtt) ? 0 : 1
        view.addSubview(connectionModeSegment)

        curY -= 40

        // Common container frame for mode-specific panels
        let modeContainerRect = NSRect(x: 0, y: curY - 175, width: width, height: 175)

        // 1. MQTT Container View
        mqttContainerView = NSView(frame: modeContainerRect)
        view.addSubview(mqttContainerView)

        var mqttY: CGFloat = 175 - 18
        let brokerSection = NSTextField(labelWithString: "MQTT Broker Settings")
        brokerSection.frame = NSRect(x: 28, y: mqttY, width: width - 56, height: 18)
        brokerSection.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        mqttContainerView.addSubview(brokerSection)

        mqttY -= 28
        mqttContainerView.addSubview(makeLabel(text: "Host", y: mqttY))
        hostField = makeInput(value: config.mqttHost, y: mqttY, width: width - 185, placeholder: "192.168.1.xxx or homeassistant.local")
        mqttContainerView.addSubview(hostField)

        mqttY -= 28
        mqttContainerView.addSubview(makeLabel(text: "Port", y: mqttY))
        portField = makeInput(value: String(config.mqttPort), y: mqttY, width: 70, placeholder: "1883")
        mqttContainerView.addSubview(portField)

        tlsCheckbox = NSButton(checkboxWithTitle: "Use TLS / SSL", target: nil, action: nil)
        tlsCheckbox.frame = NSRect(x: 236, y: mqttY, width: 120, height: 22)
        tlsCheckbox.font = NSFont.systemFont(ofSize: 12)
        tlsCheckbox.state = config.useTLS ? .on : .off
        mqttContainerView.addSubview(tlsCheckbox)

        mqttY -= 28
        mqttContainerView.addSubview(makeLabel(text: "Username", y: mqttY))
        usernameField = makeInput(value: config.mqttUsername, y: mqttY, width: width - 185, placeholder: "Optional")
        mqttContainerView.addSubview(usernameField)

        mqttY -= 28
        mqttContainerView.addSubview(makeLabel(text: "Password", y: mqttY))
        passwordField = NSSecureTextField(string: config.mqttPassword)
        passwordField.frame = NSRect(x: 155, y: mqttY, width: width - 185, height: 22)
        passwordField.placeholderString = "Optional"
        passwordField.font = NSFont.systemFont(ofSize: 12)
        attachEditContextMenu(to: passwordField)
        mqttContainerView.addSubview(passwordField)

        // 2. Home Assistant Webhook Container View
        webhookContainerView = NSView(frame: modeContainerRect)
        view.addSubview(webhookContainerView)

        var whY: CGFloat = 175 - 18
        let whSection = NSTextField(labelWithString: "Home Assistant Webhook (WAN) Settings")
        whSection.frame = NSRect(x: 28, y: whY, width: width - 56, height: 18)
        whSection.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        webhookContainerView.addSubview(whSection)

        whY -= 28
        webhookContainerView.addSubview(makeLabel(text: "Home Assistant URL", y: whY))
        haURLField = makeInput(value: config.haURL, y: whY, width: width - 250, placeholder: "https://my-ha.ui.nabu.casa or http://homeassistant.local:8123")
        webhookContainerView.addSubview(haURLField)

        let pasteUrlBtn = NSButton(title: "Paste", target: self, action: #selector(pasteUrlClicked))
        pasteUrlBtn.frame = NSRect(x: width - 88, y: whY - 1, width: 58, height: 24)
        pasteUrlBtn.bezelStyle = .rounded
        pasteUrlBtn.font = NSFont.systemFont(ofSize: 11)
        webhookContainerView.addSubview(pasteUrlBtn)

        whY -= 28
        webhookContainerView.addSubview(makeLabel(text: "Access Token", y: whY))
        haTokenField = NSSecureTextField(string: config.haToken)
        haTokenField.frame = NSRect(x: 155, y: whY, width: width - 250, height: 22)
        haTokenField.placeholderString = "Long-Lived Access Token (from HA Profile)"
        haTokenField.font = NSFont.systemFont(ofSize: 12)
        attachEditContextMenu(to: haTokenField)
        webhookContainerView.addSubview(haTokenField)

        let pasteTokenBtn = NSButton(title: "Paste", target: self, action: #selector(pasteTokenClicked))
        pasteTokenBtn.frame = NSRect(x: width - 88, y: whY - 1, width: 58, height: 24)
        pasteTokenBtn.bezelStyle = .rounded
        pasteTokenBtn.font = NSFont.systemFont(ofSize: 11)
        webhookContainerView.addSubview(pasteTokenBtn)

        whY -= 28
        webhookContainerView.addSubview(makeLabel(text: "Webhook ID", y: whY))
        haWebhookIdField = makeInput(value: config.haWebhookId, y: whY, width: width - 185, placeholder: "Auto-generated on registration, or enter manually")
        webhookContainerView.addSubview(haWebhookIdField)

        whY -= 26
        haWebSocketCheckbox = NSButton(checkboxWithTitle: "Enable Remote Commands via WebSocket (Sleep, Lock, Mute)", target: nil, action: nil)
        haWebSocketCheckbox.frame = NSRect(x: 155, y: whY, width: width - 185, height: 22)
        haWebSocketCheckbox.font = NSFont.systemFont(ofSize: 11)
        haWebSocketCheckbox.state = config.haEnableWebSocket ? .on : .off
        webhookContainerView.addSubview(haWebSocketCheckbox)

        whY -= 30
        haTestButton = NSButton(title: "Register & Test Connection", target: self, action: #selector(haTestButtonClicked))
        haTestButton.frame = NSRect(x: 155, y: whY, width: 190, height: 24)
        haTestButton.bezelStyle = .rounded
        haTestButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        webhookContainerView.addSubview(haTestButton)

        haStatusLabel = NSTextField(labelWithString: config.haWebhookId.isEmpty ? "" : "● Registered")
        haStatusLabel.frame = NSRect(x: 355, y: whY + 2, width: width - 365, height: 20)
        haStatusLabel.font = NSFont.systemFont(ofSize: 11)
        haStatusLabel.textColor = config.haWebhookId.isEmpty ? .secondaryLabelColor : .systemGreen
        webhookContainerView.addSubview(haStatusLabel)

        // Set visibility based on initial config
        let isMQTT = (config.connectionMode == .mqtt)
        mqttContainerView.isHidden = !isMQTT
        webhookContainerView.isHidden = isMQTT

        // 3. Shared Section: Device Info
        curY -= 190
        let devSection = NSTextField(labelWithString: "Device & Telemetry")
        devSection.frame = NSRect(x: 28, y: curY, width: width - 56, height: 18)
        devSection.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        view.addSubview(devSection)

        curY -= 28
        view.addSubview(makeLabel(text: "Device Name", y: curY))
        deviceNameField = makeInput(value: config.deviceName, y: curY, width: width - 185, placeholder: "My Mac")
        view.addSubview(deviceNameField)

        curY -= 28
        view.addSubview(makeLabel(text: "Identifier", y: curY))
        deviceIdField = makeInput(value: config.deviceId, y: curY, width: width - 185, placeholder: "mac_my_mac")
        view.addSubview(deviceIdField)

        curY -= 28
        view.addSubview(makeLabel(text: "Update Interval", y: curY))
        intervalField = makeInput(value: String(Int(config.updateInterval)), y: curY, width: 70, placeholder: "15")
        view.addSubview(intervalField)

        let secLabel = NSTextField(labelWithString: "seconds")
        secLabel.frame = NSRect(x: 233, y: curY + 2, width: 80, height: 18)
        secLabel.font = NSFont.systemFont(ofSize: 11)
        secLabel.textColor = .secondaryLabelColor
        view.addSubview(secLabel)

        return view
    }

    @objc private func connectionModeChanged() {
        let isMQTT = (connectionModeSegment.selectedSegment == 0)
        mqttContainerView.isHidden = !isMQTT
        webhookContainerView.isHidden = isMQTT
    }

    @objc private func haTestButtonClicked() {
        let url = haURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = haTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let devId = deviceIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let devName = deviceNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !url.isEmpty else {
            haStatusLabel.stringValue = "✕ Enter Home Assistant URL"
            haStatusLabel.textColor = .systemRed
            return
        }

        guard !token.isEmpty else {
            haStatusLabel.stringValue = "✕ Enter Access Token"
            haStatusLabel.textColor = .systemRed
            return
        }

        haStatusLabel.stringValue = "Registering with Home Assistant..."
        haStatusLabel.textColor = .secondaryLabelColor
        haTestButton.isEnabled = false

        Task {
            do {
                let res = try await HAWebhookClient.register(
                    haURL: url,
                    token: token,
                    deviceId: devId.isEmpty ? config.deviceId : devId,
                    deviceName: devName.isEmpty ? config.deviceName : devName
                )
                await MainActor.run {
                    self.haWebhookIdField.stringValue = res.webhookId
                    self.config.haWebhookId = res.webhookId
                    if let cloud = res.cloudhookURL {
                        self.config.haCloudhookURL = cloud
                    }
                    self.haStatusLabel.stringValue = "✓ Registered successfully"
                    self.haStatusLabel.textColor = .systemGreen
                    self.haTestButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    self.haStatusLabel.stringValue = "✕ \(error.localizedDescription)"
                    self.haStatusLabel.textColor = .systemRed
                    self.haTestButton.isEnabled = true
                }
            }
        }
    }

    @objc private func pasteUrlClicked() {
        if let str = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            haURLField.stringValue = str
        }
    }

    @objc private func pasteTokenClicked() {
        if let str = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            haTokenField.stringValue = str
            haStatusLabel.stringValue = "Token pasted from clipboard"
            haStatusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Tab 2: Sensors Checklist

    private func makeSensorsTabView(width: CGFloat, height: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Top Bar: summary count & quick toggles
        sensorSummaryLabel = NSTextField(labelWithString: "")
        sensorSummaryLabel.frame = NSRect(x: 24, y: 10, width: 260, height: 18)
        sensorSummaryLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        container.addSubview(sensorSummaryLabel)

        let enableAllBtn = NSButton(title: "Enable All", target: self, action: #selector(selectAllSensors))
        enableAllBtn.frame = NSRect(x: width - 180, y: 8, width: 76, height: 22)
        enableAllBtn.bezelStyle = .inline
        enableAllBtn.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(enableAllBtn)

        let disableAllBtn = NSButton(title: "Disable All", target: self, action: #selector(deselectAllSensors))
        disableAllBtn.frame = NSRect(x: width - 96, y: 8, width: 76, height: 22)
        disableAllBtn.bezelStyle = .inline
        disableAllBtn.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(disableAllBtn)

        sensorCheckboxes.removeAll()

        // Two Column Organization inside a ScrollView
        let col1Categories = ["System & Activity", "Peripherals & Hardware"]
        let col2Categories = ["Audio & Video", "Battery & Power", "Network", "Focus Mode", "Remote Controls"]

        let colWidth: CGFloat = (width - 64) / 2
        let col1X: CGFloat = 20
        let col2X: CGFloat = col1X + colWidth + 16

        func columnHeight(for categories: [String]) -> CGFloat {
            var h: CGFloat = 10
            for cat in categories {
                let catSensors = PreferencesWindowController.availableSensors.filter { $0.category == cat }
                guard !catSensors.isEmpty else { continue }
                h += 21 + CGFloat(catSensors.count) * 20 + 12
            }
            return h
        }

        let docHeight = max(height - 42, max(columnHeight(for: col1Categories), columnHeight(for: col2Categories)) + 16)
        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 16, height: docHeight))

        func renderColumn(categories: [String], startX: CGFloat, startY: CGFloat) {
            var curY = startY
            for cat in categories {
                let catSensors = PreferencesWindowController.availableSensors.filter { $0.category == cat }
                guard !catSensors.isEmpty else { continue }

                let catLabel = NSTextField(labelWithString: cat)
                catLabel.frame = NSRect(x: startX, y: curY, width: colWidth, height: 18)
                catLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                catLabel.textColor = .secondaryLabelColor
                docView.addSubview(catLabel)
                curY += 21

                for sensor in catSensors {
                    let isEnabled = config.isSensorEnabled(sensor.id)
                    let hasPermission = PreferencesWindowController.isPermissionGranted(for: sensor.requiredPermission)
                    let cb = NSButton(checkboxWithTitle: sensor.name, target: self, action: #selector(sensorCheckboxToggled))
                    cb.frame = NSRect(x: startX + 4, y: curY, width: colWidth - 4, height: 19)
                    cb.font = NSFont.systemFont(ofSize: 12)
                    cb.state = isEnabled ? .on : .off
                    cb.isEnabled = hasPermission

                    if !hasPermission {
                        let permName: String
                        switch sensor.requiredPermission {
                        case .fullDiskAccess: permName = "Full Disk Access"
                        case .location: permName = "Location Services"
                        case .bluetooth: permName = "Bluetooth"
                        case .accessibility: permName = "Accessibility"
                        case .none: permName = ""
                        }
                        cb.toolTip = "\(sensor.desc)\n⚠️ Inactive: Requires \(permName). Grant permission in Permissions tab to enable."
                    } else {
                        cb.toolTip = sensor.desc
                    }

                    sensorCheckboxes[sensor.id] = cb
                    docView.addSubview(cb)
                    curY += 20
                }
                curY += 10
            }
        }

        renderColumn(categories: col1Categories, startX: col1X, startY: 8)
        renderColumn(categories: col2Categories, startX: col2X, startY: 8)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 36, width: width, height: height - 36))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = docView
        container.addSubview(scrollView)

        updateSensorSummary()
        return container
    }

    private func updateSensorSummary() {
        let activeCount = sensorCheckboxes.values.filter { $0.state == .on && $0.isEnabled }.count
        let totalCount = PreferencesWindowController.availableSensors.count
        let pendingPermCount = sensorCheckboxes.values.filter { $0.state == .on && !$0.isEnabled }.count
        if pendingPermCount > 0 {
            sensorSummaryLabel.stringValue = "\(activeCount) of \(totalCount) enabled (\(pendingPermCount) need permission)"
        } else {
            sensorSummaryLabel.stringValue = "\(activeCount) of \(totalCount) sensors enabled"
        }
        sensorSummaryLabel.textColor = (activeCount > 0) ? .secondaryLabelColor : .systemRed
    }

    public func updateSensorsPermissionState() {
        guard !sensorCheckboxes.isEmpty else { return }
        var newlyPermitted = false
        for def in PreferencesWindowController.availableSensors {
            guard def.requiredPermission != .none, let cb = sensorCheckboxes[def.id] else { continue }
            let hasPermission = PreferencesWindowController.isPermissionGranted(for: def.requiredPermission)
            if cb.isEnabled != hasPermission {
                cb.isEnabled = hasPermission
                if !hasPermission {
                    let permName: String
                    switch def.requiredPermission {
                    case .fullDiskAccess: permName = "Full Disk Access"
                    case .location: permName = "Location Services"
                    case .bluetooth: permName = "Bluetooth"
                    case .accessibility: permName = "Accessibility"
                    case .none: permName = ""
                    }
                    cb.toolTip = "\(def.desc)\n⚠️ Inactive: Requires \(permName). Grant permission in Permissions tab to enable."
                } else {
                    cb.toolTip = def.desc
                    newlyPermitted = true
                }
            }
        }
        updateSensorSummary()
        if newlyPermitted {
            applySensorChanges()
        }
    }

    @objc private func sensorCheckboxToggled() {
        updateSensorSummary()
        applySensorChanges()
    }

    @objc private func selectAllSensors() {
        for (_, cb) in sensorCheckboxes {
            cb.state = .on
        }
        updateSensorSummary()
        applySensorChanges()
    }

    @objc private func deselectAllSensors() {
        for (_, cb) in sensorCheckboxes {
            if cb.isEnabled {
                cb.state = .off
            }
        }
        updateSensorSummary()
        applySensorChanges()
    }

    private func applySensorChanges() {
        var disabled: [String] = []
        for (id, cb) in sensorCheckboxes {
            if cb.state == .off {
                disabled.append(id)
            }
        }
        config.disabledSensors = disabled
        config.save()
        onSave(config)
    }

    // MARK: - Tab 3: Permissions

    private func makePermissionsTabView(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var curY = height - 10

        func makeCard(
            y: CGFloat,
            symbol: String,
            title: String,
            subtitle: String,
            actionTitle: String,
            action: Selector
        ) -> (NSBox, NSTextField, NSButton) {
            let box = NSBox(frame: NSRect(x: 20, y: y, width: width - 40, height: 76))
            box.boxType = .custom
            box.borderWidth = 1
            box.borderColor = NSColor.separatorColor
            box.cornerRadius = 8
            box.fillColor = NSColor.controlBackgroundColor

            let iconView = NSImageView(frame: NSRect(x: 14, y: 24, width: 28, height: 28))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                iconView.image = img
                iconView.contentTintColor = .controlAccentColor
            }
            box.addSubview(iconView)

            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.frame = NSRect(x: 52, y: 44, width: 240, height: 18)
            titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            box.addSubview(titleLabel)

            let subLabel = NSTextField(labelWithString: subtitle)
            subLabel.frame = NSRect(x: 52, y: 26, width: 280, height: 16)
            subLabel.font = NSFont.systemFont(ofSize: 11)
            subLabel.textColor = .secondaryLabelColor
            box.addSubview(subLabel)

            let badgeLabel = NSTextField(labelWithString: "● Checking")
            badgeLabel.frame = NSRect(x: 52, y: 10, width: 140, height: 14)
            badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            box.addSubview(badgeLabel)

            let button = NSButton(title: actionTitle, target: self, action: action)
            button.frame = NSRect(x: box.frame.width - 134, y: 24, width: 122, height: 28)
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 11)
            box.addSubview(button)

            return (box, badgeLabel, button)
        }

        // 1. Full Disk Access Card
        curY -= 82
        let (box1, badge1, btn1) = makeCard(
            y: curY,
            symbol: "moon.fill",
            title: "Focus Mode (Full Disk Access)",
            subtitle: "Enables instant Focus & Do Not Disturb detection.",
            actionTitle: "Open Settings",
            action: #selector(openFDASettings)
        )
        fdaBadgeLabel = badge1
        fdaActionButton = btn1
        view.addSubview(box1)

        // 2. Location Services Card
        curY -= 84
        let (box2, badge2, btn2) = makeCard(
            y: curY,
            symbol: "location.fill",
            title: "Wi-Fi & Geolocation (Location Services)",
            subtitle: "Required by macOS for Wi-Fi SSID/BSSID and GPS coordinates.",
            actionTitle: "Grant Permission",
            action: #selector(requestLocationOrOpenSettings)
        )
        locBadgeLabel = badge2
        locActionButton = btn2
        view.addSubview(box2)

        // 3. Bluetooth Peripherals Card
        curY -= 82
        let (box3, badge3, btn3) = makeCard(
            y: curY,
            symbol: "antenna.radiowaves.left.and.right",
            title: "Bluetooth Peripherals (Bluetooth)",
            subtitle: "Monitors connected Bluetooth Classic & LE accessories.",
            actionTitle: "Grant Permission",
            action: #selector(requestBluetoothOrOpenSettings)
        )
        btBadgeLabel = badge3
        btActionButton = btn3
        view.addSubview(box3)

        // 4. Accessibility (Active Window) Card
        curY -= 82
        let (box4, badge4, btn4) = makeCard(
            y: curY,
            symbol: "macwindow.on.rectangle",
            title: "Active Window (Accessibility)",
            subtitle: "Required by macOS to detect active window titles across other apps.",
            actionTitle: "Grant Permission",
            action: #selector(requestAccessibilityOrOpenSettings)
        )
        axBadgeLabel = badge4
        axActionButton = btn4
        view.addSubview(box4)

        // 5. Relaunch Helper Card
        curY -= 84
        let relaunchBox = NSBox(frame: NSRect(x: 20, y: curY, width: width - 40, height: 76))
        relaunchBox.boxType = .custom
        relaunchBox.borderWidth = 1
        relaunchBox.borderColor = NSColor.separatorColor
        relaunchBox.cornerRadius = 8
        relaunchBox.fillColor = NSColor.controlBackgroundColor

        let relaunchIcon = NSImageView(frame: NSRect(x: 14, y: 24, width: 28, height: 28))
        if let img = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil) {
            relaunchIcon.image = img
            relaunchIcon.contentTintColor = .systemBlue
        }
        relaunchBox.addSubview(relaunchIcon)

        let relaunchTitle = NSTextField(labelWithString: "Quit & Relaunch")
        relaunchTitle.frame = NSRect(x: 52, y: 44, width: 240, height: 18)
        relaunchTitle.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        relaunchBox.addSubview(relaunchTitle)

        let relaunchSub = NSTextField(labelWithString: "Apply newly granted System Settings permissions immediately.")
        relaunchSub.frame = NSRect(x: 52, y: 22, width: 280, height: 16)
        relaunchSub.font = NSFont.systemFont(ofSize: 11)
        relaunchSub.textColor = .secondaryLabelColor
        relaunchBox.addSubview(relaunchSub)

        let relaunchBtn = NSButton(title: "Relaunch App", target: self, action: #selector(relaunchClicked))
        relaunchBtn.frame = NSRect(x: relaunchBox.frame.width - 134, y: 24, width: 122, height: 28)
        relaunchBtn.bezelStyle = .rounded
        relaunchBtn.font = NSFont.systemFont(ofSize: 11)
        relaunchBox.addSubview(relaunchBtn)

        view.addSubview(relaunchBox)

        return view
    }

    public func refreshPermissionsUI() {
        updateSensorsPermissionState()
        guard fdaBadgeLabel != nil, locBadgeLabel != nil, btBadgeLabel != nil, axBadgeLabel != nil else { return }

        // FDA
        let fda = PreferencesWindowController.checkFullDiskAccess()
        if fda {
            fdaBadgeLabel.stringValue = "✓ Granted"
            fdaBadgeLabel.textColor = .systemGreen
            fdaActionButton.title = "Settings..."
        } else {
            fdaBadgeLabel.stringValue = "⚠ Not Granted"
            fdaBadgeLabel.textColor = .systemOrange
            fdaActionButton.title = "Open Settings"
        }

        // Location
        let loc = PreferencesWindowController.checkLocationPermission()
        switch loc {
        case .authorizedAlways:
            locBadgeLabel.stringValue = "✓ Granted"
            locBadgeLabel.textColor = .systemGreen
            locActionButton.title = "Settings..."
        case .notDetermined:
            locBadgeLabel.stringValue = "⚠ Not Requested"
            locBadgeLabel.textColor = .systemOrange
            locActionButton.title = "Request Access"
        case .denied, .restricted:
            locBadgeLabel.stringValue = "⚠ Denied"
            locBadgeLabel.textColor = .systemRed
            locActionButton.title = "Open Settings"
        @unknown default:
            locBadgeLabel.stringValue = "○ Unknown"
            locBadgeLabel.textColor = .secondaryLabelColor
        }

        // Bluetooth
        let bt = PreferencesWindowController.checkBluetoothPermission()
        switch bt {
        case .allowedAlways:
            btBadgeLabel.stringValue = "✓ Granted"
            btBadgeLabel.textColor = .systemGreen
            btActionButton.title = "Settings..."
        case .notDetermined:
            btBadgeLabel.stringValue = "⚠ Not Requested"
            btBadgeLabel.textColor = .systemOrange
            btActionButton.title = "Request Access"
        case .denied, .restricted:
            btBadgeLabel.stringValue = "⚠ Denied"
            btBadgeLabel.textColor = .systemRed
            btActionButton.title = "Open Settings"
        @unknown default:
            btBadgeLabel.stringValue = "○ Unknown"
            btBadgeLabel.textColor = .secondaryLabelColor
        }

        // Accessibility
        let ax = PreferencesWindowController.checkAccessibilityPermission()
        if ax {
            axBadgeLabel.stringValue = "✓ Granted"
            axBadgeLabel.textColor = .systemGreen
            axActionButton.title = "Settings..."
        } else {
            axBadgeLabel.stringValue = "⚠ Not Granted"
            axBadgeLabel.textColor = .systemOrange
            axActionButton.title = "Grant Permission"
        }
    }

    private func startLivePolling() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissionsUI()
            }
        }

        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)

        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    private func stopLivePolling() {
        liveTimer?.invalidate()
        liveTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    @objc private func handleAppDidBecomeActive() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshPermissionsUI()
        }
    }

    @objc private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestLocationOrOpenSettings() {
        let loc = PreferencesWindowController.checkLocationPermission()
        if loc == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func requestBluetoothOrOpenSettings() {
        let bt = PreferencesWindowController.checkBluetoothPermission()
        if bt == .notDetermined {
            if bluetoothManager == nil {
                bluetoothManager = CBCentralManager(delegate: self, queue: .main)
            }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func requestAccessibilityOrOpenSettings() {
        let ax = PreferencesWindowController.checkAccessibilityPermission()
        if !ax {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func relaunchClicked() {
        saveAndApply()
        stopLivePolling()
        PreferencesWindowController.relaunchApp()
    }

    // MARK: - Save & Close

    @objc private func resetDefaultsClicked() {
        let alert = NSAlert()
        alert.messageText = "Reset to Default Settings?"
        alert.informativeText = "This will erase local broker credentials and restore default sensor settings. No personal data will be kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let fresh = AppConfig.resetToDefaults()
            self.config = fresh
            if hostField != nil {
                connectionModeSegment?.selectedSegment = (fresh.connectionMode == .mqtt) ? 0 : 1
                connectionModeChanged()
                hostField.stringValue = fresh.mqttHost
                portField.stringValue = String(fresh.mqttPort)
                tlsCheckbox.state = fresh.useTLS ? .on : .off
                usernameField.stringValue = fresh.mqttUsername
                passwordField.stringValue = fresh.mqttPassword
                haURLField?.stringValue = fresh.haURL
                haTokenField?.stringValue = fresh.haToken
                haWebhookIdField?.stringValue = fresh.haWebhookId
                haWebSocketCheckbox?.state = fresh.haEnableWebSocket ? .on : .off
                haStatusLabel?.stringValue = ""
                deviceNameField.stringValue = fresh.deviceName
                deviceIdField.stringValue = fresh.deviceId
                intervalField.stringValue = String(Int(fresh.updateInterval))
            }
            for (id, cb) in sensorCheckboxes {
                cb.state = fresh.isSensorEnabled(id) ? .on : .off
            }
            updateSensorSummary()
            onSave(fresh)
        }
    }

    @objc private func doneClicked() {
        saveAndApply()
        closeWindowAndDismissDock()
    }

    private func saveAndApply() {
        if connectionModeSegment != nil {
            config.connectionMode = (connectionModeSegment.selectedSegment == 0) ? .mqtt : .haWebhook
        }

        if hostField != nil {
            config.mqttHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
                config.mqttPort = port
            }
            config.useTLS = (tlsCheckbox.state == .on)
            config.mqttUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.mqttPassword = passwordField.stringValue
        }

        if haURLField != nil {
            config.haURL = haURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.haToken = haTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.haWebhookId = haWebhookIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.haEnableWebSocket = (haWebSocketCheckbox.state == .on)
        }

        if deviceNameField != nil {
            config.deviceName = deviceNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.deviceId = deviceIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let interval = Double(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), interval >= 1.0 {
                config.updateInterval = interval
            }
        }

        // Save sensor checklist
        if !sensorCheckboxes.isEmpty {
            var disabled: [String] = []
            for (id, cb) in sensorCheckboxes {
                if cb.state == .off {
                    disabled.append(id)
                }
            }
            config.disabledSensors = disabled
        }

        config.hasCompletedOnboarding = true
        config.save()
        onSave(config)
    }

    public func windowWillClose(_ notification: Notification) {
        saveAndApply()
        stopLivePolling()
        let closing = notification.object as? NSWindow ?? window
        window = nil
        connectionView = nil
        sensorsView = nil
        permissionsView = nil
        dismissDockIconIfNoWindows(excluding: closing)
    }

    private func closeWindowAndDismissDock() {
        stopLivePolling()
        let closing = window
        window?.orderOut(nil)
        window = nil
        connectionView = nil
        sensorsView = nil
        permissionsView = nil
        dismissDockIconIfNoWindows(excluding: closing)
    }

    private func dismissDockIconIfNoWindows(excluding: NSWindow? = nil) {
        DispatchQueue.main.async {
            let visible = NSApp.windows.filter { win in
                win !== excluding && win.isVisible && win.canBecomeMain && !NSStringFromClass(type(of: win)).contains("StatusBar")
            }
            if visible.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

extension PreferencesWindowController: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.refreshPermissionsUI()
    }
}
