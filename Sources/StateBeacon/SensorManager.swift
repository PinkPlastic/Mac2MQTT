import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import CoreMediaIO
import IOKit.ps
import CoreLocation
import CoreWLAN
import Darwin
import IOBluetooth
import CoreBluetooth
import ApplicationServices

public struct SensorSnapshot: Sendable {
    public var frontmostApp: String
    public var isUserActive: Bool
    public var idleSeconds: Double
    public var batteryLevel: Int
    public var isCharging: Bool
    public var batteryState: String
    public var powerSource: String
    public var isMicInUse: Bool
    public var isAudioOutputInUse: Bool
    public var isCameraInUse: Bool
    public var activeAudioOutput: String
    public var activeAudioInput: String
    public var activeCamera: String
    public var displayCount: Int
    public var primaryDisplayId: String
    public var wifiSSID: String
    public var wifiBSSID: String
    public var connectionType: String
    public var focusMode: String
    public var isFocusActive: Bool
    public var cpuUsagePercent: Double
    public var memoryUsagePercent: Double
    public var isAudioMuted: Bool
    public var lastUpdateTrigger: String
    public var appVersion: String

    // Phase 1 HASS.Agent Parity Sensors
    public var lastBoot: String
    public var lastActive: String
    public var sessionState: String
    public var lastSystemStateChange: String
    public var loggedUser: String
    public var loggedUsers: String
    public var currentVolume: Int
    public var accentColor: String
    public var monitorPowerState: String
    public var currentClockSpeed: Int

    // Phase 2 HASS.Agent Parity Sensors
    public var bluetoothDevicesCount: Int
    public var bluetoothDevicesJson: String
    public var bluetoothLeDevicesCount: Int
    public var bluetoothLeDevicesJson: String
    public var thermalState: String
    public var gpuUsagePercent: Double
    public var geoLocation: String
    public var activeWindowTitle: String
}

public final class SensorManager: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var prevCpuInfo: host_cpu_load_info?
    private let locationManager = CLLocationManager()
    private var cachedLocation: CLLocation?

    // Live session & system state trackers
    public var lastSystemStateChange: String = "Startup"
    public var monitorPowerState: String = "PowerOn"
    public var sessionStateOverride: String? = nil

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            cachedLocation = loc
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // CoreLocation updates can intermittently fail if Wi-Fi positioning is temporarily unavailable
    }

    public func collectSnapshot(trigger: String = "Periodic") -> SensorSnapshot {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Finder"
        
        // Idle & Active
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let active = idle < 120.0

        // Battery
        let (battPct, charging, battState, pwrSrc) = getBatteryInfo()

        // Audio
        let (outName, inName, micInUse, outInUse, isMuted) = getAudioInfo()

        // Camera
        let (camInUse, camName) = getCameraInfo()

        // Displays
        let displayCount = NSScreen.screens.count
        let primaryDisplayId = String(CGMainDisplayID())

        // Wi-Fi & Network
        let (ssid, bssid, connType) = getNetworkInfo()

        // Focus Mode (Do Not Disturb / Work / Personal / etc.)
        let (focusName, focusActive) = getFocusModeInfo()

        // CPU & RAM
        let cpuPct = getCPUUsage()
        let memPct = getMemoryUsage()

        // Phase 1 HASS.Agent Parity Telemetry
        let lastBootTime = getLastBootTime()
        let lastActiveTime = getLastActiveTime(idleSeconds: idle)
        let sessionStatus = getSessionState()
        let (activeUser, activeUsersJson) = getLoggedUserInfo()
        let currentVol = getCurrentVolume()
        let accentHex = getAccentColor()
        let clockSpeed = getCurrentClockSpeed()

        // Phase 2 HASS.Agent Parity Telemetry
        let (btCount, btJson, btLeCount, btLeJson) = getBluetoothInfo()
        let therm = getThermalState()
        let gpuPct = getGpuUsage()
        let geo = getGeoLocation()
        let winTitle = getActiveWindowTitle(frontAppName: frontApp)

        return SensorSnapshot(
            frontmostApp: frontApp,
            isUserActive: active,
            idleSeconds: Double(Int(idle)),
            batteryLevel: battPct,
            isCharging: charging,
            batteryState: battState,
            powerSource: pwrSrc,
            isMicInUse: micInUse,
            isAudioOutputInUse: outInUse,
            isCameraInUse: camInUse,
            activeAudioOutput: outName,
            activeAudioInput: inName,
            activeCamera: camName,
            displayCount: displayCount,
            primaryDisplayId: primaryDisplayId,
            wifiSSID: ssid,
            wifiBSSID: bssid,
            connectionType: connType,
            focusMode: focusName,
            isFocusActive: focusActive,
            cpuUsagePercent: cpuPct,
            memoryUsagePercent: memPct,
            isAudioMuted: isMuted,
            lastUpdateTrigger: trigger,
            appVersion: "1.1.0",
            lastBoot: lastBootTime,
            lastActive: lastActiveTime,
            sessionState: sessionStatus,
            lastSystemStateChange: lastSystemStateChange,
            loggedUser: activeUser,
            loggedUsers: activeUsersJson,
            currentVolume: currentVol,
            accentColor: accentHex,
            monitorPowerState: monitorPowerState,
            currentClockSpeed: clockSpeed,
            bluetoothDevicesCount: btCount,
            bluetoothDevicesJson: btJson,
            bluetoothLeDevicesCount: btLeCount,
            bluetoothLeDevicesJson: btLeJson,
            thermalState: therm,
            gpuUsagePercent: gpuPct,
            geoLocation: geo,
            activeWindowTitle: winTitle
        )
    }

    // MARK: - Battery & Power

    private func getBatteryInfo() -> (level: Int, isCharging: Bool, state: String, powerSource: String) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (100, false, "Not Charging", "AC Power")
        }

        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] {
                let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let powerState = desc[kIOPSPowerSourceStateKey] as? String ?? "AC Power"
                
                var state = "Not Charging"
                if isCharging {
                    state = "Charging"
                } else if capacity == 100 && powerState == "AC Power" {
                    state = "Full"
                }
                
                return (capacity, isCharging, state, powerState)
            }
        }
        return (100, false, "Not Charging", "AC Power")
    }

    // MARK: - CoreAudio

    private func getAudioInfo() -> (outputName: String, inputName: String, micInUse: Bool, outInUse: Bool, isMuted: Bool) {
        var outName = "Unknown"
        var inName = "Unknown"
        var micInUse = false
        var outInUse = false
        var isMuted = false

        var defaultOutputID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var outAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddress, 0, nil, &propertySize, &defaultOutputID) == noErr {
            outName = getAudioDeviceName(deviceID: defaultOutputID)

            var muteVal: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(defaultOutputID, &muteAddress, 0, nil, &muteSize, &muteVal) == noErr {
                isMuted = (muteVal != 0)
            }

            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(defaultOutputID, &runningAddress, 0, nil, &isRunningSize, &isRunning) == noErr {
                outInUse = (isRunning != 0)
            }
        }

        var defaultInputID = AudioObjectID(0)
        var inAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &inAddress, 0, nil, &propertySize, &defaultInputID) == noErr {
            inName = getAudioDeviceName(deviceID: defaultInputID)

            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(defaultInputID, &runningAddress, 0, nil, &isRunningSize, &isRunning) == noErr {
                micInUse = (isRunning != 0)
            }
        }

        return (outName, inName, micInUse, outInUse, isMuted)
    }

    private func getAudioDeviceName(deviceID: AudioObjectID) -> String {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        if status == noErr, let name = name {
            return name as String
        }
        return "Unknown"
    }

    // MARK: - CoreMediaIO (Camera)

    private func getCameraInfo() -> (inUse: Bool, activeCameraName: String) {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        let status = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == OSStatus(kCMIOHardwareNoError), dataSize > 0 else {
            return (false, "Inactive")
        }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: deviceCount)
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataSize, &deviceIDs)

        for devID in deviceIDs {
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            if CMIOObjectGetPropertyData(devID, &runningAddress, 0, nil, size, &size, &isRunning) == OSStatus(kCMIOHardwareNoError) {
                if isRunning != 0 {
                    var name: CFString?
                    var nameSize = UInt32(MemoryLayout<CFString?>.size)
                    var nameAddress = CMIOObjectPropertyAddress(
                        mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
                        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                    )
                    var camName = "Connected Camera"
                    let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
                        CMIOObjectGetPropertyData(devID, &nameAddress, 0, nil, nameSize, &nameSize, ptr)
                    }
                    if nameStatus == OSStatus(kCMIOHardwareNoError), let name = name {
                        camName = name as String
                    }
                    return (true, camName)
                }
            }
        }

        return (false, "Inactive")
    }

    // MARK: - Wi-Fi & Network

    private func getNetworkInfo() -> (ssid: String, bssid: String, type: String) {
        // Only query CWWiFiClient if location permission has already been granted.
        // Calling iface.ssid() when authorization is notDetermined triggers an unprompted macOS dialog!
        let locStatus = locationManager.authorizationStatus
        if locStatus == .authorizedAlways {
            if let iface = CWWiFiClient.shared().interface() {
                if let ssid = iface.ssid(), !ssid.isEmpty {
                    let bssid = iface.bssid() ?? "Not Available"
                    return (ssid, bssid, "Wi-Fi")
                }
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        task.arguments = ["getsummary", "en0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var ssid = ""
        var bssid = ""
        var connType = "Wi-Fi"
        var linkActive = false

        if let str = String(data: data, encoding: .utf8) {
            for line in str.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("SSID : ") {
                    ssid = String(trimmed.dropFirst("SSID : ".count))
                } else if trimmed.hasPrefix("BSSID : ") {
                    bssid = String(trimmed.dropFirst("BSSID : ".count))
                } else if trimmed.hasPrefix("LinkStatusActive : TRUE") {
                    linkActive = true
                } else if trimmed.hasPrefix("InterfaceType : ") {
                    let itype = String(trimmed.dropFirst("InterfaceType : ".count))
                    connType = (itype.lowercased() == "wifi") ? "Wi-Fi" : itype
                }
            }
        }

        if ssid == "<redacted>" || ssid.isEmpty {
            if linkActive {
                ssid = "Wi-Fi Connected (Needs Location Permission)"
                bssid = "Location Permission Required"
            } else {
                ssid = "Not Connected"
                bssid = "None"
                connType = "None"
            }
        }

        if bssid == "<redacted>" {
            bssid = "Location Permission Required"
        }

        return (ssid, bssid, connType)
    }

    // MARK: - Focus Mode Detection (Names: Work, Personal, Do Not Disturb, etc.)

    private func getFocusModeInfo() -> (name: String, isActive: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. Check local DoNotDisturb database (Assertions.json) if granted Full Disk Access
        let assertionsURL = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: assertionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Off", false)
        }

        var assertionRecords: [[String: Any]] = []
        if let dataArr = json["data"] as? [[String: Any]], let first = dataArr.first,
           let records = first["storeAssertionRecords"] as? [[String: Any]] {
            assertionRecords = records
        } else if let dataObj = json["data"] as? [String: Any],
                  let records = dataObj["storeAssertionRecords"] as? [[String: Any]] {
            assertionRecords = records
        } else if let records = json["storeAssertionRecords"] as? [[String: Any]] {
            assertionRecords = records
        }

        if assertionRecords.isEmpty {
            return ("Off", false)
        }

        for record in assertionRecords.reversed() {
            var modeId: String? = nil
            if let details = record["assertionDetails"] as? [String: Any] {
                modeId = (details["assertionDetailsModeIdentifier"] as? String)
                      ?? (details["modeIdentifier"] as? String)
            } else if let directId = record["assertionDetailsModeIdentifier"] as? String {
                modeId = directId
            } else if let directId = record["modeIdentifier"] as? String {
                modeId = directId
            }
            
            if let modeId = modeId, !modeId.isEmpty {
                let name = resolveFocusModeName(modeId: modeId, home: home)
                return (name, true)
            }
        }

        return ("Off", false)
    }

    private func resolveFocusModeName(modeId: String, home: URL) -> String {
        let configsURL = home.appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json")
        if let data = try? Data(contentsOf: configsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]],
           let firstData = dataArr.first,
           let configs = firstData["modeConfigurations"] as? [String: [String: Any]] {
            for (key, config) in configs {
                if let mode = config["mode"] as? [String: Any] {
                    let identifier = (mode["modeIdentifier"] as? String) ?? (mode["identifier"] as? String) ?? key
                    if identifier == modeId || key == modeId {
                        if let name = mode["name"] as? String, !name.isEmpty {
                            return name
                        }
                    }
                }
            }
        }

        // Standard Apple Focus mode identifier mappings
        switch modeId {
        case "com.apple.donotdisturb": return "Do Not Disturb"
        case "com.apple.focus.work": return "Work"
        case "com.apple.focus.personal": return "Personal"
        case "com.apple.focus.sleep": return "Sleep"
        case "com.apple.focus.driving": return "Driving"
        case "com.apple.focus.fitness": return "Fitness"
        case "com.apple.focus.gaming": return "Gaming"
        case "com.apple.focus.reading": return "Reading"
        case "com.apple.focus.mindfulness": return "Mindfulness"
        default:
            let clean = modeId.replacingOccurrences(of: "com.apple.focus.", with: "")
                .replacingOccurrences(of: "com.apple.", with: "")
                .capitalized
            return clean.isEmpty ? "Focus" : clean
        }
    }

    // MARK: - System Resources (CPU & Memory)

    private func getCPUUsage() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        if let prev = prevCpuInfo {
            let user = Double(cpuInfo.cpu_ticks.0 - prev.cpu_ticks.0)
            let sys = Double(cpuInfo.cpu_ticks.1 - prev.cpu_ticks.1)
            let idle = Double(cpuInfo.cpu_ticks.2 - prev.cpu_ticks.2)
            let nice = Double(cpuInfo.cpu_ticks.3 - prev.cpu_ticks.3)
            let total = user + sys + idle + nice
            prevCpuInfo = cpuInfo
            if total > 0 {
                return ((user + sys + nice) / total) * 100.0
            }
        } else {
            prevCpuInfo = cpuInfo
        }
        return 0.0
    }

    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }

        let active = Double(stats.active_count)
        let wire = Double(stats.wire_count)
        let compressed = Double(stats.compressor_page_count)
        let free = Double(stats.free_count)
        let inactive = Double(stats.inactive_count)
        let total = active + wire + compressed + free + inactive
        if total > 0 {
            return ((active + wire + compressed) / total) * 100.0
        }
        return 0.0
    }

    // MARK: - Phase 1 HASS.Agent Parity Telemetry Collectors

    private func getLastBootTime() -> String {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &tv, &size, nil, 0) == 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        }
        return ""
    }

    private func getLastActiveTime(idleSeconds: Double) -> String {
        let date = Date().addingTimeInterval(-idleSeconds)
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func getSessionState() -> String {
        if let override = sessionStateOverride {
            return override
        }
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked {
                return "Locked"
            }
            if let lockedNum = dict["CGSSessionScreenIsLocked"] as? Int, lockedNum != 0 {
                return "Locked"
            }
            return "Unlocked"
        }
        return "Unlocked"
    }

    private func getLoggedUserInfo() -> (user: String, usersJson: String) {
        let currentUser = NSUserName()
        var userSet = Set<String>()
        userSet.insert(currentUser)

        setutxent()
        while let entry = getutxent() {
            if entry.pointee.ut_type == USER_PROCESS {
                let name = withUnsafePointer(to: entry.pointee.ut_user) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr)) { cstr in
                        String(cString: cstr)
                    }
                }
                if !name.isEmpty {
                    userSet.insert(name)
                }
            }
        }
        endutxent()

        let sortedUsers = Array(userSet).sorted()
        if let data = try? JSONSerialization.data(withJSONObject: sortedUsers, options: []),
           let json = String(data: data, encoding: .utf8) {
            return (currentUser, json)
        }
        return (currentUser, "[\"\(currentUser)\"]")
    }

    private func getCurrentVolume() -> Int {
        var defaultOutputID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var outAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddress, 0, nil, &propertySize, &defaultOutputID) == noErr {
            var volume: Float32 = 0.0
            var volSize = UInt32(MemoryLayout<Float32>.size)
            var volAddress = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(defaultOutputID, &volAddress, 0, nil, &volSize, &volume) == noErr {
                return Int(round(volume * 100))
            }
        }
        return 0
    }

    private func getAccentColor() -> String {
        if let srgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            let r = Int(round(srgb.redComponent * 255))
            let g = Int(round(srgb.greenComponent * 255))
            let b = Int(round(srgb.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return "#007AFF"
    }

    private func getCurrentClockSpeed() -> Int {
        var freq: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.cpufrequency_max", &freq, &size, nil, 0) == 0 && freq > 0 {
            return Int(freq / 1_000_000)
        }
        if sysctlbyname("hw.cpufrequency", &freq, &size, nil, 0) == 0 && freq > 0 {
            return Int(freq / 1_000_000)
        }

        var brandSize = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &brandSize, nil, 0)
        if brandSize > 0 {
            var brand = [CChar](repeating: 0, count: brandSize)
            sysctlbyname("machdep.cpu.brand_string", &brand, &brandSize, nil, 0)
            let brandStr = brand.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }?.lowercased() ?? ""
            if brandStr.contains("m4") { return 4400 }
            if brandStr.contains("m3") { return 4050 }
            if brandStr.contains("m2") { return 3500 }
            if brandStr.contains("m1") { return 3200 }
        }
        return 3200
    }

    // MARK: - Phase 2 HASS.Agent Parity Telemetry Collectors

    private func getBluetoothInfo() -> (classicCount: Int, classicJson: String, leCount: Int, leJson: String) {
        guard CBManager.authorization == .allowedAlways else {
            return (0, "[]", 0, "[]")
        }

        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return (0, "[]", 0, "[]")
        }

        var classicList: [[String: Any]] = []
        var leList: [[String: Any]] = []

        for dev in paired {
            if dev.isConnected() {
                let name = dev.name ?? dev.nameOrAddress ?? "Unknown Device"
                let addr = dev.addressString ?? "Unknown"
                let dict: [String: Any] = [
                    "name": name,
                    "address": addr,
                    "connected": true
                ]
                classicList.append(dict)
                if dev.classOfDevice == 0 || name.lowercased().contains("le") {
                    leList.append(dict)
                }
            }
        }

        let cData = (try? JSONSerialization.data(withJSONObject: classicList, options: [])) ?? Data()
        let leData = (try? JSONSerialization.data(withJSONObject: leList, options: [])) ?? Data()
        let cJson = String(data: cData, encoding: .utf8) ?? "[]"
        let leJson = String(data: leData, encoding: .utf8) ?? "[]"

        return (classicList.count, cJson, leList.count, leJson)
    }

    private func getThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Nominal"
        }
    }

    private func getGpuUsage() -> Double {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0.0
        }

        var maxUtil: Double = 0.0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                if let util = perfStats["Device Utilization %"] as? Int {
                    maxUtil = max(maxUtil, Double(util))
                } else if let utilDbl = perfStats["Device Utilization %"] as? Double {
                    maxUtil = max(maxUtil, utilDbl)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return maxUtil
    }

    private func getGeoLocation() -> String {
        let locStatus = locationManager.authorizationStatus
        guard locStatus == .authorizedAlways else {
            return "Location Permission Required"
        }
        if let loc = cachedLocation ?? locationManager.location {
            let lat = String(format: "%.6f", loc.coordinate.latitude)
            let lon = String(format: "%.6f", loc.coordinate.longitude)
            let alt = String(format: "%.1f", loc.altitude)
            return "\(lat),\(lon),\(alt)"
        }
        return "Acquiring..."
    }

    public func getActiveWindowTitle(frontAppName: String) -> String {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return frontAppName
        }

        let pid = frontApp.processIdentifier

        // 1. Accessibility API (primary method across macOS applications)
        let appElem = AXUIElementCreateApplication(pid)

        // Try focused window first
        var windowElem: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &windowElem) == .success,
           let win = windowElem {
            if let title = extractTitle(from: win as! AXUIElement) {
                return title
            }
        }

        // Try main window (fallback if focused window has no title or is subview)
        var mainWinElem: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXMainWindowAttribute as CFString, &mainWinElem) == .success,
           let mainWin = mainWinElem {
            if let title = extractTitle(from: mainWin as! AXUIElement) {
                return title
            }
        }

        // Try windows array (essential for apps like IINA or Electron where focusedWindow is nil or internal)
        var windowsElem: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsElem) == .success,
           let winList = windowsElem as? [AXUIElement] {
            for win in winList {
                if let title = extractTitle(from: win) {
                    return title
                }
            }
        }

        // 2. Quartz Window Server fallback (CGWindowListCopyWindowInfo)
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for win in windowList {
                let ownerPid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
                let layer = win[kCGWindowLayer as String] as? Int ?? -1
                if ownerPid == pid && layer == 0 {
                    if let title = win[kCGWindowName as String] as? String {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }
            }
        }

        return frontAppName
    }

    private func extractTitle(from win: AXUIElement) -> String? {
        // Direct title attribute
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Document attribute (file path or URL)
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef) == .success,
           let doc = docRef as? String {
            let path = URL(string: doc)?.lastPathComponent ?? (doc as NSString).lastPathComponent
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Description attribute
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}


