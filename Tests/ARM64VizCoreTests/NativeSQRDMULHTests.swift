import ARM64VizNative
import XCTest
@testable import ARM64VizCore

final class NativeSQRDMULHTests: XCTestCase {
    func testSaturatingMultiplyHighWidthsRoundingAliasingAndQC() throws {
        for bits in [16, 32] {
            for rounded in [false, true] {
                for shape in 0..<3 { // 64-bit vector, 128-bit vector, scalar
                    for destination: UInt32 in [0, 28, 31] {
                        let backend = SoftwareARM64Backend()
                        backend.fallbackInterpreterPolicy = .nativeOnly
                        let machine = try MachineFactory.makeResearchMachine(backend: backend)
                        let entry = ARM64VizMachineLayout.toyEntryPoint
                        let word: UInt32 = 0x0e20_b400 | (UInt32(bits == 16 ? 1 : 2) << 22)
                            | (rounded ? 0x2000_0000 : 0)
                            | (shape == 0 ? 0 : 0x4000_0000)
                            | (shape == 2 ? 0x1000_0000 : 0)
                            | (31 << 16) | (28 << 5) | destination
                        let words: [UInt32] = [word, 0xd440_0000]
                        try machine.vm.loadBinary(words.flatMap { value in
                            withUnsafeBytes(of: value.littleEndian) { Array($0) }
                        }, at: entry)
                        machine.vm.reset(entryPoint: entry)
                        let minimum = -(Int64(1) << (bits - 1))
                        let maximum = (Int64(1) << (bits - 1)) - 1
                        let a = [minimum, 1, -1, maximum, minimum + 1, -16384, 100, -100]
                        let b = [minimum, Int64(1) << (bits - 2), Int64(1) << (bits - 2), maximum,
                                 maximum, -1, maximum, maximum]
                        let mask = (UInt64(1) << bits) - 1
                        func pack(_ values: [Int64], lanes: Int) -> ARM64VectorRegister {
                            var low: UInt64 = 0, high: UInt64 = 0
                            for lane in 0..<lanes {
                                let value = UInt64(bitPattern: values[lane]) & mask
                                if lane * bits < 64 { low |= value << (lane * bits) }
                                else { high |= value << (lane * bits - 64) }
                            }
                            return ARM64VectorRegister(low: low, high: high)
                        }
                        machine.vm.cpu.v[28] = pack(a, lanes: 128 / bits)
                        machine.vm.cpu.v[31] = pack(b, lanes: 128 / bits)
                        machine.vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: 1)
                        let lanes = shape == 2 ? 1 : (shape == 0 ? 64 : 128) / bits
                        let expected = (0..<lanes).map { lane -> Int64 in
                            let product = a[lane] * b[lane]
                            let value = (product + (rounded ? Int64(1) << (bits - 2) : 0)) >> (bits - 1)
                            return min(max(value, minimum), maximum)
                        }
                        XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
                        let result = pack(expected, lanes: lanes)
                        XCTAssertEqual(machine.vm.cpu.v[Int(destination)].low, result.low)
                        XCTAssertEqual(machine.vm.cpu.v[Int(destination)].high, result.high)
                        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr),
                                       (UInt64(1) << 27) | 1)
                        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
                    }
                }
            }
        }
    }

    func testExactLockScreenFailureAndStickyQC() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let words: [UInt32] = [0x6e7f_b795, 0xd440_0000]
        try machine.vm.loadBinary(words.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.v[28] = ARM64VectorRegister(low: 0x4000400040004000, high: 0x4000400040004000)
        machine.vm.cpu.v[31] = machine.vm.cpu.v[28]
        machine.vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: UInt64(1) << 27)
        XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[21].low, 0x2000200020002000)
        XCTAssertEqual(machine.vm.cpu.v[21].high, 0x2000200020002000)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr), UInt64(1) << 27)
        // With no prior saturation, a zero product must leave QC clear.
        machine.vm.reset(entryPoint: entry)
        machine.vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: 0)
        XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr), 0)
    }

    func testReservedLaneWidthsAreRejected() {
        for word: UInt32 in [0x2e22_b420, 0x6ee2_b420] {
            var decoded = AVZNativeInstruction()
            XCTAssertEqual(avz_native_decode_instruction(word, &decoded), 0)
        }
    }
}
