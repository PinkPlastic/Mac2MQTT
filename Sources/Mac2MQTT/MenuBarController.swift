import AppKit
import ServiceManagement
import CoreAudio
import IOKit.ps
import notify

@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var config: AppConfig
    private var mqttClient: MQTTClient!
    private var discovery: HADiscovery!
    private let sensorManager = SensorManager()
    private var timer: Timer?
    private var isConnected = false
    private var lastSnapshot: SensorSnapshot?
    private var prefsWindowController: PreferencesWindowController?
    private var powerRunLoopSource: CFRunLoopSource?

    // Instant Focus Mode Watchers
    private var focusDirWatcher: DispatchSourceFileSystemObject?
    private var focusDirFd: Int32 = -1
    private var focusFileWatcher: DispatchSourceFileSystemObject?
    private var focusFileFd: Int32 = -1
    private var focusUpdateWorkItems: [DispatchWorkItem] = []
    private var darwinNotifyTokens: [Int32] = []

    // Menu item references
    private var statusMenuItem: NSMenuItem!
    private let statusView: NSView = {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        view.autoresizingMask = [.width]
        return view
    }()
    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private var statusDebounceItem: DispatchWorkItem?

    private var liveHeaderSeparator: NSMenuItem!
    private var liveHeader: NSMenuItem!
    private var appMenuItem: NSMenuItem!
    private var micMenuItem: NSMenuItem!
    private var camMenuItem: NSMenuItem!
    private var audioMenuItem: NSMenuItem!
    private var battMenuItem: NSMenuItem!
    private var wifiMenuItem: NSMenuItem!
    private var focusMenuItem: NSMenuItem!
    private var statsMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!

    public init(config: AppConfig) {
        self.config = config
        super.init()
        setupStatusItem()
        setupMQTT()
        setupEventSystem()
        startSensorLoop()
        publishSensorState(trigger: "Startup")

        // Check if onboarding or permissions need to be completed on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if !self.config.hasCompletedOnboarding || !PreferencesWindowController.isAllPermissionsGranted() {
                self.openPreferences(tab: .permissions)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Mac2MQTT") {
                image.isTemplate = true
                button.image = image
            }
        }

        buildMenu()
    }

    private func setupStatusView() {
        statusView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusView.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusView.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: statusView.centerYAnchor)
        ])
        statusMenuItem.view = statusView
    }

    private func updateStatusDisplay(connected: Bool, error: Error? = nil) {
        if connected {
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(
                string: "● ",
                attributes: [
                    .foregroundColor: NSColor.systemGreen,
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold)
                ]
            ))
            attr.append(NSAttributedString(
                string: "Connected",
                attributes: [
                    .foregroundColor: NSColor.systemGreen,
                    .font: NSFont.menuFont(ofSize: 13)
                ]
            ))
            let hostText = config.mqttHost.isEmpty ? "" : " (\(config.mqttHost))"
            attr.append(NSAttributedString(
                string: hostText,
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.menuFont(ofSize: 13)
                ]
            ))
            statusLabel.attributedStringValue = attr
            statusMenuItem.attributedTitle = attr
            statusMenuItem.title = "● Connected\(hostText)"
        } else {
            let title: String
            let color: NSColor
            if let error = error {
                title = "○ Error: \(error.localizedDescription)"
                color = .systemRed
            } else {
                title = "○ Disconnected"
                color = .secondaryLabelColor
            }
            let attr = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.menuFont(ofSize: 13)
                ]
            )
            statusLabel.attributedStringValue = attr
            statusMenuItem.attributedTitle = attr
            statusMenuItem.title = title
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "○ Disconnected", action: nil, keyEquivalent: "")
        setupStatusView()
        updateStatusDisplay(connected: false)
        menu.addItem(statusMenuItem)

        liveHeaderSeparator = NSMenuItem.separator()
        menu.addItem(liveHeaderSeparator)

        liveHeader = NSMenuItem(title: "Live Sensors:", action: nil, keyEquivalent: "")
        liveHeader.isEnabled = false
        menu.addItem(liveHeader)

        appMenuItem = NSMenuItem(title: "  App: --", action: nil, keyEquivalent: "")
        appMenuItem.isEnabled = false
        menu.addItem(appMenuItem)

        micMenuItem = NSMenuItem(title: "  Mic: --", action: nil, keyEquivalent: "")
        micMenuItem.isEnabled = false
        menu.addItem(micMenuItem)

        camMenuItem = NSMenuItem(title: "  Camera: --", action: nil, keyEquivalent: "")
        camMenuItem.isEnabled = false
        menu.addItem(camMenuItem)

        audioMenuItem = NSMenuItem(title: "  Audio: --", action: nil, keyEquivalent: "")
        audioMenuItem.isEnabled = false
        menu.addItem(audioMenuItem)

        battMenuItem = NSMenuItem(title: "  Battery: --", action: nil, keyEquivalent: "")
        battMenuItem.isEnabled = false
        menu.addItem(battMenuItem)

        wifiMenuItem = NSMenuItem(title: "  Wi-Fi: --", action: nil, keyEquivalent: "")
        wifiMenuItem.isEnabled = false
        menu.addItem(wifiMenuItem)

        focusMenuItem = NSMenuItem(title: "  Focus Mode: Off", action: nil, keyEquivalent: "")
        focusMenuItem.isEnabled = false
        menu.addItem(focusMenuItem)

        statsMenuItem = NSMenuItem(title: "  CPU: -- | RAM: --", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let wizardItem = NSMenuItem(title: "Setup & Permissions...", action: #selector(openOnboardingWizard), keyEquivalent: "p")
        wizardItem.target = self
        menu.addItem(wizardItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferencesClicked), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        loginItemMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItemMenuItem.target = self
        updateLoginItemState()
        menu.addItem(loginItemMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Mac2MQTT", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupMQTT() {
        let mqttCfg = MQTTClient.Config(
            host: config.mqttHost,
            port: config.mqttPort,
            clientID: "\(config.deviceId)_\(UUID().uuidString.prefix(6))",
            username: config.mqttUsername.isEmpty ? nil : config.mqttUsername,
            password: config.mqttPassword.isEmpty ? nil : config.mqttPassword,
            useTLS: config.useTLS,
            willTopic: "homeassistant/device/\(config.deviceId)/status",
            willPayload: "offline".data(using: .utf8),
            willRetain: true
        )

        mqttClient = MQTTClient(config: mqttCfg)
        discovery = HADiscovery(client: mqttClient, config: config)

        mqttClient.onConnect = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = true
                self.statusDebounceItem?.cancel()
                self.statusDebounceItem = nil
                self.updateStatusDisplay(connected: true)
                self.discovery.publishDiscoveryAndSubscribe()
                self.publishSensorState(trigger: "Initial Connect")
            }
        }

        mqttClient.onDisconnect = { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = false
                self.statusDebounceItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.isConnected else { return }
                    self.updateStatusDisplay(connected: false, error: error)
                }
                self.statusDebounceItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
            }
        }

        mqttClient.onMessage = { [weak self] topic, data in
            guard let message = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discovery.handleCommand(topic: topic, message: message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.publishSensorState(trigger: "Command Response")
                }
            }
        }

        mqttClient.connect()
    }

    // MARK: - Instant Event System (Zero-Latency Updates)

    private func setupEventSystem() {
        // Guarantee dock icon is dismissed whenever all windows close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            let closing = notification.object as? NSWindow
            DispatchQueue.main.async {
                let visible = NSApp.windows.filter { win in
                    win !== closing && win.isVisible && win.canBecomeMain && !NSStringFromClass(type(of: win)).contains("StatusBar")
                }
                if visible.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // 1. App Switch Event
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "App Changed")
            }
        }

        // 2. Display Connected / Disconnected Event
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Display Changed")
            }
        }

        // 3. Instant Power Cable & Battery Event (IOKit callback)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let controller = Unmanaged<MenuBarController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.publishSensorState(trigger: "Power Changed")
            }
        }, context)?.takeRetainedValue() {
            powerRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // 4. CoreAudio Device Listener (Default output changed)
        var outAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddress, DispatchQueue.main) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Audio Device Changed")
            }
        }

        var inAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddress, DispatchQueue.main) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Audio Device Changed")
            }
        }

        // 5. Focus Mode Real-time Listeners (Directory + File + Darwin + Distributed)
        setupFocusMonitoring()

        // 6. Sleep / Wake & Screen Lock Events
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Screen Sleep")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Screen Wake")
            }
        }
    }

    // MARK: - Zero-Latency Focus Monitoring

    private func setupFocusMonitoring() {
        ensureFocusWatchersArmed()

        // 3. System-wide Darwin Notifications for Focus & Do Not Disturb
        let darwinNames = [
            "com.apple.donotdisturb.state.changed",
            "com.apple.donotdisturb.mode",
            "com.apple.donotdisturb.mode.changed",
            "com.apple.donotdisturb.server.state.changed",
            "com.apple.donotdisturb.server.assertions.changed",
            "com.apple.donotdisturb.server.modeConfigurations.changed",
            "com.apple.donotdisturb.assertions.changed",
            "com.apple.controlcenter.focus",
            "com.apple.controlcenter.focus.state",
            "com.apple.controlcenter.focusModes.changed",
            "com.apple.notificationcenterui.dndprefs_changed"
        ]

        for name in darwinNames {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, DispatchQueue.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerInstantFocusUpdate()
                }
            }
            if status == NOTIFY_STATUS_OK {
                darwinNotifyTokens.append(token)
            }
        }

        // 4. Distributed Notification Center
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.donotdisturb.state.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.triggerInstantFocusUpdate()
            }
        }
    }

    private func ensureFocusWatchersArmed() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dndDir = home.appendingPathComponent("Library/DoNotDisturb/DB")
        let assertionsFile = dndDir.appendingPathComponent("Assertions.json")

        // 1. Directory Watcher (Detects atomic file replacements & creations in DB folder)
        if focusDirWatcher == nil {
            let fd = open(dndDir.path, O_EVTONLY)
            if fd >= 0 {
                focusDirFd = fd
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend, .attrib, .rename, .link],
                    queue: .main
                )
                watcher.setEventHandler { [weak self] in
                    self?.triggerInstantFocusUpdate()
                    self?.armFocusFileWatcher(assertionsPath: assertionsFile.path)
                }
                watcher.setCancelHandler {
                    close(fd)
                }
                watcher.resume()
                focusDirWatcher = watcher
            }
        }

        // 2. Direct Assertions.json File Watcher
        if focusFileWatcher == nil {
            armFocusFileWatcher(assertionsPath: assertionsFile.path)
        }
    }

    private func armFocusFileWatcher(assertionsPath: String) {
        if let existing = focusFileWatcher {
            existing.cancel()
            focusFileWatcher = nil
            focusFileFd = -1
        }

        guard FileManager.default.fileExists(atPath: assertionsPath) else { return }

        let fd = open(assertionsPath, O_EVTONLY)
        guard fd >= 0 else { return }
        focusFileFd = fd

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            let flags = watcher.data
            self?.triggerInstantFocusUpdate()
            if flags.contains(.delete) || flags.contains(.rename) {
                watcher.cancel()
                self?.focusFileWatcher = nil
                self?.focusFileFd = -1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.armFocusFileWatcher(assertionsPath: assertionsPath)
                }
            }
        }
        watcher.setCancelHandler {
            close(fd)
        }
        watcher.resume()
        focusFileWatcher = watcher
    }

    private func triggerInstantFocusUpdate() {
        for item in focusUpdateWorkItems {
            item.cancel()
        }
        focusUpdateWorkItems.removeAll()

        ensureFocusWatchersArmed()

        // Staggered execution: immediate (0.04s) for in-memory / fast updates,
        // and 0.2s, 0.45s, 0.9s to catch asynchronous filesystem flushes from dndd
        let intervals = [0.04, 0.20, 0.45, 0.90]
        for delay in intervals {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.publishSensorState(trigger: "Focus Changed")
            }
            focusUpdateWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func startSensorLoop() {
        timer?.invalidate()
        let interval = max(5.0, config.updateInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Periodic")
            }
        }
    }

    public func publishSensorState(trigger: String = "Periodic") {
        let snapshot = sensorManager.collectSnapshot(trigger: trigger)
        lastSnapshot = snapshot

        // 1. CPU & Memory
        let showCpu = config.isSensorEnabled("cpu_usage")
        let showRam = config.isSensorEnabled("memory_usage")
        let showStats = showCpu || showRam
        if showCpu && showRam {
            statsMenuItem.title = "  CPU: \(Int(snapshot.cpuUsagePercent))% | RAM: \(Int(snapshot.memoryUsagePercent))%"
        } else if showCpu {
            statsMenuItem.title = "  CPU: \(Int(snapshot.cpuUsagePercent))%"
        } else if showRam {
            statsMenuItem.title = "  RAM: \(Int(snapshot.memoryUsagePercent))%"
        }
        statsMenuItem.isHidden = !showStats

        // 2. Frontmost Application
        let showApp = config.isSensorEnabled("frontmost_app")
        appMenuItem.title = "  App: \(snapshot.frontmostApp)"
        appMenuItem.isHidden = !showApp

        // 3. Microphone (In-Use and/or Active Mic Name)
        let showMicInUse = config.isSensorEnabled("audio_input_in_use")
        let showMicName = config.isSensorEnabled("active_audio_input")
        let showMic = showMicInUse || showMicName
        if showMicName && showMicInUse {
            micMenuItem.title = "  Mic: \(snapshot.activeAudioInput)\(snapshot.isMicInUse ? " (🎙️ In Use)" : "")"
        } else if showMicName {
            micMenuItem.title = "  Mic: \(snapshot.activeAudioInput)"
        } else if showMicInUse {
            micMenuItem.title = "  Mic: \(snapshot.isMicInUse ? "🎙️ In Use" : "Inactive")"
        }
        micMenuItem.isHidden = !showMic

        // 4. Camera (In-Use and/or Active Camera Name)
        let showCamInUse = config.isSensorEnabled("camera_in_use")
        let showCamName = config.isSensorEnabled("active_camera")
        let showCam = showCamInUse || showCamName
        if showCamName && showCamInUse {
            camMenuItem.title = "  Camera: \(snapshot.activeCamera)\(snapshot.isCameraInUse ? " (📷 In Use)" : "")"
        } else if showCamName {
            camMenuItem.title = "  Camera: \(snapshot.activeCamera)"
        } else if showCamInUse {
            camMenuItem.title = "  Camera: \(snapshot.isCameraInUse ? "📷 In Use" : "Inactive")"
        }
        camMenuItem.isHidden = !showCam

        // 5. Audio Output (In-Use and/or Active Output Name)
        let showAudioInUse = config.isSensorEnabled("audio_output_in_use")
        let showAudioName = config.isSensorEnabled("active_audio_output")
        let showAudio = showAudioInUse || showAudioName
        if showAudioName && showAudioInUse {
            audioMenuItem.title = "  Audio: \(snapshot.activeAudioOutput)\(snapshot.isAudioOutputInUse ? " (Playing)" : "")"
        } else if showAudioName {
            audioMenuItem.title = "  Audio: \(snapshot.activeAudioOutput)"
        } else if showAudioInUse {
            audioMenuItem.title = "  Audio: \(snapshot.isAudioOutputInUse ? "Playing" : "Inactive")"
        }
        audioMenuItem.isHidden = !showAudio

        // 6. Battery & Power
        let showBattLevel = config.isSensorEnabled("internal_battery_level")
        let showBattCharging = config.isSensorEnabled("internal_battery_charging")
        let showBattState = config.isSensorEnabled("internal_battery_state")
        let showPowerSource = config.isSensorEnabled("power_source")
        let showBatt = showBattLevel || showBattCharging || showBattState || showPowerSource
        if showBatt {
            var details: [String] = []
            if showBattState {
                details.append(snapshot.batteryState)
            } else if showBattCharging {
                details.append(snapshot.isCharging ? "Charging" : "Not Charging")
            }
            if showPowerSource {
                details.append(snapshot.powerSource)
            }

            if showBattLevel {
                if details.isEmpty {
                    battMenuItem.title = "  Battery: \(snapshot.batteryLevel)%"
                } else {
                    battMenuItem.title = "  Battery: \(snapshot.batteryLevel)% (\(details.joined(separator: " - ")))"
                }
            } else {
                if !details.isEmpty {
                    if !showBattState && !showBattCharging && showPowerSource {
                        battMenuItem.title = "  Power Source: \(snapshot.powerSource)"
                    } else {
                        battMenuItem.title = "  Battery: " + details.joined(separator: " - ")
                    }
                }
            }
        }
        battMenuItem.isHidden = !showBatt

        // 7. Network / Wi-Fi
        let showWifiSsid = config.isSensorEnabled("wifi_ssid")
        let showWifiBssid = config.isSensorEnabled("bssid")
        let showConnType = config.isSensorEnabled("connection_type")
        let showWifi = showWifiSsid || showWifiBssid || showConnType
        if showWifi {
            if showWifiSsid && showWifiBssid {
                wifiMenuItem.title = "  Wi-Fi: \(snapshot.wifiSSID) (\(snapshot.wifiBSSID))"
            } else if showWifiSsid {
                wifiMenuItem.title = "  Wi-Fi: \(snapshot.wifiSSID)"
            } else if showWifiBssid {
                wifiMenuItem.title = "  Wi-Fi BSSID: \(snapshot.wifiBSSID)"
            } else if showConnType {
                wifiMenuItem.title = "  Network: \(snapshot.connectionType)"
            }
        }
        wifiMenuItem.isHidden = !showWifi

        // 8. Focus Mode
        let showFocusActive = config.isSensorEnabled("focus")
        let showFocusName = config.isSensorEnabled("focus_mode")
        let showFocus = showFocusActive || showFocusName
        if showFocus {
            if showFocusName {
                focusMenuItem.title = "  Focus Mode: \(snapshot.focusMode)"
            } else if showFocusActive {
                focusMenuItem.title = "  Focus: \(snapshot.isFocusActive ? "Active" : "Off")"
            }
        }
        focusMenuItem.isHidden = !showFocus

        let hasAnyLive = showApp || showMic || showCam || showAudio || showBatt || showWifi || showFocus || showStats
        liveHeader.isHidden = !hasAnyLive
        liveHeaderSeparator.isHidden = !hasAnyLive

        if isConnected {
            discovery.publishState(snapshot: snapshot)
        }
    }

    // MARK: - Actions

    public func openPreferences(tab: PreferencesWindowController.Tab = .connection) {
        if prefsWindowController == nil {
            prefsWindowController = PreferencesWindowController(
                config: config,
                onSave: { [weak self] newConfig in
                    guard let self = self else { return }
                    self.config = newConfig
                    self.publishSensorState(trigger: "Preferences Saved")
                    self.mqttClient.disconnect()
                    self.setupMQTT()
                    self.startSensorLoop()
                }
            )
        }
        prefsWindowController?.show(tab: tab)
    }

    @objc func openPreferencesClicked(_ sender: Any? = nil) {
        openPreferences(tab: .connection)
    }

    @objc func openOnboardingWizard(_ sender: Any? = nil) {
        openPreferences(tab: .permissions)
    }


    private func updateLoginItemState() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            loginItemMenuItem.state = (status == .enabled) ? .on : .off
        } else {
            loginItemMenuItem.isHidden = true
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    loginItemMenuItem.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    loginItemMenuItem.state = .on
                }
            } catch {
                print("Failed to toggle login item: \(error)")
            }
        }
    }

    @objc private func quitClicked() {
        mqttClient.disconnect()
        NSApplication.shared.terminate(nil)
    }
}
