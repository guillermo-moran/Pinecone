import XCTest
@testable import ARM64VizCore

final class ARM64MultiVCPUTests: XCTestCase {
    func testPerformanceTimelineRecordsStableBootAndTouchMetrics() throws {
        let clock = TestClock(now: 1_000_000_000)
        let timeline = VMPerformanceTimeline(startNanoseconds: clock.now) { clock.now }
        clock.now += 250_000_000
        XCTAssertTrue(timeline.mark(.shellPrompt))
        clock.now += 750_000_000
        XCTAssertTrue(timeline.mark(.firstVisibleFrame))
        XCTAssertFalse(timeline.mark(.firstVisibleFrame))
        clock.now += 25_000_000
        XCTAssertTrue(timeline.mark(.interactiveWorkloadStarted))
        clock.now += 75_000_000
        XCTAssertTrue(timeline.mark(.interactiveWorkloadReady))
        timeline.recordTouchLatency(nanoseconds: 8_000_000)
        timeline.recordTouchLatency(nanoseconds: 20_000_000)
        timeline.recordTouchLatency(nanoseconds: 12_000_000)
        timeline.recordFramePublished(
            generation: 7,
            committedAtNanoseconds: clock.now + 1_000_000,
            publishedAtNanoseconds: clock.now + 3_000_000,
            damagedByteCount: 4_096
        )
        timeline.recordFramePresented(
            generation: 7,
            presentedAtNanoseconds: clock.now + 11_000_000,
            uploadedByteCount: 1_024
        )

        let snapshot = timeline.snapshot()
        XCTAssertEqual(snapshot.elapsedMilliseconds["guestExecutionStarted"], 0)
        XCTAssertEqual(snapshot.elapsedMilliseconds["shellPrompt"], 250)
        XCTAssertEqual(snapshot.elapsedMilliseconds["firstVisibleFrame"], 1_000)
        XCTAssertEqual(snapshot.elapsedMilliseconds["interactiveWorkloadStarted"], 1_025)
        XCTAssertEqual(snapshot.elapsedMilliseconds["interactiveWorkloadReady"], 1_100)
        XCTAssertEqual(snapshot.touchLatencyP50Milliseconds, 12)
        XCTAssertEqual(snapshot.touchLatencyP95Milliseconds, 20)
        XCTAssertEqual(snapshot.touchSampleCount, 3)
        XCTAssertEqual(snapshot.framePipeline.frameSampleCount, 1)
        XCTAssertEqual(snapshot.framePipeline.commitToPublishP95Milliseconds, 2)
        XCTAssertEqual(snapshot.framePipeline.publishToPresentP95Milliseconds, 8)
        XCTAssertEqual(snapshot.framePipeline.commitToPresentP95Milliseconds, 10)
        XCTAssertEqual(snapshot.framePipeline.damagedBytes, 4_096)
        XCTAssertEqual(snapshot.framePipeline.uploadedBytes, 1_024)
        XCTAssertNoThrow(try JSONEncoder().encode(snapshot))
    }

    func testParallelClusterExecutesSecondaryCPUOnPersistentWorker() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)

        XCTAssertTrue(
            machine.vm.startVirtualCPU(
                id: 1,
                entryPoint: secondaryEntry,
                context: 0xfeed
            )
        )
        let primaryResult = try machine.vm.run(maxSteps: 1)
        XCTAssertEqual(primaryResult.steps, 1)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 4)
        XCTAssertTrue(waitUntil(timeout: 1) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .halted
        })
        let secondary = try XCTUnwrap(machine.vm.virtualCPUState(id: 1))
        XCTAssertEqual(secondary.cpu.pc, secondaryEntry + 4)
        XCTAssertEqual(secondary.cpu.x[0], 0xfeed)
        XCTAssertTrue(cluster.diagnosticsSummary.contains("smp=parallel/2"))
    }

    func testParallelClusterWakesSecondaryWFIWithTargetedInterrupt() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([
            0xd503_207f, // wfi
            0x9100_0400, // add x0, x0, #1
            0xd440_0000  // hlt
        ]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 9))
        XCTAssertTrue(waitUntil(timeout: 1) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .waitingForInterrupt
        })

        machine.vm.interruptController.setEnabled(line: 5, enabled: true, targetVCPU: 1)
        machine.vm.interruptController.raise(line: 5, targetVCPU: 1)
        XCTAssertTrue(waitUntil(timeout: 1) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .halted
        })
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.cpu.x[0], 10)
    }

    func testParallelClusterStopQuiescesSecondaryExecution() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([
            0x9100_0400, // add x0, x0, #1
            0x17ff_ffff  // b .-4
        ]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)

        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))
        XCTAssertTrue(waitUntil(timeout: 1) {
            (machine.vm.virtualCPUState(id: 1)?.cpu.x[0] ?? 0) > 0
        })

        cluster.stop()
        let stoppedState = try XCTUnwrap(machine.vm.virtualCPUState(id: 1))
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(machine.vm.virtualCPUState(id: 1), stoppedState)
    }

    func testBroadcastTLBIInvalidatesNativeTranslationCacheOnPeerVCPU() throws {
        let primaryBackend = SoftwareARM64Backend()
        primaryBackend.fallbackInterpreterPolicy = .nativeOnly
        let secondaryBackend = SoftwareARM64Backend()
        secondaryBackend.fallbackInterpreterPolicy = .nativeOnly
        let memory = PhysicalMemory(
            base: ARM64VizMachineLayout.ramBase,
            size: 8 * 1024 * 1024
        )
        let primary = VirtualMachine(memory: memory, backend: primaryBackend)
        let secondary = VirtualMachine(memory: memory, backend: secondaryBackend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1_000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2_000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3_000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4_000
        let codePhysical = ARM64VizMachineLayout.ramBase + 0x10_000
        let dataPhysicalA = ARM64VizMachineLayout.ramBase + 0x11_000
        let dataPhysicalB = ARM64VizMachineLayout.ramBase + 0x12_000
        let codeVirtual: GuestAddress = 0x1_000
        let dataVirtual: GuestAddress = 0x2_000

        try memory.write64(table1 | 0x3, at: table0)
        try memory.write64(table2 | 0x3, at: table1)
        try memory.write64(table3 | 0x3, at: table2)
        try memory.write64(codePhysical | 0x403, at: table3 + 8)
        try memory.write64(dataPhysicalA | 0x403, at: table3 + 16)
        try primary.loadBinary(littleEndianWords([
            0xf940_0020, // ldr x0, [x1]
            0xd440_0000  // hlt
        ]), at: codePhysical)
        try memory.write64(0x1111_1111_1111_1111, at: dataPhysicalA)
        try memory.write64(0x2222_2222_2222_2222, at: dataPhysicalB)

        for vm in [primary, secondary] {
            vm.reset(entryPoint: codeVirtual)
            vm.cpu.x[1] = dataVirtual
            vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0)
            vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
            vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
            vm.systemRegisterTraceCapacity = 0
            vm.systemRegisterReadTraceCapacity = 0
            vm.disableInstructionTrace()
            vm.enableMMIOTrace(capacity: 0)
            vm.enableGuestMemoryTrace(capacity: 0)
            vm.timerCyclesPerInstruction = 0
            _ = try vm.run(maxSteps: 1)
            XCTAssertEqual(vm.cpu.x[0], 0x1111_1111_1111_1111)
        }

        try memory.write64(dataPhysicalB | 0x403, at: table3 + 16)
        primary.executeSystemMaintenanceInstruction(0xd508_831f) // tlbi vmalle1is
        let missesBeforeTLBI = secondaryBackend.nativeReadTLBMisses
        secondary.cpu.pc = codeVirtual
        secondary.cpu.x[0] = 0
        _ = try secondary.run(maxSteps: 1)

        XCTAssertEqual(secondary.cpu.x[0], 0x2222_2222_2222_2222)
        XCTAssertGreaterThan(secondaryBackend.nativeReadTLBMisses, missesBeforeTLBI)
        XCTAssertEqual(primaryBackend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(secondaryBackend.swiftFallbackSingleInstructionSteps, 0)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    func testNativePSCICPUOnStartsSecondaryCPUWithoutInterpreterFallback() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        let context: UInt64 = 0x1234_5678_9abc_def0

        try machine.vm.loadBinary(littleEndianWords([0xd400_0002, 0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0xc400_0003
        machine.vm.cpu.x[1] = 1
        machine.vm.cpu.x[2] = secondaryEntry
        machine.vm.cpu.x[3] = context

        let result = try backend.run(vm: machine.vm, maxSteps: 1)
        let secondary = try XCTUnwrap(machine.vm.virtualCPUState(id: 1))

        XCTAssertEqual(result.stopReason, .maxSteps(1))
        XCTAssertEqual(machine.vm.cpu.x[0], 0)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 4)
        XCTAssertEqual(secondary.lifecycle, .runnable)
        XCTAssertEqual(secondary.cpu.pc, secondaryEntry)
        XCTAssertEqual(secondary.cpu.x[0], context)
        XCTAssertEqual(
            secondary.systemRegisters.rawValue(for: ARM64SystemRegister.mpidrEL1),
            0x8000_0001
        )
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty)
        XCTAssertGreaterThanOrEqual(
            backend.nativeBasicBlockSteps + backend.nativeSingleInstructionSteps,
            1
        )
    }

    func testCooperativeSchedulerRunsBothVirtualCPUsToCompletion() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100

        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0x55aa))

        let result = try machine.vm.run(maxSteps: 8)
        let states = machine.vm.virtualCPUStates

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(states.map(\.lifecycle), [.halted, .halted])
        XCTAssertEqual(states[0].cpu.pc, entry + 4)
        XCTAssertEqual(states[1].cpu.pc, secondaryEntry + 4)
        XCTAssertEqual(states[1].cpu.x[0], 0x55aa)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testPendingInterruptCannotStarveAnotherRunnableVirtualCPU() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0x1400_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.virtualCPUQuantumSteps = 1
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))
        machine.vm.interruptController.setEnabled(line: 5, enabled: true, targetVCPU: 1)
        machine.vm.interruptController.raise(line: 5, targetVCPU: 1)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .maxSteps(4))
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.lifecycle, .halted)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.lifecycle, .runnable)
    }

    func testContextSwitchInvalidatesCrossVCPUExclusiveReservation() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        let dataAddress = entry + 0x200
        try machine.vm.loadBinary(littleEndianWords([
            0xc85f_7c20, // ldxr x0, [x1]
            0xc802_7c23, // stxr w2, x3, [x1]
            0xd440_0000
        ]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([
            0xf900_001f, // str xzr, [x0]
            0xd440_0000
        ]), at: secondaryEntry)
        try machine.vm.memory.write64(0x1111_2222_3333_4444, at: dataAddress)
        machine.vm.reset(entryPoint: entry)
        machine.vm.virtualCPUQuantumSteps = 1
        machine.vm.cpu.x[1] = dataAddress
        machine.vm.cpu.x[3] = 0xaaaa_bbbb_cccc_dddd
        XCTAssertTrue(
            machine.vm.startVirtualCPU(
                id: 1,
                entryPoint: secondaryEntry,
                context: dataAddress
            )
        )

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.cpu.x[2], 1)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataAddress), 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty)
    }

    func testContextSwitchPreservesContextTaggedTranslationCaches() throws {
        let backend = TranslationInvalidationCountingBackend()
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        machine.vm.reset(entryPoint: entry)
        machine.vm.virtualCPUQuantumSteps = 1
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))
        let invalidationsBeforeRun = backend.translationInvalidationCount

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .maxSteps(4))
        XCTAssertEqual(backend.translationInvalidationCount, invalidationsBeforeRun)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.cpu.pc, secondaryEntry + 8)
    }

    func testGICSoftwareInterruptTargetsOnlySelectedVirtualCPU() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        let softwareInterrupt: UInt32 = 5
        let targetCPU1 = UInt64(1 << 17)

        try machine.gic.write(
            offset: 0xf00,
            width: .word,
            value: targetCPU1 | UInt64(softwareInterrupt)
        )

        XCTAssertNil(machine.vm.interruptController.peekPending(targetVCPU: 0))
        XCTAssertEqual(
            machine.vm.interruptController.peekPending(targetVCPU: 1),
            softwareInterrupt
        )
        XCTAssertEqual((try machine.gic.read(offset: 0x004, width: .word) >> 5) & 0x7, 1)
    }

    func testGICTargetRegistersExposeCPUMapAndRouteSharedInterrupts() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        let sharedInterrupt: UInt32 = 33

        XCTAssertEqual(try machine.gic.read(offset: 0x800, width: .word), 0x0101_0101)
        XCTAssertEqual(try machine.gic.read(offset: 0x820, width: .word), 0x0101_0101)

        try machine.gic.write(offset: 0x820, width: .word, value: 0x0202_0202)
        machine.vm.interruptController.setEnabled(line: sharedInterrupt, enabled: true)
        machine.vm.interruptController.raise(line: sharedInterrupt)

        XCTAssertNil(machine.vm.interruptController.peekPending(targetVCPU: 0))
        XCTAssertEqual(
            machine.vm.interruptController.peekPending(targetVCPU: 1),
            sharedInterrupt
        )
        XCTAssertEqual(
            machine.vm.interruptController.acknowledge(targetVCPU: 1),
            sharedInterrupt
        )
        machine.vm.interruptController.complete(line: sharedInterrupt, targetVCPU: 1)
        XCTAssertNil(machine.vm.interruptController.activeLine(targetVCPU: 1))
    }

    func testGICTargetRegisterByteWritePreservesAdjacentInterruptTargets() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)

        try machine.gic.write(offset: 0x821, width: .byte, value: 0x02)

        XCTAssertEqual(machine.vm.interruptController.targetMask(line: 32), 0x01)
        XCTAssertEqual(machine.vm.interruptController.targetMask(line: 33), 0x02)
        XCTAssertEqual(machine.vm.interruptController.targetMask(line: 34), 0x01)
        XCTAssertEqual(machine.vm.interruptController.targetMask(line: 35), 0x01)
        XCTAssertEqual(try machine.gic.read(offset: 0x821, width: .byte), 0x02)
        XCTAssertEqual(try machine.gic.read(offset: 0x820, width: .word), 0x0101_0201)
    }

    func testSMPUARTReceiveInterruptRemainsRoutableAfterByteTargetWrite() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)

        try machine.gic.write(offset: 0x821, width: .byte, value: 0x01)
        machine.vm.interruptController.setEnabled(line: 33, enabled: true)
        try machine.uart.write(
            offset: 0x38,
            width: .word,
            value: UInt64(VirtualUART.receiveInterrupt)
        )
        machine.uart.injectReceiveBytes([0x0a])

        XCTAssertEqual(machine.vm.interruptController.peekPending(targetVCPU: 0), 33)
        XCTAssertNil(machine.vm.interruptController.peekPending(targetVCPU: 1))
        XCTAssertEqual(try machine.uart.read(offset: 0x00, width: .word), 0x0a)
        XCTAssertNil(machine.vm.interruptController.peekPending(targetVCPU: 0))
    }

    func testLinuxDirectBootPublishesPSCIAndTwoCPUDeviceTree() throws {
        let machine = try MachineFactory.makeResearchMachine(
            memorySize: 32 * 1024 * 1024,
            virtualCPUCount: 2
        )
        let adapter = LinuxDirectBootAdapter(
            artifacts: LinuxBootArtifacts(kernelImage: littleEndianWords([0xd440_0000]))
        )

        let result = try adapter.loadWithResult(into: machine.vm)
        let strings = String(decoding: result.deviceTreeBlob, as: UTF8.self)

        XCTAssertEqual(result.configuration.cpuCount, 2)
        XCTAssertEqual(result.configuration.cpuEnableMethod, "psci")
        XCTAssertEqual(result.configuration.psciMethod, "hvc")
        XCTAssertTrue(result.configuration.renderDTS().contains("cpu@1"))
        XCTAssertTrue(strings.contains("cpu@1"))
        XCTAssertTrue(strings.contains("enable-method"))
        XCTAssertTrue(strings.contains("arm,psci-1.0"))
        XCTAssertTrue(strings.contains("hvc"))
    }

    func testSnapshotRestoresSecondaryCPUState() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        machine.vm.reset(entryPoint: entry)
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0xcafe))
        let snapshot = machine.vm.makeSnapshot()

        machine.vm.reset(entryPoint: entry)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.lifecycle, .offline)
        try machine.vm.restoreSnapshot(snapshot)

        let secondary = try XCTUnwrap(machine.vm.virtualCPUState(id: 1))
        XCTAssertEqual(secondary.lifecycle, .runnable)
        XCTAssertEqual(secondary.cpu.pc, secondaryEntry)
        XCTAssertEqual(secondary.cpu.x[0], 0xcafe)
        XCTAssertEqual(snapshot.version, 3)
    }

    func testWaitForInterruptDoesNotFastForwardWhileAnotherSMPCPUIsRunnable() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd503_207f, 0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0x1400_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))
        machine.vm.writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 1_000)
        machine.vm.writeSystemRegister(ARM64SystemRegister.cntvCtlEL0, value: 1)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .maxSteps(4))
        XCTAssertEqual(machine.vm.timerFastForwardCount, 0)
        XCTAssertEqual(machine.vm.timerFastForwardCycles, 0)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.lifecycle, .waitingForInterrupt)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.lifecycle, .runnable)
    }

    func testSMPWaitForInterruptYieldsUntilTargetedInterruptArrives() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd503_207f, 0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate |= ARM64PState.irqMask
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))

        let sleeping = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(sleeping.stopReason, .maxSteps(8))
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.lifecycle, .waitingForInterrupt)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.lifecycle, .halted)
        XCTAssertEqual(machine.vm.waitingVirtualCPUCount, 1)

        machine.vm.interruptController.raise(line: 5, targetVCPU: 0)
        let awakened = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(awakened.stopReason, .halted)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.lifecycle, .halted)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.cpu.pc, entry + 8)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty)
    }

    func testAllWaitingSMPVirtualCPUsFastForwardToEarliestTimer() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(
            backend: backend,
            virtualCPUCount: 2
        )
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = entry + 0x100
        try machine.vm.loadBinary(littleEndianWords([0xd503_207f, 0xd440_0000]), at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd503_207f]), at: secondaryEntry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate |= ARM64PState.irqMask
        XCTAssertTrue(machine.vm.startVirtualCPU(id: 1, entryPoint: secondaryEntry, context: 0))
        machine.vm.interruptController.setEnabled(
            line: VirtualMachine.virtualTimerIRQ,
            enabled: true,
            targetVCPU: 0
        )
        machine.vm.writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 100)
        machine.vm.writeSystemRegister(ARM64SystemRegister.cntvCtlEL0, value: 1)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .maxSteps(8))
        XCTAssertEqual(machine.vm.timerFastForwardCount, 1)
        XCTAssertGreaterThanOrEqual(machine.vm.timerFastForwardCycles, 98)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 0)?.lifecycle, .halted)
        XCTAssertEqual(machine.vm.virtualCPUState(id: 1)?.lifecycle, .waitingForInterrupt)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty)
    }

    private func littleEndianWords(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in
            [
                UInt8(word & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 24) & 0xff)
            ]
        }
    }
}

private final class TestClock: @unchecked Sendable {
    var now: UInt64

    init(now: UInt64) {
        self.now = now
    }
}

private final class TranslationInvalidationCountingBackend: VirtualMachineBackend {
    let name = "translation-invalidation-counting"
    private(set) var translationInvalidationCount = 0

    func run(vm: VirtualMachine, maxSteps: Int) throws -> RunResult {
        vm.cpu.pc &+= 4
        return RunResult(steps: 1, stopReason: .maxSteps(maxSteps))
    }

    func invalidateCodeCache(physicalAddress: GuestAddress, byteCount: UInt64) {}

    func invalidateTranslationCache(for vm: VirtualMachine) {
        translationInvalidationCount += 1
    }
}
