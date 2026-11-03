import ARM64VizNative
import Dispatch
import XCTest
@testable import ARM64VizCore

private let lseIdentityTranslate: AVZNativeMemoryTranslateRAMCallback = {
    context, virtualAddress, _, _, physicalAddress in
    guard context != nil, let physicalAddress else { return 0 }
    physicalAddress.pointee = virtualAddress
    return 1
}

final class NativeLSEAtomicTests: XCTestCase {
    private func atomicRMWWord(
        size: UInt32,
        ordering: UInt32,
        opcode: UInt32,
        rs: UInt32 = 0,
        rn: UInt32 = 2,
        rt: UInt32 = 1
    ) -> UInt32 {
        0x3820_0000 |
            (size << 30) |
            ((ordering & 1) << 23) |
            (((ordering >> 1) & 1) << 22) |
            (rs << 16) |
            (opcode << 12) |
            (rn << 5) |
            rt
    }

    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    private func decode(_ word: UInt32) -> AVZNativeInstruction {
        var decoded = AVZNativeInstruction()
        XCTAssertNotEqual(avz_native_decode_instruction(word, &decoded), 0)
        return decoded
    }

    private func withFastMemory<T>(
        _ body: (OpaquePointer, OpaquePointer, UnsafeMutablePointer<UInt8>) throws -> T
    ) throws -> T {
        let guest = try XCTUnwrap(avz_guest_memory_create(0x3000))
        defer { avz_guest_memory_destroy(guest) }
        let ram = try XCTUnwrap(avz_guest_memory_bytes(guest))
        let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
            ram, 0, 0x3000, nil, UnsafeMutableRawPointer(guest),
            lseIdentityTranslate,
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        ))
        defer { avz_native_memory_fast_path_destroy(fastPath) }
        XCTAssertNotEqual(
            avz_native_memory_fast_path_set_guest_memory(fastPath, guest), 0)
        return try body(guest, fastPath, ram)
    }

    private func store(
        _ value: UInt64,
        width: Int,
        at address: Int,
        in ram: UnsafeMutablePointer<UInt8>
    ) {
        var value = value
        memcpy(ram.advanced(by: address), &value, width)
    }

    private func load(
        width: Int,
        at address: Int,
        in ram: UnsafeMutablePointer<UInt8>
    ) -> UInt64 {
        var value: UInt64 = 0
        memcpy(&value, ram.advanced(by: address), width)
        return value
    }

    private func run(
        _ word: UInt32,
        registers: inout [UInt64],
        fastPath: OpaquePointer?
    ) -> AVZNativeBlockResult {
        var instruction = decode(word)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8000
        var pstate: UInt64 = 0
        var halted: UInt8 = 0
        return withUnsafeMutablePointer(to: &instruction) { instructionPointer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                avz_native_run_threaded_decoded_block_registers(
                    instructionPointer, 1, 0x8000, 1,
                    registerBuffer.baseAddress, &sp, &pc, &pstate, &halted,
                    fastPath == nil ? nil : avz_native_fast_memory_read,
                    fastPath == nil ? nil : avz_native_fast_memory_write,
                    fastPath == nil ? nil : avz_native_fast_memory_can_access,
                    nil,
                    fastPath.map(UnsafeMutableRawPointer.init)
                )
            }
        }
    }

    func testDecodesCASWidthsAndOrderingVariants() {
        let cases: [(UInt32, UInt8, UInt8)] = [
            (0x08a0_7c41, 1, 0), (0x08e3_7ca4, 1, 1),
            (0x08a6_fd07, 1, 2), (0x08e9_fd6a, 1, 3),
            (0x48a0_7c41, 2, 0), (0x48e3_7ca4, 2, 1),
            (0x48a6_fd07, 2, 2), (0x48e9_fd6a, 2, 3),
            (0x88a0_7c41, 4, 0), (0x88e3_7ca4, 4, 1),
            (0x88a6_fd07, 4, 2), (0x88e9_fd6a, 4, 3),
            (0xc8a0_7c41, 8, 0), (0xc8e3_7ca4, 8, 1),
            (0xc8a6_fd07, 8, 2), (0xc8e9_fd6a, 8, 3)
        ]
        for (word, width, flags) in cases {
            let instruction = decode(word)
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_LSE_ATOMIC)
            XCTAssertEqual(instruction.condition, UInt8(AVZ_NATIVE_LSE_COMPARE_EXCHANGE))
            XCTAssertEqual(instruction.width, width)
            XCTAssertEqual(instruction.bits, width * 8)
            XCTAssertEqual(instruction.flags, flags)
        }
    }

    func testDecodesARTAtomicReadModifyWriteInstructions() {
        let cases: [(UInt32, Int, UInt8)] = [
            (0xb8e0_0041, AVZ_NATIVE_LSE_ADD, 4),
            (0xf8e3_00a4, AVZ_NATIVE_LSE_ADD, 8),
            (0xb8e6_1107, AVZ_NATIVE_LSE_CLEAR, 4),
            (0xf8e9_116a, AVZ_NATIVE_LSE_CLEAR, 8),
            (0xb8ec_81cd, AVZ_NATIVE_LSE_SWAP, 4),
            (0xf8ef_8230, AVZ_NATIVE_LSE_SWAP, 8)
        ]
        for (word, operation, width) in cases {
            let instruction = decode(word)
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_LSE_ATOMIC)
            XCTAssertEqual(Int(instruction.condition), operation)
            XCTAssertEqual(instruction.width, width)
            XCTAssertEqual(instruction.flags, 3)
        }
    }

    func testDecodesRelaxedAcquireReleaseAndAcquireReleaseRMWForms() {
        let cases: [(UInt32, UInt8)] = [
            (0xb820_0041, 0), // ldadd
            (0xb8a0_0041, 1), // ldadda
            (0xb860_0041, 2), // ldaddl
            (0xb8e0_0041, 3)  // ldaddal
        ]
        for (word, flags) in cases {
            let instruction = decode(word)
            XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_LSE_ATOMIC)
            XCTAssertEqual(Int(instruction.condition), AVZ_NATIVE_LSE_ADD)
            XCTAssertEqual(instruction.flags, flags)
        }
    }

    func testDecodesEveryScalarRMWOperationWidthAndOrdering() {
        let operations: [(opcode: UInt32, operation: Int)] = [
            (0, AVZ_NATIVE_LSE_ADD),
            (1, AVZ_NATIVE_LSE_CLEAR),
            (2, AVZ_NATIVE_LSE_XOR),
            (3, AVZ_NATIVE_LSE_SET),
            (4, AVZ_NATIVE_LSE_SIGNED_MAX),
            (5, AVZ_NATIVE_LSE_SIGNED_MIN),
            (6, AVZ_NATIVE_LSE_UNSIGNED_MAX),
            (7, AVZ_NATIVE_LSE_UNSIGNED_MIN),
            (8, AVZ_NATIVE_LSE_SWAP)
        ]
        for size in UInt32(0)...3 {
            for ordering in UInt32(0)...3 {
                for operation in operations {
                    let instruction = decode(atomicRMWWord(
                        size: size,
                        ordering: ordering,
                        opcode: operation.opcode
                    ))
                    XCTAssertEqual(Int(instruction.kind), AVZ_NATIVE_OP_LSE_ATOMIC)
                    XCTAssertEqual(Int(instruction.condition), operation.operation)
                    XCTAssertEqual(instruction.width, UInt8(1 << size))
                    XCTAssertEqual(instruction.flags, UInt8(ordering))
                }
            }
        }
    }

    func testCASExecutesForByteHalfWordWordAndXWord() throws {
        try withFastMemory { _, fastPath, ram in
            let words: [UInt32] = [
                0x08e0_fc41, // casalb w0, w1, [x2]
                0x48e0_fc41, // casalh w0, w1, [x2]
                0x88e0_fc41, // casal w0, w1, [x2]
                0xc8e0_fc41  // casal x0, x1, [x2]
            ]
            let masks: [UInt64] = [0xff, 0xffff, 0xffff_ffff, UInt64.max]
            for index in words.indices {
                let width = 1 << index
                let initial = UInt64(0xfedc_ba98_7654_32a5) & masks[index]
                let desired = UInt64(0x0123_4567_89ab_cdef) & masks[index]
                store(initial, width: width, at: 0x1000, in: ram)
                var registers = [UInt64](repeating: 0, count: 31)
                registers[0] = initial
                registers[1] = desired
                registers[2] = 0x1000
                let result = run(words[index], registers: &registers, fastPath: fastPath)
                XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_MAX_STEPS))
                XCTAssertEqual(registers[0], initial)
                XCTAssertEqual(load(width: width, at: 0x1000, in: ram), desired)
            }

            store(0x1111_2222_3333_4444, width: 8, at: 0x1000, in: ram)
            var registers = [UInt64](repeating: 0, count: 31)
            registers[0] = 0xaaaa
            registers[1] = 0x5555
            registers[2] = 0x1000
            _ = run(0xc8e0_fc41, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(registers[0], 0x1111_2222_3333_4444)
            XCTAssertEqual(load(width: 8, at: 0x1000, in: ram), 0x1111_2222_3333_4444)
        }
    }

    func testARTLDADDALLDCLRALAndSWPALExecute() throws {
        try withFastMemory { _, fastPath, ram in
            var registers = [UInt64](repeating: 0, count: 31)

            store(10, width: 4, at: 0x1000, in: ram)
            registers[0] = 7
            registers[2] = 0x1000
            _ = run(0xb8e0_0041, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(registers[1], 10)
            XCTAssertEqual(load(width: 4, at: 0x1000, in: ram), 17)

            store(0xff0f, width: 8, at: 0x1000, in: ram)
            registers[9] = 0x0f0f
            registers[11] = 0x1000
            _ = run(0xf8e9_116a, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(registers[10], 0xff0f)
            XCTAssertEqual(load(width: 8, at: 0x1000, in: ram), 0xf000)

            store(0xaaaa_bbbb, width: 4, at: 0x1000, in: ram)
            registers[12] = 0x1234_5678
            registers[14] = 0x1000
            _ = run(0xb8ec_81cd, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(registers[13], 0xaaaa_bbbb)
            XCTAssertEqual(load(width: 4, at: 0x1000, in: ram), 0x1234_5678)
        }
    }

    func testLDEXORSETAndMinMaxExecuteAtEveryWidth() throws {
        try withFastMemory { _, fastPath, ram in
            for size in UInt32(0)...3 {
                let width = 1 << Int(size)
                let bits = width * 8
                let mask = width == 8 ? UInt64.max : (UInt64(1) << bits) - 1
                let negativeFive = mask - 4
                let operations: [(opcode: UInt32, initial: UInt64, operand: UInt64, expected: UInt64)] = [
                    (2, 0xa5 & mask, 0x3c & mask, (0xa5 ^ 0x3c) & mask),
                    (3, 0x81 & mask, 0x36 & mask, (0x81 | 0x36) & mask),
                    (4, negativeFive, 3, 3),
                    (5, negativeFive, 3, negativeFive),
                    (6, 2, 7, 7),
                    (7, 2, 7, 2)
                ]
                for operation in operations {
                    store(operation.initial, width: width, at: 0x1000, in: ram)
                    var registers = [UInt64](repeating: 0, count: 31)
                    registers[0] = operation.operand
                    registers[2] = 0x1000
                    let word = atomicRMWWord(
                        size: size,
                        ordering: size,
                        opcode: operation.opcode
                    )
                    _ = run(word, registers: &registers, fastPath: fastPath)
                    XCTAssertEqual(registers[1], operation.initial)
                    XCTAssertEqual(load(width: width, at: 0x1000, in: ram), operation.expected)
                }
            }
        }
    }

    func testRealKernelSTSETAndLDEORALWordsExecuteExactly() throws {
        try withFastMemory { _, fastPath, ram in
            store(0x10, width: 8, at: 0x1000, in: ram)
            var registers = [UInt64](repeating: 0, count: 31)
            registers[22] = 0x20
            registers[23] = 0x1000
            _ = run(0xf836_32ff, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(load(width: 8, at: 0x1000, in: ram), 0x30)

            store(0x0000_ff00, width: 4, at: 0x1000, in: ram)
            registers[11] = 0x1000
            registers[16] = 0x0000_0f0f
            _ = run(0xb8f0_2175, registers: &registers, fastPath: fastPath)
            XCTAssertEqual(registers[21], 0x0000_ff00)
            XCTAssertEqual(load(width: 4, at: 0x1000, in: ram), 0x0000_f00f)
        }
    }

    func testBackendRunsRealKernelSTSETWithoutSwiftLoadStoreFallback() throws {
        let backend = SoftwareARM64Backend()
        backend.enableBasicBlockExecution = true
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let destination = entry + 0x4000
        try machine.vm.loadBinary(words([0xf836_32ff, 0xd440_0000]), at: entry)
        try machine.vm.memory.write64(0x10, at: destination)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.x[22] = 0x20
        machine.vm.cpu.x[23] = destination

        let result = try machine.vm.run(maxSteps: 4)

        XCTAssertEqual(result.stopReason, .halted)
        XCTAssertEqual(try machine.vm.memory.read64(at: destination), 0x30)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testUnsupportedLSEAndCASPWordsCannotFallThroughToLoadStore() throws {
        let backend = SoftwareARM64Backend()
        backend.enableBasicBlockExecution = false
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let destination = entry + 0x4000

        for word: UInt32 in [0x78b4_9006, 0x4820_7c82] {
            try machine.vm.loadBinary(words([word]), at: entry)
            try machine.vm.memory.write64(0x1122_3344_5566_7788, at: destination)
            machine.vm.reset(entryPoint: entry)
            machine.vm.cpu.x[0] = destination
            machine.vm.cpu.x[4] = destination

            XCTAssertThrowsError(try backend.step(machine.vm))
            XCTAssertEqual(
                try machine.vm.memory.read64(at: destination),
                0x1122_3344_5566_7788,
                "encoding \(String(word, radix: 16))"
            )
        }
    }

    func testAtomicWriteInvalidatesExistingExclusiveReservation() throws {
        try withFastMemory { _, fastPath, ram in
            store(40, width: 8, at: 0x1000, in: ram)
            var observed: UInt64 = 0
            var generation: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_exclusive_read(
                UnsafeMutableRawPointer(fastPath), 0x1000, 8,
                &observed, &generation
            ), 0)
            var old: UInt64 = 0
            XCTAssertNotEqual(avz_native_fast_memory_atomic_rmw(
                UnsafeMutableRawPointer(fastPath), 0x1000, 8,
                UInt8(AVZ_NATIVE_LSE_ADD), 2, 0, &old
            ), 0)
            XCTAssertEqual(old, 40)
            XCTAssertEqual(avz_native_fast_memory_exclusive_write(
                UnsafeMutableRawPointer(fastPath), 0x1000, 8, 99, generation
            ), 0)
            XCTAssertEqual(load(width: 8, at: 0x1000, in: ram), 42)
        }
    }

    func testAtomicAddSerializesConcurrentVCPUs() throws {
        try withFastMemory { _, fastPath, ram in
            store(0, width: 8, at: 0x1000, in: ram)
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                for _ in 0..<1_000 {
                    var old: UInt64 = 0
                    _ = avz_native_fast_memory_atomic_rmw(
                        UnsafeMutableRawPointer(fastPath), 0x1000, 8,
                        UInt8(AVZ_NATIVE_LSE_ADD), 1, 0, &old
                    )
                }
            }
            XCTAssertEqual(load(width: 8, at: 0x1000, in: ram), 4_000)
        }
    }

    func testFirstAtomicObservationLinearizesWithOrdinaryGuestStore() throws {
        let pageCount = 2_048
        let pageSize = 0x1000
        let byteCount = pageCount * pageSize
        let guest = try XCTUnwrap(avz_guest_memory_create(byteCount))
        defer { avz_guest_memory_destroy(guest) }
        let ram = try XCTUnwrap(avz_guest_memory_bytes(guest))

        func makeFastPath() throws -> OpaquePointer {
            let path = try XCTUnwrap(avz_native_memory_fast_path_create(
                ram, 0, UInt64(byteCount), nil, UnsafeMutableRawPointer(guest),
                lseIdentityTranslate,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            XCTAssertNotEqual(
                avz_native_memory_fast_path_set_guest_memory(path, guest), 0)
            return path
        }

        let atomicPath = try makeFastPath()
        defer { avz_native_memory_fast_path_destroy(atomicPath) }
        let storePath = try makeFastPath()
        defer { avz_native_memory_fast_path_destroy(storePath) }
        let observed = UnsafeMutablePointer<UInt64>.allocate(capacity: pageCount)
        observed.initialize(repeating: 0, count: pageCount)
        defer {
            observed.deinitialize(count: pageCount)
            observed.deallocate()
        }

        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            start.wait()
            for page in 0..<pageCount {
                let address = UInt64(page * pageSize)
                _ = avz_native_fast_memory_atomic_rmw(
                    UnsafeMutableRawPointer(atomicPath), address, 8,
                    UInt8(AVZ_NATIVE_LSE_ADD), 1, 0,
                    observed.advanced(by: page)
                )
            }
            finished.leave()
        }
        finished.enter()
        DispatchQueue.global().async {
            start.wait()
            for page in 0..<pageCount {
                _ = avz_native_fast_memory_write(
                    UnsafeMutableRawPointer(storePath),
                    UInt64(page * pageSize), 8, 100)
            }
            finished.leave()
        }
        start.signal()
        start.signal()
        let completion = finished.wait(timeout: .now() + 10)
        if completion != .success {
            XCTFail("concurrent atomic/store workers timed out")
            finished.wait()
            return
        }

        for page in 0..<pageCount {
            let final = load(width: 8, at: page * pageSize, in: ram)
            switch observed[page] {
            case 0:
                XCTAssertEqual(final, 100, "page \(page)")
            case 100:
                XCTAssertEqual(final, 101, "page \(page)")
            default:
                XCTFail("unexpected old value \(observed[page]) on page \(page)")
            }
        }
    }

    func testUnsupportedContextAndUnalignedAtomicFallBackSafely() throws {
        var registers = [UInt64](repeating: 0, count: 31)
        registers[0] = 1
        registers[1] = 2
        registers[2] = 0x1000
        let result = run(0xc8e0_fc41, registers: &registers, fastPath: nil)
        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED))

        try withFastMemory { _, fastPath, _ in
            var old: UInt64 = 0
            XCTAssertEqual(avz_native_fast_memory_atomic_rmw(
                UnsafeMutableRawPointer(fastPath), 0x1001, 8,
                UInt8(AVZ_NATIVE_LSE_SWAP), 9, 0, &old
            ), 0)
        }
    }
}
