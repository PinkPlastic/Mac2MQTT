import AppKit
import CoreLocation

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
        SensorDefinition(id: "active", name: "User Active / Idle", category: "System & Activity", desc: "User presence and idle detection"),
        SensorDefinition(id: "cpu_usage", name: "CPU Usage (%)", category: "System & Activity", desc: "Overall CPU load percentage"),
        SensorDefinition(id: "memory_usage", name: "Memory Usage (%)", category: "System & Activity", desc: "RAM usage percentage"),
        SensorDefinition(id: "displays", name: "Displays Count", category: "System & Activity", desc: "Total connected displays"),
        SensorDefinition(id: "primary_display_id", name: "Primary Display ID", category: "System & Activity", desc: "Main display identifier"),
        SensorDefinition(id: "app_version", name: "Mac2MQTT Version", category: "System & Activity", desc: "Client app release version"),

        // Audio & Camera
        SensorDefinition(id: "audio_input_in_use", name: "Microphone In-Use", category: "Audio & Video", desc: "Detects active microphone usage"),
        SensorDefinition(id: "active_audio_input", name: "Active Microphone Name", category: "Audio & Video", desc: "Default input audio device name"),
        SensorDefinition(id: "audio_output_in_use", name: "Audio Output Playing", category: "Audio & Video", desc: "Detects active audio output playback"),
        SensorDefinition(id: "active_audio_output", name: "Active Audio Output Name", category: "Audio & Video", desc: "Default output audio device name"),
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
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var tlsCheckbox: NSButton!
    private var usernameField: NSTextField!
    private var passwordField: NSSecureTextField!
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
    private var liveTimer: Timer?
    private let locationManager = CLLocationManager()

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

    nonisolated public static func isPermissionGranted(for permission: RequiredPermission) -> Bool {
        switch permission {
        case .none:
            return true
        case .fullDiskAccess:
            return checkFullDiskAccess()
        case .location:
            return checkLocationPermission() == .authorizedAlways
        }
    }

    nonisolated public static func isSensorPermitted(_ sensorId: String) -> Bool {
        guard let def = availableSensors.first(where: { $0.id == sensorId }) else { return true }
        return isPermissionGranted(for: def.requiredPermission)
    }

    nonisolated public static func isAllPermissionsGranted() -> Bool {
        let fda = checkFullDiskAccess()
        let loc = checkLocationPermission()
        return fda && (loc == .authorizedAlways)
    }

    public static func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let script = "sleep 0.4 && /usr/bin/open \"\(bundlePath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
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

        let width: CGFloat = 550
        let height: CGFloat = 520
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Mac2MQTT Preferences"
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

        func makeLabel(text: String, y: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 16, y: y, width: 120, height: 20)
            label.alignment = .right
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }

        func makeInput(value: String, y: CGFloat, width fieldWidth: CGFloat, placeholder: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 144, y: y, width: fieldWidth, height: 22)
            field.placeholderString = placeholder
            field.font = NSFont.systemFont(ofSize: 12)
            return field
        }

        var curY = height - 32

        // Section: MQTT Broker
        let brokerSection = NSTextField(labelWithString: "MQTT Broker")
        brokerSection.frame = NSRect(x: 28, y: curY, width: width - 56, height: 18)
        brokerSection.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        view.addSubview(brokerSection)

        curY -= 28
        view.addSubview(makeLabel(text: "Host", y: curY))
        hostField = makeInput(value: config.mqttHost, y: curY, width: width - 176, placeholder: "192.168.1.xxx or homeassistant.local")
        view.addSubview(hostField)

        curY -= 28
        view.addSubview(makeLabel(text: "Port", y: curY))
        portField = makeInput(value: String(config.mqttPort), y: curY, width: 70, placeholder: "1883")
        view.addSubview(portField)

        tlsCheckbox = NSButton(checkboxWithTitle: "Use TLS / SSL", target: nil, action: nil)
        tlsCheckbox.frame = NSRect(x: 226, y: curY, width: 120, height: 22)
        tlsCheckbox.font = NSFont.systemFont(ofSize: 12)
        tlsCheckbox.state = config.useTLS ? .on : .off
        view.addSubview(tlsCheckbox)

        curY -= 28
        view.addSubview(makeLabel(text: "Username", y: curY))
        usernameField = makeInput(value: config.mqttUsername, y: curY, width: width - 176, placeholder: "Optional")
        view.addSubview(usernameField)

        curY -= 28
        view.addSubview(makeLabel(text: "Password", y: curY))
        passwordField = NSSecureTextField(string: config.mqttPassword)
        passwordField.frame = NSRect(x: 144, y: curY, width: width - 176, height: 22)
        passwordField.placeholderString = "Optional"
        passwordField.font = NSFont.systemFont(ofSize: 12)
        view.addSubview(passwordField)

        curY -= 36

        // Section: Device Info
        let devSection = NSTextField(labelWithString: "Device")
        devSection.frame = NSRect(x: 28, y: curY, width: width - 56, height: 18)
        devSection.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        view.addSubview(devSection)

        curY -= 28
        view.addSubview(makeLabel(text: "Name", y: curY))
        deviceNameField = makeInput(value: config.deviceName, y: curY, width: width - 176, placeholder: "My Mac")
        view.addSubview(deviceNameField)

        curY -= 28
        view.addSubview(makeLabel(text: "Identifier", y: curY))
        deviceIdField = makeInput(value: config.deviceId, y: curY, width: width - 176, placeholder: "mac_my_mac")
        view.addSubview(deviceIdField)

        curY -= 28
        view.addSubview(makeLabel(text: "Update Interval", y: curY))
        intervalField = makeInput(value: String(Int(config.updateInterval)), y: curY, width: 70, placeholder: "15")
        view.addSubview(intervalField)

        let secLabel = NSTextField(labelWithString: "seconds")
        secLabel.frame = NSRect(x: 222, y: curY + 2, width: 80, height: 18)
        secLabel.font = NSFont.systemFont(ofSize: 11)
        secLabel.textColor = .secondaryLabelColor
        view.addSubview(secLabel)

        return view
    }

    // MARK: - Tab 2: Sensors Checklist

    private func makeSensorsTabView(width: CGFloat, height: CGFloat) -> NSView {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Top Bar: summary count & quick toggles
        sensorSummaryLabel = NSTextField(labelWithString: "")
        sensorSummaryLabel.frame = NSRect(x: 24, y: 10, width: 220, height: 18)
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

        // Two Column Organization (No Scroll Needed!)
        let col1Categories = ["System & Activity", "Focus Mode", "Remote Controls"]
        let col2Categories = ["Audio & Video", "Battery & Power", "Network"]

        let colWidth: CGFloat = (width - 64) / 2
        let col1X: CGFloat = 24
        let col2X: CGFloat = col1X + colWidth + 16

        func renderColumn(categories: [String], startX: CGFloat, startY: CGFloat) {
            var curY = startY
            for cat in categories {
                let catSensors = PreferencesWindowController.availableSensors.filter { $0.category == cat }
                guard !catSensors.isEmpty else { continue }

                let catLabel = NSTextField(labelWithString: cat)
                catLabel.frame = NSRect(x: startX, y: curY, width: colWidth, height: 18)
                catLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
                catLabel.textColor = .secondaryLabelColor
                container.addSubview(catLabel)
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
                        let permName = (sensor.requiredPermission == .fullDiskAccess) ? "Full Disk Access" : "Location Services"
                        cb.toolTip = "\(sensor.desc)\n⚠️ Inactive: Requires \(permName). Grant permission in Permissions tab to enable."
                    } else {
                        cb.toolTip = sensor.desc
                    }

                    sensorCheckboxes[sensor.id] = cb
                    container.addSubview(cb)
                    curY += 20
                }
                curY += 8
            }
        }

        renderColumn(categories: col1Categories, startX: col1X, startY: 36)
        renderColumn(categories: col2Categories, startX: col2X, startY: 36)

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
                    let permName = (def.requiredPermission == .fullDiskAccess) ? "Full Disk Access" : "Location Services"
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
            symbol: "wifi",
            title: "Wi-Fi Details (Location Services)",
            subtitle: "Required by macOS to read network SSID & BSSID.",
            actionTitle: "Grant Permission",
            action: #selector(requestLocationOrOpenSettings)
        )
        locBadgeLabel = badge2
        locActionButton = btn2
        view.addSubview(box2)

        // 3. Relaunch Helper Card
        curY -= 88
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
        guard fdaBadgeLabel != nil, locBadgeLabel != nil else { return }

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
    }

    private func startLivePolling() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissionsUI()
            }
        }
    }

    private func stopLivePolling() {
        liveTimer?.invalidate()
        liveTimer = nil
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

    @objc private func relaunchClicked() {
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
                hostField.stringValue = fresh.mqttHost
                portField.stringValue = String(fresh.mqttPort)
                tlsCheckbox.state = fresh.useTLS ? .on : .off
                usernameField.stringValue = fresh.mqttUsername
                passwordField.stringValue = fresh.mqttPassword
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
        var changed = false

        if hostField != nil {
            config.mqttHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
                config.mqttPort = port
            }
            config.useTLS = (tlsCheckbox.state == .on)
            config.mqttUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.mqttPassword = passwordField.stringValue
            config.deviceName = deviceNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            config.deviceId = deviceIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let interval = Double(intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), interval >= 1.0 {
                config.updateInterval = interval
            }
            changed = true
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
            changed = true
        }

        config.hasCompletedOnboarding = true

        if changed {
            config.save()
            onSave(config)
        }
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
