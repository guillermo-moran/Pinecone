import Foundation

/// A PCI Express ECAM window containing a small, fixed set of endpoints.
public final class VirtualPCIExpressHost: MMIODevice {
    public let name = "pcie-ecam"
    public let range: AddressRange

    private let lock = NSRecursiveLock()
    private var endpoints: [UInt16: VirtIOPCIEndpoint] = [:]

    public init(base: GuestAddress, length: UInt64) {
        precondition(length >= 1 << 20, "PCI ECAM must expose at least one bus")
        self.range = AddressRange(start: base, length: length)
    }

    public func addEndpoint(_ endpoint: VirtIOPCIEndpoint) {
        lock.lock()
        defer { lock.unlock() }
        precondition(endpoints[endpoint.requesterID] == nil, "duplicate PCI requester ID")
        endpoints[endpoint.requesterID] = endpoint
    }

    public func endpoint(device: UInt8, function: UInt8 = 0) -> VirtIOPCIEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[UInt16(device) << 3 | UInt16(function)]
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let decoded = decode(offset: offset)
        guard decoded.bus == 0,
              let endpoint = endpoints[decoded.requesterID] else {
            return width == .doubleword
                ? UInt64.max
                : (UInt64(1) << UInt64(width.rawValue * 8)) - 1
        }
        return endpoint.readConfiguration(offset: decoded.register, width: width)
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        let decoded = decode(offset: offset)
        guard decoded.bus == 0,
              let endpoint = endpoints[decoded.requesterID] else { return }
        endpoint.writeConfiguration(offset: decoded.register, width: width, value: value)
    }

    public func reset() {
        lock.lock()
        let values = Array(endpoints.values)
        lock.unlock()
        values.forEach { $0.resetConfiguration() }
    }

    private func decode(offset: UInt64) -> (
        bus: UInt8,
        requesterID: UInt16,
        register: UInt16
    ) {
        let bus = UInt8((offset >> 20) & 0xff)
        let device = UInt16((offset >> 15) & 0x1f)
        let function = UInt16((offset >> 12) & 0x7)
        return (bus, device << 3 | function, UInt16(offset & 0xfff))
    }
}

/// PCI configuration-space identity and BAR ownership for a modern VirtIO endpoint.
public final class VirtIOPCIEndpoint {
    public static let vendorID: UInt16 = 0x1af4

    public let deviceNumber: UInt8
    public let functionNumber: UInt8
    public let barAddress: GuestAddress
    public let barSize: UInt32
    public let transport: VirtIOPCIModernTransport

    public var requesterID: UInt16 {
        UInt16(deviceNumber) << 3 | UInt16(functionNumber)
    }

    private var configuration = [UInt8](repeating: 0, count: 4096)
    private var probingBAR0 = false

    public init(
        deviceNumber: UInt8,
        functionNumber: UInt8 = 0,
        barAddress: GuestAddress,
        barSize: UInt32,
        transport: VirtIOPCIModernTransport
    ) {
        precondition(deviceNumber < 32 && functionNumber < 8)
        precondition(barAddress <= UInt64(UInt32.max))
        precondition(barSize >= 0x4000 && barSize.nonzeroBitCount == 1)
        precondition(barAddress % UInt64(barSize) == 0)
        self.deviceNumber = deviceNumber
        self.functionNumber = functionNumber
        self.barAddress = barAddress
        self.barSize = barSize
        self.transport = transport
        initializeConfiguration()
    }

    public func readConfiguration(offset: UInt16, width: MMIOWidth) -> UInt64 {
        if probingBAR0, offset == 0x10, width == .word {
            return UInt64((~(barSize - 1)) & 0xffff_fff0)
        }
        return readLittleEndian(configuration, offset: Int(offset), width: width.rawValue)
    }

    public func writeConfiguration(offset: UInt16, width: MMIOWidth, value: UInt64) {
        if offset == 0x10, width == .word {
            if UInt32(truncatingIfNeeded: value) == UInt32.max {
                probingBAR0 = true
            } else {
                probingBAR0 = false
                writeLE32(UInt32(barAddress), at: 0x10)
            }
            return
        }

        // The command register and interrupt-line byte are the writable fields
        // needed by Linux's generic PCI host probing path.
        if offset >= 0x04, Int(offset) + width.rawValue <= 0x06 {
            writeLittleEndian(value, into: &configuration, offset: Int(offset), width: width.rawValue)
        } else if offset == 0x3c, width == .byte {
            configuration[0x3c] = UInt8(truncatingIfNeeded: value)
        }
    }

    public func resetConfiguration() {
        probingBAR0 = false
        initializeConfiguration()
    }

    private func initializeConfiguration() {
        configuration = [UInt8](repeating: 0, count: 4096)
        writeLE16(Self.vendorID, at: 0x00)
        writeLE16(UInt16(0x1040) &+ UInt16(transport.device.kind.rawValue), at: 0x02)
        writeLE16(0x0006, at: 0x04) // memory-space and bus-master enable
        writeLE16(0x0010, at: 0x06) // capabilities list
        configuration[0x08] = 1 // revision
        let classCode = transport.pciClassCode
        configuration[0x09] = UInt8(classCode & 0xff)
        configuration[0x0a] = UInt8((classCode >> 8) & 0xff)
        configuration[0x0b] = UInt8((classCode >> 16) & 0xff)
        writeLE32(UInt32(barAddress), at: 0x10)
        writeLE16(Self.vendorID, at: 0x2c)
        writeLE16(UInt16(transport.device.kind.rawValue), at: 0x2e)
        configuration[0x34] = 0x40
        configuration[0x3c] = 0xff
        configuration[0x3d] = 1 // INTA

        writeVirtIOCapability(at: 0x40, next: 0x50, type: 1, barOffset: 0x0000, length: 0x38)
        writeVirtIOCapability(at: 0x50, next: 0x64, type: 2, barOffset: 0x1000, length: 0x1000, notifyMultiplier: 4)
        writeVirtIOCapability(at: 0x64, next: 0x74, type: 3, barOffset: 0x2000, length: 1)
        writeVirtIOCapability(at: 0x74, next: 0, type: 4, barOffset: 0x3000, length: 0x100)
    }

    private func writeVirtIOCapability(
        at offset: Int,
        next: UInt8,
        type: UInt8,
        barOffset: UInt32,
        length: UInt32,
        notifyMultiplier: UInt32? = nil
    ) {
        configuration[offset] = 0x09 // PCI_CAP_ID_VNDR
        configuration[offset + 1] = next
        configuration[offset + 2] = notifyMultiplier == nil ? 16 : 20
        configuration[offset + 3] = type
        configuration[offset + 4] = 0
        writeLE32(barOffset, at: offset + 8)
        writeLE32(length, at: offset + 12)
        if let notifyMultiplier {
            writeLE32(notifyMultiplier, at: offset + 16)
        }
    }

    private func writeLE16(_ value: UInt16, at offset: Int) {
        configuration[offset] = UInt8(value & 0xff)
        configuration[offset + 1] = UInt8(value >> 8)
    }

    private func writeLE32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            configuration[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
    }
}

/// Modern VirtIO PCI BAR layout translating the common configuration into the
/// existing, transport-independent VirtIO queue engine.
public final class VirtIOPCIModernTransport: MMIODevice {
    public let name: String
    public let range: AddressRange
    public let device: VirtualVirtIODevice

    fileprivate var pciClassCode: UInt32 {
        switch device.kind {
        case .network: return 0x02_00_00
        case .block: return 0x01_80_00
        case .gpu: return 0x03_80_00
        case .input: return 0x09_80_00
        }
    }

    private var deviceFeatureSelect: UInt32 = 0
    private var driverFeatureSelect: UInt32 = 0
    private var driverFeatures: [UInt32: UInt32] = [:]
    private var selectedQueue: UInt16 = 0

    public init(name: String, base: GuestAddress, device: VirtualVirtIODevice) {
        self.name = name
        self.range = AddressRange(start: base, length: 0x4000)
        self.device = device
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        switch offset {
        case 0x0000..<0x0038:
            return try readCommon(offset: offset, width: width)
        case 0x1000..<0x2000:
            return 0
        case 0x2000..<0x2001:
            // PCI ISR reads atomically consume all pending causes.  Do not
            // translate this into separate virtio-mmio status/ack accesses:
            // a concurrent queue completion can land between those accesses
            // and the stale ack will clear its only interrupt notification.
            return UInt64(device.consumePCIInterruptStatus() & 0xff)
        case 0x3000..<0x3100:
            return try device.read(offset: 0x100 + offset - 0x3000, width: width)
        default:
            return 0
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        switch offset {
        case 0x0000..<0x0038:
            try writeCommon(offset: offset, width: width, value: value)
        case 0x1000..<0x2000:
            let queue = UInt32((offset - 0x1000) / 4)
            try device.write(offset: 0x050, width: .word, value: UInt64(queue))
        case 0x3000..<0x3100:
            try device.write(offset: 0x100 + offset - 0x3000, width: width, value: value)
        default:
            return
        }
    }

    public func reset() {
        deviceFeatureSelect = 0
        driverFeatureSelect = 0
        driverFeatures.removeAll()
        selectedQueue = 0
    }

    private var queueCount: UInt16 {
        switch device.kind {
        case .block: return 1
        case .network, .gpu, .input: return 2
        }
    }

    private func readCommon(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        switch (offset, width) {
        case (0x00, .word): return UInt64(deviceFeatureSelect)
        case (0x04, .word):
            try device.write(offset: 0x014, width: .word, value: UInt64(deviceFeatureSelect))
            return try device.read(offset: 0x010, width: .word)
        case (0x08, .word): return UInt64(driverFeatureSelect)
        case (0x0c, .word): return UInt64(driverFeatures[driverFeatureSelect] ?? 0)
        case (0x10, .halfword): return 0xffff
        case (0x12, .halfword): return UInt64(queueCount)
        case (0x14, .byte): return try device.read(offset: 0x070, width: .word) & 0xff
        case (0x15, .byte): return try device.read(offset: 0x0fc, width: .word) & 0xff
        case (0x16, .halfword): return UInt64(selectedQueue)
        case (0x18, .halfword): return try selectedQueueSize()
        case (0x1a, .halfword): return 0xffff
        case (0x1c, .halfword): return try device.read(offset: 0x044, width: .word) & 1
        case (0x1e, .halfword): return UInt64(selectedQueue)
        case (0x20, .doubleword): return try readQueueAddress(lowOffset: 0x080)
        case (0x20, .word): return try device.read(offset: 0x080, width: .word)
        case (0x24, .word): return try device.read(offset: 0x084, width: .word)
        case (0x28, .doubleword): return try readQueueAddress(lowOffset: 0x090)
        case (0x28, .word): return try device.read(offset: 0x090, width: .word)
        case (0x2c, .word): return try device.read(offset: 0x094, width: .word)
        case (0x30, .doubleword): return try readQueueAddress(lowOffset: 0x0a0)
        case (0x30, .word): return try device.read(offset: 0x0a0, width: .word)
        case (0x34, .word): return try device.read(offset: 0x0a4, width: .word)
        default:
            return try readCommonBytes(offset: offset, width: width)
        }
    }

    private func writeCommon(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        switch (offset, width) {
        case (0x00, .word):
            deviceFeatureSelect = UInt32(truncatingIfNeeded: value)
            try device.write(offset: 0x014, width: .word, value: value)
        case (0x08, .word):
            driverFeatureSelect = UInt32(truncatingIfNeeded: value)
            try device.write(offset: 0x024, width: .word, value: value)
        case (0x0c, .word):
            driverFeatures[driverFeatureSelect] = UInt32(truncatingIfNeeded: value)
            try device.write(offset: 0x020, width: .word, value: value)
        case (0x14, .byte):
            try device.write(offset: 0x070, width: .word, value: value & 0xff)
        case (0x16, .halfword):
            selectedQueue = UInt16(truncatingIfNeeded: value)
            try device.write(offset: 0x030, width: .word, value: value & 0xffff)
        case (0x18, .halfword):
            try device.write(offset: 0x038, width: .word, value: value & 0xffff)
        case (0x1c, .halfword):
            try device.write(offset: 0x044, width: .word, value: value & 1)
        case (0x20, .doubleword): try writeQueueAddress(value, lowOffset: 0x080)
        case (0x20, .word): try device.write(offset: 0x080, width: .word, value: value)
        case (0x24, .word): try device.write(offset: 0x084, width: .word, value: value)
        case (0x28, .doubleword): try writeQueueAddress(value, lowOffset: 0x090)
        case (0x28, .word): try device.write(offset: 0x090, width: .word, value: value)
        case (0x2c, .word): try device.write(offset: 0x094, width: .word, value: value)
        case (0x30, .doubleword): try writeQueueAddress(value, lowOffset: 0x0a0)
        case (0x30, .word): try device.write(offset: 0x0a0, width: .word, value: value)
        case (0x34, .word): try device.write(offset: 0x0a4, width: .word, value: value)
        default:
            return
        }
    }

    private func readQueueAddress(lowOffset: UInt64) throws -> UInt64 {
        let low = try device.read(offset: lowOffset, width: .word)
        let high = try device.read(offset: lowOffset + 4, width: .word)
        return low | (high << 32)
    }

    private func writeQueueAddress(_ value: UInt64, lowOffset: UInt64) throws {
        try device.write(offset: lowOffset, width: .word, value: value & 0xffff_ffff)
        try device.write(offset: lowOffset + 4, width: .word, value: value >> 32)
    }

    private func readCommonBytes(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<width.rawValue {
            let byteOffset = offset + UInt64(index)
            value |= UInt64(try readCommonByte(at: byteOffset)) << UInt64(index * 8)
        }
        return value
    }

    private func readCommonByte(at offset: UInt64) throws -> UInt8 {
        func byte(_ value: UInt64, base: UInt64) -> UInt8 {
            UInt8((value >> ((offset - base) * 8)) & 0xff)
        }

        switch offset {
        case 0x00..<0x04:
            return byte(UInt64(deviceFeatureSelect), base: 0x00)
        case 0x04..<0x08:
            try device.write(offset: 0x014, width: .word, value: UInt64(deviceFeatureSelect))
            return byte(try device.read(offset: 0x010, width: .word), base: 0x04)
        case 0x08..<0x0c:
            return byte(UInt64(driverFeatureSelect), base: 0x08)
        case 0x0c..<0x10:
            return byte(UInt64(driverFeatures[driverFeatureSelect] ?? 0), base: 0x0c)
        case 0x10..<0x12:
            return byte(0xffff, base: 0x10)
        case 0x12..<0x14:
            return byte(UInt64(queueCount), base: 0x12)
        case 0x14:
            return UInt8(try device.read(offset: 0x070, width: .word) & 0xff)
        case 0x15:
            return UInt8(try device.read(offset: 0x0fc, width: .word) & 0xff)
        case 0x16..<0x18:
            return byte(UInt64(selectedQueue), base: 0x16)
        case 0x18..<0x1a:
            return byte(try selectedQueueSize(), base: 0x18)
        case 0x1a..<0x1c:
            return byte(0xffff, base: 0x1a)
        case 0x1c..<0x1e:
            return byte(try device.read(offset: 0x044, width: .word), base: 0x1c)
        case 0x1e..<0x20:
            return byte(UInt64(selectedQueue), base: 0x1e)
        case 0x20..<0x28:
            return byte(try readQueueAddress(lowOffset: 0x080), base: 0x20)
        case 0x28..<0x30:
            return byte(try readQueueAddress(lowOffset: 0x090), base: 0x28)
        case 0x30..<0x38:
            return byte(try readQueueAddress(lowOffset: 0x0a0), base: 0x30)
        default:
            return 0
        }
    }

    private func selectedQueueSize() throws -> UInt64 {
        guard selectedQueue < queueCount else { return 0 }
        let configuredSize = try device.read(offset: 0x038, width: .word) & 0xffff
        // In the modern PCI common configuration, queue_size advertises the
        // maximum size until the driver selects a smaller size. The shared
        // VirtIO engine stores zero for a queue that has not been configured
        // yet because its MMIO transport exposes that maximum separately.
        return configuredSize == 0 ? 256 : configuredSize
    }
}

private func readLittleEndian(_ bytes: [UInt8], offset: Int, width: Int) -> UInt64 {
    guard offset >= 0, width > 0, offset + width <= bytes.count else { return 0 }
    var value: UInt64 = 0
    for index in 0..<width {
        value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    }
    return value
}

private func writeLittleEndian(
    _ value: UInt64,
    into bytes: inout [UInt8],
    offset: Int,
    width: Int
) {
    guard offset >= 0, width > 0, offset + width <= bytes.count else { return }
    for index in 0..<width {
        bytes[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
    }
}
