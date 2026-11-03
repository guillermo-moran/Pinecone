import ARM64VizNative
import XCTest

final class NativeCLREXTests: XCTestCase {
    func testCLREXDecodesAndClearsLocalExclusiveMonitor() {
        var instruction = AVZNativeInstruction()
        XCTAssertNotEqual(
            avz_native_decode_instruction(0xd503_3f5f, &instruction),
            0
        )

        var registers = [UInt64](repeating: 0, count: 31)
        var vectorLows = [UInt64](repeating: 0, count: 32)
        var vectorHighs = [UInt64](repeating: 0, count: 32)
        var sp: UInt64 = 0
        var pc: UInt64 = 0x8_000
        var pstate: UInt64 = 0x6000_03c5
        var fpcr: UInt64 = 0
        var fpsr: UInt64 = 0
        var exclusiveAddress: UInt64 = 0x12_340
        var exclusiveGeneration: UInt64 = 99
        var exclusiveSize: UInt8 = 8
        var exclusiveValid: UInt8 = 1
        var halted: UInt8 = 0

        let result = withUnsafeMutablePointer(to: &instruction) { instructionPointer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                vectorLows.withUnsafeMutableBufferPointer { lowBuffer in
                    vectorHighs.withUnsafeMutableBufferPointer { highBuffer in
                        avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
                            instructionPointer,
                            1,
                            0x8_000,
                            1,
                            registerBuffer.baseAddress,
                            lowBuffer.baseAddress,
                            highBuffer.baseAddress,
                            &sp,
                            &pc,
                            &pstate,
                            &fpcr,
                            &fpsr,
                            &exclusiveAddress,
                            &exclusiveGeneration,
                            &exclusiveSize,
                            &exclusiveValid,
                            &halted,
                            nil, nil, nil, nil,
                            nil, nil, nil, nil, nil, nil,
                            nil
                        )
                    }
                }
            }
        }

        XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_MAX_STEPS))
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(pc, 0x8_004)
        XCTAssertEqual(pstate, 0x6000_03c5)
        XCTAssertEqual(exclusiveAddress, 0)
        XCTAssertEqual(exclusiveGeneration, 0)
        XCTAssertEqual(exclusiveSize, 0)
        XCTAssertEqual(exclusiveValid, 0)
    }
}
