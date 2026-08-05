import Darwin
import Foundation
import XCTest
@testable import ARM64VizCore

final class ARM64VizCoreTests: XCTestCase {
    func testInstructionCoverageScannerReadsOnlyARM64ExecutableSections() throws {
        var bytes = [UInt8](repeating: 0, count: 208)
        func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            let littleEndian = value.littleEndian
            withUnsafeBytes(of: littleEndian) { source in
                bytes.replaceSubrange(offset..<(offset + source.count), with: source)
            }
        }

        bytes[0...6] = [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]
        write(UInt16(2), at: 16)
        write(UInt16(183), at: 18)
        write(UInt32(1), at: 20)
        write(UInt64(80), at: 40)
        write(UInt16(64), at: 52)
        write(UInt16(64), at: 58)
        write(UInt16(2), at: 60)

        let section = 144
        write(UInt32(1), at: section + 4)
        write(UInt64(0x4), at: section + 8)
        write(UInt64(0x1000), at: section + 16)
        write(UInt64(64), at: section + 24)
        write(UInt64(16), at: section + 32)
        write(UInt64(4), at: section + 48)
        write(UInt32(0xd503_201f), at: 64)
        write(UInt32(0x4ee1_bbde), at: 68)
        write(UInt32(0xffff_ffff), at: 72)
        write(UInt32(0xffff_ffff), at: 76)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arm64viz-coverage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.elf")
        try Data(bytes).write(to: file)

        let report = try ARM64InstructionCoverageScanner(sampleLimit: 1).scan([
            ARM64InstructionScanInput(url: file, label: "fixture")
        ])

        XCTAssertEqual(report.scannedFiles, 1)
        XCTAssertEqual(report.arm64ELFFiles, 1)
        XCTAssertEqual(report.executableSections, 1)
        XCTAssertEqual(report.instructionWords, 4)
        XCTAssertEqual(report.decodedInstructionWords, 2)
        XCTAssertEqual(report.unsupportedInstructionWords, 2)
        XCTAssertEqual(report.decodedKinds.reduce(0) { $0 + $1.occurrences }, 2)
        XCTAssertEqual(report.unsupportedOpcodes, [
            ARM64UnsupportedInstructionSummary(
                opcode: "0xffffffff",
                occurrences: 2,
                fileCount: 1,
                samples: ["fixture:<exec-1>+0x1008"]
            )
        ])
    }

    func testHostExecutionPacerAppliesBoundedDutyCycleOutsideInteractionGrace() {
        let pacer = HostExecutionPacer(
            runShareNumerator: 4,
            cycleShareDenominator: 5,
            interactionGraceNanoseconds: 250,
            maximumDelayNanoseconds: 2_000
        )

        XCTAssertEqual(
            pacer.delayNanoseconds(
                afterRunDuration: 4_000,
                nowNanoseconds: 1_000,
                latestInteractionNanoseconds: nil
            ),
            1_000
        )
        XCTAssertEqual(
            pacer.delayNanoseconds(
                afterRunDuration: 40_000,
                nowNanoseconds: 1_000,
                latestInteractionNanoseconds: nil
            ),
            2_000
        )
        XCTAssertEqual(
            pacer.delayNanoseconds(
                afterRunDuration: 4_000,
                nowNanoseconds: 1_249,
                latestInteractionNanoseconds: 1_000
            ),
            0
        )
        XCTAssertEqual(
            pacer.delayNanoseconds(
                afterRunDuration: 4_000,
                nowNanoseconds: 1_250,
                latestInteractionNanoseconds: 1_000
            ),
            1_000
        )
        XCTAssertEqual(
            HostExecutionPacer(
                runShareNumerator: UInt64.max - 1,
                cycleShareDenominator: UInt64.max,
                maximumDelayNanoseconds: 7
            ).delayNanoseconds(
                afterRunDuration: UInt64.max,
                nowNanoseconds: 1,
                latestInteractionNanoseconds: nil
            ),
            1
        )
    }

    func testPhysicalMemoryIsLittleEndian() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 4096)

        try memory.write64(0x1122_3344_5566_7788, at: 0x4000_0010)

        XCTAssertEqual(try memory.read8(at: 0x4000_0010), 0x88)
        XCTAssertEqual(try memory.read16(at: 0x4000_0010), 0x7788)
        XCTAssertEqual(try memory.read32(at: 0x4000_0010), 0x5566_7788)
        XCTAssertEqual(try memory.read64(at: 0x4000_0010), 0x1122_3344_5566_7788)

        try memory.writeBytes([0xaa, 0xbb, 0xcc, 0xdd], at: 0x4000_0020)
        XCTAssertEqual(try memory.readBytes(at: 0x4000_0020, count: 4), [0xaa, 0xbb, 0xcc, 0xdd])
        XCTAssertEqual(try memory.read32(at: 0x4000_0020), 0xddcc_bbaa)
    }

    func testPhysicalMemorySnapshotAndRestoreUseIndependentStorage() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 16 * 1024)

        XCTAssertEqual(try memory.read64(at: 0x4000_2000), 0)
        try memory.write64(0x0123_4567_89ab_cdef, at: 0x4000_2000)
        let snapshot = memory.snapshotBytes()

        try memory.write64(0xfedc_ba98_7654_3210, at: 0x4000_2000)
        XCTAssertEqual(
            Array(snapshot[0x2000..<0x2008]),
            [0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01]
        )

        try memory.restoreBytes(snapshot)
        XCTAssertEqual(try memory.read64(at: 0x4000_2000), 0x0123_4567_89ab_cdef)
    }

    func testPhysicalMemoryDirtyEpochsTrackPagesForIndependentObservers() throws {
        let pageSize = 4_096
        let memory = PhysicalMemory(base: 0x4000_0000, size: pageSize * 3)
        let baseline = memory.advanceDirtyEpoch()

        try memory.write8(0x11, at: memory.base + 128)
        try memory.write32(0x2233_4455, at: memory.base + UInt64(pageSize * 2 + 64))
        let through = memory.advanceDirtyEpoch()
        let observationAddress = memory.base + 100
        let observationCount = memory.size - 200
        let expected: [(address: GuestAddress, count: Int)] = [
            (memory.base + 100, pageSize - 100),
            (memory.base + UInt64(pageSize * 2), pageSize - 100)
        ]

        let firstObserver = memory.dirtyRanges(
            at: observationAddress,
            count: observationCount,
            afterEpoch: baseline,
            throughEpoch: through
        )
        let secondObserver = memory.dirtyRanges(
            at: observationAddress,
            count: observationCount,
            afterEpoch: baseline,
            throughEpoch: through
        )

        XCTAssertEqual(firstObserver.map(\.address), expected.map(\.address))
        XCTAssertEqual(firstObserver.map(\.count), expected.map(\.count))
        XCTAssertEqual(secondObserver.map(\.address), expected.map(\.address))
        XCTAssertEqual(secondObserver.map(\.count), expected.map(\.count))

        let cleanEpoch = memory.advanceDirtyEpoch()
        XCTAssertTrue(memory.dirtyRanges(
            at: memory.base,
            count: memory.size,
            afterEpoch: through,
            throughEpoch: cleanEpoch
        ).isEmpty)
    }

    func testNativeCPUStoreMarksGuestMemoryDirtyPage() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let destination = entry + 0x1000
        try machine.vm.loadBinary(littleEndianWords([
            0xf900_0020, // str x0, [x1]
            0xd440_0000
        ]), at: entry)
        let baseline = machine.vm.memory.advanceDirtyEpoch()
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[1] = destination

        let result = try machine.vm.run(maxSteps: 4)
        let through = machine.vm.memory.advanceDirtyEpoch()
        let dirty = machine.vm.memory.dirtyRanges(
            at: destination,
            count: 8,
            afterEpoch: baseline,
            throughEpoch: through
        )

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: destination), 0x1122_3344_5566_7788)
        XCTAssertEqual(dirty.map(\.address), [destination])
        XCTAssertEqual(dirty.map(\.count), [8])
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testMMIOBusRejectsOverlappingDevices() throws {
        let bus = MMIOBus()
        let first = VirtualUART(name: "uart-a", base: 0x1000)
        let second = VirtualUART(name: "uart-b", base: 0x1800)

        try bus.register(first)
        XCTAssertThrowsError(try bus.register(second))
    }

    func testToyGuestWritesToUART() throws {
        let machine = try MachineFactory.makeResearchMachine()
        _ = try ToyUARTGuestAdapter(message: "ok\n").load(into: machine.vm)

        let result = try machine.vm.run(maxSteps: 100)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.uart.outputString, "ok\n")
    }

    func testSoftwareBackendCachesDecodedInstructions() throws {
        let backend = SoftwareARM64Backend()
        backend.collectCacheStatistics = true
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9100_0400,
            0x9100_0400,
            0x9100_0400,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 3)
        XCTAssertGreaterThanOrEqual(backend.decodedInstructionCacheMisses, 2)
        XCTAssertGreaterThanOrEqual(backend.decodedInstructionCacheHits, 2)
    }

    func testSoftwareBackendExecutesDecodedBasicBlocksWhenTracingIsDisabled() throws {
        let backend = SoftwareARM64Backend()
        backend.collectCacheStatistics = true
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9100_0400,
            0x9100_0400,
            0x9100_0400,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 3)
        XCTAssertGreaterThanOrEqual(backend.decodedBasicBlockCacheMisses, 1)
        XCTAssertGreaterThanOrEqual(
            backend.decodedBasicBlockExecutions + backend.nativeBasicBlockExecutions,
            1
        )
    }

    func testDiagnosticsPolicyExecutesSystemRegisterReadNativelyWhenTracingIsDisabled() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.midrEL1),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(
            machine.vm.cpu.x[0],
            machine.vm.systemRegisters.read(ARM64SystemRegister.midrEL1, cpu: machine.vm.cpu)
        )
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps + backend.nativeSingleInstructionSteps, 1)
    }

    func testNativeOnlyPolicyExecutesSystemRegisterReadWhenTracingIsDisabled() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let instruction = encodeMRS(rt: 0, key: ARM64SystemRegister.midrEL1)
        let program = littleEndianWords([
            instruction,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x410f_d034)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps + backend.nativeSingleInstructionSteps, 1)
        XCTAssertNil(backend.unsupportedInstructionCounts[instruction])
    }

    func testSoftwareBackendInvalidatesDecodedBasicBlocksOnCodeWrites() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9100_0400,
            0x9100_0400,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        _ = try machine.vm.run(maxSteps: 4)
        XCTAssertEqual(machine.vm.cpu.x[0], 2)
        XCTAssertGreaterThanOrEqual(
            backend.decodedBasicBlockExecutions + backend.nativeBasicBlockExecutions,
            1
        )

        try machine.vm.writePhysical(entry + 4, width: .word, value: 0x9100_0800)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 3)
    }

    func testSoftwareBackendExecutesBranchTerminatorBasicBlocks() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9100_0400,
            0x1400_0002,
            0x9100_0400,
            0x9100_0400,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 2)
        XCTAssertGreaterThanOrEqual(
            backend.decodedBasicBlockTerminatorExecutions + backend.nativeBasicBlockExecutions,
            1
        )
    }

    func testSoftwareBackendRetainsSinglePageBasicBlocksAcrossRuns() throws {
        let backend = SoftwareARM64Backend()
        backend.collectCacheStatistics = true
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        var words: [UInt32] = []
        for _ in 0..<16 {
            words.append(0x9100_0400) // add x0, x0, #1
            words.append(0x1400_0001) // b .+4
        }
        words.append(0xd440_0000) // hlt #0
        let program = littleEndianWords(words)

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let firstResult = try machine.vm.run(maxSteps: 128)
        XCTAssertEqual(firstResult.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 16)

        let missCountAfterFirstRun = backend.decodedBasicBlockCacheMisses

        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let secondResult = try machine.vm.run(maxSteps: 128)

        XCTAssertEqual(secondResult.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 16)
        XCTAssertEqual(
            backend.decodedBasicBlockCacheMisses,
            missCountAfterFirstRun,
            "re-running the same single-page block sequence should hit the decoded block cache"
        )
    }

    func testSoftwareBackendUsesFastRAMForUnsignedImmediateLoadStores() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataAddress = entry + 0x100
        let program = littleEndianWords([
            0xf900_0020,
            0xf940_0022,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0xfeed_face_cafe_beef
        machine.vm.cpu.x[1] = dataAddress
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0xfeed_face_cafe_beef)
        XCTAssertGreaterThanOrEqual(backend.fastRAMWriteHits, 1)
        XCTAssertGreaterThanOrEqual(backend.fastRAMReadHits, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMWriteHits, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMReadHits, 1)
    }

    func testSoftwareBackendServicesNativeMMIOWithoutUnsupportedExit() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xb900_0020,
            0xb940_0043,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0x41
        machine.vm.cpu.x[1] = ARM64VizMachineLayout.uartBase
        machine.vm.cpu.x[2] = ARM64VizMachineLayout.uartBase + 0x18
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.uart.outputString, "A")
        XCTAssertEqual(machine.vm.cpu.x[3], 0x90)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty, "\(backend.unsupportedInstructionCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMReadMisses, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMWriteMisses, 1)
    }

    func testSoftwareBackendKeepsVirtIOMMIOInsideNativeChain() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let codeVirtual: GuestAddress = 0x1000
        let deviceVirtual: GuestAddress = 0x2000
        let program = littleEndianWords([
            0xb940_0043,
            0xb900_0020,
            0xd440_0000
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(entry | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(
            ARM64VizMachineLayout.virtioBlockBase | 0x403,
            at: table3 + 16
        )
        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.cpu.x[0] = 1
        machine.vm.cpu.x[1] = deviceVirtual + 0x24
        machine.vm.cpu.x[2] = deviceVirtual
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x7472_6976)
        XCTAssertEqual(backend.nativePinnedDeviceSingleInstructionSteps, 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertGreaterThanOrEqual(backend.nativePhysicalDeviceReads, 1)
        XCTAssertGreaterThanOrEqual(backend.nativePhysicalDeviceWrites, 1)
    }

    func testUARTMarkerStopCanUseNativeExecution() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x5280_09e0, // mov w0, #'O'
            0xb900_0020, // str w0, [x1]
            0x5280_0960, // mov w0, #'K'
            0xb900_0020, // str w0, [x1]
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[1] = ARM64VizMachineLayout.uartBase
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0
        machine.vm.stopOnUARTOutputContaining = "OK"

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .uartOutputContains("OK"))
        XCTAssertEqual(machine.uart.outputString, "OK")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty, "\(backend.unsupportedInstructionCounts)")
    }

    func testSoftwareBackendUsesNativeCoreForPostConsoleIntegerHotspots() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x93d7_fef7,
            0xaac1_23e0,
            0x9bc1_7c42,
            0x9b45_7c83,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[1] = 2
        machine.vm.cpu.x[2] = UInt64.max
        machine.vm.cpu.x[4] = UInt64(bitPattern: Int64(-2))
        machine.vm.cpu.x[5] = 3
        machine.vm.cpu.x[23] = 0x8000_0000_0000_0001
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[23], 0x3)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x0200_0000_0000_0000)
        XCTAssertEqual(machine.vm.cpu.x[2], 1)
        XCTAssertEqual(machine.vm.cpu.x[3], UInt64.max)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty, "\(backend.unsupportedInstructionCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 4)
    }

    func testSoftwareBackendCollapsesNativeStorePairFillLoop() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let target = entry + 0x1000
        let program = littleEndianWords([
            0xa901_1d07,
            0xa902_1d07,
            0xa903_1d07,
            0xa984_1d07,
            0xf101_0042,
            0x54ff_ff6a,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[2] = 0x40
        machine.vm.cpu.x[7] = 0xabab_abab_abab_abab
        machine.vm.cpu.x[8] = target - 16
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 20)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], UInt64.max - 0x3f)
        XCTAssertEqual(machine.vm.cpu.x[8], target + 112)
        for offset in 0..<128 {
            XCTAssertEqual(try machine.vm.memory.read8(at: target + UInt64(offset)), 0xab)
        }
        XCTAssertEqual(try machine.vm.memory.read8(at: target - 1), 0)
        XCTAssertEqual(try machine.vm.memory.read8(at: target + 128), 0)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 12)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMWriteHits, 16)
    }

    func testSoftwareBackendUsesNativeCoreForSignedAndRegisterOffsetLoadStores() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataAddress = entry + 0x100
        let program = littleEndianWords([
            0x3840_1408,
            0xf862_78c7,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write8(0x2f, at: dataAddress)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataAddress + 24)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = dataAddress
        machine.vm.cpu.x[2] = 3
        machine.vm.cpu.x[6] = dataAddress
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], dataAddress + 1)
        XCTAssertEqual(machine.vm.cpu.x[8], 0x2f)
        XCTAssertEqual(machine.vm.cpu.x[7], 0x1122_3344_5566_7788)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMReadHits, 2)
    }

    func testSoftwareBackendUsesNativeCoreForPairLoadStores() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataAddress = entry + 0x200
        let program = littleEndianWords([
            encodePairTransfer(base: 0xa900_0000, rt: 0, rt2: 1, rn: 5, offsetBytes: -16),
            encodePairTransfer(base: 0xa940_0000, rt: 2, rt2: 3, rn: 5, offsetBytes: -16),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[1] = 0x8877_6655_4433_2211
        machine.vm.cpu.x[5] = dataAddress + 16
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x8877_6655_4433_2211)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataAddress), 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataAddress + 8), 0x8877_6655_4433_2211)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMWriteHits, 2)
        XCTAssertGreaterThanOrEqual(backend.nativeFastRAMReadHits, 2)
    }

    func testSoftwareBackendUsesNativeCoreForLogicalShiftedRegister() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xaa00_03e2,
            0x8a01_0043,
            0xea03_005f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[1] = 0x00ff_00ff_00ff_00ff
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x0022_0044_0066_0088)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 3)
    }

    func testSoftwareBackendUsesNativeCoreForLogicalImmediate() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf27e_027f,
            0xf27e_027f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[19] = 0x4
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[19], 0x4)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertTrue(backend.unsupportedInstructionCounts.isEmpty, "\(backend.unsupportedInstructionCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
    }

    func testSoftwareBackendUsesNativeCoreForRegisterBranch() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd61f_0000,
            0xd280_0021,
            0xd280_0041,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = entry + 8
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], 2)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 1)
    }

    func testSoftwareBackendUsesNativeCoreForConditionalSelect() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9a81_1002,
            0x9a81_0403,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 7
        machine.vm.cpu.x[1] = 41
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 7)
        XCTAssertEqual(machine.vm.cpu.x[3], 42)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
    }

    func testSoftwareBackendUsesNativeCoreForBitfieldMove() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd350_4c63,
            0xb360_08b0,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[3] = 0x8444_c004
        machine.vm.cpu.x[5] = 0x5
        machine.vm.cpu.x[16] = 0xaaaa
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x4)
        XCTAssertEqual(machine.vm.cpu.x[16], 0x5_0000_aaaa)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
    }

    func testSoftwareBackendUsesNativeCoreForDataProcessingOneSource() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xdac0_0002,
            0xdac0_1023,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 0x8000_0000_0000_0001
        machine.vm.cpu.x[1] = 0x00ff
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0x8000_0000_0000_0001)
        XCTAssertEqual(machine.vm.cpu.x[3], 56)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
    }

    func testSoftwareBackendUsesNativeCoreForDataProcessingTwoSource() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9ac1_2002,
            0x9ac5_0883,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 3
        machine.vm.cpu.x[1] = 4
        machine.vm.cpu.x[4] = 100
        machine.vm.cpu.x[5] = 9
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 48)
        XCTAssertEqual(machine.vm.cpu.x[3], 11)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
    }

    func testNativeCorePreservesLinuxPrimaryPlaneMaskSequence() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let plane = entry + 0x200
        let program = littleEndianWords([
            0xb400_00d6, // cbz x22, done
            0xb940_7ac9, // ldr w9, [x22, #0x78]
            0x3500_0089, // cbnz w9, done
            0x5280_0029, // mov w9, #1
            0x1ac8_2128, // lsl w8, w9, w8
            0xb900_7ac8, // str w8, [x22, #0x78]
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0, at: plane + 0x78)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[8] = 0
        machine.vm.cpu.x[22] = plane
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read32(at: plane + 0x78), 1)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 6)
    }

    func testNativeCoreExecutesKernelUnalignedPlaneMaskStore() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let structureAddress = entry + 0x204
        let program = littleEndianWords([
            0xf800_c269, // stur x9, [x19, #12]
            0xd440_0000  // hlt #0
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(UInt64.max, at: structureAddress + 12)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[9] = 1
        machine.vm.cpu.x[19] = structureAddress
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: structureAddress + 12), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: structureAddress + 12), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: structureAddress + 16), 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
    }

    func testNativeCorePreservesUpperWordThroughMMUCopyToUserSequence() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let sourceVirtual: GuestAddress = 0x2000
        let destinationVirtual: GuestAddress = 0x3000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let sourcePhysical = codePhysical + 0x1000
        let destinationPhysical = codePhysical + 0x2000
        let program = littleEndianWords([
            0xa8c1_2027, // ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0xd440_0000  // hlt #0
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(sourcePhysical | 0x403, at: table3 + 16)
        try machine.vm.memory.write64(destinationPhysical | 0x403, at: table3 + 24)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.memory.write64(0x0000_0001_0000_0026, at: sourcePhysical)
        try machine.vm.memory.write64(0x0000_0001_0000_0000, at: sourcePhysical + 8)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.x[1] = sourceVirtual
        machine.vm.cpu.x[6] = destinationVirtual
        machine.vm.timerCyclesPerInstruction = 0
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[7], 0x0000_0001_0000_0026)
        XCTAssertEqual(try machine.vm.memory.read64(at: destinationPhysical), 0x0000_0001_0000_0026)
        XCTAssertEqual(try machine.vm.memory.read64(at: destinationPhysical + 8), 0x0000_0001_0000_0000)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }

    func testNativeCoreCopiesFromTTBR1KernelPageToTTBR0UserPage() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let userTable0 = ARM64VizMachineLayout.ramBase + 0x1000
        let userTable1 = ARM64VizMachineLayout.ramBase + 0x2000
        let userTable2 = ARM64VizMachineLayout.ramBase + 0x3000
        let userTable3 = ARM64VizMachineLayout.ramBase + 0x4000
        let kernelTable0 = ARM64VizMachineLayout.ramBase + 0x5000
        let kernelTable1 = ARM64VizMachineLayout.ramBase + 0x6000
        let kernelTable2 = ARM64VizMachineLayout.ramBase + 0x7000
        let kernelTable3 = ARM64VizMachineLayout.ramBase + 0x8000
        let codeVirtual: GuestAddress = 0xffff_0000_0000_1000
        let sourceVirtual: GuestAddress = 0xffff_0000_0000_2000
        let destinationVirtual: GuestAddress = 0x3000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let sourcePhysical = codePhysical + 0x1000
        let destinationPhysical = codePhysical + 0x2000
        let program = littleEndianWords([
            0xa8c1_2027, // ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0xd440_0000  // hlt #0
        ])

        try machine.vm.memory.write64(userTable1 | 0x3, at: userTable0)
        try machine.vm.memory.write64(userTable2 | 0x3, at: userTable1)
        try machine.vm.memory.write64(userTable3 | 0x3, at: userTable2)
        try machine.vm.memory.write64(destinationPhysical | 0x403, at: userTable3 + 24)
        try machine.vm.memory.write64(kernelTable1 | 0x3, at: kernelTable0)
        try machine.vm.memory.write64(kernelTable2 | 0x3, at: kernelTable1)
        try machine.vm.memory.write64(kernelTable3 | 0x3, at: kernelTable2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: kernelTable3 + 8)
        try machine.vm.memory.write64(sourcePhysical | 0x403, at: kernelTable3 + 16)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.memory.write64(0x0000_0023_0000_0021, at: sourcePhysical)
        try machine.vm.memory.write64(0x0000_0001_0000_0026, at: sourcePhysical + 8)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.x[1] = sourceVirtual
        machine.vm.cpu.x[6] = destinationVirtual
        machine.vm.timerCyclesPerInstruction = 0
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: userTable0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.ttbr1EL1, value: kernelTable0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16 | UInt64(16 << 16), into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: destinationPhysical), 0x0000_0023_0000_0021)
        XCTAssertEqual(try machine.vm.memory.read64(at: destinationPhysical + 8), 0x0000_0001_0000_0026)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }

    func testNativeCoreAssignsWLRootsPrimaryPlaneFromPossibleCRTCMask() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let crtc = entry + 0x200
        let plane: UInt64 = 0x1122_3344_5566_7788
        let program = littleEndianWords([
            0xeb01_005f, // cmp x2, x1
            0x5400_00e0, // b.eq done
            0x5280_0020, // mov w0, #1
            0x1ac1_2000, // lsl w0, w0, w1
            0x6a04_001f, // tst w0, w4
            0x5400_0060, // b.eq done
            0xaa03_03e0, // mov x0, x3
            0xf900_2016, // str x22, [x0, #0x40]
            0xd440_0000  // done: hlt #0
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = crtc
        machine.vm.cpu.x[1] = 0
        machine.vm.cpu.x[2] = 1
        machine.vm.cpu.x[3] = crtc
        machine.vm.cpu.x[4] = 1
        machine.vm.cpu.x[22] = plane
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: crtc + 0x40), plane)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
    }

    func testNativeCoreExecutesCageDoubleMultiplyWithoutFallback() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        try machine.vm.loadBinary(littleEndianWords([
            0x1e78_083c, // fmul d28, d1, d24
            0xd440_0000  // hlt #0
        ]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.v[1].low = (3.0 as Double).bitPattern
        machine.vm.cpu.v[24].low = (4.0 as Double).bitPattern
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(Double(bitPattern: machine.vm.cpu.v[28].low), 12.0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }

    func testSoftwareBackendUsesNativeCoreForLiteralLoadAndConditionalCompare() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeLoadLiteral(rt: 8, offset: 20, opcode: 1),
            0xfa40_5a4d,
            0x7a40_3042,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: entry + 20)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[2] = 0
        machine.vm.cpu.x[18] = 0
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[8], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x2000_0000)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 3)
    }

    func testSoftwareBackendUsesNativeCoreForExtendedAddAndMultiplyFamilies() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x8b35_c275,
            0x1b02_7ca2,
            0x9bb8_7eb6,
            encodeAddSubtractWithCarry(rd: 9, rn: 10, rm: 11, bits: 64, subtract: true, setFlags: false),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[2] = 7
        machine.vm.cpu.x[5] = 3
        machine.vm.cpu.x[19] = 0x1000
        machine.vm.cpu.x[21] = 0xffff_fffc
        machine.vm.cpu.x[22] = 0xffff_ffff
        machine.vm.cpu.x[24] = 3
        machine.vm.cpu.x[10] = 10
        machine.vm.cpu.x[11] = 3
        machine.vm.cpu.pstate |= 0x2000_0000
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[21], 0xffc)
        XCTAssertEqual(machine.vm.cpu.x[2], 21)
        XCTAssertEqual(machine.vm.cpu.x[22], 0x2ff4)
        XCTAssertEqual(machine.vm.cpu.x[9], 7)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 4)
    }

    func testSoftwareBackendUsesNativeCoreForSignedUnsignedImmediateAndAcquireRelease() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xb980_0083,
            0xc8df_fc15,
            0xc89f_fc41,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0xffff_ff80, at: dataBase)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = dataBase + 8
        machine.vm.cpu.x[1] = 0xaaaa_bbbb_cccc_dddd
        machine.vm.cpu.x[2] = dataBase + 16
        machine.vm.cpu.x[4] = dataBase
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 0xffff_ffff_ffff_ff80)
        XCTAssertEqual(machine.vm.cpu.x[21], 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 16), 0xaaaa_bbbb_cccc_dddd)
        XCTAssertTrue(backend.nativeIneligibleGadgetCounts.isEmpty, "\(backend.nativeIneligibleGadgetCounts)")
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 3)
    }

    func testSoftwareBackendUsesNativeCoreForPureRegisterBlocks() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd280_0020,
            0x9100_0400,
            0x9100_0400,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 3)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockExecutions, 1)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 3)
        XCTAssertGreaterThanOrEqual(backend.performanceSnapshot().nativeBasicBlockSteps, 3)
    }

    func testStopOnUARTOutputRecordsMMIOTrace() throws {
        let machine = try MachineFactory.makeResearchMachine()
        _ = try ToyUARTGuestAdapter(message: "ok\n").load(into: machine.vm)
        machine.vm.stopOnUARTOutput = true
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.enableMMIOTrace(capacity: 4)

        let result = try machine.vm.run(maxSteps: 100)

        XCTAssertEqual(result.stopReason, .uartOutput(0x6f))
        XCTAssertEqual(machine.uart.outputString, "o")
        XCTAssertEqual(machine.vm.mmioTrace.count, 1)
        XCTAssertEqual(machine.vm.mmioTrace.first?.deviceName, "uart0")
        XCTAssertEqual(machine.vm.mmioTrace.first?.access, .write)
        XCTAssertEqual(machine.vm.mmioTrace.first?.address, ARM64VizMachineLayout.uartBase)
        XCTAssertEqual(machine.vm.mmioTrace.first?.offset, 0)
        XCTAssertEqual(machine.vm.mmioTrace.first?.width, MMIOWidth.byte.rawValue)
        XCTAssertEqual(machine.vm.mmioTrace.first?.value, 0x6f)
    }

    func testUARTTransmitInterruptUsesMaskAndClearRegisters() throws {
        let interrupts = SimpleInterruptController()
        let uart = VirtualUART(base: 0x1000, interruptLine: 33, interruptController: interrupts)
        interrupts.setEnabled(line: 33, enabled: true)

        try uart.write(offset: 0x00, width: .word, value: 0x41)

        XCTAssertEqual(uart.outputString, "A")
        XCTAssertEqual(try uart.read(offset: 0x3c, width: .word), UInt64(VirtualUART.transmitInterrupt))
        XCTAssertNil(interrupts.peekPending())

        try uart.write(offset: 0x38, width: .word, value: UInt64(VirtualUART.transmitInterrupt))

        XCTAssertEqual(try uart.read(offset: 0x40, width: .word), UInt64(VirtualUART.transmitInterrupt))
        XCTAssertEqual(interrupts.peekPending(), 33)

        try uart.write(offset: 0x44, width: .word, value: UInt64(VirtualUART.transmitInterrupt))

        XCTAssertEqual(try uart.read(offset: 0x40, width: .word), 0)
        XCTAssertNil(interrupts.peekPending())
    }

    func testInterruptControllerDoesNotRequeueActiveLine() {
        let interrupts = SimpleInterruptController()
        interrupts.setEnabled(line: 27, enabled: true)
        interrupts.raise(line: 27)

        XCTAssertEqual(interrupts.acknowledge(), 27)
        XCTAssertEqual(interrupts.activeLine(), 27)

        interrupts.raise(line: 27)

        XCTAssertNil(interrupts.peekPending())

        interrupts.complete(line: 27)
        interrupts.raise(line: 27)

        XCTAssertEqual(interrupts.peekPending(), 27)
    }

    func testInterruptControllerDiagnosticsTrackLifecycleCounts() {
        let interrupts = SimpleInterruptController()
        interrupts.setEnabled(line: 27, enabled: true)
        interrupts.raise(line: 27)

        XCTAssertEqual(interrupts.acknowledge(), 27)

        interrupts.raise(line: 27)
        interrupts.complete(line: 27)
        interrupts.raise(line: 27)
        interrupts.clear(line: 27)

        let diagnostics = interrupts.diagnostics()

        XCTAssertEqual(diagnostics.pendingLines, [])
        XCTAssertEqual(diagnostics.activeLines, [])
        XCTAssertEqual(diagnostics.enabledLines, [27])
        XCTAssertEqual(diagnostics.raisedCounts, [InterruptLineEventCount(line: 27, count: 3)])
        XCTAssertEqual(diagnostics.activeRaiseDropCounts, [InterruptLineEventCount(line: 27, count: 1)])
        XCTAssertEqual(diagnostics.acknowledgedCounts, [InterruptLineEventCount(line: 27, count: 1)])
        XCTAssertEqual(diagnostics.completedCounts, [InterruptLineEventCount(line: 27, count: 1)])
        XCTAssertEqual(diagnostics.clearedCounts, [InterruptLineEventCount(line: 27, count: 1)])
    }

    func testVMStopsWhenUARTOutputContainsMarker() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.vm.stopOnUARTOutputContaining = "rootfs ready"

        for byte in "rootfs".utf8 {
            try machine.vm.writePhysical(ARM64VizMachineLayout.uartBase, width: .word, value: UInt64(byte))
        }

        XCTAssertNil(machine.vm.requestedStopReason)

        for byte in " ready".utf8 {
            try machine.vm.writePhysical(ARM64VizMachineLayout.uartBase, width: .word, value: UInt64(byte))
        }

        XCTAssertEqual(machine.vm.requestedStopReason, .uartOutputContains("rootfs ready"))
    }

    func testUARTReceiveInterruptClearsWhenFIFOIsDrained() throws {
        let interrupts = SimpleInterruptController()
        let uart = VirtualUART(base: 0x1000, interruptLine: 34, interruptController: interrupts)
        interrupts.setEnabled(line: 34, enabled: true)

        try uart.write(offset: 0x38, width: .word, value: UInt64(VirtualUART.receiveInterrupt))
        uart.injectReceiveBytes([0x62])

        XCTAssertEqual(interrupts.peekPending(), 34)
        XCTAssertEqual(try uart.read(offset: 0x18, width: .word) & (1 << 4), 0)
        XCTAssertEqual(try uart.read(offset: 0x00, width: .word), 0x62)
        XCTAssertEqual(try uart.read(offset: 0x40, width: .word), 0)
        XCTAssertNil(interrupts.peekPending())
        XCTAssertNotEqual(try uart.read(offset: 0x18, width: .word) & (1 << 4), 0)
    }

    func testUARTReceiveInjectionHonorsFIFOBackpressure() throws {
        let uart = VirtualUART(base: 0x1000)
        let input = Array(0..<UInt8(32))

        uart.injectReceiveBytes(input)

        XCTAssertEqual(uart.receiveFIFOAvailableCapacity, 0)
        XCTAssertNotEqual(try uart.read(offset: 0x18, width: .word) & (1 << 6), 0)
        for expected in input.prefix(16) {
            XCTAssertEqual(try uart.read(offset: 0x00, width: .word), UInt64(expected))
        }
        XCTAssertEqual(uart.receiveFIFOAvailableCapacity, 16)
        XCTAssertNotEqual(try uart.read(offset: 0x18, width: .word) & (1 << 4), 0)
    }

    func testUARTExposesPL011ProbeAndConfigurationRegisters() throws {
        let uart = VirtualUART(base: 0x1000)

        XCTAssertEqual(try uart.read(offset: 0xfe0, width: .byte), 0x11)
        XCTAssertEqual(try uart.read(offset: 0xfe4, width: .byte), 0x10)
        XCTAssertEqual(try uart.read(offset: 0xfe8, width: .byte), 0x14)
        XCTAssertEqual(try uart.read(offset: 0xfec, width: .byte), 0x00)
        XCTAssertEqual(try uart.read(offset: 0xff0, width: .byte), 0x0d)
        XCTAssertEqual(try uart.read(offset: 0xff4, width: .byte), 0xf0)
        XCTAssertEqual(try uart.read(offset: 0xff8, width: .byte), 0x05)
        XCTAssertEqual(try uart.read(offset: 0xffc, width: .byte), 0xb1)
        XCTAssertEqual(try uart.read(offset: 0x30, width: .word), 0x0300)
        XCTAssertEqual(try uart.read(offset: 0x34, width: .word), 0x12)

        try uart.write(offset: 0x24, width: .word, value: 13)
        try uart.write(offset: 0x28, width: .word, value: 17)
        try uart.write(offset: 0x2c, width: .word, value: 0x70)
        try uart.write(offset: 0x30, width: .word, value: 0x0301)
        try uart.write(offset: 0x34, width: .word, value: 0x2a)
        try uart.write(offset: 0x48, width: .word, value: 0x7)

        XCTAssertEqual(try uart.read(offset: 0x24, width: .word), 13)
        XCTAssertEqual(try uart.read(offset: 0x28, width: .word), 17)
        XCTAssertEqual(try uart.read(offset: 0x2c, width: .word), 0x70)
        XCTAssertEqual(try uart.read(offset: 0x30, width: .word), 0x0301)
        XCTAssertEqual(try uart.read(offset: 0x34, width: .word), 0x2a)
        XCTAssertEqual(try uart.read(offset: 0x48, width: .word), 0x7)
    }

    func testMobileOSPrototypeGuestIsDisabled() throws {
        let machine = try MachineFactory.makeResearchMachine()

        XCTAssertThrowsError(try MobileOSToyGuestAdapter().load(into: machine.vm)) { error in
            guard case VMError.unsupportedGuest = error else {
                XCTFail("expected unsupportedGuest, got \(error)")
                return
            }
            XCTAssertTrue(String(describing: error).contains("JavaScript MobileOS is disabled"))
        }
    }

    func testMobileOSImageArtifactRoundTrips() throws {
        let image = MobileOSImage.developmentImage()
        let encoded = try image.encodedArtifact()
        let decoded = try MobileOSImage.decodeArtifact(encoded)

        XCTAssertEqual(decoded.manifest, image.manifest)
        XCTAssertFalse(decoded.manifest.verboseBoot)
        XCTAssertEqual(decoded.payload, image.payload)
        XCTAssertEqual(Array(encoded.prefix(MobileOSImage.magic.count)), MobileOSImage.magic)
    }

    func testMobileOSVerboseImageBootIsDisabled() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let image = MobileOSImage.developmentImage(verboseBoot: true)

        XCTAssertTrue(image.manifest.verboseBoot)
        XCTAssertThrowsError(try MobileOSImageBootAdapter(image: image).load(into: machine.vm)) { error in
            guard case VMError.unsupportedGuest = error else {
                XCTFail("expected unsupportedGuest, got \(error)")
                return
            }
        }
    }

    func testMobileOSImageBootAdapterIsDisabled() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let image = MobileOSImage.developmentImage(runtime: "javascript")

        XCTAssertThrowsError(try MobileOSImageBootAdapter(image: image).load(into: machine.vm)) { error in
            guard case VMError.unsupportedGuest = error else {
                XCTFail("expected unsupportedGuest, got \(error)")
                return
            }
            XCTAssertTrue(String(describing: error).contains(RuntimeDirection.javascriptMobileOSDisabledReason))
        }
    }

    func testMobileOSSchedulerRunsProcessesRoundRobin() {
        let scheduler = MobileOSScheduler()
        let first = scheduler.spawn(name: "first", kind: .app)
        let second = scheduler.spawn(name: "second", kind: .app)

        XCTAssertEqual(scheduler.tick()?.pid, first)
        XCTAssertEqual(scheduler.tick()?.pid, second)
        XCTAssertEqual(scheduler.tick()?.pid, first)
    }

    func testMobileOSIPCWakesWaitingProcess() throws {
        let scheduler = MobileOSScheduler()
        let sender = scheduler.spawn(name: "sender", kind: .systemService)
        let receiver = scheduler.spawn(name: "receiver", kind: .app)

        XCTAssertNil(try scheduler.receive(pid: receiver))
        try scheduler.send(MobileOSMessage(from: sender, to: receiver, topic: "ping", payload: "hello"))
        let message = try scheduler.receive(pid: receiver)

        XCTAssertEqual(message?.topic, "ping")
        XCTAssertEqual(message?.payload, "hello")
    }

    func testMobileOSAppLaunchCreatesProcessAndSurface() throws {
        let scheduler = MobileOSScheduler()
        let compositor = MobileOSCompositor()
        let registry = MobileOSAppRegistry()
        try registry.register(MobileOSAppManifest(
            identifier: "dev.arm64viz.test",
            displayName: "Test",
            entryPoint: "test.app.js"
        ))

        let app = try registry.launch(identifier: "dev.arm64viz.test", scheduler: scheduler, compositor: compositor)

        XCTAssertEqual(app.manifest.displayName, "Test")
        XCTAssertEqual(scheduler.allProcesses.count, 1)
        XCTAssertEqual(compositor.orderedSurfaces.count, 1)
    }

    func testMobileOSCompositorDispatchesTouchToTopSurface() {
        let compositor = MobileOSCompositor()
        _ = compositor.createSurface(
            ownerPID: 1,
            title: "Bottom",
            frame: MobileOSRect(x: 0, y: 0, width: 200, height: 200),
            color: MobileOSColor(red: 0, green: 0, blue: 0)
        )
        let top = compositor.createSurface(
            ownerPID: 2,
            title: "Top",
            frame: MobileOSRect(x: 40, y: 40, width: 200, height: 200),
            color: MobileOSColor(red: 255, green: 0, blue: 0)
        )

        let dispatch = compositor.dispatchTouch(TouchEvent(x: 80, y: 80, isDown: true))

        XCTAssertEqual(dispatch.targetSurfaceID, top.id)
        XCTAssertEqual(dispatch.targetPID, 2)
    }

    func testMobileOSCompositorBringToFrontUpdatesTouchTarget() {
        let compositor = MobileOSCompositor()
        let bottom = compositor.createSurface(
            ownerPID: 1,
            title: "Bottom",
            frame: MobileOSRect(x: 0, y: 0, width: 200, height: 200),
            color: MobileOSColor(red: 0, green: 0, blue: 0)
        )
        let top = compositor.createSurface(
            ownerPID: 2,
            title: "Top",
            frame: MobileOSRect(x: 40, y: 40, width: 200, height: 200),
            color: MobileOSColor(red: 255, green: 0, blue: 0)
        )

        XCTAssertEqual(compositor.dispatchTouch(TouchEvent(x: 80, y: 80, isDown: true)).targetSurfaceID, top.id)

        XCTAssertEqual(compositor.bringToFront(surfaceID: bottom.id), bottom)

        XCTAssertEqual(compositor.orderedSurfaces.last?.id, bottom.id)
        XCTAssertEqual(compositor.dispatchTouch(TouchEvent(x: 80, y: 80, isDown: true)).targetSurfaceID, bottom.id)
    }

    func testMobileOSKernelBootIsDisabled() throws {
        let machine = try MachineFactory.makeResearchMachine()

        XCTAssertThrowsError(try MobileOSKernel().boot(on: machine)) { error in
            guard case VMError.unsupportedGuest = error else {
                XCTFail("expected unsupportedGuest, got \(error)")
                return
            }
        }
    }

    func testMobileOSUnixSyscallsUseFileDescriptors() throws {
        let unix = MobileOSUnixEnvironment()
        let pid = try unix.spawn(executable: "/bin/msh", argv: ["msh"])

        let created = try unix.syscall(
            pid: pid,
            MobileOSSyscall(number: .open, path: "/tmp/hello.txt", flags: [.create, .readWrite, .truncate])
        )
        XCTAssertTrue(created.succeeded)

        let fd = MobileOSFileDescriptor(created.returnValue)
        let write = try unix.syscall(
            pid: pid,
            MobileOSSyscall(number: .write, fileDescriptor: fd, text: "hello unix")
        )
        XCTAssertEqual(write.returnValue, 10)
        XCTAssertTrue(try unix.syscall(pid: pid, MobileOSSyscall(number: .close, fileDescriptor: fd)).succeeded)

        let opened = try unix.syscall(pid: pid, MobileOSSyscall(number: .open, path: "/tmp/hello.txt", flags: [.readOnly]))
        let read = try unix.syscall(
            pid: pid,
            MobileOSSyscall(number: .read, fileDescriptor: MobileOSFileDescriptor(opened.returnValue), byteCount: 64)
        )

        XCTAssertEqual(read.text, "hello unix")
    }

    func testMobileOSUnixPipesAndProcessLifecycle() throws {
        let unix = MobileOSUnixEnvironment()
        let pid = try unix.spawn(executable: "/bin/msh", argv: ["msh"])

        let pipe = try unix.syscall(pid: pid, MobileOSSyscall(number: .pipe))
        XCTAssertEqual(pipe.fileDescriptors.count, 2)
        XCTAssertEqual(try unix.syscall(
            pid: pid,
            MobileOSSyscall(number: .write, fileDescriptor: pipe.fileDescriptors[1], text: "through-pipe")
        ).returnValue, 12)
        XCTAssertEqual(try unix.syscall(
            pid: pid,
            MobileOSSyscall(number: .read, fileDescriptor: pipe.fileDescriptors[0], byteCount: 64)
        ).text, "through-pipe")

        let fork = try unix.syscall(pid: pid, MobileOSSyscall(number: .fork))
        let childPID = try XCTUnwrap(fork.pid)
        XCTAssertTrue(try unix.syscall(pid: childPID, MobileOSSyscall(number: .execve, path: "/bin/true", argv: ["true"])).succeeded)
        XCTAssertTrue(try unix.syscall(pid: childPID, MobileOSSyscall(number: .exit, exitStatus: 7)).succeeded)

        let waited = try unix.syscall(pid: pid, MobileOSSyscall(number: .wait4))
        XCTAssertEqual(waited.pid, childPID)
        XCTAssertEqual(waited.text, "7")
    }

    func testMobileOSUnixPTYRunsShellCommands() throws {
        let unix = MobileOSUnixEnvironment()
        let session = try unix.openPTY()
        let banner = try unix.readPTY(id: session.id)
        XCTAssertTrue(banner.contains("MobileOS UNIX tty0"))

        try unix.writePTY(id: session.id, input: "pwd\ncd /tmp\npwd\n")
        let output = try unix.readPTY(id: session.id)

        XCTAssertTrue(output.contains("/home/mobile"))
        XCTAssertTrue(output.contains("/tmp"))
        XCTAssertEqual(unix.report.ptySessions.first?.foregroundPID, session.foregroundPID)
        XCTAssertEqual(
            unix.report.processes.first { $0.pid == session.foregroundPID }?.openFileDescriptors,
            [0, 1, 2]
        )
    }

    func testBootConfigurationRendersDevices() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let config = try ToyUARTGuestAdapter().load(into: machine.vm)
        let dts = config.renderDTS()

        XCTAssertTrue(dts.contains("compatible = \"arm64viz,research-vm\";"))
        XCTAssertTrue(dts.contains("intc: intc@8000000"))
        XCTAssertTrue(dts.contains("interrupt-controller;"))
        XCTAssertTrue(dts.contains("reg = <0x0 0x8000000 0x0 0x10000 0x0 0x8010000 0x0 0x10000>;"))
        XCTAssertTrue(dts.contains("timer: timer@0"))
        XCTAssertTrue(dts.contains("compatible = \"arm,armv8-timer\";"))
        XCTAssertTrue(dts.contains("uart0: uart0@9000000"))
        XCTAssertTrue(dts.contains("compatible = \"arm,pl011\", \"arm,primecell\";"))
        XCTAssertTrue(dts.contains("clock-names = \"uartclk\", \"apb_pclk\";"))
        XCTAssertTrue(dts.contains("clocks = <2 2>;"))
        XCTAssertTrue(dts.contains("clk24mhz: clk24mhz"))
        XCTAssertTrue(dts.contains("virtio_mmio0: virtio_mmio0@a000000"))
        XCTAssertTrue(dts.contains("compatible = \"virtio,mmio\";"))
        XCTAssertFalse(dts.contains("simple-framebuffer"))
        XCTAssertTrue(dts.contains("bootargs = \"console=ttyAMA0 earlycon=arm64viz-uart\";"))
    }

    func testBootConfigurationRendersBinaryFDT() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let config = try ToyUARTGuestAdapter().load(into: machine.vm)
        let fdt = try FlattenedDeviceTree.encode(
            configuration: config,
            initrd: DeviceTreeInitrd(start: 0x4200_0000, endExclusive: 0x4200_1000)
        )

        XCTAssertEqual(readBE32(fdt, at: 0), FlattenedDeviceTree.magic)
        XCTAssertEqual(Int(readBE32(fdt, at: 4)), fdt.count)
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("bootargs"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("linux,initrd-start"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("interrupt-controller"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("arm,armv8-timer"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("arm,primecell"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("clock-names"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("apb_pclk"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("fixed-clock"))
        XCTAssertTrue(String(decoding: fdt, as: UTF8.self).contains("virtio,mmio"))
        XCTAssertFalse(String(decoding: fdt, as: UTF8.self).contains("simple-framebuffer"))
    }

    func testLinuxConsoleDevicePublicationOmitsOptionalResearchDevices() throws {
        let machine = try MachineFactory.makeResearchMachine(publishedDevices: .linuxConsole)
        let config = try ToyUARTGuestAdapter().load(into: machine.vm)
        let dts = config.renderDTS()

        XCTAssertTrue(dts.contains("intc: intc@8000000"))
        XCTAssertTrue(dts.contains("timer: timer@0"))
        XCTAssertTrue(dts.contains("uart0: uart0@9000000"))
        XCTAssertFalse(dts.contains("virtio_mmio0"))
        XCTAssertFalse(dts.contains("simple-framebuffer"))
        XCTAssertFalse(dts.contains("touch0"))
    }

    func testFramebufferSnapshotsTrackGuestWritesByGeneration() throws {
        let framebuffer = VirtualFramebuffer(base: 0x1000_0000, width: 2, height: 1)
        let initial = try XCTUnwrap(framebuffer.snapshot())
        XCTAssertEqual(initial.generation, 0)
        XCTAssertEqual(initial.pixels, [UInt8](repeating: 0, count: 8))
        XCTAssertNil(framebuffer.snapshot(afterGeneration: initial.generation))

        try framebuffer.write(offset: 4, width: .word, value: 0x1122_3344)
        let updated = try XCTUnwrap(framebuffer.snapshot(afterGeneration: initial.generation))
        XCTAssertEqual(updated.generation, 1)
        XCTAssertEqual(updated.width, 2)
        XCTAssertEqual(updated.height, 1)
        XCTAssertEqual(updated.stride, 8)
        XCTAssertEqual(Array(updated.pixels[4..<8]), [0x44, 0x33, 0x22, 0x11])
    }

    func testVirtIOGPUReportsSingleDisplayAndCompletesDisplayInfoCommand() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioDisplayBase
        let descriptorTable: GuestAddress = 0x4018_0000
        let availableRing: GuestAddress = 0x4018_1000
        let usedRing: GuestAddress = 0x4018_2000
        let requestAddress: GuestAddress = 0x4018_3000
        let responseAddress: GuestAddress = 0x4018_4000
        var availableIndex: UInt16 = 0

        XCTAssertEqual(try machine.vm.readPhysical(base + 0x008, width: .word), UInt64(VirtIODeviceKind.gpu.rawValue))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108, width: .word), 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x10c, width: .word), 0)
        try machine.vm.writePhysical(base + 0x0ac, width: .word, value: 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x0ac, width: .word), 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x0b0, width: .word), UInt64(UInt32.max))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x0b4, width: .word), UInt64(UInt32.max))

        try configureVirtioQueue(
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )
        let response = try submitVirtioGPUCommand(
            makeVirtioGPUCommand(type: 0x0100),
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing,
            requestAddress: requestAddress,
            responseAddress: responseAddress,
            availableIndex: &availableIndex,
            responseLength: 408
        )

        XCTAssertEqual(readLE32ForTest(response, at: 0), 0x1101)
        XCTAssertEqual(readLE32ForTest(response, at: 24), 0)
        XCTAssertEqual(readLE32ForTest(response, at: 28), 0)
        XCTAssertEqual(readLE32ForTest(response, at: 32), UInt32(ARM64VizMachineLayout.framebufferWidth))
        XCTAssertEqual(readLE32ForTest(response, at: 36), UInt32(ARM64VizMachineLayout.framebufferHeight))
        XCTAssertEqual(readLE32ForTest(response, at: 40), 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), 408)
    }

    func testVirtIOGPUStagesTransfersAndPublishesOnlyOnFlush() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let frameCommitted = expectation(description: "virtio-gpu frame commit callback")
        frameCommitted.expectedFulfillmentCount = 4
        machine.virtioDisplay.onDisplayFrameCommitted = { _ in
            frameCommitted.fulfill()
        }
        let base = ARM64VizMachineLayout.virtioDisplayBase
        let descriptorTable: GuestAddress = 0x4019_0000
        let availableRing: GuestAddress = 0x4019_1000
        let usedRing: GuestAddress = 0x4019_2000
        let requestAddress: GuestAddress = 0x4019_3000
        let responseAddress: GuestAddress = 0x4019_4000
        let backingAddress: GuestAddress = 0x4019_5000
        var availableIndex: UInt16 = 0

        try configureVirtioQueue(
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )

        var createPayload: [UInt8] = []
        appendLE32(1, to: &createPayload)
        appendLE32(2, to: &createPayload) // B8G8R8X8_UNORM
        appendLE32(2, to: &createPayload)
        appendLE32(2, to: &createPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0101, payload: createPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        var backingPayload: [UInt8] = []
        appendLE32(1, to: &backingPayload)
        appendLE32(2, to: &backingPayload)
        appendLE64(backingAddress, to: &backingPayload)
        appendLE32(8, to: &backingPayload)
        appendLE32(0, to: &backingPayload)
        appendLE64(backingAddress + 8, to: &backingPayload)
        appendLE32(8, to: &backingPayload)
        appendLE32(0, to: &backingPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0106, payload: backingPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        var scanoutPayload: [UInt8] = []
        appendGPUKitRectangle(x: 0, y: 0, width: 2, height: 2, to: &scanoutPayload)
        appendLE32(0, to: &scanoutPayload)
        appendLE32(1, to: &scanoutPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0103, payload: scanoutPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        let firstPixels: [UInt8] = [
            0x10, 0x20, 0x30, 0x00, 0x40, 0x50, 0x60, 0x00,
            0x70, 0x80, 0x90, 0x00, 0xa0, 0xb0, 0xc0, 0x00
        ]
        try writeMemoryBytesForTest(firstPixels, at: backingAddress, into: machine.vm.memory)
        var transferPayload: [UInt8] = []
        appendGPUKitRectangle(x: 0, y: 0, width: 2, height: 2, to: &transferPayload)
        appendLE64(0, to: &transferPayload)
        appendLE32(1, to: &transferPayload)
        appendLE32(0, to: &transferPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0105, payload: transferPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        XCTAssertTrue(machine.virtioDisplay.displayDiagnostics.contains("c1b1"))
        XCTAssertNil(machine.virtioDisplay.displaySnapshot())

        var flushPayload: [UInt8] = []
        appendGPUKitRectangle(x: 0, y: 0, width: 2, height: 2, to: &flushPayload)
        appendLE32(1, to: &flushPayload)
        appendLE32(0, to: &flushPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0104, payload: flushPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        let firstFrame = try XCTUnwrap(machine.virtioDisplay.displaySnapshot())
        XCTAssertEqual(firstFrame.damage, [
            VirtualFramebufferDamage(x: 0, y: 0, width: 480, height: 800)
        ])
        XCTAssertGreaterThan(firstFrame.commitTimestampNanoseconds, 0)
        XCTAssertEqual(Array(firstFrame.pixels[0..<8]), [0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff])
        XCTAssertEqual(Array(firstFrame.pixels[firstFrame.stride..<(firstFrame.stride + 8)]), [0x70, 0x80, 0x90, 0xff, 0xa0, 0xb0, 0xc0, 0xff])

        let partialPixels: [UInt8] = [
            0x10, 0x20, 0x30, 0x00, 0xd1, 0xd2, 0xd3, 0x00,
            0x70, 0x80, 0x90, 0x00, 0xa0, 0xb0, 0xc0, 0x00
        ]
        try writeMemoryBytesForTest(partialPixels, at: backingAddress, into: machine.vm.memory)
        var partialTransferPayload: [UInt8] = []
        appendGPUKitRectangle(x: 1, y: 0, width: 1, height: 1, to: &partialTransferPayload)
        appendLE64(4, to: &partialTransferPayload)
        appendLE32(1, to: &partialTransferPayload)
        appendLE32(0, to: &partialTransferPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0105, payload: partialTransferPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        var partialFlushPayload: [UInt8] = []
        appendGPUKitRectangle(x: 1, y: 0, width: 1, height: 1, to: &partialFlushPayload)
        appendLE32(1, to: &partialFlushPayload)
        appendLE32(0, to: &partialFlushPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0104, payload: partialFlushPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        let partialFrame = try XCTUnwrap(
            machine.virtioDisplay.displaySnapshot(afterGeneration: firstFrame.generation)
        )
        XCTAssertEqual(
            Array(partialFrame.pixels[0..<8]),
            [0x10, 0x20, 0x30, 0xff, 0xd1, 0xd2, 0xd3, 0xff]
        )
        XCTAssertEqual(
            Array(partialFrame.pixels[partialFrame.stride..<(partialFrame.stride + 8)]),
            [0x70, 0x80, 0x90, 0xff, 0xa0, 0xb0, 0xc0, 0xff]
        )
        XCTAssertEqual(partialFrame.damage, [
            VirtualFramebufferDamage(x: 1, y: 0, width: 1, height: 1)
        ])
        var directMetadata: VirtualFramebufferFrameMetadata?
        var directPixel: [UInt8] = []
        var directBaseAddress: UnsafeRawPointer?
        var directStorageByteCount = 0
        let directResult = machine.virtioDisplay.withDisplayFrameBytes(
            afterGeneration: firstFrame.generation
        ) { metadata, bytes in
            directMetadata = metadata
            directPixel = Array(bytes[4..<8])
            directBaseAddress = bytes.baseAddress
            directStorageByteCount = bytes.count
        }
        XCTAssertEqual(directResult, directMetadata)
        XCTAssertEqual(directMetadata?.generation, partialFrame.generation)
        XCTAssertEqual(directMetadata?.damagedByteCount, 4)
        XCTAssertEqual(directMetadata?.hasStableStorage, true)
        XCTAssertGreaterThanOrEqual(
            directStorageByteCount,
            partialFrame.stride * partialFrame.height
        )
        XCTAssertEqual(
            Int(bitPattern: directBaseAddress) % Int(getpagesize()),
            0
        )
        XCTAssertEqual(directPixel, [0xd1, 0xd2, 0xd3, 0xff])

        var repeatedBaseAddress: UnsafeRawPointer?
        _ = machine.virtioDisplay.withDisplayFrameBytes(
            afterGeneration: firstFrame.generation
        ) { _, bytes in
            repeatedBaseAddress = bytes.baseAddress
        }
        XCTAssertEqual(repeatedBaseAddress, directBaseAddress)

        let untransferredPixels = [UInt8](repeating: 0xee, count: 16)
        try writeMemoryBytesForTest(untransferredPixels, at: backingAddress, into: machine.vm.memory)
        let backingFrame = try XCTUnwrap(
            machine.virtioDisplay.displayBackingSnapshot(memory: machine.vm.memory)
        )
        XCTAssertEqual(
            Array(backingFrame.pixels[0..<8]),
            [0xee, 0xee, 0xee, 0xff, 0xee, 0xee, 0xee, 0xff]
        )
        XCTAssertNil(machine.virtioDisplay.displaySnapshot(afterGeneration: partialFrame.generation))

        let secondPixels = [UInt8](repeating: 0xdd, count: 16)
        try writeMemoryBytesForTest(secondPixels, at: backingAddress, into: machine.vm.memory)
        XCTAssertEqual(try submitGPUCommandType(
            0x0105, payload: transferPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        XCTAssertNil(machine.virtioDisplay.displaySnapshot(afterGeneration: partialFrame.generation))

        XCTAssertEqual(try submitGPUCommandType(
            0x0104, payload: flushPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        let secondFrame = try XCTUnwrap(machine.virtioDisplay.displaySnapshot(afterGeneration: partialFrame.generation))
        XCTAssertGreaterThan(secondFrame.generation, firstFrame.generation)
        XCTAssertEqual(Array(secondFrame.pixels[0..<8]), [0xdd, 0xdd, 0xdd, 0xff, 0xdd, 0xdd, 0xdd, 0xff])

        var secondCreatePayload: [UInt8] = []
        appendLE32(2, to: &secondCreatePayload)
        appendLE32(2, to: &secondCreatePayload) // B8G8R8X8_UNORM
        appendLE32(2, to: &secondCreatePayload)
        appendLE32(2, to: &secondCreatePayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0101, payload: secondCreatePayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        let secondBackingAddress: GuestAddress = backingAddress + 0x1000
        var secondBackingPayload: [UInt8] = []
        appendLE32(2, to: &secondBackingPayload)
        appendLE32(1, to: &secondBackingPayload)
        appendLE64(secondBackingAddress, to: &secondBackingPayload)
        appendLE32(16, to: &secondBackingPayload)
        appendLE32(0, to: &secondBackingPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0106, payload: secondBackingPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        let alternatePixels: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x21, 0x22, 0x23, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        try writeMemoryBytesForTest(alternatePixels, at: secondBackingAddress, into: machine.vm.memory)
        var secondTransferPayload: [UInt8] = []
        appendGPUKitRectangle(x: 0, y: 0, width: 2, height: 2, to: &secondTransferPayload)
        appendLE64(0, to: &secondTransferPayload)
        appendLE32(2, to: &secondTransferPayload)
        appendLE32(0, to: &secondTransferPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0105, payload: secondTransferPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        var secondScanoutPayload = scanoutPayload
        secondScanoutPayload.replaceSubrange(20..<24, with: [2, 0, 0, 0])
        XCTAssertEqual(try submitGPUCommandType(
            0x0103, payload: secondScanoutPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)

        var secondFlushPayload: [UInt8] = []
        appendGPUKitRectangle(x: 0, y: 0, width: 2, height: 2, to: &secondFlushPayload)
        appendLE32(2, to: &secondFlushPayload)
        appendLE32(0, to: &secondFlushPayload)
        XCTAssertEqual(try submitGPUCommandType(
            0x0104, payload: secondFlushPayload, machine: machine, base: base,
            descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing,
            requestAddress: requestAddress, responseAddress: responseAddress, availableIndex: &availableIndex
        ), 0x1100)
        let switchedFrame = try XCTUnwrap(
            machine.virtioDisplay.displaySnapshot(afterGeneration: secondFrame.generation)
        )
        XCTAssertEqual(
            Array(switchedFrame.pixels[0..<8]),
            [0x00, 0x00, 0x00, 0xff, 0x21, 0x22, 0x23, 0xff]
        )
        XCTAssertEqual(
            Array(switchedFrame.pixels[switchedFrame.stride..<(switchedFrame.stride + 8)]),
            [0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff]
        )
        XCTAssertTrue(machine.virtioDisplay.displayDiagnostics.contains("tr=r2:0,0,2x2@0:c1"))
        XCTAssertTrue(machine.virtioDisplay.displayDiagnostics.contains("c1b1"))
        XCTAssertTrue(machine.virtioDisplay.displayDiagnostics.contains("fl=r2:0,0,2x2:p1c1"))
        XCTAssertEqual(machine.virtioDisplay.displayGeneration, switchedFrame.generation)
        wait(for: [frameCommitted], timeout: 0.1)
    }

    func testVirtIOGPUFullTransfersCopyOnlyDirtyBackingPages() throws {
        let width = 64
        let height = 32
        let byteCount = width * height * 4
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x10_000)
        let backingAddress = memory.base + 0x2000
        let gpu = VirtIOGPUDevice(width: width, height: height)

        var createPayload: [UInt8] = []
        appendLE32(1, to: &createPayload)
        appendLE32(2, to: &createPayload) // B8G8R8X8_UNORM
        appendLE32(UInt32(width), to: &createPayload)
        appendLE32(UInt32(height), to: &createPayload)
        XCTAssertEqual(readLE32ForTest(gpu.process(
            request: makeVirtioGPUCommand(type: 0x0101, payload: createPayload),
            memory: memory
        ), at: 0), 0x1100)

        var backingPayload: [UInt8] = []
        appendLE32(1, to: &backingPayload)
        appendLE32(1, to: &backingPayload)
        appendLE64(backingAddress, to: &backingPayload)
        appendLE32(UInt32(byteCount), to: &backingPayload)
        appendLE32(0, to: &backingPayload)
        XCTAssertEqual(readLE32ForTest(gpu.process(
            request: makeVirtioGPUCommand(type: 0x0106, payload: backingPayload),
            memory: memory
        ), at: 0), 0x1100)

        var scanoutPayload: [UInt8] = []
        appendGPUKitRectangle(
            x: 0,
            y: 0,
            width: UInt32(width),
            height: UInt32(height),
            to: &scanoutPayload
        )
        appendLE32(0, to: &scanoutPayload)
        appendLE32(1, to: &scanoutPayload)
        XCTAssertEqual(readLE32ForTest(gpu.process(
            request: makeVirtioGPUCommand(type: 0x0103, payload: scanoutPayload),
            memory: memory
        ), at: 0), 0x1100)

        var transferPayload: [UInt8] = []
        appendGPUKitRectangle(
            x: 0,
            y: 0,
            width: UInt32(width),
            height: UInt32(height),
            to: &transferPayload
        )
        appendLE64(0, to: &transferPayload)
        appendLE32(1, to: &transferPayload)
        appendLE32(0, to: &transferPayload)
        var flushPayload: [UInt8] = []
        appendGPUKitRectangle(
            x: 0,
            y: 0,
            width: UInt32(width),
            height: UInt32(height),
            to: &flushPayload
        )
        appendLE32(1, to: &flushPayload)
        appendLE32(0, to: &flushPayload)

        try memory.writeBytes([UInt8](repeating: 0, count: byteCount), at: backingAddress)
        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0105, payload: transferPayload),
            memory: memory
        )
        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0104, payload: flushPayload),
            memory: memory
        )
        let firstFrame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))

        let changedX = 7
        let changedY = 20
        let changedOffset = (changedY * width + changedX) * 4
        try memory.writeBytes(
            [0x10, 0x20, 0x30, 0x00],
            at: backingAddress + UInt64(changedOffset)
        )
        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0105, payload: transferPayload),
            memory: memory
        )
        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0104, payload: flushPayload),
            memory: memory
        )
        let changedFrame = try XCTUnwrap(
            gpu.snapshot(afterGeneration: firstFrame.generation)
        )

        XCTAssertEqual(changedFrame.damage, [
            VirtualFramebufferDamage(x: changedX, y: changedY, width: 1, height: 1)
        ])
        XCTAssertEqual(
            Array(changedFrame.pixels[changedOffset..<(changedOffset + 4)]),
            [0x10, 0x20, 0x30, 0xff]
        )
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pages=1/1:12288/4096"))

        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0105, payload: transferPayload),
            memory: memory
        )
        _ = gpu.process(
            request: makeVirtioGPUCommand(type: 0x0104, payload: flushPayload),
            memory: memory
        )
        XCTAssertNil(gpu.snapshot(afterGeneration: changedFrame.generation))
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pages=2/1:12288/12288"))
    }

    func testVirtIOGPUCursorQueueAcceptsOutputOnlyCommands() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioDisplayBase
        let descriptorTable: GuestAddress = 0x401a_0000
        let availableRing: GuestAddress = 0x401a_1000
        let usedRing: GuestAddress = 0x401a_2000
        let requestAddress: GuestAddress = 0x401a_3000

        try configureVirtioQueue(
            machine: machine,
            base: base,
            queue: 1,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )

        var cursorPayload: [UInt8] = []
        appendLE32(0, to: &cursorPayload) // scanout
        appendLE32(12, to: &cursorPayload)
        appendLE32(34, to: &cursorPayload)
        appendLE32(0, to: &cursorPayload)
        appendLE32(0, to: &cursorPayload) // hide cursor
        appendLE32(0, to: &cursorPayload)
        appendLE32(0, to: &cursorPayload)
        appendLE32(0, to: &cursorPayload)
        let request = makeVirtioGPUCommand(type: 0x0300, payload: cursorPayload)
        try writeMemoryBytesForTest(request, at: requestAddress, into: machine.vm.memory)
        try writeVirtioDescriptor(
            machine: machine,
            at: descriptorTable,
            index: 0,
            address: requestAddress,
            length: UInt32(request.count),
            flags: 0,
            next: 0
        )
        try machine.vm.memory.write16(0, at: availableRing + 4)
        try machine.vm.memory.write16(1, at: availableRing + 2)

        try machine.vm.writePhysical(base + 0x050, width: .word, value: 1)

        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 4), 0)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), 0)
    }

    func testVirtIOMMIOBlockDeviceSupportsDiscoveryQueueSetupAndInterruptAck() throws {
        let machine = try MachineFactory.makeResearchMachine(blockStorageSize: 4096)
        let base = ARM64VizMachineLayout.virtioBlockBase
        let line = try XCTUnwrap(machine.virtioBlock.interruptLine)
        machine.vm.interruptController.setEnabled(line: line, enabled: true)

        XCTAssertEqual(try machine.vm.readPhysical(base + 0x000, width: .word), UInt64(VirtualVirtIODevice.magicValue))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x004, width: .word), UInt64(VirtualVirtIODevice.version))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x008, width: .word), UInt64(VirtIODeviceKind.block.rawValue))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x00c, width: .word), UInt64(VirtualVirtIODevice.vendorID))
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x100, width: .doubleword), UInt64(machine.virtioBlock.storageBytes.count / machine.virtioBlock.blockSize))

        try machine.vm.writePhysical(base + 0x030, width: .word, value: 0)
        try machine.vm.writePhysical(base + 0x038, width: .word, value: 8)
        try machine.vm.writePhysical(base + 0x080, width: .word, value: 0x1234_5000)
        try machine.vm.writePhysical(base + 0x084, width: .word, value: 0)
        try machine.vm.writePhysical(base + 0x090, width: .word, value: 0x1234_6000)
        try machine.vm.writePhysical(base + 0x0a0, width: .word, value: 0x1234_7000)
        try machine.vm.writePhysical(base + 0x044, width: .word, value: 1)
        try machine.vm.writePhysical(base + 0x070, width: .word, value: 0xf)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(machine.virtioBlock.lastNotifiedQueue, 0)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x060, width: .word), UInt64(VirtualVirtIODevice.usedBufferInterrupt))
        XCTAssertEqual(machine.vm.interruptController.peekPending(), line)

        try machine.vm.writePhysical(base + 0x064, width: .word, value: UInt64(VirtualVirtIODevice.usedBufferInterrupt))

        XCTAssertEqual(try machine.vm.readPhysical(base + 0x060, width: .word), 0)
        XCTAssertNil(machine.vm.interruptController.peekPending())
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x070, width: .word), 0xf)
    }

    func testFileBackedVirtIOBlockStoragePersistsBoundedWritesAndZeroes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = directory.appendingPathComponent("rootfs.ext4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var initialBytes = Array(repeating: UInt8(0x5a), count: 128 * 1024)
        initialBytes.replaceSubrange(4096..<8192, with: repeatElement(UInt8(0xa5), count: 4096))
        try Data(initialBytes).write(to: imageURL)

        do {
            let storage = try FileBackedVirtIOBlockStorage(url: imageURL)
            let machine = try MachineFactory.makeResearchMachine(
                blockStorageSize: 512,
                blockStorage: storage
            )

            XCTAssertEqual(machine.virtioBlock.storageByteCount, initialBytes.count)
            XCTAssertEqual(try storage.read(at: 4096, count: 32), Array(repeating: 0xa5, count: 32))

            try storage.write(Array(repeating: 0x3c, count: 1024), at: 16 * 1024)
            try storage.zero(at: 32 * 1024, count: 64 * 1024)
            try machine.virtioBlock.flushStorage()
        }

        let reopened = try FileBackedVirtIOBlockStorage(url: imageURL)
        XCTAssertEqual(try reopened.read(at: 16 * 1024, count: 1024), Array(repeating: 0x3c, count: 1024))
        XCTAssertEqual(try reopened.read(at: 32 * 1024, count: 64 * 1024), Array(repeating: 0, count: 64 * 1024))
        XCTAssertEqual(try reopened.read(at: 96 * 1024, count: 32), Array(repeating: 0x5a, count: 32))
    }

    func testMMIOAccessCountersTrackBeyondTraceCapacity() throws {
        let machine = try MachineFactory.makeResearchMachine(blockStorageSize: 4096)
        let base = ARM64VizMachineLayout.virtioBlockBase
        machine.vm.enableMMIOTrace(capacity: 1)

        _ = try machine.vm.readPhysical(base + 0x000, width: .word)
        _ = try machine.vm.readPhysical(base + 0x004, width: .word)
        _ = try machine.vm.readPhysical(base + 0x000, width: .word)

        XCTAssertEqual(machine.vm.mmioTrace.count, 1)
        XCTAssertTrue(machine.vm.mmioAccessCounters.contains {
            $0.deviceName == "virtio_mmio0" && $0.access == .read && $0.offset == 0 && $0.count == 2
        })
        XCTAssertTrue(machine.vm.mmioAccessCounters.contains {
            $0.deviceName == "virtio_mmio0" && $0.access == .read && $0.offset == 4 && $0.count == 1
        })
    }

    func testVirtIOMMIOBlockDeviceExecutesReadAndWriteDescriptorChains() throws {
        let machine = try MachineFactory.makeResearchMachine(blockStorageSize: 4096)
        let base = ARM64VizMachineLayout.virtioBlockBase
        let descriptorTable: GuestAddress = 0x4010_0000
        let availableRing: GuestAddress = 0x4010_1000
        let usedRing: GuestAddress = 0x4010_2000
        let header: GuestAddress = 0x4010_3000
        let data: GuestAddress = 0x4010_4000
        let status: GuestAddress = 0x4010_5000
        var disk = [UInt8](repeating: 0, count: 4096)
        for index in 0..<512 {
            disk[512 + index] = UInt8(index & 0xff)
        }
        try machine.virtioBlock.replaceStorage(disk)

        try configureVirtioQueue(machine: machine, base: base, descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing)
        try writeVirtioBlockHeader(machine: machine, at: header, requestType: 0, sector: 1)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 0, address: header, length: 16, flags: 1, next: 1)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 1, address: data, length: 512, flags: 3, next: 2)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 2, address: status, length: 1, flags: 2, next: 0)
        try machine.vm.memory.write16(1, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 4)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(try machine.vm.memory.read8(at: status), 0)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 4), 0)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), 513)
        XCTAssertEqual(try machine.vm.memory.read8(at: data + 1), 1)
        XCTAssertEqual(try machine.vm.memory.read8(at: data + 255), 255)

        for index in 0..<512 {
            try machine.vm.memory.write8(UInt8((255 - index) & 0xff), at: data + UInt64(index))
        }
        try writeVirtioBlockHeader(machine: machine, at: header, requestType: 1, sector: 2)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 1, address: data, length: 512, flags: 1, next: 2)
        try machine.vm.memory.write8(0xff, at: status)
        try machine.vm.memory.write16(2, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 6)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(machine.virtioBlock.completedBlockRequests, 2)
        XCTAssertEqual(try machine.vm.memory.read8(at: status), 0)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 2)
        XCTAssertEqual(Array(machine.virtioBlock.storageBytes[1024..<1536]), (0..<512).map { UInt8((255 - $0) & 0xff) })
    }

    func testVirtIOMMIOBlockDeviceAcceptsTwoDescriptorFlushRequest() throws {
        let machine = try MachineFactory.makeResearchMachine(blockStorageSize: 4096)
        let base = ARM64VizMachineLayout.virtioBlockBase
        let descriptorTable: GuestAddress = 0x4012_0000
        let availableRing: GuestAddress = 0x4012_1000
        let usedRing: GuestAddress = 0x4012_2000
        let header: GuestAddress = 0x4012_3000
        let status: GuestAddress = 0x4012_5000

        try configureVirtioQueue(machine: machine, base: base, descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing)
        try writeVirtioBlockHeader(machine: machine, at: header, requestType: 4, sector: 0)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 0, address: header, length: 16, flags: 1, next: 1)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 1, address: status, length: 1, flags: 2, next: 0)
        try machine.vm.memory.write8(0xff, at: status)
        try machine.vm.memory.write16(1, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 4)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(try machine.vm.memory.read8(at: status), 0)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 4), 0)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), 1)
        XCTAssertEqual(machine.virtioBlock.completedBlockRequests, 1)
        XCTAssertEqual(machine.virtioBlock.completedBlockRequestTypes[4], 1)
        XCTAssertTrue(machine.virtioBlock.recentBlockRequestSummaries.last?.contains("flush") == true)
    }

    func testVirtIOMMIOBlockDeviceSupportsDiscardAndWriteZeroesRequests() throws {
        let machine = try MachineFactory.makeResearchMachine(blockStorageSize: 4096)
        let base = ARM64VizMachineLayout.virtioBlockBase
        let descriptorTable: GuestAddress = 0x4011_0000
        let availableRing: GuestAddress = 0x4011_1000
        let usedRing: GuestAddress = 0x4011_2000
        let header: GuestAddress = 0x4011_3000
        let rangePayload: GuestAddress = 0x4011_4000
        let status: GuestAddress = 0x4011_5000
        var disk = [UInt8](repeating: 0xff, count: 4096)
        disk.replaceSubrange(0..<512, with: repeatElement(UInt8(0x7a), count: 512))
        try machine.virtioBlock.replaceStorage(disk)

        try configureVirtioQueue(machine: machine, base: base, descriptorTable: descriptorTable, availableRing: availableRing, usedRing: usedRing)
        try writeVirtioBlockHeader(machine: machine, at: header, requestType: 13, sector: 0)
        try machine.vm.memory.write64(1, at: rangePayload)
        try machine.vm.memory.write32(2, at: rangePayload + 8)
        try machine.vm.memory.write32(0, at: rangePayload + 12)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 0, address: header, length: 16, flags: 1, next: 1)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 1, address: rangePayload, length: 16, flags: 1, next: 2)
        try writeVirtioDescriptor(machine: machine, at: descriptorTable, index: 2, address: status, length: 1, flags: 2, next: 0)
        try machine.vm.memory.write16(1, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 4)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(try machine.vm.memory.read8(at: status), 0)
        XCTAssertEqual(Array(machine.virtioBlock.storageBytes[0..<512]), Array(repeating: 0x7a, count: 512))
        XCTAssertEqual(Array(machine.virtioBlock.storageBytes[512..<1536]), Array(repeating: 0, count: 1024))

        try writeVirtioBlockHeader(machine: machine, at: header, requestType: 11, sector: 0)
        try machine.vm.memory.write64(3, at: rangePayload)
        try machine.vm.memory.write32(1, at: rangePayload + 8)
        try machine.vm.memory.write32(0, at: rangePayload + 12)
        try machine.vm.memory.write8(0xff, at: status)
        try machine.vm.memory.write16(2, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 6)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(try machine.vm.memory.read8(at: status), 0)
        XCTAssertEqual(Array(machine.virtioBlock.storageBytes[1536..<2048]), Array(repeating: 0, count: 512))
        XCTAssertEqual(machine.virtioBlock.completedBlockRequests, 2)
        XCTAssertEqual(machine.virtioBlock.completedBlockRequestTypes[13], 1)
        XCTAssertEqual(machine.virtioBlock.completedBlockRequestTypes[11], 1)
        XCTAssertTrue(machine.virtioBlock.recentBlockRequestSummaries.last?.contains("discard") == true)
    }

    func testVirtIONetworkTransmitQueuePublishesEthernetFrames() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let backend = BufferedVirtIONetworkBackend()
        machine.virtioNetwork.attachNetworkBackend(backend)
        let base = ARM64VizMachineLayout.virtioNetworkBase
        let descriptorTable: GuestAddress = 0x4014_0000
        let availableRing: GuestAddress = 0x4014_1000
        let usedRing: GuestAddress = 0x4014_2000
        let packet: GuestAddress = 0x4014_3000
        let frame = Array("ethernet-frame".utf8)
        let virtioHeader = [UInt8](repeating: 0, count: 10)

        try configureVirtioQueue(
            machine: machine,
            base: base,
            queue: 1,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )
        try writeMemoryBytesForTest(virtioHeader + frame, at: packet, into: machine.vm.memory)
        try writeVirtioDescriptor(
            machine: machine,
            at: descriptorTable,
            index: 0,
            address: packet,
            length: UInt32(virtioHeader.count + frame.count),
            flags: 0,
            next: 0
        )
        try machine.vm.memory.write16(1, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 4)

        try machine.vm.writePhysical(base + 0x050, width: .word, value: 1)

        XCTAssertEqual(backend.transmittedFrames, [frame])
        XCTAssertEqual(machine.virtioNetwork.completedNetworkTransmits, 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 4), 0)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), UInt32(virtioHeader.count + frame.count))
    }

    func testVirtIONetworkReceiveQueueDeliversInjectedEthernetFrames() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioNetworkBase
        let descriptorTable: GuestAddress = 0x4015_0000
        let availableRing: GuestAddress = 0x4015_1000
        let usedRing: GuestAddress = 0x4015_2000
        let packet: GuestAddress = 0x4015_3000
        let frame = Array("rx-frame".utf8)

        try configureVirtioQueue(
            machine: machine,
            base: base,
            queue: 0,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )
        try writeVirtioDescriptor(
            machine: machine,
            at: descriptorTable,
            index: 0,
            address: packet,
            length: 128,
            flags: 2,
            next: 0
        )
        try machine.vm.memory.write16(1, at: availableRing + 2)
        try machine.vm.memory.write16(0, at: availableRing + 4)

        machine.virtioNetwork.injectNetworkReceiveFrame(frame)

        XCTAssertEqual(machine.virtioNetwork.completedNetworkReceives, 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 4), 0)
        XCTAssertEqual(try machine.vm.memory.read32(at: usedRing + 8), UInt32(10 + frame.count))
        for offset in 0..<10 {
            XCTAssertEqual(try machine.vm.memory.read8(at: packet + UInt64(offset)), 0)
        }
        let received = try (0..<frame.count).map { offset in
            try machine.vm.memory.read8(at: packet + 10 + UInt64(offset))
        }
        XCTAssertEqual(received, frame)
    }

    func testVirtIOInputPublishesTouchscreenCapabilities() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioInputBase

        try machine.vm.writePhysical(base + 0x100, width: .byte, value: 0x11)
        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 0)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108, width: .byte), 0x0b)

        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 42)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108 + 41, width: .byte), 0x04)

        try machine.vm.writePhysical(base + 0x100, width: .byte, value: 0x12)
        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 0)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 20)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108 + 4, width: .word), 479)
        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108 + 4, width: .word), 799)
        for (axis, maximum) in [(47, 0), (53, 479), (54, 799), (57, Int(UInt16.max))] {
            try machine.vm.writePhysical(base + 0x101, width: .byte, value: UInt64(axis))
            XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 20)
            XCTAssertEqual(
                try machine.vm.readPhysical(base + 0x108 + 4, width: .word),
                UInt64(maximum)
            )
        }

        try machine.vm.writePhysical(base + 0x100, width: .byte, value: 0x11)
        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 3)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 8)
        for axis in [0, 1, 47, 53, 54, 57] {
            let byte = try machine.vm.readPhysical(
                base + 0x108 + UInt64(axis / 8),
                width: .byte
            )
            XCTAssertNotEqual(byte & UInt64(1 << (axis % 8)), 0)
        }
    }

    func testVirtIOInputDeliversAbsoluteTouchEventFrame() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioInputBase
        let descriptorTable: GuestAddress = 0x4018_0000
        let availableRing: GuestAddress = 0x4018_1000
        let usedRing: GuestAddress = 0x4018_2000
        let events: GuestAddress = 0x4018_3000

        try configureVirtioQueue(
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )
        for index in UInt16(0)..<8 {
            try writeVirtioDescriptor(
                machine: machine,
                at: descriptorTable,
                index: index,
                address: events + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0
            )
            try machine.vm.memory.write16(index, at: availableRing + 4 + UInt64(index) * 2)
        }
        try machine.vm.memory.write16(8, at: availableRing + 2)

        machine.virtioInput.enqueueTouch(x: 321, y: 123, isDown: true)

        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 8)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x060, width: .word), 1)
        let expected: [(UInt16, UInt16, UInt32)] = [
            (1, 330, 1),
            (3, 0, 321),
            (3, 1, 123),
            (3, 47, 0),
            (3, 57, 0),
            (3, 53, 321),
            (3, 54, 123),
            (0, 0, 0)
        ]
        for (index, event) in expected.enumerated() {
            let address = events + UInt64(index) * 8
            XCTAssertEqual(try machine.vm.memory.read16(at: address), event.0)
            XCTAssertEqual(try machine.vm.memory.read16(at: address + 2), event.1)
            XCTAssertEqual(try machine.vm.memory.read32(at: address + 4), event.2)
        }

        machine.virtioInput.enqueueTouch(x: 400, y: 300, isDown: true)
        machine.virtioInput.enqueueTouch(x: 350, y: 200, isDown: true)
        for index in UInt16(0)..<6 {
            try machine.vm.memory.write16(
                index,
                at: availableRing + 4 + UInt64(index) * 2
            )
        }
        try machine.vm.memory.write16(14, at: availableRing + 2)
        machine.virtioInput.enqueueTouch(x: 320, y: 80, isDown: true)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 14)
        let moveExpected: [(UInt16, UInt16, UInt32)] = [
            (3, 0, 320),
            (3, 1, 80),
            (3, 47, 0),
            (3, 53, 320),
            (3, 54, 80),
            (0, 0, 0)
        ]
        for (index, event) in moveExpected.enumerated() {
            let address = events + UInt64(index) * 8
            XCTAssertEqual(try machine.vm.memory.read16(at: address), event.0)
            XCTAssertEqual(try machine.vm.memory.read16(at: address + 2), event.1)
            XCTAssertEqual(try machine.vm.memory.read32(at: address + 4), event.2)
        }

        for index in UInt16(0)..<4 {
            let ringSlot = UInt16((14 + Int(index)) % 8)
            try machine.vm.memory.write16(
                index,
                at: availableRing + 4 + UInt64(ringSlot) * 2
            )
        }
        try machine.vm.memory.write16(18, at: availableRing + 2)
        machine.virtioInput.enqueueTouch(x: 320, y: 80, isDown: false)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 18)
        let releaseExpected: [(UInt16, UInt16, UInt32)] = [
            (1, 330, 0),
            (3, 47, 0),
            (3, 57, UInt32.max),
            (0, 0, 0)
        ]
        for (index, event) in releaseExpected.enumerated() {
            let address = events + UInt64(index) * 8
            XCTAssertEqual(try machine.vm.memory.read16(at: address), event.0)
            XCTAssertEqual(try machine.vm.memory.read16(at: address + 2), event.1)
            XCTAssertEqual(try machine.vm.memory.read32(at: address + 4), event.2)
        }
    }

    func testVirtIOInputRetainsTouchFrameUntilLinuxReplenishesEventQueue() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioInputBase
        let descriptorTable: GuestAddress = 0x4019_0000
        let availableRing: GuestAddress = 0x4019_1000
        let usedRing: GuestAddress = 0x4019_2000
        let events: GuestAddress = 0x4019_3000

        try configureVirtioQueue(
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )

        machine.virtioInput.enqueueTouch(x: 240, y: 700, isDown: true)
        XCTAssertEqual(machine.virtioInput.inputSamplesReceived, 1)
        XCTAssertEqual(machine.virtioInput.inputFramesGenerated, 1)
        XCTAssertEqual(machine.virtioInput.pendingInputEventCount, 8)
        XCTAssertEqual(machine.virtioInput.inputEventsDelivered, 0)
        XCTAssertGreaterThan(machine.virtioInput.inputQueueStarvations, 0)

        for index in UInt16(0)..<8 {
            try writeVirtioDescriptor(
                machine: machine,
                at: descriptorTable,
                index: index,
                address: events + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0
            )
            try machine.vm.memory.write16(index, at: availableRing + 4 + UInt64(index) * 2)
        }
        try machine.vm.memory.write16(8, at: availableRing + 2)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)

        XCTAssertEqual(machine.virtioInput.pendingInputEventCount, 0)
        XCTAssertEqual(machine.virtioInput.inputEventsDelivered, 8)
        XCTAssertEqual(machine.virtioInput.inputFramesDelivered, 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 8)
    }

    func testVirtIOKeyboardPublishesKeysAndRepeatCapabilities() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioKeyboardBase

        try machine.vm.writePhysical(base + 0x100, width: .byte, value: 0x11)
        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 0)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 3)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108, width: .byte), 0x03)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x10a, width: .byte), 0x10)

        try machine.vm.writePhysical(base + 0x101, width: .byte, value: 1)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x102, width: .byte), 32)
        XCTAssertEqual(try machine.vm.readPhysical(base + 0x108 + 30 / 8, width: .byte) & (1 << (30 % 8)), 1 << (30 % 8))
    }

    func testVirtIOKeyboardDeliversPressReleaseFrames() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let base = ARM64VizMachineLayout.virtioKeyboardBase
        let descriptorTable: GuestAddress = 0x4019_0000
        let availableRing: GuestAddress = 0x4019_1000
        let usedRing: GuestAddress = 0x4019_2000
        let events: GuestAddress = 0x4019_3000

        try configureVirtioQueue(
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing
        )
        for index in UInt16(0)..<4 {
            try writeVirtioDescriptor(
                machine: machine,
                at: descriptorTable,
                index: index,
                address: events + UInt64(index) * 8,
                length: 8,
                flags: 2,
                next: 0
            )
            try machine.vm.memory.write16(index, at: availableRing + 4 + UInt64(index) * 2)
        }
        try machine.vm.memory.write16(4, at: availableRing + 2)

        machine.virtioKeyboard.enqueueKey(code: 30, value: 1)
        machine.virtioKeyboard.enqueueKey(code: 30, value: 0)

        XCTAssertEqual(try machine.vm.memory.read16(at: usedRing + 2), 4)
        let expected: [(UInt16, UInt16, UInt32)] = [
            (1, 30, 1), (0, 0, 0), (1, 30, 0), (0, 0, 0)
        ]
        for (index, event) in expected.enumerated() {
            let address = events + UInt64(index) * 8
            XCTAssertEqual(try machine.vm.memory.read16(at: address), event.0)
            XCTAssertEqual(try machine.vm.memory.read16(at: address + 2), event.1)
            XCTAssertEqual(try machine.vm.memory.read32(at: address + 4), event.2)
        }
    }

    func testVirtIONetworkTransmitImmediatelyServicesICMPEchoReply() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.virtioNetwork.attachNetworkBackend(LinkLocalVirtIONetworkBackend())
        let base = ARM64VizMachineLayout.virtioNetworkBase
        let rxDescriptorTable: GuestAddress = 0x4016_0000
        let rxAvailableRing: GuestAddress = 0x4016_1000
        let rxUsedRing: GuestAddress = 0x4016_2000
        let rxPacket: GuestAddress = 0x4016_3000
        let txDescriptorTable: GuestAddress = 0x4017_0000
        let txAvailableRing: GuestAddress = 0x4017_1000
        let txUsedRing: GuestAddress = 0x4017_2000
        let txPacket: GuestAddress = 0x4017_3000
        let frame = makeIPv4ICMPEchoFrame(destinationIP: LinkLocalVirtIONetworkBackend.hostIPv4)
        let virtioHeader = [UInt8](repeating: 0, count: 10)

        try configureVirtioQueue(
            machine: machine,
            base: base,
            queue: 0,
            descriptorTable: rxDescriptorTable,
            availableRing: rxAvailableRing,
            usedRing: rxUsedRing
        )
        try writeVirtioDescriptor(
            machine: machine,
            at: rxDescriptorTable,
            index: 0,
            address: rxPacket,
            length: 2048,
            flags: 2,
            next: 0
        )
        try machine.vm.memory.write16(1, at: rxAvailableRing + 2)
        try machine.vm.memory.write16(0, at: rxAvailableRing + 4)

        try configureVirtioQueue(
            machine: machine,
            base: base,
            queue: 1,
            descriptorTable: txDescriptorTable,
            availableRing: txAvailableRing,
            usedRing: txUsedRing
        )
        try writeMemoryBytesForTest(virtioHeader + frame, at: txPacket, into: machine.vm.memory)
        try writeVirtioDescriptor(
            machine: machine,
            at: txDescriptorTable,
            index: 0,
            address: txPacket,
            length: UInt32(virtioHeader.count + frame.count),
            flags: 0,
            next: 0
        )
        try machine.vm.memory.write16(1, at: txAvailableRing + 2)
        try machine.vm.memory.write16(0, at: txAvailableRing + 4)

        try machine.vm.writePhysical(base + 0x050, width: .word, value: 1)

        XCTAssertEqual(machine.virtioNetwork.completedNetworkTransmits, 1)
        XCTAssertEqual(machine.virtioNetwork.completedNetworkReceives, 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: txUsedRing + 2), 1)
        XCTAssertEqual(try machine.vm.memory.read16(at: rxUsedRing + 2), 1)

        let received = try (0..<(10 + frame.count)).map { offset in
            try machine.vm.memory.read8(at: rxPacket + UInt64(offset))
        }
        XCTAssertEqual(Array(received[0..<10]), virtioHeader)
        XCTAssertEqual(Array(received[10..<16]), [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee])
        XCTAssertEqual(Array(received[16..<22]), LinkLocalVirtIONetworkBackend.hostMAC)
        XCTAssertEqual(Array(received[22..<24]), [0x08, 0x00])
        XCTAssertEqual(Array(received[36..<40]), LinkLocalVirtIONetworkBackend.hostIPv4)
        XCTAssertEqual(Array(received[40..<44]), LinkLocalVirtIONetworkBackend.guestIPv4)
        XCTAssertEqual(received[44], 0)
    }

    func testLinkLocalNetworkBackendHandlesMergedVirtioHeaderPrefix() throws {
        let senderMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]
        var arpRequest: [UInt8] = []
        arpRequest += [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        arpRequest += senderMAC
        arpRequest += [0x08, 0x06]
        arpRequest += [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01]
        arpRequest += senderMAC
        arpRequest += [10, 0, 2, 15]
        arpRequest += [0, 0, 0, 0, 0, 0]
        arpRequest += [10, 0, 2, 2]

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: [0x0a, 0x80] + arpRequest))

        XCTAssertEqual(Array(response[0..<6]), senderMAC)
        XCTAssertEqual(Array(response[6..<12]), LinkLocalVirtIONetworkBackend.hostMAC)
        XCTAssertEqual(Array(response[12..<14]), [0x08, 0x06])
        XCTAssertEqual(Array(response[20..<22]), [0x00, 0x02])
        XCTAssertEqual(Array(response[28..<32]), LinkLocalVirtIONetworkBackend.hostIPv4)
    }

    func testLinkLocalNetworkBackendAnswersARPForDNSServiceAddress() throws {
        let senderMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]
        var arpRequest: [UInt8] = []
        arpRequest += [0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        arpRequest += senderMAC
        arpRequest += [0x08, 0x06]
        arpRequest += [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01]
        arpRequest += senderMAC
        arpRequest += [10, 0, 2, 15]
        arpRequest += [0, 0, 0, 0, 0, 0]
        arpRequest += LinkLocalVirtIONetworkBackend.dnsIPv4

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: arpRequest))

        XCTAssertEqual(Array(response[0..<6]), senderMAC)
        XCTAssertEqual(Array(response[6..<12]), LinkLocalVirtIONetworkBackend.hostMAC)
        XCTAssertEqual(Array(response[20..<22]), [0x00, 0x02])
        XCTAssertEqual(Array(response[28..<32]), LinkLocalVirtIONetworkBackend.dnsIPv4)
    }

    func testLinkLocalNetworkBackendAnswersDNSAQueries() throws {
        let queryName = ["dl-cdn", "alpinelinux", "org"]
        var dnsQuery: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in queryName {
            dnsQuery.append(UInt8(label.utf8.count))
            dnsQuery += Array(label.utf8)
        }
        dnsQuery += [0, 0, 1, 0, 1]

        let frame = makeIPv4UDPFrame(
            sourcePort: 49152,
            destinationIP: LinkLocalVirtIONetworkBackend.dnsIPv4,
            destinationPort: 53,
            payload: dnsQuery
        )

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: frame))
        let ipStart = 14
        let udpStart = ipStart + 20
        let dnsStart = udpStart + 8

        XCTAssertEqual(Array(response[(ipStart + 12)..<(ipStart + 16)]), LinkLocalVirtIONetworkBackend.dnsIPv4)
        XCTAssertEqual(Array(response[(ipStart + 16)..<(ipStart + 20)]), LinkLocalVirtIONetworkBackend.guestIPv4)
        XCTAssertEqual(readBE16(response, at: udpStart), 53)
        XCTAssertEqual(readBE16(response, at: udpStart + 2), 49152)
        XCTAssertEqual(readBE16(response, at: dnsStart), 0x1234)
        XCTAssertEqual(readBE16(response, at: dnsStart + 6), 1)
        XCTAssertEqual(Array(response.suffix(4)), LinkLocalVirtIONetworkBackend.hostIPv4)
    }

    func testLinkLocalNetworkBackendPreservesMultiQuestionDNSResponses() throws {
        let queryName = ["dl-cdn", "alpinelinux", "org"]
        var dnsQuery: [UInt8] = [0x22, 0x33, 0x01, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0]
        for queryType: UInt16 in [1, 28] {
            for label in queryName {
                dnsQuery.append(UInt8(label.utf8.count))
                dnsQuery += Array(label.utf8)
            }
            dnsQuery += [0]
            appendBE16(queryType, to: &dnsQuery)
            appendBE16(1, to: &dnsQuery)
        }

        let frame = makeIPv4UDPFrame(
            sourcePort: 49153,
            destinationIP: LinkLocalVirtIONetworkBackend.dnsIPv4,
            destinationPort: 53,
            payload: dnsQuery
        )

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: frame))
        let dnsStart = 14 + 20 + 8

        XCTAssertEqual(readBE16(response, at: dnsStart), 0x2233)
        XCTAssertEqual(readBE16(response, at: dnsStart + 4), 2)
        XCTAssertEqual(readBE16(response, at: dnsStart + 6), 1)
        XCTAssertEqual(Array(response.suffix(4)), LinkLocalVirtIONetworkBackend.hostIPv4)
    }

    func testLinkLocalNetworkBackendAnswersDNSAAAAQueriesWithNoData() throws {
        let queryName = ["dl-cdn", "alpinelinux", "org"]
        var dnsQuery: [UInt8] = [0x33, 0x44, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in queryName {
            dnsQuery.append(UInt8(label.utf8.count))
            dnsQuery += Array(label.utf8)
        }
        dnsQuery += [0]
        appendBE16(28, to: &dnsQuery)
        appendBE16(1, to: &dnsQuery)

        let frame = makeIPv4UDPFrame(
            sourcePort: 49154,
            destinationIP: LinkLocalVirtIONetworkBackend.dnsIPv4,
            destinationPort: 53,
            payload: dnsQuery
        )

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: frame))
        let dnsStart = 14 + 20 + 8

        XCTAssertEqual(readBE16(response, at: dnsStart), 0x3344)
        XCTAssertEqual(readBE16(response, at: dnsStart + 2) & 0x000f, 0)
        XCTAssertEqual(readBE16(response, at: dnsStart + 4), 1)
        XCTAssertEqual(readBE16(response, at: dnsStart + 6), 0)
    }

    func testLinkLocalNetworkBackendRejectsNonLocalIPv4WithICMPUnreachable() throws {
        let destinationIP: [UInt8] = [172, 217, 72, 102]
        let request = makeIPv4ICMPEchoFrame(destinationIP: destinationIP)

        let response = try XCTUnwrap(LinkLocalVirtIONetworkBackend.response(to: request))

        XCTAssertEqual(Array(response[0..<6]), [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee])
        XCTAssertEqual(Array(response[6..<12]), LinkLocalVirtIONetworkBackend.hostMAC)
        XCTAssertEqual(Array(response[12..<14]), [0x08, 0x00])
        XCTAssertEqual(Array(response[26..<30]), LinkLocalVirtIONetworkBackend.hostIPv4)
        XCTAssertEqual(Array(response[30..<34]), LinkLocalVirtIONetworkBackend.guestIPv4)
        XCTAssertEqual(response[34], 3)
        XCTAssertEqual(response[35], 1)
        XCTAssertEqual(Array(response[54..<58]), LinkLocalVirtIONetworkBackend.guestIPv4)
        XCTAssertEqual(Array(response[58..<62]), destinationIP)
    }

    func testLinkLocalNetworkBackendServesAlpineHTTPProxyOverTCP() throws {
        let requestedPath = "/alpine/edge/main/aarch64/APKINDEX.tar.gz"
        var fetchedPaths: [String] = []
        let backend = LinkLocalVirtIONetworkBackend { path in
            fetchedPaths.append(path)
            return LinkLocalHTTPResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: ["Content-Type": "application/gzip"],
                body: Array("apk-index".utf8)
            )
        }
        let sourcePort: UInt16 = 40000
        let clientInitialSequence: UInt32 = 1000

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationPort: 80,
            sequence: clientInitialSequence,
            acknowledgment: 0,
            flags: 0x02,
            payload: []
        ))
        let synAck = try XCTUnwrap(backend.receive())
        let serverInitialSequence = readBE32(synAck, at: 14 + 20 + 4)
        XCTAssertEqual(tcpFlags(synAck), 0x12)
        XCTAssertEqual(readBE32(synAck, at: 14 + 20 + 8), clientInitialSequence + 1)

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationPort: 80,
            sequence: clientInitialSequence + 1,
            acknowledgment: serverInitialSequence + 1,
            flags: 0x10,
            payload: []
        ))
        XCTAssertNil(backend.receive())

        let request = Array("GET \(requestedPath) HTTP/1.1\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n".utf8)
        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationPort: 80,
            sequence: clientInitialSequence + 1,
            acknowledgment: serverInitialSequence + 1,
            flags: 0x18,
            payload: request
        ))

        var responsePayload: [UInt8] = []
        var sawFin = false
        while let frame = backend.receive() {
            responsePayload += tcpPayload(frame)
            sawFin = sawFin || (tcpFlags(frame) & 0x01) != 0
        }

        let responseText = String(decoding: responsePayload, as: UTF8.self)
        XCTAssertEqual(fetchedPaths, [requestedPath])
        XCTAssertTrue(responseText.contains("HTTP/1.1 200 OK"), responseText)
        XCTAssertTrue(responseText.contains("Content-Type: application/gzip"), responseText)
        XCTAssertTrue(responseText.contains("apk-index"), responseText)
        XCTAssertTrue(sawFin)
    }

    func testLinkLocalNetworkBackendStreamsLargeHTTPProxyResponsesByAckWindow() throws {
        let requestedPath = "/alpine/edge/main/aarch64/APKINDEX.tar.gz"
        let largeBody = (0..<40_000).map { UInt8($0 % 251) }
        let backend = LinkLocalVirtIONetworkBackend { path in
            XCTAssertEqual(path, requestedPath)
            return LinkLocalHTTPResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: ["Content-Type": "application/gzip"],
                body: largeBody
            )
        }
        let sourcePort: UInt16 = 40001
        let clientInitialSequence: UInt32 = 2000
        let receiveWindow: UInt16 = 3000

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationPort: 80,
            sequence: clientInitialSequence,
            acknowledgment: 0,
            flags: 0x02,
            payload: [],
            window: receiveWindow
        ))
        let synAck = try XCTUnwrap(backend.receive())
        let serverInitialSequence = readBE32(synAck, at: 14 + 20 + 4)

        let request = Array("GET \(requestedPath) HTTP/1.1\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n".utf8)
        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationPort: 80,
            sequence: clientInitialSequence + 1,
            acknowledgment: serverInitialSequence + 1,
            flags: 0x18,
            payload: request,
            window: receiveWindow
        ))

        var responsePayload: [UInt8] = []
        var sawFin = false
        var burstPayload = drainTCPPayload(from: backend, sawFin: &sawFin)
        XCTAssertLessThanOrEqual(burstPayload.count, Int(receiveWindow))
        responsePayload += burstPayload

        let clientSequence = clientInitialSequence + 1 + UInt32(request.count)
        var acknowledgment = serverInitialSequence + 1 + UInt32(responsePayload.count)
        var iterations = 0
        while !sawFin, iterations < 32 {
            backend.transmit(frame: makeIPv4TCPFrame(
                sourcePort: sourcePort,
                destinationPort: 80,
                sequence: clientSequence,
                acknowledgment: acknowledgment,
                flags: 0x10,
                payload: [],
                window: receiveWindow
            ))
            burstPayload = drainTCPPayload(from: backend, sawFin: &sawFin)
            XCTAssertLessThanOrEqual(burstPayload.count, Int(receiveWindow))
            responsePayload += burstPayload
            acknowledgment = serverInitialSequence + 1 + UInt32(responsePayload.count)
            iterations += 1
        }

        XCTAssertTrue(sawFin)
        XCTAssertTrue(responsePayload.starts(with: Array("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertEqual(Array(responsePayload.suffix(largeBody.count)), largeBody)
        XCTAssertEqual(clientSequence, clientInitialSequence + 1 + UInt32(request.count))
    }

    func testLinkLocalNetworkBackendResolvesAlpineProxyHostToLocalGateway() throws {
        let factory = FakeOutboundNetworkFactory()
        factory.resolvedIPv4ByHost["dl-cdn.alpinelinux.org"] = [203, 0, 113, 10]
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)

        var dnsQuery: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in ["dl-cdn", "alpinelinux", "org"] {
            dnsQuery.append(UInt8(label.utf8.count))
            dnsQuery += Array(label.utf8)
        }
        dnsQuery += [0, 0, 1, 0, 1]

        backend.transmit(frame: makeIPv4UDPFrame(
            sourcePort: 53000,
            destinationIP: LinkLocalVirtIONetworkBackend.dnsIPv4,
            destinationPort: 53,
            payload: dnsQuery
        ))

        let response = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(Array(response.suffix(4)), LinkLocalVirtIONetworkBackend.hostIPv4)
    }

    func testLinkLocalNetworkBackendUsesOutboundResolverForNonProxyDNSAQueries() throws {
        let factory = FakeOutboundNetworkFactory()
        factory.resolvedIPv4ByHost["example.com"] = [203, 0, 113, 10]
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)

        var dnsQuery: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in ["example", "com"] {
            dnsQuery.append(UInt8(label.utf8.count))
            dnsQuery += Array(label.utf8)
        }
        dnsQuery += [0, 0, 1, 0, 1]

        backend.transmit(frame: makeIPv4UDPFrame(
            sourcePort: 53000,
            destinationIP: LinkLocalVirtIONetworkBackend.dnsIPv4,
            destinationPort: 53,
            payload: dnsQuery
        ))

        let response = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(Array(response.suffix(4)), [203, 0, 113, 10])
    }

    func testLinkLocalNetworkBackendBridgesOutboundTCPConnections() throws {
        let factory = FakeOutboundNetworkFactory()
        let connection = FakeOutboundTCPConnection()
        factory.tcpConnection = connection
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)
        let destinationIP: [UInt8] = [93, 184, 216, 34]
        let sourcePort: UInt16 = 41000
        let destinationPort: UInt16 = 443
        let clientInitialSequence: UInt32 = 1234

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort,
            sequence: clientInitialSequence,
            acknowledgment: 0,
            flags: 0x02,
            payload: []
        ))
        let synAck = try XCTUnwrap(waitForReceiveFrame(from: backend))
        let serverInitialSequence = readBE32(synAck, at: 14 + 20 + 4)
        XCTAssertEqual(tcpFlags(synAck), 0x12)
        XCTAssertEqual(factory.lastTCPDestinationIP, destinationIP)
        XCTAssertEqual(factory.lastTCPDestinationPort, destinationPort)

        let requestPayload = Array("hello".utf8)
        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort,
            sequence: clientInitialSequence + 1,
            acknowledgment: serverInitialSequence + 1,
            flags: 0x18,
            payload: requestPayload
        ))
        let ack = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(tcpFlags(ack), 0x10)
        XCTAssertEqual(readBE32(ack, at: 14 + 20 + 8), clientInitialSequence + 1 + UInt32(requestPayload.count))
        XCTAssertEqual(connection.sentPayloads, [])

        connection.fireReady()
        XCTAssertTrue(waitForCondition { connection.sentPayloads == [requestPayload] })

        let replyPayload = Array("world".utf8)
        connection.fireReceive(replyPayload)
        let reply = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(tcpPayload(reply), replyPayload)

        connection.fireClose()
        let fin = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(tcpFlags(fin) & 0x01, 0x01)
    }

    func testLinkLocalNetworkBackendSplitsOutboundTCPResponsesIntoMTUSizedFrames() throws {
        let factory = FakeOutboundNetworkFactory()
        let connection = FakeOutboundTCPConnection()
        factory.tcpConnection = connection
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)
        let destinationIP: [UInt8] = [93, 184, 216, 34]
        let sourcePort: UInt16 = 41001
        let destinationPort: UInt16 = 443
        let clientInitialSequence: UInt32 = 5678
        let receiveWindow: UInt16 = 0xffff

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort,
            sequence: clientInitialSequence,
            acknowledgment: 0,
            flags: 0x02,
            payload: [],
            window: receiveWindow
        ))
        let synAck = try XCTUnwrap(waitForReceiveFrame(from: backend))
        let serverInitialSequence = readBE32(synAck, at: 14 + 20 + 4)

        backend.transmit(frame: makeIPv4TCPFrame(
            sourcePort: sourcePort,
            destinationIP: destinationIP,
            destinationPort: destinationPort,
            sequence: clientInitialSequence + 1,
            acknowledgment: serverInitialSequence + 1,
            flags: 0x10,
            payload: [],
            window: receiveWindow
        ))
        XCTAssertNil(backend.receive())

        let replyPayload = (0..<20_000).map { UInt8($0 & 0xff) }
        let generatedFrameBaseline = backend.generatedFrameCount
        connection.fireReceive(replyPayload)
        XCTAssertTrue(waitForCondition { backend.generatedFrameCount > generatedFrameBaseline })

        var frames: [[UInt8]] = []
        while let frame = backend.receive() {
            frames.append(frame)
        }

        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertEqual(frames.flatMap(tcpPayload), replyPayload)
        XCTAssertTrue(frames.allSatisfy { tcpPayload($0).count <= 1460 })
    }

    func testLinkLocalNetworkBackendBridgesOutboundUDPDatagrams() throws {
        let factory = FakeOutboundNetworkFactory()
        factory.udpResponsePackets = [[0xde, 0xad, 0xbe, 0xef]]
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)
        let destinationIP: [UInt8] = [8, 8, 8, 8]
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04]

        backend.transmit(frame: makeIPv4UDPFrame(
            sourcePort: 53001,
            destinationIP: destinationIP,
            destinationPort: 53,
            payload: payload
        ))

        let response = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(factory.lastUDPDestinationIP, destinationIP)
        XCTAssertEqual(factory.lastUDPDestinationPort, 53)
        XCTAssertEqual(factory.lastUDPPayload, payload)
        XCTAssertEqual(readBE16(response, at: 14 + 20), 53)
        XCTAssertEqual(readBE16(response, at: 14 + 20 + 2), 53001)
        XCTAssertEqual(Array(response.suffix(4)), [0xde, 0xad, 0xbe, 0xef])
    }

    func testLinkLocalNetworkBackendBridgesOutboundICMPEcho() throws {
        let factory = FakeOutboundNetworkFactory()
        // Darwin datagram ICMP sockets may replace the caller's identifier.
        factory.icmpResponsePayload = [0, 0, 0, 0, 0xab, 0xcd, 0x99, 0x99] + Array("pong".utf8)
        let backend = LinkLocalVirtIONetworkBackend(outboundNetworkFactory: factory)
        let destinationIP: [UInt8] = [172, 217, 72, 102]

        backend.transmit(frame: makeIPv4ICMPEchoFrame(destinationIP: destinationIP, payload: Array("pong".utf8)))

        let response = try XCTUnwrap(waitForReceiveFrame(from: backend))
        XCTAssertEqual(factory.lastICMPDestinationIP, destinationIP)
        XCTAssertEqual(factory.lastICMPIdentifier, 0x1234)
        XCTAssertEqual(factory.lastICMPSequenceNumber, 0x0001)
        XCTAssertEqual(factory.lastICMPPayload, Array("pong".utf8))
        XCTAssertEqual(Array(response[26..<30]), destinationIP)
        XCTAssertEqual(Array(response[30..<34]), LinkLocalVirtIONetworkBackend.guestIPv4)
        XCTAssertEqual(response[34], 0)
        XCTAssertEqual(response[35], 0)
        XCTAssertEqual(readBE16(response, at: 38), 0x1234)
        XCTAssertEqual(readBE16(response, at: 40), 0x0001)
    }

    func testLinuxDirectBootAdapterStagesKernelInitrdFDTAndDisk() throws {
        let machine = try MachineFactory.makeResearchMachine(memorySize: 32 * 1024 * 1024, blockStorageSize: 4096)
        let kernel = [UInt8](repeating: 0x1f, count: 4096)
        let initrd = [UInt8](repeating: 0x42, count: 1024)
        let disk = [UInt8](repeating: 0xa5, count: 2048)
        let adapter = LinuxDirectBootAdapter(
            artifacts: LinuxBootArtifacts(
                kernelImage: kernel,
                initrd: initrd,
                diskImage: disk
            ),
            profile: .postmarketOS
        )

        let result = try adapter.loadWithResult(into: machine.vm)

        XCTAssertEqual(result.configuration.machineName, "arm64viz-postmarketos")
        XCTAssertEqual(machine.vm.cpu.pc, result.layout.kernelLoadAddress)
        XCTAssertEqual(machine.vm.cpu.x[0], result.layout.fdtLoadAddress)
        XCTAssertEqual(machine.vm.cpu.x[1], 0)
        XCTAssertEqual(machine.vm.cpu.pstate, ARM64PState.el1hMasked)
        XCTAssertEqual(machine.vm.cpu.currentExceptionLevel, 1)
        XCTAssertEqual(try machine.vm.memory.read8(at: result.layout.kernelLoadAddress), 0x1f)
        XCTAssertEqual(try machine.vm.memory.read8(at: try XCTUnwrap(result.layout.initrdLoadAddress)), 0x42)
        XCTAssertEqual(Array(machine.virtioBlock.storageBytes.prefix(disk.count)), disk)
        XCTAssertNil(machine.vm.interruptController.peekPending())
        XCTAssertEqual(try machine.vm.readPhysical(ARM64VizMachineLayout.virtioBlockBase + 0x060, width: .word), 0)
        XCTAssertEqual(readBE32(result.deviceTreeBlob, at: 0), FlattenedDeviceTree.magic)
        XCTAssertTrue(String(decoding: result.deviceTreeBlob, as: UTF8.self).contains("linux,initrd-start"))
        XCTAssertTrue(String(decoding: result.deviceTreeBlob, as: UTF8.self).contains("virtio,mmio"))
        XCTAssertFalse(result.layout.usedSuppliedDeviceTree)
        XCTAssertTrue(result.layout.bootArguments.contains("root=/dev/vda"))
    }

    func testInstructionTraceRecordsUnsupportedInstruction() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint

        try machine.vm.loadBinary(littleEndianWords([0xffff_ffff]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)

        XCTAssertThrowsError(try machine.vm.run(maxSteps: 1)) { error in
            guard case let VMError.unsupportedInstruction(instruction, pc) = error else {
                XCTFail("expected unsupportedInstruction, got \(error)")
                return
            }
            XCTAssertEqual(instruction, 0xffff_ffff)
            XCTAssertEqual(pc, entry)
        }

        XCTAssertEqual(machine.vm.instructionTrace, [
            InstructionTraceEntry(step: 1, pc: entry, instruction: 0xffff_ffff, decode: "unknown")
        ])
    }

    func testInstructionTraceKeepsRecentEntries() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint

        try machine.vm.loadBinary(littleEndianWords([
            0xd503_201f,
            0xd503_201f,
            0xd503_201f,
            0xd440_0000
        ]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)

        let result = try machine.vm.run(maxSteps: 10)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.instructionTrace, [
            InstructionTraceEntry(
                step: 3,
                pc: entry + 8,
                instruction: 0xd503_201f,
                decode: "nop",
                pstateAfter: 0
            ),
            InstructionTraceEntry(
                step: 4,
                pc: entry + 12,
                instruction: 0xd440_0000,
                decode: "hlt",
                pstateAfter: 0
            )
        ])
    }

    func testPCRelativeAddressingAndConditionalBranches() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodePCRelativeAddress(rd: 1, offset: 12, page: false),
            encodePCRelativeAddress(rd: 2, offset: 0x2000, page: true),
            encodeCompareBranch(rt: 3, offset: 8, nonZero: false),
            0xd440_0000,
            encodeCompareBranch(rt: 1, offset: 8, nonZero: true),
            0xd440_0000,
            encodeTestBranch(rt: 1, bit: 0, offset: 8, nonZero: false),
            0xd440_0000,
            encodeTestBranch(rt: 1, bit: 3, offset: 8, nonZero: true),
            0xd440_0000,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], entry + 12)
        XCTAssertEqual(machine.vm.cpu.x[2], (entry & ~UInt64(0xfff)) + 0x2000)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 44)
    }

    func testLoadLiteralReadsPCRelativeData() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeLoadLiteral(rt: 8, offset: 8, opcode: 1),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: entry + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[8], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldr-64-literal")
    }

    func testConditionalCompareImmediateUpdatesNZCVWhenConditionPasses() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xfa40_5a4d,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[18] = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x6000_0000)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ccmp-immediate")
    }

    func testConditionalCompareImmediateUsesFallbackNZCVWhenConditionFails() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xfa40_4a4d,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0xd000_0000)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ccmp-immediate")
    }

    func testConditionalCompareImmediateSupportsBusyBoxAllocationGuard() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf100_001f, // cmp x0, #0
            0xfa40_0a64, // ccmp x19, #0, #4, eq
            encodeConditionalBranch(offset: 12, condition: 0x0),
            0x5280_0021, // mov w1, #1
            0xd440_0000,
            0x5280_0041, // mov w1, #2
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 8)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[0] = 0
        machine.vm.cpu.x[19] = 0x20

        let result = try machine.vm.run(maxSteps: 10)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], 1)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x2000_0000)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 20)
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ccmp-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].pstateBefore, ARM64PState.el1h | 0x6000_0000)
        XCTAssertEqual(machine.vm.instructionTrace[1].pstateAfter, ARM64PState.el1h | 0x2000_0000)
    }

    func testConditionalCompareRegisterSupportsLinuxCCMPForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x7a40_3042,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[2] = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x6000_0000)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ccmp-register")
    }

    func testConditionalCompareImmediateSupportsLibfdtOffsetGuard() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let fdt = ARM64VizMachineLayout.ramBase + 0x10000
        let program = littleEndianWords([
            0xb940_0803, // ldr w3, [x0, #8]
            0x5ac0_0863, // rev w3, w3
            0x2b03_0024, // adds w4, w1, w3
            0x1a9f_37e5, // csinc w5, wzr, wzr, cc
            0x7100_003f, // subs wzr, w1, #0
            0x7a40_a8a0, // ccmp w5, #0, #0, ge
            encodeConditionalBranch(offset: 12, condition: 0x1),
            0x8b04_0006, // add x6, x0, x4
            0xd440_0000,
            0xd280_0026,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary([0x00, 0x00, 0x00, 0x38], at: fdt + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 12)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[0] = fdt
        machine.vm.cpu.x[1] = 0
        machine.vm.cpu.x[2] = 4

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x38)
        XCTAssertEqual(machine.vm.cpu.x[4], 0x38)
        XCTAssertEqual(machine.vm.cpu.x[5], 0)
        XCTAssertEqual(machine.vm.cpu.x[6], fdt + 0x38)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x6000_0000)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 36)
        XCTAssertEqual(machine.vm.instructionTrace[5].decode, "ccmp-immediate")
    }

    func testAddSubImmediateWithFlagsSupportsLinuxCompareAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf100_227f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[19] = 8

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[19], 8)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x6000_0000)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "subs-immediate")
    }

    func testAddSubtractWithCarrySupportsLinuxSBCForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x5a1f_01aa, // sbc w10, w13, wzr
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[10] = UInt64.max
        machine.vm.cpu.x[13] = 0x20

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[10], 0x1f)
        XCTAssertEqual(machine.vm.cpu.x[13], 0x20)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "sbc")
    }

    func testAddSubtractWithCarryUpdatesNZCVForADCS() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeAddSubtractWithCarry(rd: 0, rn: 1, rm: 2, bits: 64, subtract: false, setFlags: true),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h | 0x2000_0000
        machine.vm.cpu.x[1] = UInt64.max
        machine.vm.cpu.x[2] = 0

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x6000_0000)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "adcs")
    }

    func testConditionalBranchUsesNZCVConditionCodes() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeConditionalBranch(offset: 8, condition: 0x1),
            0xd440_0000,
            encodeConditionalBranch(offset: 8, condition: 0x0),
            0xd440_0000,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.pstate = ARM64PState.el1h

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 16)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "b.cond")
    }

    func testTestBitBranchHandlesHighBitOfZeroRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        try machine.vm.loadBinary(littleEndianWords([0xb6eb_fa7f]), at: entry)
        machine.vm.reset(entryPoint: entry)

        let result = try machine.vm.run(maxSteps: 1)

        XCTAssertEqual(result.stopReason, .maxSteps(1))
        XCTAssertEqual(machine.vm.cpu.pc, entry + 32_588)
    }

    func testLogicalImmediateWithFlagsSupportsLinuxTSTAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf27e_027f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.cpu.x[19] = 0x4

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[19], 0x4)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf, ARM64PState.el1h)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ands-immediate")
    }

    func testConditionalSelectSupportsLinuxCSELForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9a93_03f3,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.pstate = ARM64PState.el1h | 0x4000_0000
        machine.vm.cpu.x[19] = 0x1234

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[19], 0)
        XCTAssertEqual(machine.vm.cpu.pstate & 0xf000_0000, 0x4000_0000)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "csel")
    }

    func testLogicalShiftedRegisterSupportsLinuxMOVAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xaa00_03f5,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[0] = 0x47f0_0000

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[21], 0x47f0_0000)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "mov-register")
    }

    func testHintInstructionActsAsNoOp() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd503_245f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "hint")
    }

    func testWaitForEventActsAsNoOpAndIsTraced() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd503_205f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "wfe")
        XCTAssertEqual(machine.vm.waitForEventCount, 1)
        XCTAssertEqual(machine.vm.waitForInterruptCount, 0)
    }

    func testWaitForInterruptFastForwardsToVirtualTimerDeadline() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let program = littleEndianWords([
            0xd503_207f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.cntvctEL0),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.pstate = ARM64PState.el1h
        machine.vm.interruptController.setEnabled(line: VirtualMachine.virtualTimerIRQ, enabled: true)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 1_000, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntvCtlEL0, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, irqVector + 8)
        XCTAssertGreaterThanOrEqual(machine.vm.cpu.x[0], 1_000)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "wfi")
        XCTAssertEqual(machine.vm.waitForInterruptCount, 1)
        XCTAssertEqual(machine.vm.waitForEventCount, 0)
        XCTAssertEqual(machine.vm.timerFastForwardCount, 1)
        XCTAssertEqual(machine.vm.timerFastForwardCycles, 1_000)
    }

    func testMaskedWaitForInterruptFastForwardsTimerWithoutRoutingIRQ() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let program = littleEndianWords([
            0xd503_207f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.cntvctEL0),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.interruptController.setEnabled(line: VirtualMachine.virtualTimerIRQ, enabled: true)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 1_000, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntvCtlEL0, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.interruptController.peekPending(), VirtualMachine.virtualTimerIRQ)
        XCTAssertEqual(machine.vm.waitForInterruptCount, 1)
        XCTAssertEqual(machine.vm.timerFastForwardCount, 1)
        XCTAssertEqual(machine.vm.timerFastForwardCycles, 1_000)
    }

    func testPrefetchUnsignedImmediateActsAsNoOp() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf980_01f1,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[15] = entry + 0x100

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[15], entry + 0x100)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "prfm-unsigned-immediate")
    }

    func testPrefetchRegisterOffsetActsAsNoOp() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf8a0_6850,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[0] = 0x70
        machine.vm.cpu.x[2] = entry + 0x100
        machine.vm.cpu.x[16] = 0x1234

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x70)
        XCTAssertEqual(machine.vm.cpu.x[2], entry + 0x100)
        XCTAssertEqual(machine.vm.cpu.x[16], 0x1234)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "prfm-register-offset")
    }

    func testUnsignedBitfieldMoveSupportsLinuxCTRExtract() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd350_4c63,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[3] = 0x8444_c004

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x4)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ubfm")
    }

    func testVariableShiftSupportsLinuxLSLVForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9ac3_2042,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[2] = 4
        machine.vm.cpu.x[3] = 4

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 64)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "lslv")
    }

    func testDivideTwoSourceInstructionsSupportLinuxSDIVForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1ad8_0c01,
            0x9ac4_0862,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.x[0] = UInt64(UInt32(bitPattern: -29))
        machine.vm.cpu.x[24] = 5
        machine.vm.cpu.x[3] = 100
        machine.vm.cpu.x[4] = 9

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], UInt64(UInt32(bitPattern: -5)))
        XCTAssertEqual(machine.vm.cpu.x[2], 11)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "sdiv")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "udiv")
    }

    func testAddSubShiftedRegisterSupportsLinuxADDForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x8b02_0000,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[0] = 0x1000
        machine.vm.cpu.x[2] = 0x40

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1040)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "add-shifted-register")
    }

    func testAddSubExtendedRegisterSupportsLinuxSXTWForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x8b35_c275,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[19] = 0x1000
        machine.vm.cpu.x[21] = 0xffff_fffc

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[21], 0xffc)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "add-extended-register")
    }

    func testMoveWideSupports32BitMOVZForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x5280_0007,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[7] = UInt64.max

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[7], 0)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "movz")
    }

    func testMultiplyAddSubtractSupportsLinuxMULAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1b02_7ca2,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[2] = 7
        machine.vm.cpu.x[5] = 3

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 21)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "mul")
    }

    func testUnsignedMultiplyLongSupportsLinuxUMULLAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9bb8_7eb5,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[21] = 0xffff_ffff
        machine.vm.cpu.x[24] = 3

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[21], 0x2_ffff_fffd)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "umull")
    }

    func testMultiplyHighSupportsLinuxTimestampMath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9bc1_7c42,
            0x9b45_7c83,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.x[1] = 2
        machine.vm.cpu.x[2] = UInt64.max
        machine.vm.cpu.x[4] = UInt64(bitPattern: Int64(-2))
        machine.vm.cpu.x[5] = 3

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 1)
        XCTAssertEqual(machine.vm.cpu.x[3], UInt64.max)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "umulh")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "smulh")
    }

    func testDataProcessingOneSourceSupportsLinuxREVAndCLZForms() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xdac0_0c84,
            0xdac0_10a6,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[4] = 0x0123_4567_89ab_cdef
        machine.vm.cpu.x[5] = 0x10

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[4], 0xefcd_ab89_6745_2301)
        XCTAssertEqual(machine.vm.cpu.x[6], 59)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "rev")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "clz")
    }

    func testBranchLinkRegisterSetsReturnAddress() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let target = entry + 0x20
        let program = littleEndianWords([
            encodeRegisterBranch(base: 0xd63f_0000, rn: 2),
            0xd440_0000
        ])
        let targetProgram = littleEndianWords([
            encodeRegisterBranch(base: 0xd65f_0000, rn: 30)
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(targetProgram, at: target)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.x[2] = target

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[30], entry + 4)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "blr")
    }

    func testBitfieldMoveSupportsLinuxBFIForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xb360_08b0,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[5] = 0x5
        machine.vm.cpu.x[16] = 0xaaaa

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[16], 0x5_0000_aaaa)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "bfm")
    }

    func testNativeBackendExecutesMuslUnsignedIntToBinary128Sequence() throws {
        let machine = try MachineFactory.makeResearchMachine(backend: SoftwareARM64Backend())
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x3400_0200, // cbz w0, zero
            0x2a00_03e0, // mov w0, w0
            0xd280_0003, // mov x3, #0
            0xdac0_1002, // clz x2, x0
            0x5100_3c41, // sub w1, w2, #15
            0x9ac1_2000, // lsl x0, x0, x1
            0x9240_bc00, // and x0, x0, #0xffffffffffff
            0x5288_07c1, // mov w1, #0x403e
            0x4b02_0021, // sub w1, w1, w2
            0x1200_3821, // and w1, w1, #0x7fff
            0xb340_bc03, // bfxil x3, x0, #0, #48
            0xd280_0002, // mov x2, #0
            0x9e67_0040, // fmov d0, x2
            0xb350_3c23, // bfi x3, x1, #48, #16
            0x9eaf_0060, // fmov v0.d[1], x3
            0xd440_0000  // hlt #0
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[0] = 1_000_000_000

        let result = try machine.vm.run(maxSteps: 32)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[0].low, 0)
        XCTAssertEqual(machine.vm.cpu.v[0].high, 0x401c_dcd6_5000_0000)
    }


    func testExtractRegisterSupportsLinuxRORImmediateAlias() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x93d7_fef7,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[23] = 0x8000_0000_0000_0001

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[23], 0x3)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ror-immediate")
    }

    func testPairStorePreIndexSupportsLinuxSTPWritebackForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xa984_1d07,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[7] = 0xfeed_face_cafe_beef
        machine.vm.cpu.x[8] = dataBase - 0x40

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[8], dataBase)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase), 0xfeed_face_cafe_beef)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 8), 0xfeed_face_cafe_beef)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "stp-64-pre-index")
    }

    func testPairStore32SignedOffsetSupportsLinuxStackFrameForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0x2908_7fe1,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.sp = dataBase
        machine.vm.cpu.x[1] = 0xffff_ffff_1122_3344

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.sp, dataBase)
        XCTAssertEqual(try machine.vm.memory.read32(at: dataBase + 64), 0x1122_3344)
        XCTAssertEqual(try machine.vm.memory.read32(at: dataBase + 68), 0)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "stp-32-signed-offset")
    }

    func testPairLoadPostIndexWritesBackBaseRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            encodePairTransfer(base: 0xa8c0_0000, rt: 0, rt2: 1, rn: 4, offsetBytes: 16),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase)
        try machine.vm.memory.write64(0x8877_6655_4433_2211, at: dataBase + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[4] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[1], 0x8877_6655_4433_2211)
        XCTAssertEqual(machine.vm.cpu.x[4], dataBase + 16)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldp-64-post-index")
    }

    func testPairSignedWordLoadSignExtendsLinuxLDPSWForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0x6940_0325,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0x8000_0001, at: dataBase)
        try machine.vm.memory.write32(0x7fff_ffff, at: dataBase + 4)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[25] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[5], 0xffff_ffff_8000_0001)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x7fff_ffff)
        XCTAssertEqual(machine.vm.cpu.x[25], dataBase)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldpsw-signed-offset")
    }

    func testUnsignedImmediateHalfwordAndWordTransfers() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xb940_0000,
            encodeUnsignedImmediateTransfer(base: 0x7900_0000, rt: 1, rn: 2, offsetBytes: 2, scale: 2),
            encodeUnsignedImmediateTransfer(base: 0x7940_0000, rt: 3, rn: 2, offsetBytes: 2, scale: 2),
            encodeUnsignedImmediateTransfer(base: 0xb900_0000, rt: 1, rn: 2, offsetBytes: 4, scale: 4),
            encodeUnsignedImmediateTransfer(base: 0xb940_0000, rt: 4, rn: 2, offsetBytes: 4, scale: 4),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0xd00d_feed, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 6)
        machine.vm.cpu.x[0] = dataBase
        machine.vm.cpu.x[1] = 0xffff_1234_abcd
        machine.vm.cpu.x[2] = dataBase

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0xd00d_feed)
        XCTAssertEqual(machine.vm.cpu.x[3], 0xabcd)
        XCTAssertEqual(machine.vm.cpu.x[4], 0x1234_abcd)
        XCTAssertEqual(try machine.vm.memory.read16(at: dataBase + 2), 0xabcd)
        XCTAssertEqual(try machine.vm.memory.read32(at: dataBase + 4), 0x1234_abcd)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 24)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ldr-32-unsigned-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "strh-unsigned-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "ldrh-unsigned-immediate")
    }

    func testSignedWordUnsignedImmediateLoadSupportsLinuxLDRSWForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xb980_9ea0,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0x8000_0001, at: dataBase + 0x9c)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[21] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0xffff_ffff_8000_0001)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldrsw-unsigned-immediate")
    }

    func testSignedImmediateByteLoadPostIndexWritesBackBaseRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0x3840_1406,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write8(0x2f, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[0] = dataBase
        machine.vm.cpu.x[6] = UInt64.max

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], dataBase + 1)
        XCTAssertEqual(machine.vm.cpu.x[6], 0x2f)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldrb-post-index")
    }

    func testSignedImmediateSignedWordLoadSupportsLinuxLDURSWForm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xb89c_43a1,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write32(0x8000_0001, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[29] = dataBase + 0x3c

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], 0xffff_ffff_8000_0001)
        XCTAssertEqual(machine.vm.cpu.x[29], dataBase + 0x3c)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldrsw-unscaled-immediate")
    }

    func testRegisterOffsetLoadUsesScaledIndexRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xf862_78c7,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase + 24)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[6] = dataBase
        machine.vm.cpu.x[2] = 3

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[6], dataBase)
        XCTAssertEqual(machine.vm.cpu.x[7], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldr-64-register-offset")
    }

    func testExclusiveLoadSupportsLinuxLDXR64Form() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc85f_7de0,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[15] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.exclusiveReservationAddress, dataBase)
        XCTAssertEqual(machine.vm.cpu.exclusiveReservationSize, 8)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldxr-64")
    }

    func testExclusivePairLoadSupportsLinuxLDXP64Form() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc87f_0262,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase)
        try machine.vm.memory.write64(0x99aa_bbcc_ddee_ff00, at: dataBase + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[19] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x99aa_bbcc_ddee_ff00)
        XCTAssertEqual(machine.vm.cpu.exclusiveReservationAddress, dataBase)
        XCTAssertEqual(machine.vm.cpu.exclusiveReservationSize, 16)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldxp-64")
    }

    func testExclusiveStoreSucceedsWhenReservationMatches() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc85f_7c20,
            0xc802_7c23,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1111_2222_3333_4444, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[1] = dataBase
        machine.vm.cpu.x[3] = 0xaaaa_bbbb_cccc_dddd

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1111_2222_3333_4444)
        XCTAssertEqual(machine.vm.cpu.x[2], 0)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase), 0xaaaa_bbbb_cccc_dddd)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationAddress)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationSize)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ldxr-64")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "stxr-64")
    }

    func testExclusivePairStoreSucceedsWhenReservationMatches() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc87f_0262,
            0xc821_1664,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1111_2222_3333_4444, at: dataBase)
        try machine.vm.memory.write64(0x5555_6666_7777_8888, at: dataBase + 8)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[19] = dataBase
        machine.vm.cpu.x[4] = 0xaaaa_bbbb_cccc_dddd
        machine.vm.cpu.x[5] = 0xeeee_ffff_0000_1111

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], 0)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase), 0xaaaa_bbbb_cccc_dddd)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 8), 0xeeee_ffff_0000_1111)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationAddress)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationSize)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ldxp-64")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "stxp-64")
    }

    func testClearExclusiveMakesExclusiveStoreFail() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc85f_7c20,
            0xd503_305f,
            0xc802_7c23,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1111_2222_3333_4444, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.x[1] = dataBase
        machine.vm.cpu.x[3] = 0xaaaa_bbbb_cccc_dddd

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 1)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase), 0x1111_2222_3333_4444)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationAddress)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationSize)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 16)
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "clrex")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "stxr-64")
    }

    func testAcquireLoadAndReleaseStoreUseNormalMemoryAccesses() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xc8df_fc15,
            0xc89f_fc41,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[0] = dataBase
        machine.vm.cpu.x[1] = 0xaaaa_bbbb_cccc_dddd
        machine.vm.cpu.x[2] = dataBase + 8
        machine.vm.cpu.exclusiveReservationAddress = dataBase
        machine.vm.cpu.exclusiveReservationSize = 8

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[21], 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 8), 0xaaaa_bbbb_cccc_dddd)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationAddress)
        XCTAssertNil(machine.vm.cpu.exclusiveReservationSize)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ldar-64")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "stlr-64")
    }

    func testUnprivilegedSignedImmediateLoadUsesSignedOffset() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            0xf842_78c7,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x8877_6655_4433_2211, at: dataBase + 39)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[6] = dataBase

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[6], dataBase)
        XCTAssertEqual(machine.vm.cpu.x[7], 0x8877_6655_4433_2211)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "ldr-64-unprivileged")
    }

    func testPairLoadStoreRegisterBranchesBarriersAndSPArithmetic() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x100
        let program = littleEndianWords([
            encodeAddSubImmediate(rd: 31, rn: 31, immediate: 16, subtract: false),
            encodeAddSubImmediate(rd: 31, rn: 31, immediate: 8, subtract: true),
            encodePairTransfer(base: 0xa900_0000, rt: 0, rt2: 1, rn: 5, offsetBytes: -16),
            encodePairTransfer(base: 0xa940_0000, rt: 2, rt2: 3, rn: 5, offsetBytes: -16),
            0xd503_3f9f,
            0xd503_3fbf,
            0xd503_3fdf,
            encodeRegisterBranch(base: 0xd61f_0000, rn: 6),
            0xd440_0000,
            encodeRegisterBranch(base: 0xd65f_0000, rn: 30),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.sp = dataBase
        machine.vm.cpu.x[0] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[1] = 0x8877_6655_4433_2211
        machine.vm.cpu.x[5] = dataBase
        machine.vm.cpu.x[6] = entry + 36
        machine.vm.cpu.x[30] = entry + 40

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.sp, dataBase + 8)
        XCTAssertEqual(machine.vm.cpu.x[2], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x8877_6655_4433_2211)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase - 16), 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase - 8), 0x8877_6655_4433_2211)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 44)
    }

    func testNonTemporalPairLoadStoreUsesOffsetAddressing() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x400
        let program = littleEndianWords([
            encodePairTransfer(base: 0xa800_0000, rt: 2, rt2: 3, rn: 0, offsetBytes: -256),
            encodePairTransfer(base: 0xa840_0000, rt: 4, rt2: 5, rn: 0, offsetBytes: -256),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[0] = dataBase
        machine.vm.cpu.x[2] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[3] = 0x8877_6655_4433_2211

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], dataBase)
        XCTAssertEqual(machine.vm.cpu.x[4], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.x[5], 0x8877_6655_4433_2211)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase - 256), 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase - 248), 0x8877_6655_4433_2211)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 12)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "stnp-64")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ldnp-64")
    }

    func testSystemRegisterReadWriteAndPStateImmediateInstructions() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.currentEL),
            encodeMRS(rt: 1, key: ARM64SystemRegister.midrEL1),
            encodeMSR(rt: 2, key: ARM64SystemRegister.sctlrEL1),
            encodeMRS(rt: 3, key: ARM64SystemRegister.sctlrEL1),
            encodeMSR(rt: 4, key: ARM64SystemRegister.daif),
            encodeMRS(rt: 5, key: ARM64SystemRegister.daif),
            encodeDAIFImmediate(mask: 0xf, set: false),
            encodeMRS(rt: 6, key: ARM64SystemRegister.daif),
            encodeDAIFImmediate(mask: 0xa, set: true),
            encodeMRS(rt: 7, key: ARM64SystemRegister.daif),
            encodeMRS(rt: 8, key: ARM64SystemRegister.cntfrqEL0),
            encodeMRS(rt: 9, key: ARM64SystemRegister.cntpctEL0),
            encodeMRS(rt: 10, key: ARM64SystemRegister.dczidEL0),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 16)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.cpu.x[2] = 0x1004
        machine.vm.cpu.x[4] = 0x280

        let result = try machine.vm.run(maxSteps: 20)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x4)
        XCTAssertEqual(machine.vm.cpu.x[1], 0x410f_d034)
        XCTAssertEqual(machine.vm.cpu.x[3], 0x1004)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.sctlrEL1), 0x1004)
        XCTAssertEqual(machine.vm.cpu.x[5], 0x280)
        XCTAssertEqual(machine.vm.cpu.x[6], 0)
        XCTAssertEqual(machine.vm.cpu.x[7], 0x280)
        XCTAssertEqual(machine.vm.cpu.x[8], 24_000_000)
        XCTAssertGreaterThan(machine.vm.cpu.x[9], 0)
        XCTAssertEqual(machine.vm.cpu.x[10], 0x4)
        XCTAssertEqual(machine.vm.systemRegisterTrace.count, 2)
        XCTAssertEqual(machine.vm.systemRegisterTrace[0].step, 3)
        XCTAssertEqual(machine.vm.systemRegisterTrace[0].pc, entry + 8)
        XCTAssertEqual(machine.vm.systemRegisterTrace[0].register, "SCTLR_EL1")
        XCTAssertEqual(machine.vm.systemRegisterTrace[0].previousValue, 0)
        XCTAssertEqual(machine.vm.systemRegisterTrace[0].newValue, 0x1004)
        XCTAssertEqual(machine.vm.systemRegisterTrace[1].step, 5)
        XCTAssertEqual(machine.vm.systemRegisterTrace[1].pc, entry + 16)
        XCTAssertEqual(machine.vm.systemRegisterTrace[1].register, "DAIF")
        XCTAssertEqual(machine.vm.systemRegisterTrace[1].previousValue, ARM64PState.el1hMasked & 0x3c0)
        XCTAssertEqual(machine.vm.systemRegisterTrace[1].newValue, 0x280)
    }

    func testDataCacheZeroByVAZerosConfiguredBlock() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = (entry + 0x1000) & ~UInt64(0x3f)
        let program = littleEndianWords([
            encodeSYS(op1: 3, crn: 7, crm: 4, op2: 1, rt: 0),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary([UInt8](repeating: 0xcc, count: 64), at: dataBase)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[0] = dataBase + 17

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        for offset in stride(from: 0, to: 64, by: 8) {
            XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + UInt64(offset)), 0)
        }
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "dc-zva")
    }

    func testSIMDDuplicateGeneralReplicatesScalarRegisterElements() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            encodeSIMDDuplicateGeneral(rd: 0, rn: 1, imm5: 0x1, q: true),
            encodeSIMDDuplicateGeneral(rd: 2, rn: 3, imm5: 0x2, q: false),
            encodeSIMDDuplicateGeneral(rd: 4, rn: 5, imm5: 0x4, q: true),
            encodeSIMDDuplicateGeneral(rd: 6, rn: 7, imm5: 0x8, q: true),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.x[1] = 0xfedc_ba98_7654_32ab
        machine.vm.cpu.x[3] = 0xfedc_ba98_7654_1234
        machine.vm.cpu.x[5] = 0xffff_ffff_dead_beef
        machine.vm.cpu.x[7] = 0x1122_3344_5566_7788

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: 0xabab_abab_abab_abab, high: 0xabab_abab_abab_abab))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: 0x1234_1234_1234_1234, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[4], ARM64VectorRegister(low: 0xdead_beef_dead_beef, high: 0xdead_beef_dead_beef))
        XCTAssertEqual(machine.vm.cpu.v[6], ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0x1122_3344_5566_7788))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "dup-vector-general")
    }

    func testSIMDMoveVectorElementToGeneralCopiesLowDWord() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4e08_3c01,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.x[1] = 0
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0x99aa_bbcc_ddee_ff00)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[1], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "mov-vector-element-to-general")
    }

    func testFPScalarGeneralMovesCopyBitsWithoutArithmetic() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e27_007f,
            0x1e26_03e4,
            0x9e67_007e,
            0x9e66_03c5,
            0x9eaf_0060,
            0x9eae_0006,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 7)
        machine.vm.cpu.x[3] = 0x1122_3344_5566_7788
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: 0x0123_4567_89ab_cdef, high: 0)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0x5566_7788, high: 0))
        XCTAssertEqual(machine.vm.cpu.x[4], 0x5566_7788)
        XCTAssertEqual(machine.vm.cpu.v[30], ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0))
        XCTAssertEqual(machine.vm.cpu.x[5], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: 0x0123_4567_89ab_cdef, high: 0x1122_3344_5566_7788))
        XCTAssertEqual(machine.vm.cpu.x[6], 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fmov-general-to-single")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fmov-single-to-general")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "fmov-general-to-double")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "fmov-double-to-general")
        XCTAssertEqual(machine.vm.instructionTrace[4].decode, "fmov-general-to-vector-high-double")
        XCTAssertEqual(machine.vm.instructionTrace[5].decode, "fmov-vector-high-double-to-general")
    }

    func testFPScalarRegisterMovesCopyScalarBits() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e60_41e0,
            0x1e20_4062,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.v[15] = ARM64VectorRegister(low: Double(12.5).bitPattern, high: 0xffff)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: UInt64(Float(-2.25).bitPattern), high: 0xffff)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: Double(12.5).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: UInt64(Float(-2.25).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fmov-double")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fmov-single")
    }

    func testFPScalarImmediateMovesExpandEntireEncoding() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e2e_101e, // fmov s30, #1.0
            0x1e70_1007, // fmov d7, #-2.0
            0x1e2c_1001, // fmov s1, #0.5
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[30], ARM64VectorRegister(low: UInt64(Float(1).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.cpu.v[7], ARM64VectorRegister(low: Double(-2).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[1], ARM64VectorRegister(low: UInt64(Float(0.5).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fmov-single-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fmov-double-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "fmov-single-immediate")
    }

    func testFPIntegerToScalarFPConversionsSupportBusyBoxLibc() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x9e63_0000,
            0x1e62_0021,
            0x1e22_0062,
            0x9e23_0083,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.x[0] = 42
        machine.vm.cpu.x[1] = UInt64(UInt32(bitPattern: -7))
        machine.vm.cpu.x[3] = UInt64(UInt32(bitPattern: -3))
        machine.vm.cpu.x[4] = 65_537

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: Double(42).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[1], ARM64VectorRegister(low: Double(-7).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: UInt64(Float(-3).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.cpu.v[3], ARM64VectorRegister(low: UInt64(Float(65_537).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ucvtf-general-to-double")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "scvtf-general-to-double")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "scvtf-general-to-single")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "ucvtf-general-to-single")
    }

    func testFPScalarAddSupportsBusyBoxLibcFormattingPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e60_29ef,
            0x1e21_2862,
            0x1e7f_3800,
            0x1e24_3865,
            0x1e7f_0806,
            0x1e24_0867,
            0x1e7e_1800,
            0x1e23_1822,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 9)
        machine.vm.cpu.v[15] = ARM64VectorRegister(low: Double(1.25).bitPattern, high: 0)
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: Double(2.5).bitPattern, high: 0)
        machine.vm.cpu.v[1] = ARM64VectorRegister(low: UInt64(Float(4.5).bitPattern), high: 0)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: UInt64(Float(2.5).bitPattern), high: 0)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: UInt64(Float(10.0).bitPattern), high: 0)
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: Double(3.75).bitPattern, high: 0)
        machine.vm.cpu.v[30] = ARM64VectorRegister(low: Double(0.5).bitPattern, high: 0)

        let result = try machine.vm.run(maxSteps: 10)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[5], ARM64VectorRegister(low: UInt64(Float(-7.5).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.cpu.v[6], ARM64VectorRegister(low: Double(-4.6875).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[7], ARM64VectorRegister(low: UInt64(Float(25.0).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: Double(-2.5).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: UInt64(Float(1.8).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fadd-double")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fadd-single")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "fsub-double")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "fsub-single")
        XCTAssertEqual(machine.vm.instructionTrace[4].decode, "fmul-double")
        XCTAssertEqual(machine.vm.instructionTrace[5].decode, "fmul-single")
        XCTAssertEqual(machine.vm.instructionTrace[6].decode, "fdiv-double")
        XCTAssertEqual(machine.vm.instructionTrace[7].decode, "fdiv-single")
    }

    func testFPScalarCompareZeroSetsNZCVForBranches() throws {
        func runCompare(
            instruction: UInt32,
            vectorLow: UInt64,
            otherVectorLow: UInt64 = 0
        ) throws -> (flags: UInt64, decode: String) {
            let machine = try MachineFactory.makeResearchMachine()
            let entry = ARM64VizMachineLayout.toyEntryPoint
            let program = littleEndianWords([instruction, 0xd440_0000])

            try machine.vm.loadBinary(program, at: entry)
            machine.vm.reset(entryPoint: entry)
            machine.vm.enableInstructionTrace(capacity: 2)
            machine.vm.cpu.v[0] = ARM64VectorRegister(low: vectorLow, high: 0)
            machine.vm.cpu.v[31] = ARM64VectorRegister(low: otherVectorLow, high: 0)

            let result = try machine.vm.run(maxSteps: 4)

            XCTAssertEqual(result.stopReason, .halted)
            return (machine.vm.cpu.pstate & 0xf000_0000, machine.vm.instructionTrace[0].decode)
        }

        let less = try runCompare(instruction: 0x1e60_2018, vectorLow: Double(-1).bitPattern)
        let equal = try runCompare(instruction: 0x1e60_2018, vectorLow: Double(0).bitPattern)
        let greater = try runCompare(instruction: 0x1e60_2018, vectorLow: Double(1).bitPattern)
        let unordered = try runCompare(instruction: 0x1e20_2018, vectorLow: UInt64(Float.nan.bitPattern))
        let registerGreater = try runCompare(
            instruction: 0x1e7f_2010,
            vectorLow: Double(5).bitPattern,
            otherVectorLow: Double(4).bitPattern
        )

        XCTAssertEqual(less.flags, 0x8000_0000)
        XCTAssertEqual(equal.flags, 0x6000_0000)
        XCTAssertEqual(greater.flags, 0x2000_0000)
        XCTAssertEqual(unordered.flags, 0x3000_0000)
        XCTAssertEqual(registerGreater.flags, 0x2000_0000)
        XCTAssertEqual(less.decode, "fcmpe-double-zero")
        XCTAssertEqual(unordered.decode, "fcmpe-single-zero")
        XCTAssertEqual(registerGreater.decode, "fcmpe-double")
    }

    func testFPScalarConditionalSelectSupportsBusyBoxPingPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e60_cfff,
            0x1e24_0c62,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.pstate = (machine.vm.cpu.pstate & ~0xf000_0000) | 0x2000_0000
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: Double(7).bitPattern, high: 0xffff)
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: Double(3).bitPattern, high: 0xffff)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: UInt64(Float(11).bitPattern), high: 0xffff)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: UInt64(Float(13).bitPattern), high: 0xffff)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(Double(bitPattern: machine.vm.cpu.v[31].low), 7)
        XCTAssertEqual(Float(bitPattern: UInt32(truncatingIfNeeded: machine.vm.cpu.v[2].low)), 13)
        XCTAssertEqual(machine.vm.cpu.v[2].high, 0)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fcsel-double")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fcsel-single")
    }

    func testFPScalarConvertToSignedIntegerRoundsTowardZero() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x5ee1_b81f,
            0x5ea1_b883,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: Double(-42.75).bitPattern, high: 0)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: UInt64(Float(123.875).bitPattern), high: 0)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: UInt64(bitPattern: -42), high: 0))
        XCTAssertEqual(machine.vm.cpu.v[3], ARM64VectorRegister(low: 123, high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fcvtzs-double-to-signed")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fcvtzs-single-to-signed")
    }

    func testFPScalarConvertToSignedGeneralIntegerSupportsCagePath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e78_03c0, // fcvtzs w0, d30
            0x9e78_03c1, // fcvtzs x1, d30
            0x1e38_0062, // fcvtzs w2, s3
            0x9e38_00a4, // fcvtzs x4, s5
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.v[30] = ARM64VectorRegister(low: Double(-42.75).bitPattern, high: 0)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: UInt64(Float(-17.5).bitPattern), high: 0)
        machine.vm.cpu.v[5] = ARM64VectorRegister(low: UInt64(Float(19.75).bitPattern), high: 0)
        let backend = try XCTUnwrap(machine.vm.backend as? SoftwareARM64Backend)
        backend.fallbackInterpreterPolicy = .nativeOnly

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], UInt64(UInt32(bitPattern: -42)))
        XCTAssertEqual(machine.vm.cpu.x[1], UInt64(bitPattern: -42))
        XCTAssertEqual(machine.vm.cpu.x[2], UInt64(UInt32(bitPattern: -17)))
        XCTAssertEqual(machine.vm.cpu.x[4], 19)
        XCTAssertEqual(backend.performanceSnapshot().swiftFallbackSingleInstructionSteps, 0)
    }

    func testFPScalarConvertToUnsignedIntegerRegisterSupportsBusyBoxPingPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x1e79_03e0,
            0x9e79_0041,
            0x1e39_0083,
            0x9e39_00c5,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: Double(42.75).bitPattern, high: 0)
        machine.vm.cpu.v[2] = ARM64VectorRegister(low: Double(123_456.875).bitPattern, high: 0)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: UInt64(Float(17.5).bitPattern), high: 0)
        machine.vm.cpu.v[6] = ARM64VectorRegister(low: UInt64(Float(19.75).bitPattern), high: 0)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 42)
        XCTAssertEqual(machine.vm.cpu.x[1], 123_456)
        XCTAssertEqual(machine.vm.cpu.x[3], 17)
        XCTAssertEqual(machine.vm.cpu.x[5], 19)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "fcvtzu-double-to-unsigned32")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "fcvtzu-double-to-unsigned64")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "fcvtzu-single-to-unsigned32")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "fcvtzu-single-to-unsigned64")
    }

    func testSIMDScalarSignedIntegerToFPConvertsScalarRegisterBits() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x5e61_dbff,
            0x5e21_d883,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: UInt64(bitPattern: -42), high: 0)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: UInt64(UInt32(bitPattern: -123)), high: 0)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: Double(-42).bitPattern, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[3], ARM64VectorRegister(low: UInt64(Float(-123).bitPattern), high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "scvtf-signed-to-double")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "scvtf-signed-to-single")
    }

    func testSIMDUnsignedMaxPairwiseSupportsCageStartupPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        try machine.vm.loadBinary(littleEndianWords([
            0x6ebf_a7ff, // umaxp v31.4s, v31.4s, v31.4s
            0xd440_0000
        ]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.v[31] = ARM64VectorRegister(
            low: 0x0000_0009_0000_0001,
            high: 0x0000_0007_0000_0003
        )

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(
            low: 0x0000_0007_0000_0009,
            high: 0x0000_0007_0000_0009
        ))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "umaxp-vector")
    }

    func testSIMDScalarPairwiseAddSupportsSettingsPathWithoutFallback() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        try machine.vm.loadBinary(littleEndianWords([
            0x5ef1_bbbf, // addp d31, v29.2d
            0xd440_0000
        ]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.v[29] = ARM64VectorRegister(low: UInt64.max - 2, high: 8)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 5, high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "addp-scalar-2d")
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testSIMDMoveImmediateWordSupportsCageStartupPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        try machine.vm.loadBinary(littleEndianWords([
            0x4f00_043e, // movi v30.4s, #1
            0x0f00_265d, // movi v29.2s, #0x12, lsl #8
            0x4f00_465c, // movi v28.4s, #0x12, lsl #16
            0x4f00_665b, // movi v27.4s, #0x12, lsl #24
            0xd440_0000
        ]), at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[30], ARM64VectorRegister(
            low: 0x0000_0001_0000_0001,
            high: 0x0000_0001_0000_0001
        ))
        XCTAssertEqual(machine.vm.cpu.v[29], ARM64VectorRegister(
            low: 0x0000_1200_0000_1200,
            high: 0
        ))
        XCTAssertEqual(machine.vm.cpu.v[28], ARM64VectorRegister(
            low: 0x0012_0000_0012_0000,
            high: 0x0012_0000_0012_0000
        ))
        XCTAssertEqual(machine.vm.cpu.v[27], ARM64VectorRegister(
            low: 0x1200_0000_1200_0000,
            high: 0x1200_0000_1200_0000
        ))
        XCTAssertEqual(machine.vm.instructionTrace.prefix(4).map(\.decode),
                       Array(repeating: "movi-vector-word", count: 4))
    }

    func testSIMDInsertGeneralToVectorElementPreservesOtherLanes() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4e0c_1c9f,
            0x4e18_1c41,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[2] = 0x1122_3344_5566_7788
        machine.vm.cpu.x[4] = 0xaabb_ccdd_eeff_0011
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: 0xaaaa_aaaa_aaaa_aaaa, high: 0xbbbb_bbbb_bbbb_bbbb)
        machine.vm.cpu.v[1] = ARM64VectorRegister(low: 0xcccc_cccc_cccc_cccc, high: 0xdddd_dddd_dddd_dddd)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0xeeff_0011_aaaa_aaaa, high: 0xbbbb_bbbb_bbbb_bbbb))
        XCTAssertEqual(machine.vm.cpu.v[1], ARM64VectorRegister(low: 0xcccc_cccc_cccc_cccc, high: 0x1122_3344_5566_7788))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "mov-general-to-vector-element")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "mov-general-to-vector-element")
    }

    func testSIMDSignedShiftLongSToDExtendsAndShiftsVectorLanes() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x0f20_a420,
            0x0f21_a422,
            0x4f20_a423,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.v[1] = ARM64VectorRegister(
            low: 0xffff_fffe_0000_0002,
            high: 0x8000_0000_7fff_ffff
        )

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: 0x2, high: 0xffff_ffff_ffff_fffe))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: 0x4, high: 0xffff_ffff_ffff_fffc))
        XCTAssertEqual(machine.vm.cpu.v[3], ARM64VectorRegister(low: 0x7fff_ffff, high: 0xffff_ffff_8000_0000))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "sshll-s-to-d")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "sshll2-s-to-d")
    }

    func testSIMDAddVectorSupportsBusyBoxProcessPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4eff_879c,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 2)
        machine.vm.cpu.v[28] = ARM64VectorRegister(
            low: 0xffff_ffff_ffff_fffe,
            high: 0x1000_0000_0000_0000
        )
        machine.vm.cpu.v[31] = ARM64VectorRegister(
            low: 0x5,
            high: 0xf000_0000_0000_0001
        )

        let result = try machine.vm.run(maxSteps: 3)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[28], ARM64VectorRegister(low: 0x3, high: 0x1))
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0x5, high: 0xf000_0000_0000_0001))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "add-vector")
    }

    func testSIMDTableLookupSupportsBusyBoxProcessPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4e17_03ff,
            0x4e03_2020,
            0x4e06_10a4,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: 0x1716_1514_1312_1110, high: 0x1f1e_1d1c_1b1a_1918)
        machine.vm.cpu.v[23] = ARM64VectorRegister(low: 0x100f_0e0d_0c03_0201, high: 0xff1f_1e11_1007_0605)
        machine.vm.cpu.v[1] = ARM64VectorRegister(low: 0x0706_0504_0302_0100, high: 0x0f0e_0d0c_0b0a_0908)
        machine.vm.cpu.v[2] = ARM64VectorRegister(low: 0x1716_1514_1312_1110, high: 0x1f1e_1d1c_1b1a_1918)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: 0x201f_100f_0801_0000, high: 0x1f1e_1d1c_1b1a_1918)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: 0xaaaa_aaaa_aaaa_aaaa, high: 0xbbbb_bbbb_bbbb_bbbb)
        machine.vm.cpu.v[5] = ARM64VectorRegister(low: 0x8786_8584_8382_8180, high: 0x8f8e_8d8c_8b8a_8988)
        machine.vm.cpu.v[6] = ARM64VectorRegister(low: 0x100f_0e0d_0c03_0201, high: 0xff1f_1e11_1007_0605)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(
            low: 0x001f_1e1d_1c13_1211,
            high: 0x0000_0000_0017_1615
        ))
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(
            low: 0x001f_100f_0801_0000,
            high: 0x1f1e_1d1c_1b1a_1918
        ))
        XCTAssertEqual(machine.vm.cpu.v[4], ARM64VectorRegister(
            low: 0xaa8f_8e8d_8c83_8281,
            high: 0xbbbb_bbbb_bb87_8685
        ))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "tbl-vector")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "tbx-vector")
    }

    func testSIMDPermuteTwoVectorSupportsBusyBoxProcessPath() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4e1b_3bfd,
            0x4e1b_7bfc,
            0x4e59_6b1a,
            0x4e96_1ab7,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.v[31] = ARM64VectorRegister(low: 0x1716_1514_1312_1110, high: 0x1f1e_1d1c_1b1a_1918)
        machine.vm.cpu.v[27] = ARM64VectorRegister(low: 0x8786_8584_8382_8180, high: 0x8f8e_8d8c_8b8a_8988)
        machine.vm.cpu.v[24] = ARM64VectorRegister(low: 0x1003_1002_1001_1000, high: 0x1007_1006_1005_1004)
        machine.vm.cpu.v[25] = ARM64VectorRegister(low: 0x8003_8002_8001_8000, high: 0x8007_8006_8005_8004)
        machine.vm.cpu.v[21] = ARM64VectorRegister(low: 0x1000_0001_1000_0000, high: 0x1000_0003_1000_0002)
        machine.vm.cpu.v[22] = ARM64VectorRegister(low: 0x8000_0001_8000_0000, high: 0x8000_0003_8000_0002)

        let result = try machine.vm.run(maxSteps: 7)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[29], ARM64VectorRegister(
            low: 0x8313_8212_8111_8010,
            high: 0x8717_8616_8515_8414
        ))
        XCTAssertEqual(machine.vm.cpu.v[28], ARM64VectorRegister(
            low: 0x8b1b_8a1a_8919_8818,
            high: 0x8f1f_8e1e_8d1d_8c1c
        ))
        XCTAssertEqual(machine.vm.cpu.v[26], ARM64VectorRegister(
            low: 0x8003_1003_8001_1001,
            high: 0x8007_1007_8005_1005
        ))
        XCTAssertEqual(machine.vm.cpu.v[23], ARM64VectorRegister(
            low: 0x1000_0002_1000_0000,
            high: 0x8000_0002_8000_0000
        ))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "zip1-vector")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "zip2-vector")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "trn2-vector")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "uzp1-vector")
    }

    func testSIMDMoveImmediateZeroClearsVectorRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x4f00_041b,
            0x4f00_e403,
            0x6f00_e402,
            0x2f00_e40f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.v[27] = ARM64VectorRegister(low: 0xffff_ffff_ffff_ffff, high: 0xffff_ffff_ffff_ffff)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: 0x1111_2222_3333_4444, high: 0x5555_6666_7777_8888)
        machine.vm.cpu.v[2] = ARM64VectorRegister(low: 0x9999_aaaa_bbbb_cccc, high: 0xdddd_eeee_ffff_0000)
        machine.vm.cpu.v[15] = ARM64VectorRegister(low: 0x1234_5678_90ab_cdef, high: 0xfedc_ba09_8765_4321)

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[27], ARM64VectorRegister())
        XCTAssertEqual(machine.vm.cpu.v[3], ARM64VectorRegister())
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister())
        XCTAssertEqual(machine.vm.cpu.v[15], ARM64VectorRegister())
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "movi-vector-zero")
    }

    func testSIMDMoveImmediateByteAndScalarByteLoadStoreSupportBusyBoxSetup() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let program = littleEndianWords([
            0x4f00_e45f,
            encodeSIMDScalarByteTransfer(base: 0x3d00_0000, rt: 31, rn: 22, offsetBytes: 0x6d),
            encodeSIMDScalarByteTransfer(base: 0x3d40_0000, rt: 2, rn: 22, offsetBytes: 0x6d),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.x[22] = dataBase

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0x0202_0202_0202_0202, high: 0x0202_0202_0202_0202))
        XCTAssertEqual(machine.vm.cpu.v[2], ARM64VectorRegister(low: 0x02, high: 0))
        XCTAssertEqual(try machine.vm.memory.read8(at: dataBase + 0x6d), 0x02)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "movi-vector-byte")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "str-b-unsigned-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "ldr-b-unsigned-immediate")
    }

    func testSIMDFPScalarDUnsignedImmediateLoadStoreUsesVectorLowBits() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let program = littleEndianWords([
            0xfd00_0fef,
            0xfd40_0ff0,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.sp = dataBase
        machine.vm.cpu.v[15] = ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0xaaaa_bbbb_cccc_dddd)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 24), 0x1122_3344_5566_7788)
        XCTAssertEqual(machine.vm.cpu.v[16], ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "str-d-unsigned-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ldr-d-unsigned-immediate")
    }

    func testSIMDMoveInvertedImmediateSupportsBusyBoxVectorFill() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x2f00_041f,
            0x6f00_2420,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0xffff_ffff_ffff_ffff, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[0], ARM64VectorRegister(low: 0xffff_feff_ffff_feff, high: 0xffff_feff_ffff_feff))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "mvni-vector-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "mvni-vector-immediate")
    }

    func testSIMDMoveDImmediateSupportsApkVectorMask() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0x2f07_e61f,
            0x6f07_e61e,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0xffff_ffff_0000_0000, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[30], ARM64VectorRegister(
            low: 0xffff_ffff_0000_0000,
            high: 0xffff_ffff_0000_0000
        ))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "movi-d-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "movi-d-immediate")
    }

    func testSIMDQUnsignedImmediateLoadStoreTransfers128Bits() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let program = littleEndianWords([
            encodeSIMDQTransfer(base: 0x3dc0_0000, rt: 31, rn: 0, offsetBytes: 16),
            encodeSIMDQTransfer(base: 0x3d80_0000, rt: 31, rn: 0, offsetBytes: 48),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.memory.write64(0x1122_3344_5566_7788, at: dataBase + 16)
        try machine.vm.memory.write64(0x99aa_bbcc_ddee_ff00, at: dataBase + 24)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[0] = dataBase

        let result = try machine.vm.run(maxSteps: 6)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[31], ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0x99aa_bbcc_ddee_ff00))
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 48), 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 56), 0x99aa_bbcc_ddee_ff00)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "ldr-q-unsigned-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "str-q-unsigned-immediate")
    }

    func testSIMDFPQSignedImmediateStoreTransfersVectorWithoutClobberingScalarRegister() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let program = littleEndianWords([
            encodeSIMDFPQSignedImmediateTransfer(base: 0x3c80_0000, rt: 0, rn: 4, offsetBytes: -16),
            encodeSIMDFPQSignedImmediateTransfer(base: 0x3cc0_0000, rt: 1, rn: 4, offsetBytes: -16),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[0] = 0x1234_5678_9abc_def0
        machine.vm.cpu.x[4] = dataBase + 0x30
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: 0x0102_0304_0506_0708, high: 0x1112_1314_1516_1718)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1234_5678_9abc_def0)
        XCTAssertEqual(machine.vm.cpu.v[1], machine.vm.cpu.v[0])
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 0x20), 0x0102_0304_0506_0708)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 0x28), 0x1112_1314_1516_1718)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "stur-q-unscaled-immediate")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ldur-q-unscaled-immediate")
    }

    func testSIMDQPairLoadStoreTransfersTwoVectorRegisters() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let stackBase = dataBase + 0x100
        let program = littleEndianWords([
            encodeSIMDQPairTransfer(base: 0xad00_0000, rt: 0, rt2: 1, rn: 2, offsetBytes: 32),
            encodeSIMDQPairTransfer(base: 0xad40_0000, rt: 8, rt2: 9, rn: 2, offsetBytes: 32),
            encodeSIMDQPairTransfer(base: 0xad80_0000, rt: 4, rt2: 5, rn: 31, offsetBytes: -32),
            encodeSIMDQPairTransfer(base: 0xacc0_0000, rt: 6, rt2: 7, rn: 31, offsetBytes: 32),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 5)
        machine.vm.cpu.x[2] = dataBase
        machine.vm.cpu.sp = stackBase
        machine.vm.cpu.v[0] = ARM64VectorRegister(low: 0x0102_0304_0506_0708, high: 0x1112_1314_1516_1718)
        machine.vm.cpu.v[1] = ARM64VectorRegister(low: 0x2122_2324_2526_2728, high: 0x3132_3334_3536_3738)
        machine.vm.cpu.v[4] = ARM64VectorRegister(low: 0x4142_4344_4546_4748, high: 0x5152_5354_5556_5758)
        machine.vm.cpu.v[5] = ARM64VectorRegister(low: 0x6162_6364_6566_6768, high: 0x7172_7374_7576_7778)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[8], machine.vm.cpu.v[0])
        XCTAssertEqual(machine.vm.cpu.v[9], machine.vm.cpu.v[1])
        XCTAssertEqual(machine.vm.cpu.v[6], machine.vm.cpu.v[4])
        XCTAssertEqual(machine.vm.cpu.v[7], machine.vm.cpu.v[5])
        XCTAssertEqual(machine.vm.cpu.sp, stackBase)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 32), 0x0102_0304_0506_0708)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 56), 0x3132_3334_3536_3738)
        XCTAssertEqual(try machine.vm.memory.read64(at: stackBase - 32), 0x4142_4344_4546_4748)
        XCTAssertEqual(try machine.vm.memory.read64(at: stackBase - 8), 0x7172_7374_7576_7778)
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "stp-q-signed-offset")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ldp-q-signed-offset")
        XCTAssertEqual(machine.vm.instructionTrace[2].decode, "stp-q-pre-index")
        XCTAssertEqual(machine.vm.instructionTrace[3].decode, "ldp-q-post-index")
    }

    func testSIMDDPairLoadStoreTransfersLow64Bits() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let dataBase = entry + 0x1000
        let program = littleEndianWords([
            encodeSIMDDPairTransfer(base: 0x6d00_0000, rt: 8, rt2: 9, rn: 0, offsetBytes: 0x70),
            encodeSIMDDPairTransfer(base: 0x6d40_0000, rt: 10, rt2: 11, rn: 0, offsetBytes: 0x70),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 3)
        machine.vm.cpu.x[0] = dataBase
        machine.vm.cpu.v[8] = ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0xaaaa_aaaa_aaaa_aaaa)
        machine.vm.cpu.v[9] = ARM64VectorRegister(low: 0x99aa_bbcc_ddee_ff00, high: 0xbbbb_bbbb_bbbb_bbbb)
        machine.vm.cpu.v[10] = ARM64VectorRegister(low: 1, high: 2)
        machine.vm.cpu.v[11] = ARM64VectorRegister(low: 3, high: 4)

        let result = try machine.vm.run(maxSteps: 5)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 0x70), 0x1122_3344_5566_7788)
        XCTAssertEqual(try machine.vm.memory.read64(at: dataBase + 0x78), 0x99aa_bbcc_ddee_ff00)
        XCTAssertEqual(machine.vm.cpu.v[10], ARM64VectorRegister(low: 0x1122_3344_5566_7788, high: 0))
        XCTAssertEqual(machine.vm.cpu.v[11], ARM64VectorRegister(low: 0x99aa_bbcc_ddee_ff00, high: 0))
        XCTAssertEqual(machine.vm.instructionTrace[0].decode, "stp-d-signed-offset")
        XCTAssertEqual(machine.vm.instructionTrace[1].decode, "ldp-d-signed-offset")
    }

    func testDefaultCPUFeaturesAdvertiseImplementedFPSIMD() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let pfr0 = machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.idAA64PFR0EL1)

        XCTAssertEqual((pfr0 >> 0) & 0xf, 0x1)
        XCTAssertEqual((pfr0 >> 4) & 0xf, 0x1)
        XCTAssertEqual((pfr0 >> 16) & 0xf, 0)
        XCTAssertEqual((pfr0 >> 20) & 0xf, 0)
    }

    func testDefaultCPUFeaturesDoNotAdvertiseUnvalidatedHardwareAccessFlagUpdates() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let mmfr1 = machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.idAA64MMFR1EL1)

        XCTAssertEqual(mmfr1 & 0xf, 0)
    }

    func testTimerScaleAdvancesGenericCounterPerInstruction() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.timerCyclesPerInstruction = 10

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(machine.vm.systemRegisters.read(ARM64SystemRegister.cntpctEL0, cpu: machine.vm.cpu), 20)
        XCTAssertEqual(machine.vm.systemRegisters.read(ARM64SystemRegister.cntvctEL0, cpu: machine.vm.cpu), 20)
    }

    func testSoftwareBackendUsesNativeCoreWhenTimerScaleIsEnabled() throws {
        let backend = SoftwareARM64Backend()
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd503_201f,
            0xd503_201f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 10

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(machine.vm.systemRegisters.read(ARM64SystemRegister.cntpctEL0, cpu: machine.vm.cpu), 30)
        XCTAssertGreaterThanOrEqual(backend.nativeBasicBlockSteps, 2)
        XCTAssertLessThanOrEqual(backend.singleInstructionSteps, 1)
    }

    func testTimerValueRegisterUsesSignedOffset() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.vm.systemRegisters.advance(cycles: 100)
        try writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 10, into: machine.vm)

        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntvCvalEL0), 110)

        try writeSystemRegister(ARM64SystemRegister.cntvTvalEL0, value: 0xffff_fffe, into: machine.vm)

        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntvCvalEL0), 98)
    }

    func testGenericTimerRefreshSkipsUntilProgrammedDeadline() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.vm.reset(entryPoint: ARM64VizMachineLayout.toyEntryPoint)
        machine.vm.interruptController.setEnabled(line: VirtualMachine.physicalTimerIRQ, enabled: true)
        try writeSystemRegister(ARM64SystemRegister.cntpTvalEL0, value: 10, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntpCtlEL0, value: 1, into: machine.vm)

        machine.vm.updateGenericTimerInterruptsIfNeeded()
        XCTAssertNil(machine.vm.interruptController.peekPending())

        machine.vm.systemRegisters.advance(cycles: 9)
        machine.vm.updateGenericTimerInterruptsIfNeeded()
        XCTAssertNil(machine.vm.interruptController.peekPending())

        machine.vm.systemRegisters.advance(cycles: 1)
        machine.vm.updateGenericTimerInterruptsIfNeeded()
        XCTAssertEqual(machine.vm.interruptController.peekPending(), VirtualMachine.physicalTimerIRQ)
    }

    func testSupervisorCallRoutesToVectorAndERETReturns() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let vectorSync = vectorBase + 0x200
        let program = littleEndianWords([
            encodeSVC(immediate: 0x1234),
            0xd440_0000
        ])
        let vector = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.esrEL1),
            encodeMRS(rt: 1, key: ARM64SystemRegister.elrEL1),
            encodeERET()
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(vector, at: vectorSync)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], ARM64ExceptionClass.supervisorCallAArch64.syndrome(iss: 0x1234))
        XCTAssertEqual(machine.vm.cpu.x[1], entry + 4)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.cpu.pstate, ARM64PState.el1hMasked)
        XCTAssertEqual(result.lastException?.source, .supervisorCall)
        XCTAssertEqual(result.lastException?.exceptionClass, .supervisorCallAArch64)
        XCTAssertEqual(result.lastException?.returnAddress, entry + 4)
        XCTAssertEqual(result.lastException?.vectorAddress, vectorSync)
    }

    func testStopOnEL0EntryRecordsExceptionLevelTransition() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let userEntry = entry + 0x1000
        let program = littleEndianWords([
            encodeERET()
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: userEntry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.stopOnEL0Entry = true
        try writeSystemRegister(ARM64SystemRegister.elrEL1, value: userEntry, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.spsrEL1, value: ARM64PState.el0t, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .el0Entry(userEntry))
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(machine.vm.cpu.currentExceptionLevel, 0)
        XCTAssertEqual(machine.vm.cpu.pc, userEntry)
        XCTAssertEqual(machine.vm.executionStateTrace.count, 1)
        XCTAssertEqual(machine.vm.firstEL0Entry, machine.vm.executionStateTrace.first)
        XCTAssertEqual(machine.vm.executionStateTrace.first?.reason, .instruction)
        XCTAssertEqual(machine.vm.executionStateTrace.first?.previousEL, 1)
        XCTAssertEqual(machine.vm.executionStateTrace.first?.newEL, 0)
        XCTAssertEqual(machine.vm.executionStateTrace.first?.previousPC, entry)
        XCTAssertEqual(machine.vm.executionStateTrace.first?.newPC, userEntry)
    }

    func testStopOnEL0FaultStopsAtUserspaceTranslationFault() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let vectorBase: GuestAddress = 0x3000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xf940_0022,
            0xd440_0000
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.loadBinary(program, at: codePhysical)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.pstate = ARM64PState.el0t
        machine.vm.cpu.x[1] = dataVirtual
        machine.vm.stopOnEL0Fault = true
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .el0Fault(codeVirtual, dataVirtual))
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(machine.vm.cpu.pc, vectorBase + 0x400)
        XCTAssertEqual(machine.vm.cpu.currentExceptionLevel, 1)
        XCTAssertEqual(result.lastException?.source, .translationFault)
        XCTAssertEqual(result.lastException?.exceptionClass, .dataAbortLowerEL)
        XCTAssertEqual(result.lastException?.returnAddress, codeVirtual)
        XCTAssertEqual(result.lastException?.faultAddress, dataVirtual)
        XCTAssertEqual(result.lastException?.vectorOffset, 0x400)
        XCTAssertEqual(result.lastException?.access, .dataRead)
        XCTAssertEqual(result.lastException?.faultLevel, 3)
        XCTAssertEqual(result.lastException?.faultStatusCode, .translationLevel3)
        XCTAssertEqual(
            machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.esrEL1),
            ARM64ExceptionClass.dataAbortLowerEL.syndrome(iss: ARM64FaultStatusCode.translationLevel3.rawValue)
        )
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.farEL1), dataVirtual)
    }

    func testExceptionReturnAndEL0ExceptionSwitchStackPointerBanks() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let userEntry = entry + 0x1000
        let vectorBase = entry + 0x2000
        let vectorSyncFromEL0 = vectorBase + 0x400
        let kernelStack: GuestAddress = 0xffff_8000_8000_bdd0
        let userStack: GuestAddress = 0xffff_f878_d270
        let userStackAfterSub = userStack - 0x20
        let entryProgram = littleEndianWords([
            encodeERET()
        ])
        let userProgram = littleEndianWords([
            encodeAddSubImmediate(rd: 31, rn: 31, immediate: 0x20, subtract: true),
            encodeSVC(immediate: 0)
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.spEL0),
            encodeAddSubImmediate(rd: 1, rn: 31, immediate: 0, subtract: false),
            0xd440_0000
        ])

        try machine.vm.loadBinary(entryProgram, at: entry)
        try machine.vm.loadBinary(userProgram, at: userEntry)
        try machine.vm.loadBinary(handler, at: vectorSyncFromEL0)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.cpu.sp = kernelStack
        try writeSystemRegister(ARM64SystemRegister.spEL0, value: userStack, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.elrEL1, value: userEntry, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.spsrEL1, value: ARM64PState.el0t, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], userStackAfterSub)
        XCTAssertEqual(machine.vm.cpu.x[1], kernelStack)
        XCTAssertEqual(machine.vm.cpu.sp, kernelStack)
        XCTAssertEqual(machine.vm.cpu.spEL1, kernelStack)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.spEL0), userStackAfterSub)
        XCTAssertEqual(result.lastException?.source, .supervisorCall)
        XCTAssertEqual(result.lastException?.currentEL, 0)
        XCTAssertEqual(result.lastException?.vectorOffset, 0x400)
    }

    func testBreakpointInstructionRoutesToVectorAtCurrentInstruction() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let vectorSync = vectorBase + 0x200
        let program = littleEndianWords([
            encodeBRK(immediate: 0x800),
            0xd440_0000
        ])
        let vector = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.esrEL1),
            encodeMRS(rt: 1, key: ARM64SystemRegister.elrEL1),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(vector, at: vectorSync)
        machine.vm.reset(entryPoint: entry)
        machine.vm.enableInstructionTrace(capacity: 4)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], ARM64ExceptionClass.breakpointAArch64.syndrome(iss: 0x800))
        XCTAssertEqual(machine.vm.cpu.x[1], entry)
        XCTAssertEqual(machine.vm.cpu.pc, vectorSync + 12)
        XCTAssertEqual(machine.vm.instructionTrace.first?.decode, "brk")
        XCTAssertEqual(result.lastException?.source, .breakpoint)
        XCTAssertEqual(result.lastException?.exceptionClass, .breakpointAArch64)
        XCTAssertEqual(result.lastException?.returnAddress, entry)
        XCTAssertEqual(result.lastException?.vectorAddress, vectorSync)
    }

    func testRepeatedBreakpointExceptionStopsAsExceptionStorm() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let vectorSync = vectorBase + 0x200
        let program = littleEndianWords([
            encodeBRK(immediate: 0x800),
            0xd440_0000
        ])
        let vector = littleEndianWords([
            encodeERET()
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(vector, at: vectorSync)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.exceptionStormThreshold = 4
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 32)

        XCTAssertEqual(result.stopReason, .exceptionStorm(entry, 4))
        XCTAssertEqual(result.lastException?.source, .breakpoint)
        XCTAssertEqual(result.lastException?.exceptionClass, .breakpointAArch64)
        XCTAssertEqual(result.lastException?.returnAddress, entry)
        XCTAssertEqual(machine.vm.exceptionStorm?.count, 4)
        XCTAssertEqual(machine.vm.exceptionStorm?.entry.returnAddress, entry)
    }

    func testMMUTranslatesInstructionFetchAndDataLoads() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let dataPhysical = codePhysical + 0x1000
        let program = littleEndianWords([
            0xf940_0022,
            0xd440_0000
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(dataPhysical | 0x403, at: table3 + 16)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.memory.write64(0xfeed_face_cafe_beef, at: dataPhysical)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.x[1] = dataVirtual
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0xfeed_face_cafe_beef)
        XCTAssertEqual(machine.vm.cpu.pc, codeVirtual + 8)
    }

    func testMMUSplitsGuestDataAccessesAcrossPageBoundary() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let secondVirtual: GuestAddress = 0x2000
        let crossPageVirtual = secondVirtual - 4
        let firstPhysical = ARM64VizMachineLayout.toyEntryPoint + 0x5000
        let secondPhysical = ARM64VizMachineLayout.toyEntryPoint + 0x9000
        let wrongContiguousPhysical = firstPhysical + 0x1000

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(firstPhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(secondPhysical | 0x403, at: table3 + 16)
        try machine.vm.memory.write64(0xaaaa_aaaa_aaaa_aaaa, at: wrongContiguousPhysical)
        machine.vm.reset(entryPoint: 0)
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        try machine.vm.writeGuest(crossPageVirtual, width: .doubleword, value: 0x1122_3344_5566_7788)

        XCTAssertEqual(try machine.vm.memory.read32(at: firstPhysical + 0xffc), 0x5566_7788)
        XCTAssertEqual(try machine.vm.memory.read32(at: secondPhysical), 0x1122_3344)
        XCTAssertEqual(try machine.vm.memory.read64(at: wrongContiguousPhysical), 0xaaaa_aaaa_aaaa_aaaa)
        XCTAssertEqual(try machine.vm.readGuest(crossPageVirtual, width: .doubleword), 0x1122_3344_5566_7788)
    }

    func testTranslationCacheReusesWalksAndSeparatesMMUContexts() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let tableA0 = ARM64VizMachineLayout.ramBase + 0x1000
        let tableA1 = ARM64VizMachineLayout.ramBase + 0x2000
        let tableA2 = ARM64VizMachineLayout.ramBase + 0x3000
        let tableA3 = ARM64VizMachineLayout.ramBase + 0x4000
        let tableB0 = ARM64VizMachineLayout.ramBase + 0x5000
        let tableB1 = ARM64VizMachineLayout.ramBase + 0x6000
        let tableB2 = ARM64VizMachineLayout.ramBase + 0x7000
        let tableB3 = ARM64VizMachineLayout.ramBase + 0x8000
        let virtual: GuestAddress = 0x1000
        let physicalA = ARM64VizMachineLayout.toyEntryPoint
        let physicalB = physicalA + 0x1000

        try machine.vm.memory.write64(tableA1 | 0x3, at: tableA0)
        try machine.vm.memory.write64(tableA2 | 0x3, at: tableA1)
        try machine.vm.memory.write64(tableA3 | 0x3, at: tableA2)
        try machine.vm.memory.write64(physicalA | 0x403, at: tableA3 + 8)
        try machine.vm.memory.write64(tableB1 | 0x3, at: tableB0)
        try machine.vm.memory.write64(tableB2 | 0x3, at: tableB1)
        try machine.vm.memory.write64(tableB3 | 0x3, at: tableB2)
        try machine.vm.memory.write64(physicalB | 0x403, at: tableB3 + 8)
        machine.vm.reset(entryPoint: virtual)
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: tableA0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        XCTAssertEqual(try machine.vm.translateAddress(virtual, access: .instruction), physicalA)
        XCTAssertEqual(machine.vm.translationCacheMisses, 1)
        XCTAssertEqual(try machine.vm.translateAddress(virtual + 4, access: .instruction), physicalA + 4)
        XCTAssertEqual(machine.vm.translationCacheHits, 1)

        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: tableB0, into: machine.vm)

        XCTAssertEqual(try machine.vm.translateAddress(virtual, access: .instruction), physicalB)
        XCTAssertEqual(machine.vm.translationCacheMisses, 2)
    }

    func testNativeBurstInvalidatesTranslatedPagesAfterSystemInstruction() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let tableVirtual: GuestAddress = 0x3000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let dataPhysicalA = codePhysical + 0x1000
        let dataPhysicalB = codePhysical + 0x2000
        let program = littleEndianWords([
            0xf940_0020, // ldr x0, [x1]
            0xf900_0043, // str x3, [x2]
            0xd50b_7e21, // dc civac, x1; modeled as a translation-cache boundary
            0xf940_0024, // ldr x4, [x1]
            0xd440_0000
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(dataPhysicalA | 0x403, at: table3 + 16)
        try machine.vm.memory.write64(table3 | 0x403, at: table3 + 24)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.memory.write64(0x1111_1111_1111_1111, at: dataPhysicalA)
        try machine.vm.memory.write64(0x2222_2222_2222_2222, at: dataPhysicalB)
        machine.vm.reset(entryPoint: codeVirtual)
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0
        machine.vm.cpu.x[1] = dataVirtual
        machine.vm.cpu.x[2] = tableVirtual + 16
        machine.vm.cpu.x[3] = dataPhysicalB | 0x403

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1111_1111_1111_1111)
        XCTAssertEqual(machine.vm.cpu.x[4], 0x2222_2222_2222_2222)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }

    func testNativeMemorySessionRetainsTLBAcrossRunsAndHonorsHostInvalidation() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let dataPhysicalA = codePhysical + 0x1000
        let dataPhysicalB = codePhysical + 0x2000
        let program = littleEndianWords([
            0xf940_0020, // ldr x0, [x1]
            0x17ff_ffff  // b #-4
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(dataPhysicalA | 0x403, at: table3 + 16)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.memory.write64(0x1111_1111_1111_1111, at: dataPhysicalA)
        try machine.vm.memory.write64(0x2222_2222_2222_2222, at: dataPhysicalB)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.x[1] = dataVirtual
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        _ = try machine.vm.run(maxSteps: 2)
        let firstMisses = backend.nativeReadTLBMisses
        let firstHits = backend.nativeReadTLBHits
        XCTAssertEqual(machine.vm.cpu.x[0], 0x1111_1111_1111_1111)
        XCTAssertEqual(backend.nativeMemorySessionCreations, 1)
        XCTAssertGreaterThan(firstMisses, 0)
        XCTAssertGreaterThan(backend.nativePageTableWalks, 0)
        XCTAssertEqual(backend.nativeTranslationCallbackWalks, 0)

        _ = try machine.vm.run(maxSteps: 2)
        XCTAssertEqual(backend.nativeMemorySessionCreations, 1)
        XCTAssertEqual(backend.nativeReadTLBMisses, firstMisses)
        XCTAssertGreaterThan(backend.nativeReadTLBHits, firstHits)

        try machine.vm.memory.write64(dataPhysicalB | 0x403, at: table3 + 16)
        machine.vm.invalidateTranslationCache()
        _ = try machine.vm.run(maxSteps: 2)

        XCTAssertEqual(machine.vm.cpu.x[0], 0x2222_2222_2222_2222)
        XCTAssertEqual(backend.nativeMemorySessionCreations, 1)
        XCTAssertGreaterThan(backend.nativeReadTLBMisses, firstMisses)
        XCTAssertEqual(backend.nativeTranslationCallbackWalks, 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testNativeFastTLBIsInvalidatedWhenIRQEntersEL1() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let vectorVirtual: GuestAddress = 0x4000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let dataPhysical = codePhysical + 0x1000
        let vectorPhysical = codePhysical + 0x2000
        let irqLine: UInt32 = 40

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(dataPhysical | 0x403, at: table3 + 16)
        try machine.vm.memory.write64(vectorPhysical | 0x403, at: table3 + 32)
        try machine.vm.loadBinary(littleEndianWords([
            0xf940_0020, // ldr x0, [x1]
            0x17ff_ffff  // b #-4
        ]), at: codePhysical)
        try machine.vm.loadBinary(littleEndianWords([
            0xf940_0022, // ldr x2, [x1]
            0xd440_0000
        ]), at: vectorPhysical + 0x480)
        try machine.vm.memory.write64(0xfeed_face_cafe_beef, at: dataPhysical)

        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.pstate = ARM64PState.el0t
        machine.vm.cpu.x[1] = dataVirtual
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorVirtual, into: machine.vm)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        _ = try machine.vm.run(maxSteps: 2)
        let missesBeforeIRQ = backend.nativeReadTLBMisses
        XCTAssertEqual(machine.vm.cpu.x[0], 0xfeed_face_cafe_beef)

        machine.vm.interruptController.setEnabled(line: irqLine, enabled: true)
        machine.vm.interruptController.raise(line: irqLine)
        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[2], 0xfeed_face_cafe_beef)
        XCTAssertGreaterThan(backend.nativeReadTLBMisses, missesBeforeIRQ)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testNativeDirectLinkDoesNotCrossTTBRContextChanges() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let roots = (0..<3).map { index in
            ARM64VizMachineLayout.ramBase + GuestAddress(0x1000 + index * 0x4000)
        }
        let codePhysicalA = ARM64VizMachineLayout.toyEntryPoint
        let codePhysicalB = codePhysicalA + 0x1000
        let codePhysicalC = codePhysicalA + 0x2000
        let codeVirtual: GuestAddress = 0x1000

        for (root, codePhysical) in zip(roots, [codePhysicalA, codePhysicalB, codePhysicalC]) {
            try machine.vm.memory.write64((root + 0x1000) | 0x3, at: root)
            try machine.vm.memory.write64((root + 0x2000) | 0x3, at: root + 0x1000)
            try machine.vm.memory.write64((root + 0x3000) | 0x3, at: root + 0x2000)
            try machine.vm.memory.write64(codePhysical | 0x403, at: root + 0x3000 + 8)
        }

        try machine.vm.loadBinary(littleEndianWords([
            encodeMSR(rt: 0, key: ARM64SystemRegister.ttbr0EL1),
            0xd440_0000,
            0xd440_0000,
            0x17ff_fffd  // b 0x1000
        ]), at: codePhysicalA)
        try machine.vm.loadBinary(littleEndianWords([
            0xd440_0000,
            0xaa02_03e0, // mov x0, x2
            encodeMSR(rt: 1, key: ARM64SystemRegister.ttbr0EL1),
            0xd440_0000
        ]), at: codePhysicalB)
        try machine.vm.loadBinary(littleEndianWords([
            0xd440_0000,
            0x9100_0463, // add x3, x3, #1
            0xd440_0000,
            0xd440_0000
        ]), at: codePhysicalC)

        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.x[0] = roots[1]
        machine.vm.cpu.x[1] = roots[0]
        machine.vm.cpu.x[2] = roots[2]
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: roots[0], into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[3], 1)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }

    func testMMURequiresAccessFlagOnLeafDescriptors() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x3, at: table3 + 8)
        machine.vm.reset(entryPoint: codeVirtual)
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        XCTAssertThrowsError(try machine.vm.translateAddress(codeVirtual, access: .instruction)) { error in
            guard let fault = error as? ARM64TranslationFault else {
                XCTFail("expected ARM64TranslationFault, got \(error)")
                return
            }
            XCTAssertEqual(fault.statusCode, .accessFlagLevel3)
            XCTAssertEqual(fault.level, 3)
        }
    }

    func testMMUTranslationCacheSeparatesExceptionLevelsWithoutFlushing() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let virtualAddress: GuestAddress = 0x1000
        let physicalAddress = ARM64VizMachineLayout.toyEntryPoint

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(physicalAddress | 0x403, at: table3 + 8)
        machine.vm.reset(entryPoint: virtualAddress)
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        machine.vm.cpu.pstate = ARM64PState.el1h
        XCTAssertEqual(
            try machine.vm.translateAddress(virtualAddress, access: .instruction),
            physicalAddress
        )
        machine.vm.cpu.pstate = ARM64PState.el0t
        XCTAssertEqual(
            try machine.vm.translateAddress(virtualAddress, access: .instruction),
            physicalAddress
        )
        machine.vm.cpu.pstate = ARM64PState.el1h
        XCTAssertEqual(
            try machine.vm.translateAddress(virtualAddress, access: .instruction),
            physicalAddress
        )

        XCTAssertEqual(machine.vm.translationCacheMisses, 2)
        XCTAssertEqual(machine.vm.translationCacheHits, 1)
    }

    func testMMURejectsEL1WritesToReadOnlyMappings() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let dataVirtual: GuestAddress = 0x2000
        let dataPhysical = ARM64VizMachineLayout.toyEntryPoint + 0x1000

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(dataPhysical | 0x403 | (1 << 7), at: table3 + 16)
        machine.vm.reset(entryPoint: 0)
        machine.vm.cpu.pstate = ARM64PState.el1h
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        XCTAssertThrowsError(try machine.vm.writeGuest(dataVirtual, width: .doubleword, value: 0xfeed)) { error in
            guard let fault = error as? ARM64TranslationFault else {
                XCTFail("expected ARM64TranslationFault, got \(error)")
                return
            }
            XCTAssertEqual(fault.statusCode, .permissionLevel3)
            XCTAssertEqual(fault.access, .dataWrite)
        }
    }

    func testDataAbortRoutesThroughExceptionVector() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let table0 = ARM64VizMachineLayout.ramBase + 0x1000
        let table1 = ARM64VizMachineLayout.ramBase + 0x2000
        let table2 = ARM64VizMachineLayout.ramBase + 0x3000
        let table3 = ARM64VizMachineLayout.ramBase + 0x4000
        let codeVirtual: GuestAddress = 0x1000
        let dataVirtual: GuestAddress = 0x2000
        let vectorBase: GuestAddress = 0x3000
        let vectorSync = vectorBase + 0x200
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint
        let vectorPhysical = codePhysical + 0x1000
        let program = littleEndianWords([
            0xf940_0022,
            0xd440_0000
        ])
        let vector = littleEndianWords([
            encodeMRS(rt: 3, key: ARM64SystemRegister.esrEL1),
            encodeMRS(rt: 4, key: ARM64SystemRegister.farEL1),
            encodeMRS(rt: 5, key: ARM64SystemRegister.elrEL1),
            0xd440_0000
        ])

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.memory.write64(vectorPhysical | 0x403, at: table3 + 24)
        try machine.vm.loadBinary(program, at: codePhysical)
        try machine.vm.loadBinary(vector, at: vectorPhysical + 0x200)
        machine.vm.reset(entryPoint: codeVirtual)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.cpu.x[1] = dataVirtual
        try writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(
            machine.vm.cpu.x[3],
            ARM64ExceptionClass.dataAbortSameEL.syndrome(iss: ARM64FaultStatusCode.translationLevel3.rawValue)
        )
        XCTAssertEqual(machine.vm.cpu.x[4], dataVirtual)
        XCTAssertEqual(machine.vm.cpu.x[5], codeVirtual)
        XCTAssertEqual(machine.vm.cpu.pc, vectorSync + 16)
        XCTAssertEqual(result.lastException?.source, .translationFault)
        XCTAssertEqual(result.lastException?.exceptionClass, .dataAbortSameEL)
        XCTAssertEqual(result.lastException?.returnAddress, codeVirtual)
        XCTAssertEqual(result.lastException?.faultAddress, dataVirtual)
        XCTAssertEqual(result.lastException?.vectorBase, vectorBase)
        XCTAssertEqual(result.lastException?.vectorOffset, 0x200)
        XCTAssertEqual(result.lastException?.vectorAddress, vectorSync)
        XCTAssertEqual(result.lastException?.access, .dataRead)
        XCTAssertEqual(result.lastException?.faultLevel, 3)
        XCTAssertEqual(result.lastException?.faultStatusCode, .translationLevel3)
        XCTAssertEqual(backend.nativePinnedDeviceSingleInstructionSteps, 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testInstructionAbortVectorSelfLoopStopsWithTelemetry() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.vm.reset(entryPoint: 0x1000)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 16)

        XCTAssertEqual(result.stopReason, .exceptionLoop(0x200))
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(result.lastException?.source, .translationFault)
        XCTAssertEqual(result.lastException?.exceptionClass, .instructionAbortSameEL)
        XCTAssertEqual(result.lastException?.returnAddress, 0x200)
        XCTAssertEqual(result.lastException?.faultAddress, 0x200)
        XCTAssertEqual(result.lastException?.vectorBase, 0)
        XCTAssertEqual(result.lastException?.vectorOffset, 0x200)
        XCTAssertEqual(result.lastException?.vectorAddress, 0x200)
        XCTAssertEqual(result.lastException?.access, .instruction)
        XCTAssertEqual(result.lastException?.faultLevel, 0)
        XCTAssertEqual(result.lastException?.faultStatusCode, .translationLevel0)
        XCTAssertEqual(machine.vm.exceptionTrace.count, 2)
    }

    func testMaskedIRQDoesNotVector() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1hMasked
        machine.vm.interruptController.setEnabled(line: 40, enabled: true)
        machine.vm.interruptController.raise(line: 40)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
    }

    func testUnmaskedIRQVectorsThroughVBAR() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.elrEL1),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        machine.vm.interruptController.setEnabled(line: 40, enabled: true)
        machine.vm.interruptController.raise(line: 40)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], entry)
        XCTAssertEqual(machine.vm.cpu.pc, irqVector + 8)
        XCTAssertEqual(machine.vm.cpu.pstate, ARM64PState.el1hMasked)
    }

    func testIRQHandlerCanERETToInterruptedCode() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            0xd280_0001,
            0xf2a1_0021,
            0xb940_0c20,
            0xb900_1020,
            encodeERET()
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        machine.vm.interruptController.setEnabled(line: 41, enabled: true)
        machine.vm.interruptController.raise(line: 41)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, entry + 8)
        XCTAssertEqual(machine.vm.cpu.pstate, ARM64PState.el1h)
    }

    func testPhysicalTimerRaisesIRQWhenDue() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.cntpctEL0),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        machine.vm.interruptController.setEnabled(line: VirtualMachine.physicalTimerIRQ, enabled: true)
        try writeSystemRegister(ARM64SystemRegister.cntpTvalEL0, value: 1, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.cntpCtlEL0, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertGreaterThanOrEqual(machine.vm.cpu.x[0], 1)
        XCTAssertEqual(machine.vm.cpu.pc, irqVector + 8)
    }

    func testGICMMIOEnablePathAllowsIRQDelivery() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let vectorBase = entry + 0x2000
        let irqVector = vectorBase + 0x280
        let line: UInt32 = 42
        let program = littleEndianWords([
            0xd503_201f,
            0xd440_0000
        ])
        let handler = littleEndianWords([
            encodeMRS(rt: 0, key: ARM64SystemRegister.elrEL1),
            0xd440_0000
        ])

        try machine.vm.loadBinary(program, at: entry)
        try machine.vm.loadBinary(handler, at: irqVector)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.pstate = ARM64PState.el1h
        try writeSystemRegister(ARM64SystemRegister.vbarEL1, value: vectorBase, into: machine.vm)
        let enableRegisterOffset = UInt64(line / 32) * 4
        let enableBit = UInt64(1) << UInt64(line % 32)
        try machine.vm.writePhysical(ARM64VizMachineLayout.gicBase + 0x100 + enableRegisterOffset, width: .word, value: enableBit)
        machine.vm.interruptController.raise(line: line)

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.x[0], entry)
    }

    func testGICIARAcknowledgesAndEOICompletesActiveLine() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let line: UInt32 = 42
        let enableRegisterOffset = UInt64(line / 32) * 4
        let enableBit = UInt64(1) << UInt64(line % 32)

        try machine.vm.writePhysical(ARM64VizMachineLayout.gicBase + 0x100 + enableRegisterOffset, width: .word, value: enableBit)
        machine.vm.interruptController.raise(line: line)

        let acknowledged = try machine.vm.readPhysical(ARM64VizMachineLayout.gicBase + 0x1_0000 + 0x00c, width: .word)

        XCTAssertEqual(acknowledged, UInt64(line))
        XCTAssertNil(machine.vm.interruptController.peekPending())
        XCTAssertEqual(machine.vm.interruptController.activeLine(), line)

        try machine.vm.writePhysical(ARM64VizMachineLayout.gicBase + 0x1_0000 + 0x010, width: .word, value: UInt64(line))

        XCTAssertNil(machine.vm.interruptController.activeLine())
    }

    func testMMUUsesTTBR1ForHighVirtualAddresses() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let table0 = ARM64VizMachineLayout.ramBase + 0x5000
        let table1 = ARM64VizMachineLayout.ramBase + 0x6000
        let table2 = ARM64VizMachineLayout.ramBase + 0x7000
        let table3 = ARM64VizMachineLayout.ramBase + 0x8000
        let codeVirtual: GuestAddress = 0xffff_0000_0000_1000
        let codePhysical = ARM64VizMachineLayout.toyEntryPoint

        try machine.vm.memory.write64(table1 | 0x3, at: table0)
        try machine.vm.memory.write64(table2 | 0x3, at: table1)
        try machine.vm.memory.write64(table3 | 0x3, at: table2)
        try machine.vm.memory.write64(codePhysical | 0x403, at: table3 + 8)
        try machine.vm.loadBinary(littleEndianWords([0xd440_0000]), at: codePhysical)
        machine.vm.reset(entryPoint: codeVirtual)
        try writeSystemRegister(ARM64SystemRegister.ttbr1EL1, value: table0, into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.tcrEL1, value: UInt64(16 << 16), into: machine.vm)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1, into: machine.vm)

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.pc, codeVirtual + 4)
    }

    func testSnapshotRestoresCPUAndUARTOutput() throws {
        let machine = try MachineFactory.makeResearchMachine()
        _ = try ToyUARTGuestAdapter(message: "snap\n").load(into: machine.vm)
        _ = try machine.vm.run(maxSteps: 100)
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 0x1234, into: machine.vm)

        let snapshot = machine.vm.makeSnapshot()
        machine.uart.replaceOutput([])
        machine.vm.cpu.pc = 0
        try writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 0, into: machine.vm)

        try machine.vm.restoreSnapshot(snapshot)

        XCTAssertEqual(machine.uart.outputString, "snap\n")
        XCTAssertEqual(machine.vm.cpu, snapshot.cpu)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.sctlrEL1), 0x1234)
    }

    func testProprietaryGuestPolicyRejectsRestrictedMaterials() {
        let manifest = ProprietaryGuestManifest(
            guestName: "restricted-example",
            researchPurpose: "Boundary test",
            authorizationSummary: "Test authorization",
            materials: [
                ProprietaryGuestMaterial(
                    kind: .ipswArchive,
                    identifier: "restricted-package",
                    lawfulSourceDescription: "Not read by this test"
                )
            ]
        )

        let report = ProprietaryGuestPolicy.evaluate(manifest)

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.findings.contains("ipswArchive is not accepted by this repository"))
    }

    func testProprietaryGuestPolicyRejectsIPSWIdentifierEvenWhenKindIsGeneric() {
        let manifest = ProprietaryGuestManifest(
            guestName: "restricted-example",
            researchPurpose: "Boundary test",
            authorizationSummary: "Test authorization",
            materials: [
                ProprietaryGuestMaterial(
                    kind: .genericOSImage,
                    identifier: "example.ipsw",
                    lawfulSourceDescription: "Not read by this test"
                )
            ]
        )

        let report = ProprietaryGuestPolicy.evaluate(manifest)

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.findings.contains("material identifier 'example.ipsw' ends with denied suffix .ipsw"))
    }

    func testPreferencesCannotWeakenBuiltInRestrictions() {
        let weakenedPreferences = ARM64VizPreferences(
            proprietaryGuests: ProprietaryGuestPreferences(deniedMaterialKinds: [.firmwareBlob])
        )

        XCTAssertThrowsError(try ARM64VizPreferencesLoader.validate(weakenedPreferences)) { error in
            guard case VMError.policyViolation = error else {
                XCTFail("expected policyViolation, got \(error)")
                return
            }
        }
    }

    func testDisabledBoundaryModeRejectsAllProprietaryManifests() {
        let preferences = ARM64VizPreferences(
            proprietaryGuests: ProprietaryGuestPreferences(boundaryMode: .disabled)
        )
        let manifest = ProprietaryGuestManifest(
            guestName: "metadata-only",
            researchPurpose: "Boundary test",
            authorizationSummary: "Test authorization",
            materials: []
        )

        let report = ProprietaryGuestPolicy.evaluate(manifest, preferences: preferences)

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.findings.contains("proprietary guest manifests are disabled by preferences"))
    }

    func testBoundaryOnlyAdapterNeverBootsProprietaryGuests() throws {
        let manifest = ProprietaryGuestManifest(
            guestName: "metadata-only",
            researchPurpose: "Boundary test",
            authorizationSummary: "Test authorization",
            materials: [
                ProprietaryGuestMaterial(
                    kind: .kernelImage,
                    identifier: "open-kernel",
                    lawfulSourceDescription: "Open-source test kernel"
                )
            ]
        )
        let machine = try MachineFactory.makeResearchMachine()
        let adapter = BoundaryOnlyProprietaryGuestAdapter(manifest: manifest)

        XCTAssertThrowsError(try adapter.load(into: machine.vm)) { error in
            guard case VMError.unsupportedGuest = error else {
                XCTFail("expected unsupportedGuest, got \(error)")
                return
            }
        }
    }

    func testBootArtifactClassifierTreatsIPSWAsRestricted() {
        let artifact = BootArtifactDescriptor(name: "example.ipsw", byteCount: 123)

        XCTAssertEqual(artifact.kind, .restrictedPackage)
    }

    func testBootAdapterRegistryPlansLinuxDirectBoot() {
        let artifacts = [
            BootArtifactDescriptor(name: "Image", byteCount: 4096),
            BootArtifactDescriptor(name: "initrd.cpio.gz", byteCount: 1024)
        ]

        let plans = BootAdapterRegistry.plans(for: artifacts)
        let linuxPlan = plans.first { $0.adapter.identifier == "linux-direct" }

        XCTAssertEqual(linuxPlan?.matchesArtifacts, true)
        XCTAssertEqual(linuxPlan?.canLaunchNow, false)
        XCTAssertEqual(linuxPlan?.warnings, ["adapter can prepare VM state; full guest execution awaits Linux-grade MMU/device/interrupt completeness"])
    }

    func testBootAdapterRegistryDisablesMobileOSImage() {
        let plans = BootAdapterRegistry.plans(for: [])
        let mobilePlan = plans.first { $0.adapter.identifier == "mobile-os-image" }

        XCTAssertEqual(mobilePlan?.matchesArtifacts, true)
        XCTAssertEqual(mobilePlan?.adapter.status, .disabled)
        XCTAssertEqual(mobilePlan?.canLaunchNow, false)
        XCTAssertTrue(mobilePlan?.findings.contains(RuntimeDirection.javascriptMobileOSDisabledReason) == true)
    }

    func testMobileOSImageArtifactClassification() {
        let artifact = BootArtifactDescriptor(name: "MobileOS.mosimg", byteCount: 4096)

        XCTAssertEqual(artifact.kind, .mobileOSImage)
    }

    func testMobileOSAppBundleClassification() {
        let artifact = BootArtifactDescriptor(name: "mail.app.js", byteCount: 512)

        XCTAssertEqual(artifact.kind, .mobileAppBundle)
    }

    func testBootPlansRejectRestrictedArtifactsAcrossAdapters() {
        let artifacts = [
            BootArtifactDescriptor(name: "example.ipsw", byteCount: 4096)
        ]

        let plans = BootAdapterRegistry.plans(for: artifacts)

        XCTAssertTrue(plans.allSatisfy { !$0.findings.isEmpty })
        XCTAssertTrue(plans.contains { plan in
            plan.findings.contains("example.ipsw is a restricted package type")
        })
    }

    private func configureVirtioQueue(
        machine: ResearchMachine,
        base: GuestAddress,
        queue: UInt32 = 0,
        descriptorTable: GuestAddress,
        availableRing: GuestAddress,
        usedRing: GuestAddress
    ) throws {
        try machine.vm.writePhysical(base + 0x030, width: .word, value: UInt64(queue))
        try machine.vm.writePhysical(base + 0x038, width: .word, value: 8)
        try machine.vm.writePhysical(base + 0x080, width: .word, value: descriptorTable & 0xffff_ffff)
        try machine.vm.writePhysical(base + 0x084, width: .word, value: descriptorTable >> 32)
        try machine.vm.writePhysical(base + 0x090, width: .word, value: availableRing & 0xffff_ffff)
        try machine.vm.writePhysical(base + 0x094, width: .word, value: availableRing >> 32)
        try machine.vm.writePhysical(base + 0x0a0, width: .word, value: usedRing & 0xffff_ffff)
        try machine.vm.writePhysical(base + 0x0a4, width: .word, value: usedRing >> 32)
        try machine.vm.writePhysical(base + 0x044, width: .word, value: 1)
        try machine.vm.writePhysical(base + 0x070, width: .word, value: 0xf)
    }

    private func writeVirtioDescriptor(
        machine: ResearchMachine,
        at table: GuestAddress,
        index: UInt16,
        address: GuestAddress,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        let offset = table + UInt64(index) * 16
        try machine.vm.memory.write64(address, at: offset)
        try machine.vm.memory.write32(length, at: offset + 8)
        try machine.vm.memory.write16(flags, at: offset + 12)
        try machine.vm.memory.write16(next, at: offset + 14)
    }

    private func writeVirtioBlockHeader(
        machine: ResearchMachine,
        at address: GuestAddress,
        requestType: UInt32,
        sector: UInt64
    ) throws {
        try machine.vm.memory.write32(requestType, at: address)
        try machine.vm.memory.write32(0, at: address + 4)
        try machine.vm.memory.write64(sector, at: address + 8)
    }

    private func writeMemoryBytesForTest(_ bytes: [UInt8], at address: GuestAddress, into memory: PhysicalMemory) throws {
        for (offset, byte) in bytes.enumerated() {
            try memory.write8(byte, at: address + UInt64(offset))
        }
    }

    private func submitGPUCommandType(
        _ type: UInt32,
        payload: [UInt8],
        machine: ResearchMachine,
        base: GuestAddress,
        descriptorTable: GuestAddress,
        availableRing: GuestAddress,
        usedRing: GuestAddress,
        requestAddress: GuestAddress,
        responseAddress: GuestAddress,
        availableIndex: inout UInt16
    ) throws -> UInt32 {
        let response = try submitVirtioGPUCommand(
            makeVirtioGPUCommand(type: type, payload: payload),
            machine: machine,
            base: base,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing,
            requestAddress: requestAddress,
            responseAddress: responseAddress,
            availableIndex: &availableIndex,
            responseLength: 24
        )
        return readLE32ForTest(response, at: 0)
    }

    private func submitVirtioGPUCommand(
        _ request: [UInt8],
        machine: ResearchMachine,
        base: GuestAddress,
        descriptorTable: GuestAddress,
        availableRing: GuestAddress,
        usedRing: GuestAddress,
        requestAddress: GuestAddress,
        responseAddress: GuestAddress,
        availableIndex: inout UInt16,
        responseLength: Int
    ) throws -> [UInt8] {
        try writeMemoryBytesForTest(request, at: requestAddress, into: machine.vm.memory)
        try writeVirtioDescriptor(
            machine: machine, at: descriptorTable, index: 0, address: requestAddress,
            length: UInt32(request.count), flags: 1, next: 1
        )
        try writeVirtioDescriptor(
            machine: machine, at: descriptorTable, index: 1, address: responseAddress,
            length: 512, flags: 2, next: 0
        )
        let ringSlot = UInt64(4 + (UInt32(availableIndex) % 8) * 2)
        try machine.vm.memory.write16(0, at: availableRing + ringSlot)
        availableIndex &+= 1
        try machine.vm.memory.write16(availableIndex, at: availableRing + 2)
        try machine.vm.writePhysical(base + 0x050, width: .word, value: 0)
        return try machine.vm.memory.readBytes(at: responseAddress, count: responseLength)
    }

    private func makeVirtioGPUCommand(type: UInt32, payload: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = []
        appendLE32(type, to: &bytes)
        appendLE32(0, to: &bytes)
        appendLE64(0, to: &bytes)
        appendLE32(0, to: &bytes)
        appendLE32(0, to: &bytes)
        bytes.append(contentsOf: payload)
        return bytes
    }

    private func appendGPUKitRectangle(x: UInt32, y: UInt32, width: UInt32, height: UInt32, to bytes: inout [UInt8]) {
        appendLE32(x, to: &bytes)
        appendLE32(y, to: &bytes)
        appendLE32(width, to: &bytes)
        appendLE32(height, to: &bytes)
    }

    private func appendLE32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendLE64(_ value: UInt64, to bytes: inout [UInt8]) {
        appendLE32(UInt32(truncatingIfNeeded: value), to: &bytes)
        appendLE32(UInt32(truncatingIfNeeded: value >> 32), to: &bytes)
    }

    private func readLE32ForTest(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private func readBE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 |
            UInt16(bytes[offset + 1])
    }

    private func readBE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }

    private func makeIPv4UDPFrame(
        sourcePort: UInt16,
        destinationIP: [UInt8],
        destinationPort: UInt16,
        payload: [UInt8]
    ) -> [UInt8] {
        var udp: [UInt8] = []
        appendBE16(sourcePort, to: &udp)
        appendBE16(destinationPort, to: &udp)
        appendBE16(UInt16(8 + payload.count), to: &udp)
        appendBE16(0, to: &udp)
        udp += payload
        return makeIPv4EthernetFrame(destinationIP: destinationIP, protocolNumber: 17, payload: udp)
    }

    private func makeIPv4ICMPEchoFrame(destinationIP: [UInt8], payload: [UInt8] = Array("ping".utf8)) -> [UInt8] {
        var icmp: [UInt8] = [8, 0, 0, 0]
        icmp += [0x12, 0x34, 0x00, 0x01]
        icmp += payload
        return makeIPv4EthernetFrame(destinationIP: destinationIP, protocolNumber: 1, payload: icmp)
    }

    private func makeIPv4TCPFrame(
        sourcePort: UInt16,
        destinationIP: [UInt8] = LinkLocalVirtIONetworkBackend.hostIPv4,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: UInt8,
        payload: [UInt8],
        window: UInt16 = 0xffff
    ) -> [UInt8] {
        var tcp: [UInt8] = []
        appendBE16(sourcePort, to: &tcp)
        appendBE16(destinationPort, to: &tcp)
        appendBE32(sequence, to: &tcp)
        appendBE32(acknowledgment, to: &tcp)
        tcp += [0x50, flags]
        appendBE16(window, to: &tcp)
        appendBE16(0, to: &tcp)
        appendBE16(0, to: &tcp)
        tcp += payload
        return makeIPv4EthernetFrame(
            destinationIP: destinationIP,
            protocolNumber: 6,
            payload: tcp
        )
    }

    private func makeIPv4EthernetFrame(destinationIP: [UInt8], protocolNumber: UInt8, payload: [UInt8]) -> [UInt8] {
        let sourceMAC: [UInt8] = [0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]
        var ipHeader: [UInt8] = [0x45, 0x00]
        appendBE16(UInt16(20 + payload.count), to: &ipHeader)
        appendBE16(0, to: &ipHeader)
        appendBE16(0x4000, to: &ipHeader)
        ipHeader += [64, protocolNumber, 0, 0]
        ipHeader += LinkLocalVirtIONetworkBackend.guestIPv4
        ipHeader += destinationIP
        return LinkLocalVirtIONetworkBackend.hostMAC + sourceMAC + [0x08, 0x00] + ipHeader + payload
    }

    private func tcpFlags(_ frame: [UInt8]) -> UInt8 {
        frame[14 + 20 + 13]
    }

    private func tcpPayload(_ frame: [UInt8]) -> [UInt8] {
        let tcpStart = 14 + 20
        let headerLength = Int(frame[tcpStart + 12] >> 4) * 4
        guard frame.count > tcpStart + headerLength else {
            return []
        }
        return Array(frame[(tcpStart + headerLength)..<frame.count])
    }

    private func drainTCPPayload(from backend: LinkLocalVirtIONetworkBackend, sawFin: inout Bool) -> [UInt8] {
        var payload: [UInt8] = []
        while let frame = backend.receive() {
            payload += tcpPayload(frame)
            sawFin = sawFin || (tcpFlags(frame) & 0x01) != 0
        }
        return payload
    }

    private func waitForReceiveFrame(
        from backend: LinkLocalVirtIONetworkBackend,
        timeout: TimeInterval = 1.0
    ) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = backend.receive() {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return nil
    }

    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func appendBE16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private func appendBE32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private final class FakeOutboundTCPConnection: VirtIOOutboundTCPConnection {
        var onReady: (() -> Void)?
        var onReceive: (([UInt8]) -> Void)?
        var onClose: (() -> Void)?
        var onError: ((String) -> Void)?

        private(set) var startCount = 0
        private(set) var sentPayloads: [[UInt8]] = []
        private(set) var cancelCount = 0

        func start() {
            startCount += 1
        }

        func send(_ bytes: [UInt8]) {
            sentPayloads.append(bytes)
        }

        func cancel() {
            cancelCount += 1
        }

        func fireReady() {
            onReady?()
        }

        func fireReceive(_ bytes: [UInt8]) {
            onReceive?(bytes)
        }

        func fireClose() {
            onClose?()
        }
    }

    private final class FakeOutboundNetworkFactory: VirtIOOutboundNetworkFactory {
        var resolvedIPv4ByHost: [String: [UInt8]] = [:]
        var tcpConnection: FakeOutboundTCPConnection?
        var udpResponsePackets: [[UInt8]] = []
        var icmpResponsePayload: [UInt8]?

        private(set) var lastTCPDestinationIP: [UInt8]?
        private(set) var lastTCPDestinationPort: UInt16?
        private(set) var lastUDPPayload: [UInt8]?
        private(set) var lastUDPDestinationIP: [UInt8]?
        private(set) var lastUDPDestinationPort: UInt16?
        private(set) var lastICMPPayload: [UInt8]?
        private(set) var lastICMPDestinationIP: [UInt8]?
        private(set) var lastICMPIdentifier: UInt16?
        private(set) var lastICMPSequenceNumber: UInt16?

        func resolveIPv4Address(for hostname: String) -> [UInt8]? {
            resolvedIPv4ByHost[hostname]
        }

        func makeTCPConnection(to hostIPv4: [UInt8], port: UInt16) -> VirtIOOutboundTCPConnection? {
            lastTCPDestinationIP = hostIPv4
            lastTCPDestinationPort = port
            return tcpConnection
        }

        func sendUDP(payload: [UInt8], to hostIPv4: [UInt8], port: UInt16, completion: @escaping ([[UInt8]]) -> Void) {
            lastUDPPayload = payload
            lastUDPDestinationIP = hostIPv4
            lastUDPDestinationPort = port
            completion(udpResponsePackets)
        }

        func sendICMPEcho(
            payload: [UInt8],
            identifier: UInt16,
            sequenceNumber: UInt16,
            to hostIPv4: [UInt8],
            completion: @escaping ([UInt8]?) -> Void
        ) {
            lastICMPPayload = payload
            lastICMPDestinationIP = hostIPv4
            lastICMPIdentifier = identifier
            lastICMPSequenceNumber = sequenceNumber
            completion(icmpResponsePayload)
        }
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

    private func encodePCRelativeAddress(rd: Int, offset: Int64, page: Bool) -> UInt32 {
        let scaledOffset = page ? offset >> 12 : offset
        let immediate = UInt32(truncatingIfNeeded: scaledOffset) & 0x1f_ffff
        let immlo = (immediate & 0x3) << 29
        let immhi = ((immediate >> 2) & 0x7_ffff) << 5
        return (page ? 0x9000_0000 : 0x1000_0000) | immlo | immhi | UInt32(rd)
    }

    private func encodeLoadLiteral(rt: Int, offset: Int64, opcode: UInt32) -> UInt32 {
        let immediate = UInt32(truncatingIfNeeded: offset >> 2) & 0x7_ffff
        return 0x1800_0000 |
            ((opcode & 0x3) << 30) |
            (immediate << 5) |
            UInt32(rt)
    }

    private func encodeCompareBranch(rt: Int, offset: Int64, nonZero: Bool) -> UInt32 {
        let immediate = UInt32(truncatingIfNeeded: offset >> 2) & 0x7_ffff
        return 0x8000_0000 |
            0x3400_0000 |
            (nonZero ? 0x0100_0000 : 0) |
            (immediate << 5) |
            UInt32(rt)
    }

    private func encodeTestBranch(rt: Int, bit: Int, offset: Int64, nonZero: Bool) -> UInt32 {
        let immediate = UInt32(truncatingIfNeeded: offset >> 2) & 0x3fff
        return 0x3600_0000 |
            (bit >= 32 ? 0x8000_0000 : 0) |
            (nonZero ? 0x0100_0000 : 0) |
            (UInt32(bit & 0x1f) << 19) |
            (immediate << 5) |
            UInt32(rt)
    }

    private func encodeConditionalBranch(offset: Int64, condition: UInt8) -> UInt32 {
        let immediate = UInt32(truncatingIfNeeded: offset >> 2) & 0x7_ffff
        return 0x5400_0000 |
            (immediate << 5) |
            UInt32(condition & 0xf)
    }

    private func encodeAddSubImmediate(rd: Int, rn: Int, immediate: UInt32, subtract: Bool) -> UInt32 {
        (subtract ? 0xd100_0000 : 0x9100_0000) |
            ((immediate & 0xfff) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rd)
    }

    private func encodeAddSubtractWithCarry(
        rd: Int,
        rn: Int,
        rm: Int,
        bits: Int,
        subtract: Bool,
        setFlags: Bool
    ) -> UInt32 {
        var instruction = UInt32(0x1a00_0000)
        if bits == 64 {
            instruction |= 0x8000_0000
        }
        if subtract {
            instruction |= 0x4000_0000
        }
        if setFlags {
            instruction |= 0x2000_0000
        }
        instruction |= UInt32(rm) << 16
        instruction |= UInt32(rn) << 5
        instruction |= UInt32(rd)
        return instruction
    }

    private func encodePairTransfer(base: UInt32, rt: Int, rt2: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        let scaledOffset = offsetBytes / 8
        return base |
            ((UInt32(truncatingIfNeeded: scaledOffset) & 0x7f) << 15) |
            (UInt32(rt2) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeUnsignedImmediateTransfer(base: UInt32, rt: Int, rn: Int, offsetBytes: Int, scale: Int) -> UInt32 {
        let scaledOffset = offsetBytes / scale
        return base |
            ((UInt32(truncatingIfNeeded: scaledOffset) & 0xfff) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeSIMDQTransfer(base: UInt32, rt: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        encodeUnsignedImmediateTransfer(base: base, rt: rt, rn: rn, offsetBytes: offsetBytes, scale: 16)
    }

    private func encodeSIMDScalarByteTransfer(base: UInt32, rt: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        base |
            ((UInt32(offsetBytes) & 0xfff) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeSIMDFPQSignedImmediateTransfer(base: UInt32, rt: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        base |
            ((UInt32(truncatingIfNeeded: offsetBytes) & 0x1ff) << 12) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeSIMDDuplicateGeneral(rd: Int, rn: Int, imm5: UInt32, q: Bool) -> UInt32 {
        0x0e00_0c00 |
            (q ? 0x4000_0000 : 0) |
            ((imm5 & 0x1f) << 16) |
            (UInt32(rn) << 5) |
            UInt32(rd)
    }

    private func encodeSIMDQPairTransfer(base: UInt32, rt: Int, rt2: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        let scaledOffset = offsetBytes / 16
        return base |
            ((UInt32(truncatingIfNeeded: scaledOffset) & 0x7f) << 15) |
            (UInt32(rt2) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeSIMDDPairTransfer(base: UInt32, rt: Int, rt2: Int, rn: Int, offsetBytes: Int) -> UInt32 {
        let scaledOffset = offsetBytes / 8
        return base |
            ((UInt32(truncatingIfNeeded: scaledOffset) & 0x7f) << 15) |
            (UInt32(rt2) << 10) |
            (UInt32(rn) << 5) |
            UInt32(rt)
    }

    private func encodeRegisterBranch(base: UInt32, rn: Int) -> UInt32 {
        base | (UInt32(rn) << 5)
    }

    private func encodeSVC(immediate: UInt16) -> UInt32 {
        0xd400_0001 | (UInt32(immediate) << 5)
    }

    private func encodeBRK(immediate: UInt16) -> UInt32 {
        0xd420_0000 | (UInt32(immediate) << 5)
    }

    private func encodeERET() -> UInt32 {
        0xd69f_03e0
    }

    private func encodeMRS(rt: Int, key: ARM64SystemRegisterKey) -> UInt32 {
        encodeSystemRegisterTransfer(base: 0xd530_0000, rt: rt, key: key)
    }

    private func encodeMSR(rt: Int, key: ARM64SystemRegisterKey) -> UInt32 {
        encodeSystemRegisterTransfer(base: 0xd510_0000, rt: rt, key: key)
    }

    private func encodeSYS(op1: UInt8, crn: UInt8, crm: UInt8, op2: UInt8, rt: Int) -> UInt32 {
        0xd508_0000 |
            (UInt32(op1 & 0x7) << 16) |
            (UInt32(crn & 0xf) << 12) |
            (UInt32(crm & 0xf) << 8) |
            (UInt32(op2 & 0x7) << 5) |
            UInt32(rt)
    }

    private func encodeSystemRegisterTransfer(base: UInt32, rt: Int, key: ARM64SystemRegisterKey) -> UInt32 {
        base |
            (UInt32(key.op0) << 19) |
            (UInt32(key.op1) << 16) |
            (UInt32(key.crn) << 12) |
            (UInt32(key.crm) << 8) |
            (UInt32(key.op2) << 5) |
            UInt32(rt)
    }

    private func encodeDAIFImmediate(mask: UInt8, set: Bool) -> UInt32 {
        0xd503_401f |
            (UInt32(mask & 0xf) << 8) |
            ((set ? UInt32(0x6) : UInt32(0x7)) << 5)
    }

    private func writeSystemRegister(_ key: ARM64SystemRegisterKey, value: UInt64, into vm: VirtualMachine) throws {
        vm.writeSystemRegister(key, value: value)
    }
}
