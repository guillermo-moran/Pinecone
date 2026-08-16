import Foundation

public protocol MMIODevice: AnyObject {
    var name: String { get }
    var range: AddressRange { get }

    func read(offset: UInt64, width: MMIOWidth) throws -> UInt64
    func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws
    func reset()
}

public final class MMIOBus {
    private let lock = NSRecursiveLock()
    private var devices: [MMIODevice] = []
    private var callingVCPUID = 0

    public init() {}

    public var allDevices: [MMIODevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices
    }

    public func register(_ device: MMIODevice) throws {
        lock.lock()
        defer { lock.unlock() }
        for existing in devices where existing.range.overlaps(device.range) {
            throw VMError.overlappingMMIORange(device: device.name, existing: existing.name)
        }
        devices.append(device)
    }

    public func device(containing address: GuestAddress, width: MMIOWidth = .byte) -> MMIODevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices.first { $0.range.contains(address, width: UInt64(width.rawValue)) }
    }

    public func read(
        address: GuestAddress,
        width: MMIOWidth,
        targetVCPU: Int = 0
    ) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let target = device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        let previousVCPUID = callingVCPUID
        callingVCPUID = targetVCPU
        defer { callingVCPUID = previousVCPUID }
        return try target.read(offset: address - target.range.start, width: width)
    }

    public func write(
        address: GuestAddress,
        width: MMIOWidth,
        value: UInt64,
        targetVCPU: Int = 0
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let target = device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        let previousVCPUID = callingVCPUID
        callingVCPUID = targetVCPU
        defer { callingVCPUID = previousVCPUID }
        try target.write(offset: address - target.range.start, width: width, value: value)
    }

    public var currentVCPUID: Int {
        lock.lock()
        defer { lock.unlock() }
        return callingVCPUID
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for device in devices {
            device.reset()
        }
    }
}
