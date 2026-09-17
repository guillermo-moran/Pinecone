import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Network)
import Network
#endif

public enum VirtIODeviceKind: UInt32, Codable, Equatable {
    case network = 1
    case block = 2
    case gpu = 16
    case input = 18

    public var displayName: String {
        switch self {
        case .network:
            return "network"
        case .block:
            return "block"
        case .gpu:
            return "gpu"
        case .input:
            return "input"
        }
    }

    var lowFeatureBits: UInt32 {
        switch self {
        case .network:
            return (UInt32(1) << 5) | (UInt32(1) << 16)
        case .block:
            return (UInt32(1) << 6) | (UInt32(1) << 9) | (UInt32(1) << 13) | (UInt32(1) << 14)
        case .gpu, .input:
            return 0
        }
    }
}

public struct VirtIOBlockRequestTypeCount: Codable, Equatable {
    public let requestType: UInt32
    public let name: String
    public let count: Int
}

private struct VirtIOQueueState: Equatable {
    var size: UInt32 = 0
    var ready: Bool = false
    var descriptorAddress: UInt64 = 0
    var driverAddress: UInt64 = 0
    var deviceAddress: UInt64 = 0
    var lastAvailableIndex: UInt16 = 0
}

private struct VirtIODescriptor: Equatable {
    static let nextFlag: UInt16 = 1
    static let writeFlag: UInt16 = 2
    static let indirectFlag: UInt16 = 4

    let address: GuestAddress
    let length: UInt32
    let flags: UInt16
    let next: UInt16

    var hasNext: Bool {
        (flags & Self.nextFlag) != 0
    }

    var isDeviceWritable: Bool {
        (flags & Self.writeFlag) != 0
    }

    var isIndirect: Bool {
        (flags & Self.indirectFlag) != 0
    }
}

public struct VirtIOInputEvent: Sendable, Equatable {
    public let type: UInt16
    public let code: UInt16
    public let value: Int32

    public init(type: UInt16, code: UInt16, value: Int32) {
        self.type = type
        self.code = code
        self.value = value
    }
}

public enum VirtIOInputRole: Sendable, Equatable {
    case touchscreen
    case keyboard
}

public protocol VirtIONetworkBackend: AnyObject {
    var onFramesAvailable: (() -> Void)? { get set }
    func transmit(frame: [UInt8])
    func receive() -> [UInt8]?
}

public protocol VirtIOOutboundTCPConnection: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onReceive: (([UInt8]) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start()
    func send(_ bytes: [UInt8])
    func cancel()
}

public protocol VirtIOOutboundNetworkFactory: AnyObject {
    func resolveIPv4Address(for hostname: String) -> [UInt8]?
    func makeTCPConnection(to hostIPv4: [UInt8], port: UInt16) -> VirtIOOutboundTCPConnection?
    func sendUDP(payload: [UInt8], to hostIPv4: [UInt8], port: UInt16, completion: @escaping ([[UInt8]]) -> Void)
    func sendICMPEcho(
        payload: [UInt8],
        identifier: UInt16,
        sequenceNumber: UInt16,
        to hostIPv4: [UInt8],
        completion: @escaping ([UInt8]?) -> Void
    )
}

#if canImport(Network)
private final class NetworkFrameworkTCPConnection: VirtIOOutboundTCPConnection {
    var onReady: (() -> Void)?
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var started = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLoop()
            case .failed(let error):
                self.onError?(error.localizedDescription)
                self.connection.cancel()
            case .cancelled:
                self.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let error else {
                return
            }
            self?.onError?(error.localizedDescription)
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.onReceive?([UInt8](data))
            }
            if let error {
                self.onError?(error.localizedDescription)
                self.connection.cancel()
                return
            }
            if isComplete {
                self.onClose?()
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }
}

private final class DefaultVirtIOOutboundNetworkFactory: VirtIOOutboundNetworkFactory {
    private let queue = DispatchQueue(label: "me.gmoran.pinecone.network-backend", qos: .utility)

    func resolveIPv4Address(for hostname: String) -> [UInt8]? {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &resultPointer) == 0 else {
            return nil
        }
        defer {
            if let resultPointer {
                freeaddrinfo(resultPointer)
            }
        }
        guard let resultPointer,
              let sockaddr = resultPointer.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) else {
            return nil
        }
        let address = sockaddr.sin_addr.s_addr.bigEndian
        return [
            UInt8((address >> 24) & 0xff),
            UInt8((address >> 16) & 0xff),
            UInt8((address >> 8) & 0xff),
            UInt8(address & 0xff)
        ]
    }

    func makeTCPConnection(to hostIPv4: [UInt8], port: UInt16) -> VirtIOOutboundTCPConnection? {
        guard hostIPv4.count == 4 else {
            return nil
        }
        let host = hostIPv4.map(String.init).joined(separator: ".")
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        return NetworkFrameworkTCPConnection(connection: connection, queue: queue)
    }

    func sendUDP(payload: [UInt8], to hostIPv4: [UInt8], port: UInt16, completion: @escaping ([[UInt8]]) -> Void) {
        guard hostIPv4.count == 4 else {
            completion([])
            return
        }
        let host = hostIPv4.map(String.init).joined(separator: ".")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            completion([])
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        var didComplete = false
        func finish(_ packets: [[UInt8]]) {
            guard !didComplete else {
                return
            }
            didComplete = true
            completion(packets)
        }
        let timeoutWorkItem = DispatchWorkItem {
            finish([])
            connection.cancel()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(payload), completion: .contentProcessed { error in
                    guard error == nil else {
                        timeoutWorkItem.cancel()
                        finish([])
                        connection.cancel()
                        return
                    }
                    connection.receiveMessage { data, _, _, _ in
                        timeoutWorkItem.cancel()
                        let packets = data.map { [[UInt8]($0)] } ?? []
                        finish(packets)
                        connection.cancel()
                    }
                    self.queue.asyncAfter(deadline: .now() + 2, execute: timeoutWorkItem)
                })
            case .failed, .cancelled:
                timeoutWorkItem.cancel()
                finish([])
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func sendICMPEcho(
        payload: [UInt8],
        identifier: UInt16,
        sequenceNumber: UInt16,
        to hostIPv4: [UInt8],
        completion: @escaping ([UInt8]?) -> Void
    ) {
        guard hostIPv4.count == 4 else {
            completion(nil)
            return
        }
        queue.async {
#if canImport(Darwin)
            let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            guard socketFD >= 0 else {
                completion(nil)
                return
            }
            defer {
                close(socketFD)
            }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(
                    socketFD,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            let packet = Self.makeICMPEchoPacket(
                payload: payload,
                identifier: identifier,
                sequenceNumber: sequenceNumber
            )
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            let addressWord =
                UInt32(hostIPv4[0]) << 24 |
                UInt32(hostIPv4[1]) << 16 |
                UInt32(hostIPv4[2]) << 8 |
                UInt32(hostIPv4[3])
            address.sin_addr = in_addr(s_addr: addressWord.bigEndian)

            let sent = packet.withUnsafeBytes { packetBytes in
                withUnsafePointer(to: &address) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        sendto(
                            socketFD,
                            packetBytes.baseAddress,
                            packet.count,
                            0,
                            sockaddrPointer,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            guard sent == packet.count else {
                completion(nil)
                return
            }

            var buffer = [UInt8](repeating: 0, count: 2048)
            let received = buffer.withUnsafeMutableBytes { bufferBytes in
                recvfrom(socketFD, bufferBytes.baseAddress, bufferBytes.count, 0, nil, nil)
            }
            guard received > 0 else {
                completion(nil)
                return
            }
            completion(Array(buffer.prefix(received)))
#else
            completion(nil)
#endif
        }
    }

    private static func makeICMPEchoPacket(
        payload: [UInt8],
        identifier: UInt16,
        sequenceNumber: UInt16
    ) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0]
        packet.append(UInt8(identifier >> 8))
        packet.append(UInt8(identifier & 0xff))
        packet.append(UInt8(sequenceNumber >> 8))
        packet.append(UInt8(sequenceNumber & 0xff))
        packet += payload
        let checksum = icmpChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)
        return packet
    }

    private static func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(~sum & 0xffff)
    }
}
#else
private final class DefaultVirtIOOutboundNetworkFactory: VirtIOOutboundNetworkFactory {
    func resolveIPv4Address(for hostname: String) -> [UInt8]? { nil }
    func makeTCPConnection(to hostIPv4: [UInt8], port: UInt16) -> VirtIOOutboundTCPConnection? { nil }
    func sendUDP(payload: [UInt8], to hostIPv4: [UInt8], port: UInt16, completion: @escaping ([[UInt8]]) -> Void) {
        completion([])
    }
    func sendICMPEcho(
        payload: [UInt8],
        identifier: UInt16,
        sequenceNumber: UInt16,
        to hostIPv4: [UInt8],
        completion: @escaping ([UInt8]?) -> Void
    ) {
        completion(nil)
    }
}
#endif

public struct LinkLocalHTTPResponse: Equatable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: [String: String]
    public let body: [UInt8]

    public init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: [UInt8] = []
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }
}

public final class BufferedVirtIONetworkBackend: VirtIONetworkBackend {
    public var onFramesAvailable: (() -> Void)?
    private var receiveFrames: [[UInt8]] = []
    public private(set) var transmittedFrames: [[UInt8]] = []

    public init() {}

    public func transmit(frame: [UInt8]) {
        transmittedFrames.append(frame)
    }

    public func receive() -> [UInt8]? {
        guard !receiveFrames.isEmpty else {
            return nil
        }
        return receiveFrames.removeFirst()
    }

    public func enqueueReceiveFrame(_ frame: [UInt8]) {
        receiveFrames.append(frame)
        onFramesAvailable?()
    }
}

public final class LinkLocalVirtIONetworkBackend: VirtIONetworkBackend {
    public static let guestMAC: [UInt8] = [0x02, 0x61, 0x72, 0x6d, 0x36, 0x34]
    public static let hostMAC: [UInt8] = [0x02, 0x70, 0x69, 0x6e, 0x65, 0x31]
    public static let guestIPv4: [UInt8] = [10, 0, 2, 15]
    public static let hostIPv4: [UInt8] = [10, 0, 2, 2]
    public static let dnsIPv4: [UInt8] = [10, 0, 2, 3]
    public static let alpineProxyBaseURL = "https://dl-cdn.alpinelinux.org"
    private static let maxTCPPayloadPerFrame = 1460
    private static let maxTCPBurstBytes = 64 * 1024

    private enum HTTPTransport {
        case synchronous((String) -> LinkLocalHTTPResponse)
        case asynchronous((String, @escaping (LinkLocalHTTPResponse) -> Void) -> Void)
    }

    private let outboundNetworkFactory: VirtIOOutboundNetworkFactory
    private var receiveFrames: [[UInt8]] = []
    private var tcpConnections: [TCPFlowKey: TCPConnection] = [:]
    private let httpTransport: HTTPTransport
    private let callbackQueue = DispatchQueue(label: "me.gmoran.pinecone.linklocal-network-callbacks", qos: .utility)
    private let stateLock = NSLock()
    public var onFramesAvailable: (() -> Void)?

    public private(set) var transmittedFrameCount = 0
    public private(set) var generatedFrameCount = 0
    public private(set) var recentFrameSummaries: [String] = []

    public var pendingReceiveFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receiveFrames.count
    }

    public var activeTCPConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tcpConnections.count
    }

    public var hasPendingAsynchronousTraffic: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !receiveFrames.isEmpty || !tcpConnections.isEmpty
    }

    public init(
        httpFetch: ((String) -> LinkLocalHTTPResponse)? = nil,
        outboundNetworkFactory: VirtIOOutboundNetworkFactory? = nil
    ) {
        if let httpFetch {
            self.httpTransport = .synchronous(httpFetch)
        } else {
            self.httpTransport = .asynchronous(Self.defaultHTTPFetchAsync)
        }
        self.outboundNetworkFactory = outboundNetworkFactory ?? DefaultVirtIOOutboundNetworkFactory()
    }

    public func transmit(frame: [UInt8]) {
        stateLock.lock()
        transmittedFrameCount += 1
        var generatedFrameDelta = 0
        if let normalizedFrame = Self.normalizedEthernetFrame(frame) {
            let responses = responseFrames(to: normalizedFrame)
            generatedFrameDelta = responses.count
            receiveFrames.append(contentsOf: responses)
            generatedFrameCount += responses.count
        }
        recordFrameSummary(frame, generatedResponse: generatedFrameDelta > 0)
        stateLock.unlock()
        signalFramesAvailableIfNeeded(generatedFrameDelta)
    }

    public func receive() -> [UInt8]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !receiveFrames.isEmpty else {
            return nil
        }
        return receiveFrames.removeFirst()
    }

    private func recordFrameSummary(_ frame: [UInt8], generatedResponse: Bool) {
        let prefix = frame.prefix(32).map { String(format: "%02x", $0) }.joined()
        let etherType = Self.etherTypeSummary(frame, at: 12)
        let shiftedEtherType = Self.etherTypeSummary(frame, at: 14)
        recentFrameSummaries.append("len=\(frame.count) ether=\(etherType) shifted=\(shiftedEtherType) generated=\(generatedResponse) prefix=\(prefix)")
        if recentFrameSummaries.count > 12 {
            recentFrameSummaries.removeFirst(recentFrameSummaries.count - 12)
        }
    }

    private static func etherTypeSummary(_ frame: [UInt8], at offset: Int) -> String {
        guard frame.count > offset + 1 else {
            return "none"
        }
        return String(format: "0x%02x%02x", frame[offset], frame[offset + 1])
    }

    public static func response(to frame: [UInt8]) -> [UInt8]? {
        guard let frame = normalizedEthernetFrame(frame) else {
            return nil
        }
        return statelessResponse(to: frame)
    }

    private func responseFrames(to frame: [UInt8]) -> [[UInt8]] {
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        switch etherType {
        case 0x0806:
            return Self.arpResponse(to: frame).map { [$0] } ?? []
        case 0x0800:
            return ipv4ResponseFrames(to: frame)
        default:
            return []
        }
    }

    private static func statelessResponse(to frame: [UInt8]) -> [UInt8]? {
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        switch etherType {
        case 0x0806:
            return arpResponse(to: frame)
        case 0x0800:
            return ipv4Response(to: frame)
        default:
            return nil
        }
    }

    private static func normalizedEthernetFrame(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 14 else {
            return nil
        }
        if isSupportedEtherType(frame, at: 12) {
            return frame
        }
        if frame.count >= 16 {
            let shifted = Array(frame.dropFirst(2))
            if isSupportedEtherType(shifted, at: 12) {
                return shifted
            }
        }
        return frame
    }

    private static func isSupportedEtherType(_ frame: [UInt8], at offset: Int) -> Bool {
        guard frame.count > offset + 1 else {
            return false
        }
        let etherType = UInt16(frame[offset]) << 8 | UInt16(frame[offset + 1])
        return etherType == 0x0800 || etherType == 0x0806 || etherType == 0x86dd
    }

    private static func arpResponse(to frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 42 else {
            return nil
        }
        let operation = UInt16(frame[20]) << 8 | UInt16(frame[21])
        let targetIP = Array(frame[38..<42])
        guard operation == 1, isLocalServiceIPv4(targetIP) else {
            return nil
        }

        var reply: [UInt8] = []
        reply += Array(frame[6..<12])
        reply += hostMAC
        reply += [0x08, 0x06]
        reply += [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x02]
        reply += hostMAC
        reply += targetIP
        reply += Array(frame[22..<28])
        reply += Array(frame[28..<32])
        return reply
    }

    private func ipv4ResponseFrames(to frame: [UInt8]) -> [[UInt8]] {
        guard frame.count >= 34 else {
            return []
        }
        let ipStart = 14
        let versionAndIHL = frame[ipStart]
        guard versionAndIHL >> 4 == 4 else {
            return []
        }
        let ihl = Int(versionAndIHL & 0x0f) * 4
        guard ihl >= 20, frame.count >= ipStart + ihl else {
            return []
        }
        let proto = frame[ipStart + 9]
        let destinationIP = Array(frame[(ipStart + 16)..<(ipStart + 20)])

        switch proto {
        case 6:
            return tcpResponseFrames(to: frame)
        case 17:
            if Self.isLocalServiceIPv4(destinationIP) || destinationIP == [255, 255, 255, 255] {
                return Self.ipv4Response(to: frame, dnsResolver: { [outboundNetworkFactory] hostname in
                    outboundNetworkFactory.resolveIPv4Address(for: hostname)
                }).map { [$0] } ?? []
            }
            return udpNATResponseFrames(to: frame)
        case 1:
            if Self.isLocalServiceIPv4(destinationIP) || destinationIP == [255, 255, 255, 255] {
                return Self.ipv4Response(to: frame, dnsResolver: { [outboundNetworkFactory] hostname in
                    outboundNetworkFactory.resolveIPv4Address(for: hostname)
                }).map { [$0] } ?? []
            }
            return icmpNATResponseFrames(to: frame, ipHeaderLength: ihl)
        default:
            return []
        }
    }

    private static func ipv4Response(
        to frame: [UInt8],
        dnsResolver: ((String) -> [UInt8]?)? = nil
    ) -> [UInt8]? {
        guard frame.count >= 34 else {
            return nil
        }
        let ipStart = 14
        let versionAndIHL = frame[ipStart]
        guard versionAndIHL >> 4 == 4 else {
            return nil
        }
        let ihl = Int(versionAndIHL & 0x0f) * 4
        guard ihl >= 20, frame.count >= ipStart + ihl else {
            return nil
        }
        let proto = frame[ipStart + 9]
        let sourceIP = Array(frame[(ipStart + 12)..<(ipStart + 16)])
        let destinationIP = Array(frame[(ipStart + 16)..<(ipStart + 20)])
        guard isLocalServiceIPv4(destinationIP) || destinationIP == [255, 255, 255, 255] else {
            if proto == 1 {
                return icmpDestinationUnreachableResponse(
                    to: frame,
                    ipHeaderLength: ihl,
                    sourceIP: sourceIP
                )
            }
            return nil
        }
        switch proto {
        case 1:
            return icmpEchoResponse(to: frame, ipHeaderLength: ihl, sourceIP: sourceIP, destinationIP: destinationIP)
        case 17:
            return udpResponse(
                to: frame,
                ipHeaderLength: ihl,
                sourceIP: sourceIP,
                destinationIP: destinationIP,
                dnsResolver: dnsResolver
            )
        default:
            return nil
        }
    }

    private static func icmpDestinationUnreachableResponse(
        to frame: [UInt8],
        ipHeaderLength: Int,
        sourceIP: [UInt8]
    ) -> [UInt8]? {
        let ipStart = 14
        let originalIPHeaderEnd = ipStart + ipHeaderLength
        guard frame.count >= originalIPHeaderEnd else {
            return nil
        }

        let quotedPayloadEnd = min(frame.count, originalIPHeaderEnd + 8)
        let quotedPacket = Array(frame[ipStart..<quotedPayloadEnd])

        var icmp: [UInt8] = [3, 1, 0, 0]
        icmp += [0, 0, 0, 0]
        icmp += quotedPacket
        writeChecksum(checksum(icmp), into: &icmp, at: 2)

        var ipHeader: [UInt8] = [0x45, 0x00]
        append16(UInt16(20 + icmp.count), to: &ipHeader)
        append16(0, to: &ipHeader)
        append16(0x4000, to: &ipHeader)
        ipHeader += [64, 1]
        append16(0, to: &ipHeader)
        ipHeader += hostIPv4
        ipHeader += sourceIP
        writeChecksum(checksum(ipHeader), into: &ipHeader, at: 10)

        return Array(frame[6..<12]) + hostMAC + [0x08, 0x00] + ipHeader + icmp
    }

    private static func icmpEchoResponse(
        to frame: [UInt8],
        ipHeaderLength: Int,
        sourceIP: [UInt8],
        destinationIP: [UInt8]
    ) -> [UInt8]? {
        let ipStart = 14
        let icmpStart = ipStart + ipHeaderLength
        guard frame.count >= icmpStart + 8, frame[icmpStart] == 8 else {
            return nil
        }
        var icmp = Array(frame[icmpStart..<frame.count])
        icmp[0] = 0
        icmp[2] = 0
        icmp[3] = 0
        writeChecksum(checksum(icmp), into: &icmp, at: 2)

        var ipHeader = Array(frame[ipStart..<(ipStart + ipHeaderLength)])
        ipHeader[8] = 64
        ipHeader[10] = 0
        ipHeader[11] = 0
        ipHeader.replaceSubrange(12..<16, with: destinationIP)
        ipHeader.replaceSubrange(16..<20, with: sourceIP)
        writeChecksum(checksum(ipHeader), into: &ipHeader, at: 10)

        return Array(frame[6..<12]) + hostMAC + [0x08, 0x00] + ipHeader + icmp
    }

    private static func udpResponse(
        to frame: [UInt8],
        ipHeaderLength: Int,
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        dnsResolver: ((String) -> [UInt8]?)?
    ) -> [UInt8]? {
        let ipStart = 14
        let udpStart = ipStart + ipHeaderLength
        guard frame.count >= udpStart + 8 else {
            return nil
        }
        let sourcePort = read16(frame, at: udpStart)
        let destinationPort = read16(frame, at: udpStart + 2)
        let udpLength = Int(read16(frame, at: udpStart + 4))
        guard destinationPort == 53,
              udpLength >= 8,
              frame.count >= udpStart + udpLength else {
            return nil
        }
        let payload = Array(frame[(udpStart + 8)..<(udpStart + udpLength)])
        guard let dnsPayload = dnsResponsePayload(to: payload, resolver: dnsResolver) else {
            return nil
        }

        var udp: [UInt8] = []
        append16(destinationPort, to: &udp)
        append16(sourcePort, to: &udp)
        append16(UInt16(8 + dnsPayload.count), to: &udp)
        append16(0, to: &udp)
        udp += dnsPayload

        return ipv4EthernetResponse(
            clientMAC: Array(frame[6..<12]),
            protocolNumber: 17,
            sourceIP: destinationIP,
            destinationIP: sourceIP,
            payload: udp
        )
    }

    private static func dnsResponsePayload(to query: [UInt8], resolver: ((String) -> [UInt8]?)?) -> [UInt8]? {
        guard query.count >= 12 else {
            return nil
        }

        let questionCount = Int(read16(query, at: 4))
        guard questionCount > 0, questionCount <= 8 else {
            return nil
        }

        var questions: [DNSQuestion] = []
        var offset = 12
        for _ in 0..<questionCount {
            let questionStart = offset
            while true {
                guard offset < query.count else {
                    return nil
                }
                let length = query[offset]
                offset += 1
                if length == 0 {
                    break
                }
                guard (length & 0xc0) == 0 else {
                    return nil
                }
                offset += Int(length)
                guard offset <= query.count else {
                    return nil
                }
            }
            guard offset + 4 <= query.count else {
                return nil
            }
            let queryType = read16(query, at: offset)
            let queryClass = read16(query, at: offset + 2)
            offset += 4
            questions.append(
                DNSQuestion(
                    nameOffset: questionStart,
                    bytes: Array(query[questionStart..<offset]),
                    queryType: queryType,
                    queryClass: queryClass
                )
            )
        }

        let answeredQuestions = questions.filter { $0.queryClass == 1 && ($0.queryType == 1 || $0.queryType == 28) }
        guard questions.count <= Int(UInt16.max),
              answeredQuestions.filter({ $0.queryType == 1 }).count <= Int(UInt16.max) else {
            return nil
        }

        var answers: [(DNSQuestion, [UInt8])] = []
        var resolutionFailed = false
        for question in answeredQuestions where question.queryType == 1 {
            let name = dnsQuestionName(from: query, offset: question.nameOffset)
            if let address = resolver?(name), address.count == 4 {
                answers.append((question, address))
            } else {
                resolutionFailed = true
            }
        }
        // getaddrinfo cannot distinguish authoritative NXDOMAIN from a temporary
        // resolver failure here. Return SERVFAIL, never a fabricated gateway A RR.
        if resolutionFailed { answers.removeAll() }
        var response: [UInt8] = []
        response += query[0..<2]
        let requestFlags = read16(query, at: 2)
        let responseFlags = UInt16(0x8080) | (requestFlags & 0x0100) | (resolutionFailed ? 2 : 0)
        append16(responseFlags, to: &response)
        append16(UInt16(questions.count), to: &response)
        append16(UInt16(answers.count), to: &response)
        append16(0, to: &response)
        append16(0, to: &response)
        for question in questions {
            response += question.bytes
        }

        for (question, resolvedIPv4) in answers {
            guard question.nameOffset <= 0x3fff else {
                return nil
            }
            append16(UInt16(0xc000 | question.nameOffset), to: &response)
            append16(1, to: &response)
            append16(1, to: &response)
            append32(60, to: &response)
            append16(4, to: &response)
            response += resolvedIPv4
        }
        return response
    }

    private static func dnsQuestionName(from query: [UInt8], offset: Int) -> String {
        var labels: [String] = []
        var cursor = offset
        while cursor < query.count {
            let length = Int(query[cursor])
            cursor += 1
            if length == 0 || cursor + length > query.count {
                break
            }
            labels.append(String(decoding: query[cursor..<(cursor + length)], as: UTF8.self))
            cursor += length
        }
        return labels.joined(separator: ".")
    }

    private func tcpResponseFrames(to frame: [UInt8]) -> [[UInt8]] {
        guard frame.count >= 34 else {
            return []
        }
        let ipStart = 14
        let versionAndIHL = frame[ipStart]
        guard versionAndIHL >> 4 == 4 else {
            return []
        }
        let ipHeaderLength = Int(versionAndIHL & 0x0f) * 4
        guard ipHeaderLength >= 20,
              frame.count >= ipStart + ipHeaderLength,
              frame[ipStart + 9] == 6 else {
            return []
        }
        let sourceIP = Array(frame[(ipStart + 12)..<(ipStart + 16)])
        let destinationIP = Array(frame[(ipStart + 16)..<(ipStart + 20)])
        let tcpStart = ipStart + ipHeaderLength
        guard frame.count >= tcpStart + 20 else {
            return []
        }
        let clientMAC = Array(frame[6..<12])
        let sourcePort = Self.read16(frame, at: tcpStart)
        let destinationPort = Self.read16(frame, at: tcpStart + 2)
        let sequence = Self.read32(frame, at: tcpStart + 4)
        let acknowledgment = Self.read32(frame, at: tcpStart + 8)
        let headerLength = Int(frame[tcpStart + 12] >> 4) * 4
        guard headerLength >= 20, frame.count >= tcpStart + headerLength else {
            return []
        }
        let flags = frame[tcpStart + 13]
        let advertisedWindow = Int(Self.read16(frame, at: tcpStart + 14))
        let payload = Array(frame[(tcpStart + headerLength)..<frame.count])
        let key = TCPFlowKey(
            sourceIP: Self.ipv4Word(sourceIP),
            destinationIP: Self.ipv4Word(destinationIP),
            sourcePort: sourcePort,
            destinationPort: destinationPort
        )
        let isLocalHTTPProxy = destinationIP == Self.hostIPv4 && destinationPort == 80

        if (flags & 0x04) != 0 {
            // A canceled browser request must not retain its host socket or
            // keep the vCPU network-polling path active indefinitely.
            let transport = tcpConnections.removeValue(forKey: key)?.transport
            transport?.cancel()
            return []
        }

        if (flags & 0x02) != 0 {
            let serverSequence = Self.serverInitialSequence(for: key)
            let transport: VirtIOOutboundTCPConnection?
            if isLocalHTTPProxy {
                transport = nil
            } else {
                transport = makeAndStartTCPTransport(flowKey: key, destinationIP: destinationIP, destinationPort: destinationPort)
                guard transport != nil else {
                    return [
                        tcpIPv4EthernetResponse(
                            clientMAC: clientMAC,
                            sourceIP: destinationIP,
                            destinationIP: sourceIP,
                            sourcePort: destinationPort,
                            destinationPort: sourcePort,
                            sequence: serverSequence,
                            acknowledgment: sequence &+ 1,
                            flags: 0x14,
                            payload: []
                        )
                    ]
                }
            }
            let connection = TCPConnection(
                clientMAC: clientMAC,
                clientIP: sourceIP,
                serverIP: destinationIP,
                clientPort: sourcePort,
                serverPort: destinationPort,
                serverInitialSequence: serverSequence,
                serverNextSequence: serverSequence &+ 1,
                clientNextSequence: sequence &+ 1,
                advertisedWindow: advertisedWindow,
                requestBytes: [],
                responseBytes: isLocalHTTPProxy ? nil : [],
                responseSentByteCount: 0,
                responseAckedByteCount: 0,
                finSent: false,
                fetchInFlight: false,
                hostClosed: false,
                pendingClientPayloads: [],
                transport: transport,
                hostReady: isLocalHTTPProxy,
                resetQueued: false
            )
            tcpConnections[key] = connection
            return [
                tcpIPv4EthernetResponse(
                    clientMAC: clientMAC,
                    sourceIP: destinationIP,
                    destinationIP: sourceIP,
                    sourcePort: destinationPort,
                    destinationPort: sourcePort,
                    sequence: serverSequence,
                    acknowledgment: sequence &+ 1,
                    flags: 0x12,
                    payload: []
                )
            ]
        }

        guard var connection = tcpConnections[key] else {
            return []
        }
        connection.advertisedWindow = advertisedWindow
        if (flags & 0x10) != 0 {
            updateResponseAcknowledgment(acknowledgment, connection: &connection)
        }

        var frames: [[UInt8]] = []
        var payloadToSend: [UInt8] = []
        if !payload.isEmpty {
            let payloadEnd = sequence &+ UInt32(payload.count)
            let acceptedPayload: ArraySlice<UInt8>
            if sequence == connection.clientNextSequence {
                acceptedPayload = payload[...]
                connection.clientNextSequence = payloadEnd
            } else if sequence < connection.clientNextSequence, payloadEnd > connection.clientNextSequence {
                let alreadyReceived = Int(connection.clientNextSequence - sequence)
                acceptedPayload = payload.dropFirst(alreadyReceived)
                connection.clientNextSequence = payloadEnd
            } else {
                acceptedPayload = []
            }
            frames.append(
                tcpIPv4EthernetResponse(
                    clientMAC: clientMAC,
                    sourceIP: destinationIP,
                    destinationIP: sourceIP,
                    sourcePort: destinationPort,
                    destinationPort: sourcePort,
                    sequence: connection.serverNextSequence,
                    acknowledgment: connection.clientNextSequence,
                    flags: 0x10,
                    payload: []
                )
            )

            if !acceptedPayload.isEmpty {
                if isLocalHTTPProxy {
                    connection.requestBytes.append(contentsOf: acceptedPayload)
                    if connection.responseBytes == nil,
                       !connection.fetchInFlight,
                       Self.httpRequestIsComplete(connection.requestBytes) {
                        switch prepareHTTPResponse(for: connection.requestBytes, flowKey: key) {
                        case let .ready(bytes):
                            connection.responseBytes = bytes
                            connection.hostClosed = true
                        case let .pending(fetch):
                            connection.fetchInFlight = true
                            startHTTPFetch(fetch)
                        }
                    }
                } else {
                    payloadToSend = Array(acceptedPayload)
                    if !connection.hostReady {
                        connection.pendingClientPayloads.append(payloadToSend)
                        payloadToSend.removeAll(keepingCapacity: false)
                    }
                }
            }
        }

        frames += appendPendingTCPResponseFrames(connection: &connection)

        if (flags & 0x01) != 0 {
            connection.transport?.cancel()
            tcpConnections.removeValue(forKey: key)
            frames.append(
                tcpIPv4EthernetResponse(
                    clientMAC: clientMAC,
                    sourceIP: destinationIP,
                    destinationIP: sourceIP,
                    sourcePort: destinationPort,
                    destinationPort: sourcePort,
                    sequence: connection.serverNextSequence,
                    acknowledgment: sequence &+ UInt32(payload.count) &+ 1,
                    flags: 0x10,
                    payload: []
                )
            )
            return frames
        }

        tcpConnections[key] = connection
        if !payloadToSend.isEmpty {
            connection.transport?.send(payloadToSend)
        }
        return frames
    }

    private func appendPendingTCPResponseFrames(connection: inout TCPConnection) -> [[UInt8]] {
        guard let responseBytes = connection.responseBytes else {
            return []
        }
        let responseStartSequence = connection.serverInitialSequence &+ 1
        var frames: [[UInt8]] = []
        var inFlight = connection.responseSentByteCount - connection.responseAckedByteCount
        var availableWindow = max(0, connection.advertisedWindow - inFlight)
        let segmentSize = min(Self.maxTCPPayloadPerFrame, max(0, availableWindow))
        let maxBurstBytes = min(max(Self.maxTCPPayloadPerFrame * 8, availableWindow), Self.maxTCPBurstBytes)
        let maxSegmentsPerBurst = max(1, (maxBurstBytes + max(1, segmentSize) - 1) / max(1, segmentSize))
        var emittedSegments = 0

        while connection.responseSentByteCount < responseBytes.count,
              availableWindow > 0,
              emittedSegments < maxSegmentsPerBurst {
            let remaining = responseBytes.count - connection.responseSentByteCount
            let count = min(segmentSize, remaining, availableWindow)
            guard count > 0 else {
                break
            }
            let offset = connection.responseSentByteCount
            let segment = Array(responseBytes[offset..<(offset + count)])
            frames.append(
                tcpIPv4EthernetResponse(
                    clientMAC: connection.clientMAC,
                    sourceIP: connection.serverIP,
                    destinationIP: connection.clientIP,
                    sourcePort: connection.serverPort,
                    destinationPort: connection.clientPort,
                    sequence: responseStartSequence &+ UInt32(offset),
                    acknowledgment: connection.clientNextSequence,
                    flags: 0x18,
                    payload: segment
                )
            )
            connection.responseSentByteCount += count
            connection.serverNextSequence = responseStartSequence &+ UInt32(connection.responseSentByteCount)
            inFlight += count
            availableWindow -= count
            emittedSegments += 1
        }

        if connection.hostClosed,
           connection.responseSentByteCount == responseBytes.count,
           !connection.finSent,
           availableWindow > 0,
           emittedSegments < maxSegmentsPerBurst {
            frames.append(
                tcpIPv4EthernetResponse(
                    clientMAC: connection.clientMAC,
                    sourceIP: connection.serverIP,
                    destinationIP: connection.clientIP,
                    sourcePort: connection.serverPort,
                    destinationPort: connection.clientPort,
                    sequence: responseStartSequence &+ UInt32(responseBytes.count),
                    acknowledgment: connection.clientNextSequence,
                    flags: 0x11,
                    payload: []
                )
            )
            connection.finSent = true
            connection.serverNextSequence = responseStartSequence &+ UInt32(responseBytes.count) &+ 1
        }

        return frames
    }

    private func updateResponseAcknowledgment(_ acknowledgment: UInt32, connection: inout TCPConnection) {
        guard let responseBytes = connection.responseBytes else {
            return
        }
        let responseStartSequence = connection.serverInitialSequence &+ 1
        guard acknowledgment >= responseStartSequence else {
            return
        }
        let acknowledged = min(Int(acknowledgment - responseStartSequence), responseBytes.count)
        connection.responseAckedByteCount = max(connection.responseAckedByteCount, acknowledged)
    }

    private func makeAndStartTCPTransport(
        flowKey: TCPFlowKey,
        destinationIP: [UInt8],
        destinationPort: UInt16
    ) -> VirtIOOutboundTCPConnection? {
        guard let transport = outboundNetworkFactory.makeTCPConnection(to: destinationIP, port: destinationPort) else {
            return nil
        }
        transport.onReady = { [weak self] in
            self?.callbackQueue.async {
                self?.markTCPTransportReady(flowKey: flowKey)
            }
        }
        transport.onReceive = { [weak self] bytes in
            self?.callbackQueue.async {
                self?.receiveTCPTransport(bytes: bytes, flowKey: flowKey)
            }
        }
        transport.onClose = { [weak self] in
            self?.callbackQueue.async {
                self?.closeTCPTransport(flowKey: flowKey)
            }
        }
        transport.onError = { [weak self] message in
            self?.callbackQueue.async {
                self?.failTCPTransport(flowKey: flowKey, reason: message)
            }
        }
        transport.start()
        return transport
    }

    private func markTCPTransportReady(flowKey: TCPFlowKey) {
        stateLock.lock()
        guard var connection = tcpConnections[flowKey] else {
            stateLock.unlock()
            return
        }
        connection.hostReady = true
        let pendingPayloads = connection.pendingClientPayloads
        connection.pendingClientPayloads.removeAll(keepingCapacity: true)
        let transport = connection.transport
        tcpConnections[flowKey] = connection
        stateLock.unlock()

        for payload in pendingPayloads {
            transport?.send(payload)
        }
    }

    private func receiveTCPTransport(bytes: [UInt8], flowKey: TCPFlowKey) {
        guard !bytes.isEmpty else {
            return
        }
        stateLock.lock()
        guard var connection = tcpConnections[flowKey] else {
            stateLock.unlock()
            return
        }
        if connection.responseBytes == nil {
            connection.responseBytes = []
        }
        connection.responseBytes?.append(contentsOf: bytes)
        let frames = appendPendingTCPResponseFrames(connection: &connection)
        tcpConnections[flowKey] = connection
        receiveFrames.append(contentsOf: frames)
        generatedFrameCount += frames.count
        stateLock.unlock()
        signalFramesAvailableIfNeeded(frames.count)
    }

    private func closeTCPTransport(flowKey: TCPFlowKey) {
        stateLock.lock()
        guard var connection = tcpConnections[flowKey] else {
            stateLock.unlock()
            return
        }
        connection.hostClosed = true
        let frames = appendPendingTCPResponseFrames(connection: &connection)
        tcpConnections[flowKey] = connection
        receiveFrames.append(contentsOf: frames)
        generatedFrameCount += frames.count
        stateLock.unlock()
        signalFramesAvailableIfNeeded(frames.count)
    }

    private func failTCPTransport(flowKey: TCPFlowKey, reason: String) {
        stateLock.lock()
        guard var connection = tcpConnections[flowKey] else {
            stateLock.unlock()
            return
        }
        guard !connection.resetQueued else {
            stateLock.unlock()
            return
        }
        connection.resetQueued = true
        let rst = tcpIPv4EthernetResponse(
            clientMAC: connection.clientMAC,
            sourceIP: connection.serverIP,
            destinationIP: connection.clientIP,
            sourcePort: connection.serverPort,
            destinationPort: connection.clientPort,
            sequence: connection.serverNextSequence,
            acknowledgment: connection.clientNextSequence,
            flags: 0x14,
            payload: []
        )
        tcpConnections.removeValue(forKey: flowKey)
        receiveFrames.append(rst)
        generatedFrameCount += 1
        recentFrameSummaries.append("tcp-rst \(connection.serverIP.map(String.init).joined(separator: ".")):\(connection.serverPort) reason=\(reason)")
        if recentFrameSummaries.count > 12 {
            recentFrameSummaries.removeFirst(recentFrameSummaries.count - 12)
        }
        stateLock.unlock()
        signalFramesAvailableIfNeeded(1)
    }

    private func udpNATResponseFrames(to frame: [UInt8]) -> [[UInt8]] {
        let ipStart = 14
        let versionAndIHL = frame[ipStart]
        let ipHeaderLength = Int(versionAndIHL & 0x0f) * 4
        let udpStart = ipStart + ipHeaderLength
        guard frame.count >= udpStart + 8 else {
            return []
        }
        let sourceIP = Array(frame[(ipStart + 12)..<(ipStart + 16)])
        let destinationIP = Array(frame[(ipStart + 16)..<(ipStart + 20)])
        let sourcePort = Self.read16(frame, at: udpStart)
        let destinationPort = Self.read16(frame, at: udpStart + 2)
        let udpLength = Int(Self.read16(frame, at: udpStart + 4))
        guard udpLength >= 8, frame.count >= udpStart + udpLength else {
            return []
        }
        let payload = Array(frame[(udpStart + 8)..<(udpStart + udpLength)])
        let clientMAC = Array(frame[6..<12])

        outboundNetworkFactory.sendUDP(payload: payload, to: destinationIP, port: destinationPort) { [weak self] packets in
            self?.callbackQueue.async {
                self?.finishUDPNATSend(
                    packets: packets,
                    clientMAC: clientMAC,
                    sourceIP: sourceIP,
                    destinationIP: destinationIP,
                    sourcePort: sourcePort,
                    destinationPort: destinationPort
                )
            }
        }
        return []
    }

    private func finishUDPNATSend(
        packets: [[UInt8]],
        clientMAC: [UInt8],
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        sourcePort: UInt16,
        destinationPort: UInt16
    ) {
        guard !packets.isEmpty else {
            return
        }
        let frames = packets.map { payload in
            var udp: [UInt8] = []
            Self.append16(destinationPort, to: &udp)
            Self.append16(sourcePort, to: &udp)
            Self.append16(UInt16(8 + payload.count), to: &udp)
            Self.append16(0, to: &udp)
            udp += payload
            return Self.ipv4EthernetResponse(
                clientMAC: clientMAC,
                protocolNumber: 17,
                sourceIP: destinationIP,
                destinationIP: sourceIP,
                payload: udp
            )
        }
        stateLock.lock()
        receiveFrames.append(contentsOf: frames)
        generatedFrameCount += frames.count
        stateLock.unlock()
        signalFramesAvailableIfNeeded(frames.count)
    }

    private func icmpNATResponseFrames(to frame: [UInt8], ipHeaderLength: Int) -> [[UInt8]] {
        let ipStart = 14
        let icmpStart = ipStart + ipHeaderLength
        guard frame.count >= icmpStart + 8 else {
            return []
        }
        let type = frame[icmpStart]
        let code = frame[icmpStart + 1]
        guard type == 8, code == 0 else {
            return Self.icmpDestinationUnreachableResponse(
                to: frame,
                ipHeaderLength: ipHeaderLength,
                sourceIP: Array(frame[(ipStart + 12)..<(ipStart + 16)])
            ).map { [$0] } ?? []
        }

        let sourceIP = Array(frame[(ipStart + 12)..<(ipStart + 16)])
        let destinationIP = Array(frame[(ipStart + 16)..<(ipStart + 20)])
        let clientMAC = Array(frame[6..<12])
        let identifier = Self.read16(frame, at: icmpStart + 4)
        let sequenceNumber = Self.read16(frame, at: icmpStart + 6)
        let payload = Array(frame[(icmpStart + 8)..<frame.count])

        outboundNetworkFactory.sendICMPEcho(
            payload: payload,
            identifier: identifier,
            sequenceNumber: sequenceNumber,
            to: destinationIP
        ) { [weak self] responsePayload in
            self?.callbackQueue.async {
                self?.finishICMPNATSend(
                    responsePayload: responsePayload,
                    clientMAC: clientMAC,
                    sourceIP: sourceIP,
                    destinationIP: destinationIP,
                    identifier: identifier,
                    sequenceNumber: sequenceNumber
                )
            }
        }
        return []
    }

    private func finishICMPNATSend(
        responsePayload: [UInt8]?,
        clientMAC: [UInt8],
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        identifier: UInt16,
        sequenceNumber: UInt16
    ) {
        guard let responsePayload,
              var normalizedPayload = Self.normalizedICMPPayload(responsePayload),
              normalizedPayload.count >= 8,
              normalizedPayload[0] == 0,
              normalizedPayload[1] == 0 else {
            return
        }
        normalizedPayload[2] = 0
        normalizedPayload[3] = 0
        normalizedPayload[4] = UInt8(identifier >> 8)
        normalizedPayload[5] = UInt8(identifier & 0xff)
        normalizedPayload[6] = UInt8(sequenceNumber >> 8)
        normalizedPayload[7] = UInt8(sequenceNumber & 0xff)
        Self.writeChecksum(Self.checksum(normalizedPayload), into: &normalizedPayload, at: 2)
        let frame = Self.ipv4EthernetResponse(
            clientMAC: clientMAC,
            protocolNumber: 1,
            sourceIP: destinationIP,
            destinationIP: sourceIP,
            payload: normalizedPayload
        )
        stateLock.lock()
        receiveFrames.append(frame)
        generatedFrameCount += 1
        stateLock.unlock()
        signalFramesAvailableIfNeeded(1)
    }

    private enum HTTPResponsePreparation {
        case ready([UInt8])
        case pending(PendingHTTPFetch)
    }

    private func prepareHTTPResponse(for requestBytes: [UInt8], flowKey: TCPFlowKey) -> HTTPResponsePreparation {
        guard let request = String(bytes: requestBytes, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return .ready(Self.encodedHTTPResponse(
                LinkLocalHTTPResponse(statusCode: 400, reasonPhrase: "Bad Request", body: Array("bad request\n".utf8))
            ))
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return .ready(Self.encodedHTTPResponse(
                LinkLocalHTTPResponse(statusCode: 400, reasonPhrase: "Bad Request", body: Array("bad request\n".utf8))
            ))
        }
        let method = parts[0].uppercased()
        let path = parts[1]
        guard method == "GET" || method == "HEAD" else {
            return .ready(Self.encodedHTTPResponse(
                LinkLocalHTTPResponse(statusCode: 405, reasonPhrase: "Method Not Allowed", body: Array("method not allowed\n".utf8))
            ))
        }
        guard path.hasPrefix("/alpine/") else {
            return .ready(Self.encodedHTTPResponse(
                LinkLocalHTTPResponse(statusCode: 404, reasonPhrase: "Not Found", body: Array("not found\n".utf8))
            ))
        }

        switch httpTransport {
        case let .synchronous(httpFetch):
            let response = httpFetch(path)
            return .ready(Self.encodedProxyHTTPResponse(response, method: method))
        case .asynchronous:
            return .pending(PendingHTTPFetch(flowKey: flowKey, method: method, path: path))
        }
    }

    private static func httpRequestIsComplete(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else {
            return false
        }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 13,
               bytes[index + 1] == 10,
               bytes[index + 2] == 13,
               bytes[index + 3] == 10 {
                return true
            }
        }
        return false
    }

    private static func encodedHTTPResponse(_ response: LinkLocalHTTPResponse) -> [UInt8] {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/octet-stream"
        }

        var text = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        for key in headers.keys.sorted() {
            text += "\(key): \(headers[key] ?? "")\r\n"
        }
        text += "\r\n"
        return Array(text.utf8) + response.body
    }

    private static func encodedProxyHTTPResponse(_ response: LinkLocalHTTPResponse, method: String) -> [UInt8] {
        if method == "HEAD" {
            return encodedHTTPResponse(
                LinkLocalHTTPResponse(
                    statusCode: response.statusCode,
                    reasonPhrase: response.reasonPhrase,
                    headers: response.headers,
                    body: []
                )
            )
        }
        return encodedHTTPResponse(response)
    }

    private func startHTTPFetch(_ fetch: PendingHTTPFetch) {
        switch httpTransport {
        case .synchronous:
            return
        case let .asynchronous(httpFetch):
            httpFetch(fetch.path) { [weak self] response in
                self?.finishHTTPFetch(fetch, response: response)
            }
        }
    }

    private func finishHTTPFetch(_ fetch: PendingHTTPFetch, response: LinkLocalHTTPResponse) {
        let encodedResponse = Self.encodedProxyHTTPResponse(response, method: fetch.method)
        stateLock.lock()
        guard var connection = tcpConnections[fetch.flowKey] else {
            stateLock.unlock()
            return
        }
        connection.fetchInFlight = false
        if connection.responseBytes == nil {
            connection.responseBytes = encodedResponse
        }
        connection.hostClosed = true
        let frames = appendPendingTCPResponseFrames(connection: &connection)
        tcpConnections[fetch.flowKey] = connection
        receiveFrames.append(contentsOf: frames)
        generatedFrameCount += frames.count
        stateLock.unlock()
        signalFramesAvailableIfNeeded(frames.count)
    }

    private func signalFramesAvailableIfNeeded(_ frameCount: Int) {
        guard frameCount > 0 else {
            return
        }
        onFramesAvailable?()
    }

    private static func defaultHTTPFetchAsync(
        path: String,
        completion: @escaping (LinkLocalHTTPResponse) -> Void
    ) {
        guard path.hasPrefix("/alpine/"),
              let url = URL(string: alpineProxyBaseURL + path) else {
            completion(LinkLocalHTTPResponse(statusCode: 404, reasonPhrase: "Not Found", body: Array("not found\n".utf8)))
            return
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(LinkLocalHTTPResponse(
                    statusCode: 502,
                    reasonPhrase: "Bad Gateway",
                    body: Array("package proxy fetch failed: \(error.localizedDescription)\n".utf8)
                ))
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            let reason = statusCode == 200 ? "OK" : "Upstream Status"
            completion(LinkLocalHTTPResponse(
                statusCode: statusCode,
                reasonPhrase: reason,
                headers: ["X-Arm64Viz-Proxy": "dl-cdn.alpinelinux.org"],
                body: [UInt8](data ?? Data())
            ))
        }
        task.resume()
    }

    private func tcpIPv4EthernetResponse(
        clientMAC: [UInt8],
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: UInt8,
        payload: [UInt8]
    ) -> [UInt8] {
        var tcp: [UInt8] = []
        Self.append16(sourcePort, to: &tcp)
        Self.append16(destinationPort, to: &tcp)
        Self.append32(sequence, to: &tcp)
        Self.append32(acknowledgment, to: &tcp)
        tcp += [0x50, flags]
        Self.append16(0xffff, to: &tcp)
        Self.append16(0, to: &tcp)
        Self.append16(0, to: &tcp)
        tcp += payload

        var pseudoHeader: [UInt8] = []
        pseudoHeader += sourceIP
        pseudoHeader += destinationIP
        pseudoHeader += [0, 6]
        Self.append16(UInt16(tcp.count), to: &pseudoHeader)
        let tcpChecksum = Self.checksum(pseudoHeader + tcp)
        Self.writeChecksum(tcpChecksum, into: &tcp, at: 16)

        return Self.ipv4EthernetResponse(
            clientMAC: clientMAC,
            protocolNumber: 6,
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            payload: tcp
        )
    }

    private static func ipv4EthernetResponse(
        clientMAC: [UInt8],
        protocolNumber: UInt8,
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        payload: [UInt8]
    ) -> [UInt8] {
        var ipHeader: [UInt8] = [0x45, 0x00]
        append16(UInt16(20 + payload.count), to: &ipHeader)
        append16(0, to: &ipHeader)
        append16(0x4000, to: &ipHeader)
        ipHeader += [64, protocolNumber]
        append16(0, to: &ipHeader)
        ipHeader += sourceIP
        ipHeader += destinationIP
        writeChecksum(checksum(ipHeader), into: &ipHeader, at: 10)

        return clientMAC + hostMAC + [0x08, 0x00] + ipHeader + payload
    }

    private static func isLocalServiceIPv4(_ ip: [UInt8]) -> Bool {
        ip == hostIPv4 || ip == dnsIPv4
    }

    private static func serverInitialSequence(for key: TCPFlowKey) -> UInt32 {
        0x4156_0000 &+ UInt32(key.sourcePort)
    }

    private static func ipv4Word(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count == 4 else {
            return 0
        }
        return UInt32(bytes[0]) << 24 |
            UInt32(bytes[1]) << 16 |
            UInt32(bytes[2]) << 8 |
            UInt32(bytes[3])
    }

    private static func read16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private struct TCPFlowKey: Hashable {
        let sourceIP: UInt32
        let destinationIP: UInt32
        let sourcePort: UInt16
        let destinationPort: UInt16
    }

    private struct TCPConnection {
        let clientMAC: [UInt8]
        let clientIP: [UInt8]
        let serverIP: [UInt8]
        let clientPort: UInt16
        let serverPort: UInt16
        let serverInitialSequence: UInt32
        var serverNextSequence: UInt32
        var clientNextSequence: UInt32
        var advertisedWindow: Int
        var requestBytes: [UInt8]
        var responseBytes: [UInt8]?
        var responseSentByteCount: Int
        var responseAckedByteCount: Int
        var finSent: Bool
        var fetchInFlight: Bool
        var hostClosed: Bool
        var pendingClientPayloads: [[UInt8]]
        var transport: VirtIOOutboundTCPConnection?
        var hostReady: Bool
        var resetQueued: Bool
    }

    private struct PendingHTTPFetch {
        let flowKey: TCPFlowKey
        let method: String
        let path: String
    }

    private struct DNSQuestion {
        let nameOffset: Int
        let bytes: [UInt8]
        let queryType: UInt16
        let queryClass: UInt16
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(~sum & 0xffff)
    }

    private static func normalizedICMPPayload(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else {
            return nil
        }
        if bytes[0] >> 4 == 4, bytes.count >= 20 {
            let ihl = Int(bytes[0] & 0x0f) * 4
            guard ihl >= 20, bytes.count >= ihl else {
                return nil
            }
            return Array(bytes[ihl..<bytes.count])
        }
        return bytes
    }

    private static func writeChecksum(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }
}

public final class VirtualVirtIODevice: MMIODevice {
    public static let magicValue: UInt32 = 0x7472_6976
    public static let version: UInt32 = 2
    public static let vendorID: UInt32 = 0x4156_3634
    public static let usedBufferInterrupt: UInt32 = 1
    public static let configChangeInterrupt: UInt32 = 2
    public static let version1FeatureSelectorValue: UInt32 = 1

    public let name: String
    public let range: AddressRange
    public let kind: VirtIODeviceKind
    public let inputRole: VirtIOInputRole
    public let interruptLine: UInt32?
    public let blockSize: Int

    private let interruptController: InterruptController?
    private let deviceLock = NSRecursiveLock()
    private let memory: PhysicalMemory?
    private var selectedDeviceFeatures: UInt32 = 0
    private var selectedDriverFeatures: UInt32 = 0
    private var driverFeatures: [UInt32: UInt32] = [:]
    private var selectedQueue: UInt32 = 0
    private var selectedSharedMemoryRegion: UInt32 = 0
    private var queues: [UInt32: VirtIOQueueState] = [:]
    private var interruptStatus: UInt32 = 0
    private var status: UInt32 = 0
    private var configGeneration: UInt32 = 0
    private var configSpace: [UInt8]
    private let blockStorage: VirtIOBlockStorage?
    private var networkBackend: VirtIONetworkBackend?
    private var pendingReceiveFrames: [[UInt8]] = []
    private var networkHeaderLength = VirtualVirtIODevice.virtioNetHeaderLength
    private var inputConfigSelect: UInt8 = 0
    private var inputConfigSubselect: UInt8 = 0
    private let inputMaximumX: UInt32
    private let inputMaximumY: UInt32
    private var pendingInputEvents: [VirtIOInputEvent] = []
    private var pendingInputReadIndex = 0
    private var pendingTouchMoveStart: Int?
    private var touchContactActive = false
    private var nextTouchTrackingID: Int32 = 0
    private let gpu: VirtIOGPUDevice?
    private var pendingGPUQueueCounts: [UInt32: Int] = [:]
    private var pendingGPUResources: [UInt64: Set<UInt32>] = [:]
    private var nextGPUCommandToken: UInt64 = 0

    private static let maximumInFlightGPUCommands = 3

    public private(set) var lastNotifiedQueue: UInt32?
    public private(set) var completedBlockRequests: Int = 0
    public private(set) var completedBlockRequestTypes: [UInt32: Int] = [:]
    public private(set) var recentBlockRequestSummaries: [String] = []
    public private(set) var completedNetworkTransmits: Int = 0
    public private(set) var completedNetworkReceives: Int = 0
    public private(set) var inputSamplesReceived: Int = 0
    public private(set) var inputFramesGenerated: Int = 0
    public private(set) var inputEventsDelivered: Int = 0
    public private(set) var inputFramesDelivered: Int = 0
    private var inputDeliveryTimes = [(frame: Int, timestamp: UInt64)?](repeating: nil, count: 128)
    public private(set) var inputQueueStarvations: Int = 0
    public var onDisplayFrameCommitted: (@Sendable (UInt64) -> Void)?

    public var pendingInputEventCount: Int {
        withDeviceLock { max(0, pendingInputEvents.count - pendingInputReadIndex) }
    }

    public var deliveredInputFrameCount: Int {
        withDeviceLock { inputFramesDelivered }
    }

    public func inputFrameDeliveryTimestamp(for frame: Int) -> UInt64? {
        withDeviceLock {
            guard frame > 0,
                  let sample = inputDeliveryTimes[frame % inputDeliveryTimes.count],
                  sample.frame == frame else { return nil }
            return sample.timestamp
        }
    }

    public var generatedInputFrameCount: Int {
        withDeviceLock { inputFramesGenerated }
    }

    public var inputFrameDeliveryProgress: (delivered: Int, target: Int) {
        withDeviceLock {
            let pendingFrames = pendingInputEvents[pendingInputReadIndex...]
                .reduce(into: 0) { count, event in
                    if event.type == 0, event.code == 0 {
                        count += 1
                    }
                }
            return (
                delivered: inputFramesDelivered,
                target: inputFramesDelivered + pendingFrames
            )
        }
    }

    public var inputDiagnostics: String {
        withDeviceLock {
            guard kind == .input else {
                return ""
            }
            let role = inputRole == .touchscreen ? "touch" : "key"
            let ready = queues[0]?.ready == true ? 1 : 0
            return "\(role)=s\(inputSamplesReceived)/f\(inputFramesGenerated)" +
                "/d\(inputFramesDelivered):e\(inputEventsDelivered)" +
                "/p\(pendingInputEventCount):q\(ready):x\(inputQueueStarvations)"
        }
    }

    public init(
        name: String,
        kind: VirtIODeviceKind,
        base: GuestAddress,
        length: UInt64 = 0x1000,
        interruptLine: UInt32? = nil,
        interruptController: InterruptController? = nil,
        memory: PhysicalMemory? = nil,
        storageSize: Int = 0,
        blockStorage: VirtIOBlockStorage? = nil,
        blockSize: Int = 512,
        macAddress: [UInt8] = [0x02, 0x61, 0x72, 0x6d, 0x36, 0x34],
        inputRole: VirtIOInputRole = .touchscreen,
        inputMaximumX: UInt32 = 639,
        inputMaximumY: UInt32 = 479,
        displayWidth: Int = 480,
        displayHeight: Int = 800
    ) {
        precondition(length >= 0x200, "virtio-mmio device range must include config space")
        precondition(blockSize > 0)
        self.name = name
        self.kind = kind
        self.inputRole = inputRole
        self.inputMaximumX = inputMaximumX
        self.inputMaximumY = inputMaximumY
        self.range = AddressRange(start: base, length: length)
        self.interruptLine = interruptLine
        self.interruptController = interruptController
        self.memory = memory
        self.blockSize = blockSize
        self.gpu = kind == .gpu ? VirtIOGPUDevice(width: displayWidth, height: displayHeight) : nil

        if kind == .block {
            let size = blockStorage?.count ?? max(storageSize, blockSize)
            precondition(size >= blockSize, "virtio block storage must contain at least one block")
            self.blockStorage = blockStorage ?? InMemoryVirtIOBlockStorage(count: size)
            self.configSpace = Self.blockConfig(storageSize: size, blockSize: blockSize)
        } else {
            self.blockStorage = nil
            self.configSpace = Self.configSpace(for: kind, macAddress: macAddress)
        }
    }

    public func attachNetworkBackend(_ backend: VirtIONetworkBackend?) {
        withDeviceLock {
            networkBackend = backend
            networkBackend?.onFramesAvailable = { [weak self] in
                self?.pumpNetworkReceiveQueue()
            }
        }
    }

    public func attachGraphicsAccelerator(
        _ accelerator: PineconeGraphicsAccelerator?
    ) {
        withDeviceLock {
            guard kind == .gpu else { return }
            gpu?.setGraphicsAccelerator(accelerator)
        }
    }

    public func injectNetworkReceiveFrame(_ frame: [UInt8]) {
        withDeviceLock {
            pendingReceiveFrames.append(frame)
            pumpNetworkReceiveQueue()
        }
    }

    public func pumpNetworkReceiveQueue() {
        withDeviceLock {
            guard kind == .network else {
                return
            }
            try? processNetworkReceiveQueue()
            updateInterruptLine()
        }
    }

    public func enqueueTouch(x: UInt32, y: UInt32, isDown: Bool) {
        enqueueTouches([TouchEvent(x: x, y: y, isDown: isDown)])
    }

    public func enqueueTouches(_ touches: [TouchEvent]) {
        guard !touches.isEmpty else { return }
        withDeviceLock {
        guard kind == .input, inputRole == .touchscreen else {
            return
        }
        for touch in touches {
            appendTouchLocked(x: touch.x, y: touch.y, isDown: touch.isDown)
        }
        if ((try? processInputEventQueue()) ?? 0) > 0 {
            interruptStatus |= Self.usedBufferInterrupt
            updateInterruptLine()
        }
        }
    }

    private func appendTouchLocked(x: UInt32, y: UInt32, isDown: Bool) {
        inputSamplesReceived += 1
        let clampedX = Int32(clamping: min(x, inputMaximumX))
        let clampedY = Int32(clamping: min(y, inputMaximumY))
        if isDown {
            if !touchContactActive {
                pendingTouchMoveStart = nil
                let trackingID = nextTouchTrackingID
                nextTouchTrackingID = nextTouchTrackingID == Int32.max ? 0 : nextTouchTrackingID + 1
                pendingInputEvents.append(contentsOf: [
                    VirtIOInputEvent(type: 1, code: 330, value: 1),
                    VirtIOInputEvent(type: 3, code: 0, value: clampedX),
                    VirtIOInputEvent(type: 3, code: 1, value: clampedY),
                    VirtIOInputEvent(type: 3, code: 47, value: 0),
                    VirtIOInputEvent(type: 3, code: 57, value: trackingID),
                    VirtIOInputEvent(type: 3, code: 53, value: clampedX),
                    VirtIOInputEvent(type: 3, code: 54, value: clampedY),
                    VirtIOInputEvent(type: 0, code: 0, value: 0)
                ])
                inputFramesGenerated += 1
                touchContactActive = true
            } else {
                let moveFrame = [
                    VirtIOInputEvent(type: 3, code: 0, value: clampedX),
                    VirtIOInputEvent(type: 3, code: 1, value: clampedY),
                    VirtIOInputEvent(type: 3, code: 47, value: 0),
                    VirtIOInputEvent(type: 3, code: 53, value: clampedX),
                    VirtIOInputEvent(type: 3, code: 54, value: clampedY),
                    VirtIOInputEvent(type: 0, code: 0, value: 0)
                ]
                if let start = pendingTouchMoveStart,
                   start >= pendingInputReadIndex,
                   start + moveFrame.count == pendingInputEvents.count {
                    pendingInputEvents.replaceSubrange(start..., with: moveFrame)
                } else {
                    pendingTouchMoveStart = pendingInputEvents.count
                    pendingInputEvents.append(contentsOf: moveFrame)
                }
                inputFramesGenerated += 1
            }
        } else if touchContactActive {
            pendingTouchMoveStart = nil
            pendingInputEvents.append(contentsOf: [
                VirtIOInputEvent(type: 1, code: 330, value: 0),
                VirtIOInputEvent(type: 3, code: 47, value: 0),
                VirtIOInputEvent(type: 3, code: 57, value: -1),
                VirtIOInputEvent(type: 0, code: 0, value: 0)
            ])
            inputFramesGenerated += 1
            touchContactActive = false
        }
    }

    public func enqueueKey(code: UInt16, value: Int32) {
        withDeviceLock {
        guard kind == .input, inputRole == .keyboard else {
            return
        }
        pendingInputEvents.append(contentsOf: [
            VirtIOInputEvent(type: 1, code: code, value: value),
            VirtIOInputEvent(type: 0, code: 0, value: 0)
        ])
        if ((try? processInputEventQueue()) ?? 0) > 0 {
            interruptStatus |= Self.usedBufferInterrupt
            updateInterruptLine()
        }
        }
    }

    public var storageBytes: [UInt8] {
        withDeviceLock {
            guard let blockStorage else {
                return []
            }
            return (try? blockStorage.snapshot()) ?? []
        }
    }

    public var storageByteCount: Int {
        withDeviceLock { blockStorage?.count ?? 0 }
    }

    public func flushStorage() throws {
        try withDeviceLock {
            guard kind == .block, let blockStorage else {
                throw VMError.deviceError("\(name) is not a block-capable virtio device")
            }
            try blockStorage.flush()
        }
    }

    public func displaySnapshot(afterGeneration previousGeneration: UInt64? = nil) -> VirtualFramebufferSnapshot? {
        guard kind == .gpu else { return nil }
        return gpu?.snapshot(afterGeneration: previousGeneration)
    }

    public func displayFrameMetadata(
        afterGeneration previousGeneration: UInt64? = nil
    ) -> VirtualFramebufferFrameMetadata? {
        guard kind == .gpu else { return nil }
        return gpu?.metadata(afterGeneration: previousGeneration)
    }

    public func withDisplayFrameBytes(
        afterGeneration previousGeneration: UInt64? = nil,
        _ body: (VirtualFramebufferFrameMetadata, UnsafeRawBufferPointer) -> Void
    ) -> VirtualFramebufferFrameMetadata? {
        guard kind == .gpu else { return nil }
        return gpu?.withFrameBytes(afterGeneration: previousGeneration, body)
    }

    public func displayFrameLease(
        afterGeneration previousGeneration: UInt64? = nil
    ) -> VirtualFramebufferFrameLease? {
        guard kind == .gpu else { return nil }
        return gpu?.frameLease(afterGeneration: previousGeneration)
    }

    public var displayGeneration: UInt64? {
        guard kind == .gpu else { return nil }
        return gpu?.generation
    }

    public func displayBackingSnapshot(memory: PhysicalMemory) -> VirtualFramebufferSnapshot? {
        guard kind == .gpu else { return nil }
        return gpu?.backingSnapshot(memory: memory)
    }

    public var displayDiagnostics: String {
        guard kind == .gpu else { return "" }
        return gpu?.diagnosticsSummary() ?? ""
    }

    public var displayPerformanceCounters: [String: Double] {
        guard kind == .gpu else { return [:] }
        return gpu?.performanceCounters() ?? [:]
    }

    public var blockRequestTypeCounts: [VirtIOBlockRequestTypeCount] {
        withDeviceLock {
            completedBlockRequestTypes
                .map {
                    VirtIOBlockRequestTypeCount(
                        requestType: $0.key,
                        name: Self.blockRequestTypeName($0.key),
                        count: $0.value
                    )
                }
                .sorted {
                    if $0.requestType == $1.requestType {
                        return $0.name < $1.name
                    }
                    return $0.requestType < $1.requestType
                }
        }
    }

    public static func blockRequestTypeName(_ requestType: UInt32) -> String {
        switch requestType {
        case 0:
            return "read"
        case 1:
            return "write"
        case 4:
            return "flush"
        case 11:
            return "discard"
        case 13:
            return "write_zeroes"
        default:
            return "unknown"
        }
    }

    public func replaceStorage(_ bytes: [UInt8], notifyConfigChange: Bool = true) throws {
        try withDeviceLock {
        guard kind == .block else {
            throw VMError.deviceError("\(name) is not a block-capable virtio device")
        }
        guard let blockStorage else {
            throw VMError.deviceError("\(name) has no block storage backend")
        }
        guard bytes.count <= blockStorage.count else {
            throw VMError.deviceError("\(name) storage image \(bytes.count) exceeds capacity \(blockStorage.count)")
        }

        try blockStorage.write(bytes, at: 0)
        try blockStorage.zero(at: bytes.count, count: blockStorage.count - bytes.count)
        configSpace = Self.blockConfig(storageSize: blockStorage.count, blockSize: blockSize)
        if notifyConfigChange {
            configGeneration &+= 1
            interruptStatus |= Self.configChangeInterrupt
            updateInterruptLine()
        }
        }
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        withDeviceLock {
        switch offset {
        case 0x000:
            return UInt64(Self.magicValue)
        case 0x004:
            return UInt64(Self.version)
        case 0x008:
            return UInt64(kind.rawValue)
        case 0x00c:
            return UInt64(Self.vendorID)
        case 0x010:
            return UInt64(deviceFeatures(for: selectedDeviceFeatures))
        case 0x034:
            return 256
        case 0x038:
            return UInt64(queueState().size)
        case 0x044:
            return queueState().ready ? 1 : 0
        case 0x060:
            return UInt64(interruptStatus)
        case 0x070:
            return UInt64(status)
        case 0x080:
            return UInt64(UInt32(queueState().descriptorAddress & 0xffff_ffff))
        case 0x084:
            return UInt64(UInt32(queueState().descriptorAddress >> 32))
        case 0x090:
            return UInt64(UInt32(queueState().driverAddress & 0xffff_ffff))
        case 0x094:
            return UInt64(UInt32(queueState().driverAddress >> 32))
        case 0x0a0:
            return UInt64(UInt32(queueState().deviceAddress & 0xffff_ffff))
        case 0x0a4:
            return UInt64(UInt32(queueState().deviceAddress >> 32))
        case 0x0ac:
            return UInt64(selectedSharedMemoryRegion)
        case 0x0b0, 0x0b4:
            // A 64-bit length of all ones means the selected region is absent.
            return UInt64(UInt32.max)
        case 0x0b8, 0x0bc:
            return 0
        case 0x0fc:
            return UInt64(configGeneration)
        case 0x100..<range.length:
            return readConfig(offset: offset - 0x100, width: width)
        default:
            return 0
        }
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        try withDeviceLock {
        switch offset {
        case 0x014:
            selectedDeviceFeatures = UInt32(value & 0xffff_ffff)
        case 0x020:
            driverFeatures[selectedDriverFeatures] = UInt32(value & 0xffff_ffff)
        case 0x024:
            selectedDriverFeatures = UInt32(value & 0xffff_ffff)
        case 0x030:
            selectedQueue = UInt32(value & 0xffff)
        case 0x038:
            updateSelectedQueue { $0.size = UInt32(value & 0xffff) }
        case 0x044:
            let ready = (value & 1) != 0
            if ready {
                try registerSelectedQueueMemory()
            }
            updateSelectedQueue { $0.ready = ready }
        case 0x050:
            notify(queue: UInt32(value & 0xffff))
        case 0x064:
            interruptStatus &= ~UInt32(value & 0x3)
            updateInterruptLine()
        case 0x070:
            if value == 0 {
                resetNegotiationState()
            } else {
                status = UInt32(value & 0xff)
            }
        case 0x080:
            updateSelectedQueue { $0.descriptorAddress = ($0.descriptorAddress & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff) }
        case 0x084:
            updateSelectedQueue { $0.descriptorAddress = ($0.descriptorAddress & 0x0000_0000_ffff_ffff) | ((value & 0xffff_ffff) << 32) }
        case 0x090:
            updateSelectedQueue { $0.driverAddress = ($0.driverAddress & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff) }
        case 0x094:
            updateSelectedQueue { $0.driverAddress = ($0.driverAddress & 0x0000_0000_ffff_ffff) | ((value & 0xffff_ffff) << 32) }
        case 0x0a0:
            updateSelectedQueue { $0.deviceAddress = ($0.deviceAddress & 0xffff_ffff_0000_0000) | (value & 0xffff_ffff) }
        case 0x0a4:
            updateSelectedQueue { $0.deviceAddress = ($0.deviceAddress & 0x0000_0000_ffff_ffff) | ((value & 0xffff_ffff) << 32) }
        case 0x0ac:
            selectedSharedMemoryRegion = UInt32(value & 0xffff_ffff)
        case 0x100..<range.length where kind == .input:
            writeInputConfig(offset: offset - 0x100, width: width, value: value)
        case 0x100..<range.length where kind == .gpu:
            writeGPUConfig(offset: offset - 0x100, width: width, value: value)
        default:
            return
        }
        }
    }

    public func reset() {
        withDeviceLock { resetNegotiationState() }
    }

    @inline(__always)
    private func withDeviceLock<T>(_ body: () throws -> T) rethrows -> T {
        deviceLock.lock()
        defer { deviceLock.unlock() }
        return try body()
    }

    private func resetNegotiationState() {
        selectedDeviceFeatures = 0
        selectedDriverFeatures = 0
        driverFeatures.removeAll()
        selectedQueue = 0
        selectedSharedMemoryRegion = 0
        queues.removeAll()
        interruptStatus = 0
        status = 0
        lastNotifiedQueue = nil
        completedBlockRequests = 0
        completedBlockRequestTypes.removeAll()
        recentBlockRequestSummaries.removeAll(keepingCapacity: true)
        completedNetworkTransmits = 0
        completedNetworkReceives = 0
        pendingReceiveFrames.removeAll()
        networkHeaderLength = Self.virtioNetHeaderLength
        inputConfigSelect = 0
        inputConfigSubselect = 0
        pendingInputEvents.removeAll(keepingCapacity: true)
        inputDeliveryTimes = .init(repeating: nil, count: inputDeliveryTimes.count)
        pendingInputReadIndex = 0
        pendingTouchMoveStart = nil
        touchContactActive = false
        nextTouchTrackingID = 0
        pendingGPUQueueCounts.removeAll(keepingCapacity: true)
        pendingGPUResources.removeAll(keepingCapacity: true)
        gpu?.reset()
        updateInterruptLine()
    }

    private func notify(queue: UInt32) {
        lastNotifiedQueue = queue
        guard queues[queue]?.ready == true else {
            return
        }
        var shouldInterrupt = false
        if kind == .block {
            try? processBlockQueue(queue)
            shouldInterrupt = true
        } else if kind == .network {
            if queue == 1 {
                try? processNetworkTransmitQueue(queue)
                try? processNetworkReceiveQueue()
            } else if queue == 0 {
                try? processNetworkReceiveQueue()
            }
            shouldInterrupt = true
        } else if kind == .input, queue == 0 {
            shouldInterrupt = ((try? processInputEventQueue()) ?? 0) > 0
        } else if kind == .gpu,
                  queue == VirtIOGPUDevice.controlQueue || queue == VirtIOGPUDevice.cursorQueue {
            shouldInterrupt = ((try? processGPUQueue(queue)) ?? 0) > 0
        }
        if shouldInterrupt {
            interruptStatus |= Self.usedBufferInterrupt
            updateInterruptLine()
        }
    }

    private func processGPUQueue(_ queue: UInt32) throws -> Int {
        guard var state = queues[queue], state.ready, state.size > 0,
              let memory, let gpu,
              pendingGPUQueueCounts[queue, default: 0] <
                Self.maximumInFlightGPUCommands else {
            return 0
        }
        let availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        let initialDisplayGeneration = gpu.generation
        var completed = 0
        while state.lastAvailableIndex != availableIndex {
            if pendingGPUQueueCounts[queue, default: 0] >=
                Self.maximumInFlightGPUCommands {
                break
            }
            let ringOffset = UInt64(4 + (UInt32(state.lastAvailableIndex) % state.size) * 2)
            let descriptorIndex = try readMemory16(memory, at: state.driverAddress + ringOffset)
            let descriptors = try descriptorChain(startingAt: descriptorIndex, queueState: state, memory: memory)
            let requestDescriptors = descriptors.filter { !$0.isDeviceWritable }
            let responseDescriptors = descriptors.filter(\.isDeviceWritable)
            guard !requestDescriptors.isEmpty else {
                throw VMError.deviceError("\(name) GPU command requires a readable request descriptor")
            }
            if queue == VirtIOGPUDevice.controlQueue, responseDescriptors.isEmpty {
                throw VMError.deviceError("\(name) GPU control command requires a writable response descriptor")
            }
            let requestLength = try requestDescriptors.reduce(0) { total, descriptor in
                let length = Int(descriptor.length)
                guard total <= 1_048_576 - length else {
                    throw VMError.deviceError("\(name) GPU control request is too large")
                }
                return total + length
            }
            var request = Array(repeating: UInt8(0), count: requestLength)
            try memory.copyOwnedDeviceBytes(
                from: requestDescriptors.map {
                    (address: $0.address, count: Int($0.length))
                },
                to: &request
            )
            let dependencies = VirtIOGPUDevice.resourceDependencies(request)
            if !pendingGPUResources.isEmpty && (dependencies == nil ||
                pendingGPUResources.values.contains(where: { !$0.isDisjoint(with: dependencies!) })) {
                break
            }
            var synchronousResponse: [UInt8]?
            if queue == VirtIOGPUDevice.controlQueue {
                let synchronousState = state
                state.lastAvailableIndex &+= 1
                let deferredQueueState = state
                queues[queue] = state
                pendingGPUQueueCounts[queue, default: 0] += 1
                nextGPUCommandToken &+= 1
                let commandToken = nextGPUCommandToken
                pendingGPUResources[commandToken] = dependencies ?? []
                let dispatch = gpu.processDeferred(
                    request: request,
                    memory: memory,
                    completion: { [weak self] response in
                        self?.completeDeferredGPUCommand(
                            queue: queue,
                            commandToken: commandToken,
                            descriptorIndex: descriptorIndex,
                            responseDescriptors: responseDescriptors,
                            queueState: deferredQueueState,
                            response: response
                        )
                    }
                )
                if case .deferred = dispatch {
                    continue
                }
                if case let .completed(response) = dispatch { synchronousResponse = response }
                pendingGPUResources.removeValue(forKey: commandToken)
                let pendingCount = pendingGPUQueueCounts[queue, default: 0]
                if pendingCount <= 1 {
                    pendingGPUQueueCounts.removeValue(forKey: queue)
                } else {
                    pendingGPUQueueCounts[queue] = pendingCount - 1
                }
                queues[queue] = synchronousState
                state = synchronousState
            }

            let response = synchronousResponse ?? gpu.process(request: request, memory: memory)
            var usedLength: UInt32 = 0
            if queue == VirtIOGPUDevice.controlQueue {
                let responseCapacity = responseDescriptors.reduce(0) { $0 + Int($1.length) }
                guard response.count <= responseCapacity else {
                    throw VMError.deviceError("\(name) GPU response descriptor is too small")
                }
                var responseOffset = 0
                for descriptor in responseDescriptors where responseOffset < response.count {
                    let count = min(Int(descriptor.length), response.count - responseOffset)
                    try memory.copyOwnedDeviceBytes(
                        from: response,
                        sourceOffset: responseOffset,
                        count: count,
                        to: descriptor.address
                    )
                    responseOffset += count
                }
                usedLength = UInt32(response.count)
            }
            try publishUsedElement(
                descriptorIndex: descriptorIndex,
                usedLength: usedLength,
                queueState: state,
                memory: memory
            )
            state.lastAvailableIndex &+= 1
            completed += 1
        }
        queues[queue] = state
        let finalDisplayGeneration = gpu.generation
        if finalDisplayGeneration != initialDisplayGeneration {
            onDisplayFrameCommitted?(finalDisplayGeneration)
        }
        return completed
    }

    private func completeDeferredGPUCommand(
        queue: UInt32,
        commandToken: UInt64,
        descriptorIndex: UInt16,
        responseDescriptors: [VirtIODescriptor],
        queueState: VirtIOQueueState,
        response: [UInt8]
    ) {
        withDeviceLock {
            guard pendingGPUResources.removeValue(forKey: commandToken) != nil,
                  let pendingCount = pendingGPUQueueCounts[queue],
                  pendingCount > 0, let memory else {
                return
            }
            if pendingCount == 1 {
                pendingGPUQueueCounts.removeValue(forKey: queue)
            } else {
                pendingGPUQueueCounts[queue] = pendingCount - 1
            }
            do {
                let responseCapacity = responseDescriptors.reduce(0) {
                    $0 + Int($1.length)
                }
                guard response.count <= responseCapacity else {
                    throw VMError.deviceError(
                        "\(name) deferred GPU response descriptor is too small"
                    )
                }
                var responseOffset = 0
                for descriptor in responseDescriptors where responseOffset < response.count {
                    let count = min(
                        Int(descriptor.length),
                        response.count - responseOffset
                    )
                    try memory.copyOwnedDeviceBytes(
                        from: response,
                        sourceOffset: responseOffset,
                        count: count,
                        to: descriptor.address
                    )
                    responseOffset += count
                }
                try publishUsedElement(
                    descriptorIndex: descriptorIndex,
                    usedLength: UInt32(response.count),
                    queueState: queueState,
                    memory: memory
                )
                interruptStatus |= Self.usedBufferInterrupt
                _ = try processGPUQueue(queue)
                _ = try processGPUQueue(VirtIOGPUDevice.cursorQueue)
                updateInterruptLine()
            } catch {
                interruptStatus |= Self.usedBufferInterrupt
                updateInterruptLine()
            }
        }
    }

    private func processInputEventQueue() throws -> Int {
        guard pendingInputReadIndex < pendingInputEvents.count else {
            return 0
        }
        guard var state = queues[0], state.ready, state.size > 0 else {
            inputQueueStarvations += 1
            return 0
        }
        guard let memory else {
            return 0
        }
        let availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        if state.lastAvailableIndex == availableIndex {
            inputQueueStarvations += 1
        }
        var delivered = 0
        while state.lastAvailableIndex != availableIndex,
              pendingInputReadIndex < pendingInputEvents.count {
            let ringOffset = UInt64(4 + (UInt32(state.lastAvailableIndex) % state.size) * 2)
            let descriptorIndex = try readMemory16(memory, at: state.driverAddress + ringOffset)
            let descriptors = try descriptorChain(startingAt: descriptorIndex, queueState: state, memory: memory)
            guard let target = descriptors.first(where: { $0.isDeviceWritable && $0.length >= 8 }) else {
                throw VMError.deviceError("\(name) input event queue requires an 8-byte writable descriptor")
            }
            let event = pendingInputEvents[pendingInputReadIndex]
            pendingInputReadIndex += 1
            if let moveStart = pendingTouchMoveStart, pendingInputReadIndex > moveStart {
                pendingTouchMoveStart = nil
            }
            var eventBytes = [UInt8](repeating: 0, count: 8)
            eventBytes[0] = UInt8(truncatingIfNeeded: event.type)
            eventBytes[1] = UInt8(truncatingIfNeeded: event.type >> 8)
            eventBytes[2] = UInt8(truncatingIfNeeded: event.code)
            eventBytes[3] = UInt8(truncatingIfNeeded: event.code >> 8)
            let eventValue = UInt32(bitPattern: event.value)
            eventBytes[4] = UInt8(truncatingIfNeeded: eventValue)
            eventBytes[5] = UInt8(truncatingIfNeeded: eventValue >> 8)
            eventBytes[6] = UInt8(truncatingIfNeeded: eventValue >> 16)
            eventBytes[7] = UInt8(truncatingIfNeeded: eventValue >> 24)
            try memory.copyOwnedDeviceBytes(
                from: eventBytes,
                sourceOffset: 0,
                count: eventBytes.count,
                to: target.address
            )
            try publishUsedElement(
                descriptorIndex: descriptorIndex,
                usedLength: 8,
                queueState: state,
                memory: memory
            )
            state.lastAvailableIndex &+= 1
            delivered += 1
            inputEventsDelivered += 1
            if event.type == 0, event.code == 0 {
                inputFramesDelivered += 1
                inputDeliveryTimes[inputFramesDelivered % inputDeliveryTimes.count] = (
                    inputFramesDelivered, DispatchTime.now().uptimeNanoseconds
                )
            }
        }
        queues[0] = state
        compactPendingInputEvents()
        return delivered
    }

    private func compactPendingInputEvents() {
        guard pendingInputReadIndex > 0 else {
            return
        }
        if pendingInputReadIndex == pendingInputEvents.count {
            pendingInputEvents.removeAll(keepingCapacity: true)
            pendingInputReadIndex = 0
            pendingTouchMoveStart = nil
            return
        }
        guard pendingInputReadIndex >= 256,
              pendingInputReadIndex * 2 >= pendingInputEvents.count else {
            return
        }
        pendingInputEvents.removeFirst(pendingInputReadIndex)
        if let moveStart = pendingTouchMoveStart {
            pendingTouchMoveStart = moveStart - pendingInputReadIndex
        }
        pendingInputReadIndex = 0
    }

    private func processNetworkTransmitQueue(_ queue: UInt32) throws {
        guard var state = queues[queue], state.ready, state.size > 0 else {
            return
        }
        guard let memory else {
            return
        }

        let availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        while state.lastAvailableIndex != availableIndex {
            let ringOffset = UInt64(4 + (UInt32(state.lastAvailableIndex) % state.size) * 2)
            let descriptorIndex = try readMemory16(memory, at: state.driverAddress + ringOffset)
            let frame = try readNetworkTransmitFrame(
                descriptorIndex: descriptorIndex,
                queueState: state,
                memory: memory
            )
            networkBackend?.transmit(frame: frame)
            try publishUsedElement(
                descriptorIndex: descriptorIndex,
                usedLength: UInt32(frame.count + networkHeaderLength),
                queueState: state,
                memory: memory
            )
            state.lastAvailableIndex &+= 1
            completedNetworkTransmits += 1
        }

        queues[queue] = state
    }

    private func processNetworkReceiveQueue() throws {
        guard var state = queues[0], state.ready, state.size > 0 else {
            return
        }
        guard let memory else {
            return
        }

        var frames = pendingReceiveFrames
        pendingReceiveFrames.removeAll(keepingCapacity: true)
        while let backendFrame = networkBackend?.receive() {
            frames.append(backendFrame)
        }
        guard !frames.isEmpty else {
            queues[0] = state
            return
        }

        var availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        while state.lastAvailableIndex != availableIndex, !frames.isEmpty {
            let frame = frames.removeFirst()
            let ringOffset = UInt64(4 + (UInt32(state.lastAvailableIndex) % state.size) * 2)
            let descriptorIndex = try readMemory16(memory, at: state.driverAddress + ringOffset)
            let usedLength = try writeNetworkReceiveFrame(
                frame,
                descriptorIndex: descriptorIndex,
                queueState: state,
                memory: memory
            )
            try publishUsedElement(
                descriptorIndex: descriptorIndex,
                usedLength: usedLength,
                queueState: state,
                memory: memory
            )
            state.lastAvailableIndex &+= 1
            completedNetworkReceives += 1
            interruptStatus |= Self.usedBufferInterrupt
            availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        }

        pendingReceiveFrames.insert(contentsOf: frames, at: 0)
        queues[0] = state
    }

    private static let virtioNetHeaderLength = 10

    private func readNetworkTransmitFrame(
        descriptorIndex: UInt16,
        queueState: VirtIOQueueState,
        memory: PhysicalMemory
    ) throws -> [UInt8] {
        let descriptors = try descriptorChain(startingAt: descriptorIndex, queueState: queueState, memory: memory)
        let byteCount = descriptors.reduce(0) { partialResult, descriptor in
            partialResult + (descriptor.isDeviceWritable ? 0 : Int(descriptor.length))
        }
        var bytes = Array(repeating: UInt8(0), count: byteCount)
        var copied = 0
        for descriptor in descriptors {
            guard !descriptor.isDeviceWritable else {
                continue
            }
            let count = Int(descriptor.length)
            try memory.copyOwnedDeviceBytes(
                from: descriptor.address,
                count: count,
                to: &bytes,
                destinationOffset: copied
            )
            copied += count
        }
        guard bytes.count >= Self.virtioNetHeaderLength else {
            return []
        }
        let frame = Array(bytes.dropFirst(Self.virtioNetHeaderLength))
        if frame.count >= 16,
           !Self.isSupportedEtherType(frame, at: 12),
           Self.isSupportedEtherType(frame, at: 14) {
            networkHeaderLength = 12
            return Array(bytes.dropFirst(networkHeaderLength))
        }
        networkHeaderLength = Self.virtioNetHeaderLength
        return frame
    }

    private func writeNetworkReceiveFrame(
        _ frame: [UInt8],
        descriptorIndex: UInt16,
        queueState: VirtIOQueueState,
        memory: PhysicalMemory
    ) throws -> UInt32 {
        let descriptors = try descriptorChain(startingAt: descriptorIndex, queueState: queueState, memory: memory)
        var packet = Array(repeating: UInt8(0), count: networkHeaderLength)
        if networkHeaderLength == 12 {
            packet[10] = 1
        }
        packet.append(contentsOf: frame)
        var copied = 0
        for descriptor in descriptors {
            guard descriptor.isDeviceWritable else {
                continue
            }
            let remaining = packet.count - copied
            guard remaining > 0 else {
                break
            }
            let count = min(Int(descriptor.length), remaining)
            try memory.copyOwnedDeviceBytes(
                from: packet,
                sourceOffset: copied,
                count: count,
                to: descriptor.address
            )
            copied += count
        }
        return UInt32(copied)
    }

    private static func isSupportedEtherType(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard bytes.count > offset + 1 else {
            return false
        }
        let etherType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        return etherType == 0x0800 || etherType == 0x0806
    }

    private func processBlockQueue(_ queue: UInt32) throws {
        guard var state = queues[queue], state.ready, state.size > 0 else {
            return
        }
        guard kind == .block, let memory else {
            return
        }

        let availableIndex = try readMemory16Acquire(memory, at: state.driverAddress + 2)
        while state.lastAvailableIndex != availableIndex {
            let ringOffset = UInt64(4 + (UInt32(state.lastAvailableIndex) % state.size) * 2)
            let descriptorIndex = try readMemory16(memory, at: state.driverAddress + ringOffset)
            let usedLength = try processBlockRequest(
                descriptorIndex: descriptorIndex,
                queueState: state,
                memory: memory
            )
            try publishUsedElement(
                descriptorIndex: descriptorIndex,
                usedLength: usedLength,
                queueState: state,
                memory: memory
            )
            state.lastAvailableIndex &+= 1
            completedBlockRequests += 1
        }

        queues[queue] = state
    }

    private func processBlockRequest(
        descriptorIndex: UInt16,
        queueState: VirtIOQueueState,
        memory: PhysicalMemory
    ) throws -> UInt32 {
        guard let blockStorage else {
            throw VMError.deviceError("\(name) has no block storage backend")
        }
        let descriptors = try descriptorChain(startingAt: descriptorIndex, queueState: queueState, memory: memory)
        guard descriptors.count >= 2 else {
            try writeStatus(1, descriptors: descriptors, memory: memory)
            return 1
        }

        guard descriptors[0].length >= 16 else {
            try writeStatus(1, descriptors: descriptors, memory: memory)
            return 1
        }

        var requestHeader = [UInt8](repeating: 0, count: 16)
        try memory.copyOwnedDeviceBytes(
            from: descriptors[0].address,
            count: requestHeader.count,
            to: &requestHeader,
            destinationOffset: 0
        )
        let requestType = UInt32(littleEndianBytes: requestHeader[0..<4])
        let sector = UInt64(littleEndianBytes: requestHeader[8..<16])
        let dataDescriptors = descriptors.dropFirst().dropLast()
        let dataLength = dataDescriptors.reduce(0) { $0 + Int($1.length) }

        switch requestType {
        case 0:
            guard let diskOffset = blockOffset(
                forSector: sector,
                byteCount: dataLength,
                storageByteCount: blockStorage.count
            ) else {
                try writeStatus(1, descriptors: descriptors, memory: memory)
                recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                return 1
            }
            var guestBuffers: [UnsafeMutableRawBufferPointer] = []
            guestBuffers.reserveCapacity(dataDescriptors.count)
            for descriptor in dataDescriptors {
                guard descriptor.isDeviceWritable else {
                    try writeStatus(1, descriptors: descriptors, memory: memory)
                    recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                    return 1
                }
                let count = Int(descriptor.length)
                guard count > 0 else { continue }
                guestBuffers.append(
                    try memory.ownedDeviceBuffer(
                        at: descriptor.address,
                        count: count
                    )
                )
            }
            try blockStorage.read(into: guestBuffers, at: diskOffset)
            for descriptor in dataDescriptors where descriptor.length > 0 {
                try memory.publishOwnedDeviceWrite(
                    at: descriptor.address,
                    count: Int(descriptor.length)
                )
            }
            try writeStatus(0, descriptors: descriptors, memory: memory)
            recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 0)
            return UInt32(dataLength + 1)
        case 1:
            guard let diskOffset = blockOffset(
                forSector: sector,
                byteCount: dataLength,
                storageByteCount: blockStorage.count
            ) else {
                try writeStatus(1, descriptors: descriptors, memory: memory)
                recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                return 1
            }
            var guestBuffers: [UnsafeRawBufferPointer] = []
            guestBuffers.reserveCapacity(dataDescriptors.count)
            for descriptor in dataDescriptors {
                guard !descriptor.isDeviceWritable else {
                    try writeStatus(1, descriptors: descriptors, memory: memory)
                    recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                    return 1
                }
                let count = Int(descriptor.length)
                guard count > 0 else { continue }
                guestBuffers.append(
                    UnsafeRawBufferPointer(
                        try memory.ownedDeviceBuffer(
                            at: descriptor.address,
                            count: count
                        )
                    )
                )
            }
            try blockStorage.write(from: guestBuffers, at: diskOffset)
            try writeStatus(0, descriptors: descriptors, memory: memory)
            recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 0)
            return 1
        case 4:
            try blockStorage.flush()
            try writeStatus(0, descriptors: descriptors, memory: memory)
            recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 0)
            return 1
        case 11, 13:
            let ranges = try readDiscardOrWriteZeroRanges(dataDescriptors, memory: memory)
            guard !ranges.isEmpty else {
                try writeStatus(1, descriptors: descriptors, memory: memory)
                recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                return 1
            }

            for range in ranges {
                guard let offset = blockOffset(
                    forSector: range.sector,
                    sectorCount: UInt64(range.sectorCount),
                    storageByteCount: blockStorage.count
                ) else {
                    try writeStatus(1, descriptors: descriptors, memory: memory)
                    recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 1)
                    return 1
                }
                try blockStorage.zero(at: offset.byteOffset, count: offset.byteCount)
            }

            try writeStatus(0, descriptors: descriptors, memory: memory)
            let detail = ranges.map { "\($0.sector)+\($0.sectorCount)" }.joined(separator: ",")
            recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 0, detail: detail)
            return 1
        default:
            try writeStatus(2, descriptors: descriptors, memory: memory)
            recordBlockRequest(type: requestType, sector: sector, payloadLength: dataLength, status: 2)
            return 1
        }
    }

    private struct BlockRange {
        let sector: UInt64
        let sectorCount: UInt32
        let flags: UInt32
    }

    private func readDiscardOrWriteZeroRanges(
        _ descriptors: ArraySlice<VirtIODescriptor>,
        memory: PhysicalMemory
    ) throws -> [BlockRange] {
        let payloadLength = descriptors.reduce(0) { partialResult, descriptor in
            partialResult + Int(descriptor.length)
        }
        var payload = Array(repeating: UInt8(0), count: payloadLength)
        var copied = 0
        for descriptor in descriptors {
            guard !descriptor.isDeviceWritable else {
                return []
            }
            let count = Int(descriptor.length)
            try memory.copyOwnedDeviceBytes(
                from: descriptor.address,
                count: count,
                to: &payload,
                destinationOffset: copied
            )
            copied += count
        }
        guard !payload.isEmpty, payload.count % 16 == 0 else {
            return []
        }

        var ranges: [BlockRange] = []
        ranges.reserveCapacity(payload.count / 16)
        var offset = 0
        while offset < payload.count {
            let sector = UInt64(littleEndianBytes: payload[offset..<(offset + 8)])
            let sectorCount = UInt32(littleEndianBytes: payload[(offset + 8)..<(offset + 12)])
            let flags = UInt32(littleEndianBytes: payload[(offset + 12)..<(offset + 16)])
            ranges.append(BlockRange(sector: sector, sectorCount: sectorCount, flags: flags))
            offset += 16
        }
        return ranges
    }

    private func blockOffset(
        forSector sector: UInt64,
        byteCount: Int,
        storageByteCount: Int
    ) -> Int? {
        guard byteCount >= 0 else {
            return nil
        }
        guard sector <= UInt64(Int.max / blockSize) else {
            return nil
        }
        let offset = Int(sector) * blockSize
        guard offset <= storageByteCount, byteCount <= storageByteCount - offset else {
            return nil
        }
        return offset
    }

    private func blockOffset(
        forSector sector: UInt64,
        sectorCount: UInt64,
        storageByteCount: Int
    ) -> (byteOffset: Int, byteCount: Int)? {
        guard sector <= UInt64(Int.max / blockSize),
              sectorCount <= UInt64(Int.max / blockSize) else {
            return nil
        }
        let offset = Int(sector) * blockSize
        let byteCount = Int(sectorCount) * blockSize
        guard offset <= storageByteCount, byteCount <= storageByteCount - offset else {
            return nil
        }
        return (offset, byteCount)
    }

    private func recordBlockRequest(
        type requestType: UInt32,
        sector: UInt64,
        payloadLength: Int,
        status: UInt8,
        detail: String? = nil
    ) {
        completedBlockRequestTypes[requestType, default: 0] += 1
#if DEBUG
        var summary = "type=\(Self.blockRequestTypeName(requestType))(\(requestType)) sector=\(sector) payload=\(payloadLength) status=\(status)"
        if let detail, !detail.isEmpty {
            summary += " ranges=\(detail)"
        }
        recentBlockRequestSummaries.append(summary)
        if recentBlockRequestSummaries.count > 24 {
            recentBlockRequestSummaries.removeFirst(recentBlockRequestSummaries.count - 24)
        }
#endif
    }

    private func descriptorChain(
        startingAt descriptorIndex: UInt16,
        queueState: VirtIOQueueState,
        memory: PhysicalMemory
    ) throws -> [VirtIODescriptor] {
        var descriptors: [VirtIODescriptor] = []
        var current = descriptorIndex
        var visited: Set<UInt16> = []

        while true {
            guard current < queueState.size, visited.insert(current).inserted else {
                throw VMError.deviceError("\(name) invalid virtqueue descriptor chain")
            }

            let descriptor = try readDescriptor(at: queueState.descriptorAddress + UInt64(current) * 16, memory: memory)
            if descriptor.isIndirect {
                return try indirectDescriptorChain(descriptor, memory: memory)
            }

            descriptors.append(descriptor)
            if !descriptor.hasNext {
                return descriptors
            }
            current = descriptor.next
        }
    }

    private func indirectDescriptorChain(_ descriptor: VirtIODescriptor, memory: PhysicalMemory) throws -> [VirtIODescriptor] {
        guard descriptor.length >= 16 else {
            throw VMError.deviceError("\(name) invalid indirect descriptor table")
        }
        try memory.registerDeviceSharedRange(
            at: descriptor.address,
            count: Int(descriptor.length)
        )
        let tableCount = Int(descriptor.length / 16)
        var descriptors: [VirtIODescriptor] = []
        var current: UInt16 = 0
        var visited: Set<UInt16> = []

        while true {
            guard Int(current) < tableCount, visited.insert(current).inserted else {
                throw VMError.deviceError("\(name) invalid indirect descriptor chain")
            }
            let entry = try readDescriptor(at: descriptor.address + UInt64(current) * 16, memory: memory)
            guard !entry.isIndirect else {
                throw VMError.deviceError("\(name) nested indirect descriptors are unsupported")
            }
            descriptors.append(entry)
            if !entry.hasNext {
                return descriptors
            }
            current = entry.next
        }
    }

    private func readDescriptor(at address: GuestAddress, memory: PhysicalMemory) throws -> VirtIODescriptor {
        VirtIODescriptor(
            address: try readMemory64(memory, at: address),
            length: try readMemory32(memory, at: address + 8),
            flags: try readMemory16(memory, at: address + 12),
            next: try readMemory16(memory, at: address + 14)
        )
    }

    private func writeStatus(_ status: UInt8, descriptors: [VirtIODescriptor], memory: PhysicalMemory) throws {
        guard let statusDescriptor = descriptors.last, statusDescriptor.isDeviceWritable, statusDescriptor.length > 0 else {
            return
        }
        let statusBytes = [status]
        try memory.copyOwnedDeviceBytes(
            from: statusBytes,
            sourceOffset: 0,
            count: statusBytes.count,
            to: statusDescriptor.address
        )
    }

    private func publishUsedElement(
        descriptorIndex: UInt16,
        usedLength: UInt32,
        queueState: VirtIOQueueState,
        memory: PhysicalMemory
    ) throws {
        let usedIndex = try readMemory16(memory, at: queueState.deviceAddress + 2)
        let ringSlot = UInt64(4 + (UInt32(usedIndex) % queueState.size) * 8)
        try writeMemory32(UInt32(descriptorIndex), at: queueState.deviceAddress + ringSlot, memory: memory)
        try writeMemory32(usedLength, at: queueState.deviceAddress + ringSlot + 4, memory: memory)
        try writeMemory16Release(
            usedIndex &+ 1,
            at: queueState.deviceAddress + 2,
            memory: memory
        )
    }

    private func updateInterruptLine() {
        guard let interruptLine, let interruptController else {
            return
        }
        if interruptStatus != 0 {
            interruptController.raise(line: interruptLine)
        } else {
            interruptController.clear(line: interruptLine)
        }
    }

    private func queueState() -> VirtIOQueueState {
        queues[selectedQueue] ?? VirtIOQueueState()
    }

    private func updateSelectedQueue(_ update: (inout VirtIOQueueState) -> Void) {
        var state = queueState()
        update(&state)
        queues[selectedQueue] = state
    }

    private func registerSelectedQueueMemory() throws {
        guard let memory else {
            throw VMError.deviceError("\(name) has no guest memory")
        }
        let state = queueState()
        guard state.size > 0,
              state.descriptorAddress != 0,
              state.driverAddress != 0,
              state.deviceAddress != 0 else {
            throw VMError.deviceError("\(name) queue \(selectedQueue) is incomplete")
        }

        let queueSize = UInt64(state.size)
        let descriptorBytes = queueSize.multipliedReportingOverflow(by: 16)
        let availableBytes = queueSize.multipliedReportingOverflow(by: 2)
        let usedBytes = queueSize.multipliedReportingOverflow(by: 8)
        guard !descriptorBytes.overflow,
              !availableBytes.overflow,
              !usedBytes.overflow,
              availableBytes.partialValue <= UInt64(Int.max - 6),
              usedBytes.partialValue <= UInt64(Int.max - 6),
              descriptorBytes.partialValue <= UInt64(Int.max) else {
            throw VMError.deviceError("\(name) queue \(selectedQueue) size overflows")
        }

        try memory.registerDeviceSharedRange(
            at: state.descriptorAddress,
            count: Int(descriptorBytes.partialValue)
        )
        try memory.registerDeviceSharedRange(
            at: state.driverAddress,
            count: Int(availableBytes.partialValue) + 6
        )
        try memory.registerDeviceSharedRange(
            at: state.deviceAddress,
            count: Int(usedBytes.partialValue) + 6
        )
    }

    private func deviceFeatures(for selector: UInt32) -> UInt32 {
        switch selector {
        case 0:
            return kind.lowFeatureBits
        case 1:
            return Self.version1FeatureSelectorValue
        default:
            return 0
        }
    }

    private func readConfig(offset: UInt64, width: MMIOWidth) -> UInt64 {
        if kind == .input {
            return readInputConfig(offset: offset, width: width)
        }
        guard offset <= UInt64(Int.max) else {
            return 0
        }
        let start = Int(offset)
        var value: UInt64 = 0
        for byteIndex in 0..<width.rawValue {
            let index = start + byteIndex
            guard index < configSpace.count else {
                break
            }
            value |= UInt64(configSpace[index]) << UInt64(byteIndex * 8)
        }
        return value
    }

    private func writeInputConfig(offset: UInt64, width: MMIOWidth, value: UInt64) {
        for byteIndex in 0..<width.rawValue {
            let byteOffset = offset + UInt64(byteIndex)
            let byte = UInt8((value >> UInt64(byteIndex * 8)) & 0xff)
            if byteOffset == 0 {
                inputConfigSelect = byte
            } else if byteOffset == 1 {
                inputConfigSubselect = byte
            }
        }
    }

    private func writeGPUConfig(offset: UInt64, width: MMIOWidth, value: UInt64) {
        // events_clear is the only writable field in virtio_gpu_config.
        guard offset < 8, offset + UInt64(width.rawValue) > 4 else { return }
        var clearMask: UInt32 = 0
        for byteIndex in 0..<width.rawValue {
            let fieldOffset = Int(offset) + byteIndex
            guard (4..<8).contains(fieldOffset) else { continue }
            clearMask |= UInt32((value >> UInt64(byteIndex * 8)) & 0xff) << UInt32((fieldOffset - 4) * 8)
        }
        let events = Self.readLE32(configSpace, at: 0) & ~clearMask
        Self.writeLE32(events, into: &configSpace, at: 0)
    }

    private func readInputConfig(offset: UInt64, width: MMIOWidth) -> UInt64 {
        let bytes = inputConfigBytes()
        guard offset <= UInt64(Int.max) else {
            return 0
        }
        var value: UInt64 = 0
        for byteIndex in 0..<width.rawValue {
            let index = Int(offset) + byteIndex
            guard index < bytes.count else {
                break
            }
            value |= UInt64(bytes[index]) << UInt64(byteIndex * 8)
        }
        return value
    }

    private func inputConfigBytes() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 136)
        bytes[0] = inputConfigSelect
        bytes[1] = inputConfigSubselect
        var payload: [UInt8] = []
        switch inputConfigSelect {
        case 0x01:
            payload = Array((inputRole == .keyboard ? "Pinecone Keyboard" : "Pinecone Touchscreen").utf8)
        case 0x02:
            payload = Array((inputRole == .keyboard ? "arm64viz-keyboard0" : "arm64viz-touch0").utf8)
        case 0x03:
            payload = Array(repeating: 0, count: 8)
            Self.writeLE16(0x06, into: &payload, at: 0)
            Self.writeLE16(0x4156, into: &payload, at: 2)
            Self.writeLE16(0x0001, into: &payload, at: 4)
            Self.writeLE16(0x0001, into: &payload, at: 6)
        case 0x10 where inputConfigSubselect == 0 && inputRole == .touchscreen:
            payload = [0x02]
        case 0x11:
            payload = inputEventBitmap(for: inputConfigSubselect)
        case 0x12 where inputRole == .touchscreen:
            let maximum: UInt32
            switch inputConfigSubselect {
            case 0, 53:
                maximum = inputMaximumX
            case 1, 54:
                maximum = inputMaximumY
            case 47:
                maximum = 0
            case 57:
                maximum = UInt32(UInt16.max)
            default:
                return bytes
            }
            payload = Array(repeating: 0, count: 20)
            Self.writeLE32(maximum, into: &payload, at: 4)
        default:
            payload = []
        }
        let count = min(payload.count, 128)
        bytes[2] = UInt8(count)
        if count > 0 {
            bytes.replaceSubrange(8..<(8 + count), with: payload.prefix(count))
        }
        return bytes
    }

    private func inputEventBitmap(for eventType: UInt8) -> [UInt8] {
        if inputRole == .keyboard {
            switch eventType {
            case 0:
                return [0x03, 0x00, 0x10]
            case 1:
                var bitmap = Array(repeating: UInt8(0xff), count: 32)
                bitmap[0] &= 0xfe
                return bitmap
            default:
                return []
            }
        }
        switch eventType {
        case 0:
            return [0x0b]
        case 1:
            var bitmap = Array(repeating: UInt8(0), count: 42)
            bitmap[330 / 8] |= UInt8(1 << (330 % 8))
            return bitmap
        case 3:
            var bitmap = Array(repeating: UInt8(0), count: 8)
            for code in [0, 1, 47, 53, 54, 57] {
                bitmap[code / 8] |= UInt8(1 << (code % 8))
            }
            return bitmap
        default:
            return []
        }
    }

    private static func configSpace(for kind: VirtIODeviceKind, macAddress: [UInt8]) -> [UInt8] {
        switch kind {
        case .network:
            var bytes = Array(repeating: UInt8(0), count: 8)
            for index in 0..<min(6, macAddress.count) {
                bytes[index] = macAddress[index]
            }
            writeLE16(1, into: &bytes, at: 6)
            return bytes
        case .input:
            return Array(repeating: 0, count: 136)
        case .gpu:
            var bytes = Array(repeating: UInt8(0), count: 16)
            writeLE32(1, into: &bytes, at: 8)
            return bytes
        case .block:
            return blockConfig(storageSize: 512, blockSize: 512)
        }
    }

    private static func blockConfig(storageSize: Int, blockSize: Int) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 64)
        let sectorCount = UInt32(min(storageSize / blockSize, Int(UInt32.max)))
        writeLE64(UInt64(storageSize / blockSize), into: &bytes, at: 0)
        writeLE32(UInt32(blockSize), into: &bytes, at: 20)
        writeLE32(sectorCount, into: &bytes, at: 36)
        writeLE32(1, into: &bytes, at: 40)
        writeLE32(1, into: &bytes, at: 44)
        writeLE32(sectorCount, into: &bytes, at: 48)
        writeLE32(1, into: &bytes, at: 52)
        return bytes
    }

    private static func writeLE16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else { return 0 }
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func writeLE32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for byteIndex in 0..<4 {
            bytes[offset + byteIndex] = UInt8((value >> UInt32(byteIndex * 8)) & 0xff)
        }
    }

    private static func writeLE64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for byteIndex in 0..<8 {
            bytes[offset + byteIndex] = UInt8((value >> UInt64(byteIndex * 8)) & 0xff)
        }
    }
}

private func readMemory16(_ memory: PhysicalMemory, at address: GuestAddress) throws -> UInt16 {
    try memory.read16(at: address)
}

private func readMemory16Acquire(_ memory: PhysicalMemory, at address: GuestAddress) throws -> UInt16 {
    try memory.read16Acquire(at: address)
}

private func readMemory32(_ memory: PhysicalMemory, at address: GuestAddress) throws -> UInt32 {
    try memory.read32(at: address)
}

private func readMemory64(_ memory: PhysicalMemory, at address: GuestAddress) throws -> UInt64 {
    try memory.read64(at: address)
}

private func writeMemory16(_ value: UInt16, at address: GuestAddress, memory: PhysicalMemory) throws {
    try memory.write16(value, at: address)
}

private func writeMemory16Release(
    _ value: UInt16,
    at address: GuestAddress,
    memory: PhysicalMemory
) throws {
    try memory.write16Release(value, at: address)
}

private func writeMemory32(_ value: UInt32, at address: GuestAddress, memory: PhysicalMemory) throws {
    try memory.write32(value, at: address)
}

private extension UInt32 {
    init<T: Collection>(littleEndianBytes bytes: T) where T.Element == UInt8 {
        var value: UInt32 = 0
        for (offset, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << UInt32(offset * 8)
        }
        self = value
    }
}

private extension UInt64 {
    init<T: Collection>(littleEndianBytes bytes: T) where T.Element == UInt8 {
        var value: UInt64 = 0
        for (offset, byte) in bytes.prefix(8).enumerated() {
            value |= UInt64(byte) << UInt64(offset * 8)
        }
        self = value
    }
}
