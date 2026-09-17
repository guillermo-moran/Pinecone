import ARM64VizNative
import XCTest
@testable import ARM64VizCore

private final class ReplicateReadProbe {
    let failingRead: Int
    var reads = 0

    init(failingRead: Int) { self.failingRead = failingRead }
}

private let replicateFaultRead: AVZNativeMemoryReadCallback = { context, _, _, value in
    guard let context, let value else { return 0 }
    let probe = Unmanaged<ReplicateReadProbe>.fromOpaque(context).takeUnretainedValue()
    let index = probe.reads
    probe.reads += 1
    if index == probe.failingRead { return 0 }
    value.pointee = 0x12345678
    return 1
}

final class ARM64ReplicateLoadTests: XCTestCase {
    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    func testReplicateStructuresNativeOnlyMatrix() throws {
        let backend = SoftwareARM64Backend()
        backend.enableBasicBlockExecution = true
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let base = entry + 0x2ffd // Exercise unaligned reads spanning a page.
        for count in 1...4 {
            for size in 0...3 {
                for q in 0...1 {
                    for mode in 0...2 {
                        let width = 1 << size
                        var raw: UInt32 = 0x0d40_c000 | 31 // Wrap v31 through v0.
                        raw |= UInt32(q) << 30
                        raw |= UInt32((count - 1) & 1) << 21
                        raw |= UInt32((count - 1) >> 1) << 13
                        raw |= UInt32(size) << 10
                        raw |= 31 << 5 // SP base.
                        if mode != 0 {
                            raw |= 1 << 23
                            raw |= UInt32(mode == 1 ? 31 : 2) << 16
                        }
                        try machine.vm.loadBinary(words([raw, 0xd440_0000]), at: entry)
                        machine.vm.reset(entryPoint: entry)
                        machine.vm.cpu.sp = base
                        machine.vm.cpu.x[2] = 37
                        for i in 0..<count {
                            let bytes = (0..<width).map { UInt8(0x80 + i * 8 + $0) }
                            try machine.vm.loadBinary(bytes, at: base + UInt64(i * width))
                            machine.vm.cpu.v[(31 + i) & 31] = ARM64VectorRegister(low: .max, high: .max)
                        }
                        let result = try machine.vm.run(maxSteps: 8)
                        XCTAssertEqual(result.stopReason, .halted, "encoding \(String(raw, radix: 16))")
                        for i in 0..<count {
                            var expected: UInt64 = 0
                            for byte in 0..<8 {
                                expected |= UInt64(0x80 + i * 8 + byte % width) << (byte * 8)
                            }
                            XCTAssertEqual(machine.vm.cpu.v[(31 + i) & 31].low, expected)
                            XCTAssertEqual(machine.vm.cpu.v[(31 + i) & 31].high, q == 1 ? expected : 0)
                        }
                        XCTAssertEqual(machine.vm.cpu.sp,
                                       base + UInt64(mode == 0 ? 0 : mode == 1 ? count * width : 37))
                        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
                    }
                }
            }
        }
    }

    func testExactSettingsInstructionAndReservedEncodings() throws {
        var decoded = AVZNativeInstruction()
        XCTAssertEqual(avz_native_decode_instruction(0x4d40_c806, &decoded), 1)
        XCTAssertEqual(decoded.rt, 6)
        XCTAssertEqual(decoded.rn, 0)
        XCTAssertEqual(decoded.bits, 32)
        XCTAssertEqual(decoded.rd, 1)
        for raw: UInt32 in [0x4d00_c806, 0x4d40_d806, 0x4d41_c806] {
            XCTAssertEqual(avz_native_decode_instruction(raw, &decoded), 0)
        }
    }

    func testReplicateLoadFaultDoesNotPublishPartialRegistersOrWriteback() {
        var decoded = AVZNativeInstruction()
        // ld4r {v31.4s, v0.4s, v1.4s, v2.4s}, [x0], #16
        XCTAssertEqual(avz_native_decode_instruction(0x4dff_e81f, &decoded), 1)
        for failingRead in 0..<4 {
            let probe = ReplicateReadProbe(failingRead: failingRead)
            var x = [UInt64](repeating: 0, count: 31)
            x[0] = 0x1000
            var low = [UInt64](repeating: 0x1111, count: 32)
            var high = [UInt64](repeating: 0x2222, count: 32)
            var sp: UInt64 = 0x2000
            var pc: UInt64 = 0x8000
            var pstate: UInt64 = 5
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var halted: UInt8 = 0
            let result = avz_native_run_threaded_decoded_block_full_registers(
                &decoded, 1, pc, 1, &x, &low, &high, &sp, &pc,
                &pstate, &fpcr, &fpsr, &halted,
                replicateFaultRead, nil, nil, nil,
                Unmanaged.passUnretained(probe).toOpaque())
            XCTAssertEqual(probe.reads, failingRead + 1)
            XCTAssertEqual(result.steps, 0)
            XCTAssertEqual(pc, 0x8000)
            XCTAssertEqual(x[0], 0x1000)
            XCTAssertEqual(low, [UInt64](repeating: 0x1111, count: 32))
            XCTAssertEqual(high, [UInt64](repeating: 0x2222, count: 32))
        }
    }
}
