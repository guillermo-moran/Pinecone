import Dispatch
import ARM64VizNative

public enum ARM64ExceptionSource: String, Codable, Equatable {
    case supervisorCall
    case breakpoint
    case translationFault
    case irq
}

public struct ARM64ExceptionTraceEntry: Codable, Equatable {
    public let source: ARM64ExceptionSource
    public let exceptionClass: ARM64ExceptionClass
    public let iss: UInt64
    public let syndrome: UInt64
    public let returnAddress: GuestAddress
    public let faultAddress: GuestAddress?
    public let vectorBase: GuestAddress
    public let vectorOffset: UInt64
    public let vectorAddress: GuestAddress
    public let previousPState: UInt64
    public let newPState: UInt64
    public let currentEL: Int
    public let access: GuestMemoryAccessKind?
    public let faultLevel: Int?
    public let faultStatusCode: ARM64FaultStatusCode?
    public let irqLine: UInt32?

    public init(
        source: ARM64ExceptionSource,
        exceptionClass: ARM64ExceptionClass,
        iss: UInt64,
        syndrome: UInt64,
        returnAddress: GuestAddress,
        faultAddress: GuestAddress?,
        vectorBase: GuestAddress,
        vectorOffset: UInt64,
        vectorAddress: GuestAddress,
        previousPState: UInt64,
        newPState: UInt64,
        currentEL: Int,
        access: GuestMemoryAccessKind? = nil,
        faultLevel: Int? = nil,
        faultStatusCode: ARM64FaultStatusCode? = nil,
        irqLine: UInt32? = nil
    ) {
        self.source = source
        self.exceptionClass = exceptionClass
        self.iss = iss
        self.syndrome = syndrome
        self.returnAddress = returnAddress
        self.faultAddress = faultAddress
        self.vectorBase = vectorBase
        self.vectorOffset = vectorOffset
        self.vectorAddress = vectorAddress
        self.previousPState = previousPState
        self.newPState = newPState
        self.currentEL = currentEL
        self.access = access
        self.faultLevel = faultLevel
        self.faultStatusCode = faultStatusCode
        self.irqLine = irqLine
    }
}

public struct ARM64SystemRegisterTraceEntry: Codable, Equatable {
    public let step: Int
    public let pc: GuestAddress
    public let register: String
    public let key: ARM64SystemRegisterKey
    public let previousValue: UInt64
    public let newValue: UInt64

    public init(
        step: Int,
        pc: GuestAddress,
        key: ARM64SystemRegisterKey,
        previousValue: UInt64,
        newValue: UInt64
    ) {
        self.step = step
        self.pc = pc
        self.register = key.description
        self.key = key
        self.previousValue = previousValue
        self.newValue = newValue
    }
}

public struct ARM64SystemRegisterReadTraceEntry: Codable, Equatable {
    public let step: Int
    public let pc: GuestAddress
    public let register: String
    public let key: ARM64SystemRegisterKey
    public let value: UInt64

    public init(
        step: Int,
        pc: GuestAddress,
        key: ARM64SystemRegisterKey,
        value: UInt64
    ) {
        self.step = step
        self.pc = pc
        self.register = key.description
        self.key = key
        self.value = value
    }
}

public struct ARM64ExceptionStorm: Codable, Equatable {
    public let entry: ARM64ExceptionTraceEntry
    public let count: Int

    public init(entry: ARM64ExceptionTraceEntry, count: Int) {
        self.entry = entry
        self.count = count
    }
}

public enum ARM64ExecutionStateTransitionReason: String, Codable, Equatable {
    case instruction
    case irq
}

public struct ARM64ExecutionStateTraceEntry: Codable, Equatable {
    public let step: Int
    public let reason: ARM64ExecutionStateTransitionReason
    public let previousPC: GuestAddress
    public let newPC: GuestAddress
    public let previousEL: Int
    public let newEL: Int
    public let previousPState: UInt64
    public let newPState: UInt64

    public init(
        step: Int,
        reason: ARM64ExecutionStateTransitionReason,
        previousPC: GuestAddress,
        newPC: GuestAddress,
        previousEL: Int,
        newEL: Int,
        previousPState: UInt64,
        newPState: UInt64
    ) {
        self.step = step
        self.reason = reason
        self.previousPC = previousPC
        self.newPC = newPC
        self.previousEL = previousEL
        self.newEL = newEL
        self.previousPState = previousPState
        self.newPState = newPState
    }
}

public enum MMIOTraceAccessKind: String, Codable, Equatable, Hashable {
    case read
    case write
}

public enum GuestMemoryTraceAccessKind: String, Codable, Equatable {
    case read
    case write
}

public struct GuestMemoryTraceEntry: Codable, Equatable {
    public let step: Int
    public let pc: GuestAddress
    public let exceptionLevel: Int
    public let access: GuestMemoryTraceAccessKind
    public let virtualAddress: GuestAddress
    public let physicalAddress: GuestAddress
    public let width: Int
    public let value: UInt64

    public init(
        step: Int,
        pc: GuestAddress,
        exceptionLevel: Int,
        access: GuestMemoryTraceAccessKind,
        virtualAddress: GuestAddress,
        physicalAddress: GuestAddress,
        width: Int,
        value: UInt64
    ) {
        self.step = step
        self.pc = pc
        self.exceptionLevel = exceptionLevel
        self.access = access
        self.virtualAddress = virtualAddress
        self.physicalAddress = physicalAddress
        self.width = width
        self.value = value
    }
}

public struct MMIOTraceEntry: Codable, Equatable {
    public let step: Int
    public let pc: GuestAddress
    public let deviceName: String
    public let access: MMIOTraceAccessKind
    public let address: GuestAddress
    public let offset: UInt64
    public let width: Int
    public let value: UInt64

    public init(
        step: Int,
        pc: GuestAddress,
        deviceName: String,
        access: MMIOTraceAccessKind,
        address: GuestAddress,
        offset: UInt64,
        width: Int,
        value: UInt64
    ) {
        self.step = step
        self.pc = pc
        self.deviceName = deviceName
        self.access = access
        self.address = address
        self.offset = offset
        self.width = width
        self.value = value
    }
}

public struct MMIOAccessCounter: Codable, Equatable {
    public let deviceName: String
    public let access: MMIOTraceAccessKind
    public let offset: UInt64
    public let count: UInt64

    public init(deviceName: String, access: MMIOTraceAccessKind, offset: UInt64, count: UInt64) {
        self.deviceName = deviceName
        self.access = access
        self.offset = offset
        self.count = count
    }
}

private struct MMIOAccessCounterKey: Hashable {
    let deviceName: String
    let access: MMIOTraceAccessKind
    let offset: UInt64
}

private struct ARM64ExceptionSignature: Equatable {
    let source: ARM64ExceptionSource
    let exceptionClass: ARM64ExceptionClass
    let iss: UInt64
    let returnAddress: GuestAddress
    let vectorAddress: GuestAddress
}

public enum RunStopReason: Equatable, CustomStringConvertible {
    case halted
    case yielded
    case breakpoint(GuestAddress)
    case maxSteps(Int)
    case exceptionLoop(GuestAddress)
    case exceptionStorm(GuestAddress, Int)
    case el0Entry(GuestAddress)
    case el0Fault(GuestAddress, GuestAddress?)
    case guestMemoryWrite(GuestAddress, GuestAddress)
    case uartOutput(UInt8)
    case uartOutputContains(String)

    public var description: String {
        switch self {
        case .halted:
            return "halted"
        case .yielded:
            return "yielded"
        case let .breakpoint(address):
            return "breakpoint(\(address.hexString))"
        case let .maxSteps(count):
            return "maxSteps(\(count))"
        case let .exceptionLoop(address):
            return "exceptionLoop(\(address.hexString))"
        case let .exceptionStorm(address, count):
            return "exceptionStorm(\(address.hexString),\(count))"
        case let .el0Entry(address):
            return "el0Entry(\(address.hexString))"
        case let .el0Fault(returnAddress, faultAddress):
            if let faultAddress {
                return "el0Fault(return=\(returnAddress.hexString),fault=\(faultAddress.hexString))"
            }
            return "el0Fault(return=\(returnAddress.hexString))"
        case let .guestMemoryWrite(virtualAddress, physicalAddress):
            return "guestMemoryWrite(virtual=\(virtualAddress.hexString),physical=\(physicalAddress.hexString))"
        case let .uartOutput(byte):
            return "uartOutput(0x\(String(byte, radix: 16)))"
        case let .uartOutputContains(marker):
            return "uartOutputContains(\(marker))"
        }
    }
}

public struct RunResult: Equatable {
    public let steps: Int
    public let stopReason: RunStopReason
    public let lastException: ARM64ExceptionTraceEntry?

    public init(steps: Int, stopReason: RunStopReason, lastException: ARM64ExceptionTraceEntry? = nil) {
        self.steps = steps
        self.stopReason = stopReason
        self.lastException = lastException
    }
}

public protocol VirtualMachineBackend: AnyObject {
    var name: String { get }
    func run(vm: VirtualMachine, maxSteps: Int) throws -> RunResult
    func invalidateCodeCache(physicalAddress: GuestAddress, byteCount: UInt64)
    func invalidateTranslationCache(for vm: VirtualMachine)
    func invalidateTranslations(for vm: VirtualMachine, matching invalidation: AVZNativeTLBI)
}

public extension VirtualMachineBackend {
    func invalidateTranslationCache(for vm: VirtualMachine) {}
    func invalidateTranslations(for vm: VirtualMachine, matching invalidation: AVZNativeTLBI) {
        invalidateTranslationCache(for: vm)
    }
}

public final class VirtualMachine {
    public static let physicalTimerIRQ: UInt32 = 30
    public static let virtualTimerIRQ: UInt32 = 27

    private struct VirtualCPURuntime {
        var architecture: VirtualCPUArchitecturalState
        var translationCache: [ARM64TranslationCacheKey: GuestAddress] = [:]
        var cachedSCTLR_EL1: UInt64 = 0
        var cachedTCR_EL1: UInt64 = 0
        var cachedTTBR0_EL1: UInt64 = 0
        var cachedTTBR1_EL1: UInt64 = 0
        var nextGenericTimerRefreshTick: UInt64 = 0
    }

    public let memory: PhysicalMemory
    public let mmio: MMIOBus
    public let interruptController: InterruptController
    public let backend: VirtualMachineBackend
    public let virtualCPUCount: Int
    public var cpu: CPUState
    public var systemRegisters: ARM64SystemRegisterBank
    public private(set) var activeVCPUID: Int
    public var virtualCPUQuantumSteps: Int
    public var breakpoints: Set<GuestAddress>
    public var breakpointSkipCounts: [GuestAddress: Int]
    public var bootDevices: [BootDeviceDescriptor]
    public var instructionTrace: [InstructionTraceEntry] {
        orderedInstructionTrace()
    }
    public private(set) var exceptionTrace: [ARM64ExceptionTraceEntry]
    public private(set) var systemRegisterTrace: [ARM64SystemRegisterTraceEntry]
    public private(set) var systemRegisterReadTrace: [ARM64SystemRegisterReadTraceEntry]
    public private(set) var executionStateTrace: [ARM64ExecutionStateTraceEntry]
    public private(set) var mmioTrace: [MMIOTraceEntry]
    public var mmioAccessCounters: [MMIOAccessCounter] {
        mmioAccessCounterStorage
            .map { key, count in
                MMIOAccessCounter(deviceName: key.deviceName, access: key.access, offset: key.offset, count: count)
            }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                if $0.deviceName != $1.deviceName {
                    return $0.deviceName < $1.deviceName
                }
                if $0.access.rawValue != $1.access.rawValue {
                    return $0.access.rawValue < $1.access.rawValue
                }
                return $0.offset < $1.offset
            }
    }
    public private(set) var guestMemoryTrace: [GuestMemoryTraceEntry]
    public private(set) var firstEL0Entry: ARM64ExecutionStateTraceEntry?
    public private(set) var exceptionLoop: ARM64ExceptionTraceEntry?
    public private(set) var exceptionStorm: ARM64ExceptionStorm?
    public private(set) var requestedStopReason: RunStopReason?
    public private(set) var observedEL0FaultCount: Int
    public private(set) var translationCacheHits: Int
    public private(set) var translationCacheMisses: Int
    public private(set) var waitForInterruptCount: UInt64
    public private(set) var waitForEventCount: UInt64
    public private(set) var timerFastForwardCount: UInt64
    public private(set) var timerFastForwardCycles: UInt64
    public var traceCapacity: Int
    public var exceptionTraceCapacity: Int
    public var systemRegisterTraceCapacity: Int
    public var systemRegisterReadTraceCapacity: Int
    public var executionStateTraceCapacity: Int
    public var mmioTraceCapacity: Int
    public var guestMemoryTraceCapacity: Int
    public var guestMemoryTraceEL0Only: Bool
    public var exceptionStormThreshold: Int
    public var timerCyclesPerInstruction: UInt64
    public var wallClockRunBudgetNanoseconds: UInt64?
    public var nativeCheckpointBlockInterval: UInt64
    public var hostPreemptionGenerationProvider: (@Sendable () -> UInt64)?
    public var stopOnEL0Entry: Bool
    public var stopOnEL0Fault: Bool
    public var el0FaultStopSkipCount: Int
    public var stopOnUARTOutput: Bool
    public var stopOnUARTOutputContaining: String?
    public var stopOnGuestMemoryWriteVirtualAddress: GuestAddress?
    public var stopOnGuestMemoryWritePhysicalAddress: GuestAddress?
    public var guestMemoryWriteStopSkipCount: Int
    public private(set) var observedGuestMemoryWriteWatchCount: Int
    private var traceStepCounter: Int
    private var instructionTraceStorage: [InstructionTraceEntry]
    private var instructionTraceStartIndex: Int
    private var instructionDecodeCache: [UInt32: String]
    private var mmioAccessCounterStorage: [MMIOAccessCounterKey: UInt64]
    private var repeatedExceptionSignature: ARM64ExceptionSignature?
    private var repeatedExceptionCount: Int
    private var translationCache: [ARM64TranslationCacheKey: GuestAddress]
    private var cachedSCTLR_EL1: UInt64
    private var cachedTCR_EL1: UInt64
    private var cachedTTBR0_EL1: UInt64
    private var cachedTTBR1_EL1: UInt64
    private var nextGenericTimerRefreshTick: UInt64
    private var virtualCPUs: [VirtualCPURuntime]
    private var nextScheduledVCPUID: Int
    private var externallyManagedVCPUID: Int?
    private var externalClock: ParallelVCPUClock?
    var nativeCounterClock: AVZNativeCounterClock? { externalClock?.nativeConfiguration }

    func synchronizeExternalCounter() {
        externalClock?.synchronize(&systemRegisters)
    }
    private var externalCPUStartHandler: ((Int, GuestAddress, UInt64) -> Bool)?
    private var externalResetHandler: ((GuestAddress) -> Void)?
    private var externalStateProvider: (() -> [VirtualCPUArchitecturalState])?
    private var observedSharedTranslationEpoch: UInt64
    var currentRunDeadlineNanoseconds: UInt64?

    public init(
        memory: PhysicalMemory,
        mmio: MMIOBus = MMIOBus(),
        interruptController: InterruptController = SimpleInterruptController(),
        backend: VirtualMachineBackend = SoftwareARM64Backend(),
        virtualCPUCount: Int = 1
    ) {
        precondition((1...8).contains(virtualCPUCount), "virtual CPU count must be between 1 and 8")
        self.memory = memory
        self.mmio = mmio
        self.interruptController = interruptController
        self.backend = backend
        self.virtualCPUCount = virtualCPUCount
        self.cpu = CPUState()
        var bootstrapRegisters = ARM64SystemRegisterBank()
        bootstrapRegisters.reset(mpidr: Self.mpidr(forVCPUID: 0))
        self.systemRegisters = bootstrapRegisters
        self.activeVCPUID = 0
        self.virtualCPUQuantumSteps = 16_384
        self.breakpoints = []
        self.breakpointSkipCounts = [:]
        self.bootDevices = []
        self.instructionTraceStorage = []
        self.instructionTraceStartIndex = 0
        self.instructionDecodeCache = [:]
        self.mmioAccessCounterStorage = [:]
        self.exceptionTrace = []
        self.systemRegisterTrace = []
        self.systemRegisterReadTrace = []
        self.executionStateTrace = []
        self.mmioTrace = []
        self.guestMemoryTrace = []
        self.firstEL0Entry = nil
        self.exceptionLoop = nil
        self.exceptionStorm = nil
        self.requestedStopReason = nil
        self.translationCacheHits = 0
        self.translationCacheMisses = 0
        self.waitForInterruptCount = 0
        self.waitForEventCount = 0
        self.timerFastForwardCount = 0
        self.timerFastForwardCycles = 0
        self.traceCapacity = 0
        self.exceptionTraceCapacity = 64
        self.systemRegisterTraceCapacity = 128
        self.systemRegisterReadTraceCapacity = 128
        self.executionStateTraceCapacity = 64
        self.mmioTraceCapacity = 0
        self.guestMemoryTraceCapacity = 0
        self.guestMemoryTraceEL0Only = false
        self.exceptionStormThreshold = 32
        self.timerCyclesPerInstruction = 1
        self.wallClockRunBudgetNanoseconds = nil
        self.nativeCheckpointBlockInterval = 1_024
        self.hostPreemptionGenerationProvider = nil
        self.stopOnEL0Entry = false
        self.stopOnEL0Fault = false
        self.el0FaultStopSkipCount = 0
        self.stopOnUARTOutput = false
        self.stopOnUARTOutputContaining = nil
        self.stopOnGuestMemoryWriteVirtualAddress = nil
        self.stopOnGuestMemoryWritePhysicalAddress = nil
        self.guestMemoryWriteStopSkipCount = 0
        self.observedGuestMemoryWriteWatchCount = 0
        self.traceStepCounter = 0
        self.repeatedExceptionSignature = nil
        self.repeatedExceptionCount = 0
        self.observedEL0FaultCount = 0
        self.translationCache = [:]
        self.cachedSCTLR_EL1 = 0
        self.cachedTCR_EL1 = 0
        self.cachedTTBR0_EL1 = 0
        self.cachedTTBR1_EL1 = 0
        self.nextGenericTimerRefreshTick = 0
        self.virtualCPUs = (0..<virtualCPUCount).map { id in
            var registers = ARM64SystemRegisterBank()
            registers.reset(mpidr: Self.mpidr(forVCPUID: id))
            return VirtualCPURuntime(
                architecture: VirtualCPUArchitecturalState(
                    id: id,
                    cpu: CPUState(),
                    systemRegisters: registers,
                    lifecycle: id == 0 ? .runnable : .offline
                )
            )
        }
        self.nextScheduledVCPUID = 0
        self.externallyManagedVCPUID = nil
        self.externalClock = nil
        self.externalCPUStartHandler = nil
        self.externalResetHandler = nil
        self.externalStateProvider = nil
        self.observedSharedTranslationEpoch = memory.sharedTranslationEpoch
        self.currentRunDeadlineNanoseconds = nil
        refreshCachedTranslationRegisters()
        saveActiveVirtualCPU()
    }

    public func reset(entryPoint: GuestAddress) {
        resetVirtualCPUs(entryPoint: entryPoint)
        mmio.reset()
        interruptController.reset()
        clearInstructionTrace()
        clearExceptionTrace()
        clearExecutionStateTrace()
        clearMMIOTrace()
        clearGuestMemoryTrace()
        observedGuestMemoryWriteWatchCount = 0
        waitForInterruptCount = 0
        waitForEventCount = 0
        timerFastForwardCount = 0
        timerFastForwardCycles = 0
        invalidateTranslationCache(resetCounters: true)
        invalidateGenericTimerDeadline()
        requestedStopReason = nil
        currentRunDeadlineNanoseconds = nil
        externalResetHandler?(entryPoint)
    }

    public func loadBinary(_ bytes: [UInt8], at address: GuestAddress) throws {
        try memory.load(bytes, at: address)
    }

    public func run(maxSteps: Int = 100_000) throws -> RunResult {
        if externallyManagedVCPUID != nil {
            return try runExternallyManagedVirtualCPU(maxSteps: maxSteps)
        }
        guard virtualCPUCount > 1 else {
            return try backend.run(vm: self, maxSteps: maxSteps)
        }
        return try runVirtualCPUs(maxSteps: maxSteps)
    }

    public var virtualCPUStates: [VirtualCPUArchitecturalState] {
        if let externalStateProvider {
            return externalStateProvider()
        }
        saveActiveVirtualCPU()
        let counterTicks = systemRegisters.counterTicks
        return virtualCPUs.map { runtime in
            var architecture = runtime.architecture
            architecture.systemRegisters.synchronizeCounterTicks(counterTicks)
            return architecture
        }
    }

    public func virtualCPUState(id: Int) -> VirtualCPUArchitecturalState? {
        if let externalStateProvider {
            return externalStateProvider().first { $0.id == id }
        }
        guard virtualCPUs.indices.contains(id) else { return nil }
        saveActiveVirtualCPU()
        var architecture = virtualCPUs[id].architecture
        architecture.systemRegisters.synchronizeCounterTicks(systemRegisters.counterTicks)
        return architecture
    }

    public var hasPendingInterruptForAnyVirtualCPU: Bool {
        (0..<virtualCPUCount).contains {
            interruptController.peekPending(targetVCPU: $0) != nil
        }
    }

    public var waitingVirtualCPUCount: Int {
        if let externalStateProvider {
            return externalStateProvider().reduce(into: 0) { count, state in
                if state.lifecycle == .waitingForInterrupt {
                    count += 1
                }
            }
        }
        saveActiveVirtualCPU()
        return virtualCPUs.reduce(into: 0) { count, runtime in
            if runtime.architecture.lifecycle == .waitingForInterrupt {
                count += 1
            }
        }
    }

    func restoreVirtualCPUStates(
        _ states: [VirtualCPUArchitecturalState],
        activeVCPUID: Int
    ) throws {
        guard states.count == virtualCPUCount,
              states.indices.contains(activeVCPUID),
              states.enumerated().allSatisfy({ $0.offset == $0.element.id }) else {
            throw VMError.invalidSnapshot(
                "snapshot virtual CPU topology does not match \(virtualCPUCount)-CPU machine"
            )
        }

        let sharedCounterTicks = states.map(\.systemRegisters.counterTicks).max() ?? 0
        virtualCPUs = states.map { architecture in
            var synchronized = architecture
            synchronized.systemRegisters.synchronizeCounterTicks(sharedCounterTicks)
            return VirtualCPURuntime(architecture: synchronized)
        }
        self.activeVCPUID = activeVCPUID
        nextScheduledVCPUID = (activeVCPUID + 1) % virtualCPUCount
        cpu = virtualCPUs[activeVCPUID].architecture.cpu
        systemRegisters = virtualCPUs[activeVCPUID].architecture.systemRegisters
        translationCache = [:]
        refreshCachedTranslationRegisters()
        nextGenericTimerRefreshTick = 0
        saveActiveVirtualCPU()
        backend.invalidateTranslationCache(for: self)
    }

    @discardableResult
    public func startVirtualCPU(
        id: Int,
        entryPoint: GuestAddress,
        context: UInt64
    ) -> Bool {
        guard virtualCPUs.indices.contains(id),
              id != activeVCPUID,
              entryPoint & 0x3 == 0,
              memory.range.contains(entryPoint, width: 4),
              !Self.isPoweredOn(virtualCPUs[id].architecture.lifecycle) else {
            return false
        }

        var registers = ARM64SystemRegisterBank()
        registers.reset(
            mpidr: Self.mpidr(forVCPUID: id),
            counterTicks: systemRegisters.counterTicks
        )
        var state = CPUState(
            pc: entryPoint,
            pstate: ARM64PState.el1hMasked
        )
        state.x[0] = context
        virtualCPUs[id] = VirtualCPURuntime(
            architecture: VirtualCPUArchitecturalState(
                id: id,
                cpu: state,
                systemRegisters: registers,
                lifecycle: .runnable
            )
        )
        if let externalCPUStartHandler,
           !externalCPUStartHandler(id, entryPoint, context) {
            virtualCPUs[id].architecture.lifecycle = .offline
            return false
        }
        return true
    }

    func configureExternalParallelExecution(
        vcpuID: Int,
        clock: ParallelVCPUClock,
        stateProvider: (() -> [VirtualCPUArchitecturalState])? = nil,
        cpuStartHandler: ((Int, GuestAddress, UInt64) -> Bool)? = nil,
        resetHandler: ((GuestAddress) -> Void)? = nil
    ) {
        precondition(virtualCPUs.indices.contains(vcpuID))
        externallyManagedVCPUID = vcpuID
        externalClock = clock
        externalStateProvider = stateProvider
        externalCPUStartHandler = cpuStartHandler
        externalResetHandler = resetHandler
        activeVCPUID = vcpuID
        cpu = virtualCPUs[vcpuID].architecture.cpu
        systemRegisters = virtualCPUs[vcpuID].architecture.systemRegisters
        translationCache = virtualCPUs[vcpuID].translationCache
        refreshCachedTranslationRegisters()
        nextGenericTimerRefreshTick = 0
    }

    func installExternalVirtualCPUState(_ architecture: VirtualCPUArchitecturalState) {
        precondition(architecture.id == externallyManagedVCPUID)
        activeVCPUID = architecture.id
        virtualCPUs[architecture.id] = VirtualCPURuntime(architecture: architecture)
        cpu = architecture.cpu
        systemRegisters = architecture.systemRegisters
        translationCache.removeAll(keepingCapacity: true)
        refreshCachedTranslationRegisters()
        nextGenericTimerRefreshTick = 0
        backend.invalidateTranslationCache(for: self)
    }

    func externalVirtualCPUStateSnapshot() -> VirtualCPUArchitecturalState {
        let id = externallyManagedVCPUID ?? activeVCPUID
        return VirtualCPUArchitecturalState(
            id: id,
            cpu: cpu,
            systemRegisters: systemRegisters,
            lifecycle: virtualCPUs[id].architecture.lifecycle
        )
    }

    private func runExternallyManagedVirtualCPU(maxSteps: Int) throws -> RunResult {
        guard maxSteps > 0 else {
            return RunResult(steps: 0, stopReason: .maxSteps(maxSteps), lastException: lastException)
        }
        let id = activeVCPUID
        externalClock?.synchronize(&systemRegisters)
        if virtualCPUs[id].architecture.lifecycle == .waitingForInterrupt {
            updateGenericTimerInterruptsIfNeeded(force: true)
            guard interruptController.peekPending(targetVCPU: id) != nil else {
                return RunResult(steps: 0, stopReason: .yielded, lastException: lastException)
            }
            virtualCPUs[id].architecture.lifecycle = .runnable
        }

        let result = try backend.run(vm: self, maxSteps: maxSteps)
        externalClock?.synchronize(&systemRegisters)
        if result.stopReason == .halted {
            virtualCPUs[id].architecture.lifecycle = .halted
        }
        virtualCPUs[id].architecture.cpu = cpu
        virtualCPUs[id].architecture.systemRegisters = systemRegisters
        return result
    }

    public func handleFirmwareCall(instruction: UInt32) -> Bool {
        let encoding = instruction & 0xffe0_001f
        guard encoding == 0xd400_0002 || encoding == 0xd400_0003 else {
            return false
        }

        let function = UInt32(truncatingIfNeeded: cpu.x[0])
        let argument1 = cpu.x[1]
        let argument2 = cpu.x[2]
        let argument3 = cpu.x[3]
        let result: Int64

        switch function {
        case 0x8000_0000: // SMCCC_VERSION
            result = Int64(0x0001_0001)
        case 0x8000_0001: // SMCCC_ARCH_FEATURES
            result = Self.psciNotSupported
        case 0x8400_0000: // PSCI_VERSION
            result = Int64(0x0001_0001)
        case 0x8400_0001, 0xc400_0001: // PSCI_CPU_SUSPEND
            result = Self.psciSuccess
        case 0x8400_0003, 0xc400_0003: // PSCI_CPU_ON
            result = psciCPUOn(target: argument1, entryPoint: argument2, context: argument3)
        case 0x8400_0004, 0xc400_0004: // PSCI_AFFINITY_INFO
            result = psciAffinityInfo(target: argument1)
        case 0x8400_0006: // PSCI_MIGRATE_INFO_TYPE
            result = 2
        case 0x8400_000a: // PSCI_FEATURES
            result = Self.supportedPSCIFunctions.contains(UInt32(truncatingIfNeeded: argument1))
                ? Self.psciSuccess
                : Self.psciNotSupported
        default:
            result = Self.psciNotSupported
        }

        cpu.x[0] = UInt64(bitPattern: result)
        cpu.pc &+= 4
        return true
    }

    private func runVirtualCPUs(maxSteps: Int) throws -> RunResult {
        guard maxSteps > 0 else {
            return RunResult(steps: 0, stopReason: .maxSteps(maxSteps), lastException: lastException)
        }

        let ownsDeadline = currentRunDeadlineNanoseconds == nil
        if ownsDeadline, let budget = wallClockRunBudgetNanoseconds {
            currentRunDeadlineNanoseconds = DispatchTime.now().uptimeNanoseconds &+ budget
        }
        defer {
            saveActiveVirtualCPU()
            if ownsDeadline {
                currentRunDeadlineNanoseconds = nil
            }
        }

        var totalSteps = 0
        while totalSteps < maxSteps {
            if let deadline = currentRunDeadlineNanoseconds,
               DispatchTime.now().uptimeNanoseconds >= deadline {
                return RunResult(
                    steps: totalSteps,
                    stopReason: .maxSteps(maxSteps),
                    lastException: lastException
                )
            }
            guard let id = nextRunnableVirtualCPU() else {
                if fastForwardWaitingVirtualCPUsToNextTimerDeadline() {
                    continue
                }
                let stopReason: RunStopReason = virtualCPUs.contains {
                    $0.architecture.lifecycle == .waitingForInterrupt
                } ? .maxSteps(maxSteps) : .halted
                return RunResult(
                    steps: totalSteps,
                    stopReason: stopReason,
                    lastException: lastException
                )
            }
            activateVirtualCPU(id)

            let sliceSteps = min(
                maxSteps - totalSteps,
                max(1, virtualCPUQuantumSteps)
            )
            let result = try backend.run(vm: self, maxSteps: sliceSteps)
            totalSteps += result.steps

            switch result.stopReason {
            case .maxSteps:
                if result.steps == 0 {
                    return RunResult(
                        steps: totalSteps,
                        stopReason: .maxSteps(maxSteps),
                        lastException: lastException
                    )
                }
            case .yielded:
                saveActiveVirtualCPU()
            case .halted:
                virtualCPUs[activeVCPUID].architecture.lifecycle = .halted
                saveActiveVirtualCPU()
                if !virtualCPUs.contains(where: {
                    $0.architecture.lifecycle == .runnable ||
                        $0.architecture.lifecycle == .waitingForInterrupt
                }) {
                    return RunResult(steps: totalSteps, stopReason: .halted, lastException: lastException)
                }
            default:
                return RunResult(
                    steps: totalSteps,
                    stopReason: result.stopReason,
                    lastException: result.lastException
                )
            }
        }
        return RunResult(steps: totalSteps, stopReason: .maxSteps(maxSteps), lastException: lastException)
    }

    private func nextRunnableVirtualCPU() -> Int? {
        wakeVirtualCPUsForPendingInterrupts()

        for offset in 0..<virtualCPUCount {
            let id = (nextScheduledVCPUID + offset) % virtualCPUCount
            if virtualCPUs[id].architecture.lifecycle == .runnable {
                nextScheduledVCPUID = (id + 1) % virtualCPUCount
                return id
            }
        }
        return nil
    }

    private func wakeVirtualCPUsForPendingInterrupts() {
        saveActiveVirtualCPU()
        let counterTicks = systemRegisters.counterTicks

        for id in virtualCPUs.indices
        where virtualCPUs[id].architecture.lifecycle == .waitingForInterrupt {
            virtualCPUs[id].architecture.systemRegisters.synchronizeCounterTicks(counterTicks)
            let registers = virtualCPUs[id].architecture.systemRegisters
            if registers.physicalTimerInterruptAsserted {
                interruptController.raise(line: Self.physicalTimerIRQ, targetVCPU: id)
            }
            if registers.virtualTimerInterruptAsserted {
                interruptController.raise(line: Self.virtualTimerIRQ, targetVCPU: id)
            }
            if interruptController.peekPending(targetVCPU: id) != nil {
                virtualCPUs[id].architecture.lifecycle = .runnable
            }
        }
    }

    private func fastForwardWaitingVirtualCPUsToNextTimerDeadline() -> Bool {
        saveActiveVirtualCPU()
        let waitingIDs = virtualCPUs.indices.filter {
            virtualCPUs[$0].architecture.lifecycle == .waitingForInterrupt
        }
        guard !waitingIDs.isEmpty,
              !virtualCPUs.contains(where: { $0.architecture.lifecycle == .runnable }) else {
            return false
        }

        let counterTicks = systemRegisters.counterTicks
        let deadline = waitingIDs.compactMap { id -> UInt64? in
            virtualCPUs[id].architecture.systemRegisters.synchronizeCounterTicks(counterTicks)
            return virtualCPUs[id].architecture.systemRegisters.nextUnmaskedTimerDeadline
        }.min()
        guard let deadline, deadline > counterTicks else {
            wakeVirtualCPUsForPendingInterrupts()
            return virtualCPUs.contains { $0.architecture.lifecycle == .runnable }
        }

        let cycles = deadline &- counterTicks
        systemRegisters.synchronizeCounterTicks(deadline)
        for id in virtualCPUs.indices {
            virtualCPUs[id].architecture.systemRegisters.synchronizeCounterTicks(deadline)
        }
        timerFastForwardCount &+= 1
        timerFastForwardCycles &+= cycles
        wakeVirtualCPUsForPendingInterrupts()
        return virtualCPUs.contains { $0.architecture.lifecycle == .runnable }
    }

    private func activateVirtualCPU(_ id: Int) {
        guard id != activeVCPUID else { return }
        // Host scheduling is invisible to the guest PE.  Keep each vCPU's
        // local monitor across a cooperative slice; writes by another PE are
        // detected by PhysicalMemory's shared reservation generation.
        let sharedCounterTicks = systemRegisters.counterTicks
        saveActiveVirtualCPU()

        var runtime = virtualCPUs[id]
        runtime.architecture.systemRegisters.synchronizeCounterTicks(sharedCounterTicks)
        activeVCPUID = id
        cpu = runtime.architecture.cpu
        systemRegisters = runtime.architecture.systemRegisters
        translationCache = runtime.translationCache
        cachedSCTLR_EL1 = runtime.cachedSCTLR_EL1
        cachedTCR_EL1 = runtime.cachedTCR_EL1
        cachedTTBR0_EL1 = runtime.cachedTTBR0_EL1
        cachedTTBR1_EL1 = runtime.cachedTTBR1_EL1
        nextGenericTimerRefreshTick = runtime.nextGenericTimerRefreshTick
        virtualCPUs[id] = runtime
    }

    private func saveActiveVirtualCPU() {
        guard virtualCPUs.indices.contains(activeVCPUID) else { return }
        virtualCPUs[activeVCPUID].architecture.cpu = cpu
        virtualCPUs[activeVCPUID].architecture.systemRegisters = systemRegisters
        virtualCPUs[activeVCPUID].translationCache = translationCache
        virtualCPUs[activeVCPUID].cachedSCTLR_EL1 = cachedSCTLR_EL1
        virtualCPUs[activeVCPUID].cachedTCR_EL1 = cachedTCR_EL1
        virtualCPUs[activeVCPUID].cachedTTBR0_EL1 = cachedTTBR0_EL1
        virtualCPUs[activeVCPUID].cachedTTBR1_EL1 = cachedTTBR1_EL1
        virtualCPUs[activeVCPUID].nextGenericTimerRefreshTick = nextGenericTimerRefreshTick
    }

    private func resetVirtualCPUs(entryPoint: GuestAddress) {
        activeVCPUID = 0
        nextScheduledVCPUID = 0
        virtualCPUs = (0..<virtualCPUCount).map { id in
            var registers = ARM64SystemRegisterBank()
            registers.reset(mpidr: Self.mpidr(forVCPUID: id))
            return VirtualCPURuntime(
                architecture: VirtualCPUArchitecturalState(
                    id: id,
                    cpu: CPUState(pc: id == 0 ? entryPoint : 0),
                    systemRegisters: registers,
                    lifecycle: id == 0 ? .runnable : .offline
                )
            )
        }
        cpu = virtualCPUs[0].architecture.cpu
        systemRegisters = virtualCPUs[0].architecture.systemRegisters
        translationCache = [:]
        cachedSCTLR_EL1 = 0
        cachedTCR_EL1 = 0
        cachedTTBR0_EL1 = 0
        cachedTTBR1_EL1 = 0
        nextGenericTimerRefreshTick = 0
        refreshCachedTranslationRegisters()
        saveActiveVirtualCPU()
    }

    private func psciCPUOn(target: UInt64, entryPoint: GuestAddress, context: UInt64) -> Int64 {
        let id = Int(target & 0xff)
        guard virtualCPUs.indices.contains(id), target & 0x00ff_ffff_ffff_ff00 == 0 else {
            return Self.psciInvalidParameters
        }
        guard virtualCPUs[id].architecture.lifecycle != .runnable else {
            return Self.psciAlreadyOn
        }
        return startVirtualCPU(id: id, entryPoint: entryPoint, context: context)
            ? Self.psciSuccess
            : Self.psciInvalidParameters
    }

    private func psciAffinityInfo(target: UInt64) -> Int64 {
        let id = Int(target & 0xff)
        guard virtualCPUs.indices.contains(id), target & 0x00ff_ffff_ffff_ff00 == 0 else {
            return Self.psciInvalidParameters
        }
        return Self.isPoweredOn(virtualCPUs[id].architecture.lifecycle) ? 0 : 1
    }

    private static func isPoweredOn(_ lifecycle: VirtualCPULifecycle) -> Bool {
        lifecycle == .runnable || lifecycle == .waitingForInterrupt
    }

    private static func mpidr(forVCPUID id: Int) -> UInt64 {
        0x8000_0000 | UInt64(id & 0xff)
    }

    private static let psciSuccess: Int64 = 0
    private static let psciNotSupported: Int64 = -1
    private static let psciInvalidParameters: Int64 = -2
    private static let psciAlreadyOn: Int64 = -4
    private static let supportedPSCIFunctions: Set<UInt32> = [
        0x8400_0000,
        0x8400_0001,
        0xc400_0001,
        0x8400_0003,
        0xc400_0003,
        0x8400_0004,
        0xc400_0004,
        0x8400_0006,
        0x8400_000a
    ]

    public func translateAddress(
        _ virtualAddress: GuestAddress,
        access: GuestMemoryAccessKind = .dataRead
    ) throws -> GuestAddress {
        let sharedEpoch = memory.sharedTranslationEpoch
        if sharedEpoch != observedSharedTranslationEpoch {
            translationCache.removeAll(keepingCapacity: true)
            observedSharedTranslationEpoch = sharedEpoch
        }
        let sctlr = cachedSCTLR_EL1
        guard (sctlr & 0x1) != 0 else {
            return virtualAddress
        }

        let pageOffset = virtualAddress & 0xfff
        let virtualPage = virtualAddress & ~UInt64(0xfff)
        let usesTTBR1 = (virtualAddress >> 63) == 1
        let tcr = cachedTCR_EL1
        let ttbr = usesTTBR1 ? cachedTTBR1_EL1 : cachedTTBR0_EL1
        let key = ARM64TranslationCacheKey(
            virtualPage: virtualPage,
            access: access.translationCacheDiscriminator,
            exceptionLevel: (cpu.pstate >> 2) & 0x3,
            sctlr: sctlr,
            tcr: tcr,
            ttbr: ttbr
        )
        if let physicalPage = translationCache[key] {
            translationCacheHits += 1
            return physicalPage | pageOffset
        }

        let physicalAddress = try ARM64Stage1Translator.translate(
            virtualAddress: virtualAddress,
            access: access,
            vm: self
        )
        translationCacheMisses += 1
        translationCache[key] = physicalAddress & ~UInt64(0xfff)
        return physicalAddress
    }

    public func readGuest(_ virtualAddress: GuestAddress, width: MMIOWidth, access: GuestMemoryAccessKind = .dataRead) throws -> UInt64 {
        if crossesTranslationPageBoundary(virtualAddress, width: width) {
            var value: UInt64 = 0
            for index in 0..<UInt64(width.rawValue) {
                let byteVirtualAddress = virtualAddress + index
                let bytePhysicalAddress = try translateAddress(byteVirtualAddress, access: access)
                let byte = try readPhysical(bytePhysicalAddress, width: .byte)
                value |= byte << (index * 8)
                recordGuestMemoryAccess(
                    access: .read,
                    virtualAddress: byteVirtualAddress,
                    physicalAddress: bytePhysicalAddress,
                    width: .byte,
                    value: byte
                )
            }
            return value
        }

        let physicalAddress = try translateAddress(virtualAddress, access: access)
        let value = try readPhysical(physicalAddress, width: width)
        recordGuestMemoryAccess(
            access: .read,
            virtualAddress: virtualAddress,
            physicalAddress: physicalAddress,
            width: width,
            value: value
        )
        return value
    }

    public func readGuestRAMFast(
        _ virtualAddress: GuestAddress,
        width: MMIOWidth,
        access: GuestMemoryAccessKind = .dataRead
    ) throws -> UInt64? {
        guard !crossesTranslationPageBoundary(virtualAddress, width: width) else {
            return nil
        }
        let physicalAddress = try translateAddress(virtualAddress, access: access)
        guard memory.range.contains(physicalAddress, width: UInt64(width.rawValue)) else {
            return nil
        }
        switch width {
        case .byte:
            return UInt64(try memory.read8(at: physicalAddress))
        case .halfword:
            return UInt64(try memory.read16(at: physicalAddress))
        case .word:
            return UInt64(try memory.read32(at: physicalAddress))
        case .doubleword:
            return try memory.read64(at: physicalAddress)
        }
    }

    public func writeGuest(_ virtualAddress: GuestAddress, width: MMIOWidth, value: UInt64) throws {
        if crossesTranslationPageBoundary(virtualAddress, width: width) {
            for index in 0..<UInt64(width.rawValue) {
                let byteVirtualAddress = virtualAddress + index
                let bytePhysicalAddress = try translateAddress(byteVirtualAddress, access: .dataWrite)
                let byte = (value >> (index * 8)) & 0xff
                try writePhysical(bytePhysicalAddress, width: .byte, value: byte)
                recordGuestMemoryAccess(
                    access: .write,
                    virtualAddress: byteVirtualAddress,
                    physicalAddress: bytePhysicalAddress,
                    width: .byte,
                    value: byte
                )
            }
            return
        }

        let physicalAddress = try translateAddress(virtualAddress, access: .dataWrite)
        try writePhysical(physicalAddress, width: width, value: value)
        recordGuestMemoryAccess(
            access: .write,
            virtualAddress: virtualAddress,
            physicalAddress: physicalAddress,
            width: width,
            value: value
        )
    }

    @discardableResult
    public func writeGuestRAMFast(_ virtualAddress: GuestAddress, width: MMIOWidth, value: UInt64) throws -> Bool {
        guard !crossesTranslationPageBoundary(virtualAddress, width: width) else {
            return false
        }
        let physicalAddress = try translateAddress(virtualAddress, access: .dataWrite)
        guard memory.range.contains(physicalAddress, width: UInt64(width.rawValue)) else {
            return false
        }
        switch width {
        case .byte:
            try memory.write8(UInt8(value & 0xff), at: physicalAddress)
        case .halfword:
            try memory.write16(UInt16(value & 0xffff), at: physicalAddress)
        case .word:
            try memory.write32(UInt32(value & 0xffff_ffff), at: physicalAddress)
        case .doubleword:
            try memory.write64(value, at: physicalAddress)
        }
        backend.invalidateCodeCache(physicalAddress: physicalAddress, byteCount: UInt64(width.rawValue))
        clearExclusiveReservation()
        return true
    }

    private func crossesTranslationPageBoundary(_ virtualAddress: GuestAddress, width: MMIOWidth) -> Bool {
        let byteCount = UInt64(width.rawValue)
        guard byteCount > 1 else {
            return false
        }
        return (virtualAddress & 0xfff) + byteCount > 0x1000
    }

    public func updateGenericTimerInterruptsIfNeeded(force: Bool = false) {
        if !force, systemRegisters.counterTicks < nextGenericTimerRefreshTick {
            return
        }

        updateTimerInterrupt(line: Self.physicalTimerIRQ, asserted: systemRegisters.physicalTimerInterruptAsserted)
        updateTimerInterrupt(line: Self.virtualTimerIRQ, asserted: systemRegisters.virtualTimerInterruptAsserted)
        nextGenericTimerRefreshTick = systemRegisters.nextUnmaskedTimerDeadline ?? UInt64.max
    }

    public func updateGenericTimerInterrupts() {
        updateGenericTimerInterruptsIfNeeded(force: true)
    }

    @discardableResult
    public func fastForwardGenericTimerToNextDeadline() -> UInt64 {
        // A sleeping vCPU cannot advance the shared architectural counter while
        // another vCPU remains runnable. SMP time advances through scheduled work.
        guard virtualCPUCount == 1 else {
            return 0
        }
        guard let deadline = systemRegisters.nextUnmaskedTimerDeadline else {
            return 0
        }
        guard deadline > systemRegisters.counterTicks else {
            return 0
        }

        let cycles = deadline &- systemRegisters.counterTicks
        systemRegisters.advance(cycles: cycles)
        timerFastForwardCount &+= 1
        timerFastForwardCycles &+= cycles
        return cycles
    }

    public func recordWaitForInterrupt() {
        waitForInterruptCount &+= 1
    }

    @discardableResult
    public func suspendActiveVirtualCPUForWaitForInterrupt() -> Bool {
        guard virtualCPUCount > 1,
              interruptController.peekPending(targetVCPU: activeVCPUID) == nil else {
            return false
        }
        virtualCPUs[activeVCPUID].architecture.lifecycle = .waitingForInterrupt
        return true
    }

    public var activeVirtualCPUIsWaitingForInterrupt: Bool {
        virtualCPUs.indices.contains(activeVCPUID) &&
            virtualCPUs[activeVCPUID].architecture.lifecycle == .waitingForInterrupt
    }

    public var hostTimerWaitNanoseconds: UInt64? {
        // A wake notification can precede the host condition wait. Recheck the
        // level predicate, including when the guest has no armed timer.
        if interruptController.peekPending(targetVCPU: activeVCPUID) != nil {
            return 0
        }
        guard let deadline = systemRegisters.nextUnmaskedTimerDeadline else {
            return nil
        }
        guard let externalClock else {
            return deadline > systemRegisters.counterTicks
                ? deadline &- systemRegisters.counterTicks
                : 0
        }
        return externalClock.nanosecondsUntil(deadlineTicks: deadline)
    }

    public func recordWaitForEvent() {
        waitForEventCount &+= 1
    }

    public func invalidateGenericTimerDeadline() {
        nextGenericTimerRefreshTick = 0
    }

    public func invalidateTranslationCache(resetCounters: Bool = false) {
        translationCache.removeAll(keepingCapacity: true)
        backend.invalidateTranslationCache(for: self)
        if resetCounters {
            translationCacheHits = 0
            translationCacheMisses = 0
        }
    }

    func executeSystemMaintenanceInstruction(_ instruction: UInt32, operand: UInt64 = 0) {
        let crn = (instruction >> 12) & 0xf
        guard crn == 8 else {
            // Guest cache maintenance needs no host action: RAM writes are
            // coherent and already advance executable-page generations.
            return
        }

        let invalidation = avz_native_decode_tlbi(instruction, operand, cachedTCR_EL1)
        if invalidation.broadcast != 0 {
            memory.publishTranslationInvalidation(invalidation)
        }
        // These auxiliary Swift caches do not carry leaf/global metadata.
        // Native execution keeps its architecturally tagged TLB entries scoped.
        translationCache.removeAll(keepingCapacity: true)
        backend.invalidateTranslations(for: self, matching: invalidation)
    }

    public func didWriteSystemRegister(_ key: ARM64SystemRegisterKey) {
        switch key.rawValue {
        case ARM64SystemRegister.sctlrEL1.rawValue,
             ARM64SystemRegister.tcrEL1.rawValue,
             ARM64SystemRegister.mairEL1.rawValue:
            refreshCachedTranslationRegisters()
            invalidateTranslationCache()
        case ARM64SystemRegister.ttbr0EL1.rawValue,
             ARM64SystemRegister.ttbr1EL1.rawValue:
            refreshCachedTranslationRegisters()
        case ARM64SystemRegister.cntpTvalEL0.rawValue,
             ARM64SystemRegister.cntpCtlEL0.rawValue,
             ARM64SystemRegister.cntpCvalEL0.rawValue,
             ARM64SystemRegister.cntvTvalEL0.rawValue,
             ARM64SystemRegister.cntvCtlEL0.rawValue,
             ARM64SystemRegister.cntvCvalEL0.rawValue:
            invalidateGenericTimerDeadline()
        default:
            break
        }
    }

    public func writeSystemRegister(_ key: ARM64SystemRegisterKey, value: UInt64) {
        var updatedCPU = cpu
        systemRegisters.write(key, value: value, cpu: &updatedCPU)
        cpu = updatedCPU
        didWriteSystemRegister(key)
    }

    public func writeRawSystemRegister(_ key: ARM64SystemRegisterKey, value: UInt64) {
        systemRegisters.writeRaw(key, value: value)
        didWriteSystemRegister(key)
    }

    public func clearExclusiveReservation() {
        cpu.exclusiveReservationAddress = nil
        cpu.exclusiveReservationSize = nil
        cpu.exclusiveReservationGeneration = nil
        for id in virtualCPUs.indices where id != activeVCPUID {
            virtualCPUs[id].architecture.cpu.exclusiveReservationAddress = nil
            virtualCPUs[id].architecture.cpu.exclusiveReservationSize = nil
            virtualCPUs[id].architecture.cpu.exclusiveReservationGeneration = nil
        }
    }

    @inline(__always)
    var translationSCTLR_EL1: UInt64 {
        cachedSCTLR_EL1
    }

    @inline(__always)
    var translationTCR_EL1: UInt64 {
        cachedTCR_EL1
    }

    @inline(__always)
    var translationTTBR0_EL1: UInt64 {
        cachedTTBR0_EL1
    }

    @inline(__always)
    var translationTTBR1_EL1: UInt64 {
        cachedTTBR1_EL1
    }

    func switchActiveStackPointer(from oldPState: UInt64, to newPState: UInt64) {
        switch CPUState.stackPointerBank(for: oldPState) {
        case .spEL0:
            systemRegisters.writeRaw(ARM64SystemRegister.spEL0, value: cpu.sp)
        case .spEL1:
            cpu.spEL1 = cpu.sp
        }

        switch CPUState.stackPointerBank(for: newPState) {
        case .spEL0:
            cpu.sp = systemRegisters.rawValue(for: ARM64SystemRegister.spEL0)
        case .spEL1:
            cpu.sp = cpu.spEL1
        }
    }

    private func updateTimerInterrupt(line: UInt32, asserted: Bool) {
        if asserted {
            interruptController.raise(line: line, targetVCPU: activeVCPUID)
        } else {
            interruptController.clear(line: line, targetVCPU: activeVCPUID)
        }
    }

    func refreshCachedTranslationRegisters() {
        cachedSCTLR_EL1 = systemRegisters.rawValue(for: ARM64SystemRegister.sctlrEL1)
        cachedTCR_EL1 = systemRegisters.rawValue(for: ARM64SystemRegister.tcrEL1)
        cachedTTBR0_EL1 = systemRegisters.rawValue(for: ARM64SystemRegister.ttbr0EL1)
        cachedTTBR1_EL1 = systemRegisters.rawValue(for: ARM64SystemRegister.ttbr1EL1)
    }

    public func enableInstructionTrace(capacity: Int = 32) {
        traceCapacity = max(0, capacity)
        clearInstructionTrace()
    }

    public func disableInstructionTrace() {
        traceCapacity = 0
        clearInstructionTrace()
    }

    public func clearInstructionTrace() {
        instructionTraceStorage.removeAll(keepingCapacity: true)
        instructionTraceStartIndex = 0
        clearSystemRegisterTrace()
        traceStepCounter = 0
    }

    public var lastException: ARM64ExceptionTraceEntry? {
        exceptionTrace.last
    }

    public func clearExceptionTrace() {
        exceptionTrace.removeAll()
        exceptionLoop = nil
        exceptionStorm = nil
        repeatedExceptionSignature = nil
        repeatedExceptionCount = 0
        observedEL0FaultCount = 0
    }

    public func clearSystemRegisterTrace() {
        systemRegisterTrace.removeAll()
        systemRegisterReadTrace.removeAll()
    }

    public func clearExecutionStateTrace() {
        executionStateTrace.removeAll()
        firstEL0Entry = nil
    }

    public func clearMMIOTrace() {
        mmioTrace.removeAll()
        mmioAccessCounterStorage.removeAll()
    }

    public func enableMMIOTrace(capacity: Int = 64) {
        mmioTraceCapacity = max(0, capacity)
        clearMMIOTrace()
    }

    public func clearGuestMemoryTrace() {
        guestMemoryTrace.removeAll()
    }

    public func enableGuestMemoryTrace(capacity: Int = 64, el0Only: Bool = false) {
        guestMemoryTraceCapacity = max(0, capacity)
        guestMemoryTraceEL0Only = el0Only
        clearGuestMemoryTrace()
    }

    func recordInstruction(pc: GuestAddress, instruction: UInt32) {
        guard traceCapacity > 0 else {
            return
        }

        traceStepCounter += 1
        let decode: String
        if let cachedDecode = instructionDecodeCache[instruction] {
            decode = cachedDecode
        } else {
            decode = ARM64InstructionClassifier.classify(instruction)
            instructionDecodeCache[instruction] = decode
        }

        let entry = InstructionTraceEntry(
            step: traceStepCounter,
            pc: pc,
            instruction: instruction,
            decode: decode,
            pstateBefore: cpu.pstate
        )

        if instructionTraceStorage.count < traceCapacity {
            instructionTraceStorage.append(entry)
        } else {
            instructionTraceStorage[instructionTraceStartIndex] = entry
            instructionTraceStartIndex = (instructionTraceStartIndex + 1) % traceCapacity
        }
    }

    func completeLastInstructionTrace(pstateAfter: UInt64) {
        guard traceCapacity > 0, !instructionTraceStorage.isEmpty else {
            return
        }

        let index: Int
        if instructionTraceStorage.count < traceCapacity {
            index = instructionTraceStorage.count - 1
        } else {
            index = (instructionTraceStartIndex + traceCapacity - 1) % traceCapacity
        }
        instructionTraceStorage[index] = instructionTraceStorage[index].completed(pstateAfter: pstateAfter)
    }

    private func orderedInstructionTrace() -> [InstructionTraceEntry] {
        guard traceCapacity > 0,
              instructionTraceStorage.count == traceCapacity,
              instructionTraceStartIndex > 0 else {
            return instructionTraceStorage
        }
        return Array(instructionTraceStorage[instructionTraceStartIndex...]) +
            Array(instructionTraceStorage[..<instructionTraceStartIndex])
    }

    func recordSystemRegisterWrite(
        pc: GuestAddress,
        key: ARM64SystemRegisterKey,
        previousValue: UInt64,
        newValue: UInt64
    ) {
        guard systemRegisterTraceCapacity > 0 else {
            return
        }

        systemRegisterTrace.append(ARM64SystemRegisterTraceEntry(
            step: traceStepCounter,
            pc: pc,
            key: key,
            previousValue: previousValue,
            newValue: newValue
        ))

        let overflow = systemRegisterTrace.count - systemRegisterTraceCapacity
        if overflow > 0 {
            systemRegisterTrace.removeFirst(overflow)
        }
    }

    func recordSystemRegisterRead(
        pc: GuestAddress,
        key: ARM64SystemRegisterKey,
        value: UInt64
    ) {
        guard systemRegisterReadTraceCapacity > 0 else {
            return
        }

        systemRegisterReadTrace.append(ARM64SystemRegisterReadTraceEntry(
            step: traceStepCounter,
            pc: pc,
            key: key,
            value: value
        ))

        let overflow = systemRegisterReadTrace.count - systemRegisterReadTraceCapacity
        if overflow > 0 {
            systemRegisterReadTrace.removeFirst(overflow)
        }
    }

    @discardableResult
    func recordExceptionLevelTransitionIfNeeded(
        step: Int,
        reason: ARM64ExecutionStateTransitionReason,
        previousPC: GuestAddress,
        previousPState: UInt64
    ) -> ARM64ExecutionStateTraceEntry? {
        let previousEL = Int((previousPState >> 2) & 0x3)
        let newEL = Int(cpu.currentExceptionLevel)
        guard previousEL != newEL else {
            return nil
        }

        let entry = ARM64ExecutionStateTraceEntry(
            step: step,
            reason: reason,
            previousPC: previousPC,
            newPC: cpu.pc,
            previousEL: previousEL,
            newEL: newEL,
            previousPState: previousPState,
            newPState: cpu.pstate
        )
        executionStateTrace.append(entry)
        let overflow = executionStateTrace.count - max(0, executionStateTraceCapacity)
        if overflow > 0 {
            executionStateTrace.removeFirst(overflow)
        }
        if newEL == 0, firstEL0Entry == nil {
            firstEL0Entry = entry
        }
        return entry
    }

    func recordException(_ entry: ARM64ExceptionTraceEntry) {
        exceptionTrace.append(entry)
        let overflow = exceptionTrace.count - max(0, exceptionTraceCapacity)
        if overflow > 0 {
            exceptionTrace.removeFirst(overflow)
        }

        let signature = ARM64ExceptionSignature(
            source: entry.source,
            exceptionClass: entry.exceptionClass,
            iss: entry.iss,
            returnAddress: entry.returnAddress,
            vectorAddress: entry.vectorAddress
        )
        if signature == repeatedExceptionSignature {
            repeatedExceptionCount += 1
        } else {
            repeatedExceptionSignature = signature
            repeatedExceptionCount = 1
        }
        if exceptionStormThreshold > 0, repeatedExceptionCount >= exceptionStormThreshold {
            exceptionStorm = ARM64ExceptionStorm(entry: entry, count: repeatedExceptionCount)
        }

        if entry.currentEL == 0, entry.source == .translationFault {
            if stopOnEL0Fault, observedEL0FaultCount >= max(0, el0FaultStopSkipCount) {
                requestStop(.el0Fault(entry.returnAddress, entry.faultAddress))
            }
            observedEL0FaultCount += 1
        }

        let isInstructionAbort = entry.exceptionClass == .instructionAbortSameEL ||
            entry.exceptionClass == .instructionAbortLowerEL
        if entry.source == .translationFault &&
            isInstructionAbort &&
            entry.vectorAddress == entry.returnAddress {
            exceptionLoop = entry
        }
    }

    func recordMMIOAccess(
        deviceName: String,
        access: MMIOTraceAccessKind,
        address: GuestAddress,
        offset: UInt64,
        width: MMIOWidth,
        value: UInt64
    ) {
        let key = MMIOAccessCounterKey(deviceName: deviceName, access: access, offset: offset)
        mmioAccessCounterStorage[key, default: 0] &+= 1

        guard mmioTraceCapacity > 0 else {
            return
        }

        mmioTrace.append(MMIOTraceEntry(
            step: traceStepCounter,
            pc: cpu.pc,
            deviceName: deviceName,
            access: access,
            address: address,
            offset: offset,
            width: width.rawValue,
            value: value
        ))
        let overflow = mmioTrace.count - max(0, mmioTraceCapacity)
        if overflow > 0 {
            mmioTrace.removeFirst(overflow)
        }
    }

    func recordGuestMemoryAccess(
        access: GuestMemoryTraceAccessKind,
        virtualAddress: GuestAddress,
        physicalAddress: GuestAddress,
        width: MMIOWidth,
        value: UInt64
    ) {
        guard guestMemoryTraceCapacity > 0,
              memory.range.contains(physicalAddress, width: UInt64(width.rawValue)),
              !guestMemoryTraceEL0Only || cpu.currentExceptionLevel == 0 else {
            maybeStopOnGuestMemoryWrite(
                access: access,
                virtualAddress: virtualAddress,
                physicalAddress: physicalAddress,
                width: width
            )
            return
        }

        guestMemoryTrace.append(GuestMemoryTraceEntry(
            step: traceStepCounter,
            pc: cpu.pc,
            exceptionLevel: Int(cpu.currentExceptionLevel),
            access: access,
            virtualAddress: virtualAddress,
            physicalAddress: physicalAddress,
            width: width.rawValue,
            value: value
        ))
        let overflow = guestMemoryTrace.count - max(0, guestMemoryTraceCapacity)
        if overflow > 0 {
            guestMemoryTrace.removeFirst(overflow)
        }
        maybeStopOnGuestMemoryWrite(
            access: access,
            virtualAddress: virtualAddress,
            physicalAddress: physicalAddress,
            width: width
        )
    }

    private func maybeStopOnGuestMemoryWrite(
        access: GuestMemoryTraceAccessKind,
        virtualAddress: GuestAddress,
        physicalAddress: GuestAddress,
        width: MMIOWidth
    ) {
        guard access == .write else {
            return
        }
        let byteCount = UInt64(width.rawValue)
        let matchedVirtual = stopOnGuestMemoryWriteVirtualAddress.map {
            $0 >= virtualAddress && $0 < virtualAddress + byteCount
        } ?? false
        let matchedPhysical = stopOnGuestMemoryWritePhysicalAddress.map {
            $0 >= physicalAddress && $0 < physicalAddress + byteCount
        } ?? false
        guard matchedVirtual || matchedPhysical else {
            return
        }
        if observedGuestMemoryWriteWatchCount >= max(0, guestMemoryWriteStopSkipCount) {
            requestStop(.guestMemoryWrite(virtualAddress, physicalAddress))
        }
        observedGuestMemoryWriteWatchCount += 1
    }

    func requestStop(_ reason: RunStopReason) {
        if requestedStopReason == nil {
            requestedStopReason = reason
        }
    }

    public func readPhysical(_ address: GuestAddress, width: MMIOWidth) throws -> UInt64 {
        if memory.range.contains(address, width: UInt64(width.rawValue)) {
            switch width {
            case .byte:
                return UInt64(try memory.read8(at: address))
            case .halfword:
                return UInt64(try memory.read16(at: address))
            case .word:
                return UInt64(try memory.read32(at: address))
            case .doubleword:
                return try memory.read64(at: address)
            }
        }
        guard let device = mmio.device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        let offset = address - device.range.start
        let value = try mmio.read(
            address: address,
            width: width,
            targetVCPU: activeVCPUID
        )
        recordMMIOAccess(
            deviceName: device.name,
            access: .read,
            address: address,
            offset: offset,
            width: width,
            value: value
        )
        return value
    }

    public func writePhysical(_ address: GuestAddress, width: MMIOWidth, value: UInt64) throws {
        if memory.range.contains(address, width: UInt64(width.rawValue)) {
            switch width {
            case .byte:
                try memory.write8(UInt8(value & 0xff), at: address)
            case .halfword:
                try memory.write16(UInt16(value & 0xffff), at: address)
            case .word:
                try memory.write32(UInt32(value & 0xffff_ffff), at: address)
            case .doubleword:
                try memory.write64(value, at: address)
            }
            backend.invalidateCodeCache(physicalAddress: address, byteCount: UInt64(width.rawValue))
            clearExclusiveReservation()
            return
        }
        guard let device = mmio.device(containing: address, width: width) else {
            throw VMError.invalidMMIOAccess(address: address, width: width.rawValue)
        }
        let offset = address - device.range.start
        try mmio.write(
            address: address,
            width: width,
            value: value,
            targetVCPU: activeVCPUID
        )
        recordMMIOAccess(
            deviceName: device.name,
            access: .write,
            address: address,
            offset: offset,
            width: width,
            value: value
        )
        if let uart = device as? VirtualUART, offset == 0 {
            if stopOnUARTOutput {
                requestStop(.uartOutput(UInt8(value & 0xff)))
            } else if let marker = stopOnUARTOutputContaining, uart.outputString.contains(marker) {
                requestStop(.uartOutputContains(marker))
            }
        }
        clearExclusiveReservation()
    }

}
