import ARM64VizNative
import XCTest

final class NativeRegisterBranchTests: XCTestCase {
    func testBLRReadsOldLinkRegisterBeforeWritingReturnAddress() {
        for threaded in [false, true] {
            for target: UInt64 in [0, 0x9000, 0x9003, UInt64.max] {
                var instruction = AVZNativeInstruction()
                XCTAssertEqual(avz_native_decode_instruction(0xd63f03c0, &instruction), 1)
                var registers = [UInt64](repeating: 0, count: 31)
                registers[30] = target
                var sp: UInt64 = 0x4000
                var pc: UInt64 = 0x8000
                var pstate: UInt64 = 5
                var halted: UInt8 = 0
                let result = registers.withUnsafeMutableBufferPointer { registers in
                    if threaded {
                        return avz_native_run_threaded_decoded_block_registers(
                            &instruction, 1, 0x8000, 1, registers.baseAddress,
                            &sp, &pc, &pstate, &halted, nil, nil, nil, nil, nil
                        )
                    }
                    return avz_native_run_decoded_block_registers(
                        &instruction, 1, 0x8000, 1, registers.baseAddress,
                        &sp, &pc, &pstate, &halted, nil, nil, nil, nil, nil
                    )
                }
                XCTAssertEqual(result.steps, 1)
                XCTAssertEqual(result.status, UInt32(AVZ_NATIVE_STATUS_MAX_STEPS))
                XCTAssertEqual(pc, target)
                XCTAssertEqual(registers[30], 0x8004)
                XCTAssertEqual(sp, 0x4000)
                XCTAssertEqual(pstate, 5)
            }
        }
    }
}
