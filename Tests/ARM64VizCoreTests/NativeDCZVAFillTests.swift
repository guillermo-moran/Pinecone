import ARM64VizNative
import XCTest
@testable import ARM64VizCore

private final class DCZVAFillMemory {
    var bytes: [UInt8]
    var fills: [(address: UInt64, count: UInt64)] = []

    init(count: Int, repeating value: UInt8) {
        bytes = [UInt8](repeating: value, count: count)
    }
}

private let dcZVAFillCallback: AVZNativeMemoryFillCallback = {
    context, virtualAddress, byteCount, pattern, patternWidth in
    guard let context, pattern == 0, patternWidth == 1,
          virtualAddress <= UInt64(Int.max), byteCount <= UInt64(Int.max),
          virtualAddress <= UInt64.max - byteCount else {
        return 0
    }
    let memory = Unmanaged<DCZVAFillMemory>
        .fromOpaque(context)
        .takeUnretainedValue()
    let start = Int(virtualAddress)
    let end = start + Int(byteCount)
    guard start >= 0, end <= memory.bytes.count else {
        return 0
    }
    memory.bytes.replaceSubrange(start..<end, with: repeatElement(0, count: end - start))
    memory.fills.append((virtualAddress, byteCount))
    return 1
}

private let dcZVAIdentityTranslate: AVZNativeMemoryTranslateRAMCallback = {
    _, virtualAddress, _, _, physicalAddress in
    guard let physicalAddress else { return 0 }
    physicalAddress.pointee = virtualAddress
    return 1
}

private let dcZVAFirstPageOnlyTranslate: AVZNativeMemoryTranslateRAMCallback = {
    _, virtualAddress, width, isWrite, physicalAddress in
    guard isWrite != 0, width == 1, virtualAddress < 0x1_000,
          let physicalAddress else { return 0 }
    physicalAddress.pointee = virtualAddress
    return 1
}

final class NativeDCZVAFillTests: XCTestCase {
    func testIsolatedDCZVATranslatedRAMUsesNativeFillWithoutSlowFallback() throws {
        let ramBase: GuestAddress = 0x4000_0000
        let tables = (0..<4).map { ramBase + UInt64($0 + 1) * 0x1_000 }
        let codePhysical = ramBase + 0x10_000
        let dataPhysical = ramBase + 0x11_000
        let memory = PhysicalMemory(base: ramBase, size: 0x20_000)
        for level in 0..<3 {
            try memory.write64(tables[level + 1] | 3, at: tables[level])
        }
        try memory.write64(codePhysical | 0x403, at: tables[3] + 8)
        try memory.write64(dataPhysical | 0x403, at: tables[3] + 16)
        try memory.write32(0xd50b_7428, at: codePhysical) // dc zva, x8
        try memory.write32(0xd440_0000, at: codePhysical + 4) // hlt
        for offset in 0..<128 {
            try memory.write8(0xa5, at: dataPhysical + UInt64(offset))
        }
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeDetailedMemoryStatisticsEnabled(true)
        let vm = VirtualMachine(memory: memory, backend: backend)
        vm.reset(entryPoint: 0x1_000)
        vm.cpu.pstate = 0x3c5 // EL1h, interrupts masked.
        vm.cpu.x[8] = 0x2_011 // Unaligned operand must zero its containing block.
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: tables[0])
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.timerCyclesPerInstruction = 0

        XCTAssertEqual(try vm.run(maxSteps: 4).stopReason, .halted)
        XCTAssertTrue(try (0..<64).allSatisfy {
            try memory.read8(at: dataPhysical + UInt64($0)) == 0
        })
        XCTAssertTrue(try (64..<128).allSatisfy {
            try memory.read8(at: dataPhysical + UInt64($0)) == 0xa5
        })
        XCTAssertGreaterThanOrEqual(backend.nativeFillHits, 1)
        XCTAssertEqual(backend.nativeFillMisses, 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testIsolatedDCZVAPermissionFaultDoesNotMutateReadOnlyPage() throws {
        let ramBase: GuestAddress = 0x4000_0000
        let tables = (0..<4).map { ramBase + UInt64($0 + 1) * 0x1_000 }
        let codePhysical = ramBase + 0x10_000
        let dataPhysical = ramBase + 0x11_000
        let memory = PhysicalMemory(base: ramBase, size: 0x20_000)
        for level in 0..<3 {
            try memory.write64(tables[level + 1] | 3, at: tables[level])
        }
        try memory.write64(codePhysical | 0x403, at: tables[3] + 8)
        try memory.write64(dataPhysical | 0x483, at: tables[3] + 16) // AP[2]: EL1 read-only.
        try memory.write32(0xd50b_7428, at: codePhysical) // dc zva, x8
        for offset in 0..<64 {
            try memory.write8(0xa5, at: dataPhysical + UInt64(offset))
        }

        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeDetailedMemoryStatisticsEnabled(true)
        let vm = VirtualMachine(memory: memory, backend: backend)
        vm.reset(entryPoint: 0x1_000)
        vm.cpu.pstate = 0x3c5 // EL1h, interrupts masked.
        vm.cpu.x[8] = 0x2_011
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: tables[0])
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.timerCyclesPerInstruction = 0

        _ = try vm.run(maxSteps: 1)

        XCTAssertEqual(
            vm.systemRegisters.rawValue(for: ARM64SystemRegister.farEL1),
            0x2_000
        )
        XCTAssertTrue(try (0..<64).allSatisfy {
            try memory.read8(at: dataPhysical + UInt64($0)) == 0xa5
        })
        XCTAssertGreaterThanOrEqual(backend.nativeFillMisses, 1)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testNativeFillCrossPageFailureDoesNotPartiallyMutate() throws {
        var ram = [UInt8](repeating: 0xa5, count: 0x2_000)
        let memory = DCZVAFillMemory(count: 1, repeating: 0)
        let context = Unmanaged.passUnretained(memory).toOpaque()

        try ram.withUnsafeMutableBufferPointer { buffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                buffer.baseAddress,
                0,
                UInt64(buffer.count),
                nil,
                context,
                dcZVAFirstPageOnlyTranslate,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            XCTAssertEqual(
                avz_native_fast_memory_fill(
                    UnsafeMutableRawPointer(fastPath),
                    0x0ff0,
                    32,
                    0,
                    8
                ),
                0
            )
            XCTAssertTrue(buffer[0x0ff0..<0x1010].allSatisfy { $0 == 0xa5 })
        }
    }

    func testSoftwareBackendRoutesIsolatedDCZVAThroughNativeFill() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeDetailedMemoryStatisticsEnabled(true)
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let destination = entry + 0x1_000
        let words: [UInt32] = [
            0xd50b_7428, // dc zva, x8
            0xd503_201f, // nop
            0xd503_201f, // nop
            0xd440_0000, // hlt
        ]
        let program = words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        }

        try machine.vm.loadBinary(program, at: entry)
        for offset in 0..<128 {
            try machine.vm.memory.write8(0xa5, at: destination + UInt64(offset))
        }
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[8] = destination + 17
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0

        let result = try machine.vm.run(maxSteps: 8)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertTrue(try (0..<64).allSatisfy {
            try machine.vm.memory.read8(at: destination + UInt64($0)) == 0
        })
        XCTAssertTrue(try (64..<128).allSatisfy {
            try machine.vm.memory.read8(at: destination + UInt64($0)) == 0xa5
        })
        XCTAssertGreaterThanOrEqual(
            backend.nativeFillHits,
            1,
            "the isolated DC ZVA must enter the native bulk-fill primitive " +
                "(blocks=\(backend.nativeBasicBlockSteps), singles=\(backend.nativeSingleInstructionSteps))"
        )
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    private func decode(_ words: [UInt32]) -> [AVZNativeInstruction] {
        words.map { word in
            var decoded = AVZNativeInstruction()
            XCTAssertNotEqual(avz_native_decode_instruction(word, &decoded), 0)
            return decoded
        }
    }

    private func run(
        maxSteps: UInt64,
        destination: UInt64 = 0x1_000,
        remaining: UInt64 = 4_032
    ) -> (
        result: AVZNativeBlockResult,
        registers: [UInt64],
        pc: UInt64,
        pstate: UInt64,
        memory: DCZVAFillMemory
    ) {
        // Linux arm64 __pi_memset's DC ZVA loop. The register allocation and
        // words are taken from the Lineage kernel image used by this project.
        var instructions = decode([
            0xd50b_7428, // dc zva, x8
            0x8b05_0108, // add x8, x8, x5
            0xeb05_0042, // subs x2, x2, x5
            0x54ff_ffaa  // b.ge 0x8000
        ])
        var registers = [UInt64](repeating: 0, count: 31)
        registers[2] = remaining
        registers[5] = 64
        registers[8] = destination
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8_000
        var pstate: UInt64 = 0x5
        var halted: UInt8 = 0
        let memory = DCZVAFillMemory(count: 0x4_000, repeating: 0xa5)
        let context = Unmanaged.passUnretained(memory).toOpaque()

        let result = instructions.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    0x8_000,
                    maxSteps,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nil,
                    nil,
                    nil,
                    dcZVAFillCallback,
                    context
                )
            }
        }
        return (result, registers, pc, pstate, memory)
    }

    func testLineageKernelDCZVALoopBulkZerosPageExactly() {
        let run = run(maxSteps: 256)

        XCTAssertEqual(run.result.fast_path_hits, 1)
        XCTAssertEqual(run.result.fast_path_steps, 256)
        XCTAssertEqual(run.result.steps, 256)
        XCTAssertEqual(run.pc, 0x8_010)
        XCTAssertEqual(run.registers[8], 0x2_000)
        XCTAssertEqual(run.registers[2], UInt64.max - 63)
        XCTAssertNotEqual(run.pstate & 0x8000_0000, 0, "final subtract sets N")
        XCTAssertEqual(run.memory.fills.count, 1)
        XCTAssertEqual(run.memory.fills.first?.address, 0x1_000)
        XCTAssertEqual(run.memory.fills.first?.count, 4_096)
        XCTAssertTrue(run.memory.bytes[0x0fc0..<0x1000].allSatisfy { $0 == 0xa5 })
        XCTAssertTrue(run.memory.bytes[0x1000..<0x2000].allSatisfy { $0 == 0 })
        XCTAssertTrue(run.memory.bytes[0x2000..<0x2040].allSatisfy { $0 == 0xa5 })
    }

    func testLineageKernelDCZVALoopHonorsExecutionBudget() {
        let run = run(maxSteps: 40)

        // The direct decoded-block API reports an internal loop PC as an
        // outside-block handoff; the cached-chain runner immediately resumes
        // that PC in the same decoded block.
        XCTAssertEqual(run.result.status, UInt32(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK))
        XCTAssertEqual(run.result.fast_path_hits, 1)
        XCTAssertEqual(run.result.fast_path_steps, 40)
        XCTAssertEqual(run.pc, 0x8_000)
        XCTAssertEqual(run.registers[8], 0x1_280)
        XCTAssertEqual(run.registers[2], 3_392)
        XCTAssertEqual(run.memory.fills.count, 1)
        XCTAssertEqual(run.memory.fills.first?.count, 640)
        XCTAssertTrue(run.memory.bytes[0x1000..<0x1280].allSatisfy { $0 == 0 })
        XCTAssertTrue(run.memory.bytes[0x1280..<0x12c0].allSatisfy { $0 == 0xa5 })
    }

    func testDCZVAFastPathRejectsUnalignedDestination() {
        let run = run(maxSteps: 256, destination: 0x1_001)

        XCTAssertEqual(run.result.fast_path_hits, 0)
        XCTAssertEqual(run.result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))
        XCTAssertEqual(run.pc, 0x8_000)
        XCTAssertEqual(run.memory.fills.count, 0)
        XCTAssertTrue(run.memory.bytes.allSatisfy { $0 == 0xa5 })
    }

    func testLineageKernelDCZVALoopUsesNativeFillCallback() throws {
        var instructions = decode([
            0xd50b_7428, 0x8b05_0108, 0xeb05_0042, 0x54ff_ffaa
        ])
        var ram = [UInt8](repeating: 0xa5, count: 0x4_000)
        let slowContext = DCZVAFillMemory(count: 1, repeating: 0)
        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                Unmanaged.passUnretained(slowContext).toOpaque(),
                dcZVAIdentityTranslate,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_detailed_statistics_enabled(fastPath, 1)

            var registers = [UInt64](repeating: 0, count: 31)
            registers[2] = 4_032
            registers[5] = 64
            registers[8] = 0x1_000
            var sp: UInt64 = 0
            var pc: UInt64 = 0x8_000
            var pstate: UInt64 = 0x5
            var halted: UInt8 = 0
            let result = instructions.withUnsafeMutableBufferPointer { instructionBuffer in
                registers.withUnsafeMutableBufferPointer { registerBuffer in
                    avz_native_run_threaded_decoded_block_registers(
                        instructionBuffer.baseAddress,
                        instructionBuffer.count,
                        0x8_000,
                        256,
                        registerBuffer.baseAddress,
                        &sp,
                        &pc,
                        &pstate,
                        &halted,
                        avz_native_fast_memory_read,
                        avz_native_fast_memory_write,
                        avz_native_fast_memory_can_access,
                        avz_native_fast_memory_fill,
                        UnsafeMutableRawPointer(fastPath)
                    )
                }
            }

            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(result.fast_path_hits, 1)
            XCTAssertEqual(result.fast_path_steps, 256)
            XCTAssertEqual(statistics.fill_hits, 1)
            XCTAssertEqual(statistics.fill_misses, 0)
            XCTAssertTrue(ramBuffer[0x1000..<0x2000].allSatisfy { $0 == 0 })
        }
    }
}
