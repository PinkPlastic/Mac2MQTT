import AppKit
import ServiceManagement
import CoreAudio
import AudioToolbox
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

    // Instant Active Window & Title Watchers
    private var activeAXObserver: AXObserver?
    private var activeAXSource: CFRunLoopSource?
    private var activeAXPid: pid_t = 0
    private var windowUpdateWorkItem: DispatchWorkItem?
    private var lastPublishedWindowTitle: String = ""

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
    private var loginItemMenuItem: NSMenuItem!

    // Live Sensors Twirl-Down Submenu
    private var allSensorsMenuItem: NSMenuItem!
    private var allSensorsMenu: NSMenu!

    // Section Headers
    private var headerSystem: NSMenuItem!
    private var headerHardware: NSMenuItem!
    private var headerAudio: NSMenuItem!
    private var headerBattery: NSMenuItem!
    private var headerNetwork: NSMenuItem!
    private var headerFocus: NSMenuItem!
    private var headerControls: NSMenuItem!

    // Consolidated Space-Saving Submenu Items
    // System & Activity
    private var subItemAppAndWindow: NSMenuItem!
    private var subItemUserAndIdle: NSMenuItem!
    private var subItemPerf: NSMenuItem!
    private var subItemDisplays: NSMenuItem!
    private var subItemSession: NSMenuItem!
    private var subItemLoggedUsers: NSMenuItem!
    private var subItemTimestamps: NSMenuItem!
    private var subItemSysInfo: NSMenuItem!

    // Peripherals & Hardware
    private var subItemThermal: NSMenuItem!
    private var subItemBluetooth: NSMenuItem!

    // Audio & Video
    private var subItemAudioIn: NSMenuItem!
    private var subItemAudioOut: NSMenuItem!
    private var subItemCamera: NSMenuItem!

    // Battery & Power
    private var subItemBattery: NSMenuItem!

    // Network & Location
    private var subItemNetwork: NSMenuItem!
    private var subItemGeo: NSMenuItem!

    // Focus Mode
    private var subItemFocus: NSMenuItem!

    // Remote Controls
    private var subItemMuteAction: NSMenuItem!
    private var subItemLockAction: NSMenuItem!
    private var subItemSleepAction: NSMenuItem!

    public init(config: AppConfig) {
        self.config = config
        super.init()
        setupStatusItem()
        setupMQTT()
        setupEventSystem()
        startSensorLoop()
        publishSensorState(trigger: "Startup")

        // Check if onboarding needs to be completed on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            if !self.config.hasCompletedOnboarding {
                self.openPreferences(tab: .permissions)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "StateBeacon") {
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

        // Live Sensors Twirl-Down Submenu (Consolidated Space-Saving Layout)
        allSensorsMenuItem = NSMenuItem(title: "Live Sensors (41 active)", action: nil, keyEquivalent: "")
        allSensorsMenu = NSMenu(title: "Live Sensors")
        allSensorsMenu.autoenablesItems = false

        func makeHeader(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        func makeInfoItem(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        // 1. System & Activity
        headerSystem = makeHeader("── System & Activity ──")
        allSensorsMenu.addItem(headerSystem)

        subItemAppAndWindow = makeInfoItem("App: --")
        allSensorsMenu.addItem(subItemAppAndWindow)

        subItemUserAndIdle = makeInfoItem("User: --")
        allSensorsMenu.addItem(subItemUserAndIdle)

        subItemPerf = makeInfoItem("CPU: -- | RAM: --")
        allSensorsMenu.addItem(subItemPerf)

        subItemDisplays = makeInfoItem("Displays: --")
        allSensorsMenu.addItem(subItemDisplays)

        subItemSession = makeInfoItem("Session: --")
        allSensorsMenu.addItem(subItemSession)

        subItemLoggedUsers = makeInfoItem("Logged User: --")
        allSensorsMenu.addItem(subItemLoggedUsers)

        subItemTimestamps = makeInfoItem("Last Active: --")
        allSensorsMenu.addItem(subItemTimestamps)

        subItemSysInfo = makeInfoItem("Accent: --")
        allSensorsMenu.addItem(subItemSysInfo)

        // 2. Peripherals & Hardware
        headerHardware = makeHeader("── Peripherals & Hardware ──")
        allSensorsMenu.addItem(headerHardware)

        subItemThermal = makeInfoItem("Thermal State: --")
        allSensorsMenu.addItem(subItemThermal)

        subItemBluetooth = makeInfoItem("Bluetooth: --")
        allSensorsMenu.addItem(subItemBluetooth)

        // 3. Audio & Video
        headerAudio = makeHeader("── Audio & Video ──")
        allSensorsMenu.addItem(headerAudio)

        subItemAudioIn = makeInfoItem("Audio In: --")
        allSensorsMenu.addItem(subItemAudioIn)

        subItemAudioOut = makeInfoItem("Audio Out: --")
        allSensorsMenu.addItem(subItemAudioOut)

        subItemCamera = makeInfoItem("Camera: --")
        allSensorsMenu.addItem(subItemCamera)

        // 4. Battery & Power
        headerBattery = makeHeader("── Battery & Power ──")
        allSensorsMenu.addItem(headerBattery)

        subItemBattery = makeInfoItem("Battery: --")
        allSensorsMenu.addItem(subItemBattery)

        // 5. Network & Location
        headerNetwork = makeHeader("── Network & Location ──")
        allSensorsMenu.addItem(headerNetwork)

        subItemNetwork = makeInfoItem("Network: --")
        allSensorsMenu.addItem(subItemNetwork)

        subItemGeo = makeInfoItem("Location: --")
        allSensorsMenu.addItem(subItemGeo)

        // 6. Focus Mode
        headerFocus = makeHeader("── Focus Mode ──")
        allSensorsMenu.addItem(headerFocus)

        subItemFocus = makeInfoItem("Focus: --")
        allSensorsMenu.addItem(subItemFocus)

        // 7. Remote Controls
        headerControls = makeHeader("── Remote Controls ──")
        allSensorsMenu.addItem(headerControls)

        subItemMuteAction = NSMenuItem(title: "Mute Audio", action: #selector(toggleAudioMuteAction), keyEquivalent: "")
        subItemMuteAction.target = self
        allSensorsMenu.addItem(subItemMuteAction)

        subItemLockAction = NSMenuItem(title: "Lock Screen", action: #selector(lockScreenAction), keyEquivalent: "")
        subItemLockAction.target = self
        allSensorsMenu.addItem(subItemLockAction)

        subItemSleepAction = NSMenuItem(title: "Sleep Mac", action: #selector(sleepMacAction), keyEquivalent: "")
        subItemSleepAction.target = self
        allSensorsMenu.addItem(subItemSleepAction)

        allSensorsMenuItem.submenu = allSensorsMenu
        allSensorsMenuItem.isEnabled = true
        menu.addItem(allSensorsMenuItem)

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

        let quitItem = NSMenuItem(title: "Quit StateBeacon", action: #selector(quitClicked), keyEquivalent: "q")
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

        // 1. App Switch Event & Instant Active Window Observer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "App Changed")
                self?.attachAXObserverToFrontmostApp()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.handleActiveWindowChanged()
                }
            }
        }

        // 1b. Space / Desktop Switch Event
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.attachAXObserverToFrontmostApp()
                self?.handleActiveWindowChanged()
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

        // 5. CoreAudio Master Volume Listener
        var defaultOutputID = AudioObjectID(0)
        var defSize = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddress, 0, nil, &defSize, &defaultOutputID) == noErr {
            var volAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(defaultOutputID, &volAddress, DispatchQueue.main) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.publishSensorState(trigger: "Volume Changed")
                }
            }
        }

        // 6. Focus Mode Real-time Listeners (Directory + File + Darwin + Distributed)
        setupFocusMonitoring()

        // 7. System Sleep / Wake Events (Suspend / Resume)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.lastSystemStateChange = "Suspend"
                self?.publishSensorState(trigger: "System Suspend")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.lastSystemStateChange = "Resume"
                self?.publishSensorState(trigger: "System Resume")
            }
        }

        // 8. Screen Sleep / Wake Events (DisplaySleep / PowerOn)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.monitorPowerState = "DisplaySleep"
                self?.publishSensorState(trigger: "Screen Sleep")
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.monitorPowerState = "PowerOn"
                self?.publishSensorState(trigger: "Screen Wake")
            }
        }

        // 9. Session Lock / Unlock Events (SessionLock / SessionUnlock)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.sessionStateOverride = "Locked"
                self?.sensorManager.lastSystemStateChange = "SessionLock"
                self?.publishSensorState(trigger: "Screen Locked")
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sensorManager.sessionStateOverride = "Unlocked"
                self?.sensorManager.lastSystemStateChange = "SessionUnlock"
                self?.publishSensorState(trigger: "Screen Unlocked")
            }
        }

        // 10. Thermal State Change Event
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Thermal State Changed")
            }
        }

        // Attach initial active window AXObserver
        attachAXObserverToFrontmostApp()
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

    // MARK: - Instant Active Window Monitoring

    private func attachAXObserverToFrontmostApp() {
        guard PreferencesWindowController.checkAccessibilityPermission() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        if pid == activeAXPid && activeAXObserver != nil {
            return
        }

        detachAXObserver()
        activeAXPid = pid

        let context = Unmanaged.passUnretained(self).toOpaque()
        var observer: AXObserver?
        let err = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let controller = Unmanaged<MenuBarController>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.handleActiveWindowChanged()
            }
        }, &observer)

        if err == .success, let observer = observer {
            let appElem = AXUIElementCreateApplication(pid)
            AXObserverAddNotification(observer, appElem, "AXFocusedWindowChanged" as CFString, context)
            AXObserverAddNotification(observer, appElem, "AXTitleChanged" as CFString, context)
            AXObserverAddNotification(observer, appElem, "AXMainWindowChanged" as CFString, context)
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.activeAXObserver = observer
            self.activeAXSource = source
        }
    }

    private func detachAXObserver() {
        if let source = activeAXSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            activeAXSource = nil
        }
        activeAXObserver = nil
        activeAXPid = 0
    }

    private func handleActiveWindowChanged() {
        windowUpdateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Finder"
            let currentTitle = self.sensorManager.getActiveWindowTitle(frontAppName: frontApp)
            if currentTitle != self.lastPublishedWindowTitle {
                self.publishSensorState(trigger: "Window Changed")
            }
        }
        windowUpdateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func startSensorLoop() {
        timer?.invalidate()
        let interval = max(5.0, config.updateInterval)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.publishSensorState(trigger: "Periodic")
            }
        }
        t.tolerance = interval * 0.1
        self.timer = t
    }

    public func publishSensorState(trigger: String = "Periodic") {
        let snapshot = sensorManager.collectSnapshot(trigger: trigger, config: config)
        lastSnapshot = snapshot
        lastPublishedWindowTitle = snapshot.activeWindowTitle

        // 1. Calculate Active Sensors Count & Update Submenu Title
        let activeCount = PreferencesWindowController.availableSensors.filter { def in
            config.isSensorEnabled(def.id) && PreferencesWindowController.isSensorPermitted(def.id)
        }.count

        allSensorsMenuItem.title = "Live Sensors (\(activeCount) active)"
        allSensorsMenuItem.isHidden = (activeCount == 0)
        liveHeaderSeparator.isHidden = (activeCount == 0)

        // 2. Space-Saving Submenu Items with 1:1 Visibility
        // Category 1: System & Activity
        let showFrontApp = config.isSensorEnabled("frontmost_app")
        let hasAX = PreferencesWindowController.isPermissionGranted(for: .accessibility)
        let showWin = config.isSensorEnabled("active_window") && hasAX
        if showFrontApp && showWin {
            let winTitle = snapshot.activeWindowTitle.count > 25 ? String(snapshot.activeWindowTitle.prefix(22)) + "..." : snapshot.activeWindowTitle
            subItemAppAndWindow.title = "App: \(snapshot.frontmostApp) | Window: \(winTitle)"
            subItemAppAndWindow.toolTip = snapshot.activeWindowTitle
            subItemAppAndWindow.isHidden = false
        } else if showFrontApp {
            subItemAppAndWindow.title = "App: \(snapshot.frontmostApp)"
            subItemAppAndWindow.toolTip = nil
            subItemAppAndWindow.isHidden = false
        } else if showWin {
            let winTitle = snapshot.activeWindowTitle.count > 35 ? String(snapshot.activeWindowTitle.prefix(32)) + "..." : snapshot.activeWindowTitle
            subItemAppAndWindow.title = "Active Window: \(winTitle)"
            subItemAppAndWindow.toolTip = snapshot.activeWindowTitle
            subItemAppAndWindow.isHidden = false
        } else {
            subItemAppAndWindow.isHidden = true
        }

        let showPresence = config.isSensorEnabled("active")
        let showIdle = config.isSensorEnabled("idle_time")
        if showPresence && showIdle {
            subItemUserAndIdle.title = "User: \(snapshot.isUserActive ? "Active" : "Idle") (Idle: \(Int(snapshot.idleSeconds))s)"
            subItemUserAndIdle.isHidden = false
        } else if showPresence {
            subItemUserAndIdle.title = "User Presence: \(snapshot.isUserActive ? "Active" : "Idle")"
            subItemUserAndIdle.isHidden = false
        } else if showIdle {
            subItemUserAndIdle.title = "Idle Time: \(Int(snapshot.idleSeconds))s"
            subItemUserAndIdle.isHidden = false
        } else {
            subItemUserAndIdle.isHidden = true
        }

        let showCpu = config.isSensorEnabled("cpu_usage")
        let showRam = config.isSensorEnabled("memory_usage")
        let showGpu = config.isSensorEnabled("gpu_load")
        let showClock = config.isSensorEnabled("current_clock_speed")
        var perfParts: [String] = []
        if showCpu { perfParts.append("CPU: \(Int(snapshot.cpuUsagePercent))%") }
        if showRam { perfParts.append("RAM: \(Int(snapshot.memoryUsagePercent))%") }
        if showGpu { perfParts.append("GPU: \(Int(snapshot.gpuUsagePercent))%") }
        if showClock { perfParts.append("Clock: \(snapshot.currentClockSpeed) MHz") }
        if !perfParts.isEmpty {
            subItemPerf.title = perfParts.joined(separator: " | ")
            subItemPerf.isHidden = false
        } else {
            subItemPerf.isHidden = true
        }

        let showDisplays = config.isSensorEnabled("displays")
        let showPrimaryDisp = config.isSensorEnabled("primary_display_id")
        let showDispPower = config.isSensorEnabled("monitor_power_state")
        var dispParts: [String] = []
        if showDisplays { dispParts.append("Displays: \(snapshot.displayCount)") }
        if showPrimaryDisp { dispParts.append("Primary: \(snapshot.primaryDisplayId)") }
        if showDispPower { dispParts.append("Power: \(snapshot.monitorPowerState)") }
        if !dispParts.isEmpty {
            subItemDisplays.title = dispParts.joined(separator: " | ")
            subItemDisplays.isHidden = false
        } else {
            subItemDisplays.isHidden = true
        }

        let showSession = config.isSensorEnabled("session_state")
        let showSysState = config.isSensorEnabled("last_system_state_change")
        var sessionParts: [String] = []
        if showSession { sessionParts.append("Session: \(snapshot.sessionState)") }
        if showSysState { sessionParts.append("System: \(snapshot.lastSystemStateChange)") }
        if !sessionParts.isEmpty {
            subItemSession.title = sessionParts.joined(separator: " | ")
            subItemSession.isHidden = false
        } else {
            subItemSession.isHidden = true
        }

        let showLoggedUser = config.isSensorEnabled("logged_user")
        let showLoggedUsers = config.isSensorEnabled("logged_users")
        if showLoggedUser && showLoggedUsers {
            subItemLoggedUsers.title = "Logged User: \(snapshot.loggedUser) (\(snapshot.loggedUsers))"
            subItemLoggedUsers.isHidden = false
        } else if showLoggedUser {
            subItemLoggedUsers.title = "Logged User: \(snapshot.loggedUser)"
            subItemLoggedUsers.isHidden = false
        } else if showLoggedUsers {
            subItemLoggedUsers.title = "Logged Users: \(snapshot.loggedUsers)"
            subItemLoggedUsers.isHidden = false
        } else {
            subItemLoggedUsers.isHidden = true
        }

        let showLastActive = config.isSensorEnabled("last_active")
        let showLastBoot = config.isSensorEnabled("last_boot")
        var timeParts: [String] = []
        if showLastActive { timeParts.append("Active: \(formatHumanTime(snapshot.lastActive))") }
        if showLastBoot { timeParts.append("Boot: \(formatHumanTime(snapshot.lastBoot))") }
        if !timeParts.isEmpty {
            subItemTimestamps.title = timeParts.joined(separator: " | ")
            subItemTimestamps.isHidden = false
        } else {
            subItemTimestamps.isHidden = true
        }

        let showAccent = config.isSensorEnabled("accent_color")
        let showVersion = config.isSensorEnabled("app_version")
        var sysInfoParts: [String] = []
        if showAccent { sysInfoParts.append("Accent: \(snapshot.accentColor)") }
        if showVersion { sysInfoParts.append("Version: \(snapshot.appVersion)") }
        if !sysInfoParts.isEmpty {
            subItemSysInfo.title = sysInfoParts.joined(separator: " | ")
            subItemSysInfo.isHidden = false
        } else {
            subItemSysInfo.isHidden = true
        }

        headerSystem.isHidden = subItemAppAndWindow.isHidden &&
                                subItemUserAndIdle.isHidden &&
                                subItemPerf.isHidden &&
                                subItemDisplays.isHidden &&
                                subItemSession.isHidden &&
                                subItemLoggedUsers.isHidden &&
                                subItemTimestamps.isHidden &&
                                subItemSysInfo.isHidden

        // Category 2: Peripherals & Hardware
        let showThermal = config.isSensorEnabled("internal_device")
        if showThermal {
            subItemThermal.title = "Thermal State: \(snapshot.thermalState)"
            subItemThermal.isHidden = false
        } else {
            subItemThermal.isHidden = true
        }

        let hasBt = PreferencesWindowController.isPermissionGranted(for: .bluetooth)
        let showBtClassic = config.isSensorEnabled("bluetooth_devices") && hasBt
        let showBtLe = config.isSensorEnabled("bluetooth_le_devices") && hasBt
        var btParts: [String] = []
        if showBtClassic { btParts.append("\(snapshot.bluetoothDevicesCount) Classic") }
        if showBtLe { btParts.append("\(snapshot.bluetoothLeDevicesCount) LE") }
        if !btParts.isEmpty {
            subItemBluetooth.title = "Bluetooth: \(btParts.joined(separator: " | ")) connected"
            subItemBluetooth.isHidden = false
        } else {
            subItemBluetooth.isHidden = true
        }

        headerHardware.isHidden = subItemThermal.isHidden && subItemBluetooth.isHidden

        // Category 3: Audio & Video
        let showAudioIn = config.isSensorEnabled("audio_input")
        if showAudioIn {
            subItemAudioIn.title = "Audio In: \(snapshot.activeAudioInput)\(snapshot.isMicInUse ? " (🎙️ In Use)" : " (Idle)")"
            subItemAudioIn.isHidden = false
        } else {
            subItemAudioIn.isHidden = true
        }

        let showAudioOut = config.isSensorEnabled("audio_output")
        let showVol = config.isSensorEnabled("current_volume")
        let showMuted = config.isSensorEnabled("audio_muted")
        var audioOutParts: [String] = []
        if showAudioOut { audioOutParts.append("Output: \(snapshot.activeAudioOutput)\(snapshot.isAudioOutputInUse ? " (Playing)" : "")") }
        if showVol { audioOutParts.append("Vol: \(snapshot.currentVolume)%") }
        if showMuted { audioOutParts.append("Muted: \(snapshot.isAudioMuted ? "Yes" : "No")") }
        if !audioOutParts.isEmpty {
            subItemAudioOut.title = audioOutParts.joined(separator: " | ")
            subItemAudioOut.isHidden = false
        } else {
            subItemAudioOut.isHidden = true
        }

        let showCamInUse = config.isSensorEnabled("camera_in_use")
        let showCamName = config.isSensorEnabled("active_camera")
        if showCamName && showCamInUse {
            subItemCamera.title = "Camera: \(snapshot.activeCamera) (\(snapshot.isCameraInUse ? "📷 In Use" : "Idle"))"
            subItemCamera.isHidden = false
        } else if showCamName {
            subItemCamera.title = "Camera: \(snapshot.activeCamera)"
            subItemCamera.isHidden = false
        } else if showCamInUse {
            subItemCamera.title = "Camera: \(snapshot.isCameraInUse ? "📷 In Use" : "Idle")"
            subItemCamera.isHidden = false
        } else {
            subItemCamera.isHidden = true
        }

        headerAudio.isHidden = subItemAudioIn.isHidden && subItemAudioOut.isHidden && subItemCamera.isHidden

        // Category 4: Battery & Power
        let showBattLevel = config.isSensorEnabled("internal_battery_level")
        let showBattCharging = config.isSensorEnabled("internal_battery_charging")
        let showBattState = config.isSensorEnabled("internal_battery_state")
        let showPowerSrc = config.isSensorEnabled("power_source")
        if showBattLevel {
            var details: [String] = []
            if showBattState { details.append(snapshot.batteryState) }
            if showPowerSrc { details.append(snapshot.powerSource) }
            if showBattCharging { details.append(snapshot.isCharging ? "Charging" : "Not Charging") }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: " - ")))"
            subItemBattery.title = "Battery: \(snapshot.batteryLevel)%\(suffix)"
            subItemBattery.isHidden = false
        } else {
            var details: [String] = []
            if showBattState { details.append("State: \(snapshot.batteryState)") }
            if showPowerSrc { details.append("Source: \(snapshot.powerSource)") }
            if showBattCharging { details.append("Charging: \(snapshot.isCharging ? "Yes" : "No")") }
            if !details.isEmpty {
                subItemBattery.title = details.joined(separator: " | ")
                subItemBattery.isHidden = false
            } else {
                subItemBattery.isHidden = true
            }
        }

        headerBattery.isHidden = subItemBattery.isHidden

        // Category 5: Network & Location
        let hasLocation = PreferencesWindowController.isPermissionGranted(for: .location)
        let showWifiSsid = config.isSensorEnabled("wifi_ssid") && hasLocation
        let showWifiBssid = config.isSensorEnabled("bssid") && hasLocation
        let showConnType = config.isSensorEnabled("connection_type")
        if showConnType {
            var netDetails: [String] = []
            if showWifiSsid { netDetails.append(snapshot.wifiSSID) }
            if showWifiBssid { netDetails.append(snapshot.wifiBSSID) }
            let suffix = netDetails.isEmpty ? "" : " (\(netDetails.joined(separator: " - ")))"
            subItemNetwork.title = "Network: \(snapshot.connectionType)\(suffix)"
            subItemNetwork.isHidden = false
        } else if showWifiSsid || showWifiBssid {
            var netDetails: [String] = []
            if showWifiSsid { netDetails.append("SSID: \(snapshot.wifiSSID)") }
            if showWifiBssid { netDetails.append("BSSID: \(snapshot.wifiBSSID)") }
            subItemNetwork.title = netDetails.joined(separator: " | ")
            subItemNetwork.isHidden = false
        } else {
            subItemNetwork.isHidden = true
        }

        let showGeo = config.isSensorEnabled("geo_location") && hasLocation
        if showGeo {
            subItemGeo.title = "Location: \(snapshot.geoLocation)"
            subItemGeo.isHidden = false
        } else {
            subItemGeo.isHidden = true
        }

        headerNetwork.isHidden = subItemNetwork.isHidden && subItemGeo.isHidden

        // Category 6: Focus Mode
        let hasFDA = PreferencesWindowController.isPermissionGranted(for: .fullDiskAccess)
        let showFocusActive = config.isSensorEnabled("focus") && hasFDA
        let showFocusMode = config.isSensorEnabled("focus_mode") && hasFDA
        if showFocusMode && showFocusActive {
            subItemFocus.title = "Focus: \(snapshot.focusMode) (\(snapshot.isFocusActive ? "Active" : "Off"))"
            subItemFocus.isHidden = false
        } else if showFocusMode {
            subItemFocus.title = "Focus Mode: \(snapshot.focusMode)"
            subItemFocus.isHidden = false
        } else if showFocusActive {
            subItemFocus.title = "Focus Active: \(snapshot.isFocusActive ? "Active" : "Off")"
            subItemFocus.isHidden = false
        } else {
            subItemFocus.isHidden = true
        }

        headerFocus.isHidden = subItemFocus.isHidden

        // Category 7: Remote Controls
        let showMuteControl = config.isSensorEnabled("mute_audio")
        subItemMuteAction.title = "Mute Audio (\(snapshot.isAudioMuted ? "Muted" : "Unmuted"))"
        subItemMuteAction.isHidden = !showMuteControl

        let showLockControl = config.isSensorEnabled("lock_screen")
        subItemLockAction.isHidden = !showLockControl

        let showSleepControl = config.isSensorEnabled("sleep")
        subItemSleepAction.isHidden = !showSleepControl

        headerControls.isHidden = subItemMuteAction.isHidden && subItemLockAction.isHidden && subItemSleepAction.isHidden

        if isConnected {
            discovery.publishState(snapshot: snapshot)
        }
    }

    @objc private func toggleAudioMuteAction() {
        guard let snapshot = lastSnapshot else { return }
        let newMute = !snapshot.isAudioMuted
        let script = "set volume output muted \(newMute)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.publishSensorState(trigger: "Mute Toggled")
        }
    }

    @objc private func lockScreenAction() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    @objc private func sleepMacAction() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    private func formatHumanTime(_ isoString: String) -> String {
        guard !isoString.isEmpty, isoString != "Unknown" else { return "--" }
        let cleaned = isoString.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        if cleaned.count >= 19 {
            return String(cleaned.prefix(19))
        }
        return cleaned
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
