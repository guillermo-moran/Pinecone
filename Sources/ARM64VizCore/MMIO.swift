public protocol MMIODevice: AnyObject {
    var name: String { get }
    var range: AddressRange { get }

    func read(offset: UInt64, width: MMIOWidth) throws -> UInt64
    func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws
    func reset()
}

public final class MMIOBus {
    private var devices: [MMIODevice] = []

    public init() {}

    public var allDevices: [MMIODevice] {
        devices
    }

    public func register(_ device: MMIODevice) throws {
        for existing in devices where existing.range.overlaps(device.range) {
            throw VMError.overlappingMMIORange(device: device.name, existing: existing.name)
        }
        devices.append(device)
    }

    public func device(containing address: GuestAddress, width: MMIOWidth = .byte) -> MMIODevice? {
        devices.first { $0.range.contains(address, width: UInt64(width.rawValue)) }
    }

    public func read(address: GuestAddress, width: MMIOWidth) throws -> UInt64 {
        guard let target = device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        return try target.read(offset: address - target.range.start, width: width)
    }

    public func write(address: GuestAddress, width: MMIOWidth, value: UInt64) throws {
        guard let target = device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        try target.write(offset: address - target.range.start, width: width, value: value)
    }

    public func reset() {
        for device in devices {
            device.reset()
        }
    }
}
