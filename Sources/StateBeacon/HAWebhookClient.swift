import Foundation
import AppKit

public final class HAWebhookClient: @unchecked Sendable {
    public struct RegistrationResult: Sendable {
        public let webhookId: String
        public let cloudhookURL: String?
        public let remoteUIURL: String?
    }

    private let config: AppConfig
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketPingTimer: Timer?
    private var isRegistered = false
    private var registeredSensors = Set<String>()
    private var hasRegisteredSensors = false
    private var hasProvisionedScripts = false
    private var haDeviceRegistryId: String?
    private var isConnectedState = false
    private var isWebSocketConnected = false
    private var isConnectingWebSocket = false
    private var reconnectAttempt = 0
    private var isClosed = false

    public var onConnect: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable (Error?) -> Void)?
    public var onCommand: (@Sendable (String, String?) -> Void)?

    public init(config: AppConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15.0
        sessionConfig.timeoutIntervalForResource = 30.0
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    deinit {
        disconnect()
    }

    // MARK: - Lifecycle

    public func connect() {
        isClosed = false
        if !config.haWebhookId.isEmpty {
            isRegistered = true
            Task {
                do {
                    try await registerAllSensorsIfNeeded()
                    await provisionRemoteControlScriptsIfNeeded()
                    await MainActor.run {
                        if !self.isConnectedState {
                            self.isConnectedState = true
                            self.onConnect?()
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isConnectedState = false
                        self.onDisconnect?(error)
                    }
                }
            }
        } else if !config.haToken.isEmpty && !config.haURL.isEmpty {
            Task {
                do {
                    let result = try await Self.register(
                        haURL: config.haURL,
                        token: config.haToken,
                        deviceId: config.deviceId,
                        deviceName: config.deviceName
                    )
                    var mutable = self.config
                    mutable.haWebhookId = result.webhookId
                    if let cloud = result.cloudhookURL {
                        mutable.haCloudhookURL = cloud
                    }
                    mutable.save()
                    self.isRegistered = true
                    try await self.registerAllSensorsIfNeeded()
                    await self.provisionRemoteControlScriptsIfNeeded()
                    await MainActor.run {
                        if !self.isConnectedState {
                            self.isConnectedState = true
                            self.onConnect?()
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isConnectedState = false
                        self.onDisconnect?(error)
                    }
                }
            }
        }

        if config.haEnableWebSocket && !config.haToken.isEmpty && !config.haURL.isEmpty {
            connectWebSocket()
        }
    }

    public func disconnect() {
        isClosed = true
        isConnectedState = false
        hasProvisionedScripts = false
        webSocketPingTimer?.invalidate()
        webSocketPingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isWebSocketConnected = false
        isConnectingWebSocket = false
    }

    // MARK: - Registration API

    public static func register(
        haURL: String,
        token: String,
        deviceId: String,
        deviceName: String
    ) async throws -> RegistrationResult {
        let cleanBase = haURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanBase)/api/mobile_app/registrations") else {
            throw NSError(domain: "HAWebhookClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Home Assistant URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let registrationPayload: [String: Any] = [
            "device_id": deviceId,
            "app_id": "io.statebeacon.macos",
            "app_name": "StateBeacon",
            "app_version": appVersion,
            "device_name": deviceName,
            "manufacturer": "Apple",
            "model": "Mac (\(ProcessInfo.processInfo.operatingSystemVersionString))",
            "os_name": "macOS",
            "os_version": "\(osVersion.majorVersion).\(osVersion.minorVersion)",
            "supports_encryption": false,
            "app_data": [:]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: registrationPayload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "HAWebhookClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "HAWebhookClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Registration failed (\(httpResponse.statusCode)): \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let webhookId = json["webhook_id"] as? String else {
            throw NSError(domain: "HAWebhookClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "No webhook_id returned by Home Assistant"])
        }

        let cloudhook = json["cloudhook_url"] as? String
        let remoteUI = json["remote_ui_url"] as? String

        return RegistrationResult(webhookId: webhookId, cloudhookURL: cloudhook, remoteUIURL: remoteUI)
    }

    // MARK: - Webhook URL Resolution

    private var webhookURL: URL? {
        if !config.haCloudhookURL.isEmpty, let cloudUrl = URL(string: config.haCloudhookURL) {
            return cloudUrl
        }
        guard !config.haWebhookId.isEmpty else { return nil }
        let cleanBase = config.haURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(cleanBase)/api/webhook/\(config.haWebhookId)")
    }

    // MARK: - Sensor Registration

    public func registerAllSensorsIfNeeded() async throws {
        guard !hasRegisteredSensors else { return }
        guard let endpoint = webhookURL else {
            throw NSError(domain: "HAWebhookClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No webhook URL configured"])
        }

        let definitions = PreferencesWindowController.availableSensors
        var didSucceedAny = false
        var lastError: Error?

        for def in definitions {
            // Do not register remote controls as sensors with HA's mobile_app webhook.
            // mobile_app only supports sensor and binary_sensor (read-only states), which would display as dummy "--" rows.
            // Remote controls are provided as actionable scripts linked under Related.
            if def.category == "Remote Controls" || def.id == "sleep" || def.id == "lock_screen" || def.id == "mute_audio" {
                continue
            }

            let isEnabled = config.isSensorEnabled(def.id) && PreferencesWindowController.isSensorPermitted(def.id)
            let isBinary = (def.category == "Focus Mode" && def.id == "focus") ||
                           def.id == "active" ||
                           def.id == "audio_muted" ||
                           def.id == "camera_in_use" ||
                           def.id == "internal_battery_charging"

            var dataDict: [String: Any] = [
                "unique_id": def.id,
                "name": def.name,
                "type": isBinary ? "binary_sensor" : "sensor",
                "state": isBinary ? false : "--",
                "disabled": !isEnabled
            ]

            if let icon = iconForSensor(def.id) {
                dataDict["icon"] = icon
            }
            if let unit = unitForSensor(def.id) {
                dataDict["unit_of_measurement"] = unit
            }
            if let devClass = deviceClassForSensor(def.id) {
                dataDict["device_class"] = devClass
            }
            if let stateClass = stateClassForSensor(def.id) {
                dataDict["state_class"] = stateClass
            }

            let payload: [String: Any] = [
                "type": "register_sensor",
                "data": dataDict
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else { continue }
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonData

            do {
                let (data, response) = try await urlSession.data(for: req)
                if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201) {
                    didSucceedAny = true
                } else if let http = response as? HTTPURLResponse {
                    let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    lastError = NSError(domain: "HAWebhookClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr])
                }
            } catch {
                lastError = error
            }
        }

        if didSucceedAny {
            hasRegisteredSensors = true
        } else if let error = lastError {
            throw error
        }
    }

    // MARK: - Auto-Provision Remote Control Scripts

    public func provisionRemoteControlScriptsIfNeeded(force: Bool = false) async {
        if !force {
            guard !hasProvisionedScripts else { return }
        }
        guard !config.haURL.isEmpty && !config.haToken.isEmpty else { return }

        let cleanBase = config.haURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanId = config.deviceId.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let token = config.haToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let commands: [(actionId: String, name: String, icon: String, cmd: String, desc: String)] = [
            ("sleep", "Sleep \(config.deviceName)", "mdi:power-sleep", "sleep", "Puts \(config.deviceName) to sleep via StateBeacon"),
            ("lock_screen", "Lock Screen \(config.deviceName)", "mdi:lock", "lock_screen", "Locks the screen of \(config.deviceName) via StateBeacon"),
            ("mute_audio", "Toggle Mute \(config.deviceName)", "mdi:volume-mute", "mute_audio", "Toggles audio mute on \(config.deviceName) via StateBeacon")
        ]

        for item in commands {
            let scriptSlug = "statebeacon_\(cleanId)_\(item.actionId)"
            guard let url = URL(string: "\(cleanBase)/api/config/script/config/\(scriptSlug)") else { continue }

            let isEnabled = config.isSensorEnabled(item.actionId) && PreferencesWindowController.isSensorPermitted(item.actionId)

            if isEnabled {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var sequence: [[String: Any]] = [
                    [
                        "event": "statebeacon_command",
                        "event_data": [
                            "command": item.cmd,
                            "device_id": config.deviceId
                        ]
                    ]
                ]

                // Link script directly to the Home Assistant Device Page under Related
                if let devId = haDeviceRegistryId {
                    sequence.append([
                        "action": "homeassistant.update_entity",
                        "target": [
                            "device_id": devId
                        ]
                    ])
                }

                let payload: [String: Any] = [
                    "alias": item.name,
                    "icon": item.icon,
                    "description": item.desc,
                    "sequence": sequence,
                    "mode": "single"
                ]

                if let body = try? JSONSerialization.data(withJSONObject: payload, options: []) {
                    req.httpBody = body
                    _ = try? await urlSession.data(for: req)
                }
            } else {
                // If remote control is disabled by user in Preferences, remove script from Home Assistant
                var req = URLRequest(url: url)
                req.httpMethod = "DELETE"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                _ = try? await urlSession.data(for: req)
            }
        }

        hasProvisionedScripts = true
    }

    // MARK: - Telemetry Dispatch

    public func publishState(snapshot: SensorSnapshot) {
        guard let endpoint = webhookURL else { return }

        var sensorUpdates: [[String: Any]] = []

        func addSensor(id: String, state: Any, type: String = "sensor", attributes: [String: Any]? = nil, icon: String? = nil) {
            guard config.isSensorEnabled(id) && PreferencesWindowController.isSensorPermitted(id) else { return }
            var dict: [String: Any] = [
                "unique_id": id,
                "type": type,
                "state": state
            ]
            if let attrs = attributes, !attrs.isEmpty {
                dict["attributes"] = attrs
            }
            if let ic = icon {
                dict["icon"] = ic
            }
            sensorUpdates.append(dict)
        }

        // 1. Binary Sensors
        addSensor(id: "active", state: snapshot.isUserActive, type: "binary_sensor", icon: "mdi:monitor")
        addSensor(id: "audio_muted", state: snapshot.isAudioMuted, type: "binary_sensor", icon: "mdi:volume-mute")
        addSensor(id: "camera_in_use", state: snapshot.isCameraInUse, type: "binary_sensor", icon: "mdi:camera")
        addSensor(id: "focus", state: snapshot.isFocusActive, type: "binary_sensor", icon: "mdi:moon-waning-crescent")
        addSensor(id: "internal_battery_charging", state: snapshot.isCharging, type: "binary_sensor")

        // 2. Numeric & Measurement Sensors
        addSensor(id: "cpu_usage", state: round(snapshot.cpuUsagePercent * 10) / 10.0, icon: "mdi:cpu-64-bit")
        addSensor(id: "memory_usage", state: round(snapshot.memoryUsagePercent * 10) / 10.0, icon: "mdi:memory")
        addSensor(id: "gpu_load", state: round(snapshot.gpuUsagePercent * 10) / 10.0, icon: "mdi:expansion-card")
        addSensor(id: "idle_time", state: snapshot.idleSeconds, icon: "mdi:timer-outline")
        addSensor(id: "internal_battery_level", state: snapshot.batteryLevel)
        addSensor(id: "displays", state: snapshot.displayCount, icon: "mdi:monitor-multiple")
        addSensor(id: "current_volume", state: snapshot.currentVolume, icon: "mdi:volume-medium")
        addSensor(id: "current_clock_speed", state: snapshot.currentClockSpeed, icon: "mdi:speedometer")

        // 3. String & Diagnostic Sensors
        addSensor(id: "frontmost_app", state: snapshot.frontmostApp, icon: "mdi:application")
        addSensor(id: "active_window", state: snapshot.activeWindowTitle, icon: "mdi:window-maximize")
        addSensor(id: "focus_mode", state: snapshot.focusMode, icon: "mdi:moon-waning-crescent")
        addSensor(id: "active_camera", state: snapshot.activeCamera, icon: "mdi:webcam")
        addSensor(id: "internal_battery_state", state: snapshot.batteryState, icon: "mdi:battery-heart")
        addSensor(id: "power_source", state: snapshot.powerSource, icon: "mdi:power-plug")
        addSensor(id: "primary_display_id", state: snapshot.primaryDisplayId, icon: "mdi:monitor-star")
        addSensor(id: "connection_type", state: snapshot.connectionType, icon: "mdi:network")
        addSensor(id: "wifi_ssid", state: snapshot.wifiSSID, icon: "mdi:wifi")
        addSensor(id: "bssid", state: snapshot.wifiBSSID, icon: "mdi:access-point")
        addSensor(id: "last_update_trigger", state: snapshot.lastUpdateTrigger, icon: "mdi:update")
        addSensor(id: "app_version", state: snapshot.appVersion, icon: "mdi:tag-outline")
        addSensor(id: "last_boot", state: snapshot.lastBoot, icon: "mdi:clock-time-three-outline")
        addSensor(id: "last_active", state: snapshot.lastActive, icon: "mdi:clock-time-three-outline")
        addSensor(id: "session_state", state: snapshot.sessionState, icon: "mdi:lock")
        addSensor(id: "last_system_state_change", state: snapshot.lastSystemStateChange, icon: "mdi:cog")
        addSensor(id: "logged_user", state: snapshot.loggedUser, icon: "mdi:account")
        addSensor(id: "logged_users", state: snapshot.loggedUsers, icon: "mdi:account-group")
        addSensor(id: "accent_color", state: snapshot.accentColor, icon: "mdi:palette")
        addSensor(id: "monitor_power_state", state: snapshot.monitorPowerState, icon: "mdi:monitor")
        addSensor(id: "thermal_state", state: snapshot.thermalState, icon: "mdi:thermometer-alert")
        addSensor(id: "geo_location", state: snapshot.geoLocation, icon: "mdi:earth")

        // 4. Sensors with Rich Attributes
        addSensor(
            id: "audio_output",
            state: snapshot.activeAudioOutput,
            attributes: [
                "in_use": snapshot.isAudioOutputInUse,
                "volume": snapshot.currentVolume,
                "muted": snapshot.isAudioMuted
            ],
            icon: "mdi:headphones"
        )
        addSensor(
            id: "audio_input",
            state: snapshot.activeAudioInput,
            attributes: [
                "in_use": snapshot.isMicInUse
            ],
            icon: "mdi:microphone-outline"
        )
        addSensor(
            id: "bluetooth_devices",
            state: snapshot.bluetoothDevicesCount,
            attributes: ["list": snapshot.bluetoothDevicesJson],
            icon: "mdi:bluetooth"
        )
        addSensor(
            id: "bluetooth_le_devices",
            state: snapshot.bluetoothLeDevicesCount,
            attributes: ["list": snapshot.bluetoothLeDevicesJson],
            icon: "mdi:bluetooth-connect"
        )

        let payload: [String: Any] = [
            "type": "update_sensor_states",
            "data": sensorUpdates
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            if let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 201) {
                if !self.isConnectedState {
                    self.isConnectedState = true
                    DispatchQueue.main.async {
                        self.onConnect?()
                    }
                }
            } else if let error = error {
                if self.isConnectedState {
                    self.isConnectedState = false
                    DispatchQueue.main.async {
                        self.onDisconnect?(error)
                    }
                }
            }
        }
        task.resume()

        // 5. Send GPS Location Update if Geolocation is Enabled and Valid
        if config.isSensorEnabled("geo_location") && PreferencesWindowController.isSensorPermitted("geo_location") {
            let parts = snapshot.geoLocation.split(separator: ",")
            if parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) {
                var locData: [String: Any] = [
                    "gps": [lat, lon],
                    "battery": snapshot.batteryLevel
                ]
                if parts.count >= 3, let alt = Double(parts[2]) {
                    locData["altitude"] = alt
                }
                let locPayload: [String: Any] = [
                    "type": "update_location",
                    "data": locData
                ]
                if let locJson = try? JSONSerialization.data(withJSONObject: locPayload, options: []) {
                    var locReq = URLRequest(url: endpoint)
                    locReq.httpMethod = "POST"
                    locReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    locReq.httpBody = locJson
                    urlSession.dataTask(with: locReq).resume()
                }
            }
        }
    }

    // MARK: - Persistent WebSocket Channel (Bidirectional Commands & Live Status)

    private func connectWebSocket() {
        guard !isClosed, !isConnectingWebSocket else { return }
        isConnectingWebSocket = true

        let cleanBase = config.haURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wsScheme = cleanBase.lowercased().starts(with: "https://") ? "wss://" : "ws://"
        let hostPart = cleanBase.replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)

        guard let wsUrl = URL(string: "\(wsScheme)\(hostPart)/api/websocket") else {
            isConnectingWebSocket = false
            return
        }

        let task = urlSession.webSocketTask(with: wsUrl)
        self.webSocketTask = task
        task.resume()

        listenWebSocket(task: task)
    }

    private func listenWebSocket(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self, !self.isClosed else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWebSocketMessage(text: text, task: task)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleWebSocketMessage(text: text, task: task)
                    }
                @unknown default:
                    break
                }
                self.listenWebSocket(task: task)

            case .failure(_):
                self.isWebSocketConnected = false
                self.isConnectingWebSocket = false
                self.webSocketPingTimer?.invalidate()
                self.webSocketPingTimer = nil
                DispatchQueue.main.async {
                    self.scheduleWebSocketReconnect()
                }
            }
        }
    }

    private func handleWebSocketMessage(text: String, task: URLSessionWebSocketTask) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "auth_required":
            let authMsg: [String: Any] = [
                "type": "auth",
                "access_token": config.haToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            if let authData = try? JSONSerialization.data(withJSONObject: authMsg, options: []),
               let authString = String(data: authData, encoding: .utf8) {
                task.send(.string(authString)) { _ in }
            }

        case "auth_ok":
            isWebSocketConnected = true
            isConnectingWebSocket = false
            reconnectAttempt = 0
            DispatchQueue.main.async {
                if !self.isConnectedState {
                    self.isConnectedState = true
                    self.onConnect?()
                }
                self.startWebSocketPing()
            }

            // Subscribe only to custom StateBeacon command events (0 idle CPU, avoids global call_service event flooding)
            let sub1: [String: Any] = [
                "id": 1,
                "type": "subscribe_events",
                "event_type": "statebeacon_command"
            ]
            if let d1 = try? JSONSerialization.data(withJSONObject: sub1, options: []),
               let s1 = String(data: d1, encoding: .utf8) {
                task.send(.string(s1)) { _ in }
            }

            // Fetch device registry to resolve Home Assistant internal 32-character device ID for Related linking
            let subDevs: [String: Any] = [
                "id": 100,
                "type": "config/device_registry/list"
            ]
            if let dDev = try? JSONSerialization.data(withJSONObject: subDevs, options: []),
               let sDev = String(data: dDev, encoding: .utf8) {
                task.send(.string(sDev)) { _ in }
            }

        case _ where (json["id"] as? Int) == 100:
            if let list = json["result"] as? [[String: Any]] {
                for dev in list {
                    if let identifiers = dev["identifiers"] as? [[Any]] {
                        for ident in identifiers {
                            if ident.count >= 2,
                               let domain = ident[0] as? String, domain == "mobile_app",
                               let devId = ident[1] as? String, devId == config.deviceId {
                                self.haDeviceRegistryId = dev["id"] as? String
                                Task { [weak self] in
                                    await self?.provisionRemoteControlScriptsIfNeeded(force: true)
                                }
                                break
                            }
                        }
                    }
                }
            }

        case "auth_invalid":
            isWebSocketConnected = false
            isConnectingWebSocket = false
            let message = json["message"] as? String ?? "Invalid Token"
            DispatchQueue.main.async {
                self.isConnectedState = false
                self.onDisconnect?(NSError(domain: "HAWebSocket", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication failed: \(message)"]))
            }

        case "event":
            guard let event = json["event"] as? [String: Any],
                  let eventType = event["event_type"] as? String else {
                return
            }

            if eventType == "statebeacon_command", let eventData = event["data"] as? [String: Any] {
                let targetId = eventData["device_id"] as? String
                if targetId == nil || targetId == config.deviceId {
                    if let cmd = eventData["command"] as? String {
                        let param = eventData["parameter"] as? String
                        DispatchQueue.main.async {
                            self.onCommand?(cmd, param)
                        }
                    }
                }
            }

        default:
            break
        }
    }

    private func startWebSocketPing() {
        webSocketPingTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let task = self.webSocketTask, self.isWebSocketConnected else { return }
            task.sendPing { error in
                if error != nil {
                    self.isWebSocketConnected = false
                    self.scheduleWebSocketReconnect()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.webSocketPingTimer = t
    }

    private func scheduleWebSocketReconnect() {
        guard !isClosed, config.haEnableWebSocket, !config.haToken.isEmpty else { return }
        reconnectAttempt += 1
        let delays = [2.0, 5.0, 10.0, 20.0, 30.0]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isClosed, !self.isWebSocketConnected else { return }
            self.connectWebSocket()
        }
    }

    // MARK: - Sensor Meta Helpers

    private func iconForSensor(_ id: String) -> String? {
        switch id {
        case "frontmost_app": return "mdi:application"
        case "active_window": return "mdi:window-maximize"
        case "active": return "mdi:monitor"
        case "idle_time": return "mdi:timer-outline"
        case "cpu_usage": return "mdi:cpu-64-bit"
        case "memory_usage": return "mdi:memory"
        case "displays": return "mdi:monitor-multiple"
        case "primary_display_id": return "mdi:monitor-star"
        case "monitor_power_state": return "mdi:monitor"
        case "session_state": return "mdi:lock"
        case "last_system_state_change": return "mdi:cog"
        case "logged_user": return "mdi:account"
        case "logged_users": return "mdi:account-group"
        case "last_boot", "last_active": return "mdi:clock-time-three-outline"
        case "accent_color": return "mdi:palette"
        case "app_version": return "mdi:tag-outline"
        case "current_clock_speed": return "mdi:speedometer"
        case "gpu_load": return "mdi:expansion-card"
        case "internal_device": return "mdi:thermometer-alert"
        case "bluetooth_devices": return "mdi:bluetooth"
        case "bluetooth_le_devices": return "mdi:bluetooth-connect"
        case "audio_input": return "mdi:microphone-outline"
        case "audio_output": return "mdi:headphones"
        case "current_volume": return "mdi:volume-medium"
        case "audio_muted": return "mdi:volume-mute"
        case "camera_in_use": return "mdi:camera"
        case "active_camera": return "mdi:webcam"
        case "internal_battery_state": return "mdi:battery-heart"
        case "power_source": return "mdi:power-plug"
        case "wifi_ssid": return "mdi:wifi"
        case "bssid": return "mdi:access-point"
        case "connection_type": return "mdi:network"
        case "geo_location": return "mdi:earth"
        case "focus", "focus_mode": return "mdi:moon-waning-crescent"
        default: return nil
        }
    }

    private func unitForSensor(_ id: String) -> String? {
        switch id {
        case "cpu_usage", "memory_usage", "gpu_load", "current_volume", "internal_battery_level":
            return "%"
        case "idle_time":
            return "s"
        case "current_clock_speed":
            return "MHz"
        default:
            return nil
        }
    }

    private func deviceClassForSensor(_ id: String) -> String? {
        switch id {
        case "internal_battery_level": return "battery"
        case "internal_battery_charging": return "battery_charging"
        case "current_clock_speed": return "frequency"
        case "last_boot", "last_active": return "timestamp"
        default: return nil
        }
    }

    private func stateClassForSensor(_ id: String) -> String? {
        switch id {
        case "cpu_usage", "memory_usage", "gpu_load", "current_volume", "internal_battery_level", "idle_time", "current_clock_speed", "bluetooth_devices", "bluetooth_le_devices":
            return "measurement"
        default:
            return nil
        }
    }
}
