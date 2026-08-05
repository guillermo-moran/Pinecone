import ARM64VizNative
import Foundation

public final class PhysicalMemory {
    public let base: GuestAddress
    public let size: Int
    private let nativeMemory: OpaquePointer
    private let bytes: UnsafeMutableRawBufferPointer

    public init(base: GuestAddress, size: Int) {
        precondition(size > 0, "physical memory must not be empty")
        guard let nativeMemory = avz_guest_memory_create(size),
              let baseAddress = avz_guest_memory_bytes(nativeMemory) else {
            preconditionFailure("failed to reserve \(size) bytes of guest memory")
        }
        self.base = base
        self.size = size
        self.nativeMemory = nativeMemory
        self.bytes = UnsafeMutableRawBufferPointer(start: baseAddress, count: size)
    }

    deinit {
        avz_guest_memory_destroy(nativeMemory)
    }

    public var range: AddressRange {
        AddressRange(start: base, length: UInt64(size))
    }

    public func load(_ data: [UInt8], at address: GuestAddress) throws {
        let startIndex = try index(for: address, width: data.count)
        guard startIndex + data.count <= bytes.count else {
            throw VMError.invalidMemoryAccess(address: address, width: data.count)
        }
        guard !data.isEmpty else {
            return
        }
        _ = data.withUnsafeBytes { sourceBytes in
            memcpy(
                bytes.baseAddress!.advanced(by: startIndex),
                sourceBytes.baseAddress!,
                data.count
            )
        }
        markDirty(offset: startIndex, count: data.count)
    }

    public func read8(at address: GuestAddress) throws -> UInt8 {
        bytes[try index(for: address, width: 1)]
    }

    public func write8(_ value: UInt8, at address: GuestAddress) throws {
        let startIndex = try index(for: address, width: 1)
        bytes[startIndex] = value
        markDirty(offset: startIndex, count: 1)
    }

    public func read16(at address: GuestAddress) throws -> UInt16 {
        try readInteger(at: address, as: UInt16.self)
    }

    public func write16(_ value: UInt16, at address: GuestAddress) throws {
        try writeInteger(value, at: address)
    }

    public func read32(at address: GuestAddress) throws -> UInt32 {
        try readInteger(at: address, as: UInt32.self)
    }

    public func write32(_ value: UInt32, at address: GuestAddress) throws {
        try writeInteger(value, at: address)
    }

    public func read64(at address: GuestAddress) throws -> UInt64 {
        try readInteger(at: address, as: UInt64.self)
    }

    public func write64(_ value: UInt64, at address: GuestAddress) throws {
        try writeInteger(value, at: address)
    }

    public func readBytes(at address: GuestAddress, count: Int) throws -> [UInt8] {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else {
            return []
        }
        let startIndex = try index(for: address, width: count)
        var result = Array(repeating: UInt8(0), count: count)
        _ = result.withUnsafeMutableBytes { destinationBytes in
            memcpy(
                destinationBytes.baseAddress!,
                bytes.baseAddress!.advanced(by: startIndex),
                count
            )
        }
        return result
    }

    public func writeBytes(_ value: [UInt8], at address: GuestAddress) throws {
        guard !value.isEmpty else {
            return
        }
        let startIndex = try index(for: address, width: value.count)
        _ = value.withUnsafeBytes { sourceBytes in
            memcpy(
                bytes.baseAddress!.advanced(by: startIndex),
                sourceBytes.baseAddress!,
                value.count
            )
        }
        markDirty(offset: startIndex, count: value.count)
    }

    public func copyBytes(
        from source: [UInt8],
        sourceOffset: Int,
        count: Int,
        to address: GuestAddress
    ) throws {
        guard count >= 0,
              sourceOffset >= 0,
              sourceOffset <= source.count,
              count <= source.count - sourceOffset else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else {
            return
        }
        let destinationIndex = try index(for: address, width: count)
        _ = source.withUnsafeBytes { sourceBytes in
            memcpy(
                bytes.baseAddress!.advanced(by: destinationIndex),
                sourceBytes.baseAddress!.advanced(by: sourceOffset),
                count
            )
        }
        markDirty(offset: destinationIndex, count: count)
    }

    public func copyBytes(
        from address: GuestAddress,
        count: Int,
        to destination: inout [UInt8],
        destinationOffset: Int
    ) throws {
        guard count >= 0,
              destinationOffset >= 0,
              destinationOffset <= destination.count,
              count <= destination.count - destinationOffset else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else {
            return
        }
        let sourceIndex = try index(for: address, width: count)
        _ = destination.withUnsafeMutableBytes { destinationBytes in
            memcpy(
                destinationBytes.baseAddress!.advanced(by: destinationOffset),
                bytes.baseAddress!.advanced(by: sourceIndex),
                count
            )
        }
    }

    func copyBytes(
        from address: GuestAddress,
        count: Int,
        to destination: UnsafeMutableRawPointer
    ) throws {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else {
            return
        }
        let sourceIndex = try index(for: address, width: count)
        memcpy(
            destination,
            bytes.baseAddress!.advanced(by: sourceIndex),
            count
        )
    }

    public func snapshotBytes() -> [UInt8] {
        Array(bytes)
    }

    public func restoreBytes(_ newBytes: [UInt8]) throws {
        guard newBytes.count == bytes.count else {
            throw VMError.invalidSnapshot("RAM size \(newBytes.count) does not match \(bytes.count)")
        }
        try writeBytes(newBytes, at: base)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(bytes))
    }

    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        defer { markDirty(offset: 0, count: size) }
        return try body(bytes)
    }

    func withUnsafeMutableBytesWithoutDirtyTracking<R>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        try body(bytes)
    }

    // PhysicalMemory owns a fixed mmap allocation, so this pointer remains
    // stable for the lifetime of the memory object.
    var persistentMutableBytes: UnsafeMutableRawBufferPointer {
        bytes
    }

    var nativeMemoryHandle: OpaquePointer {
        nativeMemory
    }

    func markDirty(at address: GuestAddress, count: Int) {
        guard count > 0,
              let offset = try? index(for: address, width: count) else {
            return
        }
        markDirty(offset: offset, count: count)
    }

    func advanceDirtyEpoch() -> UInt64 {
        avz_guest_memory_advance_dirty_epoch(nativeMemory)
    }

    func dirtyRanges(
        at address: GuestAddress,
        count: Int,
        afterEpoch: UInt64,
        throughEpoch: UInt64,
        capacity: Int = 512
    ) -> [(address: GuestAddress, count: Int)] {
        guard count > 0,
              capacity > 0,
              let offset = try? index(for: address, width: count) else {
            return []
        }

        return withUnsafeTemporaryAllocation(
            of: AVZGuestDirtyRange.self,
            capacity: capacity
        ) { ranges in
            let rangeCount = avz_guest_memory_dirty_ranges(
                nativeMemory,
                offset,
                count,
                afterEpoch,
                throughEpoch,
                ranges.baseAddress,
                capacity
            )
            return (0..<rangeCount).map { index in
                let range = ranges[index]
                return (
                    address: base + GuestAddress(range.offset),
                    count: range.length
                )
            }
        }
    }

    private func readInteger<T: FixedWidthInteger>(at address: GuestAddress, as type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        let startIndex = try index(for: address, width: width)
        var value: T = 0
        memcpy(&value, bytes.baseAddress!.advanced(by: startIndex), width)
        return T(littleEndian: value)
    }

    private func writeInteger<T: FixedWidthInteger>(_ value: T, at address: GuestAddress) throws {
        let width = MemoryLayout<T>.size
        let startIndex = try index(for: address, width: width)
        var littleEndianValue = value.littleEndian
        memcpy(
            bytes.baseAddress!.advanced(by: startIndex),
            &littleEndianValue,
            width
        )
        markDirty(offset: startIndex, count: width)
    }

    private func markDirty(offset: Int, count: Int) {
        avz_guest_memory_mark_dirty(nativeMemory, offset, count)
    }

    private func index(for address: GuestAddress, width: Int) throws -> Int {
        guard width > 0, range.contains(address, width: UInt64(width)) else {
            throw VMError.invalidMemoryAccess(address: address, width: width)
        }
        return Int(address - base)
    }
}
