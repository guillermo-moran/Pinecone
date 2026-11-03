import ARM64VizNative
import XCTest
@testable import ARM64VizCore

final class NativeVectorFADDPTests: XCTestCase {
    func testVectorPairwiseAddArrangementsAndAliasing() throws {
        for arrangement in 0..<3 {
            for destination: UInt32 in [0, 1, 2, 31] {
                let backend = SoftwareARM64Backend()
                backend.fallbackInterpreterPolicy = .nativeOnly
                let machine = try MachineFactory.makeResearchMachine(backend: backend)
                let entry = ARM64VizMachineLayout.toyEntryPoint
                let base: UInt32 = arrangement == 0 ? 0x2e20_d400
                    : arrangement == 1 ? 0x6e20_d400 : 0x6e60_d400
                let word = base | (2 << 16) | (1 << 5) | destination
                let words: [UInt32] = [word, 0xd440_0000]
                try machine.vm.loadBinary(words.flatMap { word in
                    withUnsafeBytes(of: word.littleEndian) { Array($0) }
                }, at: entry)
                machine.vm.reset(entryPoint: entry)
                func pack(_ a: Float, _ b: Float) -> UInt64 {
                    UInt64(a.bitPattern) | (UInt64(b.bitPattern) << 32)
                }
                machine.vm.cpu.v[1] = arrangement == 2
                    ? ARM64VectorRegister(low: Double(1.5).bitPattern, high: Double(-4).bitPattern)
                    : ARM64VectorRegister(low: pack(1.5, -4), high: pack(8, 2))
                machine.vm.cpu.v[2] = arrangement == 2
                    ? ARM64VectorRegister(low: Double(16).bitPattern, high: Double(4).bitPattern)
                    : ARM64VectorRegister(low: pack(16, 4), high: pack(-8, 3))
                machine.vm.timerCyclesPerInstruction = 0
                let result = try machine.vm.run(maxSteps: 4)
                XCTAssertEqual(result.stopReason, .halted)
                XCTAssertEqual(machine.vm.cpu.v[Int(destination)].low,
                    arrangement == 2 ? Double(-2.5).bitPattern
                        : arrangement == 0 ? pack(-2.5, 20) : pack(-2.5, 10))
                XCTAssertEqual(machine.vm.cpu.v[Int(destination)].high,
                    arrangement == 2 ? Double(20).bitPattern
                        : arrangement == 0 ? 0 : pack(20, -5))
                XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
            }
        }
    }

    func testExactSimulatorOpcodeWithAllOperandsAliased() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let words: [UInt32] = [0x6e21_d421, 0xd440_0000]
        try machine.vm.loadBinary(words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        }, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.v[1] = ARM64VectorRegister(low: 0x40000000_3f800000, high: 0x40800000_40400000)
        XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[1].low, 0x40e00000_40400000)
        XCTAssertEqual(machine.vm.cpu.v[1].high, 0x40e00000_40400000)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testReservedOneDoubleVectorIsRejected() {
        var decoded = AVZNativeInstruction()
        XCTAssertEqual(avz_native_decode_instruction(0x2e62_d420, &decoded), 0)
    }
}
