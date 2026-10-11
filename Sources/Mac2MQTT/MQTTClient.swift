import Foundation
import Network

/// Lightweight, native MQTT 3.1.1 client implemented via Apple's Network.framework.
/// Zero external dependencies, supports TCP and TLS (MQTTS).
public final class MQTTClient: @unchecked Sendable {
    public struct Config {
        public var host: String
        public var port: UInt16
        public var clientID: String
        public var username: String?
        public var password: String?
        public var useTLS: Bool
        public var keepAlive: UInt16
        public var willTopic: String?
        public var willPayload: Data?
        public var willRetain: Bool

        public init(
            host: String,
            port: UInt16 = 1883,
            clientID: String = "MacAgent_\(UUID().uuidString.prefix(8))",
            username: String? = nil,
            password: String? = nil,
            useTLS: Bool = false,
            keepAlive: UInt16 = 60,
            willTopic: String? = nil,
            willPayload: Data? = nil,
            willRetain: Bool = true
        ) {
            self.host = host
            self.port = port
            self.clientID = clientID
            self.username = username
            self.password = password
            self.useTLS = useTLS
            self.keepAlive = keepAlive
            self.willTopic = willTopic
            self.willPayload = willPayload
            self.willRetain = willRetain
        }
    }

    public var onConnect: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable (Error?) -> Void)?
    public var onMessage: (@Sendable (_ topic: String, _ payload: Data) -> Void)?

    private var config: Config
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.mac2mqtt.mqtt", qos: .userInitiated)
    private var pingTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var isConnected = false
    private var shouldReconnect = true
    private var nextPacketID: UInt16 = 1

    public init(config: Config) {
        self.config = config
    }

    public func updateConfig(_ config: Config) {
        self.config = config
    }

    public func connect() {
        queue.async {
            self.shouldReconnect = true
            self.setupConnection()
        }
    }

    public func disconnect() {
        queue.async {
            self.shouldReconnect = false
            self.stopPingTimer()
            self.stopReconnectTimer()
            self.sendDisconnectPacket()
            if let conn = self.connection {
                conn.stateUpdateHandler = nil
                conn.cancel()
                self.connection = nil
            }
            self.isConnected = false
            self.onDisconnect?(nil)
        }
    }

    private func setupConnection() {
        stopPingTimer()
        stopReconnectTimer()

        if let oldConn = connection {
            oldConn.stateUpdateHandler = nil
            oldConn.cancel()
            connection = nil
        }

        let endpointHost = NWEndpoint.Host(config.host)
        guard let endpointPort = NWEndpoint.Port(rawValue: config.port) else {
            print("[MQTT] Invalid port: \(config.port)")
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = 10

        let parameters: NWParameters
        if config.useTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }

        let conn = NWConnection(host: endpointHost, port: endpointPort, using: parameters)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            guard self.connection === conn else { return }

            switch state {
            case .ready:
                print("[MQTT] TCP connection established to \(self.config.host):\(self.config.port). Sending CONNECT...")
                self.sendConnectPacket()
                self.receiveNextPacket()
            case .failed(let error):
                print("[MQTT] Connection failed: \(error.localizedDescription)")
                self.handleDisconnection(error: error)
            case .waiting(let error):
                print("[MQTT] Connection waiting: \(error.localizedDescription)")
            case .cancelled:
                print("[MQTT] Connection cancelled.")
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func handleDisconnection(error: Error?) {
        guard isConnected || connection != nil else { return }
        isConnected = false
        stopPingTimer()

        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
        }

        onDisconnect?(error)

        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        stopReconnectTimer()
        guard shouldReconnect else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            print("[MQTT] Attempting reconnect...")
            self.setupConnection()
        }
        timer.resume()
        self.reconnectTimer = timer
    }

    private func startPingTimer() {
        stopPingTimer()
        let interval = max(10, Int(config.keepAlive) / 2)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.sendPingPacket()
        }
        timer.resume()
        self.pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func stopReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - Packet Encoding

    private func encodeRemainingLength(_ length: Int) -> [UInt8] {
        var num = length
        var bytes = [UInt8]()
        repeat {
            var digit = UInt8(num % 128)
            num /= 128
            if num > 0 {
                digit |= 0x80
            }
            bytes.append(digit)
        } while num > 0
        return bytes
    }

    private func writeUTF8String(_ string: String, to data: inout Data) {
        let utf8 = Array(string.utf8)
        let len = UInt16(utf8.count)
        data.append(UInt8(len >> 8))
        data.append(UInt8(len & 0xFF))
        data.append(contentsOf: utf8)
    }

    private func sendConnectPacket() {
        var variableHeader = Data()
        writeUTF8String("MQTT", to: &variableHeader)
        variableHeader.append(0x04) // Protocol Level 4 (MQTT 3.1.1)

        var connectFlags: UInt8 = 0x02 // Clean Session

        if config.willTopic != nil && config.willPayload != nil {
            connectFlags |= 0x04 // Will Flag
            connectFlags |= (0x01 << 3) // Will QoS 1
            if config.willRetain {
                connectFlags |= 0x20 // Will Retain
            }
        }

        if config.username != nil {
            connectFlags |= 0x80
        }
        if config.password != nil {
            connectFlags |= 0x40
        }
        variableHeader.append(connectFlags)

        let keepAlive = config.keepAlive
        variableHeader.append(UInt8(keepAlive >> 8))
        variableHeader.append(UInt8(keepAlive & 0xFF))

        var payload = Data()
        writeUTF8String(config.clientID, to: &payload)

        if let willTopic = config.willTopic, let willPayload = config.willPayload {
            writeUTF8String(willTopic, to: &payload)
            let len = UInt16(willPayload.count)
            payload.append(UInt8(len >> 8))
            payload.append(UInt8(len & 0xFF))
            payload.append(willPayload)
        }

        if let username = config.username {
            writeUTF8String(username, to: &payload)
        }
        if let password = config.password {
            writeUTF8String(password, to: &payload)
        }

        let remainingLength = variableHeader.count + payload.count
        var packet = Data([0x10]) // CONNECT
        packet.append(contentsOf: encodeRemainingLength(remainingLength))
        packet.append(variableHeader)
        packet.append(payload)

        send(packet: packet)
    }

    private func sendPingPacket() {
        let packet = Data([0xC0, 0x00]) // PINGREQ
        send(packet: packet)
    }

    private func sendDisconnectPacket() {
        let packet = Data([0xE0, 0x00]) // DISCONNECT
        send(packet: packet)
    }

    public func publish(topic: String, payload: Data, retain: Bool = false, qos: UInt8 = 0) {
        queue.async {
            guard self.isConnected else { return }

            var headerByte: UInt8 = 0x30 // PUBLISH
            if retain { headerByte |= 0x01 }
            if qos == 1 { headerByte |= 0x02 }

            var variableHeader = Data()
            self.writeUTF8String(topic, to: &variableHeader)

            if qos > 0 {
                let pid = self.nextPacketID
                self.nextPacketID = (self.nextPacketID == UInt16.max) ? 1 : (self.nextPacketID + 1)
                variableHeader.append(UInt8(pid >> 8))
                variableHeader.append(UInt8(pid & 0xFF))
            }

            let remainingLength = variableHeader.count + payload.count
            var packet = Data([headerByte])
            packet.append(contentsOf: self.encodeRemainingLength(remainingLength))
            packet.append(variableHeader)
            packet.append(payload)

            self.send(packet: packet)
        }
    }

    public func publishString(topic: String, string: String, retain: Bool = false, qos: UInt8 = 0) {
        if let data = string.data(using: .utf8) {
            publish(topic: topic, payload: data, retain: retain, qos: qos)
        }
    }

    public func subscribe(topic: String, qos: UInt8 = 0) {
        queue.async {
            guard self.isConnected else { return }

            let pid = self.nextPacketID
            self.nextPacketID = (self.nextPacketID == UInt16.max) ? 1 : (self.nextPacketID + 1)

            var variableHeader = Data()
            variableHeader.append(UInt8(pid >> 8))
            variableHeader.append(UInt8(pid & 0xFF))

            var payload = Data()
            self.writeUTF8String(topic, to: &payload)
            payload.append(qos)

            let remainingLength = variableHeader.count + payload.count
            var packet = Data([0x82]) // SUBSCRIBE (QoS 1)
            packet.append(contentsOf: self.encodeRemainingLength(remainingLength))
            packet.append(variableHeader)
            packet.append(payload)

            self.send(packet: packet)
        }
    }

    private func send(packet: Data) {
        guard let conn = connection else { return }
        conn.send(content: packet, completion: .contentProcessed({ [weak self, weak conn] error in
            guard let self = self, let conn = conn, self.connection === conn else { return }
            if let error = error {
                print("[MQTT] Send error: \(error)")
                self.handleDisconnection(error: error)
            }
        }))
    }

    // MARK: - Packet Receiving

    private func receiveNextPacket() {
        guard let conn = connection else { return }

        // Step 1: Read the 1-byte fixed header
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, self.connection === conn else { return }
            if let error = error {
                print("[MQTT] Receive error: \(error)")
                self.handleDisconnection(error: error)
                return
            }
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    print("[MQTT] Connection closed by broker.")
                    self.handleDisconnection(error: nil)
                }
                return
            }

            let headerByte = data[0]
            self.readRemainingLength { remainingLength in
                guard let remainingLength = remainingLength else { return }
                if remainingLength == 0 {
                    self.processPacket(headerByte: headerByte, payload: Data())
                    self.receiveNextPacket()
                } else {
                    self.readExactBytes(remainingLength) { bodyData in
                        guard let bodyData = bodyData else { return }
                        self.processPacket(headerByte: headerByte, payload: bodyData)
                        self.receiveNextPacket()
                    }
                }
            }
        }
    }

    private func readRemainingLength(multiplier: Int = 1, currentLength: Int = 0, completion: @escaping @Sendable (Int?) -> Void) {
        guard let conn = connection else {
            completion(nil)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, self.connection === conn else {
                completion(nil)
                return
            }
            if let error = error {
                print("[MQTT] Receive remaining length error: \(error)")
                self.handleDisconnection(error: error)
                completion(nil)
                return
            }
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.handleDisconnection(error: nil)
                }
                completion(nil)
                return
            }
            let byte = data[0]
            let length = currentLength + Int(byte & 0x7F) * multiplier
            if (byte & 0x80) != 0 {
                if multiplier > 128 * 128 * 128 {
                    print("[MQTT] Protocol error: remaining length exceeded 4 bytes.")
                    self.handleDisconnection(error: nil)
                    completion(nil)
                    return
                }
                self.readRemainingLength(multiplier: multiplier * 128, currentLength: length, completion: completion)
            } else {
                completion(length)
            }
        }
    }

    private func readExactBytes(_ count: Int, accumulated: Data = Data(), completion: @escaping @Sendable (Data?) -> Void) {
        let needed = count - accumulated.count
        guard needed > 0 else {
            completion(accumulated)
            return
        }
        guard let conn = connection else {
            completion(nil)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, self.connection === conn else {
                completion(nil)
                return
            }
            if let error = error {
                print("[MQTT] Receive exact bytes error: \(error)")
                self.handleDisconnection(error: error)
                completion(nil)
                return
            }
            guard let data = data, !data.isEmpty else {
                if isComplete {
                    self.handleDisconnection(error: nil)
                }
                completion(nil)
                return
            }
            var newAccumulated = accumulated
            newAccumulated.append(data)
            if newAccumulated.count >= count {
                completion(newAccumulated)
            } else {
                self.readExactBytes(count, accumulated: newAccumulated, completion: completion)
            }
        }
    }

    private func processPacket(headerByte: UInt8, payload: Data) {
        let packetType = headerByte >> 4

        switch packetType {
        case 0x02: // CONNACK
            if payload.count >= 2 {
                let returnCode = payload[1]
                if returnCode == 0 {
                    print("[MQTT] Successfully connected & authenticated!")
                    isConnected = true
                    startPingTimer()
                    onConnect?()
                } else {
                    print("[MQTT] Connection refused with code: \(returnCode)")
                    connection?.cancel()
                }
            }
        case 0x03: // PUBLISH
            handleIncomingPublish(headerByte: headerByte, payload: payload)
        case 0x09: // SUBACK
            break
        case 0x0D: // PINGRESP
            break
        default:
            break
        }
    }

    private func handleIncomingPublish(headerByte: UInt8, payload: Data) {
        guard payload.count >= 2 else { return }
        let topicLength = Int(payload[0]) << 8 | Int(payload[1])
        guard payload.count >= 2 + topicLength else { return }

        let topicData = payload.subdata(in: 2..<(2 + topicLength))
        guard let topic = String(data: topicData, encoding: .utf8) else { return }

        var offset = 2 + topicLength
        let qos = (headerByte >> 1) & 0x03
        if qos > 0 {
            offset += 2 // skip packet identifier
        }

        let messageData = payload.subdata(in: offset..<payload.count)
        onMessage?(topic, messageData)
    }
}
