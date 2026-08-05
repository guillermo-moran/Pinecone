import ARM64VizNative
import XCTest

private final class NativeTestMemory {
    private var bytes: [UInt64: UInt8] = [:]

    func read(at address: UInt64, width: UInt8) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<UInt64(width) {
            value |= UInt64(bytes[address + index, default: 0]) << (index * 8)
        }
        return value
    }

    func write(_ value: UInt64, at address: UInt64, width: UInt8) {
        for index in 0..<UInt64(width) {
            bytes[address + index] = UInt8((value >> (index * 8)) & 0xff)
        }
    }
}

private let nativeTestMemoryRead: AVZNativeMemoryReadCallback = { context, virtualAddress, rawWidth, value in
    guard let context, let value, rawWidth > 0, rawWidth <= 8 else {
        return 0
    }
    let memory = Unmanaged<NativeTestMemory>.fromOpaque(context).takeUnretainedValue()
    value.pointee = memory.read(at: virtualAddress, width: rawWidth)
    return 1
}

private let nativeTestMemoryRejectRead: AVZNativeMemoryReadCallback = { _, _, _, _ in
    0
}

private let nativeTestMemoryWrite: AVZNativeMemoryWriteCallback = { context, virtualAddress, rawWidth, value in
    guard let context, rawWidth > 0, rawWidth <= 8 else {
        return 0
    }
    let memory = Unmanaged<NativeTestMemory>.fromOpaque(context).takeUnretainedValue()
    memory.write(value, at: virtualAddress, width: rawWidth)
    return 1
}

private let nativeTestPhysicalMemoryRead: AVZNativePhysicalMemoryReadCallback = {
    context, physicalAddress, rawWidth, value
in
    guard let context, let value, rawWidth > 0, rawWidth <= 8 else {
        return 0
    }
    let memory = Unmanaged<NativeTestMemory>.fromOpaque(context).takeUnretainedValue()
    value.pointee = memory.read(at: physicalAddress, width: rawWidth)
    return 1
}

private let nativeTestPhysicalMemoryWrite: AVZNativePhysicalMemoryWriteCallback = {
    context, physicalAddress, rawWidth, value
in
    guard let context, rawWidth > 0, rawWidth <= 8 else {
        return 0
    }
    let memory = Unmanaged<NativeTestMemory>.fromOpaque(context).takeUnretainedValue()
    memory.write(value, at: physicalAddress, width: rawWidth)
    return 1
}

private let nativeTestMemoryCanAccess: AVZNativeMemoryCanAccessCallback = {
    context, _, rawWidth, _
in
    context != nil && rawWidth > 0 && rawWidth <= 8 ? 1 : 0
}

private let nativeTestMemoryFill: AVZNativeMemoryFillCallback = {
    context, virtualAddress, byteCount, pattern, patternWidth
in
    guard let context, byteCount > 0, patternWidth > 0, patternWidth <= 8,
          byteCount % UInt64(patternWidth) == 0 else {
        return 0
    }
    let memory = Unmanaged<NativeTestMemory>.fromOpaque(context).takeUnretainedValue()
    for offset in stride(
        from: UInt64(0),
        to: byteCount,
        by: Int(patternWidth)
    ) {
        memory.write(pattern, at: virtualAddress + offset, width: patternWidth)
    }
    return 1
}

private let nativeIdentityTranslateRAM: AVZNativeMemoryTranslateRAMCallback = {
    context, virtualAddress, _, _, physicalAddress
in
    guard context != nil, let physicalAddress else {
        return 0
    }
    physicalAddress.pointee = virtualAddress
    return 1
}

private final class NativeTranslationProbe {
    struct Fault: Equatable {
        let virtualAddress: UInt64
        let access: UInt8
        let level: UInt8
        let statusCode: UInt8
    }

    var callbackWalks = 0
    var faults: [Fault] = []
}

private let nativeRejectingTranslationProbe: AVZNativeMemoryTranslateRAMCallback = {
    context, _, _, _, _
in
    guard let context else {
        return 0
    }
    let probe = Unmanaged<NativeTranslationProbe>
        .fromOpaque(context)
        .takeUnretainedValue()
    probe.callbackWalks += 1
    return 0
}

private let nativeTranslationFaultProbe: AVZNativeMemoryTranslationFaultCallback = {
    context, virtualAddress, access, level, statusCode
in
    guard let context else {
        return
    }
    let probe = Unmanaged<NativeTranslationProbe>
        .fromOpaque(context)
        .takeUnretainedValue()
    probe.faults.append(.init(
        virtualAddress: virtualAddress,
        access: access,
        level: level,
        statusCode: statusCode
    ))
}

private func nativeStore64(
    _ value: UInt64,
    in buffer: UnsafeMutableBufferPointer<UInt8>,
    at offset: Int
) {
    for byte in 0..<8 {
        buffer[offset + byte] = UInt8(
            truncatingIfNeeded: value >> UInt64(byte * 8)
        )
    }
}

private func nativeStore32(
    _ value: UInt32,
    in buffer: UnsafeMutableBufferPointer<UInt8>,
    at offset: Int
) {
    for byte in 0..<4 {
        buffer[offset + byte] = UInt8(
            truncatingIfNeeded: value >> UInt32(byte * 8)
        )
    }
}

private final class NativeBlockFetchContext {
    var words: [UInt64: UInt32]
    let virtualBase: UInt64
    let physicalBase: UInt64

    init(words: [UInt32], virtualBase: UInt64 = 0x8000, physicalBase: UInt64 = 0x4000) {
        self.words = Dictionary(uniqueKeysWithValues: words.enumerated().map {
            (virtualBase + UInt64($0.offset * 4), $0.element)
        })
        self.virtualBase = virtualBase
        self.physicalBase = physicalBase
    }
}

private let nativeBlockFetch: AVZNativeInstructionFetchCallback = {
    context,
    virtualAddress,
    physicalAddress,
    instruction
in
    guard let context, let physicalAddress, let instruction else {
        return 0
    }
    let fetch = Unmanaged<NativeBlockFetchContext>.fromOpaque(context).takeUnretainedValue()
    guard let word = fetch.words[virtualAddress], virtualAddress >= fetch.virtualBase else {
        return 0
    }
    physicalAddress.pointee = fetch.physicalBase + (virtualAddress - fetch.virtualBase)
    instruction.pointee = word
    return 1
}

private final class NativeChainCheckpointContext {
    var calls: [(steps: UInt64, blocks: UInt64, totalSteps: UInt64, pc: UInt64)] = []
    let stepLimit: UInt64
    let stopAfterCalls: Int?

    init(stepLimit: UInt64, stopAfterCalls: Int? = nil) {
        self.stepLimit = stepLimit
        self.stopAfterCalls = stopAfterCalls
    }
}

private let nativeChainCheckpoint: AVZNativeChainCheckpointCallback = {
    context, executionSteps, executionBlocks, totalSteps, pc, _, remainingSteps
in
    guard let context else {
        return 0
    }
    let checkpoint = Unmanaged<NativeChainCheckpointContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    checkpoint.calls.append((executionSteps, executionBlocks, totalSteps, pc))
    if let stopAfterCalls = checkpoint.stopAfterCalls,
       checkpoint.calls.count >= stopAfterCalls {
        return 0
    }
    return min(checkpoint.stepLimit, remainingSteps)
}

final class ARM64NativeThreadedInterpreterTests: XCTestCase {
    func testThreadedMemoryCallbackExitIsNotReportedAsUnsupportedInstruction() {
        var decoded = decode([
            0xb940_0002 // ldr w2, [x0]
        ])
        var registers = [UInt64](repeating: 0, count: 31)
        registers[0] = 0x4000
        var sp: UInt64 = 0x8000
        var pc: UInt64 = 0x1000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    1,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRejectRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    nil
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK))
        XCTAssertEqual(result.unsupported_instruction, 0)
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(pc, 0x1000)
    }

    func testThreadedRegister31SemanticsPreserveKernelAndSqueekboardStacks() {
        let program: [UInt32] = [
            0x8b01_03e0, // add x0, xzr, x1
            0xb240_03e2, // orr x2, xzr, #1
            0xa9be_7bfd, // stp x29, x30, [sp, #-0x20]!
            0xf900_0bfc, // str x28, [sp, #0x10]
            0x9100_03fd, // mov x29, sp
            0xd11b_83e9, // sub x9, sp, #0x6e0
            0x9279_e13f, // and sp, x9, #0xffffffffffffff80
            0x9100_03bf, // mov sp, x29
            0xf940_0bfc, // ldr x28, [sp, #0x10]
            0xa8c2_7bfd, // ldp x29, x30, [sp], #0x20
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0x20f8
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[1] = 7
        registers[28] = 0x2828
        registers[29] = 0x2929
        registers[30] = 0x3030

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    16,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(
            result.status,
            UInt32(AVZ_NATIVE_STATUS_HALTED),
            String(format: "unsupported 0x%08x", result.unsupported_instruction)
        )
        XCTAssertEqual(registers[0], 7)
        XCTAssertEqual(registers[2], 1)
        XCTAssertEqual(sp, 0x20f8)
        XCTAssertEqual(registers[28], 0x2828)
        XCTAssertEqual(registers[29], 0x2929)
        XCTAssertEqual(registers[30], 0x3030)
    }

    func testDecodedLogicalImmediateReadsXZRAndWritesSP() {
        var decoded = decode([
            0xb240_03e2, // orr x2, xzr, #1
            0x9279_e13f, // and sp, x9, #0xffffffffffffff80
            0xd440_0000  // hlt #0
        ])
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0xdead_beef
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        registers[9] = 0x20f8

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[2], 1)
        XCTAssertEqual(sp, 0x2080)
    }

    func testFullRegisterRunnerHandlesCPULocalSystemRegistersWithoutCallbacks() {
        var decoded = decode([
            0xd51b_4200, // msr nzcv, x0
            0xd53b_4201, // mrs x1, nzcv
            0xd51b_4222, // msr daif, x2
            0xd53b_4223, // mrs x3, daif
            0xd51b_4404, // msr fpcr, x4
            0xd53b_4405, // mrs x5, fpcr
            0xd51b_4426, // msr fpsr, x6
            0xd53b_4427, // mrs x7, fpsr
            0xd538_4248, // mrs x8, CurrentEL
            0xd440_0000  // hlt #0
        ])
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0x2000
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0x5
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        registers[0] = 0xa000_0000
        registers[2] = 0x3c0
        registers[4] = 0x00c0_0000
        registers[6] = 0x0800_0000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            16,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        XCTAssertEqual(registers[1], 0xa000_0000)
        XCTAssertEqual(registers[3], 0x3c0)
        XCTAssertEqual(registers[5], 0x00c0_0000)
        XCTAssertEqual(registers[7], 0x0800_0000)
        XCTAssertEqual(registers[8], 0x4)
        XCTAssertEqual(pstate & 0xf000_03c0, 0xa000_03c0)
        XCTAssertEqual(fpcr, 0x00c0_0000)
        XCTAssertEqual(fpsr, 0x0800_0000)
    }

    func testThreadedHotScalarFamiliesAvoidGenericDispatch() {
        let program: [UInt32] = [
            0xf862_7820, // ldr x0, [x1, x2, lsl #3]
            0xf825_7883, // str x3, [x4, x5, lsl #3]
            0xc8df_fdac, // ldar x12, [x13]
            0xc89f_fdee, // stlr x14, [x15]
            0xc85f_7e30, // ldxr x16, [x17]
            0xc812_7e33, // stxr w18, x19, [x17]
            0x9ad6_22b4, // lslv x20, x21, x22
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE)
        XCTAssertEqual(Int(decoded[3].kind), AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE)
        XCTAssertEqual(Int(decoded[4].kind), AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE)
        XCTAssertEqual(Int(decoded[5].kind), AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE)
        XCTAssertEqual(Int(decoded[6].kind), AVZ_NATIVE_OP_DATA_PROCESSING_TWO_SOURCE)

        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[1] = 0x1000
        registers[2] = 2
        registers[3] = 0x3333
        registers[4] = 0x2000
        registers[5] = 1
        registers[13] = 0x3000
        registers[14] = 0xeeee
        registers[15] = 0x4000
        registers[17] = 0x5000
        registers[19] = 0x1919
        registers[21] = 3
        registers[22] = 4
        memory.write(0x1010, at: 0x1010, width: 8)
        memory.write(0x3030, at: 0x3000, width: 8)
        memory.write(0x5050, at: 0x5000, width: 8)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    16,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        XCTAssertEqual(registers[0], 0x1010)
        XCTAssertEqual(memory.read(at: 0x2008, width: 8), 0x3333)
        XCTAssertEqual(registers[12], 0x3030)
        XCTAssertEqual(memory.read(at: 0x4000, width: 8), 0xeeee)
        XCTAssertEqual(registers[16], 0x5050)
        XCTAssertEqual(registers[18], 0)
        XCTAssertEqual(memory.read(at: 0x5000, width: 8), 0x1919)
        XCTAssertEqual(registers[20], 48)
    }

    func testThreadedIntegerControlAndArithmeticAvoidGenericDispatch() {
        let program: [UInt32] = [
            0x9a82_0020, // csel x0, x1, x2, eq
            0xd348_3ce6, // ubfx x6, x7, #8, #8
            0xdac0_1128, // clz x8, x9
            0x9b0c_356a, // madd x10, x11, x12, x13
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_CONDITIONAL_SELECT)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_BITFIELD_MOVE)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_DATA_PROCESSING_ONE_SOURCE)
        XCTAssertEqual(Int(decoded[3].kind), AVZ_NATIVE_OP_MULTIPLY_ADD_SUBTRACT)

        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x9000
        var pstate: UInt64 = 0x4000_0000
        var halted: UInt8 = 0
        registers[1] = 0x111
        registers[2] = 0x222
        registers[7] = 0x1234_5678
        registers[9] = 1
        registers[11] = 3
        registers[12] = 4
        registers[13] = 5

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        XCTAssertEqual(registers[0], 0x111)
        XCTAssertEqual(registers[6], 0x56)
        XCTAssertEqual(registers[8], 63)
        XCTAssertEqual(registers[10], 17)
    }

    func testNativeFastPathKeepsThreadRegistersInCAndReportsDirtyWrites() throws {
        var ram = [UInt8](repeating: 0, count: 0x2000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil,
                nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            var state = AVZNativeThreadRegisterState(
                tpidr_el0: 0x1000,
                tpidrro_el0: 0x2000,
                tpidr_el1: 0x3000,
                contextidr_el1: 0x4000,
                dirty_mask: UInt32.max
            )
            avz_native_memory_fast_path_set_thread_registers(fastPath, &state)

            var value: UInt64 = 0
            XCTAssertNotEqual(
                avz_native_fast_read_system_register(
                    UnsafeMutableRawPointer(fastPath),
                    0xd53b_d040, // mrs x0, tpidr_el0
                    0x8000,
                    0,
                    0,
                    &value
                ),
                0
            )
            XCTAssertEqual(value, 0x1000)

            var pstate: UInt64 = 0
            var sp: UInt64 = 0
            XCTAssertNotEqual(
                avz_native_fast_write_system_register(
                    UnsafeMutableRawPointer(fastPath),
                    0xd518_d080, // msr tpidr_el1, x0
                    0x8004,
                    0xfeed_face,
                    &pstate,
                    &sp
                ),
                0
            )

            avz_native_memory_fast_path_get_thread_registers(fastPath, &state)
            XCTAssertEqual(state.tpidr_el1, 0xfeed_face)
            XCTAssertEqual(
                state.dirty_mask,
                UInt32(AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL1)
            )
            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.local_system_register_reads, 1)
            XCTAssertEqual(statistics.local_system_register_writes, 1)
        }
    }

    func testNativeFastPathCachesTranslationsAndFillsAcrossPagesInC() throws {
        var ram = [UInt8](repeating: 0, count: 0x5000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            for address in stride(from: UInt64(0), to: 0x5000, by: 0x1000) {
                var value: UInt64 = 0
                XCTAssertNotEqual(
                    avz_native_fast_memory_read(
                        UnsafeMutableRawPointer(fastPath),
                        address,
                        8,
                        &value
                    ),
                    0
                )
            }
            for address in stride(from: UInt64(0), to: 0x5000, by: 0x1000) {
                var value: UInt64 = 0
                XCTAssertNotEqual(
                    avz_native_fast_memory_read(
                        UnsafeMutableRawPointer(fastPath),
                        address,
                        8,
                        &value
                    ),
                    0
                )
            }

            XCTAssertNotEqual(
                avz_native_fast_memory_fill(
                    UnsafeMutableRawPointer(fastPath),
                    0x0ffc,
                    16,
                    0x4433_2211,
                    4
                ),
                0
            )
            XCTAssertEqual(
                Array(ramBuffer[0x0ffc..<0x100c]),
                [
                    0x11, 0x22, 0x33, 0x44,
                    0x11, 0x22, 0x33, 0x44,
                    0x11, 0x22, 0x33, 0x44,
                    0x11, 0x22, 0x33, 0x44
                ]
            )

            var statistics =
                avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.read_tlb_misses, 5)
            XCTAssertEqual(statistics.read_tlb_hits, 5)
            XCTAssertEqual(statistics.fill_hits, 1)
            XCTAssertEqual(statistics.fill_misses, 0)

            avz_native_memory_fast_path_invalidate_translation(fastPath)
            var value: UInt64 = 0
            XCTAssertNotEqual(
                avz_native_fast_memory_read(
                    UnsafeMutableRawPointer(fastPath),
                    0,
                    8,
                    &value
                ),
                0
            )
            statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.read_tlb_misses, 6)
        }
    }

    func testNativeStage1WalkerHandlesPageMappingsWithoutSwiftTranslation() throws {
        var ram = [UInt8](repeating: 0, count: 0x8000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()

        func store64(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 {
                ram[offset + byte] = UInt8(
                    truncatingIfNeeded: value >> UInt64(byte * 8)
                )
            }
        }

        store64(0x2003, at: 0x1000)
        store64(0x3003, at: 0x2000)
        store64(0x4003, at: 0x3000)
        store64(0x5000 | 0x403, at: 0x4000 + 4 * 8)
        store64(0xd440_0000, at: 0x5000)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeRejectingTranslationProbe
            )
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16,
                ttbr0_el1: 0x1000,
                ttbr1_el1: 0,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            var value: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath),
                0x4000,
                8,
                &value
            ), 0)
            XCTAssertEqual(value, 0xd440_0000)

            var physicalAddress: UInt64 = 0
            var instruction: UInt32 = 0
            XCTAssertNotEqual(avz_native_fast_fetch_instruction(
                UnsafeMutableRawPointer(fastPath),
                0x4000,
                &physicalAddress,
                &instruction
            ), 0)
            XCTAssertEqual(physicalAddress, 0x5000)
            XCTAssertEqual(instruction, 0xd440_0000)

            XCTAssertNotEqual(avz_native_fast_memory_write(
                UnsafeMutableRawPointer(fastPath),
                0x4000,
                4,
                0x1234_5678
            ), 0)
            XCTAssertEqual(
                Array(ramBuffer[0x5000..<0x5004]),
                [0x78, 0x56, 0x34, 0x12]
            )

            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.native_page_table_walks, 3)
            XCTAssertEqual(statistics.native_page_table_faults, 0)
            XCTAssertEqual(statistics.translation_callback_walks, 0)
            XCTAssertEqual(probe.callbackWalks, 0)
            XCTAssertTrue(probe.faults.isEmpty)
        }
    }

    func testNativeStage1WalkerInvalidationRefreshesRemappedPages() throws {
        var ram = [UInt8](repeating: 0, count: 0x8000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()

        func store64(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 {
                ram[offset + byte] = UInt8(
                    truncatingIfNeeded: value >> UInt64(byte * 8)
                )
            }
        }

        store64(0x2003, at: 0x1000)
        store64(0x3003, at: 0x2000)
        store64(0x4003, at: 0x3000)
        store64(0x5000 | 0x403, at: 0x4000 + 4 * 8)
        store64(0x1111, at: 0x5000)
        store64(0x2222, at: 0x6000)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16,
                ttbr0_el1: 0x1000,
                ttbr1_el1: 0,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            var value: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(value, 0x1111)

            nativeStore64(0x6000 | 0x403, in: ramBuffer, at: 0x4000 + 4 * 8)
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(value, 0x1111)

            avz_native_memory_fast_path_invalidate_translation(fastPath)
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(value, 0x2222)
            XCTAssertEqual(
                avz_native_memory_fast_path_statistics(fastPath)
                    .native_page_table_walks,
                2
            )
            XCTAssertEqual(probe.callbackWalks, 0)
        }
    }

    func testNativeStage1WalkerDispatchesCachedPhysicalDeviceAddresses() throws {
        var ram = [UInt8](repeating: 0, count: 0x5000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()
        let firstDevicePage: UInt64 = 0x0900_0000
        let secondDevicePage: UInt64 = 0x0a00_0000

        memory.write(0x1111_2222_3333_4444, at: firstDevicePage, width: 8)
        memory.write(0xaaaa_bbbb_cccc_dddd, at: secondDevicePage, width: 8)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            nativeStore64(0x2003, in: ramBuffer, at: 0x1000)
            nativeStore64(0x3003, in: ramBuffer, at: 0x2000)
            nativeStore64(0x4003, in: ramBuffer, at: 0x3000)
            nativeStore64(
                firstDevicePage | 0x403,
                in: ramBuffer,
                at: 0x4000 + 4 * 8
            )
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nativeTestMemoryRejectRead,
                nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_physical_memory_callbacks(
                fastPath,
                nativeTestPhysicalMemoryRead,
                nativeTestPhysicalMemoryWrite
            )
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16,
                ttbr0_el1: 0x1000,
                ttbr1_el1: 0,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nil
            )

            var value: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(value, 0x1111_2222_3333_4444)
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)

            XCTAssertNotEqual(avz_native_fast_memory_write(
                UnsafeMutableRawPointer(fastPath), 0x4000, 4, 0x1234_5678
            ), 0)
            XCTAssertEqual(memory.read(at: firstDevicePage, width: 4), 0x1234_5678)

            nativeStore64(
                secondDevicePage | 0x403,
                in: ramBuffer,
                at: 0x4000 + 4 * 8
            )
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertNotEqual(value, 0xaaaa_bbbb_cccc_dddd)

            avz_native_memory_fast_path_invalidate_translation(fastPath)
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(value, 0xaaaa_bbbb_cccc_dddd)

            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.native_page_table_walks, 3)
            XCTAssertEqual(statistics.translation_callback_walks, 0)
            XCTAssertEqual(statistics.physical_device_reads, 4)
            XCTAssertEqual(statistics.physical_device_writes, 1)
            XCTAssertGreaterThanOrEqual(statistics.read_tlb_hits, 2)
        }
    }

    func testNativeStage1WalkerReportsAccessAndExecuteFaultsDirectly() throws {
        var ram = [UInt8](repeating: 0, count: 0x7000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()

        func store64(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 {
                ram[offset + byte] = UInt8(
                    truncatingIfNeeded: value >> UInt64(byte * 8)
                )
            }
        }

        store64(0x2003, at: 0x1000)
        store64(0x3003, at: 0x2000)
        store64(0x4003, at: 0x3000)
        store64(0x5003, at: 0x4000 + 4 * 8)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeRejectingTranslationProbe
            )
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16,
                ttbr0_el1: 0x1000,
                ttbr1_el1: 0,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            var value: UInt64 = 0
            XCTAssertEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, &value
            ), 0)
            XCTAssertEqual(probe.faults.last, .init(
                virtualAddress: 0x4000,
                access: UInt8(AVZ_NATIVE_MEMORY_ACCESS_READ),
                level: 3,
                statusCode: 0x0b
            ))

            avz_native_memory_fast_path_clear_translation_fault(fastPath)
            nativeStore64(
                0x5000 | 0x403 | (1 << 7),
                in: ramBuffer,
                at: 0x4000 + 4 * 8
            )
            avz_native_memory_fast_path_invalidate_translation(fastPath)
            XCTAssertEqual(avz_native_fast_memory_write(
                UnsafeMutableRawPointer(fastPath), 0x4000, 8, 1
            ), 0)
            XCTAssertEqual(probe.faults.last?.access, UInt8(AVZ_NATIVE_MEMORY_ACCESS_WRITE))
            XCTAssertEqual(probe.faults.last?.statusCode, 0x0f)

            nativeStore64(
                0x5000 | 0x403 | (UInt64(1) << 53),
                in: ramBuffer,
                at: 0x4000 + 4 * 8
            )
            avz_native_memory_fast_path_invalidate_translation(fastPath)
            var physicalAddress: UInt64 = 0
            var instruction: UInt32 = 0
            XCTAssertEqual(avz_native_fast_fetch_instruction(
                UnsafeMutableRawPointer(fastPath),
                0x4000,
                &physicalAddress,
                &instruction
            ), 0)
            XCTAssertEqual(probe.faults.last?.access, UInt8(AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION))
            XCTAssertEqual(probe.faults.last?.statusCode, 0x0f)
            XCTAssertEqual(probe.callbackWalks, 0)
            XCTAssertEqual(
                avz_native_memory_fast_path_statistics(fastPath)
                    .native_page_table_faults,
                3
            )
        }
    }

    func testNativeStage1WalkerUsesTTBR1AndResolvesBlockMappings() throws {
        var ram = [UInt8](repeating: 0, count: 0x10_000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()
        let virtualAddress: UInt64 = 0xffff_8000_0000_8234

        func store64(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 {
                ram[offset + byte] = UInt8(
                    truncatingIfNeeded: value >> UInt64(byte * 8)
                )
            }
        }

        store64(0x2003, at: 0x1800)
        store64(0x3003, at: 0x2000)
        store64(0x401, at: 0x3000)
        store64(0xfeed_face_cafe_beef, at: 0x8234)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16 | (UInt64(16) << 16),
                ttbr0_el1: 0,
                ttbr1_el1: 0x1000,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            var value: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_read(
                UnsafeMutableRawPointer(fastPath),
                virtualAddress,
                8,
                &value
            ), 0)
            XCTAssertEqual(value, 0xfeed_face_cafe_beef)
            XCTAssertEqual(probe.callbackWalks, 0)
            XCTAssertTrue(probe.faults.isEmpty)
            XCTAssertEqual(
                avz_native_memory_fast_path_statistics(fastPath)
                    .native_page_table_walks,
                1
            )
        }
    }

    func testNativeStage1TLBRetainsAddressSpacesAcrossTTBR0Switches() throws {
        var ram = [UInt8](repeating: 0, count: 0xb000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            nativeStore64(0x2003, in: ramBuffer, at: 0x1000)
            nativeStore64(0x3003, in: ramBuffer, at: 0x2000)
            nativeStore64(0x4003, in: ramBuffer, at: 0x3000)
            nativeStore64(0x9000 | 0x403, in: ramBuffer, at: 0x4000 + 4 * 8)

            nativeStore64(0x6003, in: ramBuffer, at: 0x5000)
            nativeStore64(0x7003, in: ramBuffer, at: 0x6000)
            nativeStore64(0x8003, in: ramBuffer, at: 0x7000)
            nativeStore64(0xa000 | 0x403, in: ramBuffer, at: 0x8000 + 4 * 8)
            nativeStore32(0xd503_201f, in: ramBuffer, at: 0x9000)
            nativeStore32(0xd65f_03c0, in: ramBuffer, at: 0xa000)

            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeRejectingTranslationProbe
            )

            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16,
                ttbr0_el1: 0x1000,
                ttbr1_el1: 0,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            func fetch() -> UInt32 {
                var physicalAddress: UInt64 = 0
                var instruction: UInt32 = 0
                XCTAssertNotEqual(avz_native_fast_fetch_instruction(
                    UnsafeMutableRawPointer(fastPath),
                    0x4000,
                    &physicalAddress,
                    &instruction
                ), 0)
                return instruction
            }

            XCTAssertEqual(fetch(), 0xd503_201f)
            state.ttbr0_el1 = 0x5000
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )
            XCTAssertEqual(fetch(), 0xd65f_03c0)

            state.ttbr0_el1 = 0x1000 | (UInt64(7) << 48)
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )
            XCTAssertEqual(fetch(), 0xd503_201f)

            var statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_tlb_misses, 2)
            XCTAssertEqual(statistics.instruction_tlb_hits, 1)
            XCTAssertEqual(statistics.native_page_table_walks, 2)

            avz_native_memory_fast_path_invalidate_translation(fastPath)
            XCTAssertEqual(fetch(), 0xd503_201f)
            statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_tlb_misses, 3)
            XCTAssertEqual(statistics.native_page_table_walks, 3)
        }
    }

    func testNativeInstructionTLBRetainsPhoshSizedWorkingSet() throws {
        let pageCount = 1_536
        let pageSize = 4_096
        var ram = [UInt8](repeating: 0, count: pageCount * pageSize)

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            for page in 0..<pageCount {
                nativeStore32(
                    0xd503_201f,
                    in: ramBuffer,
                    at: page * pageSize
                )
            }
            let context = UnsafeMutableRawPointer(bitPattern: 1)
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeIdentityTranslateRAM
            )

            func fetch(at virtualAddress: UInt64) {
                var physicalAddress: UInt64 = 0
                var instruction: UInt32 = 0
                XCTAssertNotEqual(avz_native_fast_fetch_instruction(
                    UnsafeMutableRawPointer(fastPath),
                    virtualAddress,
                    &physicalAddress,
                    &instruction
                ), 0)
                XCTAssertEqual(physicalAddress, virtualAddress)
                XCTAssertEqual(instruction, 0xd503_201f)
            }

            for page in 0..<pageCount {
                fetch(at: UInt64(page * pageSize))
            }
            fetch(at: 0)

            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_tlb_misses, UInt64(pageCount))
            XCTAssertEqual(statistics.instruction_tlb_hits, 1)
        }
    }

    func testNativeStage1TLBKeepsKernelEntryAcrossTTBR0AndELChanges() throws {
        var ram = [UInt8](repeating: 0, count: 0x10_000)
        let probe = NativeTranslationProbe()
        let context = Unmanaged.passUnretained(probe).toOpaque()
        let virtualAddress: UInt64 = 0xffff_8000_0000_8230

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            nativeStore64(0x2003, in: ramBuffer, at: 0x1800)
            nativeStore64(0x3003, in: ramBuffer, at: 0x2000)
            nativeStore64(0x401, in: ramBuffer, at: 0x3000)
            nativeStore32(0xd503_201f, in: ramBuffer, at: 0x8230)

            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeRejectingTranslationProbe,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeRejectingTranslationProbe
            )
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: 1,
                tcr_el1: 16 | (UInt64(16) << 16),
                ttbr0_el1: 0x5000,
                ttbr1_el1: 0x1000,
                current_el: 1
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )

            func fetch() {
                var physicalAddress: UInt64 = 0
                var instruction: UInt32 = 0
                XCTAssertNotEqual(avz_native_fast_fetch_instruction(
                    UnsafeMutableRawPointer(fastPath),
                    virtualAddress,
                    &physicalAddress,
                    &instruction
                ), 0)
                XCTAssertEqual(physicalAddress, 0x8230)
                XCTAssertEqual(instruction, 0xd503_201f)
            }

            fetch()
            state.ttbr0_el1 = 0x9000
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )
            fetch()

            state.current_el = 0
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )
            fetch()
            state.current_el = 1
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                nativeTranslationFaultProbe
            )
            fetch()

            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_tlb_misses, 2)
            XCTAssertEqual(statistics.instruction_tlb_hits, 2)
            XCTAssertEqual(statistics.native_page_table_walks, 2)
        }
    }

    func testNativeFastInstructionFetchCachesExecuteTranslationInC() throws {
        var ram = [UInt8](repeating: 0, count: 0x3000)
        let words: [UInt32] = [
            0x9100_0400, // add x0, x0, #1
            0xd65f_03c0  // ret
        ]
        for (wordIndex, word) in words.enumerated() {
            for byteIndex in 0..<MemoryLayout<UInt32>.size {
                ram[0x1000 + wordIndex * 4 + byteIndex] = UInt8(
                    truncatingIfNeeded: word >> UInt32(byteIndex * 8)
                )
            }
        }
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeIdentityTranslateRAM
            )

            for (index, expected) in words.enumerated() {
                var physicalAddress: UInt64 = 0
                var instruction: UInt32 = 0
                XCTAssertNotEqual(
                    avz_native_fast_fetch_instruction(
                        UnsafeMutableRawPointer(fastPath),
                        0x1000 + UInt64(index * 4),
                        &physicalAddress,
                        &instruction
                    ),
                    0
                )
                XCTAssertEqual(physicalAddress, 0x1000 + UInt64(index * 4))
                XCTAssertEqual(instruction, expected)
            }

            var statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_fetch_hits, 2)
            XCTAssertEqual(statistics.instruction_tlb_misses, 1)
            XCTAssertEqual(statistics.instruction_tlb_hits, 1)

            avz_native_memory_fast_path_invalidate_translation(fastPath)
            var physicalAddress: UInt64 = 0
            var instruction: UInt32 = 0
            XCTAssertNotEqual(
                avz_native_fast_fetch_instruction(
                    UnsafeMutableRawPointer(fastPath),
                    0x1000,
                    &physicalAddress,
                    &instruction
                ),
                0
            )
            statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.instruction_tlb_misses, 2)
        }
    }

    func testNativeBlockCacheDecodesAdjacentInstructionsFromPinnedRAM() throws {
        var ram = [UInt8](repeating: 0, count: 0x3000)
        let words: [UInt32] = [
            0x9100_0400, // add x0, x0, #1
            0xd65f_03c0  // ret
        ]
        for (wordIndex, word) in words.enumerated() {
            for byteIndex in 0..<MemoryLayout<UInt32>.size {
                ram[0x1000 + wordIndex * 4 + byteIndex] = UInt8(
                    truncatingIfNeeded: word >> UInt32(byteIndex * 8)
                )
            }
        }
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                cache,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeIdentityTranslateRAM
            )

            var key = AVZNativeBlockKey(
                pc: 0x1000,
                sctlr_el1: 1,
                tcr_el1: 0,
                ttbr0_el1: 0,
                ttbr1_el1: 0,
                current_el: 1
            )
            var status: UInt32 = 0
            var unsupported: UInt32 = 0
            let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                cache,
                &key,
                avz_native_fast_fetch_instruction,
                UnsafeMutableRawPointer(fastPath),
                &status,
                &unsupported
            ))

            XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
            XCTAssertEqual(avz_native_decoded_block_instruction_count(block), 2)
            XCTAssertEqual(avz_native_decoded_block_code_page_count(block), 1)
            XCTAssertEqual(
                avz_native_decoded_block_physical_code_page(block, 0),
                0x1000
            )
            XCTAssertEqual(
                avz_native_decoded_block_host_code_page(block, 0),
                UnsafePointer(ramBuffer.baseAddress!.advanced(by: 0x1000))
            )

            let memoryStatistics =
                avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(memoryStatistics.instruction_fetch_hits, 1)
            XCTAssertEqual(memoryStatistics.instruction_tlb_misses, 1)
            XCTAssertEqual(memoryStatistics.instruction_tlb_hits, 0)
            XCTAssertEqual(
                avz_native_block_cache_statistics(cache).direct_code_fetches,
                1
            )
        }
    }

    func testNativeBlockCacheBatchDecodesConditionalFallthroughBlocks() throws {
        var ram = [UInt8](repeating: 0, count: 0x3000)
        let words: [UInt32] = [
            0x9100_0400, // add x0, x0, #1
            0xb400_0040, // cbz x0, +8
            0x9100_0421, // add x1, x1, #1
            0xb400_0040, // cbz x0, +8
            0x9100_0442, // add x2, x2, #1
            0xd65f_03c0  // ret
        ]
        for (wordIndex, word) in words.enumerated() {
            for byteIndex in 0..<MemoryLayout<UInt32>.size {
                ram[0x1000 + wordIndex * 4 + byteIndex] = UInt8(
                    truncatingIfNeeded: word >> UInt32(byteIndex * 8)
                )
            }
        }
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                cache,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }
            avz_native_memory_fast_path_set_instruction_translator(
                fastPath,
                nativeIdentityTranslateRAM
            )

            var key = AVZNativeBlockKey(
                pc: 0x1000,
                sctlr_el1: 1,
                tcr_el1: 0,
                ttbr0_el1: 0,
                ttbr1_el1: 0,
                current_el: 1
            )
            var status: UInt32 = 0
            var unsupported: UInt32 = 0
            _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                cache,
                &key,
                avz_native_fast_fetch_instruction,
                UnsafeMutableRawPointer(fastPath),
                &status,
                &unsupported
            ))

            var statistics = avz_native_block_cache_statistics(cache)
            XCTAssertEqual(statistics.decodes, 3)
            XCTAssertEqual(statistics.batch_prefetched_blocks, 2)
            XCTAssertEqual(statistics.batch_prefetch_hits, 0)
            XCTAssertEqual(statistics.batch_prefetch_unused, 0)
            XCTAssertEqual(statistics.batch_prefetch_limit, 3)
            XCTAssertEqual(statistics.decode_window_hits, 2)
            XCTAssertEqual(statistics.direct_code_fetches, 5)
            let memoryStatistics =
                avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(memoryStatistics.instruction_fetch_hits, 1)
            XCTAssertEqual(memoryStatistics.instruction_tlb_misses, 1)

            key.pc = 0x1008
            _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                cache,
                &key,
                avz_native_fast_fetch_instruction,
                UnsafeMutableRawPointer(fastPath),
                &status,
                &unsupported
            ))
            statistics = avz_native_block_cache_statistics(cache)
            XCTAssertEqual(statistics.hits, 1)
            XCTAssertEqual(statistics.decodes, 3)
            XCTAssertEqual(statistics.batch_prefetch_hits, 1)
            XCTAssertEqual(statistics.batch_prefetch_unused, 0)
            XCTAssertEqual(statistics.batch_prefetch_limit, 3)

            avz_native_block_cache_invalidate_physical_range(
                cache,
                0x1000,
                UInt64(words.count * MemoryLayout<UInt32>.size)
            )
            for _ in 0..<2_048 {
                key.pc = 0x1000
                _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                    cache,
                    &key,
                    avz_native_fast_fetch_instruction,
                    UnsafeMutableRawPointer(fastPath),
                    &status,
                    &unsupported
                ))
                avz_native_block_cache_invalidate_physical_range(
                    cache,
                    0x1000,
                    UInt64(words.count * MemoryLayout<UInt32>.size)
                )
            }
            statistics = avz_native_block_cache_statistics(cache)
            XCTAssertEqual(statistics.batch_prefetch_hits, 1)
            XCTAssertEqual(statistics.batch_prefetch_unused, 4_095)
            XCTAssertEqual(statistics.batch_prefetch_limit, 1)
            XCTAssertEqual(statistics.batch_prefetch_limit_changes, 1)

            key.pc = 0x1000
            _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                cache,
                &key,
                avz_native_fast_fetch_instruction,
                UnsafeMutableRawPointer(fastPath),
                &status,
                &unsupported
            ))
            statistics = avz_native_block_cache_statistics(cache)
            XCTAssertEqual(statistics.batch_prefetched_blocks, 4_099)
        }
    }

    func testNativeFastPathBulkWriteRetainsValidatedCrossPageSpans() throws {
        var ram = [UInt8](repeating: 0, count: 0x3000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()
        let source = Array(UInt8(0)..<UInt8(32))

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            let wrote = source.withUnsafeBytes { bytes in
                avz_native_fast_memory_write_bytes(
                    UnsafeMutableRawPointer(fastPath),
                    0x0ff0,
                    bytes.baseAddress,
                    bytes.count
                )
            }

            XCTAssertNotEqual(wrote, 0)
            XCTAssertEqual(Array(ramBuffer[0x0ff0..<0x1010]), source)
            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.write_tlb_misses, 2)
            XCTAssertEqual(statistics.write_tlb_hits, 0)
            XCTAssertEqual(statistics.write_hits, 1)
        }
    }

    func testNativeFastPathExecutesInterleavedLD4WithOneTranslation() throws {
        let program: [UInt32] = [
            0x0cdf_0104, // ld4 {v4.8b-v7.8b}, [x8], #32
            0xd440_0000
        ]
        var decoded = decode(program)
        var ram = [UInt8](repeating: 0, count: 0x5000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()
        for index in 0..<32 {
            ram[0x3000 + index] = UInt8(index)
        }

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            var registers = [UInt64](repeating: 0, count: 31)
            var vectorLows = [UInt64](repeating: 0, count: 32)
            var vectorHighs = [UInt64](repeating: 0, count: 32)
            var sp: UInt64 = 0
            var pc: UInt64 = 0x12_000
            var pstate: UInt64 = 0
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var halted: UInt8 = 0
            registers[8] = 0x3000

            let result = decoded.withUnsafeMutableBufferPointer { instructions in
                registers.withUnsafeMutableBufferPointer { registerBuffer in
                    vectorLows.withUnsafeMutableBufferPointer { lowBuffer in
                        vectorHighs.withUnsafeMutableBufferPointer { highBuffer in
                            avz_native_run_threaded_decoded_block_full_registers(
                                instructions.baseAddress,
                                instructions.count,
                                pc,
                                4,
                                registerBuffer.baseAddress,
                                lowBuffer.baseAddress,
                                highBuffer.baseAddress,
                                &sp,
                                &pc,
                                &pstate,
                                &fpcr,
                                &fpsr,
                                &halted,
                                avz_native_fast_memory_read,
                                avz_native_fast_memory_write,
                                avz_native_fast_memory_can_access,
                                nil,
                                UnsafeMutableRawPointer(fastPath)
                            )
                        }
                    }
                }
            }

            XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
            XCTAssertEqual(registers[8], 0x3020)
            XCTAssertEqual(vectorLows[4], 0x1c18_1410_0c08_0400)
            XCTAssertEqual(vectorLows[7], 0x1f1b_1713_0f0b_0703)
            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.read_hits, 1)
            XCTAssertEqual(statistics.read_tlb_misses, 1)
            XCTAssertEqual(statistics.read_tlb_hits, 0)
        }
    }

    func testNativeFastPathExecutesInterleavedST4DirectlyIntoRAM() throws {
        let program: [UInt32] = [
            0x0c9f_0104, // st4 {v4.8b-v7.8b}, [x8], #32
            0xd440_0000
        ]
        var decoded = decode(program)
        var ram = [UInt8](repeating: 0, count: 0x5000)
        let memory = NativeTestMemory()
        let context = Unmanaged.passUnretained(memory).toOpaque()

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress,
                0,
                UInt64(ramBuffer.count),
                nil,
                context,
                nativeIdentityTranslateRAM,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            var registers = [UInt64](repeating: 0, count: 31)
            var vectorLows = [UInt64](repeating: 0, count: 32)
            var vectorHighs = [UInt64](repeating: 0, count: 32)
            var sp: UInt64 = 0
            var pc: UInt64 = 0x12_000
            var pstate: UInt64 = 0
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var halted: UInt8 = 0
            registers[8] = 0x3000
            vectorLows[4] = 0x1c18_1410_0c08_0400
            vectorLows[5] = 0x1d19_1511_0d09_0501
            vectorLows[6] = 0x1e1a_1612_0e0a_0602
            vectorLows[7] = 0x1f1b_1713_0f0b_0703

            let result = decoded.withUnsafeMutableBufferPointer { instructions in
                registers.withUnsafeMutableBufferPointer { registerBuffer in
                    vectorLows.withUnsafeMutableBufferPointer { lowBuffer in
                        vectorHighs.withUnsafeMutableBufferPointer { highBuffer in
                            avz_native_run_threaded_decoded_block_full_registers(
                                instructions.baseAddress,
                                instructions.count,
                                pc,
                                4,
                                registerBuffer.baseAddress,
                                lowBuffer.baseAddress,
                                highBuffer.baseAddress,
                                &sp,
                                &pc,
                                &pstate,
                                &fpcr,
                                &fpsr,
                                &halted,
                                avz_native_fast_memory_read,
                                avz_native_fast_memory_write,
                                avz_native_fast_memory_can_access,
                                nil,
                                UnsafeMutableRawPointer(fastPath)
                            )
                        }
                    }
                }
            }

            XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
            XCTAssertEqual(registers[8], 0x3020)
            XCTAssertEqual(
                Array(ramBuffer[0x3000..<0x3020]),
                Array(UInt8(0)..<UInt8(32))
            )
            let statistics = avz_native_memory_fast_path_statistics(fastPath)
            XCTAssertEqual(statistics.write_hits, 1)
            XCTAssertEqual(statistics.write_tlb_misses, 1)
            XCTAssertEqual(statistics.write_tlb_hits, 0)
        }
    }

    func testNativeDecoderClassifiesLLVMConstructorStackSpill() {
        var instruction = AVZNativeInstruction()

        XCTAssertNotEqual(avz_native_decode_instruction(0xf900_07e5, &instruction), 0)
        XCTAssertEqual(instruction.kind, UInt16(AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE))
        XCTAssertEqual(instruction.rn, 31)
        XCTAssertEqual(instruction.rt, 5)
        XCTAssertEqual(instruction.width, 8)
        XCTAssertEqual(instruction.bits, 64)
        XCTAssertEqual(instruction.flags & 1, 0)
        XCTAssertEqual(instruction.immediate, 8)
    }

    func testNativeDecoderPreservesNegativePCRelativeDisplacements() {
        let cases: [(raw: UInt32, kind: Int, displacement: Int64)] = [
            (0x70ff_ffe0, AVZ_NATIVE_OP_ADR, -1),
            (0xf0ff_ffe0, AVZ_NATIVE_OP_ADR, -4096),
            (0xb4ff_ffe0, AVZ_NATIVE_OP_CBZ, -4),
            (0x3607_ffe0, AVZ_NATIVE_OP_TBZ, -4),
            (0x54ff_ffe0, AVZ_NATIVE_OP_BCOND, -4),
            (0x58ff_ffe0, AVZ_NATIVE_OP_LOAD_LITERAL, -4),
            (0x17ff_ffff, AVZ_NATIVE_OP_BRANCH, -4),
            (0x97ff_ffff, AVZ_NATIVE_OP_BRANCH, -4)
        ]

        for testCase in cases {
            var instruction = AVZNativeInstruction()
            XCTAssertNotEqual(
                avz_native_decode_instruction(testCase.raw, &instruction),
                0,
                String(format: "instruction 0x%08x", testCase.raw)
            )
            XCTAssertEqual(Int(instruction.kind), testCase.kind)
            XCTAssertEqual(instruction.immediate, testCase.displacement)
        }
    }

    func testFullRegisterRunnerTreatsUnscaledPrefetchFamilyAsHints() {
        let program: [UInt32] = [
            0xf881_c020, // prfum pldl1keep, [x1, #28] (live Phosh instruction)
            0xf890_03f5, // prfum pstl3strm, [sp, #-256]
            0xf88f_f3df, // prfum #31, [x30, #255]
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_NOP)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0x2000
        var pc: UInt64 = 0x8_800
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        registers[1] = 0x1000
        registers[30] = 0x3000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 4)
        XCTAssertEqual(registers[1], 0x1000)
        XCTAssertEqual(registers[30], 0x3000)
        XCTAssertEqual(sp, 0x2000)
        XCTAssertEqual(pc, 0x8_810)
    }

    func testNativeDecoderDoesNotAliasLLVMVector26MemoryOperationsToX26() {
        let decoded = decode([
            0xad45_7c1a, // ldp q26, q31, [x0, #0xa0]
            0x3c91_817a, // stur q26, [x11, #-0xe8]
            0x3c85_817a, // stur q26, [x11, #0x58]
            0x3d81_77fa, // str q26, [sp, #0x5d0]
            0x3dc1_4ffa, // ldr q26, [sp, #0x530]
            0x3ca0_689a, // str q26, [x4, x0]
            0xad47_f43a, // ldp q26, q29, [x1, #0xf0]
            0x3c96_813a, // stur q26, [x9, #-0x98]
            0x3c8a_813a, // stur q26, [x9, #0xa8]
            0x3d80_e3fa, // str q26, [sp, #0x380]
            0xad41_641a, // ldp q26, q25, [x0, #0x20]
            0xad01_677a  // stp q26, q25, [x27, #0x20]
        ])

        for instruction in decoded {
            XCTAssertTrue(
                instruction.kind == UInt16(AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE) ||
                    instruction.kind == UInt16(AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR) ||
                    instruction.kind == UInt16(AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET),
                String(format: "0x%08x decoded as native operation %u", instruction.raw, instruction.kind)
            )
        }
    }

    func testThreadedARM64RunnerPreservesLLVMConstructorStackSpill() {
        let program: [UInt32] = [
            0xd102_83ff, // sub sp, sp, #0xa0
            0xaa1a_03e5, // mov x5, x26
            0xf900_07e5, // str x5, [sp, #8]
            0xf940_07e0, // ldr x0, [sp, #8]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0x10a0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let expected: UInt64 = 0xffff_964b_b2e8
        registers[26] = expected

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nil,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(sp, 0x1000)
        XCTAssertEqual(registers[5], expected)
        XCTAssertEqual(registers[0], expected)
        XCTAssertEqual(memory.read(at: 0x1008, width: 8), expected)
    }

    func testFullRegisterRunnerExecutesSIMDRegisterOffsetLoadStore() {
        let program: [UInt32] = [
            0x3ca0_689a, // str q26, [x4, x0]
            0x3ce0_689b, // ldr q27, [x4, x0]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()

        registers[4] = 0x1000
        registers[0] = 0x80
        registers[26] = 0xfeed_face_feed_face
        vectorLows[26] = 0x1122_3344_5566_7788
        vectorHighs[26] = 0x99aa_bbcc_ddee_ff00

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nil,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(registers[26], 0xfeed_face_feed_face)
        XCTAssertEqual(vectorLows[27], vectorLows[26])
        XCTAssertEqual(vectorHighs[27], vectorHighs[26])
        XCTAssertEqual(memory.read(at: 0x1080, width: 8), vectorLows[26])
        XCTAssertEqual(memory.read(at: 0x1088, width: 8), vectorHighs[26])
    }

    func testNativeDecoderClassifiesScalarFPDivideWithoutFallback() {
        let decoded = decode([
            0x1e7e_1800, // fdiv d0, d0, d30
            0x1e23_1822, // fdiv s2, s1, s3
            0x9eaf_0060, // fmov v0.d[1], x3
            0x9eae_00a4, // fmov x4, v5.d[1]
            0x1e2e_101e, // fmov s30, #1.0
            0x6ebf_a7ff, // umaxp v31.4s, v31.4s, v31.4s
            0x4f00_043e, // movi v30.4s, #1
            0x1e62_43ff, // fcvt s31, d31
            0x1e22_c062, // fcvt d2, s3
            0x1e3f_7800, // fminnm s0, s0, s31
            0x1e6e_69ac  // fmaxnm d12, d13, d14
        ])

        XCTAssertEqual(decoded[0].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC))
        XCTAssertEqual(decoded[0].flags & 3, 3)
        XCTAssertEqual(decoded[0].flags & 4, 4)
        XCTAssertEqual(decoded[1].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC))
        XCTAssertEqual(decoded[1].flags & 3, 3)
        XCTAssertEqual(decoded[1].flags & 4, 0)
        XCTAssertEqual(decoded[2].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE))
        XCTAssertEqual(decoded[2].flags, 4)
        XCTAssertEqual(decoded[3].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE))
        XCTAssertEqual(decoded[3].flags, 5)
        XCTAssertEqual(decoded[4].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE))
        XCTAssertEqual(decoded[4].immediate, 0x70)
        XCTAssertEqual(decoded[4].flags, 0)
        XCTAssertEqual(decoded[5].kind, UInt16(AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE))
        XCTAssertEqual(decoded[5].bits, 32)
        XCTAssertEqual(decoded[5].flags, 1)
        XCTAssertEqual(decoded[6].kind, UInt16(AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE))
        XCTAssertEqual(decoded[6].bits, 32)
        XCTAssertEqual(decoded[6].flags, 1)
        XCTAssertEqual(decoded[6].immediate, 1)
        XCTAssertEqual(decoded[7].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION))
        XCTAssertEqual(decoded[7].rd, 31)
        XCTAssertEqual(decoded[7].rn, 31)
        XCTAssertEqual(decoded[7].flags, 0)
        XCTAssertEqual(decoded[8].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION))
        XCTAssertEqual(decoded[8].rd, 2)
        XCTAssertEqual(decoded[8].rn, 3)
        XCTAssertEqual(decoded[8].flags, 1)
        XCTAssertEqual(decoded[9].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_MINMAX))
        XCTAssertEqual(decoded[9].flags, 1)
        XCTAssertEqual(decoded[10].kind, UInt16(AVZ_NATIVE_OP_FP_SCALAR_MINMAX))
        XCTAssertEqual(decoded[10].flags, 4)
    }

    func testFullRegisterRunnerExecutesScalarFPMinMaxFamily() {
        let program: [UInt32] = [
            0x1e3f_7800, // fminnm s0, s0, s31
            0x1e62_6861, // fmaxnm d1, d3, d2
            0x1e25_4884, // fmax s4, s4, s5
            0xd440_0000
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = UInt64(Float.nan.bitPattern)
        vectorLows[31] = UInt64(Float(3.5).bitPattern)
        vectorLows[3] = Double(-0.0).bitPattern
        vectorLows[2] = Double(0.0).bitPattern
        vectorLows[4] = UInt64(Float.nan.bitPattern)
        vectorLows[5] = UInt64(Float(2.0).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(UInt32(vectorLows[0]), Float(3.5).bitPattern)
        XCTAssertEqual(vectorLows[1], Double(0.0).bitPattern)
        XCTAssertTrue(Float(bitPattern: UInt32(vectorLows[4])).isNaN)
    }

    func testFullRegisterRunnerExecutesScalarFPPrecisionConversions() {
        let program: [UInt32] = [
            0x1e62_43ff, // fcvt s31, d31
            0x1e22_c3e0, // fcvt d0, s31
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        vectorLows[31] = Double(12.375).bitPattern
        vectorHighs[31] = 0xfeed_face_feed_face

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nil,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[31], UInt64(Float(12.375).bitPattern))
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(vectorLows[0], Double(Float(12.375)).bitPattern)
        XCTAssertEqual(vectorHighs[0], 0)
    }

    func testFullRegisterRunnerExecutesSIMDFPConvertNarrowWidenFamily() {
        let program: [UInt32] = [
            0x0e61_6bde, // fcvtn v30.2s, v30.2d (live Settings instruction)
            0x4e61_6822, // fcvtn2 v2.4s, v1.2d
            0x0e61_7883, // fcvtl v3.2d, v4.2s
            0x4e61_78c5, // fcvtl2 v5.2d, v6.4s
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[30] = Double(1.5).bitPattern
        vectorHighs[30] = Double(-2.25).bitPattern
        vectorLows[1] = Double(3.75).bitPattern
        vectorHighs[1] = Double(-4.5).bitPattern
        vectorLows[2] = 0x1122_3344_5566_7788
        vectorLows[4] =
            UInt64(Float(5.25).bitPattern) | (UInt64(Float(-6.5).bitPattern) << 32)
        vectorHighs[6] =
            UInt64(Float(7.75).bitPattern) | (UInt64(Float(-8.125).bitPattern) << 32)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(
            vectorLows[30],
            UInt64(Float(1.5).bitPattern) | (UInt64(Float(-2.25).bitPattern) << 32)
        )
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(vectorLows[2], 0x1122_3344_5566_7788)
        XCTAssertEqual(
            vectorHighs[2],
            UInt64(Float(3.75).bitPattern) | (UInt64(Float(-4.5).bitPattern) << 32)
        )
        XCTAssertEqual(vectorLows[3], Double(Float(5.25)).bitPattern)
        XCTAssertEqual(vectorHighs[3], Double(Float(-6.5)).bitPattern)
        XCTAssertEqual(vectorLows[5], Double(Float(7.75)).bitPattern)
        XCTAssertEqual(vectorHighs[5], Double(Float(-8.125)).bitPattern)
    }

    func testNativeDecoderClassifiesSingleStructureLaneLoadStores() {
        let decoded = decode([
            0x0d00_0020, // st1 {v0.b}[0], [x1]
            0x4d00_1c20, // st1 {v0.b}[15], [x1]
            0x0d40_5107, // ld1 {v7.h}[2], [x8]
            0x4d00_9149, // st1 {v9.s}[3], [x10]
            0x4d00_8582, // st1 {v2.d}[1], [x12]
            0x4d9f_8582, // st1 {v2.d}[1], [x12], #8
            0x4dcd_8582  // ld1 {v2.d}[1], [x12], x13
        ])

        for instruction in decoded {
            XCTAssertEqual(
                instruction.kind,
                UInt16(AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE)
            )
        }
        XCTAssertEqual(decoded[0].width, 1)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(decoded[1].width, 1)
        XCTAssertEqual(decoded[1].condition, 15)
        XCTAssertEqual(decoded[2].width, 2)
        XCTAssertEqual(decoded[2].condition, 2)
        XCTAssertEqual(decoded[3].width, 4)
        XCTAssertEqual(decoded[3].condition, 3)
        XCTAssertEqual(decoded[4].width, 8)
        XCTAssertEqual(decoded[4].condition, 1)
        XCTAssertEqual(decoded[5].flags & 8, 8)
        XCTAssertEqual(decoded[5].flags & 16, 0)
        XCTAssertEqual(decoded[6].flags & 1, 1)
        XCTAssertEqual(decoded[6].flags & 8, 8)
        XCTAssertEqual(decoded[6].flags & 16, 16)
    }

    func testFullRegisterRunnerExecutesSingleStructureLaneLoadStoreAndWriteback() {
        let program: [UInt32] = [
            0x4d00_8582, // st1 {v2.d}[1], [x12]
            0x4ddf_8583, // ld1 {v3.d}[1], [x12], #8
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[12] = 0x1200
        vectorLows[2] = 0x1111_2222_3333_4444
        vectorHighs[2] = 0xfeed_face_cafe_beef
        vectorLows[3] = 0xaabb_ccdd_eeff_0011
        vectorHighs[3] = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nil,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(memory.read(at: 0x1200, width: 8), 0xfeed_face_cafe_beef)
        XCTAssertEqual(vectorLows[3], 0xaabb_ccdd_eeff_0011)
        XCTAssertEqual(vectorHighs[3], 0xfeed_face_cafe_beef)
        XCTAssertEqual(registers[12], 0x1208)
    }

    func testNativeBlockCacheDecodesCachesAndInvalidatesByPhysicalPage() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x9100_0400, // add x0, x0, #1
            0xf100_141f, // cmp x0, #5
            0x54ff_ffc1  // b.ne -8
        ])
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0x1234,
            ttbr0_el1: 0x5000,
            ttbr1_el1: 0x6000,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0
        let context = Unmanaged.passUnretained(fetch).toOpaque()

        let first = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &key, nativeBlockFetch, context, &status, &unsupported
        ))
        XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
        XCTAssertEqual(avz_native_decoded_block_instruction_count(first), 3)
        XCTAssertEqual(avz_native_decoded_block_instructions(first)?.pointee.raw, 0x9100_0400)

        let decoded = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &key, nativeBlockFetch, context, &status, &unsupported
        ))
        XCTAssertNotEqual(
            avz_native_decoded_block_code_is_current(cache, decoded),
            0
        )
        var statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.hits, 1)
        XCTAssertEqual(statistics.front_hits, 1)
        XCTAssertEqual(statistics.misses, 1)
        XCTAssertEqual(statistics.decodes, 1)

        fetch.words[0x8000] = 0xd100_0400 // sub x0, x0, #1
        avz_native_block_cache_invalidate_physical_range(cache, 0x4000, 4)
        let replaced = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &key, nativeBlockFetch, context, &status, &unsupported
        ))
        XCTAssertEqual(avz_native_decoded_block_instructions(replaced)?.pointee.raw, 0xd100_0400)
        statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidations, 1)
        XCTAssertEqual(statistics.misses, 2)
        XCTAssertEqual(statistics.decodes, 2)
    }

    func testNativeBlockCacheProjectsPageTableContextByAddressHalf() throws {
        let highPC: UInt64 = 0xffff_8000_0000_8000
        let highFetch = NativeBlockFetchContext(
            words: [0xd503_201f, 0xd65f_03c0],
            virtualBase: highPC,
            physicalBase: 0x4000
        )
        let lowFetch = NativeBlockFetchContext(words: [
            0xd503_201f,
            0xd65f_03c0
        ])
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var status: UInt32 = 0
        var unsupported: UInt32 = 0

        var highKey = AVZNativeBlockKey(
            pc: highPC,
            sctlr_el1: 1,
            tcr_el1: 0x1234,
            ttbr0_el1: 0x5000,
            ttbr1_el1: 0x9000,
            current_el: 1
        )
        let highContext = Unmanaged.passUnretained(highFetch).toOpaque()
        let firstHigh = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &highKey, nativeBlockFetch, highContext, &status, &unsupported
        ))
        highKey.ttbr0_el1 = 0x7000
        highKey.ttbr1_el1 = 0x9000 | (UInt64(11) << 48)
        let secondHigh = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &highKey, nativeBlockFetch, highContext, &status, &unsupported
        ))
        XCTAssertEqual(firstHigh, secondHigh)

        var lowKey = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0x1234,
            ttbr0_el1: 0x5000,
            ttbr1_el1: 0x9000,
            current_el: 0
        )
        let lowContext = Unmanaged.passUnretained(lowFetch).toOpaque()
        let firstLow = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &lowKey, nativeBlockFetch, lowContext, &status, &unsupported
        ))
        lowKey.ttbr0_el1 = 0x7000
        let secondLow = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &lowKey, nativeBlockFetch, lowContext, &status, &unsupported
        ))
        XCTAssertNotEqual(firstLow, secondLow)

        lowKey.ttbr0_el1 = 0x5000 | (UInt64(5) << 48)
        lowKey.ttbr1_el1 = 0xb000
        let asidVariant = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &lowKey, nativeBlockFetch, lowContext, &status, &unsupported
        ))
        XCTAssertEqual(firstLow, asidVariant)

        let statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.hits, 2)
        XCTAssertEqual(statistics.misses, 3)
        XCTAssertEqual(statistics.decodes, 3)
    }

    func testNativeBlockCacheSkipsWritesToPagesWithoutDecodedCode() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x9100_0400, // add x0, x0, #1
            0xd65f_03c0  // ret
        ])
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0
        let context = Unmanaged.passUnretained(fetch).toOpaque()

        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(cache, 0x4000, 0x4000),
            0
        )
        let decoded = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &key, nativeBlockFetch, context, &status, &unsupported
        ))
        XCTAssertNotEqual(
            avz_native_decoded_block_code_is_current(cache, decoded),
            0
        )

        avz_native_block_cache_invalidate_physical_range(cache, 0x7000, 8)
        var statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidation_checks, 1)
        XCTAssertEqual(statistics.invalidation_skips, 1)
        XCTAssertEqual(statistics.invalidations, 0)

        fetch.words[0x8000] = 0xd100_0400 // sub x0, x0, #1
        let globalGeneration = avz_native_block_cache_generation(cache)
        let codeMutationEpoch = avz_native_block_cache_code_mutation_epoch(cache)
        avz_native_block_cache_invalidate_physical_range(cache, 0x4000, 4)
        statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidation_checks, 2)
        XCTAssertEqual(statistics.invalidation_skips, 1)
        XCTAssertEqual(statistics.invalidations, 0)
        XCTAssertEqual(statistics.code_page_generation_bumps, 1)
        XCTAssertEqual(avz_native_block_cache_generation(cache), globalGeneration)
        XCTAssertNotEqual(
            avz_native_block_cache_code_mutation_epoch(cache),
            codeMutationEpoch
        )
        XCTAssertEqual(
            avz_native_decoded_block_code_is_current(cache, decoded),
            0
        )

        avz_native_block_cache_invalidate_physical_range(cache, 0x4000, 4)
        statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidation_checks, 3)
        XCTAssertEqual(statistics.invalidation_skips, 1)
        XCTAssertEqual(statistics.code_page_generation_bumps, 2)

        let replacement = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache, &key, nativeBlockFetch, context, &status, &unsupported
        ))
        XCTAssertEqual(
            avz_native_decoded_block_instructions(replacement)?.pointee.raw,
            0xd100_0400
        )
        XCTAssertNotEqual(
            avz_native_decoded_block_code_is_current(cache, replacement),
            0
        )
        statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidations, 1)
        XCTAssertEqual(statistics.stale_block_discards, 1)
        avz_native_block_cache_invalidate_physical_range(cache, 0x4000, 4)
        statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidation_checks, 4)
        XCTAssertEqual(statistics.invalidation_skips, 1)
        XCTAssertEqual(statistics.invalidations, 1)
        XCTAssertEqual(statistics.code_page_generation_bumps, 3)
    }

    func testNativeExecutionContextChainsCachedBlocksWithoutStateCopies() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x9100_0400, // add x0, x0, #1
            0x1400_03ff  // b 0x9000
        ])
        fetch.words[0x9000] = 0x9100_0800 // add x0, x0, #2
        fetch.words[0x9004] = 0xd440_0000 // hlt #0
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        registers[0] = 10
        registers.withUnsafeBufferPointer { registerBuffer in
            vectorLows.withUnsafeBufferPointer { lowBuffer in
                vectorHighs.withUnsafeBufferPointer { highBuffer in
                    avz_native_execution_context_load(
                        execution,
                        registerBuffer.baseAddress,
                        lowBuffer.baseAddress,
                        highBuffer.baseAddress,
                        0x2000,
                        0x8000,
                        0x5,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0
                    )
                }
            }
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        let result = avz_native_execution_context_run_cached_chain(
            execution,
            cache,
            &key,
            16,
            8,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil
        )

        var sp: UInt64 = 0
        var pc: UInt64 = 0
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var exclusiveAddress: UInt64 = 0
        var exclusiveSize: UInt8 = 0
        var exclusiveValid: UInt8 = 0
        var halted: UInt8 = 0
        registers.withUnsafeMutableBufferPointer { registerBuffer in
            vectorLows.withUnsafeMutableBufferPointer { lowBuffer in
                vectorHighs.withUnsafeMutableBufferPointer { highBuffer in
                    avz_native_execution_context_store(
                        execution,
                        registerBuffer.baseAddress,
                        lowBuffer.baseAddress,
                        highBuffer.baseAddress,
                        &sp,
                        &pc,
                        &pstate,
                        &fpcr,
                        &fpsr,
                        &exclusiveAddress,
                        &exclusiveSize,
                        &exclusiveValid,
                        &halted
                    )
                }
            }
        }

        XCTAssertEqual(result.blocks, 2)
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))
        XCTAssertEqual(result.unsupported_instruction, 0xd440_0000)
        XCTAssertEqual(registers[0], 13)
        XCTAssertEqual(pc, 0x9004)
        XCTAssertEqual(pstate, 0x5)
    }

    func testMappedSuperblockBulkExecutesStorePairFillLoop() throws {
        let fetch = NativeBlockFetchContext(words: [], virtualBase: 0x7ff8)
        fetch.words[0x7ff8] = 0x1400_0002 // b 0x8000
        fetch.words[0x8000] = 0xa881_0401 // stp x1, x1, [x0], #16
        fetch.words[0x8004] = 0xf100_0442 // subs x2, x2, #1
        fetch.words[0x8008] = 0x54ff_ffc1 // b.ne 0x8000
        fetch.words[0x800c] = 0xd440_0000 // hlt #0
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let memory = NativeTestMemory()
        var key = AVZNativeBlockKey(
            pc: 0, sctlr_el1: 1, tcr_el1: 0,
            ttbr0_el1: 0, ttbr1_el1: 0, current_el: 1
        )

        func loadAndRun() -> AVZNativeChainResult {
            let checkpoint = NativeChainCheckpointContext(stepLimit: 512)
            var registers = [UInt64](repeating: 0, count: 31)
            registers[0] = 0x10_000
            registers[1] = 0x1122_3344_5566_7788
            registers[2] = 64
            registers.withUnsafeBufferPointer {
                avz_native_execution_context_load(
                    execution, $0.baseAddress, nil, nil,
                    0x20_000, 0x7ff8, 0x5, 0, 0, 0, 0, 0, 0
                )
            }
            return avz_native_execution_context_run_cached_chain_checkpointed(
                execution, cache, &key, 512, 512, 16, 16,
                nativeChainCheckpoint,
                Unmanaged.passUnretained(checkpoint).toOpaque(),
                nativeBlockFetch,
                Unmanaged.passUnretained(fetch).toOpaque(),
                nil, nil, nil, nativeTestMemoryFill,
                nil, nil, nil, nil, nil, nil,
                Unmanaged.passUnretained(memory).toOpaque()
            )
        }

        _ = loadAndRun()
        let mapped = loadAndRun()

        XCTAssertGreaterThan(mapped.superblock_dispatches, 0)
        XCTAssertEqual(mapped.fast_path_hits, 1)
        XCTAssertEqual(mapped.fast_path_steps, 192)
        XCTAssertEqual(avz_native_execution_context_pc(execution), 0x800c)
        for offset in stride(from: UInt64(0), to: 1_024, by: 8) {
            XCTAssertEqual(
                memory.read(at: 0x10_000 + offset, width: 8),
                0x1122_3344_5566_7788
            )
        }
    }

    func testMappedSuperblockBulkExecutesPixmanSIMDSolidFillLoop() throws {
        let fetch = NativeBlockFetchContext(words: [], virtualBase: 0x8ff8)
        fetch.words[0x8ff8] = 0x1400_0002 // b 0x9000
        fetch.words[0x9000] = 0x0c9f_2840 // st1 {v0.2s-v3.2s}, [x2], #32
        fetch.words[0x9004] = 0xf100_0463 // subs x3, x3, #1
        fetch.words[0x9008] = 0x54ff_ffc1 // b.ne 0x9000
        fetch.words[0x900c] = 0xd440_0000 // hlt #0
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let memory = NativeTestMemory()
        var key = AVZNativeBlockKey(
            pc: 0, sctlr_el1: 1, tcr_el1: 0,
            ttbr0_el1: 0, ttbr1_el1: 0, current_el: 1
        )

        func loadAndRun() -> AVZNativeChainResult {
            let checkpoint = NativeChainCheckpointContext(stepLimit: 512)
            var registers = [UInt64](repeating: 0, count: 31)
            var vectorLows = [UInt64](repeating: 0, count: 32)
            let vectorHighs = [UInt64](repeating: 0, count: 32)
            registers[2] = 0x20_000
            registers[3] = 64
            for vector in 0..<4 {
                vectorLows[vector] = 0xaabb_ccdd_aabb_ccdd
            }
            registers.withUnsafeBufferPointer { registerBuffer in
                vectorLows.withUnsafeBufferPointer { lowBuffer in
                    vectorHighs.withUnsafeBufferPointer { highBuffer in
                        avz_native_execution_context_load(
                            execution,
                            registerBuffer.baseAddress,
                            lowBuffer.baseAddress,
                            highBuffer.baseAddress,
                            0x30_000, 0x8ff8, 0x5, 0, 0, 0, 0, 0, 0
                        )
                    }
                }
            }
            return avz_native_execution_context_run_cached_chain_checkpointed(
                execution, cache, &key, 512, 512, 16, 16,
                nativeChainCheckpoint,
                Unmanaged.passUnretained(checkpoint).toOpaque(),
                nativeBlockFetch,
                Unmanaged.passUnretained(fetch).toOpaque(),
                nil, nil, nil, nativeTestMemoryFill,
                nil, nil, nil, nil, nil, nil,
                Unmanaged.passUnretained(memory).toOpaque()
            )
        }

        _ = loadAndRun()
        let mapped = loadAndRun()

        XCTAssertGreaterThan(mapped.superblock_dispatches, 0)
        XCTAssertEqual(mapped.fast_path_hits, 1)
        XCTAssertEqual(mapped.fast_path_steps, 192)
        XCTAssertEqual(avz_native_execution_context_pc(execution), 0x900c)
        for offset in stride(from: UInt64(0), to: 2_048, by: 8) {
            XCTAssertEqual(
                memory.read(at: 0x20_000 + offset, width: 8),
                0xaabb_ccdd_aabb_ccdd
            )
        }
    }

    func testCheckpointedNativeChainResumesInsideBlockAndAcrossCachedBlocks() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x9100_0400, // add x0, x0, #1
            0x9100_0400, // add x0, x0, #1
            0x1400_03fe  // b 0x9000
        ])
        fetch.words[0x9000] = 0x9100_0800 // add x0, x0, #2
        fetch.words[0x9004] = 0xd440_0000 // hlt #0
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 1)

        var registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution,
            cache,
            &key,
            1,
            16,
            16,
            1,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        var sp: UInt64 = 0
        var pc: UInt64 = 0
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var exclusiveAddress: UInt64 = 0
        var exclusiveSize: UInt8 = 0
        var exclusiveValid: UInt8 = 0
        var halted: UInt8 = 0
        registers.withUnsafeMutableBufferPointer {
            avz_native_execution_context_store(
                execution, $0.baseAddress, nil, nil,
                &sp, &pc, &pstate, &fpcr, &fpsr,
                &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
            )
        }

        XCTAssertEqual(result.steps, 4)
        XCTAssertEqual(result.blocks, 4)
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))
        XCTAssertEqual(result.unsupported_instruction, 0xd440_0000)
        XCTAssertEqual(checkpoint.calls.map(\.steps), [1, 1, 1, 1])
        XCTAssertEqual(checkpoint.calls.map(\.blocks), [1, 1, 1, 1])
        XCTAssertEqual(checkpoint.calls.map(\.pc), [0x8004, 0x8008, 0x9000, 0x9004])
        XCTAssertEqual(registers[0], 4)
    }

    func testCheckpointedNativeChainStopsWhenCheckpointRequestsYield() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x9100_0400, // add x0, x0, #1
            0x1400_03ff  // b 0x9000
        ])
        fetch.words[0x9000] = 0x9100_0800 // add x0, x0, #2
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32, stopAfterCalls: 1)
        let registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution,
            cache,
            &key,
            32,
            32,
            8,
            1,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        XCTAssertEqual(result.blocks, 1)
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(checkpoint.calls.count, 1)
        XCTAssertEqual(avz_native_execution_context_pc(execution), 0x9000)
    }

    func testCheckpointedNativeChainBatchesSchedulerAccounting() throws {
        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8004] = 0x1400_0003 // b 0x8010
        fetch.words[0x8010] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8014] = 0x1400_0003 // b 0x8020
        fetch.words[0x8020] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8024] = 0xd440_0000 // hlt #0
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        let registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution,
            cache,
            &key,
            32,
            32,
            8,
            2,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        XCTAssertEqual(result.blocks, 3)
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))
        XCTAssertEqual(checkpoint.calls.map(\.steps), [4, 1])
        XCTAssertEqual(checkpoint.calls.map(\.blocks), [2, 1])
        XCTAssertEqual(checkpoint.calls.map(\.pc), [0x8020, 0x8024])
    }

    func testCheckpointedNativeChainDirectLinksHotLoopEdges() throws {
        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8004] = 0x1400_0003 // b 0x8010
        fetch.words[0x8010] = 0x9100_0421 // add x1, x1, #1
        fetch.words[0x8014] = 0x17ff_fffb // b 0x8000
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(cache, 0x4000, 0x2000),
            0
        )
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        var registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            64, 32, 16, 16,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        registers.withUnsafeMutableBufferPointer {
            var sp: UInt64 = 0
            var pc: UInt64 = 0
            var pstate: UInt64 = 0
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var exclusiveAddress: UInt64 = 0
            var exclusiveSize: UInt8 = 0
            var exclusiveValid: UInt8 = 0
            var halted: UInt8 = 0
            avz_native_execution_context_store(
                execution, $0.baseAddress, nil, nil,
                &sp, &pc, &pstate, &fpcr, &fpsr,
                &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
            )
        }

        XCTAssertEqual(result.steps, 32)
        XCTAssertEqual(result.blocks, 16)
        XCTAssertGreaterThanOrEqual(
            result.superblock_hits + result.superblock_dispatches,
            1
        )
        XCTAssertGreaterThanOrEqual(result.superblock_blocks, 10)
        XCTAssertGreaterThanOrEqual(result.superblock_dispatches, 1)
        XCTAssertLessThan(result.superblock_dispatches, result.superblock_blocks)
        XCTAssertGreaterThan(
            result.superblock_blocks,
            result.superblock_dispatches * 8
        )
        XCTAssertEqual(result.direct_link_misses, 2)
        XCTAssertEqual(registers[0], 8)
        XCTAssertEqual(registers[1], 8)

        fetch.words[0x9000] = 0x9100_0842 // add x2, x2, #2
        var unrelatedKey = key
        unrelatedKey.pc = 0x9000
        var decodeStatus: UInt32 = 0
        var unsupported: UInt32 = 0
        _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &unrelatedKey,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &decodeStatus,
            &unsupported
        ))
        avz_native_block_cache_invalidate_physical_range(cache, 0x5000, 4)

        registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        let reused = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            8, 4, 2, 2,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        XCTAssertGreaterThanOrEqual(reused.superblock_hits, 1)
        XCTAssertGreaterThanOrEqual(reused.superblock_front_hits, 1)
    }

    func testCheckpointedNativeChainReusesKernelTraceAcrossTTBR0Switch() throws {
        let highPC: UInt64 = 0xffff_8000_0000_8000
        let fetch = NativeBlockFetchContext(
            words: [],
            virtualBase: highPC,
            physicalBase: 0x4000
        )
        fetch.words[highPC] = 0x9100_0400 // add x0, x0, #1
        fetch.words[highPC + 4] = 0x1400_0003 // b +12
        fetch.words[highPC + 16] = 0x9100_0421 // add x1, x1, #1
        fetch.words[highPC + 20] = 0x17ff_fffb // b -20

        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(
                cache,
                0x4000,
                0x2000
            ),
            0
        )
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        let registers = [UInt64](repeating: 0, count: 31)
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0x1234,
            ttbr0_el1: 0x5000,
            ttbr1_el1: 0x9000,
            current_el: 1
        )

        func loadCPU() {
            registers.withUnsafeBufferPointer {
                avz_native_execution_context_load(
                    execution, $0.baseAddress, nil, nil,
                    0x2000, highPC, 0x5, 0, 0, 0, 0, 0, 0
                )
            }
        }

        loadCPU()
        let first = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            64, 32, 16, 16,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        XCTAssertGreaterThanOrEqual(first.superblock_dispatches, 1)

        loadCPU()
        key.ttbr0_el1 = 0x7000
        key.ttbr1_el1 = 0x9000 | (UInt64(9) << 48)
        let reused = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            8, 4, 2, 2,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        XCTAssertGreaterThanOrEqual(reused.superblock_hits, 1)
        XCTAssertEqual(
            avz_native_block_cache_statistics(cache).decodes,
            2
        )
    }

    func testSuperblockSurvivesDecodedBlockCacheEviction() throws {
        func mix(_ input: UInt64) -> UInt64 {
            var value = input
            value ^= value >> 30
            value &*= 0xbf58_476d_1ce4_e5b9
            value ^= value >> 27
            value &*= 0x94d0_49bb_1331_11eb
            value ^= value >> 31
            return value
        }
        func blockCacheSet(for pc: UInt64) -> UInt64 {
            // This test key's two nonzero context fields cancel before hashing.
            mix(mix(pc)) & 2_047
        }

        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8004] = 0x1400_0003 // b 0x8010
        fetch.words[0x8010] = 0x9100_0421 // add x1, x1, #1
        fetch.words[0x8014] = 0x17ff_fffb // b 0x8000

        let targetSet = blockCacheSet(for: 0x8000)
        var collidingAddresses: [UInt64] = []
        for index in 0..<100_000 where collidingAddresses.count < 4 {
            let address = 0x10_000 + UInt64(index) * 0x100
            if blockCacheSet(for: address) == targetSet {
                collidingAddresses.append(address)
                fetch.words[address] = 0x1400_0000 // b .
            }
        }
        XCTAssertEqual(collidingAddresses.count, 4)

        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(
                cache,
                0x4000,
                0x20_0000
            ),
            0
        )
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 64)
        var registers = [UInt64](repeating: 0, count: 31)
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        let trained = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            64, 32, 16, 16,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        XCTAssertGreaterThanOrEqual(trained.superblock_dispatches, 1)

        var headKey = key
        headKey.pc = 0x8000
        var decodeStatus: UInt32 = 0
        var unsupported: UInt32 = 0
        let originalHead = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &headKey,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &decodeStatus,
            &unsupported
        ))
        let originalSerial = avz_native_decoded_block_serial(cache, originalHead)
        XCTAssertNotEqual(originalSerial, 0)

        for address in collidingAddresses {
            var collisionKey = key
            collisionKey.pc = address
            _ = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                cache,
                &collisionKey,
                nativeBlockFetch,
                Unmanaged.passUnretained(fetch).toOpaque(),
                &decodeStatus,
                &unsupported
            ))
        }
        XCTAssertEqual(
            avz_native_block_cache_validate_block(
                cache,
                originalHead,
                originalSerial,
                &headKey
            ),
            0
        )

        registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        let reused = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            16, 8, 4, 4,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        XCTAssertGreaterThanOrEqual(reused.superblock_hits, 1)
        XCTAssertEqual(reused.steps, 8)
    }

    func testDirectLinkSetRetainsBothConditionalBranchSuccessors() throws {
        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0x3600_0080 // tbz x0, #0, 0x8010
        fetch.words[0x8004] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8008] = 0x17ff_fffe // b 0x8000
        fetch.words[0x8010] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8014] = 0x17ff_fffb // b 0x8000
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 128)
        let registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            128, 64, 32, 32,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        XCTAssertEqual(result.steps, 48)
        XCTAssertGreaterThan(result.direct_link_hits, result.direct_link_misses)
        XCTAssertGreaterThanOrEqual(result.direct_link_hits, 7)
        XCTAssertEqual(result.direct_link_misses, 3)
    }

    func testSuperblockCacheRetainsFourCollidingTraceKeys() throws {
        func mix(_ input: UInt64) -> UInt64 {
            var value = input
            value ^= value >> 30
            value &*= 0xbf58_476d_1ce4_e5b9
            value ^= value >> 27
            value &*= 0x94d0_49bb_1331_11eb
            value ^= value >> 31
            return value
        }
        func traceSet(for pc: UInt64) -> UInt64 {
            (mix(pc) ^ mix(1) ^ mix(1)) & 63
        }

        var addressesBySet: [UInt64: [UInt64]] = [:]
        var collidingAddresses: [UInt64] = []
        for index in 0..<1_024 where collidingAddresses.isEmpty {
            let address = 0x10_000 + UInt64(index) * 0x100
            let set = traceSet(for: address)
            addressesBySet[set, default: []].append(address)
            if addressesBySet[set]!.count == 4 {
                collidingAddresses = addressesBySet[set]!
            }
        }
        XCTAssertEqual(collidingAddresses.count, 4)

        let fetch = NativeBlockFetchContext(
            words: [],
            virtualBase: 0x10_000,
            physicalBase: 0x20_000
        )
        for address in collidingAddresses {
            fetch.words[address] = 0x9100_0400 // add x0, x0, #1
            fetch.words[address + 4] = 0x1400_0007 // b to second block
            fetch.words[address + 0x20] = 0x9100_0421 // add x1, x1, #1
            fetch.words[address + 0x24] = 0x17ff_fff7 // b to first block
        }
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        let registers = [UInt64](repeating: 0, count: 31)
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        func run(at pc: UInt64) -> AVZNativeChainResult {
            registers.withUnsafeBufferPointer {
                avz_native_execution_context_load(
                    execution, $0.baseAddress, nil, nil,
                    0x3000, pc, 0x5, 0, 0, 0, 0, 0, 0
                )
            }
            return avz_native_execution_context_run_cached_chain_checkpointed(
                execution, cache, &key,
                32, 16, 16, 16,
                nativeChainCheckpoint,
                Unmanaged.passUnretained(checkpoint).toOpaque(),
                nativeBlockFetch,
                Unmanaged.passUnretained(fetch).toOpaque(),
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            )
        }

        for address in collidingAddresses {
            let trained = run(at: address)
            XCTAssertGreaterThanOrEqual(trained.superblock_dispatches, 1)
        }
        for address in collidingAddresses {
            let reused = run(at: address)
            XCTAssertGreaterThanOrEqual(reused.superblock_hits, 1)
        }
    }

    func testFusedSuperblockSideExitsWhenConditionalBranchChangesDirection() throws {
        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0xb400_0080 // cbz x0, 0x8010
        fetch.words[0x8004] = 0xd440_0000 // hlt #0
        fetch.words[0x8010] = 0x9100_0421 // add x1, x1, #1
        fetch.words[0x8014] = 0x17ff_fffb // b 0x8000
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        var registers = [UInt64](repeating: 0, count: 31)
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        _ = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            32, 12, 8, 8,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )

        registers = [UInt64](repeating: 0, count: 31)
        registers[0] = 1
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution, $0.baseAddress, nil, nil,
                0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
            )
        }
        let result = avz_native_execution_context_run_cached_chain_checkpointed(
            execution, cache, &key,
            32, 4, 4, 4,
            nativeChainCheckpoint,
            Unmanaged.passUnretained(checkpoint).toOpaque(),
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        )
        registers.withUnsafeMutableBufferPointer {
            var sp: UInt64 = 0
            var pc: UInt64 = 0
            var pstate: UInt64 = 0
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var exclusiveAddress: UInt64 = 0
            var exclusiveSize: UInt8 = 0
            var exclusiveValid: UInt8 = 0
            var halted: UInt8 = 0
            avz_native_execution_context_store(
                execution, $0.baseAddress, nil, nil,
                &sp, &pc, &pstate, &fpcr, &fpsr,
                &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
            )
        }

        XCTAssertEqual(
            result.status,
            UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED)
        )
        XCTAssertEqual(result.unsupported_instruction, 0xd440_0000)
        XCTAssertGreaterThanOrEqual(result.superblock_dispatches, 1)
        XCTAssertEqual(registers[1], 0)
    }

    func testCheckpointedNativeChainRejectsInvalidatedDirectLinkTarget() throws {
        let fetch = NativeBlockFetchContext(words: [])
        fetch.words[0x8000] = 0x9100_0400 // add x0, x0, #1
        fetch.words[0x8004] = 0x1400_0003 // b 0x8010
        fetch.words[0x8010] = 0x9100_0421 // add x1, x1, #1
        fetch.words[0x8014] = 0x17ff_fffb // b 0x8000
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(cache, 0x4000, 0x1000),
            0
        )
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let checkpoint = NativeChainCheckpointContext(stepLimit: 32)
        var registers = [UInt64](repeating: 0, count: 31)
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )

        func loadExecution() {
            registers.withUnsafeBufferPointer {
                avz_native_execution_context_load(
                    execution, $0.baseAddress, nil, nil,
                    0x2000, 0x8000, 0x5, 0, 0, 0, 0, 0, 0
                )
            }
        }
        func runLoop() -> AVZNativeChainResult {
            avz_native_execution_context_run_cached_chain_checkpointed(
                execution, cache, &key,
                32, 8, 4, 4,
                nativeChainCheckpoint,
                Unmanaged.passUnretained(checkpoint).toOpaque(),
                nativeBlockFetch,
                Unmanaged.passUnretained(fetch).toOpaque(),
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            )
        }
        func storeExecution() {
            registers.withUnsafeMutableBufferPointer {
                var sp: UInt64 = 0
                var pc: UInt64 = 0
                var pstate: UInt64 = 0
                var fpcr: UInt64 = 0
                var fpsr: UInt64 = 0
                var exclusiveAddress: UInt64 = 0
                var exclusiveSize: UInt8 = 0
                var exclusiveValid: UInt8 = 0
                var halted: UInt8 = 0
                avz_native_execution_context_store(
                    execution, $0.baseAddress, nil, nil,
                    &sp, &pc, &pstate, &fpcr, &fpsr,
                    &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
                )
            }
        }

        loadExecution()
        _ = runLoop()
        storeExecution()
        XCTAssertEqual(registers[1], 2)

        fetch.words[0x8010] = 0x9100_0821 // add x1, x1, #2
        avz_native_block_cache_invalidate_physical_range(cache, 0x4010, 4)
        loadExecution()
        let result = runLoop()
        storeExecution()

        XCTAssertGreaterThanOrEqual(result.direct_link_misses, 1)
        XCTAssertEqual(result.superblock_hits, 0)
        XCTAssertEqual(registers[0], 4)
        XCTAssertEqual(registers[1], 6)
        let statistics = avz_native_block_cache_statistics(cache)
        XCTAssertEqual(statistics.invalidations, 2)
        XCTAssertEqual(statistics.stale_block_discards, 2)
        XCTAssertEqual(statistics.code_page_generation_bumps, 1)
    }

    func testNativeExecutionContextStopsChainAtSystemRegisterBarrier() throws {
        let fetch = NativeBlockFetchContext(words: [
            0xd538_4241, // mrs x1, CurrentEL
            0x1400_03ff  // b 0x9000
        ])
        fetch.words[0x9000] = 0x9100_0400 // add x0, x0, #1
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let registers = [UInt64](repeating: 0, count: 31)
        registers.withUnsafeBufferPointer {
            avz_native_execution_context_load(
                execution,
                $0.baseAddress,
                nil,
                nil,
                0x2000,
                0x8000,
                0x5,
                0,
                0,
                0,
                0,
                0,
                0
            )
        }
        var key = AVZNativeBlockKey(
            pc: 0,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        let result = avz_native_execution_context_run_cached_chain(
            execution,
            cache,
            &key,
            16,
            8,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil
        )

        XCTAssertEqual(result.blocks, 1)
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK))
        XCTAssertEqual(avz_native_execution_context_pc(execution), 0x9000)
        XCTAssertEqual(avz_native_execution_context_pstate(execution), 0x5)
    }

    func testNativeBlockCacheDecodesWaitAsTerminatingBlock() throws {
        let fetch = NativeBlockFetchContext(words: [0xd503_205f]) // WFE
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0

        let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &key,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &status,
            &unsupported
        ))
        XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
        XCTAssertEqual(unsupported, 0)
        XCTAssertEqual(avz_native_decoded_block_instruction_count(block), 1)
        XCTAssertEqual(
            avz_native_decoded_block_instructions(block)?.pointee.kind,
            UInt16(AVZ_NATIVE_OP_WAIT)
        )
    }

    func testNativeBlockCacheDecodesCageDoubleMultiplyWithVectorState() throws {
        let fetch = NativeBlockFetchContext(words: [0x1e78_083c]) // fmul d28, d1, d24
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0

        let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &key,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &status,
            &unsupported
        ))
        XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
        XCTAssertEqual(unsupported, 0)
        XCTAssertEqual(avz_native_decoded_block_instruction_count(block), 1)
        XCTAssertEqual(
            avz_native_decoded_block_instructions(block)?.pointee.kind,
            UInt16(AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC)
        )
        XCTAssertNotEqual(avz_native_decoded_block_uses_vector_state(block), 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = (3.0 as Double).bitPattern
        vectorLows[24] = (4.0 as Double).bitPattern
        let instructions = try XCTUnwrap(avz_native_decoded_block_instructions(block))
        let result = registers.withUnsafeMutableBufferPointer { registerBuffer in
            vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                    avz_native_run_threaded_decoded_block_full_registers(
                        instructions,
                        1,
                        0x8000,
                        1,
                        registerBuffer.baseAddress,
                        vectorLowBuffer.baseAddress,
                        vectorHighBuffer.baseAddress,
                        &sp,
                        &pc,
                        &pstate,
                        &fpcr,
                        &fpsr,
                        &halted,
                        nil,
                        nil,
                        nil,
                        nil,
                        nil
                    )
                }
            }
        }
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_MAX_STEPS))
        XCTAssertEqual(result.unsupported_instruction, 0)
        XCTAssertEqual(Double(bitPattern: vectorLows[28]), 12.0)
    }

    func testNativeBlockCacheMarksSIMDBitwiseSelectAsUsingVectorState() throws {
        let fetch = NativeBlockFetchContext(words: [
            0x6e7e_1fbf // bsl.16b v31, v29, v30
        ])
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x8000,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0

        let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &key,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &status,
            &unsupported
        ))

        XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
        XCTAssertEqual(unsupported, 0)
        XCTAssertEqual(
            avz_native_decoded_block_instructions(block)?.pointee.kind,
            UInt16(AVZ_NATIVE_OP_SIMD_ORR_VECTOR)
        )
        XCTAssertNotEqual(avz_native_decoded_block_uses_vector_state(block), 0)
    }

    func testThreadedARM64RunnerExecutesCachedStyleLoop() {
        let program: [UInt32] = [
            0x9100_0400, // add x0, x0, #1
            0xf100_141f, // cmp x0, #5
            0x54ff_ffc1, // b.ne -8
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    32,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 16)
        XCTAssertEqual(registers[0], 5)
        XCTAssertEqual(pc, 0x8010)
        XCTAssertEqual(pstate & 0x4000_0000, 0x4000_0000)
        XCTAssertEqual(halted, 1)
    }

    func testThreadedARM64RunnerReportsUnsupportedInstruction() {
        var unsupported = AVZNativeInstruction()
        unsupported.raw = 0xffff_ffff
        var decoded = [unsupported]
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x4000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    1,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.unsupported_instruction, 0xffff_ffff)
        XCTAssertEqual(pc, 0x4000)
    }

    func testThreadedARM64RunnerExecutesSignedImmediateStoreZeroRegister() {
        let program: [UInt32] = [
            0xf800_081f, // stur xzr, [x0]
            0xf940_0001, // ldr x1, [x0]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x6000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let dataAddress: UInt64 = 0x1000
        memory.write(0x1122_3344_5566_7788, at: dataAddress, width: 8)
        registers[0] = dataAddress

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nil,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(registers[1], 0)
        XCTAssertEqual(memory.read(at: dataAddress, width: 8), 0)
        XCTAssertEqual(pc, 0x600c)
    }

    func testThreadedARM64RunnerExecutesUnalignedSignedImmediateDoublewordStore() {
        let program: [UInt32] = [
            0xf800_c269, // stur x9, [x19, #12]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE)
        XCTAssertEqual(decoded[0].rn, 19)
        XCTAssertEqual(decoded[0].rt, 9)
        XCTAssertEqual(decoded[0].width, 8)
        XCTAssertEqual(decoded[0].immediate, 12)

        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x6000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let structureAddress: UInt64 = 0x1000
        registers[9] = 1
        registers[19] = structureAddress
        memory.write(UInt64.max, at: structureAddress + 12, width: 8)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nil,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(memory.read(at: structureAddress + 12, width: 8), 1)
        XCTAssertEqual(memory.read(at: structureAddress + 12, width: 4), 1)
        XCTAssertEqual(memory.read(at: structureAddress + 16, width: 4), 0)
    }

    func testThreadedARM64RunnerPreservesUpperWordThroughLinuxCopyToUserSequence() {
        let program: [UInt32] = [
            0xa8c1_2027, // ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x7000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let source: UInt64 = 0x1000
        let destination: UInt64 = 0x2000
        memory.write(0x0000_0001_0000_0026, at: source, width: 8)
        memory.write(0x0000_0001_0000_0000, at: source + 8, width: 8)
        registers[1] = source
        registers[6] = destination

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    8,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[7], 0x0000_0001_0000_0026)
        XCTAssertEqual(registers[8], 0x0000_0001_0000_0000)
        XCTAssertEqual(memory.read(at: destination, width: 8), 0x0000_0001_0000_0026)
        XCTAssertEqual(memory.read(at: destination + 8, width: 8), 0x0000_0001_0000_0000)
    }

    func testThreadedARM64RunnerExecutesAlignedLinuxCopyToUserControlPath() {
        let program: [UInt32] = [
            0xf27c_0443, // ands x3, x2, #0x30
            0x5400_0200, // b.eq tail
            0x7100_807f, // cmp w3, #0x20
            0x5400_00c0, // b.eq copy32
            0x5400_012b, // b.lt copy16
            0xa8c1_2027, // ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0x9100_40c6, // add x6, x6, #16
            0xa8c1_2027, // copy32: ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0x9100_40c6, // add x6, x6, #16
            0xa8c1_2027, // copy16: ldp x7, x8, [x1], #16
            0xf800_08c7, // sttr x7, [x6]
            0xf800_88c8, // sttr x8, [x6, #8]
            0x9100_40c6, // add x6, x6, #16
            0xd440_0000  // tail: hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let source: UInt64 = 0x1000
        let destination: UInt64 = 0x2000
        let words: [UInt64] = [
            0x0000_0023_0000_0021,
            0x0000_0001_0000_0026,
            0x0000_0001_0000_0000,
            0x0000_ffff_1234_5678
        ]
        for (index, word) in words.enumerated() {
            memory.write(word, at: source + UInt64(index * 8), width: 8)
        }
        registers[1] = source
        registers[2] = 32
        registers[6] = destination

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    32,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        for (index, word) in words.enumerated() {
            XCTAssertEqual(memory.read(at: destination + UInt64(index * 8), width: 8), word)
        }
    }

    func testThreadedARM64RunnerComputesDRMIoctlBufferSizes() {
        let program: [UInt32] = [
            0x5310_768a, // ubfx w10, w20, #16, #14
            0xb940_02e8, // ldr w8, [x23]
            0x0a14_0109, // and w9, w8, w20
            0x5310_7508, // ubfx w8, w8, #16, #14
            0x531f_792b, // lsl w11, w9, #1
            0x0a89_7d58, // and w24, w10, w9, asr #31
            0x0a8b_7d59, // and w25, w10, w11, asr #31
            0x6b18_033f, // cmp w25, w24
            0x1a98_8329, // csel w9, w25, w24, hi
            0x6b08_013f, // cmp w9, w8
            0x1a88_813a, // csel w26, w9, w8, hi
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x9000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let descriptor: UInt64 = 0x1000
        let command: UInt64 = 0xc020_64b6
        registers[20] = command
        registers[23] = descriptor
        memory.write(command, at: descriptor, width: 4)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionBuffer.baseAddress,
                    instructionBuffer.count,
                    pc,
                    24,
                    registerBuffer.baseAddress,
                    &sp,
                    &pc,
                    &pstate,
                    &halted,
                    nativeTestMemoryRead,
                    nativeTestMemoryWrite,
                    nativeTestMemoryCanAccess,
                    nil,
                    Unmanaged.passUnretained(memory).toOpaque()
                )
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[10], 32)
        XCTAssertEqual(registers[24], 32)
        XCTAssertEqual(registers[25], 32)
        XCTAssertEqual(registers[26], 32)
    }

    func testFullRegisterRunnerCopiesLibDRMPlaneMaskThroughScalarDRegister() {
        let program: [UInt32] = [
            0xfc41_43ff, // ldur d31, [sp, #20]
            0xfc02_c2bf, // stur d31, [x21, #44]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE)
        XCTAssertEqual(decoded[0].width, 8)
        XCTAssertEqual(decoded[0].immediate, 20)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE)
        XCTAssertEqual(decoded[1].width, 8)
        XCTAssertEqual(decoded[1].immediate, 44)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0x1000
        var pc: UInt64 = 0xa000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        let resultAddress: UInt64 = 0x2000
        let possibleAndGamma: UInt64 = 1
        registers[21] = resultAddress
        memory.write(possibleAndGamma, at: sp + 20, width: 8)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], possibleAndGamma)
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(memory.read(at: resultAddress + 44, width: 8), possibleAndGamma)
    }

    func testFullRegisterRunnerExecutesCageDoubleCompareWithZero() {
        let program: [UInt32] = [
            0x1e60_2008, // fcmp d0, #0.0
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_SCALAR_COMPARE)
        XCTAssertEqual(decoded[0].rn, 0)
        XCTAssertEqual(decoded[0].flags & 3, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xb000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = (-1.0 as Double).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(pstate & 0xf000_0000, 0x8000_0000)
    }

    func testFullRegisterRunnerExecutesCageSingleRegisterCompare() {
        let program: [UInt32] = [
            0x1e3e_23e0, // fcmp s31, s30
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_SCALAR_COMPARE)
        XCTAssertEqual(decoded[0].rn, 31)
        XCTAssertEqual(decoded[0].rm, 30)
        XCTAssertEqual(decoded[0].flags & 3, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xe000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = UInt64((7.0 as Float).bitPattern)
        vectorLows[30] = UInt64((3.0 as Float).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(pstate & 0xf000_0000, 0x2000_0000)
    }

    func testFullRegisterRunnerExecutesCageDoubleMultiply() {
        let program: [UInt32] = [
            0x1e78_083c, // fmul d28, d1, d24
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC)
        XCTAssertEqual(decoded[0].rn, 1)
        XCTAssertEqual(decoded[0].rm, 24)
        XCTAssertEqual(decoded[0].rd, 28)
        XCTAssertEqual(decoded[0].flags & 7, 6)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = (3.0 as Double).bitPattern
        vectorLows[24] = (4.0 as Double).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Double(bitPattern: vectorLows[28]), 12.0)
    }

    func testFullRegisterRunnerExecutesSignedFPToGeneralIntegerConversions() {
        let program: [UInt32] = [
            0x1e78_03c0, // fcvtzs w0, d30
            0x9e78_03c1, // fcvtzs x1, d30
            0x1e38_0062, // fcvtzs w2, s3
            0x9e38_00a4, // fcvtzs x4, s5
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER)
            XCTAssertEqual(instruction.flags & 4, 0)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xd000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[30] = (-42.75 as Double).bitPattern
        vectorLows[3] = UInt64((-17.5 as Float).bitPattern)
        vectorLows[5] = UInt64((19.75 as Float).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[0], UInt64(UInt32(bitPattern: -42)))
        XCTAssertEqual(registers[1], UInt64(bitPattern: -42))
        XCTAssertEqual(registers[2], UInt64(UInt32(bitPattern: -17)))
        XCTAssertEqual(registers[4], 19)
    }

    func testFullRegisterRunnerExecutesFixedPointFPToIntegerConversions() {
        let program: [UInt32] = [
            0x1e19_e083, // fcvtzu w3, s4, #8 (live Settings instruction)
            0x1e18_e0c5, // fcvtzs w5, s6, #8
            0x9e19_e107, // fcvtzu x7, s8, #8
            0x9e58_e251, // fcvtzs x17, d18, #8
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(
                Int(instruction.kind),
                AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER
            )
            XCTAssertEqual(instruction.shift_amount, 8)
        }
        XCTAssertEqual(decoded[0].flags & 4, 4)
        XCTAssertEqual(decoded[1].flags & 4, 0)
        XCTAssertEqual(decoded[3].flags & 1, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1d_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[4] = UInt64(Float(1.75).bitPattern)
        vectorLows[6] = UInt64(Float(-1.75).bitPattern)
        vectorLows[8] = UInt64(Float(2.5).bitPattern)
        vectorLows[18] = Double(-3.125).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[3], 448)
        XCTAssertEqual(registers[5], UInt64(UInt32(bitPattern: -448)))
        XCTAssertEqual(registers[7], 640)
        XCTAssertEqual(registers[17], UInt64(bitPattern: -800))
    }

    func testFullRegisterRunnerExecutesGeneralFPToIntegerRoundingFamilies() {
        let program: [UInt32] = [
            0x1e30_0022, // fcvtms w2, s1 (live Cage instruction)
            0x1e20_0020, // fcvtns w0, s1
            0x9e61_0074, // fcvtnu x20, d3
            0x1e68_00a4, // fcvtps w4, d5
            0x9e29_00e6, // fcvtpu x6, s7
            0x1e30_0128, // fcvtms w8, s9
            0x9e71_016a, // fcvtmu x10, d11
            0x1e64_01ac, // fcvtas w12, d13
            0x9e25_01ee, // fcvtau x14, s15
            0x1e38_0230, // fcvtzs w16, s17
            0x9e79_0272, // fcvtzu x18, d19
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER)
            XCTAssertEqual(instruction.flags & 8, 0)
        }
        XCTAssertEqual((decoded[0].flags >> 4) & 7, 3)
        XCTAssertEqual((decoded[1].flags >> 4) & 7, 1)
        XCTAssertEqual((decoded[3].flags >> 4) & 7, 2)
        XCTAssertEqual((decoded[7].flags >> 4) & 7, 4)
        XCTAssertEqual((decoded[9].flags >> 4) & 7, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1c_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(-1.1).bitPattern)
        vectorLows[3] = Double(2.5).bitPattern
        vectorLows[5] = Double(1.1).bitPattern
        vectorLows[7] = UInt64(Float(1.1).bitPattern)
        vectorLows[9] = UInt64(Float(-1.1).bitPattern)
        vectorLows[11] = Double(1.9).bitPattern
        vectorLows[13] = Double(-2.5).bitPattern
        vectorLows[15] = UInt64(Float(2.5).bitPattern)
        vectorLows[17] = UInt64(Float(-3.9).bitPattern)
        vectorLows[19] = Double(4.9).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            14,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[2], UInt64(UInt32(bitPattern: -2)))
        XCTAssertEqual(registers[0], UInt64(UInt32(bitPattern: -1)))
        XCTAssertEqual(registers[20], 2)
        XCTAssertEqual(registers[4], 2)
        XCTAssertEqual(registers[6], 2)
        XCTAssertEqual(registers[8], UInt64(UInt32(bitPattern: -2)))
        XCTAssertEqual(registers[10], 1)
        XCTAssertEqual(registers[12], UInt64(UInt32(bitPattern: -3)))
        XCTAssertEqual(registers[14], 3)
        XCTAssertEqual(registers[16], UInt64(UInt32(bitPattern: -3)))
        XCTAssertEqual(registers[18], 4)
    }

    func testFullRegisterRunnerExecutesCageSinglePrecisionLoadPair() {
        let program: [UInt32] = [
            0x2d42_767c, // ldp s28, s29, [x19, #16]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR)
        XCTAssertEqual(decoded[0].width, 4)
        XCTAssertEqual(decoded[0].immediate, 16)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: UInt64.max, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xf000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[19] = 0x1000
        memory.write(UInt64((3.5 as Float).bitPattern), at: 0x1010, width: 4)
        memory.write(UInt64((-7.25 as Float).bitPattern), at: 0x1014, width: 4)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[28], UInt64((3.5 as Float).bitPattern))
        XCTAssertEqual(vectorLows[29], UInt64((-7.25 as Float).bitPattern))
        XCTAssertEqual(vectorHighs[28], 0)
        XCTAssertEqual(vectorHighs[29], 0)
    }

    func testFullRegisterRunnerExecutesCageUnsignedFPToVectorInteger() {
        let program: [UInt32] = [
            0x7ea1_bbbd, // fcvtzu s29, s29
            0x7ee1_bbdc, // fcvtzu d28, d30
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER)
        XCTAssertEqual(decoded[0].flags & 12, 12)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER)
        XCTAssertEqual(decoded[1].flags & 13, 13)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x10_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[29] = UInt64((42.75 as Float).bitPattern)
        vectorLows[30] = (123.875 as Double).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[29], 42)
        XCTAssertEqual(vectorLows[28], 123)
        XCTAssertEqual(vectorHighs[29], 0)
        XCTAssertEqual(vectorHighs[28], 0)
    }

    func testFullRegisterRunnerExecutesSIMDFPToIntegerConversionFamily() {
        let program: [UInt32] = [
            0x4e21_a820, // fcvtns v0.4s, v1.4s
            0x6e21_a862, // fcvtnu v2.4s, v3.4s
            0x4ea1_a8a4, // fcvtps v4.4s, v5.4s
            0x6ea1_a8e6, // fcvtpu v6.4s, v7.4s
            0x4e21_b928, // fcvtms v8.4s, v9.4s
            0x6e21_b96a, // fcvtmu v10.4s, v11.4s
            0x4ea1_b9ac, // fcvtzs v12.4s, v13.4s
            0x6ea1_b9ee, // fcvtzu v14.4s, v15.4s
            0x4e21_ca30, // fcvtas v16.4s, v17.4s
            0x6e21_ca72, // fcvtau v18.4s, v19.4s
            0x4ee1_bbde, // fcvtzs v30.2d, v30.2d (live Settings instruction)
            0x0e21_aab4, // fcvtns v20.2s, v21.2s
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER)
        }
        XCTAssertEqual(decoded.map(\.flags), [12, 14, 20, 22, 28, 30, 4, 6, 36, 38, 5, 8, 0])

        func packedFloats(_ values: [Float]) -> (UInt64, UInt64) {
            precondition(values.count == 4)
            return (
                UInt64(values[0].bitPattern) | (UInt64(values[1].bitPattern) << 32),
                UInt64(values[2].bitPattern) | (UInt64(values[3].bitPattern) << 32)
            )
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x10_800
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let sources: [(Int, [Float])] = [
            (1, [1.5, 2.5, -1.5, -2.5]),
            (3, [1.5, 2.5, -1, 3.5]),
            (5, [1.1, -1.1, 2, -2]),
            (7, [1.1, -1.1, 2.1, 0]),
            (9, [1.9, -1.1, 2, -2]),
            (11, [1.9, -1.1, 2.9, 0]),
            (13, [1.9, -1.9, 2.5, -2.5]),
            (15, [1.9, -1.9, 2.5, 0]),
            (17, [1.5, -1.5, 2.4, -2.4]),
            (19, [1.5, -1.5, 2.5, 0]),
            (21, [3.5, 4.5, 99, 99])
        ]
        for (register, values) in sources {
            (vectorLows[register], vectorHighs[register]) = packedFloats(values)
        }
        vectorLows[30] = Double(42.9).bitPattern
        vectorHighs[30] = Double(-42.9).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            16,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        func signedWordLanes(_ register: Int) -> [Int32] {
            let words = [vectorLows[register], vectorHighs[register]]
            return words.flatMap { word in
                [
                    Int32(bitPattern: UInt32(truncatingIfNeeded: word)),
                    Int32(bitPattern: UInt32(truncatingIfNeeded: word >> 32))
                ]
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(signedWordLanes(0), [2, 2, -2, -2])
        XCTAssertEqual(signedWordLanes(2), [2, 2, 0, 4])
        XCTAssertEqual(signedWordLanes(4), [2, -1, 2, -2])
        XCTAssertEqual(signedWordLanes(6), [2, 0, 3, 0])
        XCTAssertEqual(signedWordLanes(8), [1, -2, 2, -2])
        XCTAssertEqual(signedWordLanes(10), [1, 0, 2, 0])
        XCTAssertEqual(signedWordLanes(12), [1, -1, 2, -2])
        XCTAssertEqual(signedWordLanes(14), [1, 0, 2, 0])
        XCTAssertEqual(signedWordLanes(16), [2, -2, 2, -2])
        XCTAssertEqual(signedWordLanes(18), [2, 0, 3, 0])
        XCTAssertEqual(Int64(bitPattern: vectorLows[30]), 42)
        XCTAssertEqual(Int64(bitPattern: vectorHighs[30]), -42)
        XCTAssertEqual(Array(signedWordLanes(20).prefix(2)), [4, 4])
        XCTAssertEqual(vectorHighs[20], 0)
    }

    func testFullRegisterRunnerExecutesCageHalfwordUnsignedImmediateStore() {
        let program: [UInt32] = [
            0x7d00_47fd, // str h29, [sp, #34]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE)
        XCTAssertEqual(decoded[0].width, 2)
        XCTAssertEqual(decoded[0].immediate, 34)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0x1000
        var pc: UInt64 = 0x11_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        vectorLows[29] = 0xfeed_beef

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(memory.read(at: sp + 34, width: 2), 0xbeef)
    }

    func testNativeDecoderClassifiesSIMDMultipleStructureRegisterCounts() {
        let instructions: [UInt32] = [
            0x0c00_7020, // st1 {v0.8b}, [x1]
            0x0c9f_a064, // st1 {v4.8b-v5.8b}, [x3], #16
            0x0c9f_6088, // st1 {v8.8b-v10.8b}, [x4], #24
            0x0c9f_20ac, // st1 {v12.8b-v15.8b}, [x5], #32
            0x4cdf_2020  // ld1 {v0.16b-v3.16b}, [x1], #64
        ]
        let decoded = decode(instructions)

        for (index, instruction) in decoded.enumerated() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE)
            XCTAssertEqual(instruction.condition, UInt8(index + 1 > 4 ? 4 : index + 1))
        }
        XCTAssertEqual(decoded[0].width, 8)
        XCTAssertEqual(decoded[4].width, 16)
        XCTAssertEqual(decoded[4].flags & 1, 1)
    }

    func testFullRegisterRunnerExecutesInterleavedLD4WithPostIndex() {
        let program: [UInt32] = [
            0x0cdf_0104, // ld4 {v4.8b-v7.8b}, [x8], #32 (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE)
        XCTAssertEqual(decoded[0].condition, 4)
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertNotEqual(decoded[0].flags & 32, 0)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x12_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[8] = 0x3000
        for byte in 0..<UInt64(32) {
            memory.write(byte, at: 0x3000 + byte, width: 1)
        }

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 4,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nativeTestMemoryRead, nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess, nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[8], 0x3020)
        XCTAssertEqual(vectorLows[4], 0x1c18_1410_0c08_0400)
        XCTAssertEqual(vectorLows[5], 0x1d19_1511_0d09_0501)
        XCTAssertEqual(vectorLows[6], 0x1e1a_1612_0e0a_0602)
        XCTAssertEqual(vectorLows[7], 0x1f1b_1713_0f0b_0703)
    }

    func testFullRegisterRunnerExecutesCageFourRegisterST1WithPostIndex() {
        let program: [UInt32] = [
            0x0c9f_23a8, // st1 {v8.8b-v11.8b}, [x29], #32
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE)
        XCTAssertEqual(decoded[0].condition, 4)
        XCTAssertEqual(decoded[0].width, 8)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x12_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[29] = 0x2000
        vectorLows[8] = 0x0808_0808_0808_0808
        vectorLows[9] = 0x0909_0909_0909_0909
        vectorLows[10] = 0x0a0a_0a0a_0a0a_0a0a
        vectorLows[11] = 0x0b0b_0b0b_0b0b_0b0b

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nativeTestMemoryRead,
                            nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess,
                            nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(memory.read(at: 0x2000, width: 8), vectorLows[8])
        XCTAssertEqual(memory.read(at: 0x2008, width: 8), vectorLows[9])
        XCTAssertEqual(memory.read(at: 0x2010, width: 8), vectorLows[10])
        XCTAssertEqual(memory.read(at: 0x2018, width: 8), vectorLows[11])
        XCTAssertEqual(registers[29], 0x2020)
    }

    func testFullRegisterRunnerExecutesCageVectorElementDuplicate() {
        let program: [UInt32] = [
            0x0e04_0403, // dup v3.2s, v0.s[0]
            0x4e1c_0424, // dup v4.4s, v1.s[3]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT)
        XCTAssertEqual(decoded[0].bits, 32)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].condition, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x13_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0xfeed_face_1234_5678
        vectorHighs[1] = 0xcafe_babe_dead_beef

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[3], 0x1234_5678_1234_5678)
        XCTAssertEqual(vectorHighs[3], 0)
        XCTAssertEqual(vectorLows[4], 0xcafe_babe_cafe_babe)
        XCTAssertEqual(vectorHighs[4], 0xcafe_babe_cafe_babe)
    }

    func testFullRegisterRunnerExecutesUnsignedSIMDScalarIntegerToFP() {
        let program: [UInt32] = [
            0x7e21_d800, // ucvtf s0, s0
            0x7e61_d821, // ucvtf d1, d1
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP)
        XCTAssertEqual(decoded[0].flags & 3, 2)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP)
        XCTAssertEqual(decoded[1].flags & 3, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x14_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = UInt64(UInt32.max)
        vectorLows[1] = 123

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[0])), Float(UInt32.max))
        XCTAssertEqual(Double(bitPattern: vectorLows[1]), 123)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorHighs[1], 0)
    }

    func testFullRegisterRunnerExecutesSIMDVectorIntegerToFP() {
        let program: [UInt32] = [
            0x4e61_dbff, // scvtf v31.2d, v31.2d (live Phosh instruction)
            0x6e21_d820, // ucvtf v0.4s, v1.4s
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP)
        XCTAssertEqual(decoded[0].flags, 13)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP)
        XCTAssertEqual(decoded[1].flags, 14)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x14_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = UInt64(bitPattern: Int64(-2))
        vectorHighs[31] = 3
        vectorLows[1] = 0x0000_0002_0000_0001
        vectorHighs[1] = 0x0100_0000_0000_0003

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 0xc000_0000_0000_0000)
        XCTAssertEqual(vectorHighs[31], 0x4008_0000_0000_0000)
        XCTAssertEqual(vectorLows[0], 0x4000_0000_3f80_0000)
        XCTAssertEqual(vectorHighs[0], 0x4b80_0000_4040_0000)
    }

    func testFullRegisterRunnerExecutesSIMDVectorFPArithmetic() {
        let program: [UInt32] = [
            0x0e22_d420, // fadd v0.2s, v1.2s, v2.2s
            0x4eab_d549, // fsub v9.4s, v10.4s, v11.4s
            0x6e2e_ddac, // fmul v12.4s, v13.4s, v14.4s
            0x6e7e_ffff, // fdiv v31.2d, v31.2d, v30.2d (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x15_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x4000_0000_3f80_0000 // 2, 1
        vectorLows[2] = 0x4080_0000_4040_0000 // 4, 3
        vectorLows[10] = 0x40a0_0000_4110_0000 // 5, 9
        vectorHighs[10] = 0x4140_0000_4180_0000 // 12, 16
        vectorLows[11] = 0x3f80_0000_4000_0000 // 1, 2
        vectorHighs[11] = 0x4040_0000_4080_0000 // 3, 4
        vectorLows[13] = 0x4000_0000_3f80_0000
        vectorHighs[13] = 0x4080_0000_4040_0000
        vectorLows[14] = 0x4100_0000_4080_0000
        vectorHighs[14] = 0x4000_0000_3f00_0000
        vectorLows[31] = 0x4024_0000_0000_0000 // 10
        vectorHighs[31] = 0xc022_0000_0000_0000 // -9
        vectorLows[30] = 0x4000_0000_0000_0000 // 2
        vectorHighs[30] = 0x4008_0000_0000_0000 // 3

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 10,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[0], 0x40c0_0000_4080_0000) // 6, 4
        XCTAssertEqual(vectorLows[9], 0x4080_0000_40e0_0000) // 4, 7
        XCTAssertEqual(vectorHighs[9], 0x4110_0000_4140_0000) // 9, 12
        XCTAssertEqual(vectorLows[12], 0x4180_0000_4080_0000) // 16, 4
        XCTAssertEqual(vectorHighs[12], 0x4100_0000_3fc0_0000) // 8, 1.5
        XCTAssertEqual(vectorLows[31], 0x4014_0000_0000_0000) // 5
        XCTAssertEqual(vectorHighs[31], 0xc008_0000_0000_0000) // -3
    }

    func testFullRegisterRunnerExecutesSIMDIntegerMinMaxFamily() {
        let program: [UInt32] = [
            0x0e7f_67bf, // smax v31.4h, v29.4h, v31.4h (live Phosh instruction)
            0x4eae_6dac, // smin v12.4s, v13.4s, v14.4s
            0x6eb1_660f, // umax v15.4s, v16.4s, v17.4s
            0x6eb4_6e72, // umin v18.4s, v19.4s, v20.4s
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX)
        }
        XCTAssertEqual(decoded[0].bits, 16)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[29] = 0x0003_fffc_0001_fffe
        vectorLows[31] = 0xffff_0004_fffd_0002
        vectorLows[13] = 0xffff_ffff_0000_0005
        vectorHighs[13] = 0x0000_0009_8000_0000
        vectorLows[14] = 0x0000_0002_ffff_ffff
        vectorHighs[14] = 0xffff_ffff_7fff_ffff
        vectorLows[16] = 0xffff_ffff_0000_0001
        vectorHighs[16] = 0x0000_0003_8000_0000
        vectorLows[17] = 0x0000_0002_ffff_fffe
        vectorHighs[17] = 0xffff_ffff_7fff_ffff
        vectorLows[19] = vectorLows[16]
        vectorHighs[19] = vectorHighs[16]
        vectorLows[20] = vectorLows[17]
        vectorHighs[20] = vectorHighs[17]

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 10,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 0x0003_0004_0001_0002)
        XCTAssertEqual(vectorLows[12], 0xffff_ffff_ffff_ffff)
        XCTAssertEqual(vectorHighs[12], 0xffff_ffff_8000_0000)
        XCTAssertEqual(vectorLows[15], 0xffff_ffff_ffff_fffe)
        XCTAssertEqual(vectorHighs[15], 0xffff_ffff_8000_0000)
        XCTAssertEqual(vectorLows[18], 0x0000_0002_0000_0001)
        XCTAssertEqual(vectorHighs[18], 0x0000_0003_7fff_ffff)
    }

    func testFullRegisterRunnerExecutesSIMDFPMinMaxFamily() {
        let program: [UInt32] = [
            0x0e22_c420, // fmaxnm v0.2s, v1.2s, v2.2s
            0x4ea5_c483, // fminnm v3.4s, v4.4s, v5.4s
            0x4e68_f4e6, // fmax v6.2d, v7.2d, v8.2d
            0x4eab_f549, // fmin v9.4s, v10.4s, v11.4s
            0x4ebf_f400, // fmin v0.4s, v0.4s, v31.4s (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_MINMAX)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }
        XCTAssertEqual(decoded[4].flags, 27)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_080
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[1] = 0x7fc0_0000_3f80_0000
        vectorLows[2] = 0x4040_0000_4000_0000
        vectorLows[4] = 0xbf80_0000_40a0_0000
        vectorHighs[4] = 0x7fc0_0000_4100_0000
        vectorLows[5] = 0x4000_0000_4080_0000
        vectorHighs[5] = 0x40e0_0000_7fc0_0000
        vectorLows[7] = 0x4024_0000_0000_0000
        vectorHighs[7] = 0x7ff8_0000_0000_0000
        vectorLows[8] = 0x4010_0000_0000_0000
        vectorHighs[8] = 0x4008_0000_0000_0000
        vectorLows[10] = 0xbf80_0000_40a0_0000
        vectorHighs[10] = 0x40c0_0000_4100_0000
        vectorLows[11] = 0x4000_0000_4080_0000
        vectorHighs[11] = 0x4110_0000_40e0_0000
        vectorLows[31] = 0x4080_0000_3f80_0000
        vectorHighs[31] = 0x40a0_0000_bf80_0000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 10,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[0], 0x4040_0000_3f80_0000)
        XCTAssertEqual(vectorHighs[0], 0x0000_0000_bf80_0000)
        XCTAssertEqual(vectorLows[3], 0xbf80_0000_4080_0000)
        XCTAssertEqual(vectorHighs[3], 0x40e0_0000_4100_0000)
        XCTAssertEqual(vectorLows[6], 0x4024_0000_0000_0000)
        XCTAssertTrue(Double(bitPattern: vectorHighs[6]).isNaN)
        XCTAssertEqual(vectorLows[9], 0xbf80_0000_4080_0000)
        XCTAssertEqual(vectorHighs[9], 0x40c0_0000_40e0_0000)
    }

    func testFullRegisterRunnerExecutesLivePhoshSignedWordMaximum() {
        let program: [UInt32] = [
            0x0ebf_65ef, // smax v15.2s, v15.2s, v31.2s (live Phosh instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX)
        XCTAssertEqual(decoded[0].bits, 32)
        XCTAssertEqual(decoded[0].flags, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_100
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[15] = 0xffff_fff0_0000_0007
        vectorLows[31] = 0x0000_0003_ffff_ffff

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 4,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(vectorLows[15], 0x0000_0003_0000_0007)
        XCTAssertEqual(vectorHighs[15], 0)
    }

    func testFullRegisterRunnerExecutesVectorByElementFPMultiply() {
        let program: [UInt32] = [
            0x0fa2_9820, // fmul v0.2s, v1.2s, v2.s[3]
            0x4fc5_9883, // fmul v3.2d, v4.2d, v5.d[1]
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC)
            XCTAssertNotEqual(instruction.flags & 32, 0)
        }
        XCTAssertEqual(decoded[0].condition, 3)
        XCTAssertEqual(decoded[1].condition, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_200
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(2).bitPattern) |
            (UInt64(Float(-3).bitPattern) << 32)
        vectorHighs[2] = UInt64(Float(4).bitPattern) << 32
        vectorLows[4] = Double(1.5).bitPattern
        vectorHighs[4] = Double(-2).bitPattern
        vectorHighs[5] = Double(3).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 6,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(
            vectorLows[0],
            UInt64(Float(8).bitPattern) | (UInt64(Float(-12).bitPattern) << 32)
        )
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[3], Double(4.5).bitPattern)
        XCTAssertEqual(vectorHighs[3], Double(-6).bitPattern)
    }

    func testFullRegisterRunnerExecutesGeneralizedSignedShiftLongFamily() {
        let program: [UInt32] = [
            0x0f0b_a4e6, // sshll v6.8h, v7.8b, #3
            0x4f1c_a528, // sshll2 v8.4s, v9.8h, #12
            0x4f3f_a56a, // sshll2 v10.2d, v11.4s, #31
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[1].bits, 16)
        XCTAssertEqual(decoded[2].bits, 32)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(decoded[1].condition, 4)
        XCTAssertEqual(decoded[2].condition, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_300
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[7] = 0xfc04_fd03_fe02_ff01
        vectorHighs[9] = 0xfffe_0002_ffff_0001
        vectorHighs[11] = 0xffff_ffff_0000_0001

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 6,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[6], 0xfff0_0010_fff8_0008)
        XCTAssertEqual(vectorHighs[6], 0xffe0_0020_ffe8_0018)
        XCTAssertEqual(vectorLows[8], 0xffff_f000_0000_1000)
        XCTAssertEqual(vectorHighs[8], 0xffff_e000_0000_2000)
        XCTAssertEqual(vectorLows[10], 0x0000_0000_8000_0000)
        XCTAssertEqual(vectorHighs[10], 0xffff_ffff_8000_0000)
    }

    func testFullRegisterRunnerExecutesVectorMultiplyAccumulateFamily() {
        let program: [UInt32] = [
            0x0e2e_9dac, // mul v12.8b, v13.8b, v14.8b
            0x0e71_960f, // mla v15.4h, v16.4h, v17.4h
            0x6eb4_9672, // mls v18.4s, v19.4s, v20.4s
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG)
            XCTAssertNotEqual(instruction.flags & 4, 0)
        }
        XCTAssertEqual((decoded[0].flags >> 4) & 3, 0)
        XCTAssertEqual((decoded[1].flags >> 4) & 3, 1)
        XCTAssertEqual((decoded[2].flags >> 4) & 3, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_400
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[13] = 0x0807_0605_0403_0201
        vectorLows[14] = 0x0202_0202_0202_0202
        vectorLows[15] = 0x0028_001e_0014_000a
        vectorLows[16] = 0x0005_0004_0003_0002
        vectorLows[17] = 0x000a_000a_000a_000a
        vectorLows[18] = 0x0000_00c8_0000_0064
        vectorHighs[18] = 0x0000_0190_0000_012c
        vectorLows[19] = 0x0000_0003_0000_0002
        vectorHighs[19] = 0x0000_0005_0000_0004
        vectorLows[20] = 0x0000_000a_0000_000a
        vectorHighs[20] = 0x0000_000a_0000_000a

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 6,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[12], 0x100e_0c0a_0806_0402)
        XCTAssertEqual(vectorHighs[12], 0)
        XCTAssertEqual(vectorLows[15], 0x005a_0046_0032_001e)
        XCTAssertEqual(vectorHighs[15], 0)
        XCTAssertEqual(vectorLows[18], 0x0000_00aa_0000_0050)
        XCTAssertEqual(vectorHighs[18], 0x0000_015e_0000_0104)
    }

    func testFullRegisterRunnerExecutesIntegerMultiplyByElementFamily() {
        let program: [UInt32] = [
            0x0f9f_83de, // mul v30.2s, v30.2s, v31.s[0] (live Phosh instruction)
            0x4f75_8883, // mul v3.8h, v4.8h, v5.h[7]
            0x2f7e_01ac, // mla v12.4h, v13.4h, v14.h[3]
            0x6f91_4a0f, // mls v15.4s, v16.4s, v17.s[2]
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG)
            XCTAssertNotEqual(instruction.flags & 64, 0)
        }
        XCTAssertEqual(decoded[0].rm, 31)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(decoded[1].rm, 5)
        XCTAssertEqual(decoded[1].condition, 7)
        XCTAssertEqual((decoded[2].flags >> 4) & 3, 1)
        XCTAssertEqual((decoded[3].flags >> 4) & 3, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_500
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[30] = 0xffff_fffd_0000_0007
        vectorLows[31] = 5
        vectorLows[4] = 0x0004_0003_0002_0001
        vectorHighs[4] = 0x0008_0007_0006_0005
        vectorHighs[5] = 0x0003_0000_0000_0000
        vectorLows[12] = 0x0028_001e_0014_000a
        vectorLows[13] = 0x0005_0004_0003_0002
        vectorLows[14] = 0x000a_0000_0000_0000
        vectorLows[15] = 0x0000_00c8_0000_0064
        vectorHighs[15] = 0x0000_0190_0000_012c
        vectorLows[16] = 0x0000_0003_0000_0002
        vectorHighs[16] = 0x0000_0005_0000_0004
        vectorHighs[17] = 10

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[30], 0xffff_fff1_0000_0023)
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(vectorLows[3], 0x000c_0009_0006_0003)
        XCTAssertEqual(vectorHighs[3], 0x0018_0015_0012_000f)
        XCTAssertEqual(vectorLows[12], 0x005a_0046_0032_001e)
        XCTAssertEqual(vectorHighs[12], 0)
        XCTAssertEqual(vectorLows[15], 0x0000_00aa_0000_0050)
        XCTAssertEqual(vectorHighs[15], 0x0000_015e_0000_0104)
    }

    func testFullRegisterRunnerExecutesWideningMultiplyAccumulateFamily() {
        let program: [UInt32] = [
            0x2e3d_82e8, // umlal v8.8h, v23.8b, v29.8b (live Phosh instruction)
            0x4e25_8083, // smlal2 v3.8h, v4.16b, v5.16b
            0x4e71_a20f, // smlsl2 v15.4s, v16.8h, v17.8h
            0x2eb4_a272, // umlsl v18.2d, v19.2s, v20.2s
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].flags, 10)
        XCTAssertEqual(decoded[1].flags, 9)
        XCTAssertEqual(decoded[2].bits, 16)
        XCTAssertEqual(decoded[2].flags, 25)
        XCTAssertEqual(decoded[3].bits, 32)
        XCTAssertEqual(decoded[3].flags, 26)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_600
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[8] = 0x0028_001e_0014_000a
        vectorHighs[8] = 0x0050_0046_003c_0032
        vectorLows[23] = 0x0807_0605_0403_0201
        vectorLows[29] = 0x0202_0202_0202_0202
        vectorLows[3] = 0x0064_0064_0064_0064
        vectorHighs[3] = 0x0064_0064_0064_0064
        vectorHighs[4] = 0x0605_7f80_0403_feff
        vectorHighs[5] = 0x05fe_0202_04ff_0302
        vectorLows[15] = 0x0000_07d0_0000_03e8
        vectorHighs[15] = 0x0000_0fa0_0000_0bb8
        vectorHighs[16] = 0x0005_fffc_0003_fffe
        vectorHighs[17] = 0x0028_ffe2_ffec_000a
        vectorLows[18] = 1_000
        vectorHighs[18] = 2_000
        vectorLows[19] = 0x0000_0014_0000_000a
        vectorLows[20] = 0x0000_0004_0000_0003

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(vectorLows[8], 0x0030_0024_0018_000c)
        XCTAssertEqual(vectorHighs[8], 0x0060_0054_0048_003c)
        XCTAssertEqual(vectorLows[3], 0x0074_0061_005e_0062)
        XCTAssertEqual(vectorHighs[3], 0x0082_005a_0162_ff64)
        XCTAssertEqual(vectorLows[15], 0x0000_080c_0000_03fc)
        XCTAssertEqual(vectorHighs[15], 0x0000_0ed8_0000_0b40)
        XCTAssertEqual(vectorLows[18], 970)
        XCTAssertEqual(vectorHighs[18], 1_920)
    }

    func testFullRegisterRunnerExecutesWideningMultiplyByElementFamily() {
        let program: [UInt32] = [
            0x0f72_a0c0, // smull v0.4s, v6.4h, v2.h[3]
            0x4fa5_a083, // smull2 v3.2d, v4.4s, v5.s[1]
            0x6f96_22b4, // umlal2 v20.2d, v21.4s, v22.s[0]
            0x0f4e_29ac, // smlal v12.4s, v13.4h, v14.h[4]
            0x0f59_6b17, // smlsl v23.4s, v24.4h, v9.h[5]
            0x2f4f_6921, // umlsl v1.4s, v9.4h, v15.h[4] (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG)
            XCTAssertNotEqual(instruction.flags & 64, 0)
        }
        XCTAssertEqual(decoded[0].rm, 2)
        XCTAssertEqual(decoded[0].condition, 3)
        XCTAssertEqual(decoded[0].flags, 64)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].condition, 1)
        XCTAssertEqual(decoded[1].flags, 65)
        XCTAssertEqual(decoded[2].rm, 22)
        XCTAssertEqual(decoded[2].condition, 0)
        XCTAssertEqual(decoded[2].flags, 75)
        XCTAssertEqual(decoded[3].condition, 4)
        XCTAssertEqual(decoded[3].flags, 72)
        XCTAssertEqual(decoded[4].condition, 5)
        XCTAssertEqual(decoded[4].flags, 88)
        XCTAssertEqual(decoded[5].rm, 15)
        XCTAssertEqual(decoded[5].condition, 4)
        XCTAssertEqual(decoded[5].flags, 90)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_680
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x0000_07d0_0000_03e8
        vectorHighs[1] = 0x0000_0fa0_0000_0bb8
        vectorLows[2] = 0xfff6_0000_0000_0000
        vectorLows[6] = 0x0005_fffc_0003_fffe
        vectorHighs[4] = 0x0000_0004_ffff_fffd
        vectorLows[5] = 0xffff_fffb_0000_0000
        vectorLows[20] = 100
        vectorHighs[20] = 200
        vectorHighs[21] = 0x0000_0014_0000_000a
        vectorLows[22] = 3
        vectorLows[12] = 0x0000_0064_0000_0064
        vectorHighs[12] = 0x0000_0064_0000_0064
        vectorLows[13] = 0x0005_fffc_0003_fffe
        vectorHighs[14] = 0x0000_0000_0000_fff6
        vectorLows[23] = 0x0000_00c8_0000_0064
        vectorHighs[23] = 0x0000_0190_0000_012c
        vectorLows[24] = 0xfffc_0003_fffe_0001
        vectorLows[9] = 0x0004_0003_0002_0001
        vectorHighs[9] = 0x0000_0000_fff6_0000
        vectorHighs[15] = 10

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 10,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 7)
        XCTAssertEqual(vectorLows[0], 0xffff_ffe2_0000_0014)
        XCTAssertEqual(vectorHighs[0], 0xffff_ffce_0000_0028)
        XCTAssertEqual(vectorLows[3], 15)
        XCTAssertEqual(vectorHighs[3], 0xffff_ffff_ffff_ffec)
        XCTAssertEqual(vectorLows[20], 130)
        XCTAssertEqual(vectorHighs[20], 260)
        XCTAssertEqual(vectorLows[12], 0x0000_0046_0000_0078)
        XCTAssertEqual(vectorHighs[12], 0x0000_0032_0000_008c)
        XCTAssertEqual(vectorLows[23], 0x0000_00b4_0000_006e)
        XCTAssertEqual(vectorHighs[23], 0x0000_0168_0000_014a)
        XCTAssertEqual(vectorLows[1], 0x0000_07bc_0000_03de)
        XCTAssertEqual(vectorHighs[1], 0x0000_0f78_0000_0b9a)
    }

    func testFullRegisterRunnerExecutesAddSubtractLongAndWideFamilies() {
        let program: [UInt32] = [
            0x0e7e_13ff, // saddw v31.4s, v31.4s, v30.4h (live Phosh instruction)
            0x4e65_0083, // saddl2 v3.4s, v4.8h, v5.8h
            0x2ea8_00e6, // uaddl v6.2d, v7.2s, v8.2s
            0x0e2b_2149, // ssubl v9.8h, v10.8b, v11.8b
            0x6e3d_339b, // usubw2 v27.8h, v28.8h, v29.16b
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_ADD_VECTOR)
            XCTAssertNotEqual(instruction.flags & 4, 0)
        }
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].flags, 20)
        XCTAssertEqual(decoded[1].flags, 5)
        XCTAssertEqual(decoded[2].bits, 32)
        XCTAssertEqual(decoded[2].flags, 12)
        XCTAssertEqual(decoded[3].flags, 6)
        XCTAssertEqual(decoded[4].flags, 31)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_700
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0x0000_00c8_0000_0064
        vectorHighs[31] = 0x0000_0190_0000_012c
        vectorLows[30] = 0x8000_7fff_fffe_0001
        vectorHighs[4] = 0x0005_fffc_0003_fffe
        vectorHighs[5] = 0x0028_ffe2_ffec_000a
        vectorLows[7] = 0x0000_0002_ffff_ffff
        vectorLows[8] = 0xffff_fffe_0000_0001
        vectorLows[10] = 0xf807_fa05_fc03_fe01
        vectorLows[11] = 0x08f9_06fb_04fd_02ff
        vectorLows[28] = 0x0190_012c_00c8_0064
        vectorHighs[28] = 0x0320_02bc_0258_01f4
        vectorHighs[29] = 0xff07_0605_0403_0201

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorLows[31], 0x0000_00c6_0000_0065)
        XCTAssertEqual(vectorHighs[31], 0xffff_8190_0000_812b)
        XCTAssertEqual(vectorLows[3], 0xffff_ffef_0000_0008)
        XCTAssertEqual(vectorHighs[3], 0x0000_002d_ffff_ffde)
        XCTAssertEqual(vectorLows[6], 0x0000_0001_0000_0000)
        XCTAssertEqual(vectorHighs[6], 0x0000_0001_0000_0000)
        XCTAssertEqual(vectorLows[9], 0xfff8_0006_fffc_0002)
        XCTAssertEqual(vectorHighs[9], 0xfff0_000e_fff4_000a)
        XCTAssertEqual(vectorLows[27], 0x018c_0129_00c6_0063)
        XCTAssertEqual(vectorHighs[27], 0x0221_02b5_0252_01ef)
    }

    func testFullRegisterRunnerExecutesCageScalarDShiftLeftImmediate() {
        let program: [UInt32] = [
            0x5f74_57ff, // shl d31, d31, #52
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE)
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].shift_amount, 52)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x15_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0xabc

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 0xabc0_0000_0000_0000)
        XCTAssertEqual(vectorHighs[31], 0)
    }

    func testFullRegisterRunnerExecutesFixedPointIntegerToFPConversions() {
        let program: [UInt32] = [
            0x1e42_f800, // scvtf d0, w0, #2
            0x9e43_e821, // ucvtf d1, x1, #6
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP)
        XCTAssertEqual(decoded[0].shift_amount, 2)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP)
        XCTAssertEqual(decoded[1].shift_amount, 6)
        XCTAssertEqual(decoded[1].flags & 7, 7)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x16_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        registers[0] = UInt64(UInt32(bitPattern: -42))
        registers[1] = 8_000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Double(bitPattern: vectorLows[0]), -10.5)
        XCTAssertEqual(Double(bitPattern: vectorLows[1]), 125)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorHighs[1], 0)
    }

    func testFullRegisterRunnerExecutesCageAddAcrossVector() {
        let program: [UInt32] = [
            0x0e31_bbff, // addv b31, v31.8b
            0x4eb1_b928, // addv s8, v9.4s
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR)
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].flags & 1, 0)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].flags & 1, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x17_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0x0807_0605_0403_0201
        vectorLows[9] = 0x0000_0002_0000_0001
        vectorHighs[9] = 0x0000_0004_0000_0003

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 36)
        XCTAssertEqual(vectorLows[8], 10)
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(vectorHighs[8], 0)
    }

    func testFullRegisterRunnerExecutesIntegerMinMaxAcrossVectorFamily() {
        let program: [UInt32] = [
            0x6e30_a801, // umaxv b1, v0.16b (live Squeekboard instruction)
            0x0e30_a883, // smaxv b3, v4.8b
            0x4e71_a9ac, // sminv h12, v13.8h
            0x6eb1_ab7a, // uminv s26, v27.4s
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }
        XCTAssertNotEqual(decoded[0].flags & 4, 0)
        XCTAssertEqual(decoded[1].flags & 4, 0)
        XCTAssertNotEqual(decoded[2].flags & 16, 0)
        XCTAssertNotEqual(decoded[3].flags & 16, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x17_100
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0x100f_0e0d_0c0b_0a09
        vectorHighs[0] = 0x807f_01fe_0302_0405
        vectorLows[4] = 0x807f_01ff_00fe_0280
        vectorLows[13] = 0x0001_8000_7fff_ffff
        vectorHighs[13] = 0x0010_fff0_0100_ff00
        vectorLows[27] = 0x0000_0003_0000_0002
        vectorHighs[27] = 0xffff_ffff_0000_0004

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[3], 0x7f)
        XCTAssertEqual(vectorLows[12], 0x8000)
        XCTAssertEqual(vectorLows[1], 0xfe)
        XCTAssertEqual(vectorLows[26], 2)
        for register in [1, 3, 12, 26] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesSIMDExtractVectorFamily() {
        let program: [UInt32] = [
            0x6e00_4001, // ext v1.16b, v0.16b, v0.16b, #8 (live Phosh instruction)
            0x6e04_7862, // ext v2.16b, v3.16b, v4.16b, #15
            0x2e0a_3928, // ext v8.8b, v9.8b, v10.8b, #7
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR)
        }
        XCTAssertEqual(decoded[0].shift_amount, 8)
        XCTAssertEqual(decoded[1].shift_amount, 15)
        XCTAssertEqual(decoded[2].shift_amount, 7)
        XCTAssertEqual(decoded[0].flags, 1)
        XCTAssertEqual(decoded[2].flags, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x17_200
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0x0706_0504_0302_0100
        vectorHighs[0] = 0x0f0e_0d0c_0b0a_0908
        vectorLows[3] = 0x1716_1514_1312_1110
        vectorHighs[3] = 0x1f1e_1d1c_1b1a_1918
        vectorLows[4] = 0x2726_2524_2322_2120
        vectorHighs[4] = 0x2f2e_2d2c_2b2a_2928
        vectorLows[9] = 0x3736_3534_3332_3130
        vectorHighs[8] = UInt64.max
        vectorLows[10] = 0x4746_4544_4342_4140

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 4)
        XCTAssertEqual(vectorLows[1], 0x0f0e_0d0c_0b0a_0908)
        XCTAssertEqual(vectorHighs[1], 0x0706_0504_0302_0100)
        XCTAssertEqual(vectorLows[2], 0x2625_2423_2221_201f)
        XCTAssertEqual(vectorHighs[2], 0x2e2d_2c2b_2a29_2827)
        XCTAssertEqual(vectorLows[8], 0x4645_4443_4241_4037)
        XCTAssertEqual(vectorHighs[8], 0)
    }

    func testFullRegisterRunnerExecutesWideningAddAcrossVector() {
        let program: [UInt32] = [
            0x0e30_3820, // saddlv h0, v1.8b
            0x6e30_3862, // uaddlv h2, v3.16b
            0x0e70_38a4, // saddlv s4, v5.4h
            0x6eb0_396a, // uaddlv d10, v11.4s
            0x2e30_3800, // uaddlv h0, v0.8b (live GNOME instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR)
            XCTAssertNotEqual(instruction.flags & 2, 0)
        }
        XCTAssertEqual(decoded[0].flags & 4, 0)
        XCTAssertNotEqual(decoded[1].flags & 4, 0)
        XCTAssertEqual(decoded[3].bits, 32)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x2c_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x01ff_02fe_03fd_04fc
        vectorLows[3] = 0x0807_0605_0403_0201
        vectorHighs[3] = 0x100f_0e0d_0c0b_0a09
        vectorLows[5] = 0xffff_0002_fffd_0004
        vectorLows[11] = 0x0000_0002_ffff_ffff
        vectorHighs[11] = 0x8000_0000_7fff_ffff

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorLows[2], 136)
        XCTAssertEqual(vectorLows[4], 2)
        XCTAssertEqual(vectorLows[10], 0x0000_0002_0000_0000)
        XCTAssertEqual(vectorHighs[0], 0)
    }

    func testFullRegisterRunnerExecutesSIMDPairwiseAddFamily() {
        let program: [UInt32] = [
            0x0e22_bc20, // addp v0.8b, v1.8b, v2.8b
            0x0ebe_bfdf, // addp v31.2s, v30.2s, v30.2s (live Phosh instruction)
            0x4ef4_be72, // addp v18.2d, v19.2d, v20.2d
            0x5ef1_bbbd, // addp d29, v29.2d (live Settings instruction family)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[2].bits, 64)
        XCTAssertEqual(decoded[2].flags, 1)
        XCTAssertEqual(decoded[3].bits, 64)
        XCTAssertEqual(decoded[3].flags, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1d_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x0807_0605_0403_0201
        vectorLows[2] = 0x5046_3c32_281e_140a
        vectorLows[30] = 0x0000_0002_ffff_ffff
        vectorLows[19] = UInt64.max
        vectorHighs[19] = 2
        vectorLows[20] = 3
        vectorHighs[20] = 4
        vectorLows[29] = UInt64.max - 3
        vectorHighs[29] = 9

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.unsupported_instruction, 0)
        XCTAssertEqual(result.generic_dispatches, 4)
        XCTAssertEqual(vectorLows[0], 0x966e_461e_0f0b_0703)
        XCTAssertEqual(vectorLows[31], 0x0000_0001_0000_0001)
        XCTAssertEqual(vectorLows[18], 1)
        XCTAssertEqual(vectorHighs[18], 7)
        XCTAssertEqual(vectorLows[29], 5)
        XCTAssertEqual(vectorHighs[29], 0)
    }

    func testFullRegisterRunnerExecutesSIMDPairwiseAddLongFamily() {
        let program: [UInt32] = [
            0x2e20_2820, // uaddlp v0.4h, v1.8b
            0x6e20_2862, // uaddlp v2.8h, v3.16b
            0x2e60_28a4, // uaddlp v4.2s, v5.4h
            0x6e60_28e6, // uaddlp v6.4s, v7.8h
            0x2ea0_2928, // uaddlp v8.1d, v9.2s
            0x6ea0_296a, // uaddlp v10.2d, v11.4s
            0x0e20_29ac, // saddlp v12.4h, v13.8b
            0x4ea0_29ee, // saddlp v14.2d, v15.4s
            0x6e20_2bff, // uaddlp v31.8h, v31.16b (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].flags, 2)
        XCTAssertEqual(decoded[1].flags, 3)
        XCTAssertEqual(decoded[2].bits, 16)
        XCTAssertEqual(decoded[4].bits, 32)
        XCTAssertEqual(decoded[6].flags, 0)
        XCTAssertEqual(decoded[7].flags, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1e_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x0807_0605_0403_01ff
        vectorLows[13] = 0xfefd_7f01_ff80_01ff
        vectorLows[15] = 0x0000_0002_ffff_ffff
        vectorHighs[15] = 0x0000_0004_ffff_fffd
        vectorLows[31] = 0x0807_0605_0403_0201
        vectorHighs[31] = 0x100f_0e0d_0c0b_0a09

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            12,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[0], 0x000f_000b_0007_0100)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[12], 0xfffb_0080_ff7f_0000)
        XCTAssertEqual(vectorHighs[12], 0)
        XCTAssertEqual(vectorLows[14], 1)
        XCTAssertEqual(vectorHighs[14], 1)
        XCTAssertEqual(vectorLows[31], 0x000f_000b_0007_0003)
        XCTAssertEqual(vectorHighs[31], 0x001f_001b_0017_0013)
    }

    func testFullRegisterRunnerExecutesSIMDIntegerNegate() {
        let program: [UInt32] = [
            0x2ea0_bbfd, // neg v29.2s, v31.2s (live Wayland client instruction)
            0x4f30_57ff, // shl v31.4s, v31.4s, #16 (live Wayland client instruction)
            0x2e28_c30c, // umull v12.8h, v24.8b, v8.8b (live kernel instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE)
        XCTAssertEqual(decoded[0].bits, 32)
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].shift_amount, 16)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG)
        XCTAssertEqual(decoded[2].bits, 8)
        XCTAssertEqual(decoded[2].flags, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1f_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0x0000_0002_ffff_ffff
        vectorLows[24] = 0x0807_0605_0403_0201
        vectorLows[8] = 0x0101_0101_0101_0101

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[29], 0xffff_fffe_0000_0001)
        XCTAssertEqual(vectorHighs[29], 0)
        XCTAssertEqual(vectorLows[31], 0x0002_0000_ffff_0000)
        XCTAssertEqual(vectorHighs[31], 0xffff_0000_ffff_0000)
        XCTAssertEqual(vectorLows[12], 0x0004_0003_0002_0001)
        XCTAssertEqual(vectorHighs[12], 0x0008_0007_0006_0005)
    }

    func testFullRegisterRunnerExecutesSIMDScalarDNegate() {
        let program: [UInt32] = [
            0x7ee0_bbaf, // neg d15, d29 (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE)
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].flags, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x17_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[29] = 7

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 4,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[15], UInt64.max - 6)
        XCTAssertEqual(vectorHighs[15], 0)
    }

    func testFullRegisterRunnerExecutesSIMDLogicalWordImmediateFamily() {
        let program: [UInt32] = [
            0x4f04_741f, // orr v31.4s, #0x80, lsl #24 (live Phosh instruction)
            0x0f00_1640, // orr v0.2s, #0x12
            0x6f05_7785, // bic v5.4s, #0xbc, lsl #24
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE)
        XCTAssertEqual(decoded[0].flags, 3)
        XCTAssertEqual(decoded[0].immediate, 0x8000_0000)
        XCTAssertEqual(decoded[1].flags, 2)
        XCTAssertEqual(decoded[2].flags, 5)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x18_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0x0000_0001_0000_0002
        vectorHighs[31] = 0x0000_0003_0000_0004
        vectorLows[0] = 0x1000_0000_2000_0000
        vectorHighs[0] = UInt64.max
        vectorLows[5] = UInt64.max
        vectorHighs[5] = UInt64.max

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 0x8000_0001_8000_0002)
        XCTAssertEqual(vectorHighs[31], 0x8000_0003_8000_0004)
        XCTAssertEqual(vectorLows[0], 0x1000_0012_2000_0012)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[5], 0x43ff_ffff_43ff_ffff)
        XCTAssertEqual(vectorHighs[5], 0x43ff_ffff_43ff_ffff)
    }

    func testFullRegisterRunnerSeparatesRenderingSIMDEncodingFamilies() {
        let program: [UInt32] = [
            0x2ea1_47e1, // ushl v1.2s, v31.2s, v1.2s
            0x4f99_131f, // fmla v31.4s, v24.4s, v25.s[0]
            0x4e21_9bde, // frintm v30.4s, v30.4s
            0x4f07_87e6, // movi v6.8h, #255
            0x2f08_a4d0, // ushll v16.8h, v6.8b, #0
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD)
        XCTAssertNotEqual(decoded[1].flags & 8, 0)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL)
        XCTAssertNotEqual(decoded[2].flags & 16, 0)
        XCTAssertEqual(Int(decoded[3].kind), AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE)
        XCTAssertEqual(decoded[3].bits, 16)
        XCTAssertEqual(Int(decoded[4].kind), AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D)
        XCTAssertNotEqual(decoded[4].flags & 1, 0)

        func packed(_ lower: Float, _ upper: Float) -> UInt64 {
            UInt64(lower.bitPattern) | (UInt64(upper.bitPattern) << 32)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x19_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[1] = UInt64(UInt32(bitPattern: -4)) | (UInt64(1) << 32)
        vectorLows[24] = packed(10, 20)
        vectorHighs[24] = packed(30, 40)
        vectorLows[25] = packed(0.5, 0)
        vectorLows[31] = packed(1, 2)
        vectorHighs[31] = packed(3, 4)
        vectorLows[30] = packed(1.9, -1.1)
        vectorHighs[30] = packed(3, -0.0)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[1], UInt64(0x03f8_0000) | (UInt64(0x8000_0000) << 32))
        XCTAssertEqual(vectorLows[31], packed(6, 12))
        XCTAssertEqual(vectorHighs[31], packed(18, 24))
        XCTAssertEqual(vectorLows[30], packed(1, -2))
        XCTAssertEqual(vectorHighs[30], packed(3, -0.0))
        XCTAssertEqual(vectorLows[6], 0x00ff_00ff_00ff_00ff)
        XCTAssertEqual(vectorHighs[6], 0x00ff_00ff_00ff_00ff)
        XCTAssertEqual(vectorLows[16], 0x0000_00ff_0000_00ff)
        XCTAssertEqual(vectorHighs[16], 0x0000_00ff_0000_00ff)
    }

    func testFullRegisterRunnerExecutesSIMDNarrowHighFamily() {
        let program: [UInt32] = [
            0x2e30_4180, // raddhn v0.8b, v12.8h, v16.8h (live renderer instruction)
            0x4e22_4020, // addhn2 v0.16b, v1.8h, v2.8h
            0x2e25_6083, // rsubhn v3.8b, v4.8h, v5.8h
            0x2e20_5879, // mvn v25.8b, v3.8b (live kernel instruction)
            0x6e20_58da, // mvn v26.16b, v6.16b
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_NARROW_HIGH)
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].flags, 2)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(decoded[2].flags, 6)
        XCTAssertEqual(Int(decoded[3].kind), AVZ_NATIVE_OP_SIMD_BITWISE_NOT)
        XCTAssertEqual(decoded[3].flags, 0)
        XCTAssertEqual(decoded[4].flags, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[12] = 0x0100_00ff_0080_007f
        vectorHighs[12] = 0x8000_ffff_0180_017f
        vectorLows[1] = 0x0100_0100_0100_0100
        vectorHighs[1] = 0x0100_0100_0100_0100
        vectorLows[5] = 0x0081_0081_0081_0081
        vectorHighs[5] = 0x0081_0081_0081_0081
        vectorLows[6] = 0x0123_4567_89ab_cdef
        vectorHighs[6] = 0xfedc_ba98_7654_3210

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[0], 0x8000_0201_0101_0100)
        XCTAssertEqual(vectorHighs[0], 0x0101_0101_0101_0101)
        XCTAssertEqual(vectorLows[3], UInt64.max)
        XCTAssertEqual(vectorHighs[3], 0)
        XCTAssertEqual(vectorLows[25], 0)
        XCTAssertEqual(vectorHighs[25], 0)
        XCTAssertEqual(vectorLows[26], 0xfedc_ba98_7654_3210)
        XCTAssertEqual(vectorHighs[26], 0x0123_4567_89ab_cdef)
    }

    func testFullRegisterRunnerExecutesSIMDShiftRightNarrowFamily() {
        let program: [UInt32] = [
            0x0f0c_8420, // shrn v0.8b, v1.8h, #4
            0x4f08_8462, // shrn2 v2.16b, v3.8h, #8
            0x0f14_84a4, // shrn v4.4h, v5.4s, #12
            0x4f20_856a, // shrn2 v10.4s, v11.2d, #32
            0x0f0c_8400, // shrn v0.8b, v0.8h, #4 (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_NARROW_HIGH)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].shift_amount, 4)
        XCTAssertEqual(decoded[1].flags, 9)
        XCTAssertEqual(decoded[2].bits, 32)
        XCTAssertEqual(decoded[3].bits, 64)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x24_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x00f0_00e0_00d0_00c0
        vectorHighs[1] = 0x00b0_00a0_0090_0080
        vectorLows[2] = 0x0706_0504_0302_0100
        vectorLows[3] = 0x0800_0700_0600_0500
        vectorHighs[3] = 0x0400_0300_0200_0100
        vectorLows[5] = 0x0001_2000_0001_1000
        vectorHighs[5] = 0x0001_0000_0000_f000
        vectorLows[10] = 0x1111_1111_2222_2222
        vectorHighs[10] = 0x3333_3333_4444_4444
        vectorLows[11] = 0xaaaa_bbbb_0000_0000
        vectorHighs[11] = 0xcccc_dddd_0000_0000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorHighs[2], 0x0403_0201_0807_0605)
        XCTAssertEqual(vectorLows[4], 0x0010_000f_0012_0011)
        XCTAssertEqual(vectorLows[10], 0x1111_1111_2222_2222)
        XCTAssertEqual(vectorHighs[10], 0xcccc_dddd_aaaa_bbbb)
    }

    func testFullRegisterRunnerExecutesSIMDExtractNarrowFamily() {
        let program: [UInt32] = [
            0x0e21_2800, // xtn v0.8b, v0.8h (live Phosh instruction)
            0x4e21_2862, // xtn2 v2.16b, v3.8h
            0x0e61_28a4, // xtn v4.4h, v5.4s
            0x4e61_28e6, // xtn2 v6.8h, v7.4s
            0x0ea1_2928, // xtn v8.2s, v9.2d
            0x4ea1_296a, // xtn2 v10.4s, v11.2d
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_NARROW_HIGH)
            XCTAssertNotEqual(instruction.flags & 32, 0)
        }
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].flags, 32)
        XCTAssertEqual(decoded[1].flags, 33)
        XCTAssertEqual(decoded[2].bits, 32)
        XCTAssertEqual(decoded[4].bits, 64)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x27_100
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0x047f_0380_02ff_0100
        vectorHighs[0] = 0x08dd_07cc_06bb_05aa
        vectorLows[2] = 0x7766_5544_3322_1100
        vectorHighs[2] = UInt64.max
        vectorLows[3] = 0x0044_0033_0022_0011
        vectorHighs[3] = 0x0088_0077_0066_0055
        vectorLows[5] = 0xbbbb_2222_aaaa_1111
        vectorHighs[5] = 0xdddd_4444_cccc_3333
        vectorLows[6] = 0x1234_5678_9abc_def0
        vectorHighs[6] = UInt64.max
        vectorLows[7] = 0x2222_bbbb_1111_aaaa
        vectorHighs[7] = 0x4444_dddd_3333_cccc
        vectorLows[9] = 0x1111_1111_89ab_cdef
        vectorHighs[9] = 0x2222_2222_0123_4567
        vectorLows[10] = 0x7654_3210_fedc_ba98
        vectorHighs[10] = UInt64.max
        vectorLows[11] = 0x1111_1111_dead_beef
        vectorHighs[11] = 0x2222_2222_cafe_babe

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 10,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 7)
        XCTAssertEqual(vectorLows[0], 0xddcc_bbaa_7f80_ff00)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[2], 0x7766_5544_3322_1100)
        XCTAssertEqual(vectorHighs[2], 0x8877_6655_4433_2211)
        XCTAssertEqual(vectorLows[4], 0x4444_3333_2222_1111)
        XCTAssertEqual(vectorHighs[4], 0)
        XCTAssertEqual(vectorLows[6], 0x1234_5678_9abc_def0)
        XCTAssertEqual(vectorHighs[6], 0xdddd_cccc_bbbb_aaaa)
        XCTAssertEqual(vectorLows[8], 0x0123_4567_89ab_cdef)
        XCTAssertEqual(vectorHighs[8], 0)
        XCTAssertEqual(vectorLows[10], 0x7654_3210_fedc_ba98)
        XCTAssertEqual(vectorHighs[10], 0xcafe_babe_dead_beef)
    }

    func testFullRegisterRunnerExecutesSIMDRoundingShiftRightNarrowFamily() {
        let program: [UInt32] = [
            0x0f08_8d1c, // rshrn v28.8b, v8.8h, #8 (live Phosh instruction)
            0x0f14_8c20, // rshrn v0.4h, v1.4s, #12
            0x4f0b_8c62, // rshrn2 v2.16b, v3.8h, #5
            0x4f20_8ca4, // rshrn2 v4.4s, v5.2d, #32
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_NARROW_HIGH)
            XCTAssertNotEqual(instruction.flags & 8, 0)
            XCTAssertNotEqual(instruction.flags & 16, 0)
        }
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].shift_amount, 8)
        XCTAssertEqual(decoded[0].flags, 24)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].shift_amount, 12)
        XCTAssertEqual(decoded[2].flags, 25)
        XCTAssertEqual(decoded[3].bits, 64)
        XCTAssertEqual(decoded[3].shift_amount, 32)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x27_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[8] = 0x0180_017f_0080_007f
        vectorHighs[8] = 0xff80_ff7f_7fff_7f80
        vectorLows[1] = 0x0000_17ff_0000_0800
        vectorHighs[1] = 0xffff_f800_0000_07ff
        vectorLows[2] = 0x7766_5544_3322_1100
        vectorHighs[2] = 0xaaaa_bbbb_cccc_dddd
        vectorLows[3] = 0x0030_002f_0010_000f
        vectorHighs[3] = 0xfff0_ffef_1fef_1ff0
        vectorLows[4] = 0x2222_2222_1111_1111
        vectorHighs[4] = 0x4444_4444_3333_3333
        vectorLows[5] = 0x0000_0000_7fff_ffff
        vectorHighs[5] = 0x0000_0000_8000_0000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(vectorLows[28], 0x00ff_8080_0201_0100)
        XCTAssertEqual(vectorHighs[28], 0)
        XCTAssertEqual(vectorLows[0], 0x0000_0000_0001_0001)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[2], 0x7766_5544_3322_1100)
        XCTAssertEqual(vectorHighs[2], 0x00ff_ff00_0201_0100)
        XCTAssertEqual(vectorLows[4], 0x2222_2222_1111_1111)
        XCTAssertEqual(vectorHighs[4], 0x0000_0001_0000_0000)
    }

    func testFullRegisterRunnerExecutesSIMDReverseElementFamilies() {
        let program: [UInt32] = [
            0x0e20_1820, // rev16 v0.8b, v1.8b
            0x6e20_0928, // rev32 v8.16b, v9.16b
            0x2e60_08e6, // rev32 v6.4h, v7.4h
            0x0ea0_0a30, // rev64 v16.2s, v17.2s
            0x0ea0_0bde, // rev64 v30.2s, v30.2s (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].shift_amount, 16)
        XCTAssertEqual(decoded[1].shift_amount, 32)
        XCTAssertEqual(decoded[3].bits, 32)
        XCTAssertEqual(decoded[3].shift_amount, 64)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x28_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x0706_0504_0302_0100
        vectorLows[9] = 0x0706_0504_0302_0100
        vectorHighs[9] = 0x0f0e_0d0c_0b0a_0908
        vectorLows[7] = 0x4444_3333_2222_1111
        vectorLows[17] = 0x2222_2222_1111_1111
        vectorLows[30] = 0x89ab_cdef_0123_4567
        vectorHighs[30] = 0x7654_3210_fedc_ba98

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorLows[0], 0x0607_0405_0203_0001)
        XCTAssertEqual(vectorLows[8], 0x0405_0607_0001_0203)
        XCTAssertEqual(vectorHighs[8], 0x0c0d_0e0f_0809_0a0b)
        XCTAssertEqual(vectorLows[6], 0x3333_4444_1111_2222)
        XCTAssertEqual(vectorLows[16], 0x1111_1111_2222_2222)
        XCTAssertEqual(vectorLows[30], 0x0123_4567_89ab_cdef)
        XCTAssertEqual(vectorHighs[30], 0)
    }

    func testFullRegisterRunnerExecutesSIMDSubtractVector() {
        let program: [UInt32] = [
            0x6efd_87ff, // sub v31.2d, v31.2d, v29.2d (live rootfs instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_ADD_VECTOR)
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].flags, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 10
        vectorHighs[31] = 3
        vectorLows[29] = 4
        vectorHighs[29] = 8

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 6)
        XCTAssertEqual(vectorHighs[31], UInt64.max - 4)
    }

    func testFullRegisterRunnerExecutesSIMDScalarAddSubtractFamily() {
        let program: [UInt32] = [
            0x5eff_85ef, // add d15, d15, d31 (live Phosh instruction)
            0x5ee2_8420, // add d0, d1, d2
            0x7ee5_8483, // sub d3, d4, d5
            0x7eff_87ff, // sub d31, d31, d31
            0xd440_0000
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_ADD_VECTOR)
            XCTAssertEqual(instruction.bits, 64)
        }
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[2].flags, 2)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_100
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[15] = UInt64.max - 2
        vectorLows[31] = 5
        vectorLows[1] = 10
        vectorLows[2] = 20
        vectorLows[4] = 3
        vectorLows[5] = 8

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(vectorLows[15], 2)
        XCTAssertEqual(vectorHighs[15], 0)
        XCTAssertEqual(vectorLows[0], 30)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[3], UInt64.max - 4)
        XCTAssertEqual(vectorHighs[3], 0)
        XCTAssertEqual(vectorLows[31], 0)
        XCTAssertEqual(vectorHighs[31], 0)
    }

    func testFullRegisterRunnerExecutesSIMDUnsignedVariableShift() {
        let program: [UInt32] = [
            0x6eff_475f, // ushl v31.2d, v26.2d, v31.2d (live musl instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER)
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].flags, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[26] = 3
        vectorHighs[26] = 0x8000_0000_0000_0000
        vectorLows[31] = 2
        vectorHighs[31] = UInt64.max

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 12)
        XCTAssertEqual(vectorHighs[31], 0x4000_0000_0000_0000)
    }

    func testFullRegisterRunnerExecutesSIMDSaturatingAddSubtractFamily() {
        let program: [UInt32] = [
            0x2e3c_0c1c, // uqadd v28.8b, v0.8b, v28.8b (live renderer instruction)
            0x4ee3_0c41, // sqadd v1.2d, v2.2d, v3.2d
            0x6e26_2ca4, // uqsub v4.16b, v5.16b, v6.16b
            0x4e69_2d07, // sqsub v7.8h, v8.8h, v9.8h
            0x5e3a_0f7b, // sqadd b27, b27, b26
            0x7e7f_2fde, // uqsub h30, h30, h31 (live BusyBox instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].flags, 2)
        XCTAssertEqual(decoded[1].bits, 64)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(decoded[2].flags, 7)
        XCTAssertEqual(decoded[3].bits, 16)
        XCTAssertEqual(decoded[3].flags, 5)
        XCTAssertEqual(decoded[4].bits, 8)
        XCTAssertEqual(decoded[4].flags, 8)
        XCTAssertEqual(decoded[5].bits, 16)
        XCTAssertEqual(decoded[5].flags, 14)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x21_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 4
        var halted: UInt8 = 0
        vectorLows[0] = 0x0101_0101_0101_0101
        vectorLows[28] = 0xfffe_fdfc_fbfa_f9f8
        vectorLows[2] = UInt64(bitPattern: Int64.max)
        vectorHighs[2] = UInt64(bitPattern: Int64.min)
        vectorLows[3] = 1
        vectorHighs[3] = UInt64.max
        vectorLows[6] = 0x0101_0101_0101_0101
        vectorHighs[6] = 0x0101_0101_0101_0101
        vectorLows[8] = 0x0005_0005_0005_0005
        vectorHighs[8] = 0x0005_0005_0005_0005
        vectorLows[9] = 0x0003_0003_0003_0003
        vectorHighs[9] = 0x0003_0003_0003_0003
        vectorLows[26] = 1
        vectorLows[27] = 0x7f
        vectorHighs[27] = UInt64.max
        vectorLows[30] = 2
        vectorLows[31] = 5
        vectorHighs[30] = UInt64.max

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        XCTAssertEqual(vectorLows[28], 0xffff_fefd_fcfb_faf9)
        XCTAssertEqual(vectorHighs[28], 0)
        XCTAssertEqual(vectorLows[1], UInt64(bitPattern: Int64.max))
        XCTAssertEqual(vectorHighs[1], UInt64(bitPattern: Int64.min))
        XCTAssertEqual(vectorLows[4], 0)
        XCTAssertEqual(vectorHighs[4], 0)
        XCTAssertEqual(vectorLows[7], 0x0002_0002_0002_0002)
        XCTAssertEqual(vectorHighs[7], 0x0002_0002_0002_0002)
        XCTAssertEqual(vectorLows[27], 0x7f)
        XCTAssertEqual(vectorHighs[27], 0)
        XCTAssertEqual(vectorLows[30], 0)
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(fpsr, (UInt64(1) << 27) | 4)
    }

    func testFullRegisterRunnerExecutesPixmanShiftInsertSequence() {
        let program: [UInt32] = [
            0x6f15_5400, // sli v0.8h, v0.8h, #5
            0x2f0b_47de, // sri v30.8b, v30.8b, #5
            0x2f0a_47bd, // sri v29.8b, v29.8b, #6
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE)
        XCTAssertEqual(decoded[0].bits, 16)
        XCTAssertEqual(decoded[0].shift_amount, 5)
        XCTAssertEqual(decoded[0].flags, 3)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE)
        XCTAssertEqual(decoded[1].bits, 8)
        XCTAssertEqual(decoded[1].shift_amount, 5)
        XCTAssertEqual(decoded[1].flags, 10)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE)
        XCTAssertEqual(decoded[2].shift_amount, 6)
        XCTAssertEqual(decoded[2].flags, 10)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x21_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0x1234_1234_1234_1234
        vectorHighs[0] = 0x1234_1234_1234_1234
        vectorLows[30] = 0xe0e0_e0e0_e0e0_e0e0
        vectorHighs[30] = 0xe0e0_e0e0_e0e0_e0e0
        vectorLows[29] = 0xc0c0_c0c0_c0c0_c0c0
        vectorHighs[29] = 0xc0c0_c0c0_c0c0_c0c0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        XCTAssertEqual(vectorLows[0], 0x4694_4694_4694_4694)
        XCTAssertEqual(vectorHighs[0], 0x4694_4694_4694_4694)
        XCTAssertEqual(vectorLows[30], 0xe7e7_e7e7_e7e7_e7e7)
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(vectorLows[29], 0xc3c3_c3c3_c3c3_c3c3)
        XCTAssertEqual(vectorHighs[29], 0)
    }

    func testFullRegisterRunnerExecutesPixmanRGB565ToBGRALoop() {
        let program: [UInt32] = [
            0x0cdf_a480, // ld1 {v0.4h, v1.4h}, [x4], #16
            0x6e18_0420, // mov v0.d[1], v1.d[0]
            0x0f08_841e, // shrn v30.8b, v0.8h, #8
            0x0f0d_841d, // shrn v29.8b, v0.8h, #3
            0x6f15_5400, // sli v0.8h, v0.8h, #5
            0x0f07_e7ff, // movi v31.8b, #0xff
            0x2f0b_47de, // sri v30.8b, v30.8b, #5
            0x2f0a_47bd, // sri v29.8b, v29.8b, #6
            0x0f0e_841c, // shrn v28.8b, v0.8h, #2
            0x4e08_3e0f, // mov x15, v16.d[0]
            0x0e1e_3b90, // zip1 v16.8b, v28.8b, v30.8b
            0x0e1e_7b9e, // zip2 v30.8b, v28.8b, v30.8b
            0x0eb0_1e1c, // mov v28.8b, v16.8b
            0x4e08_1df0, // mov v16.d[0], x15
            0x4e08_3e0f, // mov x15, v16.d[0]
            0x0e1f_3bb0, // zip1 v16.8b, v29.8b, v31.8b
            0x0e1f_7bbf, // zip2 v31.8b, v29.8b, v31.8b
            0x0eb0_1e1d, // mov v29.8b, v16.8b
            0x4e08_1df0, // mov v16.d[0], x15
            0x4e08_3e0f, // mov x15, v16.d[0]
            0x0e1f_3bd0, // zip1 v16.8b, v30.8b, v31.8b
            0x0e1f_7bdf, // zip2 v31.8b, v30.8b, v31.8b
            0x0eb0_1e1e, // mov v30.8b, v16.8b
            0x4e08_1df0, // mov v16.d[0], x15
            0x4e08_3e0f, // mov x15, v16.d[0]
            0x0e1d_3b90, // zip1 v16.8b, v28.8b, v29.8b
            0x0e1d_7b9d, // zip2 v29.8b, v28.8b, v29.8b
            0x0eb0_1e1c, // mov v28.8b, v16.8b
            0x4e08_1df0, // mov v16.d[0], x15
            0x0c9f_285c, // st1 {v28.2s-v31.2s}, [x2], #32
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertFalse(decoded.dropLast().contains { $0.kind == 0 })

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x22_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[2] = 0x2_000
        registers[4] = 0x1_000
        for index in 0..<8 {
            memory.write(0xef7d, at: 0x1_000 + UInt64(index * 2), width: 2)
        }

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 64,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nativeTestMemoryRead, nativeTestMemoryWrite,
                            nativeTestMemoryCanAccess, nil,
                            Unmanaged.passUnretained(memory).toOpaque()
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[2], 0x2_020)
        XCTAssertEqual(registers[4], 0x1_010)
        for index in 0..<8 {
            XCTAssertEqual(
                memory.read(at: 0x2_000 + UInt64(index * 4), width: 4),
                0xffef_efef,
                "pixel \(index)"
            )
        }
    }

    func testNativeBlockCacheExecutesPixmanSolidFillWithoutZeroLanes() throws {
        let program: [UInt32] = [
            0x4e04_1c80, // mov v0.s[0], w4
            0x0e04_0403, // dup v3.2s, v0.s[0]
            0x0e04_0402, // dup v2.2s, v0.s[0]
            0x0e04_0401, // dup v1.2s, v0.s[0]
            0x0e04_0400, // dup v0.2s, v0.s[0]
            0x0c9f_2840, // st1 {v0.2s-v3.2s}, [x2], #32
            0xd440_0000  // hlt #0
        ]
        let fetch = NativeBlockFetchContext(words: program, virtualBase: 0x23_000)
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        var key = AVZNativeBlockKey(
            pc: 0x23_000,
            sctlr_el1: 1,
            tcr_el1: 0,
            ttbr0_el1: 0,
            ttbr1_el1: 0,
            current_el: 1
        )
        var status: UInt32 = 0
        var unsupported: UInt32 = 0
        let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
            cache,
            &key,
            nativeBlockFetch,
            Unmanaged.passUnretained(fetch).toOpaque(),
            &status,
            &unsupported
        ))

        XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
        XCTAssertEqual(unsupported, 0)
        let instructionCount = avz_native_decoded_block_instruction_count(block)
        XCTAssertEqual(instructionCount, program.count - 1)
        XCTAssertNotEqual(avz_native_decoded_block_uses_vector_state(block), 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x23_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        let memory = NativeTestMemory()
        registers[2] = 0x2_000
        registers[4] = 0xffed_edef

        let instructions = try XCTUnwrap(avz_native_decoded_block_instructions(block))
        let result = registers.withUnsafeMutableBufferPointer { registerBuffer in
            vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                    avz_native_run_threaded_decoded_block_full_registers(
                        instructions, instructionCount, pc, UInt64(program.count),
                        registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                        vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                        &halted, nativeTestMemoryRead, nativeTestMemoryWrite,
                        nativeTestMemoryCanAccess, nil,
                        Unmanaged.passUnretained(memory).toOpaque()
                    )
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK))
        XCTAssertEqual(registers[2], 0x2_020)
        for index in 0..<8 {
            XCTAssertEqual(
                memory.read(at: 0x2_000 + UInt64(index * 4), width: 4),
                0xffed_edef,
                "pixel \(index)"
            )
        }
    }

    func testFullRegisterRunnerExecutesSIMDShiftRightImmediateFamily() {
        let program: [UInt32] = [
            0x7f51_07dd, // ushr d29, d30, #47 (live renderer instruction)
            0x5f40_0420, // sshr d0, d1, #64
            0x6f09_0422, // ushr v2.16b, v1.16b, #7
            0x4f21_0483, // sshr v3.4s, v4.4s, #31
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE)
        }
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].shift_amount, 47)
        XCTAssertEqual(decoded[0].flags, 6)
        XCTAssertEqual(decoded[1].shift_amount, 64)
        XCTAssertEqual(decoded[1].flags, 4)
        XCTAssertEqual(decoded[2].bits, 8)
        XCTAssertEqual(decoded[2].shift_amount, 7)
        XCTAssertEqual(decoded[2].flags, 3)
        XCTAssertEqual(decoded[3].bits, 32)
        XCTAssertEqual(decoded[3].shift_amount, 31)
        XCTAssertEqual(decoded[3].flags, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x22_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[30] = 0x8000_0000_0000_0000
        vectorLows[1] = 0x8080_8080_8080_8080
        vectorHighs[1] = 0x8080_8080_8080_8080
        vectorLows[4] = 0x7fff_ffff_8000_0000
        vectorHighs[4] = 0xffff_ffff_0000_0001

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            5,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[29], 0x1_0000)
        XCTAssertEqual(vectorHighs[29], 0)
        XCTAssertEqual(vectorLows[0], UInt64.max)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[2], 0x0101_0101_0101_0101)
        XCTAssertEqual(vectorHighs[2], 0x0101_0101_0101_0101)
        XCTAssertEqual(vectorLows[3], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[3], 0xffff_ffff_0000_0000)
    }

    func testFullRegisterRunnerExecutesRoundedAndAccumulatingShiftRightFamily() {
        let program: [UInt32] = [
            0x6f18_2551, // urshr v17.8h, v10.8h, #8 (Pixman blend path)
            0x6f18_1552, // usra v18.8h, v10.8h, #8
            0x6f18_3553, // ursra v19.8h, v10.8h, #8
            0x4f18_2574, // srshr v20.8h, v11.8h, #8
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE)
            XCTAssertEqual(instruction.bits, 16)
            XCTAssertEqual(instruction.shift_amount, 8)
        }
        XCTAssertEqual(decoded[0].flags, 19)
        XCTAssertEqual(decoded[1].flags, 35)
        XCTAssertEqual(decoded[2].flags, 51)
        XCTAssertEqual(decoded[3].flags, 17)

        let unsignedInputs: [UInt16] = [0, 127, 128, 255, 256, 383, 384, 65_535]
        let signedInputs: [Int16] = [0, 127, 128, 255, 256, -1, -128, -32_768]
        func packed(_ values: [UInt16], half: Int) -> UInt64 {
            values[(half * 4)..<(half * 4 + 4)].enumerated().reduce(0) { partial, pair in
                partial | (UInt64(pair.element) << (pair.offset * 16))
            }
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x24_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[10] = packed(unsignedInputs, half: 0)
        vectorHighs[10] = packed(unsignedInputs, half: 1)
        let signedBits = signedInputs.map { UInt16(bitPattern: $0) }
        vectorLows[11] = packed(signedBits, half: 0)
        vectorHighs[11] = packed(signedBits, half: 1)
        vectorLows[18] = packed(Array(repeating: 3, count: 8), half: 0)
        vectorHighs[18] = packed(Array(repeating: 3, count: 8), half: 1)
        vectorLows[19] = vectorLows[18]
        vectorHighs[19] = vectorHighs[18]

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.generic_dispatches, 0)
        let rounded = unsignedInputs.map { UInt16((UInt32($0) + 128) >> 8) }
        let shifted = unsignedInputs.map { UInt16(UInt32($0) >> 8) }
        let signedRounded = signedInputs.map {
            UInt16(truncatingIfNeeded: (Int32($0) + 128) >> 8)
        }
        XCTAssertEqual(vectorLows[17], packed(rounded, half: 0))
        XCTAssertEqual(vectorHighs[17], packed(rounded, half: 1))
        XCTAssertEqual(vectorLows[18], packed(shifted.map { $0 &+ 3 }, half: 0))
        XCTAssertEqual(vectorHighs[18], packed(shifted.map { $0 &+ 3 }, half: 1))
        XCTAssertEqual(vectorLows[19], packed(rounded.map { $0 &+ 3 }, half: 0))
        XCTAssertEqual(vectorHighs[19], packed(rounded.map { $0 &+ 3 }, half: 1))
        XCTAssertEqual(vectorLows[20], packed(signedRounded, half: 0))
        XCTAssertEqual(vectorHighs[20], packed(signedRounded, half: 1))
    }

    func testFullRegisterRunnerExecutesSIMDInsertVectorElementFamily() {
        let program: [UInt32] = [
            0x6e01_7c20, // mov v0.b[0], v1.b[15]
            0x6e06_0462, // mov v2.h[1], v3.h[0]
            0x6e14_64a4, // mov v4.s[2], v5.s[3]
            0x6e18_04e6, // mov v6.d[1], v7.d[0]
            0x6e06_07bf, // mov v31.h[1], v29.h[0] (live renderer instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT)
        }
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(decoded[0].shift_amount, 15)
        XCTAssertEqual(decoded[2].bits, 32)
        XCTAssertEqual(decoded[2].condition, 2)
        XCTAssertEqual(decoded[2].shift_amount, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x23_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0x1122_3344_5566_7788
        vectorHighs[0] = 0x99aa_bbcc_ddee_ff00
        vectorHighs[1] = 0xab00_0000_0000_0000
        vectorLows[2] = 0x1111_2222_3333_4444
        vectorLows[3] = 0x0000_0000_0000_beef
        vectorHighs[4] = 0x1111_2222_3333_4444
        vectorHighs[5] = 0xdead_beef_0000_0000
        vectorHighs[6] = 0xfeed_face_cafe_babe
        vectorLows[7] = 0x0123_4567_89ab_cdef
        vectorLows[29] = 0x0000_0000_0000_1357
        vectorLows[31] = 0xffff_ffff_ffff_ffff

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorLows[0], 0x1122_3344_5566_77ab)
        XCTAssertEqual(vectorHighs[0], 0x99aa_bbcc_ddee_ff00)
        XCTAssertEqual(vectorLows[2], 0x1111_2222_beef_4444)
        XCTAssertEqual(vectorHighs[4], 0x1111_2222_dead_beef)
        XCTAssertEqual(vectorHighs[6], 0x0123_4567_89ab_cdef)
        XCTAssertEqual(vectorLows[31], 0xffff_ffff_1357_ffff)
    }

    func testFullRegisterRunnerExecutesScalarFusedMultiplyAddFamily() {
        let program: [UInt32] = [
            0x1f4c_7c1f, // fmadd d31, d0, d12, d31 (live Cage instruction)
            0x1f42_0c20, // fmadd d0, d1, d2, d3
            0x1f46_9ca4, // fmsub d4, d5, d6, d7
            0x1f2a_2d28, // fnmadd s8, s9, s10, s11
            0x1f2e_bdac, // fnmsub s12, s13, s14, s15
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD)
        }
        XCTAssertEqual(decoded[0].rd, 31)
        XCTAssertEqual(decoded[0].rn, 0)
        XCTAssertEqual(decoded[0].rm, 12)
        XCTAssertEqual(decoded[0].rt, 31)
        XCTAssertEqual(decoded[0].flags, 4)
        XCTAssertEqual(decoded[2].flags, 5)
        XCTAssertEqual(decoded[3].flags, 2)
        XCTAssertEqual(decoded[4].flags, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x18_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = Double(2).bitPattern
        vectorLows[12] = Double(3).bitPattern
        vectorLows[31] = Double(5).bitPattern
        vectorLows[1] = Double(2).bitPattern
        vectorLows[2] = Double(4).bitPattern
        vectorLows[3] = Double(1).bitPattern
        vectorLows[5] = Double(4).bitPattern
        vectorLows[6] = Double(2).bitPattern
        vectorLows[7] = Double(1).bitPattern
        vectorLows[9] = UInt64(Float(2).bitPattern)
        vectorLows[10] = UInt64(Float(3).bitPattern)
        vectorLows[11] = UInt64(Float(4).bitPattern)
        vectorLows[13] = UInt64(Float(2).bitPattern)
        vectorLows[14] = UInt64(Float(3).bitPattern)
        vectorLows[15] = UInt64(Float(4).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Double(bitPattern: vectorLows[31]), 11)
        XCTAssertEqual(Double(bitPattern: vectorLows[0]), 9)
        XCTAssertEqual(Double(bitPattern: vectorLows[4]), -7)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[8])), -10)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[12])), 2)
        for register in [0, 4, 8, 12, 31] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesVectorFusedMultiplyAddFamily() {
        let program: [UInt32] = [
            0x0e3e_cfbc, // fmla v28.2s, v29.2s, v30.2s (live Settings instruction)
            0x4e22_cc20, // fmla v0.4s, v1.4s, v2.4s
            0x4ea5_cc83, // fmls v3.4s, v4.4s, v5.4s
            0x4e68_cce6, // fmla v6.2d, v7.2d, v8.2d
            0x4eeb_cd49, // fmls v9.2d, v10.2d, v11.2d
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD)
        }
        XCTAssertEqual(decoded[0].flags, 8)
        XCTAssertEqual(decoded[1].flags, 24)
        XCTAssertEqual(decoded[2].flags, 25)
        XCTAssertEqual(decoded[3].flags, 28)
        XCTAssertEqual(decoded[4].flags, 29)

        func packed(_ lower: Float, _ upper: Float) -> UInt64 {
            UInt64(lower.bitPattern) | (UInt64(upper.bitPattern) << 32)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x18_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[28] = packed(1, 2)
        vectorLows[29] = packed(3, 4)
        vectorLows[30] = packed(5, 6)

        vectorLows[0] = packed(1, 2)
        vectorHighs[0] = packed(3, 4)
        vectorLows[1] = packed(2, 3)
        vectorHighs[1] = packed(4, 5)
        vectorLows[2] = packed(0.5, 1)
        vectorHighs[2] = packed(1.5, 2)

        vectorLows[3] = packed(10, 20)
        vectorHighs[3] = packed(30, 40)
        vectorLows[4] = packed(1, 2)
        vectorHighs[4] = packed(3, 4)
        vectorLows[5] = packed(2, 3)
        vectorHighs[5] = packed(4, 5)

        vectorLows[6] = Double(1).bitPattern
        vectorHighs[6] = Double(2).bitPattern
        vectorLows[7] = Double(3).bitPattern
        vectorHighs[7] = Double(4).bitPattern
        vectorLows[8] = Double(5).bitPattern
        vectorHighs[8] = Double(6).bitPattern

        vectorLows[9] = Double(10).bitPattern
        vectorHighs[9] = Double(20).bitPattern
        vectorLows[10] = Double(2).bitPattern
        vectorHighs[10] = Double(3).bitPattern
        vectorLows[11] = Double(4).bitPattern
        vectorHighs[11] = Double(5).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[28], packed(16, 26))
        XCTAssertEqual(vectorHighs[28], 0)
        XCTAssertEqual(vectorLows[0], packed(2, 5))
        XCTAssertEqual(vectorHighs[0], packed(9, 14))
        XCTAssertEqual(vectorLows[3], packed(8, 14))
        XCTAssertEqual(vectorHighs[3], packed(18, 20))
        XCTAssertEqual(Double(bitPattern: vectorLows[6]), 16)
        XCTAssertEqual(Double(bitPattern: vectorHighs[6]), 26)
        XCTAssertEqual(Double(bitPattern: vectorLows[9]), 2)
        XCTAssertEqual(Double(bitPattern: vectorHighs[9]), 5)
    }

    func testFullRegisterRunnerExecutesScalarFPUnaryFamily() {
        let program: [UInt32] = [
            0x1e20_c020, // fabs s0, s1
            0x1e60_c062, // fabs d2, d3
            0x1e21_40a4, // fneg s4, s5
            0x1e61_40e6, // fneg d6, d7
            0x1e21_c128, // fsqrt s8, s9
            0x1e61_c16a, // fsqrt d10, d11
            0x1e61_41ef, // fneg d15, d15 (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_UNARY)
        }
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[1].flags, 4)
        XCTAssertEqual(decoded[2].flags, 1)
        XCTAssertEqual(decoded[3].flags, 5)
        XCTAssertEqual(decoded[4].flags, 2)
        XCTAssertEqual(decoded[5].flags, 6)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x19_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(-2).bitPattern)
        vectorLows[3] = Double(-3).bitPattern
        vectorLows[5] = UInt64(Float(4).bitPattern)
        vectorLows[7] = Double(5).bitPattern
        vectorLows[9] = UInt64(Float(9).bitPattern)
        vectorLows[11] = Double(16).bitPattern
        vectorLows[15] = Double(6).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            10,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[0])), 2)
        XCTAssertEqual(Double(bitPattern: vectorLows[2]), 3)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[4])), -4)
        XCTAssertEqual(Double(bitPattern: vectorLows[6]), -5)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[8])), 3)
        XCTAssertEqual(Double(bitPattern: vectorLows[10]), 4)
        XCTAssertEqual(Double(bitPattern: vectorLows[15]), -6)
        for register in [0, 2, 4, 6, 8, 10, 15] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesVectorFPUnaryFamily() {
        let program: [UInt32] = [
            0x2ea0_fbde, // fneg v30.2s, v30.2s (live Settings instruction)
            0x4ea0_f820, // fabs v0.4s, v1.4s
            0x4ee0_f862, // fabs v2.2d, v3.2d
            0x6ea0_f8a4, // fneg v4.4s, v5.4s
            0x6ee0_f8e6, // fneg v6.2d, v7.2d
            0x6ea1_f928, // fsqrt v8.4s, v9.4s
            0x6ee1_f96a, // fsqrt v10.2d, v11.2d
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_UNARY)
            XCTAssertNotEqual(instruction.flags & 8, 0)
        }
        XCTAssertEqual(decoded[0].flags, 9)
        XCTAssertEqual(decoded[1].flags, 24)
        XCTAssertEqual(decoded[2].flags, 28)
        XCTAssertEqual(decoded[3].flags, 25)
        XCTAssertEqual(decoded[4].flags, 29)
        XCTAssertEqual(decoded[5].flags, 26)
        XCTAssertEqual(decoded[6].flags, 30)

        func packed(_ lower: Float, _ upper: Float) -> UInt64 {
            UInt64(lower.bitPattern) | (UInt64(upper.bitPattern) << 32)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x18_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[30] = packed(-1.5, 2)
        vectorLows[1] = packed(-1, 2)
        vectorHighs[1] = packed(-3, -0.0)
        vectorLows[3] = Double(-4).bitPattern
        vectorHighs[3] = Double(5).bitPattern
        vectorLows[5] = packed(1, -2)
        vectorHighs[5] = packed(3, -4)
        vectorLows[7] = Double(1).bitPattern
        vectorHighs[7] = Double(-2).bitPattern
        vectorLows[9] = packed(1, 4)
        vectorHighs[9] = packed(9, 16)
        vectorLows[11] = Double(25).bitPattern
        vectorHighs[11] = Double(36).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            10,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[30], packed(1.5, -2))
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(vectorLows[0], packed(1, 2))
        XCTAssertEqual(vectorHighs[0], packed(3, 0))
        XCTAssertEqual(Double(bitPattern: vectorLows[2]), 4)
        XCTAssertEqual(Double(bitPattern: vectorHighs[2]), 5)
        XCTAssertEqual(vectorLows[4], packed(-1, 2))
        XCTAssertEqual(vectorHighs[4], packed(-3, 4))
        XCTAssertEqual(Double(bitPattern: vectorLows[6]), -1)
        XCTAssertEqual(Double(bitPattern: vectorHighs[6]), 2)
        XCTAssertEqual(vectorLows[8], packed(1, 2))
        XCTAssertEqual(vectorHighs[8], packed(3, 4))
        XCTAssertEqual(Double(bitPattern: vectorLows[10]), 5)
        XCTAssertEqual(Double(bitPattern: vectorHighs[10]), 6)
    }

    func testFullRegisterRunnerExecutesFPReciprocalEstimateFamily() {
        let program: [UInt32] = [
            0x0ea1_d820, // frecpe v0.2s, v1.2s
            0x4ea1_d862, // frecpe v2.4s, v3.4s
            0x4ee1_d8a4, // frecpe v4.2d, v5.2d
            0x2ea1_d8e6, // frsqrte v6.2s, v7.2s
            0x6ea1_d928, // frsqrte v8.4s, v9.4s
            0x6ee1_d96a, // frsqrte v10.2d, v11.2d
            0x5ea1_d9ac, // frecpe s12, s13
            0x5ee1_d9ee, // frecpe d14, d15
            0x7ea1_da30, // frsqrte s16, s17
            0x7ee1_da72, // frsqrte d18, d19
            0x6ea1_dbdf, // frsqrte v31.4s, v30.4s (live Settings instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE)
        }
        XCTAssertEqual(decoded.map(\.flags), [4, 12, 14, 5, 13, 15, 0, 2, 1, 3, 13, 0])

        func packedFloats(_ low: Float, _ high: Float) -> UInt64 {
            UInt64(low.bitPattern) | (UInt64(high.bitPattern) << 32)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x19_800
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = packedFloats(2, 4)
        vectorLows[3] = packedFloats(2, 4)
        vectorHighs[3] = packedFloats(8, 16)
        vectorLows[5] = Double(2).bitPattern
        vectorHighs[5] = Double(4).bitPattern
        vectorLows[7] = packedFloats(4, 16)
        vectorLows[9] = packedFloats(1, 4)
        vectorHighs[9] = packedFloats(9, 16)
        vectorLows[11] = Double(4).bitPattern
        vectorHighs[11] = Double(16).bitPattern
        vectorLows[13] = UInt64(Float(8).bitPattern)
        vectorHighs[13] = UInt64.max
        vectorLows[15] = Double(8).bitPattern
        vectorHighs[15] = UInt64.max
        vectorLows[17] = UInt64(Float(9).bitPattern)
        vectorHighs[17] = UInt64.max
        vectorLows[19] = Double(9).bitPattern
        vectorHighs[19] = UInt64.max
        vectorLows[30] = packedFloats(1, 4)
        vectorHighs[30] = packedFloats(9, 16)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            14,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        func floatLane(_ register: Int, _ lane: Int) -> Float {
            let word = lane < 2 ? vectorLows[register] : vectorHighs[register]
            return Float(bitPattern: UInt32(truncatingIfNeeded: word >> UInt64((lane & 1) * 32)))
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(floatLane(0, 0), 0.5, accuracy: 0.01)
        XCTAssertEqual(floatLane(0, 1), 0.25, accuracy: 0.01)
        XCTAssertEqual(floatLane(2, 2), 0.125, accuracy: 0.01)
        XCTAssertEqual(floatLane(2, 3), 0.0625, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorLows[4]), 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorHighs[4]), 0.25, accuracy: 0.01)
        XCTAssertEqual(floatLane(6, 0), 0.5, accuracy: 0.01)
        XCTAssertEqual(floatLane(6, 1), 0.25, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorLows[10]), 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorHighs[10]), 0.25, accuracy: 0.01)
        XCTAssertEqual(floatLane(12, 0), 0.125, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorLows[14]), 0.125, accuracy: 0.01)
        XCTAssertEqual(floatLane(16, 0), 1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(Double(bitPattern: vectorLows[18]), 1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(floatLane(31, 0), 1, accuracy: 0.01)
        XCTAssertEqual(floatLane(31, 1), 0.5, accuracy: 0.01)
        XCTAssertEqual(floatLane(31, 2), 1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(floatLane(31, 3), 0.25, accuracy: 0.01)
        XCTAssertEqual(vectorHighs[0], 0)
        for register in [12, 14, 16, 18] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesFPReciprocalStepFamily() {
        let program: [UInt32] = [
            0x0e22_fc20, // frecps v0.2s, v1.2s, v2.2s
            0x4e25_fc83, // frecps v3.4s, v4.4s, v5.4s
            0x4e68_fce6, // frecps v6.2d, v7.2d, v8.2d
            0x0eab_fd49, // frsqrts v9.2s, v10.2s, v11.2s
            0x4eae_fdac, // frsqrts v12.4s, v13.4s, v14.4s
            0x4ef1_fe0f, // frsqrts v15.2d, v16.2d, v17.2d
            0x5e34_fe72, // frecps s18, s19, s20
            0x5e77_fed5, // frecps d21, d22, d23
            0x5eba_ff38, // frsqrts s24, s25, s26
            0x5efe_ff9b, // frsqrts d27, d28, d30
            0x4ebf_ffbd, // frsqrts v29.4s, v29.4s, v31.4s (live Settings instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_RECIPROCAL_STEP)
        }
        XCTAssertEqual(decoded.map(\.flags), [4, 12, 14, 5, 13, 15, 0, 2, 1, 3, 13, 0])

        func packedFloats(_ low: Float, _ high: Float) -> UInt64 {
            UInt64(low.bitPattern) | (UInt64(high.bitPattern) << 32)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x19_c00
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        for register in [1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 29] {
            vectorLows[register] = packedFloats(0.25, 0.25)
            vectorHighs[register] = packedFloats(0.25, 0.25)
        }
        for register in [2, 5, 8, 11, 14, 17, 20, 23, 26, 31] {
            vectorLows[register] = packedFloats(2, 2)
            vectorHighs[register] = packedFloats(2, 2)
        }
        vectorLows[7] = Double(0.25).bitPattern
        vectorHighs[7] = Double(0.25).bitPattern
        vectorLows[8] = Double(2).bitPattern
        vectorHighs[8] = Double(2).bitPattern
        vectorLows[16] = Double(0.25).bitPattern
        vectorHighs[16] = Double(0.25).bitPattern
        vectorLows[17] = Double(2).bitPattern
        vectorHighs[17] = Double(2).bitPattern
        vectorLows[22] = Double(0.25).bitPattern
        vectorLows[23] = Double(2).bitPattern
        vectorLows[28] = Double(0.25).bitPattern
        vectorLows[30] = Double(2).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            14,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        func floatLane(_ register: Int, _ lane: Int) -> Float {
            let word = lane < 2 ? vectorLows[register] : vectorHighs[register]
            return Float(bitPattern: UInt32(truncatingIfNeeded: word >> ((lane & 1) * 32)))
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        for lane in 0..<2 {
            XCTAssertEqual(floatLane(0, lane), 1.5, accuracy: 0.001)
            XCTAssertEqual(floatLane(9, lane), 1.25, accuracy: 0.001)
        }
        for lane in 0..<4 {
            XCTAssertEqual(floatLane(3, lane), 1.5, accuracy: 0.001)
            XCTAssertEqual(floatLane(12, lane), 1.25, accuracy: 0.001)
            XCTAssertEqual(floatLane(29, lane), 1.25, accuracy: 0.001)
        }
        XCTAssertEqual(Double(bitPattern: vectorLows[6]), 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(bitPattern: vectorHighs[6]), 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(bitPattern: vectorLows[15]), 1.25, accuracy: 0.001)
        XCTAssertEqual(Double(bitPattern: vectorHighs[15]), 1.25, accuracy: 0.001)
        XCTAssertEqual(floatLane(18, 0), 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(bitPattern: vectorLows[21]), 1.5, accuracy: 0.001)
        XCTAssertEqual(floatLane(24, 0), 1.25, accuracy: 0.001)
        XCTAssertEqual(Double(bitPattern: vectorLows[27]), 1.25, accuracy: 0.001)
        XCTAssertEqual(vectorHighs[0], 0)
        for register in [18, 21, 24, 27] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesScalarFPRoundIntegralFamily() {
        let program: [UInt32] = [
            0x1e24_4020, // frintn s0, s1
            0x1e64_4062, // frintn d2, d3
            0x1e24_c0a4, // frintp s4, s5
            0x1e64_c0e6, // frintp d6, d7
            0x1e25_4128, // frintm s8, s9
            0x1e65_416a, // frintm d10, d11
            0x1e25_c1ac, // frintz s12, s13
            0x1e65_c1ee, // frintz d14, d15
            0x1e26_4230, // frinta s16, s17
            0x1e66_4272, // frinta d18, d19
            0x1e27_42b4, // frintx s20, s21
            0x1e67_42f6, // frintx d22, d23
            0x1e27_c338, // frinti s24, s25
            0x1e67_c37a, // frinti d26, d27
            0x1e24_c3ff, // frintp s31, s31 (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL)
        }
        XCTAssertEqual(decoded[0].flags, 1)
        XCTAssertEqual(decoded[2].flags, 2)
        XCTAssertEqual(decoded[4].flags, 3)
        XCTAssertEqual(decoded[6].flags, 0)
        XCTAssertEqual(decoded[8].flags, 4)
        XCTAssertEqual(decoded[10].flags, 5)
        XCTAssertEqual(decoded[11].flags, 13)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 2 << 22
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(2.5).bitPattern)
        vectorLows[3] = Double(3.5).bitPattern
        vectorLows[5] = UInt64(Float(1.1).bitPattern)
        vectorLows[7] = Double(-1.1).bitPattern
        vectorLows[9] = UInt64(Float(1.9).bitPattern)
        vectorLows[11] = Double(-1.1).bitPattern
        vectorLows[13] = UInt64(Float(-1.9).bitPattern)
        vectorLows[15] = Double(1.9).bitPattern
        vectorLows[17] = UInt64(Float(2.5).bitPattern)
        vectorLows[19] = Double(-2.5).bitPattern
        vectorLows[21] = UInt64(Float(1.9).bitPattern)
        vectorLows[23] = Double(-1.1).bitPattern
        vectorLows[25] = UInt64(Float(3.9).bitPattern)
        vectorLows[27] = Double(-3.1).bitPattern
        vectorLows[31] = UInt64(Float(-1.1).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            18,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[0])), 2)
        XCTAssertEqual(Double(bitPattern: vectorLows[2]), 4)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[4])), 2)
        XCTAssertEqual(Double(bitPattern: vectorLows[6]), -1)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[8])), 1)
        XCTAssertEqual(Double(bitPattern: vectorLows[10]), -2)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[12])), -1)
        XCTAssertEqual(Double(bitPattern: vectorLows[14]), 1)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[16])), 3)
        XCTAssertEqual(Double(bitPattern: vectorLows[18]), -3)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[20])), 1)
        XCTAssertEqual(Double(bitPattern: vectorLows[22]), -2)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[24])), 3)
        XCTAssertEqual(Double(bitPattern: vectorLows[26]), -4)
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[31])), -1)
        for register in [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 31] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerPreservesNegativeZeroWhenRoundingToIntegral() {
        let program: [UInt32] = [
            0x1e27_c020, // frinti s0, s1
            0x1e67_c062, // frinti d2, d3
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x20_100
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(-0.25).bitPattern)
        vectorLows[3] = Double(-0.25).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            3,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(UInt32(vectorLows[0]), Float(-0.0).bitPattern)
        XCTAssertEqual(vectorLows[2], Double(-0.0).bitPattern)
    }

    func testFullRegisterRunnerExecutesScalarFPNegatedMultiply() {
        let program: [UInt32] = [
            0x1e22_8820, // fnmul s0, s1, s2
            0x1e65_8883, // fnmul d3, d4, d5
            0x1e7e_89ff, // fnmul d31, d15, d30 (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY)
        }
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(decoded[2].rd, 31)
        XCTAssertEqual(decoded[2].rn, 15)
        XCTAssertEqual(decoded[2].rm, 30)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1d_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(2).bitPattern)
        vectorLows[2] = UInt64(Float(3).bitPattern)
        vectorLows[4] = Double(4).bitPattern
        vectorLows[5] = Double(5).bitPattern
        vectorLows[15] = Double(6).bitPattern
        vectorLows[30] = Double(7).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[0])), -6)
        XCTAssertEqual(Double(bitPattern: vectorLows[3]), -20)
        XCTAssertEqual(Double(bitPattern: vectorLows[31]), -42)
        for register in [0, 3, 31] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesFPScalarConditionalCompare() {
        let program: [UInt32] = [
            0x1e22_0423, // fccmp s1, s2, #3, eq
            0x1a9f_a7e0, // cset w0, lt
            0x1e64_0475, // fccmpe d3, d4, #5, eq
            0x1a9f_17e1, // cset w1, eq
            0x1e3f_0420, // fccmp s1, s31, #0, eq (live Cage instruction)
            0x1a9f_17e2, // cset w2, eq
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE)
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[0].immediate, 3)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE)
        XCTAssertEqual(decoded[2].flags, 3)
        XCTAssertEqual(decoded[2].immediate, 5)
        XCTAssertEqual(Int(decoded[4].kind), AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE)
        XCTAssertEqual(decoded[4].rn, 1)
        XCTAssertEqual(decoded[4].rm, 31)
        XCTAssertEqual(decoded[4].condition, 0)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1f_000
        var pstate: UInt64 = 0x4000_0000
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(2).bitPattern)
        vectorLows[2] = UInt64(Float(3).bitPattern)
        vectorLows[3] = Double(5).bitPattern
        vectorLows[4] = Double(5).bitPattern
        vectorLows[31] = UInt64(Float(2).bitPattern)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            9,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(registers[0], 1)
        XCTAssertEqual(registers[1], 1)
        XCTAssertEqual(registers[2], 1)
        XCTAssertEqual(pstate & 0xf000_0000, 0x6000_0000)
    }

    func testFullRegisterRunnerExecutesSIMDScalarFPAbsoluteDifference() {
        let program: [UInt32] = [
            0x7ea2_d420, // fabd s0, s1, s2
            0x7ee5_d483, // fabd d3, d4, d5
            0x7efe_d7bd, // fabd d29, d29, d30 (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE)
        }
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(decoded[2].rd, 29)
        XCTAssertEqual(decoded[2].rn, 29)
        XCTAssertEqual(decoded[2].rm, 30)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1a_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = UInt64(Float(-2).bitPattern)
        vectorLows[2] = UInt64(Float(5).bitPattern)
        vectorLows[4] = Double(12).bitPattern
        vectorLows[5] = Double(-3).bitPattern
        vectorLows[29] = Double(2.5).bitPattern
        vectorLows[30] = Double(9).bitPattern

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            6,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(Float(bitPattern: UInt32(vectorLows[0])), 7)
        XCTAssertEqual(Double(bitPattern: vectorLows[3]), 15)
        XCTAssertEqual(Double(bitPattern: vectorLows[29]), 6.5)
        for register in [0, 3, 29] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    func testFullRegisterRunnerExecutesSIMDFPImmediateMove() {
        let program: [UInt32] = [
            0x0f03_f600, // fmov v0.2s, #1.0
            0x4f04_f401, // fmov v1.4s, #-2.0
            0x6f03_f402, // fmov v2.2d, #0.5
            0x0f03_f61f, // fmov v31.2s, #1.0 (live Cage instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE)
        }
        XCTAssertEqual(decoded[0].bits, 32)
        XCTAssertEqual(decoded[0].flags, 0)
        XCTAssertEqual(decoded[1].bits, 32)
        XCTAssertEqual(decoded[1].flags, 1)
        XCTAssertEqual(decoded[2].bits, 64)
        XCTAssertEqual(decoded[2].flags, 1)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x1b_000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            7,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[0], 0x3f80_0000_3f80_0000)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[1], 0xc000_0000_c000_0000)
        XCTAssertEqual(vectorHighs[1], 0xc000_0000_c000_0000)
        XCTAssertEqual(vectorLows[2], Double(0.5).bitPattern)
        XCTAssertEqual(vectorHighs[2], Double(0.5).bitPattern)
        XCTAssertEqual(vectorLows[31], 0x3f80_0000_3f80_0000)
        XCTAssertEqual(vectorHighs[31], 0)
    }

    func testFullRegisterRunnerExecutesVectorAddAndMoveToGeneral() {
        let program: [UInt32] = [
            0x4eff_879c, // add v28.2d, v28.2d, v31.2d
            0x4e08_3f80, // mov x0, v28.d[0]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[28] = 0xffff_ffff_ffff_fffe
        vectorHighs[28] = 0x1000_0000_0000_0000
        vectorLows[31] = 0x5
        vectorHighs[31] = 0xf000_0000_0000_0001

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(registers[0], 0x3)
        XCTAssertEqual(vectorLows[28], 0x3)
        XCTAssertEqual(vectorHighs[28], 0x1)
        XCTAssertEqual(vectorLows[31], 0x5)
        XCTAssertEqual(vectorHighs[31], 0xf000_0000_0000_0001)
    }

    func testFullRegisterRunnerExecutesVectorImmediateAndInsertInstructions() {
        let program: [UInt32] = [
            0x4f00_e45f, // movi v31.16b, #0x02
            0x6f00_2420, // mvni v0.8h, #0x01, lsl #8
            0x2f07_e61e, // movi d30, #0xffffffff00000000
            0x6f07_e61d, // movi v29.2d, #0xffffffff00000000
            0x4e18_1c41, // mov v1.d[1], x2
            0x4f00_043c, // movi v28.4s, #1
            0x0f00_265b, // movi v27.2s, #0x12, lsl #8
            0x4f00_465a, // movi v26.4s, #0x12, lsl #16
            0x4f00_6659, // movi v25.4s, #0x12, lsl #24
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x9000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        registers[2] = 0x1122_3344_5566_7788
        vectorLows[1] = 0xcccc_cccc_cccc_cccc
        vectorHighs[1] = 0xdddd_dddd_dddd_dddd

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            16,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 10)
        XCTAssertEqual(vectorLows[31], 0x0202_0202_0202_0202)
        XCTAssertEqual(vectorHighs[31], 0x0202_0202_0202_0202)
        XCTAssertEqual(vectorLows[0], 0xffff_feff_ffff_feff)
        XCTAssertEqual(vectorHighs[0], 0xffff_feff_ffff_feff)
        XCTAssertEqual(vectorLows[30], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorHighs[30], 0)
        XCTAssertEqual(vectorLows[29], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorHighs[29], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorLows[1], 0xcccc_cccc_cccc_cccc)
        XCTAssertEqual(vectorHighs[1], 0x1122_3344_5566_7788)
        XCTAssertEqual(vectorLows[28], 0x0000_0001_0000_0001)
        XCTAssertEqual(vectorHighs[28], 0x0000_0001_0000_0001)
        XCTAssertEqual(vectorLows[27], 0x0000_1200_0000_1200)
        XCTAssertEqual(vectorHighs[27], 0)
        XCTAssertEqual(vectorLows[26], 0x0012_0000_0012_0000)
        XCTAssertEqual(vectorHighs[26], 0x0012_0000_0012_0000)
        XCTAssertEqual(vectorLows[25], 0x1200_0000_1200_0000)
        XCTAssertEqual(vectorHighs[25], 0x1200_0000_1200_0000)
    }

    func testFullRegisterRunnerExecutesTableLookupWithoutFallback() {
        let program: [UInt32] = [
            0x4e17_03ff, // tbl.16b v31, { v31 }, v23
            0x4e03_2020, // tbl.16b v0, { v1, v2 }, v3
            0x4e06_10a4, // tbx.16b v4, { v5 }, v6
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x9000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[31] = 0x1716_1514_1312_1110
        vectorHighs[31] = 0x1f1e_1d1c_1b1a_1918
        vectorLows[23] = 0x100f_0e0d_0c03_0201
        vectorHighs[23] = 0xff1f_1e11_1007_0605
        vectorLows[1] = 0x0706_0504_0302_0100
        vectorHighs[1] = 0x0f0e_0d0c_0b0a_0908
        vectorLows[2] = 0x1716_1514_1312_1110
        vectorHighs[2] = 0x1f1e_1d1c_1b1a_1918
        vectorLows[3] = 0x201f_100f_0801_0000
        vectorHighs[3] = 0x1f1e_1d1c_1b1a_1918
        vectorLows[4] = 0xaaaa_aaaa_aaaa_aaaa
        vectorHighs[4] = 0xbbbb_bbbb_bbbb_bbbb
        vectorLows[5] = 0x8786_8584_8382_8180
        vectorHighs[5] = 0x8f8e_8d8c_8b8a_8988
        vectorLows[6] = 0x100f_0e0d_0c03_0201
        vectorHighs[6] = 0xff1f_1e11_1007_0605

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 4)
        XCTAssertEqual(vectorLows[31], 0x001f_1e1d_1c13_1211)
        XCTAssertEqual(vectorHighs[31], 0x0000_0000_0017_1615)
        XCTAssertEqual(vectorLows[0], 0x001f_100f_0801_0000)
        XCTAssertEqual(vectorHighs[0], 0x1f1e_1d1c_1b1a_1918)
        XCTAssertEqual(vectorLows[4], 0xaa8f_8e8d_8c83_8281)
        XCTAssertEqual(vectorHighs[4], 0xbbbb_bbbb_bb87_8685)
    }

    func testFullRegisterRunnerExecutesPermuteTwoVectorWithoutFallback() {
        let program: [UInt32] = [
            0x4e1b_3bfd, // zip1.16b v29, v31, v27
            0x4e1b_7bfc, // zip2.16b v28, v31, v27
            0x4e59_6b1a, // trn2.8h v26, v24, v25
            0x4e96_1ab7, // uzp1.4s v23, v21, v22
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x9000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[31] = 0x1716_1514_1312_1110
        vectorHighs[31] = 0x1f1e_1d1c_1b1a_1918
        vectorLows[27] = 0x8786_8584_8382_8180
        vectorHighs[27] = 0x8f8e_8d8c_8b8a_8988
        vectorLows[24] = 0x1003_1002_1001_1000
        vectorHighs[24] = 0x1007_1006_1005_1004
        vectorLows[25] = 0x8003_8002_8001_8000
        vectorHighs[25] = 0x8007_8006_8005_8004
        vectorLows[21] = 0x1000_0001_1000_0000
        vectorHighs[21] = 0x1000_0003_1000_0002
        vectorLows[22] = 0x8000_0001_8000_0000
        vectorHighs[22] = 0x8000_0003_8000_0002

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 5)
        XCTAssertEqual(vectorLows[29], 0x8313_8212_8111_8010)
        XCTAssertEqual(vectorHighs[29], 0x8717_8616_8515_8414)
        XCTAssertEqual(vectorLows[28], 0x8b1b_8a1a_8919_8818)
        XCTAssertEqual(vectorHighs[28], 0x8f1f_8e1e_8d1d_8c1c)
        XCTAssertEqual(vectorLows[26], 0x8003_1003_8001_1001)
        XCTAssertEqual(vectorHighs[26], 0x8007_1007_8005_1005)
        XCTAssertEqual(vectorLows[23], 0x1000_0002_1000_0000)
        XCTAssertEqual(vectorHighs[23], 0x8000_0002_8000_0000)
    }

    func testFullRegisterRunnerExecutesSIMDCompareEqualVectorWithoutFallback() {
        let program: [UInt32] = [
            0x6eb9_8fde, // cmeq.4s v30, v30, v25
            0x4efb_8fff, // cmtst.2d v31, v31, v27 (live musl instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(decoded[1].flags, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xa000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[30] = 0x0000_0002_0000_0001
        vectorHighs[30] = 0x0000_0004_0000_0003
        vectorLows[25] = 0xffff_ffff_0000_0001
        vectorHighs[25] = 0x0000_0004_ffff_ffff
        vectorLows[31] = 0x10
        vectorHighs[31] = 0x20
        vectorLows[27] = 0x08
        vectorHighs[27] = 0x20

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[30], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[30], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorLows[31], 0)
        XCTAssertEqual(vectorHighs[31], UInt64.max)
    }

    func testFullRegisterRunnerExecutesSIMDFPCompareVectorFamily() {
        let program: [UInt32] = [
            0x2ea2_e43c, // fcmgt v28.2s, v1.2s, v2.2s (live Settings instruction)
            0x4e22_e420, // fcmeq v0.4s, v1.4s, v2.4s
            0x6e62_e423, // fcmge v3.2d, v1.2d, v2.2d
            0x6ea2_ec24, // facgt v4.4s, v1.4s, v2.4s
            0x6ea0_d825, // fcmle v5.4s, v1.4s, #0.0
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] =
            UInt64(Float(3).bitPattern) | (UInt64(Float(-2).bitPattern) << 32)
        vectorHighs[1] =
            UInt64(Float(-4).bitPattern) | (UInt64(Float.nan.bitPattern) << 32)
        vectorLows[2] =
            UInt64(Float(2).bitPattern) | (UInt64(Float(-2).bitPattern) << 32)
        vectorHighs[2] =
            UInt64(Float(1).bitPattern) | (UInt64(Float.nan.bitPattern) << 32)

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[28], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[28], 0)
        XCTAssertEqual(vectorLows[0], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorHighs[0], 0)
        XCTAssertEqual(vectorLows[4], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[4], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorLows[5], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorHighs[5], 0x0000_0000_ffff_ffff)
    }

    func testFullRegisterRunnerExecutesSIMDCompareAgainstZeroFamily() {
        let program: [UInt32] = [
            0x4ea0_9bde, // cmeq v30.4s, v30.4s, #0 (live Phosh instruction)
            0x4ea0_88a4, // cmgt v4.4s, v5.4s, #0
            0x6ea0_9928, // cmle v8.4s, v9.4s, #0
            0xd440_0000
        ]
        var decoded = decode(program)
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xa000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[30] = 0x0000_0001_0000_0000
        vectorHighs[30] = 0xffff_ffff_0000_0000
        vectorLows[5] = 0xffff_ffff_0000_0001
        vectorHighs[5] = 0x0000_0000_7fff_ffff
        vectorLows[9] = 0x0000_0001_0000_0000
        vectorHighs[9] = 0x8000_0000_ffff_ffff

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[30], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[30], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorLows[4], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[4], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorLows[8], 0x0000_0000_ffff_ffff)
        XCTAssertEqual(vectorHighs[8], 0xffff_ffff_ffff_ffff)
    }

    func testFullRegisterRunnerExecutesSIMDUnsignedCompareVectorWithoutFallback() {
        let program: [UInt32] = [
            0x6efe_37bf, // cmhi.2d v31, v29, v30 (live phoc instruction)
            0x6ee2_3c20, // cmhs.2d v0, v1, v2
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(decoded[0].flags, 5)
        XCTAssertEqual(decoded[1].flags, 7)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xa000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[29] = 0x30
        vectorHighs[29] = 0x10
        vectorLows[30] = 0x20
        vectorHighs[30] = 0x20
        vectorLows[1] = 0x20
        vectorHighs[1] = 0x10
        vectorLows[2] = 0x20
        vectorHighs[2] = 0x20

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[31], UInt64.max)
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(vectorLows[0], UInt64.max)
        XCTAssertEqual(vectorHighs[0], 0)
    }

    func testFullRegisterRunnerExecutesSIMDSignedCompareVectorWithoutFallback() {
        let program: [UInt32] = [
            0x0e22_3420, // cmgt v0.8b, v1.8b, v2.8b
            0x0e65_3c83, // cmge v3.4h, v4.4h, v5.4h
            0x4ebb_3fff, // cmge v31.4s, v31.4s, v27.4s (live Phosh instruction)
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(decoded[0].flags >> 1, 9)
        XCTAssertEqual(decoded[1].flags >> 1, 10)
        XCTAssertEqual(decoded[2].flags >> 1, 10)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xa000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x807f_02fe_0100_ff03
        vectorLows[2] = 0x7f80_01ff_0101_fe02
        vectorLows[4] = 0x8000_7fff_0002_ffff
        vectorLows[5] = 0x7fff_8000_0002_0000
        vectorLows[31] = 0xffff_ffff_0000_0002
        vectorHighs[31] = 0x8000_0000_7fff_ffff
        vectorLows[27] = 0xffff_ffff_0000_0003
        vectorHighs[27] = 0x7fff_ffff_8000_0000

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[31], 0xffff_ffff_0000_0000)
        XCTAssertEqual(vectorHighs[31], 0x0000_0000_ffff_ffff)
    }

    func testFullRegisterRunnerExecutesSIMDScalarCompareEqualZeroWithoutFallback() {
        let program: [UInt32] = [
            0x5ee0_9bff, // cmeq d31, d31, #0 (live GNOME Calculator instruction)
            0x5ee0_981e, // cmeq d30, d0, #0
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR)
        XCTAssertEqual(decoded[0].bits, 64)
        XCTAssertEqual(decoded[0].flags >> 1, 4)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xa800
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[31] = 0
        vectorHighs[31] = UInt64.max
        vectorLows[0] = 1
        vectorHighs[0] = UInt64.max

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[31], UInt64.max)
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(vectorLows[30], 0)
        XCTAssertEqual(vectorHighs[30], 0)
    }

    func testFullRegisterRunnerExecutesSIMDCountSetBitsWithoutFallback() {
        let program: [UInt32] = [
            0x0e20_5bff, // cnt.8b v31, v31
            0x4e20_5820, // cnt.16b v0, v1
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xb000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[31] = 0x017f_8055_f00f_00ff
        vectorHighs[31] = 0xffff_ffff_ffff_ffff
        vectorLows[1] = 0x017f_8055_f00f_00ff
        vectorHighs[1] = 0xf0de_bc9a_7856_3412

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[31], 0x0107_0104_0404_0008)
        XCTAssertEqual(vectorHighs[31], 0)
        XCTAssertEqual(vectorLows[0], 0x0107_0104_0404_0008)
        XCTAssertEqual(vectorHighs[0], 0x0406_0504_0404_0302)
    }

    func testFullRegisterRunnerExecutesSIMDVectorORRWithoutFallback() {
        let program: [UInt32] = [
            0x4ebd_1fde, // orr v30.16b, v30.16b, v29.16b
            0x6e3e_1ffe, // eor v30.16b, v31.16b, v30.16b (live musl instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_ORR_VECTOR)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_ORR_VECTOR)
        XCTAssertEqual(decoded[1].flags, 3)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[30] = 0x00ff_0000_00ff_0000
        vectorHighs[30] = 0xaaaa_0000_aaaa_0000
        vectorLows[29] = 0x0000_ff00_0000_ff00
        vectorHighs[29] = 0x0000_5555_0000_5555
        vectorLows[31] = UInt64.max
        vectorHighs[31] = UInt64.max

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 4,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 3)
        XCTAssertEqual(vectorLows[30], 0xff00_00ff_ff00_00ff)
        XCTAssertEqual(vectorHighs[30], 0x5555_aaaa_5555_aaaa)
    }

    func testFullRegisterRunnerExecutesSIMDLogicalVectorFamilyWithoutFallback() {
        let program: [UInt32] = [
            0x0e3f_1c1b, // and v27.8b, v0.8b, v31.8b (live Phosh instruction)
            0x4e65_1c83, // bic v3.16b, v4.16b, v5.16b
            0x4eeb_1d49, // orn v9.16b, v10.16b, v11.16b
            0xd440_0000
        ]
        var decoded = decode(program)
        XCTAssertEqual(decoded.dropLast().map { Int($0.kind) }, [
            AVZ_NATIVE_OP_SIMD_ORR_VECTOR,
            AVZ_NATIVE_OP_SIMD_ORR_VECTOR,
            AVZ_NATIVE_OP_SIMD_ORR_VECTOR
        ])
        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[0] = 0xff00_ff00_ff00_ff00
        vectorLows[31] = 0x0f0f_0f0f_0f0f_0f0f
        vectorLows[4] = UInt64.max
        vectorHighs[4] = UInt64.max
        vectorLows[5] = 0x00ff_00ff_00ff_00ff
        vectorHighs[5] = 0xff00_ff00_ff00_ff00
        vectorLows[10] = 0
        vectorHighs[10] = 0
        vectorLows[11] = UInt64.max
        vectorHighs[11] = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(vectorLows[27], 0x0f00_0f00_0f00_0f00)
        XCTAssertEqual(vectorHighs[27], 0)
        XCTAssertEqual(vectorLows[3], 0xff00_ff00_ff00_ff00)
        XCTAssertEqual(vectorHighs[3], 0x00ff_00ff_00ff_00ff)
        XCTAssertEqual(vectorLows[9], 0)
        XCTAssertEqual(vectorHighs[9], UInt64.max)
    }

    func testFullRegisterRunnerExecutesSIMDBitwiseSelectWithoutFallback() {
        let program: [UInt32] = [
            0x6e7e_1fbf, // bsl.16b v31, v29, v30 (live phoc instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_ORR_VECTOR)
        XCTAssertEqual(decoded[0].flags, 5)

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[31] = 0xffff_0000_ffff_0000
        vectorHighs[31] = 0xaaaa_aaaa_aaaa_aaaa
        vectorLows[29] = 0x1111_2222_3333_4444
        vectorHighs[29] = UInt64.max
        vectorLows[30] = 0xaaaa_bbbb_cccc_dddd
        vectorHighs[30] = 0

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            4,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(vectorLows[31], 0x1111_bbbb_3333_dddd)
        XCTAssertEqual(vectorHighs[31], 0xaaaa_aaaa_aaaa_aaaa)
    }

    func testFullRegisterRunnerExecutesSIMDMoveVectorElementToGeneralWithoutFallback() {
        let program: [UInt32] = [
            0x0e01_3fe0, // umov w0, v31.b[0]
            0x0e0f_3c41, // umov w1, v2.b[7]
            0x0e0e_3cc5, // umov w5, v6.h[3]
            0x0e0c_3d49, // mov w9, v10.s[1]
            0x4e18_3dcd, // mov x13, v14.d[1]
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        XCTAssertEqual(Int(decoded[0].kind), AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL)
        XCTAssertEqual(Int(decoded[1].kind), AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL)
        XCTAssertEqual(Int(decoded[2].kind), AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL)
        XCTAssertEqual(Int(decoded[3].kind), AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL)
        XCTAssertEqual(Int(decoded[4].kind), AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL)
        XCTAssertEqual(decoded[0].bits, 8)
        XCTAssertEqual(decoded[0].condition, 0)
        XCTAssertEqual(decoded[4].bits, 64)
        XCTAssertEqual(decoded[4].condition, 1)

        var registers = [UInt64](repeating: 0xffff_ffff_ffff_ffff, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0

        vectorLows[31] = 0x0102_0304_0506_07ab
        vectorLows[2] = 0x9900_0000_0000_0000
        vectorLows[6] = 0xabcd_0000_0000_0000
        vectorLows[10] = 0xdead_beef_1234_5678
        vectorHighs[14] = 0x1122_3344_5566_7788

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress,
                            instructionBuffer.count,
                            pc,
                            8,
                            registerBuffer.baseAddress,
                            vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &halted,
                            nil,
                            nil,
                            nil,
                            nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(registers[0], 0xab)
        XCTAssertEqual(registers[1], 0x99)
        XCTAssertEqual(registers[5], 0xabcd)
        XCTAssertEqual(registers[9], 0xdead_beef)
        XCTAssertEqual(registers[13], 0x1122_3344_5566_7788)
    }

    func testFullRegisterRunnerExecutesSIMDScalarElementCopyWithoutFallback() {
        let program: [UInt32] = [
            0x5e0f_0420, // mov b0, v1.b[7]
            0x5e0a_0462, // mov h2, v3.h[2]
            0x5e0c_04a4, // mov s4, v5.s[1]
            0x5e18_04e6, // mov d6, v7.d[1]
            0x5e0c_07fe, // mov s30, v31.s[1] (live Phosh instruction)
            0xd440_0000  // hlt #0
        ]
        var decoded = decode(program)
        for instruction in decoded.dropLast() {
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT)
            XCTAssertEqual(instruction.flags, 2)
        }

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: UInt64.max, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0xc000
        var pstate: UInt64 = 0
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var halted: UInt8 = 0
        vectorLows[1] = 0x8877_6655_4433_2211
        vectorLows[3] = 0x7766_5544_3322_1100
        vectorLows[5] = 0xdead_beef_1234_5678
        vectorHighs[7] = 0x1122_3344_5566_7788
        vectorLows[31] = 0xaabb_ccdd_1357_2468

        let result = decoded.withUnsafeMutableBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                        avz_native_run_threaded_decoded_block_full_registers(
                            instructionBuffer.baseAddress, instructionBuffer.count, pc, 8,
                            registerBuffer.baseAddress, vectorLowBuffer.baseAddress,
                            vectorHighBuffer.baseAddress, &sp, &pc, &pstate, &fpcr, &fpsr,
                            &halted, nil, nil, nil, nil, nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_HALTED))
        XCTAssertEqual(result.steps, 6)
        XCTAssertEqual(vectorLows[0], 0x88)
        XCTAssertEqual(vectorLows[2], 0x5544)
        XCTAssertEqual(vectorLows[4], 0xdead_beef)
        XCTAssertEqual(vectorLows[6], 0x1122_3344_5566_7788)
        XCTAssertEqual(vectorLows[30], 0xaabb_ccdd)
        for register in [0, 2, 4, 6, 30] {
            XCTAssertEqual(vectorHighs[register], 0)
        }
    }

    private func decode(_ words: [UInt32]) -> [AVZNativeInstruction] {
        words.map { word in
            var instruction = AVZNativeInstruction()
            XCTAssertNotEqual(avz_native_decode_instruction(word, &instruction), 0, String(format: "%08x", word))
            return instruction
        }
    }
}
