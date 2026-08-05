import Foundation

public struct InterruptLineEventCount: Codable, Equatable {
    public let line: UInt32
    public let count: UInt64

    public init(line: UInt32, count: UInt64) {
        self.line = line
        self.count = count
    }
}

public struct InterruptControllerDiagnostics: Codable, Equatable {
    public let pendingLines: [UInt32]
    public let activeLines: [UInt32]
    public let enabledLines: [UInt32]
    public let raisedCounts: [InterruptLineEventCount]
    public let activeRaiseDropCounts: [InterruptLineEventCount]
    public let acknowledgedCounts: [InterruptLineEventCount]
    public let completedCounts: [InterruptLineEventCount]
    public let clearedCounts: [InterruptLineEventCount]

    public init(
        pendingLines: [UInt32],
        activeLines: [UInt32],
        enabledLines: [UInt32],
        raisedCounts: [InterruptLineEventCount],
        activeRaiseDropCounts: [InterruptLineEventCount],
        acknowledgedCounts: [InterruptLineEventCount],
        completedCounts: [InterruptLineEventCount],
        clearedCounts: [InterruptLineEventCount]
    ) {
        self.pendingLines = pendingLines
        self.activeLines = activeLines
        self.enabledLines = enabledLines
        self.raisedCounts = raisedCounts
        self.activeRaiseDropCounts = activeRaiseDropCounts
        self.acknowledgedCounts = acknowledgedCounts
        self.completedCounts = completedCounts
        self.clearedCounts = clearedCounts
    }
}

public protocol InterruptController: AnyObject {
    func raise(line: UInt32)
    func clear(line: UInt32)
    func setEnabled(line: UInt32, enabled: Bool)
    func isEnabled(line: UInt32) -> Bool
    func peekPending() -> UInt32?
    func acknowledge() -> UInt32?
    func complete(line: UInt32)
    func activeLine() -> UInt32?
    func diagnostics() -> InterruptControllerDiagnostics
    func reset()
}

public final class SimpleInterruptController: InterruptController {
    private static let initialLineCapacity = 64
    private var pending: [UInt32] = []
    private var enabled: Set<UInt32> = []
    private var active: [UInt32] = []
    private var raisedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var activeRaiseDropCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var acknowledgedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var completedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var clearedCounts = [UInt64](repeating: 0, count: initialLineCapacity)

    public init() {}

    public func raise(line: UInt32) {
        increment(&raisedCounts, line: line)
        guard !active.contains(line) else {
            increment(&activeRaiseDropCounts, line: line)
            return
        }
        if !pending.contains(line) {
            pending.append(line)
        }
    }

    public func clear(line: UInt32) {
        increment(&clearedCounts, line: line)
        pending.removeAll { $0 == line }
    }

    public func setEnabled(line: UInt32, enabled: Bool) {
        if enabled {
            self.enabled.insert(line)
        } else {
            self.enabled.remove(line)
        }
    }

    public func isEnabled(line: UInt32) -> Bool {
        enabled.contains(line)
    }

    public func peekPending() -> UInt32? {
        pending.first { enabled.contains($0) && !active.contains($0) }
    }

    public func acknowledge() -> UInt32? {
        guard let line = peekPending(), let index = pending.firstIndex(of: line) else {
            return nil
        }
        pending.remove(at: index)
        if !active.contains(line) {
            active.append(line)
        }
        increment(&acknowledgedCounts, line: line)
        return line
    }

    public func complete(line: UInt32) {
        active.removeAll { $0 == line }
        increment(&completedCounts, line: line)
    }

    public func activeLine() -> UInt32? {
        active.first
    }

    public func diagnostics() -> InterruptControllerDiagnostics {
        InterruptControllerDiagnostics(
            pendingLines: pending.sorted(),
            activeLines: active.sorted(),
            enabledLines: enabled.sorted(),
            raisedCounts: eventCounts(from: raisedCounts),
            activeRaiseDropCounts: eventCounts(from: activeRaiseDropCounts),
            acknowledgedCounts: eventCounts(from: acknowledgedCounts),
            completedCounts: eventCounts(from: completedCounts),
            clearedCounts: eventCounts(from: clearedCounts)
        )
    }

    public func reset() {
        pending.removeAll()
        enabled.removeAll()
        active.removeAll()
        resetCounts(&raisedCounts)
        resetCounts(&activeRaiseDropCounts)
        resetCounts(&acknowledgedCounts)
        resetCounts(&completedCounts)
        resetCounts(&clearedCounts)
    }

    private func eventCounts(from counts: [UInt64]) -> [InterruptLineEventCount] {
        counts.enumerated().compactMap { line, count in
            guard count != 0 else {
                return nil
            }
            return InterruptLineEventCount(line: UInt32(line), count: count)
        }
    }

    @inline(__always)
    private func increment(_ counts: inout [UInt64], line: UInt32) {
        let index = Int(line)
        if index >= counts.count {
            counts.append(contentsOf: repeatElement(0, count: index - counts.count + 1))
        }
        counts[index] &+= 1
    }

    private func resetCounts(_ counts: inout [UInt64]) {
        for index in counts.indices {
            counts[index] = 0
        }
    }
}

public final class VirtualGIC: MMIODevice {
    public let name: String
    public let range: AddressRange
    public let cpuInterfaceOffset: UInt64
    private let interruptController: InterruptController
    private var distributorEnabled = false
    private var cpuInterfaceEnabled = false
    private var priorityMask: UInt8 = 0xff

    public init(
        name: String = "intc",
        base: GuestAddress,
        length: UInt64 = 0x20_000,
        cpuInterfaceOffset: UInt64 = 0x1_0000,
        interruptController: InterruptController
    ) {
        self.name = name
        self.range = AddressRange(start: base, length: length)
        self.cpuInterfaceOffset = cpuInterfaceOffset
        self.interruptController = interruptController
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        if offset >= cpuInterfaceOffset {
            return readCPUInterface(offset: offset - cpuInterfaceOffset)
        }
        return readDistributor(offset: offset)
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        if offset >= cpuInterfaceOffset {
            writeCPUInterface(offset: offset - cpuInterfaceOffset, value: value)
        } else {
            writeDistributor(offset: offset, value: value)
        }
    }

    public func reset() {
        distributorEnabled = false
        cpuInterfaceEnabled = false
        priorityMask = 0xff
    }

    private func readDistributor(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x000:
            return distributorEnabled ? 1 : 0
        case 0x004:
            return 0
        case 0x100..<0x180:
            return enabledBitmap(offset: offset - 0x100)
        case 0x200..<0x280:
            return pendingBitmap(offset: offset - 0x200)
        default:
            return 0
        }
    }

    private func writeDistributor(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x000:
            distributorEnabled = (value & 0x1) != 0
        case 0x100..<0x180:
            setLines(offset: offset - 0x100, bitmap: UInt32(value & 0xffff_ffff), enabled: true)
        case 0x180..<0x200:
            setLines(offset: offset - 0x180, bitmap: UInt32(value & 0xffff_ffff), enabled: false)
        case 0x200..<0x280:
            raiseLines(offset: offset - 0x200, bitmap: UInt32(value & 0xffff_ffff))
        case 0x280..<0x300:
            clearLines(offset: offset - 0x280, bitmap: UInt32(value & 0xffff_ffff))
        default:
            return
        }
    }

    private func readCPUInterface(offset: UInt64) -> UInt64 {
        switch offset {
        case 0x000:
            return cpuInterfaceEnabled ? 1 : 0
        case 0x004:
            return UInt64(priorityMask)
        case 0x00c:
            return UInt64(interruptController.acknowledge() ?? 1023)
        default:
            return 0
        }
    }

    private func writeCPUInterface(offset: UInt64, value: UInt64) {
        switch offset {
        case 0x000:
            cpuInterfaceEnabled = (value & 0x1) != 0
        case 0x004:
            priorityMask = UInt8(value & 0xff)
        case 0x010:
            interruptController.complete(line: UInt32(value & 0x3ff))
        default:
            return
        }
    }

    private func enabledBitmap(offset: UInt64) -> UInt64 {
        var bitmap: UInt32 = 0
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where interruptController.isEnabled(line: baseLine + UInt32(bit)) {
            bitmap |= UInt32(1) << UInt32(bit)
        }
        return UInt64(bitmap)
    }

    private func pendingBitmap(offset: UInt64) -> UInt64 {
        var bitmap: UInt32 = 0
        let baseLine = UInt32(offset / 4) * 32
        if let pending = interruptController.peekPending(), pending >= baseLine, pending < baseLine + 32 {
            bitmap |= UInt32(1) << UInt32(pending - baseLine)
        }
        return UInt64(bitmap)
    }

    private func setLines(offset: UInt64, bitmap: UInt32, enabled: Bool) {
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where (bitmap & (UInt32(1) << UInt32(bit))) != 0 {
            interruptController.setEnabled(line: baseLine + UInt32(bit), enabled: enabled)
        }
    }

    private func raiseLines(offset: UInt64, bitmap: UInt32) {
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where (bitmap & (UInt32(1) << UInt32(bit))) != 0 {
            interruptController.raise(line: baseLine + UInt32(bit))
        }
    }

    private func clearLines(offset: UInt64, bitmap: UInt32) {
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where (bitmap & (UInt32(1) << UInt32(bit))) != 0 {
            interruptController.clear(line: baseLine + UInt32(bit))
        }
    }
}

public final class VirtualUART: MMIODevice {
    public static let receiveInterrupt: UInt32 = 1 << 4
    public static let transmitInterrupt: UInt32 = 1 << 5
    private static let fifoCapacity = 16

    public let name: String
    public let range: AddressRange
    public let interruptLine: UInt32?
    public var onByte: ((UInt8) -> Void)?
    private let interruptController: InterruptController?
    private var output: [UInt8] = []
    private var receiveFIFO: [UInt8] = []
    private var receiveStatusErrorClear: UInt32 = 0
    private var integerBaudRateDivisor: UInt32 = 0
    private var fractionalBaudRateDivisor: UInt32 = 0
    private var lineControl: UInt32 = 0
    private var control: UInt32 = 0x0300
    private var interruptFIFOLevelSelect: UInt32 = 0x12
    private var interruptMask: UInt32 = 0
    private var rawInterruptStatus: UInt32 = 0
    private var dmaControl: UInt32 = 0

    public init(
        name: String = "uart0",
        base: GuestAddress,
        length: UInt64 = 0x1000,
        interruptLine: UInt32? = nil,
        interruptController: InterruptController? = nil,
        onByte: ((UInt8) -> Void)? = nil
    ) {
        self.name = name
        self.range = AddressRange(start: base, length: length)
        self.interruptLine = interruptLine
        self.interruptController = interruptController
        self.onByte = onByte
    }

    public var outputBytes: [UInt8] {
        output
    }

    public var outputString: String {
        String(decoding: output, as: UTF8.self)
    }

    public var receiveFIFOAvailableCapacity: Int {
        max(0, Self.fifoCapacity - receiveFIFO.count)
    }

    public func replaceOutput(_ bytes: [UInt8]) {
        output = bytes
    }

    public func injectReceiveBytes(_ bytes: [UInt8]) {
        let accepted = bytes.prefix(receiveFIFOAvailableCapacity)
        receiveFIFO.append(contentsOf: accepted)
        if !accepted.isEmpty {
            rawInterruptStatus |= Self.receiveInterrupt
            updateInterruptLine()
        }
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        switch offset {
        case 0x00:
            if receiveFIFO.isEmpty {
                return 0
            }
            let byte = receiveFIFO.removeFirst()
            if receiveFIFO.isEmpty {
                rawInterruptStatus &= ~Self.receiveInterrupt
                updateInterruptLine()
            }
            return UInt64(byte)
        case 0x04:
            return UInt64(receiveStatusErrorClear)
        case 0x18:
            var flags: UInt64 = 0
            if receiveFIFO.isEmpty {
                flags |= 1 << 4
            }
            if receiveFIFO.count >= Self.fifoCapacity {
                flags |= 1 << 6
            }
            flags |= 1 << 7
            return flags
        case 0x20:
            return 0
        case 0x24:
            return UInt64(integerBaudRateDivisor)
        case 0x28:
            return UInt64(fractionalBaudRateDivisor)
        case 0x2c:
            return UInt64(lineControl)
        case 0x30:
            return UInt64(control)
        case 0x34:
            return UInt64(interruptFIFOLevelSelect)
        case 0x38:
            return UInt64(interruptMask)
        case 0x3c:
            return UInt64(rawInterruptStatus)
        case 0x40:
            return UInt64(rawInterruptStatus & interruptMask)
        case 0x44:
            return 0
        case 0x48:
            return UInt64(dmaControl)
        case 0xfe0:
            return 0x11
        case 0xfe4:
            return 0x10
        case 0xfe8:
            return 0x14
        case 0xfec:
            return 0x00
        case 0xff0:
            return 0x0d
        case 0xff4:
            return 0xf0
        case 0xff8:
            return 0x05
        case 0xffc:
            return 0xb1
        default:
            return 0
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        switch offset {
        case 0x00:
            let byte = UInt8(value & 0xff)
            output.append(byte)
            rawInterruptStatus |= Self.transmitInterrupt
            onByte?(byte)
            updateInterruptLine()
        case 0x04:
            receiveStatusErrorClear = 0
        case 0x20:
            return
        case 0x24:
            integerBaudRateDivisor = UInt32(value & 0xffff)
        case 0x28:
            fractionalBaudRateDivisor = UInt32(value & 0x3f)
        case 0x2c:
            lineControl = UInt32(value & 0xff)
        case 0x30:
            control = UInt32(value & 0xffff)
        case 0x34:
            interruptFIFOLevelSelect = UInt32(value & 0x3f)
        case 0x38:
            interruptMask = UInt32(value & 0x7ff)
            updateInterruptLine()
        case 0x44:
            rawInterruptStatus &= ~UInt32(value & 0x7ff)
            updateInterruptLine()
        case 0x48:
            dmaControl = UInt32(value & 0x7)
        default:
            return
        }
    }

    public func reset() {
        output.removeAll()
        receiveFIFO.removeAll()
        receiveStatusErrorClear = 0
        integerBaudRateDivisor = 0
        fractionalBaudRateDivisor = 0
        lineControl = 0
        control = 0x0300
        interruptFIFOLevelSelect = 0x12
        interruptMask = 0
        rawInterruptStatus = 0
        dmaControl = 0
        updateInterruptLine()
    }

    private func updateInterruptLine() {
        guard let interruptLine, let interruptController else {
            return
        }
        if (rawInterruptStatus & interruptMask) != 0 {
            interruptController.raise(line: interruptLine)
        } else {
            interruptController.clear(line: interruptLine)
        }
    }
}

public struct VirtualFramebufferDamage: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        precondition(x >= 0 && y >= 0 && width >= 0 && height >= 0)
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var byteCountBGRA8: Int {
        width * height * 4
    }
}

public struct VirtualFramebufferFrameMetadata: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let bytesPerPixel: Int
    public let generation: UInt64
    public let commitTimestampNanoseconds: UInt64
    public let damage: [VirtualFramebufferDamage]
    public let hasStableStorage: Bool

    public init(
        width: Int,
        height: Int,
        stride: Int,
        bytesPerPixel: Int,
        generation: UInt64,
        commitTimestampNanoseconds: UInt64,
        damage: [VirtualFramebufferDamage],
        hasStableStorage: Bool = false
    ) {
        self.width = width
        self.height = height
        self.stride = stride
        self.bytesPerPixel = bytesPerPixel
        self.generation = generation
        self.commitTimestampNanoseconds = commitTimestampNanoseconds
        self.damage = damage
        self.hasStableStorage = hasStableStorage
    }

    public var damagedByteCount: Int {
        damage.reduce(0) { $0 + $1.width * $1.height * bytesPerPixel }
    }
}

public struct VirtualFramebufferSnapshot: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let bytesPerPixel: Int
    public let generation: UInt64
    public let commitTimestampNanoseconds: UInt64
    public let damage: [VirtualFramebufferDamage]
    public let pixels: [UInt8]

    public init(
        width: Int,
        height: Int,
        stride: Int,
        bytesPerPixel: Int,
        generation: UInt64,
        commitTimestampNanoseconds: UInt64 = 0,
        damage: [VirtualFramebufferDamage]? = nil,
        pixels: [UInt8]
    ) {
        self.width = width
        self.height = height
        self.stride = stride
        self.bytesPerPixel = bytesPerPixel
        self.generation = generation
        self.commitTimestampNanoseconds = commitTimestampNanoseconds
        self.damage = damage ?? [VirtualFramebufferDamage(
            x: 0,
            y: 0,
            width: width,
            height: height
        )]
        self.pixels = pixels
    }
}

public final class VirtualFramebuffer: MMIODevice {
    public let name: String
    public let range: AddressRange
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    private let pixelLock = NSLock()
    private var pixels: [UInt8]
    private var generation: UInt64 = 0

    public init(
        name: String = "framebuffer0",
        base: GuestAddress,
        width: Int,
        height: Int,
        bytesPerPixel: Int = 4
    ) {
        precondition(width > 0 && height > 0 && bytesPerPixel > 0)
        self.name = name
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        self.pixels = Array(repeating: 0, count: width * height * bytesPerPixel)
        self.range = AddressRange(start: base, length: UInt64(pixels.count))
    }

    public var stride: Int {
        width * bytesPerPixel
    }

    public var pixelBytes: [UInt8] {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        return pixels
    }

    public func snapshot(afterGeneration previousGeneration: UInt64? = nil) -> VirtualFramebufferSnapshot? {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        if let previousGeneration, previousGeneration == generation {
            return nil
        }
        return VirtualFramebufferSnapshot(
            width: width,
            height: height,
            stride: stride,
            bytesPerPixel: bytesPerPixel,
            generation: generation,
            pixels: pixels
        )
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        let index = try checkedIndex(offset: offset, width: width.rawValue)
        var value: UInt64 = 0
        for byteIndex in 0..<width.rawValue {
            value |= UInt64(pixels[index + byteIndex]) << UInt64(byteIndex * 8)
        }
        return value
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        let index = try checkedIndex(offset: offset, width: width.rawValue)
        for byteIndex in 0..<width.rawValue {
            pixels[index + byteIndex] = UInt8((value >> UInt64(byteIndex * 8)) & 0xff)
        }
        generation &+= 1
    }

    public func reset() {
        pixelLock.lock()
        defer { pixelLock.unlock() }
        pixels = Array(repeating: 0, count: pixels.count)
        generation &+= 1
    }

    private func checkedIndex(offset: UInt64, width: Int) throws -> Int {
        guard offset <= UInt64(Int.max), Int(offset) + width <= pixels.count else {
            throw VMError.deviceError("\(name) framebuffer access out of range")
        }
        return Int(offset)
    }
}

public struct TouchEvent: Codable, Equatable {
    public let x: UInt32
    public let y: UInt32
    public let isDown: Bool

    public init(x: UInt32, y: UInt32, isDown: Bool) {
        self.x = x
        self.y = y
        self.isDown = isDown
    }
}

public final class VirtualTouchInput: MMIODevice {
    public let name: String
    public let range: AddressRange
    private var queue: [TouchEvent] = []
    private var current = TouchEvent(x: 0, y: 0, isDown: false)

    public init(name: String = "touch0", base: GuestAddress, length: UInt64 = 0x1000) {
        self.name = name
        self.range = AddressRange(start: base, length: length)
    }

    public func enqueue(_ event: TouchEvent) {
        queue.append(event)
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        if offset == 0x0c, !queue.isEmpty {
            return 1
        }

        switch offset {
        case 0x00:
            return UInt64(current.x)
        case 0x04:
            return UInt64(current.y)
        case 0x08:
            return current.isDown ? 1 : 0
        case 0x0c:
            return 0
        default:
            return 0
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        guard offset == 0x0c, value == 1, !queue.isEmpty else { return }
        current = queue.removeFirst()
    }

    public func reset() {
        queue.removeAll()
        current = TouchEvent(x: 0, y: 0, isDown: false)
    }
}

public final class VirtualBlockDevice: MMIODevice {
    public let name: String
    public let range: AddressRange
    public let blockSize: Int
    private var storage: [UInt8]

    public init(
        name: String = "block0",
        base: GuestAddress,
        storageSize: Int = 1024 * 1024,
        blockSize: Int = 512
    ) {
        precondition(storageSize > 0 && blockSize > 0)
        self.name = name
        self.blockSize = blockSize
        self.storage = Array(repeating: 0, count: storageSize)
        self.range = AddressRange(start: base, length: UInt64(0x100 + storageSize))
    }

    public var storageBytes: [UInt8] {
        storage
    }

    public func replaceStorage(_ bytes: [UInt8]) throws {
        guard bytes.count <= storage.count else {
            throw VMError.deviceError("\(name) storage image \(bytes.count) exceeds capacity \(storage.count)")
        }
        storage = Array(repeating: 0, count: storage.count)
        storage.replaceSubrange(0..<bytes.count, with: bytes)
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        switch offset {
        case 0x00:
            return UInt64(storage.count)
        case 0x08:
            return UInt64(blockSize)
        default:
            guard offset >= 0x100 else { return 0 }
            let index = try storageIndex(offset: offset, width: width.rawValue)
            var value: UInt64 = 0
            for byteIndex in 0..<width.rawValue {
                value |= UInt64(storage[index + byteIndex]) << UInt64(byteIndex * 8)
            }
            return value
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        guard offset >= 0x100 else { return }
        let index = try storageIndex(offset: offset, width: width.rawValue)
        for byteIndex in 0..<width.rawValue {
            storage[index + byteIndex] = UInt8((value >> UInt64(byteIndex * 8)) & 0xff)
        }
    }

    public func reset() {
        storage = Array(repeating: 0, count: storage.count)
    }

    private func storageIndex(offset: UInt64, width: Int) throws -> Int {
        let storageOffset = offset - 0x100
        guard storageOffset <= UInt64(Int.max), Int(storageOffset) + width <= storage.count else {
            throw VMError.deviceError("\(name) storage access out of range")
        }
        return Int(storageOffset)
    }
}

public final class VirtualNetworkDevice: MMIODevice {
    public let name: String
    public let range: AddressRange
    private var txBytes: [UInt8] = []
    private var rxBytes: [UInt8] = []

    public init(name: String = "net0", base: GuestAddress, length: UInt64 = 0x1000) {
        self.name = name
        self.range = AddressRange(start: base, length: length)
    }

    public var transmittedBytes: [UInt8] {
        txBytes
    }

    public func injectReceiveBytes(_ bytes: [UInt8]) {
        rxBytes.append(contentsOf: bytes)
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        switch offset {
        case 0x00:
            return rxBytes.isEmpty ? 0 : UInt64(rxBytes.removeFirst())
        case 0x08:
            return rxBytes.isEmpty ? 0 : 1
        default:
            return 0
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        guard offset == 0 else { return }
        txBytes.append(UInt8(value & 0xff))
    }

    public func reset() {
        txBytes.removeAll()
        rxBytes.removeAll()
    }
}
