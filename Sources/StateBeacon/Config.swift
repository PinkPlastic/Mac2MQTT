import Foundation

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case mqtt = "mqtt"
    case haWebhook = "webhook"
}

public struct AppConfig: Codable, Sendable {
    public var connectionMode: ConnectionMode

    // MQTT Broker Configuration
    public var mqttHost: String
    public var mqttPort: UInt16
    public var mqttUsername: String
    public var mqttPassword: String
    public var useTLS: Bool

    // Home Assistant Native Webhook / WAN Configuration
    public var haURL: String
    public var haToken: String
    public var haWebhookId: String
    public var haCloudhookURL: String
    public var haEnableWebSocket: Bool

    // Shared Device & Telemetry Settings
    public var deviceId: String
    public var deviceName: String
    public var updateInterval: Double
    public var hasCompletedOnboarding: Bool
    public var disabledSensors: [String]

    enum CodingKeys: String, CodingKey {
        case connectionMode
        case mqttHost, mqttPort, mqttUsername, mqttPassword, useTLS
        case haURL, haToken, haWebhookId, haCloudhookURL, haEnableWebSocket
        case deviceId, deviceName, updateInterval, hasCompletedOnboarding, disabledSensors
    }

    public init(
        connectionMode: ConnectionMode = .mqtt,
        mqttHost: String = "homeassistant.local",
        mqttPort: UInt16 = 1883,
        mqttUsername: String = "",
        mqttPassword: String = "",
        useTLS: Bool = false,
        haURL: String = "",
        haToken: String = "",
        haWebhookId: String = "",
        haCloudhookURL: String = "",
        haEnableWebSocket: Bool = true,
        deviceId: String,
        deviceName: String,
        updateInterval: Double = 15.0,
        hasCompletedOnboarding: Bool = false,
        disabledSensors: [String] = []
    ) {
        self.connectionMode = connectionMode
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUsername = mqttUsername
        self.mqttPassword = mqttPassword
        self.useTLS = useTLS
        self.haURL = haURL
        self.haToken = haToken
        self.haWebhookId = haWebhookId
        self.haCloudhookURL = haCloudhookURL
        self.haEnableWebSocket = haEnableWebSocket
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updateInterval = updateInterval
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.disabledSensors = disabledSensors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .mqtt
        mqttHost = try container.decodeIfPresent(String.self, forKey: .mqttHost) ?? "homeassistant.local"
        mqttPort = try container.decodeIfPresent(UInt16.self, forKey: .mqttPort) ?? 1883
        mqttUsername = try container.decodeIfPresent(String.self, forKey: .mqttUsername) ?? ""
        mqttPassword = try container.decodeIfPresent(String.self, forKey: .mqttPassword) ?? ""
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false

        haURL = try container.decodeIfPresent(String.self, forKey: .haURL) ?? ""
        haToken = try container.decodeIfPresent(String.self, forKey: .haToken) ?? ""
        haWebhookId = try container.decodeIfPresent(String.self, forKey: .haWebhookId) ?? ""
        haCloudhookURL = try container.decodeIfPresent(String.self, forKey: .haCloudhookURL) ?? ""
        haEnableWebSocket = try container.decodeIfPresent(Bool.self, forKey: .haEnableWebSocket) ?? true

        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        updateInterval = try container.decode(Double.self, forKey: .updateInterval)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        disabledSensors = try container.decodeIfPresent([String].self, forKey: .disabledSensors) ?? []
    }

    public func isSensorEnabled(_ id: String) -> Bool {
        return !disabledSensors.contains(id)
    }

    public mutating func setSensorEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledSensors.removeAll(where: { $0 == id })
        } else {
            if !disabledSensors.contains(id) {
                disabledSensors.append(id)
            }
        }
    }

    public static var defaultConfig: AppConfig {
        let hostname = Host.current().localizedName ?? "Mac"
        let sanitizedId = "mac_" + hostname.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        
        return AppConfig(
            connectionMode: .mqtt,
            mqttHost: "homeassistant.local",
            mqttPort: 1883,
            mqttUsername: "",
            mqttPassword: "",
            useTLS: false,
            haURL: "",
            haToken: "",
            haWebhookId: "",
            haCloudhookURL: "",
            haEnableWebSocket: true,
            deviceId: sanitizedId.isEmpty ? "my_mac" : sanitizedId,
            deviceName: hostname,
            updateInterval: 15.0,
            hasCompletedOnboarding: false,
            disabledSensors: []
        )
    }

    public static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/StateBeacon")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    public static var legacyConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/Mac2MQTT/config.json")
    }

    public static func load() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }

        // Migrate from legacy Mac2MQTT config if available
        let legacy = legacyConfigURL
        if let data = try? Data(contentsOf: legacy),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            let migrated = config
            migrated.save()
            return migrated
        }

        let initial = defaultConfig
        initial.save()
        return initial
    }

    public static func resetToDefaults() -> AppConfig {
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.removeItem(at: legacyConfigURL)
        let initial = defaultConfig
        initial.save()
        return initial
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: AppConfig.configURL)
        }
    }
}
