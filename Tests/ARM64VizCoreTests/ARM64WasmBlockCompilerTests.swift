import XCTest
@testable import ARM64VizCore

final class ARM64WasmBlockCompilerTests: XCTestCase {
    func testRuntimeModuleAndNativeReferenceWrap64Bits() throws {
        let p = try ARM64WasmProgram.sample()
        XCTAssertEqual(Array(p.module.prefix(8)), [0,97,115,109,1,0,0,0])
        XCTAssertEqual(p.memoryPages, 2)
        let r = try WasmPrototypeReference.execute(p, blocks:32, registers:WasmPrototypeReference.sampleRegisters())
        XCTAssertEqual(r.registers[0], "0000000000000018")
        XCTAssertEqual(r.registers[2], r.registers[0])
        XCTAssertEqual(r.registers[3], "0000000000000000")
        XCTAssertEqual(r.pc, "0000000000001000")
        XCTAssertEqual(r.retiredInstructions, "00000000000000a0")
        XCTAssertEqual(r.ramSample[0], 24)
        XCTAssertEqual(r.nativeInstructions, 160)
        let mmu = try WasmPrototypeReference.executeMMU(p, blocks:32, registers:WasmPrototypeReference.sampleRegisters())
        XCTAssertEqual(mmu.registers, r.registers)
        XCTAssertEqual(mmu.pc, r.pc)
        XCTAssertEqual(mmu.ramSample, r.ramSample)
    }
    func testUntranslatedControlFlowAndFlagsAreRejected() throws {
        for code: [UInt32] in [[0xd503201f, 0x14000001], [0xb1000400, 0x17ffffff],
                               [0xd4000001, 0x17ffffff], [0x32800000, 0x17ffffff],
                               [0xffffffff, 0x17ffffff]] {
            XCTAssertThrowsError(try ARM64WasmProgram(words:code))
        }
        XCTAssertThrowsError(try ARM64WasmProgram(words:[0x14000000]))
        XCTAssertThrowsError(try ARM64WasmProgram(words:[0xd503201f,0x17ffffff], basePC:3))
    }
    func testZeroBudgetKeepsGuestState() throws {
        let p = try ARM64WasmProgram.sample(), registers = WasmPrototypeReference.sampleRegisters()
        let r = try WasmPrototypeReference.execute(p, blocks:0, registers:registers)
        XCTAssertEqual(r.registers[0], "fffffffffffffff8")
        XCTAssertEqual(r.retiredInstructions, "0000000000000000")
        XCTAssertEqual(r.ramSample, Array(repeating:0, count:16))
    }
}
