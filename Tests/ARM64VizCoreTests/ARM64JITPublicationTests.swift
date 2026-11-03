import XCTest
@testable import ARM64VizCore

final class ARM64JITPublicationTests: XCTestCase {
    func testGuestJITPublicationInvalidatesPeerVCPUCodeCache() throws {
        let memory = PhysicalMemory(
            base: ARM64VizMachineLayout.ramBase,
            size: 2 * 1024 * 1024
        )
        let writerBackend = SoftwareARM64Backend()
        writerBackend.fallbackInterpreterPolicy = .nativeOnly
        let readerBackend = SoftwareARM64Backend()
        readerBackend.fallbackInterpreterPolicy = .nativeOnly
        let writer = VirtualMachine(memory: memory, backend: writerBackend)
        let reader = VirtualMachine(memory: memory, backend: readerBackend)
        let target = ARM64VizMachineLayout.ramBase + 0x10_000
        let publisher = ARM64VizMachineLayout.ramBase + 0x20_000

        try writer.loadBinary(words([
            0x9100_0442, // add x2, x2, #1
            0xd440_0000, // hlt
        ]), at: target)
        try writer.loadBinary(words([
            0xb900_0020, // str w0, [x1]
            0xd50b_7b21, // dc cvau, x1
            0xd503_3b9f, // dsb ish
            0xd50b_7521, // ic ivau, x1
            0xd503_3b9f, // dsb ish
            0xd503_3fdf, // isb
            0xd440_0000, // hlt
        ]), at: publisher)

        reader.reset(entryPoint: target)
        let initial = try reader.run(maxSteps: 8)
        XCTAssertEqual(initial.stopReason, .halted)
        XCTAssertEqual(reader.cpu.x[2], 1)

        writer.reset(entryPoint: publisher)
        writer.cpu.x[0] = 0x9100_0842 // add x2, x2, #2
        writer.cpu.x[1] = target
        let publication = try writer.run(maxSteps: 16)
        XCTAssertEqual(publication.stopReason, .halted)
        XCTAssertEqual(try memory.read32(at: target), 0x9100_0842)

        // Re-enter without resetting the backend so this execution must reject
        // the block previously decoded by the peer reader.
        reader.cpu.pc = target
        reader.cpu.x[2] = 0
        reader.cpu.halted = false
        let patched = try reader.run(maxSteps: 8)
        XCTAssertEqual(patched.stopReason, .halted)
        XCTAssertEqual(reader.cpu.x[2], 2)
        XCTAssertEqual(writerBackend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(readerBackend.swiftFallbackSingleInstructionSteps, 0)
    }

    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in
            let littleEndian = value.littleEndian
            return withUnsafeBytes(of: littleEndian) { Array($0) }
        }
    }
}
