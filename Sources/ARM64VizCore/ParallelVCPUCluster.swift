import Foundation

final class ParallelVCPUClock: @unchecked Sendable {
    private static let frequency: UInt64 = 24_000_000
    private let lock = NSLock()
    private var counterTicks: UInt64 = 0
    private var lastHostNanoseconds = DispatchTime.now().uptimeNanoseconds

    func reset() {
        lock.lock()
        counterTicks = 0
        lastHostNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func synchronize(_ registers: inout ARM64SystemRegisterBank) {
        lock.lock()
        advanceFromHostClock()
        let ticks = counterTicks
        lock.unlock()
        registers.synchronizeCounterTicks(ticks)
    }

    func publish(_ ticks: UInt64) {
        lock.lock()
        advanceFromHostClock()
        counterTicks = max(counterTicks, ticks)
        lock.unlock()
    }

    var currentTicks: UInt64 {
        lock.lock()
        advanceFromHostClock()
        let ticks = counterTicks
        lock.unlock()
        return ticks
    }

    private func advanceFromHostClock() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- lastHostNanoseconds
        lastHostNanoseconds = now
        let seconds = elapsed / 1_000_000_000
        let nanoseconds = elapsed % 1_000_000_000
        counterTicks &+= seconds &* Self.frequency
        counterTicks &+= nanoseconds &* Self.frequency / 1_000_000_000
    }
}

public final class ParallelVCPUCluster: @unchecked Sendable {
    private final class SecondaryWorker: @unchecked Sendable {
        let id: Int
        let vm: VirtualMachine
        private let condition: NSCondition
        private let finished = DispatchSemaphore(value: 0)
        private var thread: Thread?
        private var shouldStop = false
        private var state: VirtualCPUArchitecturalState
        private var failureDescription: String?
        private var executedSteps: UInt64 = 0

        init(
            id: Int,
            vm: VirtualMachine,
            condition: NSCondition
        ) {
            self.id = id
            self.vm = vm
            self.condition = condition
            self.state = vm.externalVirtualCPUStateSnapshot()
        }

        func start() {
            let workerThread = Thread { [weak self] in
                self?.runLoop()
            }
            workerThread.name = "pinecone-vcpu-\(id)"
            // UIKit input and Metal presentation own userInteractive QoS. A
            // continuously runnable guest CPU at that class can starve the
            // host event loop on a physical iPhone even when VM throughput is
            // otherwise healthy.
            workerThread.qualityOfService = .userInitiated
            thread = workerThread
            workerThread.start()
        }

        func activate(entryPoint: GuestAddress, context: UInt64, counterTicks: UInt64) -> Bool {
            condition.lock()
            guard !shouldStop,
                  state.lifecycle == .offline || state.lifecycle == .halted else {
                condition.unlock()
                return false
            }
            var registers = ARM64SystemRegisterBank()
            registers.reset(
                mpidr: 0x8000_0000 | UInt64(id),
                counterTicks: counterTicks
            )
            var cpu = CPUState(pc: entryPoint, pstate: ARM64PState.el1hMasked)
            cpu.x[0] = context
            let architecture = VirtualCPUArchitecturalState(
                id: id,
                cpu: cpu,
                systemRegisters: registers,
                lifecycle: .runnable
            )
            vm.installExternalVirtualCPUState(architecture)
            state = architecture
            failureDescription = nil
            condition.broadcast()
            condition.unlock()
            return true
        }

        func reset(counterTicks: UInt64) {
            condition.lock()
            var registers = ARM64SystemRegisterBank()
            registers.reset(
                mpidr: 0x8000_0000 | UInt64(id),
                counterTicks: counterTicks
            )
            let architecture = VirtualCPUArchitecturalState(
                id: id,
                cpu: CPUState(),
                systemRegisters: registers,
                lifecycle: .offline
            )
            vm.installExternalVirtualCPUState(architecture)
            state = architecture
            failureDescription = nil
            executedSteps = 0
            condition.broadcast()
            condition.unlock()
        }

        func stop() {
            condition.lock()
            shouldStop = true
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilStopped() {
            guard thread != nil else { return }
            finished.wait()
            thread = nil
        }

        var snapshot: VirtualCPUArchitecturalState {
            condition.lock()
            let value = state
            condition.unlock()
            return value
        }

        var diagnostics: (steps: UInt64, failure: String?) {
            condition.lock()
            let value = (executedSteps, failureDescription)
            condition.unlock()
            return value
        }

        private func runLoop() {
            defer { finished.signal() }
            while true {
                condition.lock()
                while !shouldStop &&
                      (state.lifecycle == .offline || state.lifecycle == .halted) {
                    condition.wait()
                }
                if shouldStop {
                    condition.unlock()
                    return
                }
                if state.lifecycle == .waitingForInterrupt {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 1.0 / 120.0))
                    if shouldStop {
                        condition.unlock()
                        return
                    }
                }
                condition.unlock()

                do {
                    let result = try vm.run(maxSteps: 262_144)
                    let currentState = vm.externalVirtualCPUStateSnapshot()
                    condition.lock()
                    executedSteps &+= UInt64(max(0, result.steps))
                    state = currentState
                    if case .halted = result.stopReason {
                        state.lifecycle = .halted
                    }
                    condition.unlock()
                } catch {
                    condition.lock()
                    failureDescription = String(describing: error)
                    state = vm.externalVirtualCPUStateSnapshot()
                    state.lifecycle = .halted
                    condition.unlock()
                }
            }
        }
    }

    public let primary: VirtualMachine
    private let clock = ParallelVCPUClock()
    private let condition = NSCondition()
    private var workers: [SecondaryWorker] = []
    private let stopLock = NSLock()
    private var stopped = false

    init(primary: VirtualMachine) {
        precondition(primary.virtualCPUCount > 1)
        self.primary = primary
        self.workers = (1..<primary.virtualCPUCount).map { id in
            let backend = SoftwareARM64Backend()
            backend.enableBasicBlockExecution = true
            backend.fallbackInterpreterPolicy = .nativeOnly
            let vm = VirtualMachine(
                memory: primary.memory,
                mmio: primary.mmio,
                interruptController: primary.interruptController,
                backend: backend,
                virtualCPUCount: primary.virtualCPUCount
            )
            vm.timerCyclesPerInstruction = primary.timerCyclesPerInstruction
            vm.wallClockRunBudgetNanoseconds = primary.wallClockRunBudgetNanoseconds
            vm.nativeCheckpointBlockInterval = primary.nativeCheckpointBlockInterval
            vm.hostPreemptionGenerationProvider = primary.hostPreemptionGenerationProvider
            vm.exceptionStormThreshold = 0
            vm.systemRegisterTraceCapacity = 0
            vm.systemRegisterReadTraceCapacity = 0
            vm.disableInstructionTrace()
            vm.enableMMIOTrace(capacity: 0)
            vm.configureExternalParallelExecution(vcpuID: id, clock: clock)
            return SecondaryWorker(id: id, vm: vm, condition: condition)
        }

        primary.configureExternalParallelExecution(
            vcpuID: 0,
            clock: clock,
            stateProvider: { [weak self] in
                self?.states ?? []
            },
            cpuStartHandler: { [weak self] id, entryPoint, context in
                self?.startVirtualCPU(id: id, entryPoint: entryPoint, context: context) ?? false
            },
            resetHandler: { [weak self] _ in
                self?.resetSecondaries()
            }
        )
        (primary.interruptController as? SimpleInterruptController)?
            .setWakeHandler { [weak self] in self?.signal() }
        workers.forEach { $0.start() }
    }

    deinit {
        stop()
    }

    public var states: [VirtualCPUArchitecturalState] {
        [primary.externalVirtualCPUStateSnapshot()] + workers.map(\.snapshot)
    }

    public var diagnosticsSummary: String {
        let diagnostics = workers.map(\.diagnostics)
        let steps = diagnostics.reduce(UInt64(0)) { $0 &+ $1.steps }
        let failures = diagnostics.compactMap(\.failure)
        return " smp=parallel/\(primary.virtualCPUCount) secondary=\(steps)" +
            (failures.isEmpty ? "" : " smp-error=\(failures.joined(separator: ","))")
    }

    public func signal() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    public func configureExecution(
        timerCyclesPerInstruction: UInt64,
        wallClockRunBudgetNanoseconds: UInt64?,
        nativeCheckpointBlockInterval: UInt64,
        hostPreemptionGenerationProvider: (@Sendable () -> UInt64)?,
        fallbackInterpreterPolicy: ARM64FallbackInterpreterPolicy
    ) {
        condition.lock()
        for worker in workers {
            worker.vm.timerCyclesPerInstruction = timerCyclesPerInstruction
            worker.vm.wallClockRunBudgetNanoseconds = wallClockRunBudgetNanoseconds
            worker.vm.nativeCheckpointBlockInterval = max(1, nativeCheckpointBlockInterval)
            worker.vm.hostPreemptionGenerationProvider = hostPreemptionGenerationProvider
            if let backend = worker.vm.backend as? SoftwareARM64Backend {
                backend.enableBasicBlockExecution = true
                backend.fallbackInterpreterPolicy = fallbackInterpreterPolicy
            }
        }
        condition.unlock()
    }

    public func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        (primary.interruptController as? SimpleInterruptController)?
            .setWakeHandler(nil)
        workers.forEach { $0.stop() }
        workers.forEach { $0.waitUntilStopped() }
    }

    private func startVirtualCPU(
        id: Int,
        entryPoint: GuestAddress,
        context: UInt64
    ) -> Bool {
        guard let worker = workers.first(where: { $0.id == id }) else {
            return false
        }
        return worker.activate(
            entryPoint: entryPoint,
            context: context,
            counterTicks: clock.currentTicks
        )
    }

    private func resetSecondaries() {
        clock.reset()
        workers.forEach { $0.reset(counterTicks: 0) }
    }
}
