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
        XCTAssertTrue(timeline.mark(
            .interactiveWorkloadReady,
            execution: VMExecutionMilestoneSnapshot(
                primaryNativeSteps: 900_000_000,
                primaryFallbackSteps: 0,
                secondarySteps: 400_000_000
            )
        ))
        clock.now += 25_000_000
        XCTAssertTrue(timeline.mark(
            .applicationLaunchRequested,
            execution: VMExecutionMilestoneSnapshot(
                primaryNativeSteps: 920_000_000,
                primaryFallbackSteps: 0,
                secondarySteps: 420_000_000
            )
        ))
        clock.now += 250_000_000
        XCTAssertTrue(timeline.mark(
            .applicationFirstVisibleFrame,
            execution: VMExecutionMilestoneSnapshot(
                primaryNativeSteps: 980_000_000,
                primaryFallbackSteps: 0,
                secondarySteps: 470_000_000
            )
        ))
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
        XCTAssertEqual(snapshot.elapsedMilliseconds["applicationLaunchRequested"], 1_125)
        XCTAssertEqual(snapshot.elapsedMilliseconds["applicationFirstVisibleFrame"], 1_375)
        XCTAssertEqual(
            snapshot.executionAtMilestones["interactiveWorkloadReady"],
            VMExecutionMilestoneSnapshot(
                primaryNativeSteps: 900_000_000,
                primaryFallbackSteps: 0,
                secondarySteps: 400_000_000
            )
        )
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

    func testPerformanceTimelineExcludesIdlePresentationGaps() {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0) { 0 }
        timeline.recordFramePresented(
            generation: 1,
            presentedAtNanoseconds: 100_000_000,
            uploadedByteCount: 0
        )
        timeline.recordFramePresented(
            generation: 2,
            presentedAtNanoseconds: 3_100_000_000,
            uploadedByteCount: 0
        )
        timeline.recordFramePresented(
            generation: 3,
            presentedAtNanoseconds: 3_116_000_000,
            uploadedByteCount: 0
        )

        XCTAssertEqual(
            timeline.snapshot().framePipeline.presentationIntervalP95Milliseconds,
            16
        )
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
        try machine.vm.loadBinary(littleEndianWords([
            0x9100_0400, // add x0, x0, #1
            0xd440_0000  // hlt
        ]), at: secondaryEntry)
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
        XCTAssertEqual(secondary.cpu.pc, secondaryEntry + 8)
        XCTAssertEqual(secondary.cpu.x[0], 0xfeee)
        XCTAssertGreaterThanOrEqual(cluster.secondaryExecutionTotals.nativeSteps, 1)
        XCTAssertEqual(cluster.secondaryExecutionTotals.fallbackSteps, 0)
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

    func testParallelClusterSerializesKernelStyleExclusiveSpinLock() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let lockAddress = entry + 0x1_000
        let counterAddress = lockAddress + 0x2_000
        let iterations: UInt64 = 20_000

        // This is the same LDAXR/STXR locking shape used by the Linux queued
        // spinlocks that protect ext4's allocation bitmaps. The counter in the
        // critical section is deliberately non-atomic and lives on a separate
        // guest page from the lock. Any lost increment means guest ordering
        // failed; host page-stripe locking cannot hide that failure.
        let program: [UInt32] = [
            0x9140_0801, // add x1, x0, #2, lsl #12
            0x5289_c402, // mov w2, #20000
            0x885f_fc03, // ldaxr w3, [x0]
            0x35ff_ffe3, // cbnz w3, .-4
            0x5280_0024, // mov w4, #1
            0x8805_7c04, // stxr w5, w4, [x0]
            0x35ff_ff85, // cbnz w5, .-16
            0xf940_0026, // ldr x6, [x1]
            0x9100_04c6, // add x6, x6, #1
            0xf900_0026, // str x6, [x1]
            0x089f_fc1f, // stlrb wzr, [x0]
            0x7100_0442, // subs w2, w2, #1
            0x54ff_fec1, // b.ne .-40
            0xd440_0000  // hlt
        ]
        try machine.vm.loadBinary(littleEndianWords(program), at: entry)
        try machine.vm.memory.write64(0, at: lockAddress)
        try machine.vm.memory.write64(0, at: counterAddress)
        machine.vm.memory.beginConcurrentExecution()
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = lockAddress

        XCTAssertTrue(
            machine.vm.startVirtualCPU(
                id: 1,
                entryPoint: entry,
                context: lockAddress
            )
        )
        let primary = try machine.vm.run(maxSteps: 2_000_000)
        XCTAssertEqual(primary.stopReason, .halted)
        XCTAssertTrue(waitUntil(timeout: 10) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .halted
        })
        let exclusive = machine.vm.memory.nativeExclusiveStatistics
        XCTAssertEqual(
            try machine.vm.memory.read64(at: counterAddress),
            iterations * 2,
            "exclusive reads=\(exclusive.reads) successes=\(exclusive.write_successes) conflicts=\(exclusive.write_conflicts)"
        )
        XCTAssertEqual(try machine.vm.memory.read32(at: lockAddress), 0)
    }

    func testParallelClusterSerializesQueuedSpinLockPendingPath() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let lockAddress = entry + 0x1_000
        let counterAddress = lockAddress + 0x2_000
        let iterations: UInt64 = 20_000

        // Linux's two-CPU queued-spinlock pending path mixes 32-bit
        // exclusives with byte acquire/release and a halfword claim on the
        // same lock word. The real queue escalation requires per-CPU qnodes;
        // this fixture retries the pending observation instead.
        let program: [UInt32] = [
            0x9140_0807, 0x5289_c402,
            0xf980_0011, 0x885f_fc03, 0x3500_00a3, 0x5280_0024,
            0x8805_7c04, 0x35ff_ff65, 0x1400_0003,
            0x2a03_03e1, 0x9400_0008,
            0xf940_00e6, 0x9100_04c6, 0xf900_00e6, 0x089f_fc1f,
            0x7100_0442, 0x54ff_fe41, 0xd440_0000,
            0x7104_003f, 0x5400_0181, 0xb940_0001, 0x7104_003f,
            0x5400_0121, 0x5280_2008, 0xd503_20bf, 0xd503_205f,
            0x885f_7c09, 0x4a08_0129, 0x3500_0049, 0xd503_205f,
            0xb940_0001, 0x7103_fc3f, 0x54ff_ffc8, 0xf980_0011,
            0x885f_fc08, 0x3218_0109, 0x880a_7c09, 0x35ff_ff8a,
            0x7104_011f, 0x5400_0242, 0x3400_01c8, 0x08df_fc08,
            0x7200_1d1f, 0x5400_0160, 0x9240_1d08, 0xd503_20bf,
            0xd503_205f, 0x085f_7c09, 0x4a08_0129, 0x3500_0049,
            0xd503_205f, 0x08df_fc08, 0x7200_1d1f, 0x54ff_fe81,
            0x5280_0028, 0x7900_0008, 0xd65f_03c0, 0x7218_1d1f,
            0x5400_0041, 0x3900_041f, 0xd503_203f, 0x17ff_ffe2
        ]
        try machine.vm.loadBinary(littleEndianWords(program), at: entry)
        try machine.vm.memory.write64(0, at: lockAddress)
        try machine.vm.memory.write64(0, at: counterAddress)
        machine.vm.memory.beginConcurrentExecution()
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = lockAddress

        XCTAssertTrue(machine.vm.startVirtualCPU(
            id: 1,
            entryPoint: entry,
            context: lockAddress
        ))
        let primary = try machine.vm.run(maxSteps: 10_000_000)
        XCTAssertEqual(primary.stopReason, .halted)
        let secondaryHalted = waitUntil(timeout: 10) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .halted
        }
        let secondaryState = machine.vm.virtualCPUState(id: 1)
        let lockValue = try machine.vm.memory.read32(at: lockAddress)
        XCTAssertTrue(
            secondaryHalted,
            "secondary pc=\(String(secondaryState?.cpu.pc ?? 0, radix: 16)) " +
                "lifecycle=\(String(describing: secondaryState?.lifecycle)) " +
                "lock=\(String(lockValue, radix: 16))"
        )
        let exclusive = machine.vm.memory.nativeExclusiveStatistics
        XCTAssertEqual(
            try machine.vm.memory.read64(at: counterAddress),
            iterations * 2,
            "exclusive reads=\(exclusive.reads) successes=\(exclusive.write_successes) conflicts=\(exclusive.write_conflicts)"
        )
        XCTAssertEqual(lockValue, 0)
    }

    func testCooperativeVCPUsKeepIndependentExclusiveMonitorGenerations() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2)
        machine.vm.virtualCPUQuantumSteps = 1
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let firstCounter = entry + 0x2_000
        let secondCounter = entry + 0x3_000
        let iterations: UInt32 = 64

        let program: [UInt32] = [
            0x5280_0801, // mov w1, #64
            0x885f_fc02, // ldaxr w2, [x0]
            0x1100_0442, // add w2, w2, #1
            0x8803_7c02, // stxr w3, w2, [x0]
            0x35ff_ffa3, // cbnz w3, .-12
            0x7100_0421, // subs w1, w1, #1
            0x54ff_ff61, // b.ne .-20
            0xd440_0000  // hlt
        ]
        try machine.vm.loadBinary(littleEndianWords(program), at: entry)

        // Give both locations non-zero monitor generations before execution.
        // Reusing one native context must not replace one vCPU's generation
        // with the other vCPU's reservation state at each one-step quantum.
        _ = try machine.vm.memory.exclusiveRead(at: firstCounter, width: .word)
        try machine.vm.memory.write32(0, at: firstCounter)
        _ = try machine.vm.memory.exclusiveRead(at: secondCounter, width: .word)
        try machine.vm.memory.write32(0, at: secondCounter)

        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = firstCounter
        XCTAssertTrue(machine.vm.startVirtualCPU(
            id: 1,
            entryPoint: entry,
            context: secondCounter
        ))

        let result = try machine.vm.run(maxSteps: 100_000)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read32(at: firstCounter), iterations)
        XCTAssertEqual(try machine.vm.memory.read32(at: secondCounter), iterations)
    }

    func testExt4BitmapAllocationLoopSurvivesNativeBlockChaining() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let bitmapPhysical = codePhysical + 0x20_000
        let codeVirtual: GuestAddress = 0x1_000
        let bitmapVirtual: GuestAddress = 0x2_000
        let table0 = ARM64VizMachineLayout.ramBase + 0x1_000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2_000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3_000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4_000
        let highCodeVirtual: GuestAddress = 0xffff_8000_0000_1000
        let highBitmapVirtual: GuestAddress = 0xffff_8000_0000_2000
        let program: [UInt32] = [
            0x531d_090a, // ubfiz w10, w8, #3, #3
            0x927d_f10b, // and x11, x8, #0xfffffffffffffff8
            0x1280_000c, // mov w12, #-1
            0x1400_000d, // b aligned-check
            0x0b0a_034d, // add w13, w26, w10
            0x9340_7dae, // sxtw x14, w13
            0x5280_002d, // mov w13, #1
            0xd343_fdcf, // lsr x15, x14, #3
            0x9ace_21ae, // lsl x14, x13, x14
            0x927d_e5ef, // and x15, x15, #0x1ffffffffffffff8
            0xf86f_6970, // ldr x16, [x11, x15]
            0xaa0e_020e, // orr x14, x16, x14
            0xf82f_696e, // str x14, [x11, x15]
            0x0b1a_01ba, // add w26, w13, w26
            0x6b09_035f, // cmp w26, w9
            0x5400_014a, // b.ge done
            0x1200_134d, // and w13, w26, #0x1f
            0x35ff_fe6d, // cbnz w13, bit-path
            0x4b1a_012d, // sub w13, w9, w26
            0x7100_81bf, // cmp w13, #0x20
            0x54ff_fe0b, // b.lt bit-path
            0x1303_7f4d, // asr w13, w26, #3
            0xb82d_c90c, // str w12, [x8, w13, sxtw]
            0x5280_040d, // mov w13, #0x20
            0x17ff_fff5, // b increment
            0xd440_0000  // hlt
        ]
        try machine.vm.loadBinary(littleEndianWords(program), at: codePhysical)
        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table1 | 0x3, at: table0 + 256 * 8)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(bitmapPhysical | 0x403, at: table3 + 16)

        let translations: [(
            code: GuestAddress,
            bitmap: GuestAddress,
            ttbr0: UInt64,
            ttbr1: UInt64
        )] = [
            (codeVirtual, bitmapVirtual, table0, 0),
            (highCodeVirtual, highBitmapVirtual, 0, table0)
        ]
        for translation in translations {
            for bitCount in [UInt64(745), 896] {
                try machine.vm.memory.writeBytes(
                    Array(repeating: 0, count: 128),
                    at: bitmapPhysical
                )
                machine.vm.reset(entryPoint: translation.code)
                machine.vm.cpu.x[8] = translation.bitmap
                machine.vm.cpu.x[9] = bitCount
                machine.vm.cpu.x[26] = 0
                machine.vm.writeSystemRegister(
                    ARM64SystemRegister.ttbr0EL1,
                    value: translation.ttbr0
                )
                machine.vm.writeSystemRegister(
                    ARM64SystemRegister.ttbr1EL1,
                    value: translation.ttbr1
                )
                machine.vm.writeSystemRegister(
                    ARM64SystemRegister.tcrEL1,
                    value: 16 | (16 << 16)
                )
                machine.vm.writeSystemRegister(
                    ARM64SystemRegister.sctlrEL1,
                    value: 1
                )
                machine.vm.timerCyclesPerInstruction = 0
                machine.vm.disableInstructionTrace()
                machine.vm.enableMMIOTrace(capacity: 0)

                let result = try machine.vm.run(maxSteps: 100_000)
                XCTAssertEqual(result.stopReason, .halted)
                for bit in UInt64(0)..<bitCount {
                    let word = try machine.vm.memory.read64(
                        at: bitmapPhysical + (bit / 64) * 8
                    )
                    XCTAssertNotEqual(
                        word & (UInt64(1) << (bit & 63)),
                        0,
                        "bit \(bit) of \(bitCount)"
                    )
                }
                let nextWord = try machine.vm.memory.read64(
                    at: bitmapPhysical + (bitCount / 64) * 8
                )
                XCTAssertEqual(
                    nextWord & (UInt64(1) << (bitCount & 63)),
                    0
                )
            }
        }
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testParallelSecondaryVCPUExecutesExt4BitmapAllocationLoop() throws {
        let machine = try MachineFactory.makeResearchMachine(
            virtualCPUCount: 2,
            parallelVCPUExecution: true
        )
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let primaryEntry = ARM64VizMachineLayout.toyEntryPoint
        let secondaryEntry = primaryEntry + 0x1_000
        let bitmap = primaryEntry + 0x20_000
        let bitCount: UInt64 = 896

        try machine.vm.loadBinary(littleEndianWords([
            0x9100_0400, // add x0, x0, #1
            0x17ff_ffff  // b .-4
        ]), at: primaryEntry)
        let secondaryProgram: [UInt32] = [
            0xaa00_03e8, // mov x8, x0
            0x5280_7009, // mov w9, #896
            0x5280_001a, // mov w26, #0
            0x531d_090a, 0x927d_f10b, 0x1280_000c, 0x1400_000d,
            0x0b0a_034d, 0x9340_7dae, 0x5280_002d, 0xd343_fdcf,
            0x9ace_21ae, 0x927d_e5ef, 0xf86f_6970, 0xaa0e_020e,
            0xf82f_696e, 0x0b1a_01ba, 0x6b09_035f, 0x5400_014a,
            0x1200_134d, 0x35ff_fe6d, 0x4b1a_012d, 0x7100_81bf,
            0x54ff_fe0b, 0x1303_7f4d, 0xb82d_c90c, 0x5280_040d,
            0x17ff_fff5, 0xd440_0000
        ]
        try machine.vm.loadBinary(
            littleEndianWords(secondaryProgram),
            at: secondaryEntry
        )
        try machine.vm.memory.writeBytes(
            Array(repeating: 0, count: 128),
            at: bitmap
        )
        machine.vm.memory.beginConcurrentExecution()
        machine.vm.reset(entryPoint: primaryEntry)

        XCTAssertTrue(machine.vm.startVirtualCPU(
            id: 1,
            entryPoint: secondaryEntry,
            context: bitmap
        ))
        _ = try machine.vm.run(maxSteps: 2_000_000)
        XCTAssertTrue(waitUntil(timeout: 5) {
            machine.vm.virtualCPUState(id: 1)?.lifecycle == .halted
        })
        for bit in UInt64(0)..<bitCount {
            let word = try machine.vm.memory.read64(
                at: bitmap + (bit / 64) * 8
            )
            XCTAssertNotEqual(
                word & (UInt64(1) << (bit & 63)),
                0,
                "secondary vCPU missed bit \(bit)"
            )
        }
        XCTAssertEqual(
            (machine.vm.backend as? SoftwareARM64Backend)?
                .swiftFallbackSingleInstructionSteps,
            0
        )
    }

    func testBroadcastTLBIInvalidatesNativeTranslationCacheOnPeerVCPU() throws {
        let primaryBackend = SoftwareARM64Backend()
        primaryBackend.fallbackInterpreterPolicy = .nativeOnly
        primaryBackend.setNativeDetailedMemoryStatisticsEnabled(true)
        let secondaryBackend = SoftwareARM64Backend()
        secondaryBackend.fallbackInterpreterPolicy = .nativeOnly
        secondaryBackend.setNativeDetailedMemoryStatisticsEnabled(true)
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

    func testDataCacheMaintenanceDoesNotInvalidateTranslationCaches() throws {
        let backend = TranslationInvalidationCountingBackend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let invalidationsBeforeMaintenance = backend.translationInvalidationCount

        machine.vm.executeSystemMaintenanceInstruction(0xd508_7620) // dc ivac, x0

        XCTAssertEqual(
            backend.translationInvalidationCount,
            invalidationsBeforeMaintenance
        )
    }

    func testTLBMaintenanceStillInvalidatesTranslationCaches() throws {
        let backend = TranslationInvalidationCountingBackend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let invalidationsBeforeMaintenance = backend.translationInvalidationCount

        machine.vm.executeSystemMaintenanceInstruction(0xd508_831f) // tlbi vmalle1is

        XCTAssertEqual(
            backend.translationInvalidationCount,
            invalidationsBeforeMaintenance + 1
        )
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
