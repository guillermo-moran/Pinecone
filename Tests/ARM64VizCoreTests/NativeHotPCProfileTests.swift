import XCTest
@testable import ARM64VizCore

final class NativeHotPCProfileTests: XCTestCase {
    func testProfileCapturesFullBlockAndRefreshesChangedCode() throws {
        let backend = SoftwareARM64Backend()
        backend.setNativeAssemblyExecutorEnabled(false)
        let base = ARM64VizMachineLayout.ramBase
        let memory = PhysicalMemory(base: base, size: 0x10000)
        let vm = VirtualMachine(memory: memory, backend: backend)
        let code = base + 0x8000
        try memory.write64((base + 0x2000) | 3, at: base + 0x1000)
        try memory.write64((base + 0x3000) | 3, at: base + 0x2000)
        try memory.write64((base + 0x4000) | 3, at: base + 0x3000)
        try memory.write64(code | 0x403, at: base + 0x4008)
        let words = Array(repeating: UInt32(0x91000400), count: 15) + [0x17fffff1]
        for (i, word) in words.enumerated() {
            try memory.write32(word, at: code + UInt64(i * 4))
        }
        vm.reset(entryPoint: 0x1000)
        vm.cpu.pstate = ARM64PState.el1h
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: base + 0x1000)
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        backend.setNativeHotPCProfilingEnabled(true)
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.timerCyclesPerInstruction = 0
        _ = try vm.run(maxSteps: 262144)
        let first = try XCTUnwrap(backend.nativeHotPCSnapshot(limit: 256).first { $0.pc == 0x1000 })
        XCTAssertEqual(first.instructions, words)
        XCTAssertGreaterThan(first.samples, 0)
        XCTAssertEqual(first.sampleError, 0)
        XCTAssertTrue(try vm.writeGuestRAMFast(0x1000, width: .word, value: 0x91000800))
        _ = try vm.run(maxSteps: 262144)
        let changed = try XCTUnwrap(backend.nativeHotPCSnapshot(limit: 256).first { $0.pc == 0x1000 })
        XCTAssertEqual(changed.instructions.count, 16)
        XCTAssertEqual(changed.instructions.first, 0x91000800)
        XCTAssertEqual(changed.instructions.last, words.last)
        XCTAssertLessThanOrEqual(changed.samples, first.samples)
        backend.resetNativeHotPCProfile()
        XCTAssertTrue(backend.nativeHotPCSnapshot(limit: 256).isEmpty)
    }
}
