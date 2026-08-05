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

    private final class Resource {
        let format: PixelFormat
        let width: Int
        let height: Int
        var backing: [BackingEntry] = []
        var pixels: [UInt8]
        var hasCompleteHostContents = false
        var pendingTransfers: [Rectangle] = []
        var lastBackingDirtyEpoch: UInt64?

        init(format: PixelFormat, width: Int, height: Int, pixels: [UInt8]) {
            self.format = format
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        var stride: Int { width * 4 }
        var byteCount: Int { pixels.count }
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

    let width: Int
    let height: Int

    private let lock = NSLock()
    private var resources: [UInt32: Resource] = [:]
    private var scanout: Scanout?
    private var committedScanout: Scanout?
    private var cursor: Cursor?
    private let committedPixels: NativeFramebufferStorage
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
    private var dirtyTileScanCount: UInt64 = 0
    private var unchangedFlushCount: UInt64 = 0
    private var dirtyTileChangedByteCount: UInt64 = 0
    private var dirtyPageTransferCount: UInt64 = 0
    private var backingCopiedByteCount: UInt64 = 0
    private var cleanBackingSkippedByteCount: UInt64 = 0
    private var dirtyBackingRangeCount: UInt64 = 0
    private var lastTransferSummary = "none"
    private var lastFlushSummary = "none"

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
        self.committedPixels = NativeFramebufferStorage(
            byteCount: width * height * 4
        )
    }

    func reset() {
        lock.lock()
        resources.removeAll(keepingCapacity: true)
        scanout = nil
        committedScanout = nil
        cursor = nil
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
        dirtyTileScanCount = 0
        unchangedFlushCount = 0
        dirtyTileChangedByteCount = 0
        dirtyPageTransferCount = 0
        backingCopiedByteCount = 0
        cleanBackingSkippedByteCount = 0
        dirtyBackingRangeCount = 0
        lastTransferSummary = "none"
        lastFlushSummary = "none"
        lock.unlock()
    }

    func diagnosticsSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "gpu=t\(transferCommandCount)/f\(flushCommandCount)" +
            " bytes=\(transferredByteCount)/\(committedByteCount)" +
            " direct=\(directFrameReadCount)/\(directFrameReadByteCount)" +
            " snap=\(snapshotCopyCount)" +
            " dirty=\(dirtyTileScanCount)/\(unchangedFlushCount)" +
            ":\(dirtyTileChangedByteCount)" +
            " pages=\(dirtyPageTransferCount)/\(dirtyBackingRangeCount)" +
            ":\(backingCopiedByteCount)/\(cleanBackingSkippedByteCount)" +
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
        lock.lock()
        defer { lock.unlock() }
        guard let metadata = frameMetadata(afterGeneration: previousGeneration) else {
            return nil
        }

        directFrameReadCount &+= 1
        directFrameReadByteCount &+= UInt64(metadata.damagedByteCount)
        if cursor == nil {
            committedPixels.withUnsafeBytes { body(metadata, $0) }
        } else {
            let pixels = compositedPixels()
            snapshotCopyCount &+= 1
            pixels.withUnsafeBytes { body(metadata, $0) }
        }
        return metadata
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

    func backingSnapshot(memory: PhysicalMemory) -> VirtualFramebufferSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard hasCommittedFrame,
              let scanout,
              let resource = resources[scanout.resourceID],
              !resource.backing.isEmpty else {
            return nil
        }

        var backingPixels = Array(repeating: UInt8(0), count: resource.byteCount)
        do {
            try copyBackingBytes(
                resource.backing,
                logicalOffset: 0,
                count: resource.byteCount,
                memory: memory,
                destination: &backingPixels,
                destinationOffset: 0
            )
        } catch {
            return nil
        }
        normalizePixels(
            in: &backingPixels,
            rectangle: Rectangle(
                x: 0,
                y: 0,
                width: resource.width,
                height: resource.height
            ),
            stride: resource.stride,
            format: resource.format
        )
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

        lock.lock()
        defer { lock.unlock() }
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
            height: resourceHeight,
            pixels: Array(repeating: 0, count: byteCount)
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
        if scanout?.resourceID == resourceID {
            scanout = nil
            committedScanout = nil
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
                let dirtyRanges = dirtyBackingRanges(
                    resource.backing,
                    byteCount: resource.byteCount,
                    memory: memory,
                    afterEpoch: afterEpoch,
                    throughEpoch: throughEpoch
                )
                copiedByteCount = dirtyRanges.reduce(0) { $0 + $1.count }
                dirtyRangeCount = dirtyRanges.count
                transferredRectangles = Self.compactDamageRectangles(
                    dirtyRanges.flatMap {
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
                        destination: &resource.pixels,
                        destinationOffset: range.offset
                    )
                    normalizePixelBytes(
                        in: &resource.pixels,
                        offset: range.offset,
                        count: range.count,
                        format: resource.format
                    )
                }
                dirtyPageTransferCount &+= 1
                cleanBackingSkippedByteCount &+= UInt64(
                    nominalByteCount - copiedByteCount
                )
            } else {
                try copyBackingBytes(
                    resource.backing,
                    logicalOffset: 0,
                    count: nominalByteCount,
                    memory: memory,
                    destination: &resource.pixels,
                    destinationOffset: 0
                )
                normalizePixels(
                    in: &resource.pixels,
                    rectangle: rectangle,
                    stride: resource.stride,
                    format: resource.format
                )
            }
            resource.hasCompleteHostContents = true
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
                destination: &resource.pixels,
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
                    destination: &resource.pixels,
                    destinationOffset: destinationOffset
                )
            }
        }
        if !isCompleteTransfer {
            normalizePixels(
                in: &resource.pixels,
                rectangle: rectangle,
                stride: resource.stride,
                format: resource.format
            )
            resource.lastBackingDirtyEpoch = nil
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
        in pixels: inout [UInt8],
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
        in pixels: inout [UInt8],
        offset: Int,
        count: Int,
        format: PixelFormat
    ) {
        guard count > 0 else { return }
        precondition(offset >= 0 && count % 4 == 0 && offset <= pixels.count - count)
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
        for row in 0..<rectangle.height {
            let sourceOffset = (rectangle.y + row) * resource.stride + rectangle.x * 4
            let destinationOffset = row * width * 4
            let byteCount = rectangle.width * 4
            output.replaceSubrange(
                destinationOffset..<(destinationOffset + byteCount),
                with: resource.pixels[sourceOffset..<(sourceOffset + byteCount)]
            )
        }
        return output
    }

    private func copyBackingBytes(
        _ entries: [BackingEntry],
        logicalOffset: Int,
        count: Int,
        memory: PhysicalMemory,
        destination: inout [UInt8],
        destinationOffset: Int
    ) throws {
        guard logicalOffset >= 0,
              count >= 0,
              destinationOffset >= 0,
              destinationOffset <= destination.count,
              count <= destination.count - destinationOffset else {
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
                try memory.copyBytes(
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

    private static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
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
