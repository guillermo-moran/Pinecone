import ARM64VizNative
import Foundation

/// A virtio-gpu 2D scanout implementation. Guest writes remain private to a
/// resource until RESOURCE_FLUSH publishes an immutable display snapshot.
final class VirtIOGPUDevice {
    static let controlQueue: UInt32 = 0
    static let cursorQueue: UInt32 = 1

    private enum Command: UInt32 {
        case getDisplayInfo = 0x0100
        case resourceCreate2D = 0x0101
        case resourceUnref = 0x0102
        case setScanout = 0x0103
        case resourceFlush = 0x0104
        case transferToHost2D = 0x0105
        case resourceAttachBacking = 0x0106
        case resourceDetachBacking = 0x0107
        case submit3D = 0x0207
        case updateCursor = 0x0300
        case moveCursor = 0x0301
    }

    private enum Response: UInt32 {
        case okNoData = 0x1100
        case okDisplayInfo = 0x1101
        case errorUnspecified = 0x1200
        case errorOutOfMemory = 0x1201
        case errorInvalidScanoutID = 0x1202
        case errorInvalidResourceID = 0x1203
        case errorInvalidParameter = 0x1205
    }

    private enum PixelFormat: UInt32 {
        case b8g8r8a8UNorm = 1
        case b8g8r8x8UNorm = 2
        case a8r8g8b8UNorm = 3
        case x8r8g8b8UNorm = 4
        case r8g8b8a8UNorm = 67
        case x8b8g8r8UNorm = 68
        case a8b8g8r8UNorm = 121
        case r8g8b8x8UNorm = 134

        var hasAlpha: Bool {
            switch self {
            case .b8g8r8a8UNorm, .a8r8g8b8UNorm, .r8g8b8a8UNorm, .a8b8g8r8UNorm:
                return true
            case .b8g8r8x8UNorm, .x8r8g8b8UNorm, .x8b8g8r8UNorm, .r8g8b8x8UNorm:
                return false
            }
        }
    }

    private struct Header {
        static let byteCount = 24
        static let fenceFlag: UInt32 = 1

        let flags: UInt32
        let fenceID: UInt64
        let contextID: UInt32
        let ringIndex: UInt8
    }

    private struct Rectangle: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var isEmpty: Bool { width == 0 || height == 0 }

        func isWithin(width outerWidth: Int, height outerHeight: Int) -> Bool {
            x >= 0 && y >= 0 && width >= 0 && height >= 0 &&
                x <= outerWidth && y <= outerHeight &&
                width <= outerWidth - x && height <= outerHeight - y
        }

        func intersection(_ other: Rectangle) -> Rectangle? {
            let left = max(x, other.x)
            let top = max(y, other.y)
            let right = min(x + width, other.x + other.width)
            let bottom = min(y + height, other.y + other.height)
            guard right > left, bottom > top else { return nil }
            return Rectangle(x: left, y: top, width: right - left, height: bottom - top)
        }

        func union(_ other: Rectangle) -> Rectangle {
            let left = min(x, other.x)
            let top = min(y, other.y)
            let right = max(x + width, other.x + other.width)
            let bottom = max(y + height, other.y + other.height)
            return Rectangle(
                x: left,
                y: top,
                width: right - left,
                height: bottom - top
            )
        }

        var framebufferDamage: VirtualFramebufferDamage {
            VirtualFramebufferDamage(x: x, y: y, width: width, height: height)
        }

        func subtracting(_ other: Rectangle) -> [Rectangle] {
            guard let overlap = intersection(other) else { return [self] }
            var remaining: [Rectangle] = []
            if overlap.y > y {
                remaining.append(Rectangle(
                    x: x,
                    y: y,
                    width: width,
                    height: overlap.y - y
                ))
            }
            let bottom = overlap.y + overlap.height
            if bottom < y + height {
                remaining.append(Rectangle(
                    x: x,
                    y: bottom,
                    width: width,
                    height: y + height - bottom
                ))
            }
            if overlap.x > x {
                remaining.append(Rectangle(
                    x: x,
                    y: overlap.y,
                    width: overlap.x - x,
                    height: overlap.height
                ))
            }
            let right = overlap.x + overlap.width
            if right < x + width {
                remaining.append(Rectangle(
                    x: right,
                    y: overlap.y,
                    width: x + width - right,
                    height: overlap.height
                ))
            }
            return remaining
        }
    }

    private struct BackingEntry {
        let address: GuestAddress
        let length: Int
    }

    private struct LogicalByteRange {
        let offset: Int
        let count: Int

        var end: Int { offset + count }
    }

    private struct KnownGuestWrite {
        let rectangle: Rectangle
        let packedA8: Bool

        var byteCount: Int {
            rectangle.width * rectangle.height * (packedA8 ? 1 : 4)
        }

        func subtracting(_ other: Rectangle) -> [KnownGuestWrite] {
            rectangle.subtracting(other).map {
                KnownGuestWrite(rectangle: $0, packedA8: packedA8)
            }
        }
    }

    private final class Resource {
        let format: PixelFormat
        let width: Int
        let height: Int
        var backing: [BackingEntry] = []
        let pixels: NativeFramebufferStorage
        var hasCompleteHostContents = false
        var pendingTransfers: [Rectangle] = []
        var pendingGuestWrites: [KnownGuestWrite] = []
        var lastBackingDirtyEpoch: UInt64?

        init(format: PixelFormat, width: Int, height: Int) {
            self.format = format
            self.width = width
            self.height = height
            self.pixels = NativeFramebufferStorage(byteCount: width * height * 4)
        }

        var stride: Int { width * 4 }
        var byteCount: Int { pixels.byteCount }
    }

    private final class NativeFramebufferStorage {
        let byteCount: Int
        let allocationByteCount: Int
        private let handle: OpaquePointer
        private let baseAddress: UnsafeMutableRawPointer

        init(byteCount: Int) {
            precondition(byteCount > 0)
            guard let handle = avz_framebuffer_surface_create(byteCount),
                  let bytes = avz_framebuffer_surface_bytes(handle) else {
                preconditionFailure("failed to allocate native framebuffer storage")
            }
            self.byteCount = Int(avz_framebuffer_surface_byte_count(handle))
            self.allocationByteCount = Int(
                avz_framebuffer_surface_allocation_size(handle)
            )
            self.handle = handle
            self.baseAddress = UnsafeMutableRawPointer(bytes)
        }

        deinit {
            avz_framebuffer_surface_destroy(handle)
        }

        func clear() {
            avz_framebuffer_surface_clear(handle)
        }

        func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            try body(UnsafeRawBufferPointer(
                start: baseAddress,
                count: allocationByteCount
            ))
        }

        func withUnsafeMutableBytes<R>(
            _ body: (UnsafeMutableRawBufferPointer) throws -> R
        ) rethrows -> R {
            try body(UnsafeMutableRawBufferPointer(
                start: baseAddress,
                count: allocationByteCount
            ))
        }

        func snapshot() -> [UInt8] {
            withUnsafeBytes { bytes in
                Array(bytes.prefix(byteCount))
            }
        }

        func copyContents(from source: NativeFramebufferStorage) {
            precondition(source.byteCount == byteCount)
            source.withUnsafeBytes { sourceBytes in
                withUnsafeMutableBytes { destinationBytes in
                    destinationBytes.baseAddress?.copyMemory(
                        from: sourceBytes.baseAddress!,
                        byteCount: byteCount
                    )
                }
            }
        }

        var unsafeBaseAddress: UnsafeRawPointer {
            UnsafeRawPointer(baseAddress)
        }

        func acceleratorSurface(
            resourceID: UInt32,
            width: Int,
            height: Int,
            pixelFormat: PineconeGraphicsPixelFormat
        ) -> PineconeGraphicsSurface {
            PineconeGraphicsSurface(
                resourceID: resourceID,
                width: width,
                height: height,
                stride: width * 4,
                pixelFormat: pixelFormat,
                bytes: UnsafeMutableRawBufferPointer(
                    start: baseAddress,
                    count: byteCount
                ),
                allocationByteCount: allocationByteCount
            )
        }
    }

    private struct Scanout: Equatable {
        let resourceID: UInt32
        let rectangle: Rectangle
    }

    private struct Cursor {
        let resourceID: UInt32
        let x: Int
        let y: Int
        let hotX: Int
        let hotY: Int
    }

    private struct DamageRecord {
        let generation: UInt64
        let rectangles: [Rectangle]
    }

    private final class PublishedFrameSlot {
        let pixels: NativeFramebufferStorage
        var leaseCount = 0

        init(byteCount: Int) {
            pixels = NativeFramebufferStorage(byteCount: byteCount)
        }
    }

    let width: Int
    let height: Int

    private let lock = NSLock()
    private var resources: [UInt32: Resource] = [:]
    private var scanout: Scanout?
    private var committedScanout: Scanout?
    private var cursor: Cursor?
    private var frameSlots: [PublishedFrameSlot]
    private var committedFrame: PublishedFrameSlot
    private var committedPixels: NativeFramebufferStorage {
        committedFrame.pixels
    }
    private var committedGeneration: UInt64 = 0
    private var commitTimestampNanoseconds: UInt64 = 0
    private var damageHistory: [DamageRecord] = []
    private var hasCommittedFrame = false
    private var transferCommandCount: UInt64 = 0
    private var flushCommandCount: UInt64 = 0
    private var transferredByteCount: UInt64 = 0
    private var committedByteCount: UInt64 = 0
    private var directFrameReadCount: UInt64 = 0
    private var directFrameReadByteCount: UInt64 = 0
    private var snapshotCopyCount: UInt64 = 0
    private var frameCopyOnWriteCount: UInt64 = 0
    private var frameCopyOnWriteByteCount: UInt64 = 0
    private var commandLockWaitNanoseconds: [UInt64] = []
    private var commandLockHoldNanoseconds: [UInt64] = []
    private var dirtyTileScanCount: UInt64 = 0
    private var unchangedFlushCount: UInt64 = 0
    private var dirtyTileChangedByteCount: UInt64 = 0
    private var dirtyPageTransferCount: UInt64 = 0
    private var backingCopiedByteCount: UInt64 = 0
    private var cleanBackingSkippedByteCount: UInt64 = 0
    private var dirtyBackingRangeCount: UInt64 = 0
    private var exactGuestWriteCount: UInt64 = 0
    private var exactGuestWriteByteCount: UInt64 = 0
    private var paravirtualCommandCount: UInt64 = 0
    private var paravirtualBatchCount: UInt64 = 0
    private var paravirtualAcceleratedCount: UInt64 = 0
    private var paravirtualPixelCount: UInt64 = 0
    private var acceleratedDirtyRangeCount: UInt64 = 0
    private var paravirtualPrepareFailureCount: UInt64 = 0
    private var paravirtualSyncFailureCount: UInt64 = 0
    private var paravirtualNativeFailureCount: UInt64 = 0
    private var paravirtualFinishFailureCount: UInt64 = 0
    private var lastParavirtualFailure = "none"
    private var lastTransferSummary = "none"
    private var lastFlushSummary = "none"
    private weak var graphicsAccelerator: PineconeGraphicsAccelerator?

    private static let maximumDamageHistory = 120
    private static let maximumPublishedDamageRectangles = 128
    private static let dirtyTileWidth = 32
    private static let dirtyTileHeight = 32

    var generation: UInt64 {
        lock.lock()
        let value = committedGeneration
        lock.unlock()
        return value
    }

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        let frameSlots = [PublishedFrameSlot(byteCount: width * height * 4)]
        self.frameSlots = frameSlots
        self.committedFrame = frameSlots[0]
    }

    func setGraphicsAccelerator(_ accelerator: PineconeGraphicsAccelerator?) {
        lock.lock()
        graphicsAccelerator?.reset()
        graphicsAccelerator = accelerator
        lock.unlock()
    }

    func reset() {
        lock.lock()
        resources.removeAll(keepingCapacity: true)
        graphicsAccelerator?.reset()
        scanout = nil
        committedScanout = nil
        cursor = nil
        prepareCommittedFrameForWrite()
        committedPixels.clear()
        committedGeneration &+= 1
        commitTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        damageHistory.removeAll(keepingCapacity: true)
        hasCommittedFrame = false
        transferCommandCount = 0
        flushCommandCount = 0
        transferredByteCount = 0
        committedByteCount = 0
        directFrameReadCount = 0
        directFrameReadByteCount = 0
        snapshotCopyCount = 0
        frameCopyOnWriteCount = 0
        frameCopyOnWriteByteCount = 0
        commandLockWaitNanoseconds.removeAll(keepingCapacity: true)
        commandLockHoldNanoseconds.removeAll(keepingCapacity: true)
        dirtyTileScanCount = 0
        unchangedFlushCount = 0
        dirtyTileChangedByteCount = 0
        dirtyPageTransferCount = 0
        backingCopiedByteCount = 0
        cleanBackingSkippedByteCount = 0
        dirtyBackingRangeCount = 0
        exactGuestWriteCount = 0
        exactGuestWriteByteCount = 0
        paravirtualCommandCount = 0
        paravirtualBatchCount = 0
        paravirtualAcceleratedCount = 0
        paravirtualPixelCount = 0
        acceleratedDirtyRangeCount = 0
        paravirtualPrepareFailureCount = 0
        paravirtualSyncFailureCount = 0
        paravirtualNativeFailureCount = 0
        paravirtualFinishFailureCount = 0
        lastParavirtualFailure = "none"
        lastTransferSummary = "none"
        lastFlushSummary = "none"
        lock.unlock()
    }

    func diagnosticsSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let lockWaitP95 = String(
            format: "%.2f",
            Self.percentileMilliseconds(commandLockWaitNanoseconds)
        )
        let lockHoldP95 = String(
            format: "%.2f",
            Self.percentileMilliseconds(commandLockHoldNanoseconds)
        )
        return "gpu=t\(transferCommandCount)/f\(flushCommandCount)" +
            " bytes=\(transferredByteCount)/\(committedByteCount)" +
            " direct=\(directFrameReadCount)/\(directFrameReadByteCount)" +
            " snap=\(snapshotCopyCount)" +
            " cow=\(frameCopyOnWriteCount)/\(frameCopyOnWriteByteCount)" +
            " glock=\(lockWaitP95)/\(lockHoldP95)ms" +
            " dirty=\(dirtyTileScanCount)/\(unchangedFlushCount)" +
            ":\(dirtyTileChangedByteCount)" +
            " pages=\(dirtyPageTransferCount)/\(dirtyBackingRangeCount)" +
            ":\(backingCopiedByteCount)/\(cleanBackingSkippedByteCount)" +
            " exact=\(exactGuestWriteCount)/\(exactGuestWriteByteCount)" +
            " pv2d=\(paravirtualCommandCount)/\(paravirtualAcceleratedCount)" +
            ":\(paravirtualPixelCount)/b\(paravirtualBatchCount)" +
            "/m\(acceleratedDirtyRangeCount)" +
            " err=\(paravirtualPrepareFailureCount)/" +
            "\(paravirtualSyncFailureCount)/" +
            "\(paravirtualNativeFailureCount)/" +
            "\(paravirtualFinishFailureCount):\(lastParavirtualFailure)" +
            " tr=\(lastTransferSummary) fl=\(lastFlushSummary)"
    }

    func metadata(afterGeneration previousGeneration: UInt64?) -> VirtualFramebufferFrameMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return frameMetadata(afterGeneration: previousGeneration)
    }

    func withFrameBytes(
        afterGeneration previousGeneration: UInt64?,
        _ body: (VirtualFramebufferFrameMetadata, UnsafeRawBufferPointer) -> Void
    ) -> VirtualFramebufferFrameMetadata? {
        guard let lease = frameLease(afterGeneration: previousGeneration) else {
            return nil
        }
        lease.withUnsafeBytes { body(lease.metadata, $0) }
        return lease.metadata
    }

    func frameLease(
        afterGeneration previousGeneration: UInt64?
    ) -> VirtualFramebufferFrameLease? {
        lock.lock()
        guard let metadata = frameMetadata(afterGeneration: previousGeneration) else {
            lock.unlock()
            return nil
        }

        directFrameReadCount &+= 1
        directFrameReadByteCount &+= UInt64(metadata.damagedByteCount)
        if cursor == nil {
            let slot = committedFrame
            slot.leaseCount += 1
            let lease = VirtualFramebufferFrameLease(
                metadata: metadata,
                storageOwner: slot.pixels,
                baseAddress: slot.pixels.unsafeBaseAddress,
                byteCount: slot.pixels.allocationByteCount,
                releaseHandler: { [weak self, weak slot] in
                    guard let self, let slot else { return }
                    self.lock.lock()
                    precondition(slot.leaseCount > 0)
                    slot.leaseCount -= 1
                    self.lock.unlock()
                }
            )
            lock.unlock()
            return lease
        }

        let composited = compositedPixels()
        let storage = NativeFramebufferStorage(byteCount: width * height * 4)
        storage.withUnsafeMutableBytes { destination in
            composited.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(
                    from: source.baseAddress!,
                    byteCount: composited.count
                )
            }
        }
        snapshotCopyCount &+= 1
        let leasedMetadata = VirtualFramebufferFrameMetadata(
            width: metadata.width,
            height: metadata.height,
            stride: metadata.stride,
            bytesPerPixel: metadata.bytesPerPixel,
            generation: metadata.generation,
            commitTimestampNanoseconds: metadata.commitTimestampNanoseconds,
            damage: metadata.damage,
            hasStableStorage: true
        )
        let lease = VirtualFramebufferFrameLease(
            metadata: leasedMetadata,
            storageOwner: storage,
            baseAddress: storage.unsafeBaseAddress,
            byteCount: storage.allocationByteCount
        )
        lock.unlock()
        return lease
    }

    func snapshot(afterGeneration previousGeneration: UInt64?) -> VirtualFramebufferSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let metadata = frameMetadata(afterGeneration: previousGeneration) else {
            return nil
        }
        snapshotCopyCount &+= 1
        return VirtualFramebufferSnapshot(
            width: width,
            height: height,
            stride: width * 4,
            bytesPerPixel: 4,
            generation: committedGeneration,
            commitTimestampNanoseconds: metadata.commitTimestampNanoseconds,
            damage: metadata.damage,
            pixels: compositedPixels()
        )
    }

    private func frameMetadata(
        afterGeneration previousGeneration: UInt64?
    ) -> VirtualFramebufferFrameMetadata? {
        guard hasCommittedFrame, previousGeneration != committedGeneration else {
            return nil
        }

        let fullFrame = Rectangle(x: 0, y: 0, width: width, height: height)
        let damageRectangles: [Rectangle]
        if let previousGeneration {
            let records = damageHistory.filter { $0.generation > previousGeneration }
            let historyStartsAfterRequestedGeneration = damageHistory.first.map {
                $0.generation > previousGeneration &+ 1
            } ?? true
            if records.isEmpty || historyStartsAfterRequestedGeneration {
                damageRectangles = [fullFrame]
            } else {
                damageRectangles = Self.compactDamageRectangles(
                    records.flatMap(\.rectangles)
                )
            }
        } else {
            damageRectangles = [fullFrame]
        }

        return VirtualFramebufferFrameMetadata(
            width: width,
            height: height,
            stride: width * 4,
            bytesPerPixel: 4,
            generation: committedGeneration,
            commitTimestampNanoseconds: commitTimestampNanoseconds,
            damage: damageRectangles.map(\.framebufferDamage),
            hasStableStorage: cursor == nil
        )
    }

    private func commit(damage: Rectangle) {
        commit(damage: [damage])
    }

    private func commit(damage rectangles: [Rectangle]) {
        let rectangles = rectangles.filter { !$0.isEmpty }
        guard !rectangles.isEmpty else { return }
        committedGeneration &+= 1
        commitTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        damageHistory.append(DamageRecord(
            generation: committedGeneration,
            rectangles: rectangles
        ))
        if damageHistory.count > Self.maximumDamageHistory {
            damageHistory.removeFirst(damageHistory.count - Self.maximumDamageHistory)
        }
        committedByteCount &+= UInt64(rectangles.reduce(0) {
            $0 + $1.width * $1.height * 4
        })
        hasCommittedFrame = true
    }

    private func prepareCommittedFrameForWrite() {
        guard committedFrame.leaseCount != 0 else { return }
        let nextFrame: PublishedFrameSlot
        if let available = frameSlots.first(where: {
            $0 !== committedFrame && $0.leaseCount == 0
        }) {
            nextFrame = available
        } else {
            nextFrame = PublishedFrameSlot(byteCount: width * height * 4)
            frameSlots.append(nextFrame)
        }
        nextFrame.pixels.copyContents(from: committedFrame.pixels)
        frameCopyOnWriteCount &+= 1
        frameCopyOnWriteByteCount &+= UInt64(committedFrame.pixels.byteCount)
        committedFrame = nextFrame
    }

    private static func compactDamageRectangles(
        _ rectangles: [Rectangle]
    ) -> [Rectangle] {
        guard !rectangles.isEmpty else { return [] }
        var compacted: [Rectangle] = []
        compacted.reserveCapacity(min(rectangles.count, maximumPublishedDamageRectangles))

        for rectangle in rectangles where !rectangle.isEmpty {
            var candidate = rectangle
            var index = 0
            while index < compacted.count {
                let existing = compacted[index]
                let horizontallyAdjacent = existing.y == candidate.y &&
                    existing.height == candidate.height &&
                    existing.x + existing.width >= candidate.x &&
                    candidate.x + candidate.width >= existing.x
                let verticallyAdjacent = existing.x == candidate.x &&
                    existing.width == candidate.width &&
                    existing.y + existing.height >= candidate.y &&
                    candidate.y + candidate.height >= existing.y
                if existing.intersection(candidate) != nil ||
                    horizontallyAdjacent || verticallyAdjacent {
                    candidate = existing.union(candidate)
                    compacted.remove(at: index)
                    index = 0
                } else {
                    index += 1
                }
            }
            compacted.append(candidate)
            if compacted.count > maximumPublishedDamageRectangles {
                return [rectangles.dropFirst().reduce(rectangles[0]) {
                    $0.union($1)
                }]
            }
        }
        return compacted
    }

    private static func appendTiming(_ value: UInt64, to samples: inout [UInt64]) {
        let limit = 128
        if samples.count == limit {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private static func percentileMilliseconds(_ samples: [UInt64]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        return Double(sorted[index]) / 1_000_000
    }

    func backingSnapshot(memory: PhysicalMemory) -> VirtualFramebufferSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasCommittedFrame,
              let scanout,
              let resource = resources[scanout.resourceID],
              !resource.backing.isEmpty else {
            return nil
        }

        let backingStorage = NativeFramebufferStorage(byteCount: resource.byteCount)
        do {
            try copyBackingBytes(
                resource.backing,
                logicalOffset: 0,
                count: resource.byteCount,
                memory: memory,
                destination: backingStorage,
                destinationOffset: 0
            )
        } catch {
            return nil
        }
        normalizePixels(
            in: backingStorage,
            rectangle: Rectangle(
                x: 0,
                y: 0,
                width: resource.width,
                height: resource.height
            ),
            stride: resource.stride,
            format: resource.format
        )
        let backingPixels = backingStorage.snapshot()
        var visiblePixels = Array(repeating: UInt8(0), count: width * height * 4)
        for row in 0..<scanout.rectangle.height {
            let sourceOffset = (scanout.rectangle.y + row) * resource.stride +
                scanout.rectangle.x * 4
            let destinationOffset = row * width * 4
            let byteCount = scanout.rectangle.width * 4
            visiblePixels.replaceSubrange(
                destinationOffset..<(destinationOffset + byteCount),
                with: backingPixels[sourceOffset..<(sourceOffset + byteCount)]
            )
        }

        return VirtualFramebufferSnapshot(
            width: width,
            height: height,
            stride: width * 4,
            bytesPerPixel: 4,
            generation: committedGeneration,
            commitTimestampNanoseconds: commitTimestampNanoseconds,
            pixels: visiblePixels
        )
    }

    func process(request: [UInt8], memory: PhysicalMemory) -> [UInt8] {
        guard request.count >= Header.byteCount else {
            return responseHeader(.errorInvalidParameter, requestHeader: nil)
        }
        let header = Header(
            flags: Self.readLE32(request, at: 4),
            fenceID: Self.readLE64(request, at: 8),
            contextID: Self.readLE32(request, at: 16),
            ringIndex: request[20]
        )
        guard let command = Command(rawValue: Self.readLE32(request, at: 0)) else {
            return responseHeader(.errorUnspecified, requestHeader: header)
        }

        let lockWaitStarted = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let lockAcquired = DispatchTime.now().uptimeNanoseconds
        Self.appendTiming(lockAcquired &- lockWaitStarted, to: &commandLockWaitNanoseconds)
        defer {
            let lockReleased = DispatchTime.now().uptimeNanoseconds
            Self.appendTiming(lockReleased &- lockAcquired, to: &commandLockHoldNanoseconds)
            lock.unlock()
        }
        do {
            switch command {
            case .getDisplayInfo:
                return displayInfoResponse(requestHeader: header)
            case .resourceCreate2D:
                return try createResource(request, header: header)
            case .resourceUnref:
                return try unrefResource(request, header: header)
            case .setScanout:
                return try setScanout(request, header: header)
            case .resourceFlush:
                return try flushResource(request, header: header)
            case .transferToHost2D:
                return try transferToHost(request, header: header, memory: memory)
            case .resourceAttachBacking:
                return try attachBacking(request, header: header, memory: memory)
            case .resourceDetachBacking:
                return try detachBacking(request, header: header)
            case .submit3D:
                return try submitParavirtual2D(request, header: header, memory: memory)
            case .updateCursor:
                return try updateCursor(request, header: header)
            case .moveCursor:
                return try moveCursor(request, header: header)
            }
        } catch let error as GPUError {
            return responseHeader(error.response, requestHeader: header)
        } catch {
            return responseHeader(.errorUnspecified, requestHeader: header)
        }
    }

    /// Starts a paravirtual graphics command without holding the calling vCPU
    /// until the host GPU completes. The completion response is delivered only
    /// after Metal writes are CPU-visible, so the virtqueue used-ring entry is
    /// also the guest-visible fence.
    func processDeferred(
        request: [UInt8],
        memory: PhysicalMemory,
        completion: @escaping @Sendable ([UInt8]) -> Void
    ) -> Bool {
        guard request.count >= Header.byteCount,
              Command(rawValue: Self.readLE32(request, at: 0)) == .submit3D else {
            return false
        }
        let header = Header(
            flags: Self.readLE32(request, at: 4),
            fenceID: Self.readLE64(request, at: 8),
            contextID: Self.readLE32(request, at: 16),
            ringIndex: request[20]
        )

        let initialLockWaitStarted = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let initialLockAcquired = DispatchTime.now().uptimeNanoseconds
        Self.appendTiming(
            initialLockAcquired &- initialLockWaitStarted,
            to: &commandLockWaitNanoseconds
        )
        do {
            let prepared: [PreparedParavirtual2D]
            do {
                prepared = try prepareParavirtual2DRequest(request, memory: memory)
            } catch {
                recordParavirtualFailure(.prepare, prepared: nil)
                throw error
            }
            do {
                try synchronizeParavirtual2DInputs(prepared, memory: memory)
            } catch {
                recordParavirtualFailure(.synchronize, prepared: prepared)
                throw error
            }
            let workItems = paravirtual2DWorkItems(prepared)
            guard let graphicsAccelerator,
                  graphicsAccelerator.executeBatchAsync(
                    workItems,
                    completion: { [weak self] succeeded in
                        guard let self else {
                            completion([])
                            return
                        }
                        let completionLockWaitStarted = DispatchTime.now().uptimeNanoseconds
                        self.lock.lock()
                        let completionLockAcquired = DispatchTime.now().uptimeNanoseconds
                        Self.appendTiming(
                            completionLockAcquired &- completionLockWaitStarted,
                            to: &self.commandLockWaitNanoseconds
                        )
                        let response: [UInt8]
                        if succeeded {
                            do {
                                for item in prepared {
                                    do {
                                        try self.finishParavirtual2D(
                                            item,
                                            accelerated: true,
                                            memory: memory
                                        )
                                    } catch {
                                        self.recordParavirtualFailure(
                                            .finish,
                                            prepared: [item]
                                        )
                                        throw error
                                    }
                                }
                                if prepared.count > 1 {
                                    self.paravirtualBatchCount &+= 1
                                }
                                response = self.responseHeader(
                                    .okNoData,
                                    requestHeader: header
                                )
                            } catch {
                                response = self.responseHeader(
                                    .errorUnspecified,
                                    requestHeader: header
                                )
                            }
                        } else {
                            response = self.responseHeader(
                                .errorUnspecified,
                                requestHeader: header
                            )
                        }
                        Self.appendTiming(
                            DispatchTime.now().uptimeNanoseconds &- completionLockAcquired,
                            to: &self.commandLockHoldNanoseconds
                        )
                        self.lock.unlock()
                        completion(response)
                    }
                  ) else {
                Self.appendTiming(
                    DispatchTime.now().uptimeNanoseconds &- initialLockAcquired,
                    to: &commandLockHoldNanoseconds
                )
                lock.unlock()
                return false
            }
            Self.appendTiming(
                DispatchTime.now().uptimeNanoseconds &- initialLockAcquired,
                to: &commandLockHoldNanoseconds
            )
            lock.unlock()
            return true
        } catch {
            Self.appendTiming(
                DispatchTime.now().uptimeNanoseconds &- initialLockAcquired,
                to: &commandLockHoldNanoseconds
            )
            lock.unlock()
            return false
        }
    }

    private enum GPUError: Error {
        case response(Response)

        var response: Response {
            switch self {
            case let .response(response): return response
            }
        }
    }

    private func displayInfoResponse(requestHeader: Header) -> [UInt8] {
        var response = responseHeader(.okDisplayInfo, requestHeader: requestHeader)
        response += Array(repeating: 0, count: 16 * 24)
        Self.writeLE32(0, into: &response, at: Header.byteCount)
        Self.writeLE32(0, into: &response, at: Header.byteCount + 4)
        Self.writeLE32(UInt32(width), into: &response, at: Header.byteCount + 8)
        Self.writeLE32(UInt32(height), into: &response, at: Header.byteCount + 12)
        Self.writeLE32(1, into: &response, at: Header.byteCount + 16)
        return response
    }

    private func createResource(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 40)
        let resourceID = Self.readLE32(request, at: 24)
        guard resourceID != 0, resources[resourceID] == nil else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        guard let format = PixelFormat(rawValue: Self.readLE32(request, at: 28)) else {
            throw GPUError.response(.errorInvalidParameter)
        }
        let resourceWidth = Int(Self.readLE32(request, at: 32))
        let resourceHeight = Int(Self.readLE32(request, at: 36))
        guard resourceWidth > 0, resourceHeight > 0,
              resourceWidth <= 16_384, resourceHeight <= 16_384,
              resourceWidth <= Int.max / resourceHeight / 4 else {
            throw GPUError.response(.errorInvalidParameter)
        }
        let byteCount = resourceWidth * resourceHeight * 4
        let allocatedBytes = resources.values.reduce(0) { $0 + $1.byteCount }
        guard byteCount <= 256 * 1024 * 1024 - allocatedBytes else {
            throw GPUError.response(.errorOutOfMemory)
        }
        resources[resourceID] = Resource(
            format: format,
            width: resourceWidth,
            height: resourceHeight
        )
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func unrefResource(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 32)
        let resourceID = Self.readLE32(request, at: 24)
        let oldCursorDamage = cursor?.resourceID == resourceID
            ? cursorRectangle(cursor)
            : nil
        guard resources.removeValue(forKey: resourceID) != nil else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        graphicsAccelerator?.discardSurface(resourceID: resourceID)
        if scanout?.resourceID == resourceID {
            scanout = nil
            committedScanout = nil
            prepareCommittedFrameForWrite()
            committedPixels.clear()
            commit(damage: Rectangle(x: 0, y: 0, width: width, height: height))
        }
        if cursor?.resourceID == resourceID {
            cursor = nil
            displayStateChanged(damage: oldCursorDamage)
        }
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func attachBacking(_ request: [UInt8], header: Header, memory: PhysicalMemory) throws -> [UInt8] {
        try require(request, count: 32)
        let resourceID = Self.readLE32(request, at: 24)
        let entryCount = Int(Self.readLE32(request, at: 28))
        guard entryCount > 0, entryCount <= 16_384,
              entryCount <= (request.count - 32) / 16,
              let resource = resources[resourceID] else {
            throw GPUError.response(resources[resourceID] == nil ? .errorInvalidResourceID : .errorInvalidParameter)
        }
        var entries: [BackingEntry] = []
        entries.reserveCapacity(entryCount)
        var totalLength = 0
        for index in 0..<entryCount {
            let offset = 32 + index * 16
            let address = Self.readLE64(request, at: offset)
            let length = Int(Self.readLE32(request, at: offset + 8))
            guard length > 0, memory.range.contains(address, width: UInt64(length)),
                  totalLength <= Int.max - length else {
                throw GPUError.response(.errorInvalidParameter)
            }
            totalLength += length
            if let previous = entries.last,
               previous.address + UInt64(previous.length) == address,
               previous.length <= Int.max - length {
                entries[entries.count - 1] = BackingEntry(
                    address: previous.address,
                    length: previous.length + length
                )
            } else {
                entries.append(BackingEntry(address: address, length: length))
            }
        }
        guard totalLength >= resource.byteCount else {
            throw GPUError.response(.errorInvalidParameter)
        }
        resource.backing = entries
        resource.hasCompleteHostContents = false
        resource.pendingTransfers.removeAll(keepingCapacity: true)
        resource.pendingGuestWrites.removeAll(keepingCapacity: true)
        resource.lastBackingDirtyEpoch = nil
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func detachBacking(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 32)
        let resourceID = Self.readLE32(request, at: 24)
        guard let resource = resources[resourceID] else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        resource.backing.removeAll(keepingCapacity: true)
        resource.hasCompleteHostContents = false
        resource.pendingTransfers.removeAll(keepingCapacity: true)
        resource.pendingGuestWrites.removeAll(keepingCapacity: true)
        resource.lastBackingDirtyEpoch = nil
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func setScanout(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 48)
        let rectangle = try Self.rectangle(request, at: 24)
        let scanoutID = Self.readLE32(request, at: 40)
        let resourceID = Self.readLE32(request, at: 44)
        guard scanoutID == 0 else {
            throw GPUError.response(.errorInvalidScanoutID)
        }
        if resourceID == 0 {
            scanout = nil
            committedScanout = nil
            prepareCommittedFrameForWrite()
            committedPixels.clear()
            commit(damage: Rectangle(x: 0, y: 0, width: width, height: height))
            return responseHeader(.okNoData, requestHeader: header)
        }
        guard let resource = resources[resourceID] else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        guard !rectangle.isEmpty,
              rectangle.isWithin(width: resource.width, height: resource.height),
              rectangle.width <= width, rectangle.height <= height else {
            throw GPUError.response(.errorInvalidParameter)
        }
        scanout = Scanout(resourceID: resourceID, rectangle: rectangle)
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func transferToHost(_ request: [UInt8], header: Header, memory: PhysicalMemory) throws -> [UInt8] {
        try require(request, count: 56)
        let rectangle = try Self.rectangle(request, at: 24)
        let sourceOffset = Self.readLE64(request, at: 40)
        let resourceID = Self.readLE32(request, at: 48)
        guard let resource = resources[resourceID] else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        guard !resource.backing.isEmpty, !rectangle.isEmpty,
              rectangle.isWithin(width: resource.width, height: resource.height),
              sourceOffset <= UInt64(Int.max) else {
            throw GPUError.response(.errorInvalidParameter)
        }
        let rowBytes = rectangle.width * 4
        let baseSourceOffset = Int(sourceOffset)
        guard baseSourceOffset <= resource.byteCount else {
            throw GPUError.response(.errorInvalidParameter)
        }
        let isCompleteTransfer = rectangle.x == 0 && rectangle.y == 0 &&
            rectangle.width == resource.width && rectangle.height == resource.height &&
            sourceOffset == 0
        let nominalByteCount = rowBytes * rectangle.height
        var copiedByteCount = nominalByteCount
        var transferredRectangles = [rectangle]
        var dirtyRangeCount = 0

        if isCompleteTransfer {
            let throughEpoch = memory.advanceDirtyEpoch()
            if resource.hasCompleteHostContents,
               let afterEpoch = resource.lastBackingDirtyEpoch {
                let knownWrites = resource.pendingGuestWrites
                for write in knownWrites {
                    try copyBackingRectangle(
                        resource,
                        rectangle: write.rectangle,
                        packedA8: write.packedA8,
                        memory: memory
                    )
                }
                let dirtyRanges = dirtyBackingRanges(
                    resource.backing,
                    byteCount: resource.byteCount,
                    memory: memory,
                    afterEpoch: afterEpoch,
                    throughEpoch: throughEpoch
                )
                let knownByteCount = knownWrites.reduce(0) { $0 + $1.byteCount }
                copiedByteCount = knownByteCount + dirtyRanges.reduce(0) { $0 + $1.count }
                dirtyRangeCount = dirtyRanges.count
                transferredRectangles = Self.compactDamageRectangles(
                    knownWrites.map(\.rectangle) + dirtyRanges.flatMap {
                        Self.rectangles(
                            for: $0,
                            resourceWidth: resource.width,
                            resourceHeight: resource.height
                        )
                    }
                )
                for range in dirtyRanges {
                    try copyBackingBytes(
                        resource.backing,
                        logicalOffset: range.offset,
                        count: range.count,
                        memory: memory,
                        destination: resource.pixels,
                        destinationOffset: range.offset
                    )
                    normalizePixelBytes(
                        in: resource.pixels,
                        offset: range.offset,
                        count: range.count,
                        format: resource.format
                    )
                }
                dirtyPageTransferCount &+= 1
                exactGuestWriteCount &+= UInt64(knownWrites.count)
                exactGuestWriteByteCount &+= UInt64(knownByteCount)
                cleanBackingSkippedByteCount &+= UInt64(
                    max(0, nominalByteCount - copiedByteCount)
                )
            } else {
                try copyBackingBytes(
                    resource.backing,
                    logicalOffset: 0,
                    count: nominalByteCount,
                    memory: memory,
                    destination: resource.pixels,
                    destinationOffset: 0
                )
                normalizePixels(
                    in: resource.pixels,
                    rectangle: rectangle,
                    stride: resource.stride,
                    format: resource.format
                )
            }
            resource.hasCompleteHostContents = true
            resource.pendingGuestWrites.removeAll(keepingCapacity: true)
            resource.lastBackingDirtyEpoch = throughEpoch
        } else if rectangle.x == 0, rectangle.width == resource.width {
            let byteCount = rowBytes * rectangle.height
            guard byteCount <= resource.byteCount - baseSourceOffset else {
                throw GPUError.response(.errorInvalidParameter)
            }
            try copyBackingBytes(
                resource.backing,
                logicalOffset: baseSourceOffset,
                count: byteCount,
                memory: memory,
                destination: resource.pixels,
                destinationOffset: rectangle.y * resource.stride
            )
        } else {
            for row in 0..<rectangle.height {
                let rowOffset = row * resource.stride
                guard rowOffset <= resource.byteCount - baseSourceOffset else {
                    throw GPUError.response(.errorInvalidParameter)
                }
                let logicalSource = baseSourceOffset + rowOffset
                guard rowBytes <= resource.byteCount - logicalSource else {
                    throw GPUError.response(.errorInvalidParameter)
                }
                let destinationOffset = (rectangle.y + row) * resource.stride + rectangle.x * 4
                try copyBackingBytes(
                    resource.backing,
                    logicalOffset: logicalSource,
                    count: rowBytes,
                    memory: memory,
                    destination: resource.pixels,
                    destinationOffset: destinationOffset
                )
            }
        }
        if !isCompleteTransfer {
            normalizePixels(
                in: resource.pixels,
                rectangle: rectangle,
                stride: resource.stride,
                format: resource.format
            )
            resource.lastBackingDirtyEpoch = nil
            resource.pendingGuestWrites = resource.pendingGuestWrites.flatMap {
                $0.subtracting(rectangle)
            }
        }
        resource.pendingTransfers.append(contentsOf: transferredRectangles)
        transferCommandCount &+= 1
        transferredByteCount &+= UInt64(nominalByteCount)
        backingCopiedByteCount &+= UInt64(copiedByteCount)
        dirtyBackingRangeCount &+= UInt64(dirtyRangeCount)
        lastTransferSummary = Self.rectangleSummary(
            resourceID: resourceID,
            rectangle: rectangle,
            suffix: "@\(sourceOffset):c\(resource.hasCompleteHostContents ? 1 : 0)" +
                "b\(resource.backing.count)r\(dirtyRangeCount):\(copiedByteCount)"
        )
        return responseHeader(.okNoData, requestHeader: header)
    }

    private struct PreparedParavirtual2D {
        let command: PineconeGraphicsCommand
        let source: Resource?
        let sourceRectangle: Rectangle?
        let sourceSurface: (surface: PineconeGraphicsSurface, isGuestMemory: Bool)?
        let destination: Resource
        let destinationRectangle: Rectangle
        let destinationSurface: (surface: PineconeGraphicsSurface, isGuestMemory: Bool)
        let mask: Resource?
        let maskRectangle: Rectangle?
        let maskSurface: (surface: PineconeGraphicsSurface, isGuestMemory: Bool)?
        let sourceContainsAlpha: Bool
    }

    private enum ParavirtualFailureStage: String {
        case prepare = "prep"
        case synchronize = "sync"
        case native
        case finish
    }

    private func recordParavirtualFailure(
        _ stage: ParavirtualFailureStage,
        prepared: [PreparedParavirtual2D]?
    ) {
        switch stage {
        case .prepare: paravirtualPrepareFailureCount &+= 1
        case .synchronize: paravirtualSyncFailureCount &+= 1
        case .native: paravirtualNativeFailureCount &+= 1
        case .finish: paravirtualFinishFailureCount &+= 1
        }
        guard let item = prepared?.first else {
            lastParavirtualFailure = stage.rawValue
            return
        }
        let command = item.command
        let rectangle = command.destinationRectangle
        lastParavirtualFailure = "\(stage.rawValue):o\(command.blendOperator.rawValue)" +
            ":s\(command.sourceResourceID):\(item.source?.width ?? 0)x" +
            "\(item.source?.height ?? 0)@\(item.source?.stride ?? 0)" +
            ":d\(command.destinationResourceID):\(item.destination.width)x" +
            "\(item.destination.height)@\(item.destination.stride)" +
            ":r\(rectangle.x),\(rectangle.y),\(rectangle.width)x" +
            "\(rectangle.height):a\(command.sourceIsPackedA8 ? 1 : 0)" +
            "\(command.destinationIsPackedA8 ? 1 : 0)"
    }

    private func submitParavirtual2D(
        _ request: [UInt8],
        header: Header,
        memory: PhysicalMemory
    ) throws -> [UInt8] {
        let prepared: [PreparedParavirtual2D]
        do {
            prepared = try prepareParavirtual2DRequest(request, memory: memory)
        } catch {
            recordParavirtualFailure(.prepare, prepared: nil)
            throw error
        }
        return try executeParavirtual2D(
            prepared,
            header: header,
            memory: memory
        )
    }

    private func prepareParavirtual2DRequest(
        _ request: [UInt8],
        memory: PhysicalMemory
    ) throws -> [PreparedParavirtual2D] {
        let payloadOffset = 32
        try require(request, count: payloadOffset + 8)
        let payloadSize = Int(Self.readLE32(request, at: 24))
        guard payloadSize >= 8,
              request.count >= payloadOffset + payloadSize,
              Self.readLE32(request, at: payloadOffset) == PineconeGraphicsProtocol.magic else {
            throw GPUError.response(.errorInvalidParameter)
        }

        let version = Self.readLE16(request, at: payloadOffset + 4)
        let prepared: [PreparedParavirtual2D]
        if version == PineconeGraphicsProtocol.version ||
            version == PineconeGraphicsProtocol.exactCompositeVersion {
            guard payloadSize == PineconeGraphicsProtocol.payloadByteCount else {
                throw GPUError.response(.errorInvalidParameter)
            }
            prepared = [try prepareParavirtual2D(
                request,
                payloadOffset: payloadOffset,
                memory: memory
            )]
        } else if version == PineconeGraphicsProtocol.batchVersion {
            try require(
                request,
                count: payloadOffset + PineconeGraphicsProtocol.batchHeaderByteCount
            )
            let commandCount = Int(Self.readLE16(request, at: payloadOffset + 6))
            let recordByteCount = Int(Self.readLE16(request, at: payloadOffset + 8))
            let batchFlags = Self.readLE16(request, at: payloadOffset + 10)
            let declaredByteCount = Int(Self.readLE32(request, at: payloadOffset + 12))
            guard commandCount > 0,
                  commandCount <= PineconeGraphicsProtocol.maximumBatchCommandCount,
                  recordByteCount == PineconeGraphicsProtocol.batchRecordByteCount,
                  batchFlags == 0 else {
                throw GPUError.response(.errorInvalidParameter)
            }
            let recordsByteCount = commandCount.multipliedReportingOverflow(
                by: recordByteCount
            )
            guard !recordsByteCount.overflow else {
                throw GPUError.response(.errorInvalidParameter)
            }
            let expectedByteCount = PineconeGraphicsProtocol.batchHeaderByteCount +
                recordsByteCount.partialValue
            guard payloadSize == expectedByteCount,
                  declaredByteCount == expectedByteCount else {
                throw GPUError.response(.errorInvalidParameter)
            }
            prepared = try (0..<commandCount).map { index in
                try prepareParavirtual2D(
                    request,
                    payloadOffset: payloadOffset +
                        PineconeGraphicsProtocol.batchHeaderByteCount +
                        index * recordByteCount,
                    memory: memory
                )
            }
        } else {
            throw GPUError.response(.errorInvalidParameter)
        }

        return prepared
    }

    private func prepareParavirtual2D(
        _ request: [UInt8],
        payloadOffset: Int,
        memory: PhysicalMemory
    ) throws -> PreparedParavirtual2D {
        try require(
            request,
            count: payloadOffset + PineconeGraphicsProtocol.payloadByteCount
        )
        let recordVersion = Self.readLE16(request, at: payloadOffset + 4)
        let rawOperation = Self.readLE16(request, at: payloadOffset + 6)
        let flags = Self.readLE32(request, at: payloadOffset + 8)
        let isExactComposite = recordVersion ==
            PineconeGraphicsProtocol.exactCompositeVersion
        let blendOperator: PineconeGraphicsBlendOperator
        let operation: PineconeGraphicsOperation
        if isExactComposite {
            guard let exactOperator = PineconeGraphicsBlendOperator(
                rawValue: rawOperation
            ) else {
                throw GPUError.response(.errorInvalidParameter)
            }
            blendOperator = exactOperator
            let solid = flags & PineconeGraphicsProtocol.solidSourceFlag != 0
            operation = solid
                ? (exactOperator == .source ? .fill : .fillOver)
                : (exactOperator == .source ? .source : .sourceOver)
        } else {
            guard recordVersion == PineconeGraphicsProtocol.version,
                  let legacyOperation = PineconeGraphicsOperation(
                    rawValue: rawOperation
                  ) else {
                throw GPUError.response(.errorInvalidParameter)
            }
            operation = legacyOperation
            blendOperator = legacyOperation == .source || legacyOperation == .fill
                ? .source : .sourceOver
        }
        let permittedFlags = isExactComposite
            ? PineconeGraphicsProtocol.supportedFlags
            : PineconeGraphicsProtocol.legacySupportedFlags
        guard Self.readLE32(request, at: payloadOffset) == PineconeGraphicsProtocol.magic,
              flags & ~permittedFlags == 0 else {
            throw GPUError.response(.errorInvalidParameter)
        }

        let sourceContainsAlpha = flags &
            PineconeGraphicsProtocol.sourceContainsAlphaFlag != 0
        let usesBilinearFiltering = flags &
            PineconeGraphicsProtocol.bilinearFilterFlag != 0
        let hasMask = flags & PineconeGraphicsProtocol.hasMaskFlag != 0
        let hasSolidMask = flags & PineconeGraphicsProtocol.solidMaskFlag != 0
        let hasSolidSource = flags & PineconeGraphicsProtocol.solidSourceFlag != 0
        let hasComponentAlphaMask = flags &
            PineconeGraphicsProtocol.componentAlphaMaskFlag != 0
        let hasPackedA8Mask = flags &
            PineconeGraphicsProtocol.packedA8MaskFlag != 0
        let hasPackedA8Source = flags &
            PineconeGraphicsProtocol.packedA8SourceFlag != 0
        let hasPackedA8Destination = flags &
            PineconeGraphicsProtocol.packedA8DestinationFlag != 0
        let sourceResourceID = Self.readLE32(request, at: payloadOffset + 12)
        let destinationResourceID = Self.readLE32(request, at: payloadOffset + 16)
        let sourceX = Self.readSignedLE32(request, at: payloadOffset + 20)
        let sourceY = Self.readSignedLE32(request, at: payloadOffset + 24)
        let destinationRectangle = Rectangle(
            x: Self.readSignedLE32(request, at: payloadOffset + 28),
            y: Self.readSignedLE32(request, at: payloadOffset + 32),
            width: Int(Self.readLE32(request, at: payloadOffset + 36)),
            height: Int(Self.readLE32(request, at: payloadOffset + 40))
        )
        let color = Self.readLE32(request, at: payloadOffset + 44)
        let sourceWidth = Int(Self.readLE32(request, at: payloadOffset + 48))
        let sourceHeight = Int(Self.readLE32(request, at: payloadOffset + 52))
        let maskResourceID = Self.readLE32(request, at: payloadOffset + 56)
        let maskAlphaValue = Self.readLE32(request, at: payloadOffset + 60)
        guard (!hasSolidMask || hasMask),
              (!hasComponentAlphaMask || (hasMask && !hasSolidMask)),
              (!hasPackedA8Mask || (hasMask && !hasSolidMask)),
              (isExactComposite ||
                (!hasSolidSource && !hasComponentAlphaMask && !hasPackedA8Mask &&
                 !hasPackedA8Source && !hasPackedA8Destination)),
              maskAlphaValue <= UInt32(UInt8.max),
              (hasMask
                  ? (hasSolidMask
                      ? maskResourceID == 0
                      : maskResourceID != 0 && maskAlphaValue == 0)
                  : maskResourceID == 0 && maskAlphaValue == 0) else {
            throw GPUError.response(.errorInvalidParameter)
        }
        guard destinationResourceID != 0,
              let destination = resources[destinationResourceID],
              Self.paravirtualPixelFormat(destination.format) != nil,
              !destination.backing.isEmpty,
              !destinationRectangle.isEmpty,
              destinationRectangle.isWithin(
                  width: destination.width,
                  height: destination.height
              ) else {
            throw GPUError.response(
                resources[destinationResourceID] == nil
                    ? .errorInvalidResourceID
                    : .errorInvalidParameter
            )
        }

        let source: Resource?
        let sourceRectangle: Rectangle?
        let operatorNeedsSource = blendOperator != .clear &&
            blendOperator != .destination
        if !operatorNeedsSource || hasSolidSource ||
            (!isExactComposite && (operation == .fill || operation == .fillOver)) {
            guard sourceResourceID == 0,
                  !sourceContainsAlpha,
                  !usesBilinearFiltering,
                  sourceWidth == 0,
                  sourceHeight == 0 else {
                throw GPUError.response(.errorInvalidParameter)
            }
            guard !hasSolidSource || operatorNeedsSource else {
                throw GPUError.response(.errorInvalidParameter)
            }
            source = nil
            sourceRectangle = nil
        } else {
            let rectangle = Rectangle(
                x: sourceX,
                y: sourceY,
                width: sourceWidth,
                height: sourceHeight
            )
            guard sourceResourceID != 0,
                  sourceWidth > 0,
                  sourceHeight > 0,
                  let candidate = resources[sourceResourceID],
                  Self.paravirtualPixelFormat(candidate.format) != nil,
                  !candidate.backing.isEmpty,
                  rectangle.isWithin(width: candidate.width, height: candidate.height),
                  sourceResourceID != destinationResourceID else {
                throw GPUError.response(
                    resources[sourceResourceID] == nil
                        ? .errorInvalidResourceID
                        : .errorInvalidParameter
                )
            }
            source = candidate
            sourceRectangle = rectangle
        }

        guard (!hasPackedA8Source ||
                (operatorNeedsSource && !hasSolidSource && sourceContainsAlpha &&
                 !usesBilinearFiltering)),
              (!hasPackedA8Destination || isExactComposite) else {
            throw GPUError.response(.errorInvalidParameter)
        }

        let mask: Resource?
        let maskRectangle: Rectangle?
        if hasMask && !hasSolidMask {
            let rectangle = Rectangle(
                x: 0,
                y: 0,
                width: destinationRectangle.width,
                height: destinationRectangle.height
            )
            guard let candidate = resources[maskResourceID],
                  Self.paravirtualPixelFormat(candidate.format) != nil,
                  !candidate.backing.isEmpty,
                  rectangle.isWithin(width: candidate.width, height: candidate.height),
                  maskResourceID != destinationResourceID,
                  maskResourceID != sourceResourceID else {
                throw GPUError.response(
                    resources[maskResourceID] == nil
                        ? .errorInvalidResourceID
                        : .errorInvalidParameter
                )
            }
            mask = candidate
            maskRectangle = rectangle
        } else {
            mask = nil
            maskRectangle = nil
        }

        let sourceSurface = source.map {
            acceleratorSurface(
                for: $0,
                resourceID: sourceResourceID,
                memory: memory
            )
        }
        let destinationSurface = acceleratorSurface(
            for: destination,
            resourceID: destinationResourceID,
            memory: memory
        )
        let maskSurface = mask.map {
            acceleratorSurface(
                for: $0,
                resourceID: maskResourceID,
                memory: memory
            )
        }
        let command = PineconeGraphicsCommand(
            operation: operation,
            sourceResourceID: sourceResourceID,
            destinationResourceID: destinationResourceID,
            sourceX: sourceX,
            sourceY: sourceY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destinationRectangle: PineconeGraphicsRectangle(
                x: destinationRectangle.x,
                y: destinationRectangle.y,
                width: destinationRectangle.width,
                height: destinationRectangle.height
            ),
            color: color,
            sourceContainsAlpha: sourceContainsAlpha,
            usesBilinearFiltering: usesBilinearFiltering,
            maskResourceID: maskResourceID,
            maskAlpha: hasSolidMask ? UInt8(maskAlphaValue) : nil,
            blendOperator: blendOperator,
            sourceIsSolid: hasSolidSource ||
                (!isExactComposite && (operation == .fill || operation == .fillOver)),
            componentAlphaMask: hasComponentAlphaMask,
            maskIsPackedA8: hasPackedA8Mask,
            sourceIsPackedA8: hasPackedA8Source,
            destinationIsPackedA8: hasPackedA8Destination
        )

        return PreparedParavirtual2D(
            command: command,
            source: source,
            sourceRectangle: sourceRectangle,
            sourceSurface: sourceSurface,
            destination: destination,
            destinationRectangle: destinationRectangle,
            destinationSurface: destinationSurface,
            mask: mask,
            maskRectangle: maskRectangle,
            maskSurface: maskSurface,
            sourceContainsAlpha: sourceContainsAlpha
        )
    }

    private func executeParavirtual2D(
        _ prepared: [PreparedParavirtual2D],
        header: Header,
        memory: PhysicalMemory
    ) throws -> [UInt8] {
        do {
            try synchronizeParavirtual2DInputs(prepared, memory: memory)
        } catch {
            recordParavirtualFailure(.synchronize, prepared: prepared)
            throw error
        }
        let workItems = paravirtual2DWorkItems(prepared)
        let accelerated = graphicsAccelerator?.executeBatch(workItems) ?? false

        if !accelerated {
            for item in prepared {
                if let source = item.source,
                   let rectangle = item.sourceRectangle,
                   item.sourceSurface?.isGuestMemory == true {
                    try synchronizeResource(
                        source,
                        rectangle: rectangle,
                        from: memory,
                        preserveAlpha: item.sourceContainsAlpha,
                        packedA8: item.command.sourceIsPackedA8
                    )
                }
                if item.destinationSurface.isGuestMemory {
                    try synchronizeResource(
                        item.destination,
                        rectangle: item.destinationRectangle,
                        from: memory,
                        packedA8: item.command.destinationIsPackedA8
                    )
                }
                if let mask = item.mask,
                   let rectangle = item.maskRectangle,
                   item.maskSurface?.isGuestMemory == true {
                    try synchronizeResource(
                        mask,
                        rectangle: rectangle,
                        from: memory,
                        preserveAlpha: true,
                        packedA8: item.command.maskIsPackedA8
                    )
                }
                do {
                    try executeParavirtual2DInNativeCore(
                        item.command,
                        source: item.source,
                        mask: item.mask,
                        destination: item.destination
                    )
                } catch {
                    recordParavirtualFailure(.native, prepared: [item])
                    throw error
                }
                do {
                    try finishParavirtual2D(item, accelerated: false, memory: memory)
                } catch {
                    recordParavirtualFailure(.finish, prepared: [item])
                    throw error
                }
            }
        } else {
            for item in prepared {
                do {
                    try finishParavirtual2D(item, accelerated: true, memory: memory)
                } catch {
                    recordParavirtualFailure(.finish, prepared: [item])
                    throw error
                }
            }
        }
        if prepared.count > 1 {
            paravirtualBatchCount &+= 1
        }
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func synchronizeParavirtual2DInputs(
        _ prepared: [PreparedParavirtual2D],
        memory: PhysicalMemory
    ) throws {
        for item in prepared {
            if let source = item.source,
               let rectangle = item.sourceRectangle,
               item.sourceSurface?.isGuestMemory == false {
                try synchronizeResource(
                    source,
                    rectangle: rectangle,
                    from: memory,
                    preserveAlpha: item.sourceContainsAlpha,
                    packedA8: item.command.sourceIsPackedA8
                )
            }
            if !item.destinationSurface.isGuestMemory {
                try synchronizeResource(
                    item.destination,
                    rectangle: item.destinationRectangle,
                    from: memory,
                    packedA8: item.command.destinationIsPackedA8
                )
            }
            if let mask = item.mask,
               let rectangle = item.maskRectangle,
               item.maskSurface?.isGuestMemory == false {
                try synchronizeResource(
                    mask,
                    rectangle: rectangle,
                    from: memory,
                    preserveAlpha: true,
                    packedA8: item.command.maskIsPackedA8
                )
            }
        }
    }

    private func paravirtual2DWorkItems(
        _ prepared: [PreparedParavirtual2D]
    ) -> [PineconeGraphicsWorkItem] {
        prepared.map {
            PineconeGraphicsWorkItem(
                command: $0.command,
                source: $0.sourceSurface?.surface,
                mask: $0.maskSurface?.surface,
                destination: $0.destinationSurface.surface
            )
        }
    }

    private func finishParavirtual2D(
        _ item: PreparedParavirtual2D,
        accelerated: Bool,
        memory: PhysicalMemory
    ) throws {
        let destinationWasComplete = item.destination.hasCompleteHostContents
        let directlyUpdatedGuestMemory = accelerated &&
            item.destinationSurface.isGuestMemory
        if directlyUpdatedGuestMemory {
            noteDirectGuestWrite(
                item.destination,
                rectangle: item.destinationRectangle,
                packedA8: item.command.destinationIsPackedA8,
                memory: memory
            )
            acceleratedDirtyRangeCount &+= 1
        } else {
            try copyResourceBytesToBacking(
                item.destination,
                rectangle: item.destinationRectangle,
                packedA8: item.command.destinationIsPackedA8,
                memory: memory
            )
        }
        let hostContentsUpdated = !directlyUpdatedGuestMemory
        let updatedWholeResource = item.destinationRectangle.x == 0 &&
            item.destinationRectangle.y == 0 &&
            item.destinationRectangle.width == item.destination.width &&
            item.destinationRectangle.height == item.destination.height
        // A direct Metal write makes only its dirty pages stale in the host
        // mirror. Preserve the established dirty epoch so the following full
        // transfer copies those pages instead of rebuilding the whole surface.
        item.destination.hasCompleteHostContents = destinationWasComplete ||
            (hostContentsUpdated && updatedWholeResource)
        if hostContentsUpdated {
            item.destination.pendingTransfers.append(item.destinationRectangle)
        }
        paravirtualCommandCount &+= 1
        paravirtualAcceleratedCount &+= accelerated ? 1 : 0
        paravirtualPixelCount &+= UInt64(
            item.destinationRectangle.width * item.destinationRectangle.height
        )
    }

    private func acceleratorSurface(
        for resource: Resource,
        resourceID: UInt32,
        memory: PhysicalMemory
    ) -> (surface: PineconeGraphicsSurface, isGuestMemory: Bool) {
        let pixelFormat = Self.paravirtualPixelFormat(resource.format)!
        if resource.backing.count == 1,
           let backing = resource.backing.first,
           backing.length >= resource.byteCount,
           let bytes = try? memory.persistentMutableBytes(
               at: backing.address,
               count: resource.byteCount
           ) {
            return (
                PineconeGraphicsSurface(
                    resourceID: resourceID,
                    width: resource.width,
                    height: resource.height,
                    stride: resource.stride,
                    pixelFormat: pixelFormat,
                    bytes: bytes,
                    allocationByteCount: backing.length
                ),
                true
            )
        }
        return (
            resource.pixels.acceleratorSurface(
                resourceID: resourceID,
                width: resource.width,
                height: resource.height,
                pixelFormat: pixelFormat
            ),
            false
        )
    }

    private func noteDirectGuestWrite(
        _ resource: Resource,
        rectangle: Rectangle,
        packedA8: Bool,
        memory: PhysicalMemory
    ) {
        guard let backing = resource.backing.first,
              rectangle.width > 0,
              rectangle.height > 0 else { return }
        let bytesPerPixel = packedA8 ? 1 : 4
        let offset = rectangle.y * resource.stride + rectangle.x * bytesPerPixel
        let byteCount = (rectangle.height - 1) * resource.stride +
            rectangle.width * bytesPerPixel
        memory.noteDeviceWrite(
            at: backing.address + UInt64(offset),
            count: byteCount
        )
        resource.pendingGuestWrites.append(KnownGuestWrite(
            rectangle: rectangle,
            packedA8: packedA8
        ))
    }

    private func executeParavirtual2DInNativeCore(
        _ command: PineconeGraphicsCommand,
        source: Resource?,
        mask: Resource?,
        destination: Resource
    ) throws {
        let rectangle = command.destinationRectangle
        let result: Int32
        if command.componentAlphaMask || command.maskIsPackedA8 ||
            command.sourceIsPackedA8 || command.destinationIsPackedA8 ||
            (command.blendOperator != .sourceOver &&
             command.blendOperator != .source) {
            func executeGeneric(
                sourceBytes: UnsafeRawBufferPointer?,
                maskBytes: UnsafeRawBufferPointer?
            ) -> Int32 {
                destination.pixels.withUnsafeMutableBytes { destinationBytes in
                    avz_framebuffer_composite_bgra8(
                        sourceBytes?.baseAddress,
                        source?.stride ?? 0,
                        command.sourceX,
                        command.sourceY,
                        command.sourceWidth,
                        command.sourceHeight,
                        maskBytes?.baseAddress,
                        mask?.stride ?? 0,
                        command.maskAlpha ?? UInt8.max,
                        destinationBytes.baseAddress,
                        destination.stride,
                        rectangle.x,
                        rectangle.y,
                        rectangle.width,
                        rectangle.height,
                        command.color,
                        UInt32(command.blendOperator.rawValue),
                        command.sourceIsSolid ? 1 : 0,
                        command.usesBilinearFiltering ? 1 : 0,
                        command.componentAlphaMask ? 1 : 0,
                        command.maskIsPackedA8 ? 1 : 0,
                        command.sourceIsPackedA8 ? 1 : 0,
                        command.destinationIsPackedA8 ? 1 : 0
                    )
                }
            }
            func executeWithMask(
                sourceBytes: UnsafeRawBufferPointer?
            ) -> Int32 {
                if let mask {
                    return mask.pixels.withUnsafeBytes {
                        executeGeneric(sourceBytes: sourceBytes, maskBytes: $0)
                    }
                }
                return executeGeneric(sourceBytes: sourceBytes, maskBytes: nil)
            }
            if let source {
                result = source.pixels.withUnsafeBytes {
                    executeWithMask(sourceBytes: $0)
                }
            } else {
                result = executeWithMask(sourceBytes: nil)
            }
        } else if mask != nil || command.maskAlpha != nil {
            func executeMasked(
                sourceBytes: UnsafeRawBufferPointer?,
                maskBytes: UnsafeRawBufferPointer?
            ) -> Int32 {
                destination.pixels.withUnsafeMutableBytes { destinationBytes in
                    avz_framebuffer_masked_composite_bgra8(
                        sourceBytes?.baseAddress,
                        source?.stride ?? 0,
                        command.sourceX,
                        command.sourceY,
                        command.sourceWidth,
                        command.sourceHeight,
                        maskBytes?.baseAddress,
                        mask?.stride ?? 0,
                        command.maskAlpha ?? UInt8.max,
                        destinationBytes.baseAddress,
                        destination.stride,
                        rectangle.x,
                        rectangle.y,
                        rectangle.width,
                        rectangle.height,
                        command.color,
                        UInt32(command.operation.rawValue),
                        command.usesBilinearFiltering ? 1 : 0
                    )
                }
            }
            func executeWithMask(
                sourceBytes: UnsafeRawBufferPointer?
            ) -> Int32 {
                if let mask {
                    return mask.pixels.withUnsafeBytes {
                        executeMasked(sourceBytes: sourceBytes, maskBytes: $0)
                    }
                }
                return executeMasked(sourceBytes: sourceBytes, maskBytes: nil)
            }
            if let source {
                result = source.pixels.withUnsafeBytes {
                    executeWithMask(sourceBytes: $0)
                }
            } else {
                result = executeWithMask(sourceBytes: nil)
            }
        } else { switch command.operation {
        case .source:
            guard let source else {
                throw GPUError.response(.errorInvalidParameter)
            }
            result = source.pixels.withUnsafeBytes { sourceBytes in
                destination.pixels.withUnsafeMutableBytes { destinationBytes in
                    if command.usesBilinearFiltering {
                        avz_framebuffer_bilinear_scale_copy_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            command.sourceWidth,
                            command.sourceHeight,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    } else if command.sourceWidth == rectangle.width,
                       command.sourceHeight == rectangle.height {
                        avz_framebuffer_copy_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    } else {
                        avz_framebuffer_scale_copy_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            command.sourceWidth,
                            command.sourceHeight,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    }
                }
            }
        case .sourceOver:
            guard let source else {
                throw GPUError.response(.errorInvalidParameter)
            }
            result = source.pixels.withUnsafeBytes { sourceBytes in
                destination.pixels.withUnsafeMutableBytes { destinationBytes in
                    if command.usesBilinearFiltering {
                        avz_framebuffer_bilinear_scale_source_over_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            command.sourceWidth,
                            command.sourceHeight,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    } else if command.sourceWidth == rectangle.width,
                       command.sourceHeight == rectangle.height {
                        avz_framebuffer_source_over_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    } else {
                        avz_framebuffer_scale_source_over_bgra8(
                            sourceBytes.baseAddress,
                            source.stride,
                            command.sourceX,
                            command.sourceY,
                            command.sourceWidth,
                            command.sourceHeight,
                            destinationBytes.baseAddress,
                            destination.stride,
                            rectangle.x,
                            rectangle.y,
                            rectangle.width,
                            rectangle.height
                        )
                    }
                }
            }
        case .fill:
            result = destination.pixels.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_fill_bgra8(
                    destinationBytes.baseAddress,
                    destination.stride,
                    rectangle.x,
                    rectangle.y,
                    rectangle.width,
                    rectangle.height,
                    command.color
                )
            }
        case .fillOver:
            result = destination.pixels.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_fill_over_bgra8(
                    destinationBytes.baseAddress,
                    destination.stride,
                    rectangle.x,
                    rectangle.y,
                    rectangle.width,
                    rectangle.height,
                    command.color
                )
            }
        } }
        guard result != 0 else {
            throw GPUError.response(.errorInvalidParameter)
        }
        if destination.format == .b8g8r8x8UNorm {
            normalizePixels(
                in: destination.pixels,
                rectangle: Rectangle(
                    x: rectangle.x,
                    y: rectangle.y,
                    width: rectangle.width,
                    height: rectangle.height
                ),
                stride: destination.stride,
                format: destination.format
            )
        }
    }

    private func synchronizeResource(
        _ resource: Resource,
        rectangle: Rectangle,
        from memory: PhysicalMemory,
        preserveAlpha: Bool = false,
        packedA8: Bool = false
    ) throws {
        let bytesPerPixel = packedA8 ? 1 : 4
        for row in 0..<rectangle.height {
            let offset = (rectangle.y + row) * resource.stride +
                rectangle.x * bytesPerPixel
            try copyBackingBytes(
                resource.backing,
                logicalOffset: offset,
                count: rectangle.width * bytesPerPixel,
                memory: memory,
                destination: resource.pixels,
                destinationOffset: offset
            )
        }
        if !preserveAlpha && !packedA8 {
            normalizePixels(
                in: resource.pixels,
                rectangle: rectangle,
                stride: resource.stride,
                format: resource.format
            )
        }
    }

    private func copyResourceBytesToBacking(
        _ resource: Resource,
        rectangle: Rectangle,
        packedA8: Bool,
        memory: PhysicalMemory
    ) throws {
        let bytesPerPixel = packedA8 ? 1 : 4
        try resource.pixels.withUnsafeBytes { sourceBytes in
            for row in 0..<rectangle.height {
                let offset = (rectangle.y + row) * resource.stride +
                    rectangle.x * bytesPerPixel
                try copyBytesToBacking(
                    resource.backing,
                    logicalOffset: offset,
                    count: rectangle.width * bytesPerPixel,
                    memory: memory,
                    source: sourceBytes.baseAddress!.advanced(by: offset)
                )
            }
        }
    }

    private func copyBytesToBacking(
        _ entries: [BackingEntry],
        logicalOffset: Int,
        count: Int,
        memory: PhysicalMemory,
        source: UnsafeRawPointer
    ) throws {
        var skipped = logicalOffset
        var copied = 0
        for entry in entries {
            if skipped >= entry.length {
                skipped -= entry.length
                continue
            }
            let byteCount = min(entry.length - skipped, count - copied)
            try memory.copyOwnedDeviceBytes(
                from: source.advanced(by: copied),
                count: byteCount,
                to: entry.address + UInt64(skipped)
            )
            copied += byteCount
            skipped = 0
            if copied == count { return }
        }
        throw GPUError.response(.errorInvalidParameter)
    }

    private static func paravirtualPixelFormat(
        _ format: PixelFormat
    ) -> PineconeGraphicsPixelFormat? {
        switch format {
        case .b8g8r8a8UNorm:
            return .bgra8Premultiplied
        case .b8g8r8x8UNorm:
            return .bgrx8
        default:
            return nil
        }
    }

    private func updateCursor(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 56)
        let scanoutID = Self.readLE32(request, at: 24)
        let x = Int(Self.readLE32(request, at: 28))
        let y = Int(Self.readLE32(request, at: 32))
        let resourceID = Self.readLE32(request, at: 40)
        guard scanoutID == 0 else {
            throw GPUError.response(.errorInvalidScanoutID)
        }
        let oldCursor = cursor
        if resourceID == 0 {
            cursor = nil
            displayStateChanged(damage: cursorRectangle(oldCursor))
            return responseHeader(.okNoData, requestHeader: header)
        }
        guard let resource = resources[resourceID] else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        guard resource.width == 64, resource.height == 64 else {
            throw GPUError.response(.errorInvalidParameter)
        }
        let hotX = Int(Self.readLE32(request, at: 44))
        let hotY = Int(Self.readLE32(request, at: 48))
        guard hotX < resource.width, hotY < resource.height else {
            throw GPUError.response(.errorInvalidParameter)
        }
        cursor = Cursor(resourceID: resourceID, x: x, y: y, hotX: hotX, hotY: hotY)
        displayStateChanged(damage: combinedCursorDamage(oldCursor, cursor))
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func moveCursor(_ request: [UInt8], header: Header) throws -> [UInt8] {
        try require(request, count: 56)
        let scanoutID = Self.readLE32(request, at: 24)
        guard scanoutID == 0 else {
            throw GPUError.response(.errorInvalidScanoutID)
        }
        if let cursor {
            let oldCursor = cursor
            self.cursor = Cursor(
                resourceID: cursor.resourceID,
                x: Int(Self.readLE32(request, at: 28)),
                y: Int(Self.readLE32(request, at: 32)),
                hotX: cursor.hotX,
                hotY: cursor.hotY
            )
            displayStateChanged(damage: combinedCursorDamage(oldCursor, self.cursor))
        }
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func displayStateChanged(damage: Rectangle?) {
        guard hasCommittedFrame, let damage else { return }
        commit(damage: damage)
    }

    private func cursorRectangle(_ cursor: Cursor?) -> Rectangle? {
        guard let cursor, let resource = resources[cursor.resourceID] else {
            return nil
        }
        return Rectangle(
            x: cursor.x - cursor.hotX,
            y: cursor.y - cursor.hotY,
            width: resource.width,
            height: resource.height
        ).intersection(Rectangle(x: 0, y: 0, width: width, height: height))
    }

    private func combinedCursorDamage(_ first: Cursor?, _ second: Cursor?) -> Rectangle? {
        switch (cursorRectangle(first), cursorRectangle(second)) {
        case let (first?, second?):
            return first.union(second)
        case let (first?, nil):
            return first
        case let (nil, second?):
            return second
        case (nil, nil):
            return nil
        }
    }

    private func compositedPixels() -> [UInt8] {
        guard let cursor, let resource = resources[cursor.resourceID] else {
            return committedPixels.snapshot()
        }
        var output = committedPixels.snapshot()
        let originX = cursor.x - cursor.hotX
        let originY = cursor.y - cursor.hotY
        guard let visible = Rectangle(
            x: originX,
            y: originY,
            width: resource.width,
            height: resource.height
        ).intersection(Rectangle(x: 0, y: 0, width: width, height: height)) else {
            return output
        }
        let sourceX = visible.x - originX
        let sourceY = visible.y - originY
        let blended = resource.pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_source_over_bgra8(
                    sourceBytes.baseAddress,
                    resource.stride,
                    sourceX,
                    sourceY,
                    destinationBytes.baseAddress,
                    width * 4,
                    visible.x,
                    visible.y,
                    visible.width,
                    visible.height
                )
            }
        }
        precondition(blended != 0, "invalid native cursor composition")
        return output
    }

    private func normalizePixels(
        in pixels: NativeFramebufferStorage,
        rectangle: Rectangle,
        stride: Int,
        format: PixelFormat
    ) {
        guard !rectangle.isEmpty else { return }
        let offset = rectangle.y * stride + rectangle.x * 4
        let normalized = pixels.withUnsafeMutableBytes { bytes in
            avz_framebuffer_normalize_bgra8(
                bytes.baseAddress!.advanced(by: offset),
                stride,
                rectangle.width,
                rectangle.height,
                format.rawValue
            )
        }
        precondition(normalized != 0, "unsupported framebuffer normalization")
    }

    private func normalizePixelBytes(
        in pixels: NativeFramebufferStorage,
        offset: Int,
        count: Int,
        format: PixelFormat
    ) {
        guard count > 0 else { return }
        precondition(offset >= 0 && count % 4 == 0 && offset <= pixels.byteCount - count)
        let normalized = pixels.withUnsafeMutableBytes { bytes in
            avz_framebuffer_normalize_bgra8(
                bytes.baseAddress!.advanced(by: offset),
                count,
                count / 4,
                1,
                format.rawValue
            )
        }
        precondition(normalized != 0, "unsupported framebuffer normalization")
    }

    private func flushResource(
        _ request: [UInt8],
        header: Header
    ) throws -> [UInt8] {
        try require(request, count: 48)
        let flushRectangle = try Self.rectangle(request, at: 24)
        let resourceID = Self.readLE32(request, at: 40)
        guard let resource = resources[resourceID] else {
            throw GPUError.response(.errorInvalidResourceID)
        }
        flushCommandCount &+= 1
        guard !flushRectangle.isEmpty,
              flushRectangle.isWithin(width: resource.width, height: resource.height) else {
            throw GPUError.response(.errorInvalidParameter)
        }
        guard let scanout, scanout.resourceID == resourceID,
              let visible = flushRectangle.intersection(scanout.rectangle) else {
            lastFlushSummary = Self.rectangleSummary(
                resourceID: resourceID,
                rectangle: flushRectangle,
                suffix: ":hidden"
            )
            return responseHeader(.okNoData, requestHeader: header)
        }

        let pendingTransferCount = resource.pendingTransfers.count
        let wasComplete = resource.hasCompleteHostContents
        let geometryChanged = committedScanout?.rectangle != scanout.rectangle
        let transferredVisible = Self.compactDamageRectangles(
            resource.pendingTransfers.compactMap {
                $0.intersection(flushRectangle)?.intersection(scanout.rectangle)
            }
        )

        prepareCommittedFrameForWrite()
        let outputDamage: [Rectangle]
        var changedByteCount = 0
        if !hasCommittedFrame || geometryChanged {
            committedPixels.clear()
            copyResourceRectangle(
                visible,
                from: resource,
                scanout: scanout,
                into: committedPixels
            )
            outputDamage = [Rectangle(x: 0, y: 0, width: width, height: height)]
            changedByteCount = width * height * 4
        } else {
            var damage: [Rectangle] = []
            for candidate in transferredVisible {
                let result = copyChangedResourceTiles(
                    candidate,
                    from: resource,
                    scanout: scanout,
                    into: committedPixels
                )
                damage.append(contentsOf: result.damage)
                changedByteCount += result.changedByteCount
            }
            outputDamage = Self.compactDamageRectangles(damage)
            dirtyTileScanCount &+= UInt64(transferredVisible.count)
            dirtyTileChangedByteCount &+= UInt64(changedByteCount)
            if outputDamage.isEmpty {
                unchangedFlushCount &+= 1
            }
        }
        resource.pendingTransfers = resource.pendingTransfers.flatMap {
            $0.subtracting(flushRectangle)
        }
        lastFlushSummary = Self.rectangleSummary(
            resourceID: resourceID,
            rectangle: flushRectangle,
            suffix: ":p\(pendingTransferCount)c\(wasComplete ? 1 : 0)" +
                "s\(transferredVisible.count)d\(outputDamage.count):\(changedByteCount)"
        )
        committedScanout = scanout
        commit(damage: outputDamage)
        return responseHeader(.okNoData, requestHeader: header)
    }

    private func copyChangedResourceTiles(
        _ rectangle: Rectangle,
        from resource: Resource,
        scanout: Scanout,
        into destination: NativeFramebufferStorage
    ) -> (damage: [Rectangle], changedByteCount: Int) {
        let outputX = rectangle.x - scanout.rectangle.x
        let outputY = rectangle.y - scanout.rectangle.y
        let capacity = Int(AVZ_FRAMEBUFFER_MAX_DAMAGE_RECTS)
        var damage: [Rectangle] = []
        var changedByteCount = 0

        withUnsafeTemporaryAllocation(
            of: AVZFramebufferDamageRect.self,
            capacity: capacity
        ) { damageBuffer in
            resource.pixels.withUnsafeBytes { sourceBytes in
                destination.withUnsafeMutableBytes { destinationBytes in
                    let count = avz_framebuffer_commit_dirty_tiles(
                        sourceBytes.baseAddress!,
                        resource.stride,
                        rectangle.x,
                        rectangle.y,
                        destinationBytes.baseAddress!,
                        width * 4,
                        outputX,
                        outputY,
                        rectangle.width,
                        rectangle.height,
                        Self.dirtyTileWidth,
                        Self.dirtyTileHeight,
                        damageBuffer.baseAddress!,
                        capacity,
                        &changedByteCount
                    )
                    damage.reserveCapacity(count)
                    for index in 0..<count {
                        let native = damageBuffer[index]
                        damage.append(Rectangle(
                            x: Int(native.x),
                            y: Int(native.y),
                            width: Int(native.width),
                            height: Int(native.height)
                        ))
                    }
                }
            }
        }
        return (damage, changedByteCount)
    }

    private func copyResourceRectangle(
        _ rectangle: Rectangle,
        from resource: Resource,
        scanout: Scanout,
        into destination: NativeFramebufferStorage
    ) {
        resource.pixels.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else {
                    return
                }
                let copied = avz_framebuffer_copy_bgra8(
                    sourceBase,
                    resource.stride,
                    rectangle.x,
                    rectangle.y,
                    destinationBase,
                    width * 4,
                    rectangle.x - scanout.rectangle.x,
                    rectangle.y - scanout.rectangle.y,
                    rectangle.width,
                    rectangle.height
                )
                precondition(copied != 0, "invalid native framebuffer copy")
            }
        }
    }

    private func fullScanoutPixels(resource: Resource, rectangle: Rectangle) -> [UInt8] {
        var output = Array(repeating: UInt8(0), count: width * height * 4)
        resource.pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                for row in 0..<rectangle.height {
                    let sourceOffset = (rectangle.y + row) * resource.stride + rectangle.x * 4
                    let destinationOffset = row * width * 4
                    memcpy(
                        destinationBytes.baseAddress!.advanced(by: destinationOffset),
                        sourceBytes.baseAddress!.advanced(by: sourceOffset),
                        rectangle.width * 4
                    )
                }
            }
        }
        return output
    }

    private func copyBackingBytes(
        _ entries: [BackingEntry],
        logicalOffset: Int,
        count: Int,
        memory: PhysicalMemory,
        destination: NativeFramebufferStorage,
        destinationOffset: Int
    ) throws {
        guard logicalOffset >= 0,
              count >= 0,
              destinationOffset >= 0,
              destinationOffset <= destination.byteCount,
              count <= destination.byteCount - destinationOffset else {
            throw GPUError.response(.errorInvalidParameter)
        }
        guard count > 0 else { return }

        try destination.withUnsafeMutableBytes { destinationBytes in
            var skipped = logicalOffset
            var copied = 0
            for entry in entries {
                if skipped >= entry.length {
                    skipped -= entry.length
                    continue
                }
                let available = entry.length - skipped
                let byteCount = min(available, count - copied)
                try memory.copyOwnedDeviceBytes(
                    from: entry.address + UInt64(skipped),
                    count: byteCount,
                    to: destinationBytes.baseAddress!.advanced(
                        by: destinationOffset + copied
                    )
                )
                copied += byteCount
                skipped = 0
                if copied == count { return }
            }
            throw GPUError.response(.errorInvalidParameter)
        }
    }

    private func copyBackingRectangle(
        _ resource: Resource,
        rectangle: Rectangle,
        packedA8: Bool,
        memory: PhysicalMemory
    ) throws {
        let bytesPerPixel = packedA8 ? 1 : 4
        for row in 0..<rectangle.height {
            let offset = (rectangle.y + row) * resource.stride +
                rectangle.x * bytesPerPixel
            try copyBackingBytes(
                resource.backing,
                logicalOffset: offset,
                count: rectangle.width * bytesPerPixel,
                memory: memory,
                destination: resource.pixels,
                destinationOffset: offset
            )
        }
        if !packedA8 {
            normalizePixels(
                in: resource.pixels,
                rectangle: rectangle,
                stride: resource.stride,
                format: resource.format
            )
        }
    }

    private func dirtyBackingRanges(
        _ entries: [BackingEntry],
        byteCount: Int,
        memory: PhysicalMemory,
        afterEpoch: UInt64,
        throughEpoch: UInt64
    ) -> [LogicalByteRange] {
        var logicalOffset = 0
        var ranges: [LogicalByteRange] = []

        for entry in entries where logicalOffset < byteCount {
            let observedLength = min(entry.length, byteCount - logicalOffset)
            let dirtyRanges = memory.dirtyRanges(
                at: entry.address,
                count: observedLength,
                afterEpoch: afterEpoch,
                throughEpoch: throughEpoch,
                capacity: 1_024
            )
            for dirtyRange in dirtyRanges {
                let physicalOffset = Int(dirtyRange.address - entry.address)
                let dirtyStart = logicalOffset + physicalOffset
                let dirtyEnd = dirtyStart + dirtyRange.count
                let pixelStart = max(0, dirtyStart & ~3)
                let pixelEnd = min(byteCount, (dirtyEnd + 3) & ~3)
                if pixelEnd > pixelStart {
                    ranges.append(LogicalByteRange(
                        offset: pixelStart,
                        count: pixelEnd - pixelStart
                    ))
                }
            }
            logicalOffset += entry.length
        }

        return Self.compactLogicalByteRanges(ranges)
    }

    private static func compactLogicalByteRanges(
        _ ranges: [LogicalByteRange]
    ) -> [LogicalByteRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { lhs, rhs in
            lhs.offset == rhs.offset ? lhs.end < rhs.end : lhs.offset < rhs.offset
        }
        var compacted: [LogicalByteRange] = []
        compacted.reserveCapacity(sorted.count)
        for range in sorted where range.count > 0 {
            guard let previous = compacted.last, range.offset <= previous.end else {
                compacted.append(range)
                continue
            }
            compacted[compacted.count - 1] = LogicalByteRange(
                offset: previous.offset,
                count: max(previous.end, range.end) - previous.offset
            )
        }
        return compacted
    }

    private static func rectangles(
        for range: LogicalByteRange,
        resourceWidth: Int,
        resourceHeight: Int
    ) -> [Rectangle] {
        guard range.count > 0, resourceWidth > 0 else { return [] }
        var pixel = range.offset / 4
        var remaining = range.count / 4
        var rectangles: [Rectangle] = []

        let firstX = pixel % resourceWidth
        if firstX != 0 {
            let width = min(remaining, resourceWidth - firstX)
            rectangles.append(Rectangle(
                x: firstX,
                y: pixel / resourceWidth,
                width: width,
                height: 1
            ))
            pixel += width
            remaining -= width
        }

        let fullRows = remaining / resourceWidth
        if fullRows > 0 {
            rectangles.append(Rectangle(
                x: 0,
                y: pixel / resourceWidth,
                width: resourceWidth,
                height: fullRows
            ))
            let fullRowPixels = fullRows * resourceWidth
            pixel += fullRowPixels
            remaining -= fullRowPixels
        }

        if remaining > 0 {
            rectangles.append(Rectangle(
                x: 0,
                y: pixel / resourceWidth,
                width: remaining,
                height: 1
            ))
        }
        return rectangles.filter {
            $0.isWithin(width: resourceWidth, height: resourceHeight)
        }
    }

    private func responseHeader(_ response: Response, requestHeader: Header?) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Header.byteCount)
        Self.writeLE32(response.rawValue, into: &bytes, at: 0)
        if let requestHeader, (requestHeader.flags & Header.fenceFlag) != 0 {
            Self.writeLE32(Header.fenceFlag, into: &bytes, at: 4)
            Self.writeLE64(requestHeader.fenceID, into: &bytes, at: 8)
            Self.writeLE32(requestHeader.contextID, into: &bytes, at: 16)
            bytes[20] = requestHeader.ringIndex
        }
        return bytes
    }

    private func require(_ bytes: [UInt8], count: Int) throws {
        guard bytes.count >= count else {
            throw GPUError.response(.errorInvalidParameter)
        }
    }

    private static func rectangle(_ bytes: [UInt8], at offset: Int) throws -> Rectangle {
        guard bytes.count >= offset + 16 else {
            throw GPUError.response(.errorInvalidParameter)
        }
        return Rectangle(
            x: Int(readLE32(bytes, at: offset)),
            y: Int(readLE32(bytes, at: offset + 4)),
            width: Int(readLE32(bytes, at: offset + 8)),
            height: Int(readLE32(bytes, at: offset + 12))
        )
    }

    private static func rectangleSummary(
        resourceID: UInt32,
        rectangle: Rectangle,
        suffix: String
    ) -> String {
        "r\(resourceID):\(rectangle.x),\(rectangle.y)," +
            "\(rectangle.width)x\(rectangle.height)\(suffix)"
    }

    private static func readLE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset >= 0, offset <= bytes.count - 2 else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readSignedLE32(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(Int32(bitPattern: readLE32(bytes, at: offset)))
    }

    private static func readLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(readLE32(bytes, at: offset)) | (UInt64(readLE32(bytes, at: offset + 4)) << 32)
    }

    private static func writeLE32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func writeLE64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        writeLE32(UInt32(truncatingIfNeeded: value), into: &bytes, at: offset)
        writeLE32(UInt32(truncatingIfNeeded: value >> 32), into: &bytes, at: offset + 4)
    }
}
