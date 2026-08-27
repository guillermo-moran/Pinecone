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
        withAccessLock(offset: startIndex, count: data.count) {
            _ = data.withUnsafeBytes { sourceBytes in
                memcpy(
                    bytes.baseAddress!.advanced(by: startIndex),
                    sourceBytes.baseAddress!,
                    data.count
                )
            }
            markDirty(offset: startIndex, count: data.count)
        }
    }

    public func read8(at address: GuestAddress) throws -> UInt8 {
        let startIndex = try index(for: address, width: 1)
        return withAccessLock(offset: startIndex, count: 1) { bytes[startIndex] }
    }

    public func write8(_ value: UInt8, at address: GuestAddress) throws {
        let startIndex = try index(for: address, width: 1)
        withAccessLock(offset: startIndex, count: 1) {
            bytes[startIndex] = value
            markDirty(offset: startIndex, count: 1)
        }
    }

    public func read16(at address: GuestAddress) throws -> UInt16 {
        try readInteger(at: address, as: UInt16.self)
    }

    public func write16(_ value: UInt16, at address: GuestAddress) throws {
        try writeInteger(value, at: address)
    }

    func read16Acquire(at address: GuestAddress) throws -> UInt16 {
        let offset = try index(for: address, width: MemoryLayout<UInt16>.size)
        var value: UInt16 = 0
        guard avz_guest_memory_load_u16_acquire(nativeMemory, offset, &value) != 0 else {
            throw VMError.invalidMemoryAccess(
                address: address,
                width: MemoryLayout<UInt16>.size
            )
        }
        return value
    }

    func write16Release(_ value: UInt16, at address: GuestAddress) throws {
        let offset = try index(for: address, width: MemoryLayout<UInt16>.size)
        guard avz_guest_memory_store_u16_release(nativeMemory, offset, value) != 0 else {
            throw VMError.invalidMemoryAccess(
                address: address,
                width: MemoryLayout<UInt16>.size
            )
        }
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
        withAccessLock(offset: startIndex, count: count) {
            _ = result.withUnsafeMutableBytes { destinationBytes in
                memcpy(
                    destinationBytes.baseAddress!,
                    bytes.baseAddress!.advanced(by: startIndex),
                    count
                )
            }
        }
        return result
    }

    public func writeBytes(_ value: [UInt8], at address: GuestAddress) throws {
        guard !value.isEmpty else {
            return
        }
        let startIndex = try index(for: address, width: value.count)
        withAccessLock(offset: startIndex, count: value.count) {
            _ = value.withUnsafeBytes { sourceBytes in
                memcpy(
                    bytes.baseAddress!.advanced(by: startIndex),
                    sourceBytes.baseAddress!,
                    value.count
                )
            }
            markDirty(offset: startIndex, count: value.count)
        }
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
        withAccessLock(offset: destinationIndex, count: count) {
            _ = source.withUnsafeBytes { sourceBytes in
                memcpy(
                    bytes.baseAddress!.advanced(by: destinationIndex),
                    sourceBytes.baseAddress!.advanced(by: sourceOffset),
                    count
                )
            }
            markDirty(offset: destinationIndex, count: count)
        }
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
        withAccessLock(offset: sourceIndex, count: count) {
            _ = destination.withUnsafeMutableBytes { destinationBytes in
                memcpy(
                    destinationBytes.baseAddress!.advanced(by: destinationOffset),
                    bytes.baseAddress!.advanced(by: sourceIndex),
                    count
                )
            }
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
        _ = withAccessLock(offset: sourceIndex, count: count) {
            memcpy(
                destination,
                bytes.baseAddress!.advanced(by: sourceIndex),
                count
            )
        }
    }

    func copyBytes(
        from source: UnsafeRawPointer,
        count: Int,
        to address: GuestAddress
    ) throws {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else { return }
        let destinationIndex = try index(for: address, width: count)
        withAccessLock(offset: destinationIndex, count: count) {
            memcpy(bytes.baseAddress!.advanced(by: destinationIndex), source, count)
            markDirty(offset: destinationIndex, count: count)
        }
    }

    func copyDeviceBytes(
        from source: UnsafeRawPointer,
        count: Int,
        to address: GuestAddress
    ) throws {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else { return }
        let destinationIndex = try index(for: address, width: count)
        withAccessLock(offset: destinationIndex, count: count) {
            memcpy(bytes.baseAddress!.advanced(by: destinationIndex), source, count)
            avz_guest_memory_note_device_write(
                nativeMemory,
                destinationIndex,
                count
            )
        }
    }

    /// Reads a range after a virtio ownership transfer without permanently
    /// classifying its pages as host-shared. The guest must not mutate the
    /// range until the device completes the request.
    func copyOwnedDeviceBytes(
        from address: GuestAddress,
        count: Int,
        to destination: UnsafeMutableRawPointer
    ) throws {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else { return }
        let sourceIndex = try index(for: address, width: count)
        guard avz_guest_memory_dma_read_owned(
            nativeMemory,
            sourceIndex,
            destination,
            count
        ) != 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
    }

    func copyOwnedDeviceBytes(
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
        guard count > 0 else { return }
        try destination.withUnsafeMutableBytes { destinationBytes in
            try copyOwnedDeviceBytes(
                from: address,
                count: count,
                to: destinationBytes.baseAddress!.advanced(by: destinationOffset)
            )
        }
    }

    /// Publishes device output before its virtqueue completion without making
    /// later guest accesses pay the permanent shared-page locking cost.
    func copyOwnedDeviceBytes(
        from source: UnsafeRawPointer,
        count: Int,
        to address: GuestAddress
    ) throws {
        guard count >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        guard count > 0 else { return }
        let destinationIndex = try index(for: address, width: count)
        guard avz_guest_memory_dma_write_owned(
            nativeMemory,
            destinationIndex,
            source,
            count
        ) != 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
    }

    func copyOwnedDeviceBytes(
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
        guard count > 0 else { return }
        try source.withUnsafeBytes { sourceBytes in
            try copyOwnedDeviceBytes(
                from: sourceBytes.baseAddress!.advanced(by: sourceOffset),
                count: count,
                to: address
            )
        }
    }

    func ownedDeviceBuffer(
        at address: GuestAddress,
        count: Int
    ) throws -> UnsafeMutableRawBufferPointer {
        guard count > 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        let offset = try index(for: address, width: count)
        guard let baseAddress = avz_guest_memory_dma_owned_pointer(
            nativeMemory,
            offset,
            count
        ) else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        return UnsafeMutableRawBufferPointer(start: baseAddress, count: count)
    }

    func publishOwnedDeviceWrite(
        at address: GuestAddress,
        count: Int
    ) throws {
        guard count > 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        let offset = try index(for: address, width: count)
        avz_guest_memory_dma_write_owned_complete(nativeMemory, offset, count)
    }

    func noteDeviceWrite(at address: GuestAddress, count: Int) {
        guard count > 0,
              let offset = try? index(for: address, width: count) else {
            return
        }
        avz_guest_memory_note_device_write(nativeMemory, offset, count)
    }

    public func snapshotBytes() -> [UInt8] {
        withAccessLock { Array(bytes) }
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

    func withLockedDirectAccess<R>(_ body: () throws -> R) rethrows -> R {
        try withAccessLock(body)
    }

    func withLockedAccess<R>(
        to spans: [(address: GuestAddress, count: Int)],
        _ body: () throws -> R
    ) throws -> R {
        var nativeSpans: [AVZGuestMemorySpan] = []
        nativeSpans.reserveCapacity(spans.count)
        for span in spans {
            guard span.count >= 0 else {
                throw VMError.invalidMemoryAccess(
                    address: span.address,
                    width: span.count
                )
            }
            guard span.count > 0 else { continue }
            let offset = try index(for: span.address, width: span.count)
            nativeSpans.append(AVZGuestMemorySpan(
                offset: offset,
                byte_count: span.count
            ))
        }
        guard !nativeSpans.isEmpty else { return try body() }
        let locked = nativeSpans.withUnsafeBufferPointer {
            avz_guest_memory_lock_spans(
                nativeMemory,
                $0.baseAddress,
                $0.count
            )
        }
        guard locked != 0 else {
            throw VMError.deviceError("failed to lock guest memory spans")
        }
        defer {
            nativeSpans.withUnsafeBufferPointer {
                avz_guest_memory_unlock_spans(
                    nativeMemory,
                    $0.baseAddress,
                    $0.count
                )
            }
        }
        return try body()
    }

    // PhysicalMemory owns a fixed mmap allocation, so this pointer remains
    // stable for the lifetime of the memory object.
    var persistentMutableBytes: UnsafeMutableRawBufferPointer {
        bytes
    }

    func persistentMutableBytes(
        at address: GuestAddress,
        count: Int
    ) throws -> UnsafeMutableRawBufferPointer {
        let startIndex = try index(for: address, width: count)
        return UnsafeMutableRawBufferPointer(
            start: bytes.baseAddress!.advanced(by: startIndex),
            count: count
        )
    }

    var nativeMemoryHandle: OpaquePointer {
        nativeMemory
    }

    /// Discards host-access observations accumulated while loading a stopped
    /// VM. Runtime device accesses repopulate the shared-page set before they
    /// acquire the corresponding range lock.
    public func beginConcurrentExecution() {
        avz_guest_memory_clear_host_observations(nativeMemory)
    }

    /// Diagnostic mode that makes every guest RAM page participate in the
    /// page-stripe synchronization protocol. This is intentionally separate
    /// from the normal sparse-observation path because it is correctness-first
    /// and carries a substantial execution cost.
    public func requireFullySynchronizedConcurrentAccess() {
        avz_guest_memory_lock(nativeMemory)
        avz_guest_memory_unlock(nativeMemory)
    }

    func registerDeviceSharedRange(
        at address: GuestAddress,
        count: Int
    ) throws {
        guard count > 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
        let offset = try index(for: address, width: count)
        guard avz_guest_memory_register_host_range(
            nativeMemory,
            offset,
            count
        ) != 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: count)
        }
    }

    func isDeviceSharedRangeRegistered(
        at address: GuestAddress,
        count: Int
    ) -> Bool {
        guard count > 0,
              let offset = try? index(for: address, width: count) else {
            return false
        }
        return avz_guest_memory_host_range_is_registered(
            nativeMemory,
            offset,
            count
        ) != 0
    }

    var nativeExclusiveStatistics: AVZGuestExclusiveStatistics {
        avz_guest_memory_exclusive_statistics(nativeMemory)
    }

    func exclusiveRead(
        at address: GuestAddress,
        width: MMIOWidth
    ) throws -> (value: UInt64, generation: UInt64) {
        let offset = try index(for: address, width: width.rawValue)
        var value: UInt64 = 0
        var generation: UInt64 = 0
        guard avz_guest_memory_exclusive_read(
            nativeMemory, offset, UInt8(width.rawValue), &value, &generation
        ) != 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: width.rawValue)
        }
        return (value, generation)
    }

    func exclusiveReadPair(
        at address: GuestAddress,
        width: MMIOWidth
    ) throws -> (first: UInt64, second: UInt64, generation: UInt64) {
        let byteCount = width.rawValue * 2
        let offset = try index(for: address, width: byteCount)
        var first: UInt64 = 0
        var second: UInt64 = 0
        var generation: UInt64 = 0
        guard avz_guest_memory_exclusive_read_pair(
            nativeMemory, offset, UInt8(width.rawValue),
            &first, &second, &generation
        ) != 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: byteCount)
        }
        return (first, second, generation)
    }

    func exclusiveWrite(
        _ value: UInt64,
        at address: GuestAddress,
        width: MMIOWidth,
        expectedGeneration: UInt64
    ) throws -> Bool {
        let offset = try index(for: address, width: width.rawValue)
        let result = avz_guest_memory_exclusive_write(
            nativeMemory, offset, UInt8(width.rawValue),
            value, expectedGeneration
        )
        guard result >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: width.rawValue)
        }
        return result != 0
    }

    func exclusiveWritePair(
        first: UInt64,
        second: UInt64,
        at address: GuestAddress,
        width: MMIOWidth,
        expectedGeneration: UInt64
    ) throws -> Bool {
        let byteCount = width.rawValue * 2
        let offset = try index(for: address, width: byteCount)
        let result = avz_guest_memory_exclusive_write_pair(
            nativeMemory, offset, UInt8(width.rawValue),
            first, second, expectedGeneration
        )
        guard result >= 0 else {
            throw VMError.invalidMemoryAccess(address: address, width: byteCount)
        }
        return result != 0
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

    func invalidateSharedTranslationCaches() {
        avz_guest_memory_invalidate_translations(nativeMemory)
    }

    var sharedTranslationEpoch: UInt64 {
        avz_guest_memory_translation_epoch(nativeMemory)
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
        return withAccessLock(offset: startIndex, count: width) {
            var value: T = 0
            memcpy(&value, bytes.baseAddress!.advanced(by: startIndex), width)
            return T(littleEndian: value)
        }
    }

    private func writeInteger<T: FixedWidthInteger>(_ value: T, at address: GuestAddress) throws {
        let width = MemoryLayout<T>.size
        let startIndex = try index(for: address, width: width)
        withAccessLock(offset: startIndex, count: width) {
            var littleEndianValue = value.littleEndian
            memcpy(
                bytes.baseAddress!.advanced(by: startIndex),
                &littleEndianValue,
                width
            )
            markDirty(offset: startIndex, count: width)
        }
    }

    private func withAccessLock<R>(_ body: () throws -> R) rethrows -> R {
        avz_guest_memory_lock(nativeMemory)
        defer { avz_guest_memory_unlock(nativeMemory) }
        return try body()
    }

    private func withAccessLock<R>(
        offset: Int,
        count: Int,
        _ body: () throws -> R
    ) rethrows -> R {
        avz_guest_memory_lock_range(nativeMemory, offset, count)
        defer { avz_guest_memory_unlock_range(nativeMemory, offset, count) }
        return try body()
    }

    private func markDirty(offset: Int, count: Int) {
        avz_guest_memory_note_write(nativeMemory, offset, count)
    }

    private func index(for address: GuestAddress, width: Int) throws -> Int {
        guard width > 0, range.contains(address, width: UInt64(width)) else {
            throw VMError.invalidMemoryAccess(address: address, width: width)
        }
        return Int(address - base)
    }
}
