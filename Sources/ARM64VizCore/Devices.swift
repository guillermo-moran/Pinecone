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
    func raise(line: UInt32, targetVCPU: Int)
    func clear(line: UInt32, targetVCPU: Int)
    func setEnabled(line: UInt32, enabled: Bool, targetVCPU: Int)
    func isEnabled(line: UInt32, targetVCPU: Int) -> Bool
    func peekPending(targetVCPU: Int) -> UInt32?
    func acknowledge(targetVCPU: Int) -> UInt32?
    func complete(line: UInt32, targetVCPU: Int)
    func activeLine(targetVCPU: Int) -> UInt32?
    func setTargetMask(line: UInt32, mask: UInt8)
    func targetMask(line: UInt32) -> UInt8
}

public extension InterruptController {
    func raise(line: UInt32, targetVCPU: Int) { raise(line: line) }
    func clear(line: UInt32, targetVCPU: Int) { clear(line: line) }
    func setEnabled(line: UInt32, enabled: Bool, targetVCPU: Int) {
        setEnabled(line: line, enabled: enabled)
    }
    func isEnabled(line: UInt32, targetVCPU: Int) -> Bool { isEnabled(line: line) }
    func peekPending(targetVCPU: Int) -> UInt32? { peekPending() }
    func acknowledge(targetVCPU: Int) -> UInt32? { acknowledge() }
    func complete(line: UInt32, targetVCPU: Int) { complete(line: line) }
    func activeLine(targetVCPU: Int) -> UInt32? { activeLine() }
    func setTargetMask(line: UInt32, mask: UInt8) {}
    func targetMask(line: UInt32) -> UInt8 { 1 }
}

public final class SimpleInterruptController: InterruptController {
    private static let initialLineCapacity = 64
    private let lock = NSRecursiveLock()
    private var pending: [UInt32] = []
    private var enabled: Set<UInt32> = []
    private var active: [UInt32] = []
    private var raisedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var activeRaiseDropCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var acknowledgedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var completedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var clearedCounts = [UInt64](repeating: 0, count: initialLineCapacity)
    private var targetedPending: [Int: [UInt32]] = [:]
    private var targetedEnabled: [Int: Set<UInt32>] = [:]
    private var targetedActive: [Int: [UInt32]] = [:]
    private var sharedTargetMasks: [UInt32: UInt8] = [:]
    private var wakeHandler: (() -> Void)?

    public init() {}

    public func setWakeHandler(_ handler: (() -> Void)?) {
        withLock { wakeHandler = handler }
    }

    public func raise(line: UInt32) {
        withLock {
            increment(&raisedCounts, line: line)
            if active.contains(line) {
                increment(&activeRaiseDropCounts, line: line)
            }
            // GIC interrupt state may be active and pending at the same time.
            // Preserve a reassertion until EOI instead of losing the event.
            if !pending.contains(line) {
                pending.append(line)
            }
            wakeHandler?()
        }
    }

    public func clear(line: UInt32) {
        withLock {
            increment(&clearedCounts, line: line)
            pending.removeAll { $0 == line }
        }
    }

    public func setEnabled(line: UInt32, enabled: Bool) {
        withLock {
            if enabled {
                self.enabled.insert(line)
            } else {
                self.enabled.remove(line)
            }
        }
    }

    public func isEnabled(line: UInt32) -> Bool {
        withLock { line < 16 || enabled.contains(line) }
    }

    public func peekPending() -> UInt32? {
        withLock { pendingLine(targetVCPU: 0) ?? globalPendingLine(targetVCPU: 0) }
    }

    public func acknowledge() -> UInt32? {
        withLock {
            if let line = acknowledgeTargeted(targetVCPU: 0) {
                return line
            }
            return acknowledgeGlobal(targetVCPU: 0)
        }
    }

    public func complete(line: UInt32) {
        withLock {
            active.removeAll { $0 == line }
            increment(&completedCounts, line: line)
        }
    }

    public func activeLine() -> UInt32? {
        withLock { targetedActive[0]?.first ?? active.first }
    }

    public func raise(line: UInt32, targetVCPU: Int) {
        withLock {
            increment(&raisedCounts, line: line)
            if targetedActive[targetVCPU, default: []].contains(line) {
                increment(&activeRaiseDropCounts, line: line)
            }
            if !targetedPending[targetVCPU, default: []].contains(line) {
                targetedPending[targetVCPU, default: []].append(line)
            }
            wakeHandler?()
        }
    }

    public func clear(line: UInt32, targetVCPU: Int) {
        withLock {
            increment(&clearedCounts, line: line)
            targetedPending[targetVCPU]?.removeAll { $0 == line }
        }
    }

    public func setEnabled(line: UInt32, enabled: Bool, targetVCPU: Int) {
        withLock {
            guard line >= 16 else { return }
            if enabled {
                targetedEnabled[targetVCPU, default: []].insert(line)
            } else {
                targetedEnabled[targetVCPU, default: []].remove(line)
            }
        }
    }

    public func isEnabled(line: UInt32, targetVCPU: Int) -> Bool {
        withLock {
            line < 16 ||
                targetedEnabled[targetVCPU, default: []].contains(line) ||
                enabled.contains(line)
        }
    }

    public func peekPending(targetVCPU: Int) -> UInt32? {
        withLock {
            if let line = pendingLine(targetVCPU: targetVCPU) { return line }
            return globalPendingLine(targetVCPU: targetVCPU)
        }
    }

    public func acknowledge(targetVCPU: Int) -> UInt32? {
        withLock {
            if let line = acknowledgeTargeted(targetVCPU: targetVCPU) { return line }
            return acknowledgeGlobal(targetVCPU: targetVCPU)
        }
    }

    public func complete(line: UInt32, targetVCPU: Int) {
        withLock {
            let wasTargeted = targetedActive[targetVCPU]?.contains(line) ?? false
            targetedActive[targetVCPU]?.removeAll { $0 == line }
            if wasTargeted {
                increment(&completedCounts, line: line)
            } else if active.contains(line) {
                complete(line: line)
            }
        }
    }

    public func activeLine(targetVCPU: Int) -> UInt32? {
        withLock {
            targetedActive[targetVCPU]?.first ?? active.first {
                (targetMask(line: $0) & Self.targetBit(for: targetVCPU)) != 0
            }
        }
    }

    public func setTargetMask(line: UInt32, mask: UInt8) {
        withLock {
            guard line >= 32 else { return }
            sharedTargetMasks[line] = mask
        }
    }

    public func targetMask(line: UInt32) -> UInt8 {
        withLock { line < 32 ? 1 : sharedTargetMasks[line, default: 1] }
    }

    public func diagnostics() -> InterruptControllerDiagnostics {
        withLock {
            let allPending = Set(pending + targetedPending.values.flatMap { $0 })
            let allActive = Set(active + targetedActive.values.flatMap { $0 })
            let allEnabled = enabled.union(targetedEnabled.values.reduce(into: Set<UInt32>()) {
                $0.formUnion($1)
            })
            return InterruptControllerDiagnostics(
                pendingLines: allPending.sorted(),
                activeLines: allActive.sorted(),
                enabledLines: allEnabled.sorted(),
                raisedCounts: eventCounts(from: raisedCounts),
                activeRaiseDropCounts: eventCounts(from: activeRaiseDropCounts),
                acknowledgedCounts: eventCounts(from: acknowledgedCounts),
                completedCounts: eventCounts(from: completedCounts),
                clearedCounts: eventCounts(from: clearedCounts)
            )
        }
    }

    public func reset() {
        withLock {
            pending.removeAll()
            enabled.removeAll()
            active.removeAll()
            targetedPending.removeAll(keepingCapacity: true)
            targetedEnabled.removeAll(keepingCapacity: true)
            targetedActive.removeAll(keepingCapacity: true)
            sharedTargetMasks.removeAll(keepingCapacity: true)
            resetCounts(&raisedCounts)
            resetCounts(&activeRaiseDropCounts)
            resetCounts(&acknowledgedCounts)
            resetCounts(&completedCounts)
            resetCounts(&clearedCounts)
        }
    }

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func eventCounts(from counts: [UInt64]) -> [InterruptLineEventCount] {
        counts.enumerated().compactMap { line, count in
            guard count != 0 else {
                return nil
            }
            return InterruptLineEventCount(line: UInt32(line), count: count)
        }
    }

    private func pendingLine(targetVCPU: Int) -> UInt32? {
        targetedPending[targetVCPU]?.first {
            isEnabled(line: $0, targetVCPU: targetVCPU) &&
                !(targetedActive[targetVCPU]?.contains($0) ?? false)
        }
    }

    private func globalPendingLine(targetVCPU: Int) -> UInt32? {
        let targetBit = Self.targetBit(for: targetVCPU)
        return pending.first {
            isEnabled(line: $0) &&
                !active.contains($0) &&
                (targetMask(line: $0) & targetBit) != 0
        }
    }

    private func acknowledgeTargeted(targetVCPU: Int) -> UInt32? {
        guard let line = pendingLine(targetVCPU: targetVCPU),
              let index = targetedPending[targetVCPU]?.firstIndex(of: line) else {
            return nil
        }
        targetedPending[targetVCPU]?.remove(at: index)
        if !(targetedActive[targetVCPU]?.contains(line) ?? false) {
            targetedActive[targetVCPU, default: []].append(line)
        }
        increment(&acknowledgedCounts, line: line)
        return line
    }

    private func acknowledgeGlobal(targetVCPU: Int) -> UInt32? {
        guard let line = globalPendingLine(targetVCPU: targetVCPU),
              let index = pending.firstIndex(of: line) else {
            return nil
        }
        pending.remove(at: index)
        if !active.contains(line) {
            active.append(line)
        }
        increment(&acknowledgedCounts, line: line)
        return line
    }

    private static func targetBit(for targetVCPU: Int) -> UInt8 {
        guard (0..<8).contains(targetVCPU) else { return 0 }
        return UInt8(1) << UInt8(targetVCPU)
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
    private let lock = NSRecursiveLock()
    private let virtualCPUCount: Int
    private var distributorEnabled = false
    private var cpuInterfaceEnabled: [Bool]
    private var priorityMask: [UInt8]
    private var currentVCPUIDProvider: () -> Int = { 0 }

    public init(
        name: String = "intc",
        base: GuestAddress,
        length: UInt64 = 0x20_000,
        cpuInterfaceOffset: UInt64 = 0x1_0000,
        interruptController: InterruptController,
        virtualCPUCount: Int = 1
    ) {
        precondition(virtualCPUCount > 0)
        self.name = name
        self.range = AddressRange(start: base, length: length)
        self.cpuInterfaceOffset = cpuInterfaceOffset
        self.interruptController = interruptController
        self.virtualCPUCount = virtualCPUCount
        self.cpuInterfaceEnabled = Array(repeating: false, count: virtualCPUCount)
        self.priorityMask = Array(repeating: 0xff, count: virtualCPUCount)
    }

    public func setCurrentVCPUIDProvider(_ provider: @escaping () -> Int) {
        withLock { currentVCPUIDProvider = provider }
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        withLock {
            if offset >= cpuInterfaceOffset {
                return readCPUInterface(offset: offset - cpuInterfaceOffset)
            }
            return readDistributor(offset: offset, width: width)
        }
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        withLock {
            if offset >= cpuInterfaceOffset {
                writeCPUInterface(offset: offset - cpuInterfaceOffset, value: value)
            } else {
                writeDistributor(offset: offset, width: width, value: value)
            }
        }
    }

    public func reset() {
        withLock {
            distributorEnabled = false
            cpuInterfaceEnabled = Array(repeating: false, count: virtualCPUCount)
            priorityMask = Array(repeating: 0xff, count: virtualCPUCount)
        }
    }

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func readDistributor(offset: UInt64, width: MMIOWidth) -> UInt64 {
        switch offset {
        case 0x000:
            return distributorEnabled ? 1 : 0
        case 0x004:
            let cpuCountField = UInt64(max(0, min(7, virtualCPUCount - 1))) << 5
            return 2 | cpuCountField
        case 0x100..<0x180:
            return enabledBitmap(offset: offset - 0x100)
        case 0x200..<0x280:
            return pendingBitmap(offset: offset - 0x200)
        case 0x800..<0xc00:
            return targetRegisterValue(offset: offset - 0x800, width: width)
        default:
            return 0
        }
    }

    private func writeDistributor(offset: UInt64, width: MMIOWidth, value: UInt64) {
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
        case 0x800..<0xc00:
            setTargetRegisterValue(offset: offset - 0x800, width: width, value: value)
        case 0xf00:
            sendSoftwareGeneratedInterrupt(value: UInt32(value & 0xffff_ffff))
        default:
            return
        }
    }

    private func readCPUInterface(offset: UInt64) -> UInt64 {
        let vcpuID = currentVCPUID
        switch offset {
        case 0x000:
            return cpuInterfaceEnabled[vcpuID] ? 1 : 0
        case 0x004:
            return UInt64(priorityMask[vcpuID])
        case 0x00c:
            return UInt64(interruptController.acknowledge(targetVCPU: vcpuID) ?? 1023)
        default:
            return 0
        }
    }

    private func writeCPUInterface(offset: UInt64, value: UInt64) {
        let vcpuID = currentVCPUID
        switch offset {
        case 0x000:
            cpuInterfaceEnabled[vcpuID] = (value & 0x1) != 0
        case 0x004:
            priorityMask[vcpuID] = UInt8(value & 0xff)
        case 0x010:
            interruptController.complete(
                line: UInt32(value & 0x3ff),
                targetVCPU: vcpuID
            )
        default:
            return
        }
    }

    private func enabledBitmap(offset: UInt64) -> UInt64 {
        var bitmap: UInt32 = 0
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where isEnabled(line: baseLine + UInt32(bit)) {
            bitmap |= UInt32(1) << UInt32(bit)
        }
        return UInt64(bitmap)
    }

    private func pendingBitmap(offset: UInt64) -> UInt64 {
        var bitmap: UInt32 = 0
        let baseLine = UInt32(offset / 4) * 32
        if let pending = interruptController.peekPending(targetVCPU: currentVCPUID),
           pending >= baseLine,
           pending < baseLine + 32 {
            bitmap |= UInt32(1) << UInt32(pending - baseLine)
        }
        return UInt64(bitmap)
    }

    private func targetRegisterValue(offset: UInt64, width: MMIOWidth) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<width.rawValue {
            let line = UInt32(offset) + UInt32(byte)
            let mask: UInt8
            if line < 32 {
                mask = UInt8(1) << UInt8(currentVCPUID)
            } else {
                mask = interruptController.targetMask(line: line)
            }
            value |= UInt64(mask) << UInt64(byte * 8)
        }
        return value
    }

    private func setTargetRegisterValue(offset: UInt64, width: MMIOWidth, value: UInt64) {
        let availableMask = UInt8((UInt16(1) << UInt16(virtualCPUCount)) - 1)
        for byte in 0..<width.rawValue {
            let line = UInt32(offset) + UInt32(byte)
            guard line >= 32 else { continue }
            let mask = UInt8(truncatingIfNeeded: value >> UInt64(byte * 8)) & availableMask
            interruptController.setTargetMask(line: line, mask: mask)
        }
    }

    private func setLines(offset: UInt64, bitmap: UInt32, enabled: Bool) {
        let baseLine = UInt32(offset / 4) * 32
        for bit in 0..<32 where (bitmap & (UInt32(1) << UInt32(bit))) != 0 {
            let line = baseLine + UInt32(bit)
            if line < 32 {
                interruptController.setEnabled(
                    line: line,
                    enabled: enabled,
                    targetVCPU: currentVCPUID
                )
            } else {
                interruptController.setEnabled(line: line, enabled: enabled)
            }
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

    private var currentVCPUID: Int {
        min(max(0, currentVCPUIDProvider()), virtualCPUCount - 1)
    }

    private func isEnabled(line: UInt32) -> Bool {
        line < 32
            ? interruptController.isEnabled(line: line, targetVCPU: currentVCPUID)
            : interruptController.isEnabled(line: line)
    }

    private func sendSoftwareGeneratedInterrupt(value: UInt32) {
        let line = value & 0xf
        let targetList = (value >> 16) & 0xff
        let targetFilter = (value >> 24) & 0x3
        let sender = currentVCPUID

        for id in 0..<virtualCPUCount {
            let selected: Bool
            switch targetFilter {
            case 0:
                selected = (targetList & (UInt32(1) << UInt32(id))) != 0
            case 1:
                selected = id != sender
            case 2:
                selected = id == sender
            default:
                selected = false
            }
            if selected {
                interruptController.raise(line: line, targetVCPU: id)
            }
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
    private let lock = NSRecursiveLock()
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
        withLock { output }
    }

    public var outputString: String {
        withLock { String(decoding: output, as: UTF8.self) }
    }

    public var receiveFIFOAvailableCapacity: Int {
        withLock { max(0, Self.fifoCapacity - receiveFIFO.count) }
    }

    public var receiveFIFOCount: Int {
        withLock { receiveFIFO.count }
    }

    public var rawInterruptStatusValue: UInt32 {
        withLock { rawInterruptStatus }
    }

    public var interruptMaskValue: UInt32 {
        withLock { interruptMask }
    }

    public func replaceOutput(_ bytes: [UInt8]) {
        withLock { output = bytes }
    }

    public func injectReceiveBytes(_ bytes: [UInt8]) {
        withLock {
            let accepted = bytes.prefix(receiveFIFOAvailableCapacity)
            receiveFIFO.append(contentsOf: accepted)
            if !accepted.isEmpty {
                rawInterruptStatus |= Self.receiveInterrupt
                updateInterruptLine()
            }
        }
    }

    public func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        withLock {
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
    }

    public func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        withLock {
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
    }

    public func reset() {
        withLock {
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
    }

    @inline(__always)
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
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

public final class VirtualFramebufferFrameLease: @unchecked Sendable {
    public let metadata: VirtualFramebufferFrameMetadata

    private let storageOwner: AnyObject
    private let baseAddress: UnsafeRawPointer
    private let byteCount: Int
    private let releaseHandler: @Sendable () -> Void

    init(
        metadata: VirtualFramebufferFrameMetadata,
        storageOwner: AnyObject,
        baseAddress: UnsafeRawPointer,
        byteCount: Int,
        releaseHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.metadata = metadata
        self.storageOwner = storageOwner
        self.baseAddress = baseAddress
        self.byteCount = byteCount
        self.releaseHandler = releaseHandler
    }

    deinit {
        releaseHandler()
    }

    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        defer { _fixLifetime(storageOwner) }
        return try body(UnsafeRawBufferPointer(
            start: baseAddress,
            count: byteCount
        ))
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
