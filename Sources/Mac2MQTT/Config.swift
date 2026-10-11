import Foundation

public struct AppConfig: Codable {
    public var mqttHost: String
    public var mqttPort: UInt16
    public var mqttUsername: String
    public var mqttPassword: String
    public var useTLS: Bool
    public var deviceId: String
    public var deviceName: String
    public var updateInterval: Double
    public var hasCompletedOnboarding: Bool
    public var disabledSensors: [String]

    enum CodingKeys: String, CodingKey {
        case mqttHost, mqttPort, mqttUsername, mqttPassword, useTLS, deviceId, deviceName, updateInterval, hasCompletedOnboarding, disabledSensors
    }

    public init(
        mqttHost: String,
        mqttPort: UInt16,
        mqttUsername: String,
        mqttPassword: String,
        useTLS: Bool,
        deviceId: String,
        deviceName: String,
        updateInterval: Double,
        hasCompletedOnboarding: Bool = false,
        disabledSensors: [String] = []
    ) {
        self.mqttHost = mqttHost
        self.mqttPort = mqttPort
        self.mqttUsername = mqttUsername
        self.mqttPassword = mqttPassword
        self.useTLS = useTLS
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updateInterval = updateInterval
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.disabledSensors = disabledSensors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mqttHost = try container.decode(String.self, forKey: .mqttHost)
        mqttPort = try container.decode(UInt16.self, forKey: .mqttPort)
        mqttUsername = try container.decode(String.self, forKey: .mqttUsername)
        mqttPassword = try container.decode(String.self, forKey: .mqttPassword)
        useTLS = try container.decode(Bool.self, forKey: .useTLS)
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
            mqttHost: "homeassistant.local",
            mqttPort: 1883,
            mqttUsername: "",
            mqttPassword: "",
            useTLS: false,
            deviceId: sanitizedId.isEmpty ? "my_mac" : sanitizedId,
            deviceName: hostname,
            updateInterval: 15.0,
            hasCompletedOnboarding: false,
            disabledSensors: []
        )
    }

    public static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/Mac2MQTT")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    public static var legacyConfigURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/HassMacAgent/config.json")
    }

    public static func load() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }

        // Migrate from legacy HassMacAgent config if available
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

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: AppConfig.configURL)
        }
    }
}
