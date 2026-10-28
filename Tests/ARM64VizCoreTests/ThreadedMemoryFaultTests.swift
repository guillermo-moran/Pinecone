import XCTest
import ARM64VizCore

private final class ThreadedFaultDevice: MMIODevice {
    let name = "threaded-memory-fault"
    let range = AddressRange(start: 0x5000_0000, length: 0x1000)
    private(set) var prefixWrites: [UInt64] = []
    private(set) var failedReads = 0
    private(set) var failedWrites = 0

    func read(offset: UInt64, width: MMIOWidth) throws -> UInt64 {
        XCTAssertEqual(offset, 8)
        XCTAssertEqual(width, .doubleword)
        failedReads += 1
        throw VMError.deviceError("intentional threaded load failure")
    }

    func write(offset: UInt64, width: MMIOWidth, value: UInt64) throws {
        XCTAssertEqual(width, .doubleword)
        if offset == 0 {
            prefixWrites.append(value)
            return
        }
        XCTAssertEqual(offset, 8)
        failedWrites += 1
        throw VMError.deviceError("intentional threaded store failure")
    }

    func reset() {
        prefixWrites.removeAll()
        failedReads = 0
        failedWrites = 0
    }
}

final class ThreadedMemoryFaultTests: XCTestCase {
    func testThreadedLoadFailurePublishesRetiredPrefixWithoutRetry() throws {
        try checkFault(isLoad: true)
    }

    func testThreadedStoreFailurePublishesRetiredPrefixWithoutRetry() throws {
        try checkFault(isLoad: false)
    }

    private func checkFault(isLoad: Bool) throws {
        let ramBase: GuestAddress = 0x4000_0000
        let tables = (0..<4).map { ramBase + UInt64($0 + 1) * 0x1000 }
        let codePhysical = ramBase + 0x10_000
        let dataPhysical = ramBase + 0x11_000
        let entry: GuestAddress = 0x1000
        let memory = PhysicalMemory(base: ramBase, size: 0x20_000)
        let device = ThreadedFaultDevice()
        let bus = MMIOBus()
        try bus.register(device)
        for level in 0..<3 {
            try memory.write64(tables[level + 1] | 3, at: tables[level])
        }
        try memory.write64(codePhysical | 0x403, at: tables[3] + 8)
        try memory.write64(dataPhysical | 0x403, at: tables[3] + 16)
        try memory.write64(device.range.start | 0x403, at: tables[3] + 24)

        // Successful memory boundaries must retain their prefix before the
        // later helper throws. The trailing ADD and HLT must not retire.
        let program: [UInt32] = [
            0xb100_0400, // adds x0, x0, #1
            0x9100_43ff, // add sp, sp, #16
            0xf900_0020, // str x0, [x1] (counted MMIO side effect)
            0xf900_00a6, // str x6, [x5] (RAM side effect)
            0xf100_0484, // subs x4, x4, #1
            isLoad ? 0xf940_0043 : 0xf900_0043, // ldr/str x3, [x2]
            0x9100_04e7, // add x7, x7, #1
            0xd440_0000  // hlt #0
        ]
        for (index, word) in program.enumerated() {
            try memory.write32(word, at: codePhysical + UInt64(index * 4))
        }
        let canary: UInt64 = 0x1122_3344_5566_7788
        try memory.write64(canary, at: dataPhysical - 8)
        try memory.write64(0, at: dataPhysical)
        try memory.write64(canary, at: dataPhysical + 8)

        let backend = SoftwareARM64Backend()
        backend.enableBasicBlockExecution = true
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeThreadedPrototypeEnabled(true)
        backend.setNativeThreadedMemoryEnabled(true)
        let vm = VirtualMachine(memory: memory, mmio: bus, backend: backend)
        vm.reset(entryPoint: entry)
        vm.cpu.pstate = 0x8000_03c5 // EL1h, interrupts masked, N initially set
        vm.cpu.sp = 0x8000
        vm.cpu.x[0] = .max
        vm.cpu.x[1] = 0x3000
        vm.cpu.x[2] = 0x3008
        vm.cpu.x[3] = 0xfeed_face_dead_beef
        vm.cpu.x[4] = 1
        vm.cpu.x[5] = 0x2000
        vm.cpu.x[6] = 0x0123_4567_89ab_cdef
        vm.cpu.x[7] = 41
        vm.cpu.v[0] = ARM64VectorRegister(low: canary, high: ~canary)
        vm.writeSystemRegister(ARM64SystemRegister.fpcr, value: 0x0040_0000)
        vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: 0x10)
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: tables[0])
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.timerCyclesPerInstruction = 0

        var expectedCPU = vm.cpu
        expectedCPU.x[0] = 0
        expectedCPU.x[4] = 0
        expectedCPU.sp += 16
        expectedCPU.pc = entry + 5 * 4
        expectedCPU.pstate = 0x6000_03c5 // Z and C from SUBS, same EL/DAIF

        XCTAssertThrowsError(try vm.run(maxSteps: 64)) { error in
            guard let vmError = error as? VMError,
                  case let .deviceError(message) = vmError else {
                return XCTFail("Expected threaded helper failure, got \(error)")
            }
            XCTAssertEqual(message, "native threaded memory access failed at PC 0x1014")
        }
        XCTAssertEqual(vm.cpu, expectedCPU)
        XCTAssertEqual(vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpcr), 0x0040_0000)
        XCTAssertEqual(vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr), 0x10)
        XCTAssertEqual(try memory.read64(at: dataPhysical), expectedCPU.x[6])
        XCTAssertEqual(try memory.read64(at: dataPhysical - 8), canary)
        XCTAssertEqual(try memory.read64(at: dataPhysical + 8), canary)
        XCTAssertEqual(device.prefixWrites, [0], "A retired MMIO store must not replay")
        XCTAssertEqual(device.failedReads, isLoad ? 1 : 0, "A failed MMIO read must not retry")
        XCTAssertEqual(device.failedWrites, isLoad ? 0 : 1, "A failed MMIO write must not retry")
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        let statistics = backend.nativeThreadedPrototypeStatistics
        XCTAssertEqual(statistics["enabled"], 1)
        XCTAssertEqual(statistics["memoryEnabled"], 1)
        XCTAssertEqual(statistics["memoryFaults"], 1)
        XCTAssertGreaterThan(statistics["steps"] ?? 0, 0)
    }
}
