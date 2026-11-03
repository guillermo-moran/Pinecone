import ARM64VizNative
import CryptoKit
import XCTest
@testable import ARM64VizCore

final class NativeCryptoInstructionTests: XCTestCase {
    private let initial: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]

    private func pack(_ words: [UInt32]) -> ARM64VectorRegister {
        ARM64VectorRegister(low: UInt64(words[0]) | UInt64(words[1]) << 32,
                            high: UInt64(words[2]) | UInt64(words[3]) << 32)
    }
    private func unpack(_ v: ARM64VectorRegister) -> [UInt32] {
        [UInt32(truncatingIfNeeded: v.low), UInt32(v.low >> 32),
         UInt32(truncatingIfNeeded: v.high), UInt32(v.high >> 32)]
    }
    private func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in withUnsafeBytes(of: word.littleEndian) { Array($0) } }
    }

    func testGuestSHA256MatchesSystemHashesWithBothExecutors() throws {
        let messages: [[UInt8]] = [[], Array("abc".utf8), Array(repeating: 0xa5, count: 129)]
        for assembly in [false, true] {
            let backend = SoftwareARM64Backend()
            backend.fallbackInterpreterPolicy = .nativeOnly
            backend.setNativeAssemblyExecutorEnabled(assembly)
            let machine = try MachineFactory.makeResearchMachine(backend: backend)
            let vm = machine.vm, entry = ARM64VizMachineLayout.toyEntryPoint
            // SU0 v4,v5; SU1 v4,v6,v7; H q0,q1,v3; H2 q1,q2,v3.
            try vm.loadBinary(bytes([0x5e2828a4, 0x5e0760c4, 0x5e034020, 0x5e035041]), at: entry)
            for message in messages {
                vm.reset(entryPoint: entry)
                var padded = message + [0x80]
                while padded.count % 64 != 56 { padded.append(0) }
                let bitLength = UInt64(message.count * 8)
                padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> ($0 * 8)) }
                var h = initial
                let fpsr: UInt64 = 0x0800009f
                vm.writeSystemRegister(ARM64SystemRegister.fpsr, value: fpsr)
                for block in stride(from: 0, to: padded.count, by: 64) {
                    let words: [UInt32] = stride(from: block, to: block + 64, by: 4).map { offset in
                        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(padded[offset + $1]) }
                    }
                    var ring = (0..<4).map { pack(Array(words[($0 * 4)..<($0 * 4 + 4)])) }
                    vm.cpu.v[0] = pack(Array(h[0..<4])); vm.cpu.v[1] = pack(Array(h[4..<8]))
                    for group in 0..<16 {
                        let slot = group % 4
                        if group >= 4 {
                            vm.cpu.v[4] = ring[slot]; vm.cpu.v[5] = ring[(slot + 1) % 4]
                            vm.cpu.v[6] = ring[(slot + 2) % 4]; vm.cpu.v[7] = ring[(slot + 3) % 4]
                            vm.cpu.pc = entry
                            XCTAssertEqual(try vm.run(maxSteps: 2).steps, 2)
                            ring[slot] = vm.cpu.v[4]
                        }
                        vm.cpu.v[2] = vm.cpu.v[0]
                        vm.cpu.v[3] = pack(unpack(ring[slot]).enumerated().map { $0.element &+ constants[group * 4 + $0.offset] })
                        vm.cpu.pc = entry + 8
                        XCTAssertEqual(try vm.run(maxSteps: 2).steps, 2)
                    }
                    let working = unpack(vm.cpu.v[0]) + unpack(vm.cpu.v[1])
                    h = zip(h, working).map { $0 &+ $1 }
                }
                let digest = h.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
                XCTAssertEqual(digest, Array(SHA256.hash(data: Data(message))))
                XCTAssertEqual(vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr), fpsr)
                XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
            }
        }
    }

    func testCRC32AndCRC32CAllWidthsMatchBitwiseReference() throws {
        for assembly in [false, true] {
            let backend = SoftwareARM64Backend()
            backend.fallbackInterpreterPolicy = .nativeOnly
            backend.setNativeAssemblyExecutorEnabled(assembly)
            let machine = try MachineFactory.makeResearchMachine(backend: backend)
            let vm = machine.vm, entry = ARM64VizMachineLayout.toyEntryPoint
            for castagnoli in [false, true] {
                for size: UInt32 in 0..<4 {
                    let flag = 0x10 + size + (castagnoli ? 4 : 0)
                    let word: UInt32 = 0x1ac00020 | 2 << 16 | flag << 10 | (size == 3 ? 0x80000000 : 0)
                    try vm.loadBinary(bytes([word]), at: entry)
                    for input: UInt64 in [0, .max, 0x0123456789abcdef] {
                        vm.reset(entryPoint: entry)
                        vm.cpu.x[1] = 0x12345678; vm.cpu.x[2] = input
                        var expected: UInt32 = 0x12345678
                        let polynomial: UInt32 = castagnoli ? 0x82f63b78 : 0xedb88320
                        for index in 0..<(1 << Int(size)) {
                            expected ^= UInt32(truncatingIfNeeded: input >> (index * 8)) & 255
                            for _ in 0..<8 { expected = (expected >> 1) ^ (expected & 1 != 0 ? polynomial : 0) }
                        }
                        XCTAssertEqual(try vm.run(maxSteps: 1).steps, 1)
                        XCTAssertEqual(vm.cpu.x[0], UInt64(expected))
                    }
                }
            }
        }
    }

    func testAdvertisedCryptoMatchesImplementedInstructionFamilies() {
        let registers = ARM64SystemRegisterBank()
        let features = registers.rawValue(for: ARM64SystemRegister.idAA64ISAR0EL1)
        XCTAssertEqual(features >> 12 & 15, 1) // SHA256, without SHA512.
        XCTAssertEqual(features >> 16 & 15, 1) // CRC32.
        XCTAssertEqual(features >> 4 & 255, 0) // No AES/PMULL or SHA1 claim.
    }

    func testCryptoRegisterAliasingAcrossGenericThreadedAndAssemblyFallback() throws {
        let aliases = [(0,0,0), (0,0,1), (0,1,0), (0,1,1), (31,0,1), (31,31,31)]
        let bases: [UInt32] = [0x5e004000, 0x5e005000, 0x5e282800, 0x5e006000]
        for mode in 0..<3 {
            let backend = SoftwareARM64Backend()
            backend.enableBasicBlockExecution = mode != 0
            backend.setNativeAssemblyExecutorEnabled(mode == 2)
            backend.fallbackInterpreterPolicy = .nativeOnly
            let vm = try MachineFactory.makeResearchMachine(backend: backend).vm
            let entry = ARM64VizMachineLayout.toyEntryPoint
            for operation in 0..<4 {
                for (rd, rn, rm) in aliases {
                    func opcode(_ d: Int, _ n: Int, _ m: Int) -> UInt32 {
                        bases[operation] | UInt32(d) | UInt32(n) << 5 |
                            (operation == 2 ? 0 : UInt32(m) << 16)
                    }
                    try vm.loadBinary(bytes([opcode(rd, rn, rm), opcode(28, 29, 30)]), at: entry)
                    vm.reset(entryPoint: entry)
                    for r in 0..<32 { vm.cpu.v[r] = pack([UInt32(r), .max, UInt32(r * 7919), 0x89abcdef]) }
                    let before = vm.cpu.v
                    XCTAssertEqual(try vm.run(maxSteps: 1).steps, 1)
                    let actual = vm.cpu.v[rd]
                    for r in 0..<32 where r != rd { XCTAssertEqual(vm.cpu.v[r], before[r]) }
                    vm.reset(entryPoint: entry + 4)
                    vm.cpu.v[28] = before[rd]; vm.cpu.v[29] = before[rn]; vm.cpu.v[30] = before[rm]
                    XCTAssertEqual(try vm.run(maxSteps: 1).steps, 1)
                    XCTAssertEqual(actual, vm.cpu.v[28])
                }
            }
        }
    }
}
