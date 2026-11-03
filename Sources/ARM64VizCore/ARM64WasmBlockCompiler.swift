import ARM64VizNative
import Foundation

public enum ARM64WasmError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(Int, UInt32)
    public var description: String {
        switch self {
        case .invalid(let text): return text
        case .unsupported(let index, let word):
            return String(format: "Wasm prototype rejects instruction %d: 0x%08x", index, word)
        }
    }
}

/// Runtime ARM64 -> Wasm translation. No compiled interpreter or guest-code
/// download is involved. CPU state and flat guest RAM share imported Wasm
/// memory; high addresses are checked BEFORE wrapping to Wasm32 addresses.
public struct ARM64WasmProgram: Sendable {
    public let words: [UInt32]
    public let basePC: UInt64
    public let guestRAMBytes: Int
    public let module: Data
    public var memoryPages: Int { (4096 + guestRAMBytes + 65535) / 65536 }
    public static let ramOffset = 4096
    public static let pcOffset = 256
    public static let pstateOffset = 264
    public static let retiredOffset = 272

    public init(words: [UInt32], basePC: UInt64 = 0x1000, guestRAMBytes: Int = 65536) throws {
        guard (2...16).contains(words.count), basePC & 3 == 0,
              guestRAMBytes >= 16384, guestRAMBytes <= 16 * 1024 * 1024,
              basePC <= UInt64(guestRAMBytes - words.count * 4) else {
            throw ARM64WasmError.invalid("Expected 2..16 instructions in 16 KiB..16 MiB flat guest RAM")
        }
        self.words = words; self.basePC = basePC; self.guestRAMBytes = guestRAMBytes
        var e = WasmEmitter()
        // run(i32 blockBudget) -> i32 completedBlocks; locals: counter, address.
        e.bytes += [0x02, 0x40, 0x03, 0x40] // block { loop {
        e.local(1); e.local(0); e.bytes += [0x4f, 0x0d, 0x01] // budget boundary
        for (index, word) in words.enumerated() {
            var d = AVZNativeInstruction()
            guard avz_native_decode_instruction(word, &d) != 0 else {
                throw ARM64WasmError.unsupported(index, word)
            }
            let rd = Int(word & 31), rn = Int((word >> 5) & 31)
            let bits = word >> 31 == 0 ? 32 : 64
            var branch = false
            if index == words.count - 1 {
                let imm = Int64(Int32(bitPattern: (word & 0x03ff_ffff) << 6)) >> 4
                guard word & 0xfc00_0000 == 0x1400_0000,
                      Int64(index * 4) + imm == 0 else {
                    throw ARM64WasmError.invalid("The final instruction must be B back to this block's start")
                }
                branch = true
            } else if word == 0xd503201f {
                // NOP
            } else if word & 0x1f80_0000 == 0x1100_0000 && word & (1 << 29) == 0 {
                e.destination(rd, sp: true)
                e.register(rn, sp: true)
                let immediate = UInt64((word >> 10) & 4095) << (word & (1 << 22) == 0 ? 0 : 12)
                e.constant(immediate); e.bytes.append(word & (1 << 30) == 0 ? 0x7c : 0x7d)
                e.truncate(bits); e.storeRegister(rd, sp: true)
            } else if word & 0x1f80_0000 == 0x1280_0000 {
                let opc = (word >> 29) & 3, shift = Int((word >> 21) & 3) * 16
                guard opc != 1, shift < bits else { throw ARM64WasmError.unsupported(index, word) }
                let value = UInt64((word >> 5) & 65535) << shift
                e.destination(rd)
                if opc == 3 {
                    e.register(rd); e.constant(~(UInt64(65535) << shift)); e.bytes.append(0x83)
                    e.constant(value); e.bytes.append(0x84)
                } else { e.constant(opc == 0 ? ~value : value) }
                e.truncate(bits); e.storeRegister(rd)
            } else if word & 0x1f20_fc00 == 0x0a00_0000 && (word >> 29) & 3 != 3 {
                e.destination(rd); e.register(rn); e.register(Int((word >> 16) & 31))
                e.bytes.append([UInt8(0x83), 0x84, 0x85][Int((word >> 29) & 3)])
                e.truncate(bits); e.storeRegister(rd)
            } else if word & 0x3b00_0000 == 0x3900_0000 && word & (1 << 26) == 0 &&
                        (word >> 22) & 3 <= 1 {
                let width = 1 << Int(word >> 30), load = word & (1 << 22) != 0
                e.register(rn, sp: true); e.constant(UInt64((word >> 10) & 4095) * UInt64(width))
                e.bytes += [0x7c, 0x21, 0x02] // add; local.set address
                e.local(2); e.constant(UInt64(guestRAMBytes - width)); e.bytes += [0x56, 0x04, 0x40, 0x00, 0x0b]
                if !load {
                    // This initial translator has no code-invalidation engine.
                    // Reject stores overlapping the selected immutable block.
                    e.local(2); e.constant(basePC + UInt64(words.count * 4)); e.bytes.append(0x54)
                    e.local(2); e.constant(UInt64(width)); e.bytes.append(0x7c)
                    e.constant(basePC); e.bytes += [0x56, 0x71, 0x04, 0x40, 0x00, 0x0b]
                }
                if load { e.destination(rd) }
                e.local(2); e.bytes.append(0xa7); e.i32(4096); e.bytes.append(0x6a)
                if load {
                    e.bytes.append([1: UInt8(0x31), 2: 0x33, 4: 0x35, 8: 0x29][width]!)
                    e.bytes += [0x00, 0x00]; e.storeRegister(rd)
                } else {
                    e.register(rd)
                    e.bytes.append([1: UInt8(0x3c), 2: 0x3d, 4: 0x3e, 8: 0x37][width]!)
                    e.bytes += [0x00, 0x00]
                }
            } else {
                throw ARM64WasmError.unsupported(index, word)
            }
            e.i32(Self.pcOffset); e.constant(branch ? basePC : basePC + UInt64((index + 1) * 4))
            e.bytes += [0x37, 0x03, 0x00]
            e.i32(Self.retiredOffset); e.i32(Self.retiredOffset); e.bytes += [0x29, 0x03, 0x00]
            e.constant(1); e.bytes += [0x7c, 0x37, 0x03, 0x00]
        }
        e.local(1); e.i32(1); e.bytes += [0x6a, 0x21, 0x01, 0x0c, 0x00, 0x0b, 0x0b]
        e.local(1); e.bytes.append(0x0b)
        let body = [UInt8(0x02), 0x01, 0x7f, 0x01, 0x7e] + e.bytes
        var module = Array<UInt8>([0, 97, 115, 109, 1, 0, 0, 0])
        module += WasmEmitter.section(1, [1, 0x60, 1, 0x7f, 1, 0x7f])
        let memoryImport = [UInt8(1)] + WasmEmitter.string("env") + WasmEmitter.string("memory") +
            [2, 0] + WasmEmitter.unsigned(UInt64((4096 + guestRAMBytes + 65535) / 65536))
        module += WasmEmitter.section(2, memoryImport)
        module += WasmEmitter.section(3, [1, 0])
        module += WasmEmitter.section(7, [1] + WasmEmitter.string("run") + [0, 0])
        module += WasmEmitter.section(10, [1] + WasmEmitter.unsigned(UInt64(body.count)) + body)
        self.module = Data(module)
    }

    public static func sample() throws -> Self {
        try Self(words: [0x91000400, 0xf9000020, 0xf9400022, 0xca000043, 0x17fffffc])
    }
}

private struct WasmEmitter {
    var bytes: [UInt8] = []
    static func unsigned(_ value: UInt64) -> [UInt8] {
        var v = value, result: [UInt8] = []
        repeat { let b = UInt8(v & 127); v >>= 7; result.append(b | (v == 0 ? 0 : 128)) } while v != 0
        return result
    }
    static func string(_ s: String) -> [UInt8] { unsigned(UInt64(s.utf8.count)) + Array(s.utf8) }
    static func section(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] { [id] + unsigned(UInt64(payload.count)) + payload }
    mutating func i32(_ value: Int) { bytes.append(0x41); signed(Int64(value)) }
    mutating func constant(_ value: UInt64) { bytes.append(0x42); signed(Int64(bitPattern: value)) }
    mutating func signed(_ value: Int64) {
        var v = value
        while true {
            let b = UInt8(truncatingIfNeeded: v) & 127; v >>= 7
            let done = (v == 0 && b & 64 == 0) || (v == -1 && b & 64 != 0)
            bytes.append(b | (done ? 0 : 128)); if done { break }
        }
    }
    mutating func local(_ index: UInt8) { bytes += [0x20, index] }
    mutating func register(_ index: Int, sp: Bool = false) {
        if index == 31 && !sp { constant(0) }
        else { i32(index * 8); bytes += [0x29, 0x03, 0x00] }
    }
    mutating func destination(_ index: Int, sp: Bool = false) {
        if index != 31 || sp { i32(index * 8) }
    }
    mutating func storeRegister(_ index: Int, sp: Bool = false) {
        bytes += index == 31 && !sp ? [0x1a] : [0x37, 0x03, 0x00]
    }
    mutating func truncate(_ bits: Int) { if bits == 32 { constant(0xffff_ffff); bytes.append(0x83) } }
}
