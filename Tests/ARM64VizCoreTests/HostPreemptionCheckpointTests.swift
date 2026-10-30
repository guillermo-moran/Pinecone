import Foundation
import XCTest
@testable import ARM64VizCore

final class HostPreemptionCheckpointTests: XCTestCase {
    func testProviderRetainsOnlySignalUntilLastProviderReleasesIt() {
        var signal: HostPreemptionSignal? = HostPreemptionSignal()
        weak var weakSignal: HostPreemptionSignal?
        weakSignal = signal
        var primary: (@Sendable () -> UInt64)? = signal?.makeGenerationProvider()
        var secondary = primary
        signal?.signal()
        signal = nil

        XCTAssertNotNil(weakSignal)
        XCTAssertEqual(primary?(), 1)
        primary = nil
        weakSignal?.signal()
        XCTAssertEqual(secondary?(), 2, "A surviving vCPU must not observe a synthetic zero")
        secondary = nil
        XCTAssertNil(weakSignal, "The provider and signal must not form a retain cycle")
    }

    func testConcurrentSignalsAreNotLostOrConsumedByReaders() {
        let signal = HostPreemptionSignal()
        let primary = signal.makeGenerationProvider()
        let secondary = signal.makeGenerationProvider()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            var previous: UInt64 = 0
            for _ in 0..<1_000 {
                signal.signal()
                let current = primary()
                XCTAssertGreaterThanOrEqual(current, previous)
                previous = current
            }
        }
        XCTAssertEqual(primary(), 4_000)
        XCTAssertEqual(secondary(), 4_000)
        XCTAssertEqual(primary(), 4_000)
    }

    func testStableGenerationDoesNotShortenNativeRun() throws {
        let (vm, backend) = try makeLoopVM()
        let signal = HostPreemptionSignal()
        signal.signal() // Input before a run is part of its initial baseline.
        vm.hostPreemptionGenerationProvider = signal.makeGenerationProvider()

        let result = try vm.run(maxSteps: 128)

        XCTAssertEqual(result.steps, 128)
        XCTAssertEqual(result.stopReason, .maxSteps(128))
        XCTAssertEqual(vm.cpu.x[0], 64)
        assertNativeOnly(backend)
    }

    func testSignalAtCheckpointPreemptsWithoutExtraPollOrStickyYield() throws {
        let (vm, backend) = try makeLoopVM()
        let signal = HostPreemptionSignal()
        let probe = CheckpointProbe(provider: signal.makeGenerationProvider()) {
            signal.signal()
        }
        vm.hostPreemptionGenerationProvider = { probe.read() }

        let result = try vm.run(maxSteps: 100_000)

        XCTAssertEqual(probe.readCount, 2, "Yield on the poll that observes the change")
        XCTAssertEqual(result.stopReason, .maxSteps(100_000))
        XCTAssertGreaterThan(result.steps, 0)
        XCTAssertLessThanOrEqual(result.steps, 65_536, "Do not exceed the existing native burst bound")
        let stepsBeforeResume = vm.cpu.x[0]
        let resumed = try vm.run(maxSteps: 128)
        XCTAssertEqual(resumed.steps, 128)
        XCTAssertEqual(vm.cpu.x[0], stepsBeforeResume + 64)
        assertNativeOnly(backend)
    }

    func testStableProviderDoesNotHideIRQArrivingAtCheckpoint() throws {
        let (vm, backend) = try makeLoopVM()
        let signal = HostPreemptionSignal()
        let controller = vm.interruptController
        let probe = CheckpointProbe(provider: signal.makeGenerationProvider()) {
            controller.raise(line: 5, targetVCPU: 0)
        }
        vm.hostPreemptionGenerationProvider = { probe.read() }
        vm.cpu.pstate = ARM64PState.el1h
        vm.writeSystemRegister(ARM64SystemRegister.vbarEL1, value: 0x4_000)

        let result = try vm.run(maxSteps: 100_000)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertLessThanOrEqual(result.steps, 65_537, "The IRQ handler halts immediately after the burst")
        XCTAssertEqual(vm.exceptionTrace.last?.source, .irq)
        XCTAssertEqual(controller.peekPending(targetVCPU: 0), 5, "Polling must not acknowledge IRQs")
        assertNativeOnly(backend)
    }

    // Invoked only on the executing vCPU thread. The second read is the first
    // native checkpoint after the burst's initial generation snapshot.
    private final class CheckpointProbe: @unchecked Sendable {
        let provider: @Sendable () -> UInt64
        let onSecondRead: () -> Void
        var readCount = 0

        init(provider: @escaping @Sendable () -> UInt64, onSecondRead: @escaping () -> Void) {
            self.provider = provider
            self.onSecondRead = onSecondRead
        }

        func read() -> UInt64 {
            readCount += 1
            if readCount == 2 { onSecondRead() }
            return provider()
        }
    }

    private func makeLoopVM() throws -> (VirtualMachine, SoftwareARM64Backend) {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let base = ARM64VizMachineLayout.ramBase
        let memory = PhysicalMemory(base: base, size: 128 * 1024)
        let vm = VirtualMachine(memory: memory, backend: backend)
        let table0 = base + 0x1_000
        let table1 = base + 0x2_000
        let table2 = base + 0x3_000
        let table3 = base + 0x4_000
        let code = base + 0x10_000
        let vectors = base + 0x11_000
        try memory.write64(table1 | 3, at: table0)
        try memory.write64(table2 | 3, at: table1)
        try memory.write64(table3 | 3, at: table2)
        try memory.write64(code | 0x403, at: table3 + 8)
        try memory.write64(vectors | 0x403, at: table3 + 32)
        try memory.write32(0x9100_0400, at: code)     // add x0, x0, #1
        try memory.write32(0x17ff_ffff, at: code + 4) // b #-4
        try memory.write32(0xd440_0000, at: vectors + 0x280) // EL1h IRQ: hlt
        vm.reset(entryPoint: 0x1_000)
        vm.cpu.pstate = ARM64PState.el1h
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0)
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.timerCyclesPerInstruction = 0
        vm.nativeCheckpointBlockInterval = 1
        return (vm, backend)
    }

    private func assertNativeOnly(
        _ backend: SoftwareARM64Backend,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(backend.nativeBasicBlockSteps, 0, file: file, line: line)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0, file: file, line: line)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0, file: file, line: line)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty, file: file, line: line)
    }
}
