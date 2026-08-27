import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class MMIOVCPUContext {
    private var key = pthread_key_t()

    init() {
        precondition(pthread_key_create(&key, nil) == 0)
    }

    deinit {
        pthread_key_delete(key)
    }

    @inline(__always)
    var current: Int {
        guard let encoded = pthread_getspecific(key) else { return 0 }
        return Int(bitPattern: encoded) - 1
    }

    @inline(__always)
    func withValue<T>(_ vcpuID: Int, _ body: () throws -> T) rethrows -> T {
        let previous = pthread_getspecific(key)
        let encoded = UnsafeMutableRawPointer(bitPattern: max(0, vcpuID) + 1)
        pthread_setspecific(key, encoded)
        defer { pthread_setspecific(key, previous) }
        return try body()
    }
}

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
    private let vcpuContext = MMIOVCPUContext()

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
        let target: MMIODevice
        lock.lock()
        guard let resolved = devices.first(where: {
            $0.range.contains(address, width: UInt64(width.rawValue))
        }) else {
            lock.unlock()
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        target = resolved
        lock.unlock()
        return try vcpuContext.withValue(targetVCPU) {
            try target.read(offset: address - target.range.start, width: width)
        }
    }

    public func write(
        address: GuestAddress,
        width: MMIOWidth,
        value: UInt64,
        targetVCPU: Int = 0
    ) throws {
        let target: MMIODevice
        lock.lock()
        guard let resolved = devices.first(where: {
            $0.range.contains(address, width: UInt64(width.rawValue))
        }) else {
            lock.unlock()
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        target = resolved
        lock.unlock()
        try vcpuContext.withValue(targetVCPU) {
            try target.write(
                offset: address - target.range.start,
                width: width,
                value: value
            )
        }
    }

    public var currentVCPUID: Int {
        vcpuContext.current
    }

    public func reset() {
        lock.lock()
        let registeredDevices = devices
        lock.unlock()
        for device in registeredDevices {
            device.reset()
        }
    }
}
