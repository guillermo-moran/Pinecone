import ARM64VizNative
import XCTest
@testable import ARM64VizCore

final class NativeHalvingArithmeticTests: XCTestCase {
    func testHalvingArithmeticWidthsRoundingAliasingAndPrototypeFallback() throws {
        for assembly in [false, true] {
            for bits in [8, 16, 32] {
                for operation in 0..<6 { // signed/unsigned ADD, rounded ADD, SUB
                    for wide in [false, true] {
                        for destination: UInt32 in [0, 2, 31] {
                            let backend = SoftwareARM64Backend()
                            backend.fallbackInterpreterPolicy = .nativeOnly
                            backend.setNativeAssemblyExecutorEnabled(assembly)
                            let machine = try MachineFactory.makeResearchMachine(backend: backend)
                            let entry = ARM64VizMachineLayout.toyEntryPoint
                            let size: UInt32 = bits == 8 ? 0 : bits == 16 ? 1 : 2
                            let unsigned = operation % 2 != 0
                            let rounded = operation / 2 == 1
                            let subtract = operation / 2 == 2
                            let opcode: UInt32 = subtract ? 0x0e20_2400 : rounded ? 0x0e20_1400 : 0x0e20_0400
                            let word = opcode | (unsigned ? 0x2000_0000 : 0)
                                | (wide ? 0x4000_0000 : 0) | (size << 22)
                                | (31 << 16) | (2 << 5) | destination
                            let words: [UInt32] = [word, 0xd440_0000]
                            try machine.vm.loadBinary(words.flatMap { value in
                                withUnsafeBytes(of: value.littleEndian) { Array($0) }
                            }, at: entry)
                            machine.vm.reset(entryPoint: entry)
                            let mask = (UInt64(1) << bits) - 1
                            let sign = UInt64(1) << (bits - 1)
                            let lhs: [UInt64] = [mask, 0, sign, sign - 1, 1, mask - 1, 3, 2]
                            let rhs: [UInt64] = [mask, 1, sign - 1, sign - 1, 2, 1, 0, mask]
                            func pack(_ values: [UInt64], lanes: Int) -> ARM64VectorRegister {
                                var low: UInt64 = 0, high: UInt64 = 0
                                for lane in 0..<lanes {
                                    let value = values[lane % values.count] & mask
                                    if lane * bits < 64 { low |= value << (lane * bits) }
                                    else { high |= value << (lane * bits - 64) }
                                }
                                return ARM64VectorRegister(low: low, high: high)
                            }
                            machine.vm.cpu.v[2] = pack(lhs, lanes: 128 / bits)
                            machine.vm.cpu.v[31] = pack(rhs, lanes: 128 / bits)
                            machine.vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: 0x0800_009f)
                            func extend(_ value: UInt64) -> Int64 {
                                if unsigned || value & sign == 0 { return Int64(value) }
                                return Int64(value) - (Int64(1) << bits)
                            }
                            let lanes = (wide ? 128 : 64) / bits
                            let expected = (0..<lanes).map { lane -> UInt64 in
                                let a = extend(lhs[lane % lhs.count]), b = extend(rhs[lane % rhs.count])
                                let value = (subtract ? a - b : a + b) + (rounded ? 1 : 0)
                                // Swift's signed shift rounds negative odd values toward -infinity.
                                return UInt64(bitPattern: value >> 1) & mask
                            }
                            XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
                            let result = pack(expected, lanes: lanes)
                            XCTAssertEqual(machine.vm.cpu.v[Int(destination)].low, result.low, "opcode \(String(word, radix: 16))")
                            XCTAssertEqual(machine.vm.cpu.v[Int(destination)].high, result.high)
                            XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr), 0x0800_009f)
                            XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
                        }
                    }
                }
            }
        }
    }

    func testExactAndroidFailure() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeAssemblyExecutorEnabled(true)
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let words: [UInt32] = [0x2e23_0442, 0xd440_0000]
        try machine.vm.loadBinary(words.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.cpu.v[2] = ARM64VectorRegister(low: 0xff00_0102_7f80_feff, high: .max)
        machine.vm.cpu.v[3] = ARM64VectorRegister(low: 0xff01_0201_807f_0102, high: .max)
        XCTAssertEqual(try machine.vm.run(maxSteps: 4).stopReason, .halted)
        XCTAssertEqual(machine.vm.cpu.v[2].low, 0xff00_0101_7f7f_7f80)
        XCTAssertEqual(machine.vm.cpu.v[2].high, 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testReservedWidthsAndScalarFormsAreRejected() {
        for base: UInt32 in [0x0e20_0400, 0x0e20_1400, 0x0e20_2400] {
            for modifiers: UInt32 in [0x00c0_0000, 0x40c0_0000, 0x5000_0000] {
                var decoded = AVZNativeInstruction()
                XCTAssertEqual(avz_native_decode_instruction(base | modifiers, &decoded), 0)
            }
        }
    }
}
