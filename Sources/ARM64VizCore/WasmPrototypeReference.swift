import Foundation
import ARM64VizNative

public struct WasmPrototypeReferenceResult: Codable, Sendable {
    public let registers: [String]
    public let pc: String
    public let pstate: String
    public let retiredInstructions: String
    public let ramSample: [UInt8]
    public let milliseconds: Double
    public let nativeInstructions: Int
    public let memoryModel: String

    public func matches(_ report: WasmPrototypeReport) -> Bool {
        report.trapped == nil && report.registers == registers && report.pc == pc &&
        report.pstate == pstate && report.retiredInstructions == retiredInstructions && report.ramSample == ramSample
    }
}

public enum WasmPrototypeReference {
    public static func sampleRegisters() -> [UInt64] {
        var r = (0..<32).map { UInt64($0) * 0x100000001 }
        r[0] = UInt64.max - 7; r[1] = 0x2000; r[31] = 0x3000
        return r
    }

    public static func codeSeed(_ program: ARM64WasmProgram) -> (offset: Int, bytes: [UInt8]) {
        (Int(program.basePC), program.words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        })
    }

    public static func execute(_ program: ARM64WasmProgram, blocks: UInt32, registers: [UInt64],
                               watchAddress: Int = 0x2000) throws -> WasmPrototypeReferenceResult {
        guard program.guestRAMBytes == 65536, registers.count == 32, blocks <= 100_000_000,
              watchAddress >= 0, watchAddress <= 65536 - 16,
              let ram = avz_guest_memory_create(65536) else {
            throw ARM64WasmError.invalid("Invalid flat native reference configuration")
        }
        defer { avz_guest_memory_destroy(ram) }
        guard let cache = avz_native_block_cache_create() else { throw ARM64WasmError.invalid("Cannot allocate reference cache") }
        defer { avz_native_block_cache_destroy(cache) }
        let bytes = avz_guest_memory_bytes(ram)!
        let translate: AVZNativeMemoryTranslateRAMCallback = { _, address, width, _, physical in
            guard width > 0, address <= 65536 - UInt64(width), let physical else { return 0 }
            physical.pointee = address; return 1
        }
        guard avz_native_block_cache_bind_physical_memory(cache, bytes, 0, 65536) != 0,
              let path = avz_native_memory_fast_path_create(bytes, 0, 65536, cache,
                UnsafeMutableRawPointer(bytes), translate, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil) else {
            throw ARM64WasmError.invalid("Cannot create flat native memory path")
        }
        defer { avz_native_memory_fast_path_destroy(path) }
        avz_native_memory_fast_path_set_instruction_translator(path, translate)
        avz_native_memory_fast_path_set_detailed_statistics_enabled(path, 0)
        guard avz_native_memory_fast_path_set_guest_memory(path, ram) != 0,
              let context = avz_native_execution_context_create() else {
            throw ARM64WasmError.invalid("Cannot create native reference context")
        }
        defer { avz_native_execution_context_destroy(context) }
        let seed = codeSeed(program)
        seed.bytes.withUnsafeBufferPointer { source in
            bytes.advanced(by:seed.offset).update(from:source.baseAddress!, count:source.count)
        }
        var values = Array(registers.prefix(31))
        values.withUnsafeBufferPointer { x in
            avz_native_execution_context_load(context, x.baseAddress, nil, nil, registers[31],
                program.basePC, 5, 0, 0, 0, 0, 0, 0)
        }
        avz_native_execution_context_set_assembly_executor(context, 0)
        avz_native_execution_context_set_threaded_prototype(context, 0)
        var key = AVZNativeBlockKey(); key.pc = program.basePC; key.current_el = 1
        let steps = UInt64(blocks) * UInt64(program.words.count)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = avz_native_execution_context_run_cached_chain(context, cache, &key, steps, steps + 1,
            avz_native_fast_fetch_instruction, UnsafeMutableRawPointer(path), avz_native_fast_memory_read, avz_native_fast_memory_write,
            nil, nil, nil, nil, nil, nil, nil, nil, UnsafeMutableRawPointer(path))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        guard result.steps == steps else {
            throw ARM64WasmError.invalid("Flat native reference stopped with status \(result.status), after \(result.steps) steps")
        }
        var sp: UInt64 = 0, pc: UInt64 = 0, pstate: UInt64 = 0
        var halted: UInt8 = 0
        values.withUnsafeMutableBufferPointer { x in
            avz_native_execution_context_store(context, x.baseAddress, nil, nil, &sp, &pc, &pstate,
                nil, nil, nil, nil, nil, &halted)
        }
        let hex: (UInt64) -> String = { String(format:"%016llx", $0) }
        return WasmPrototypeReferenceResult(registers:(values + [sp]).map(hex), pc:hex(pc), pstate:hex(pstate),
            retiredInstructions:hex(steps), ramSample:Array(UnsafeBufferPointer(start:bytes.advanced(by:watchAddress), count:16)),
            milliseconds:elapsed, nativeInstructions:Int(result.steps), memoryModel:"Flat 64 KiB RAM; native C interpreter; MMU off")
    }

    /// An additional independently wired VM/MMU fixture validates the flat C
    /// baseline. It is not the timing baseline because Wasm has no MMU yet.
    public static func executeMMU(_ program: ARM64WasmProgram, blocks: UInt32, registers: [UInt64],
                               watchAddress: Int = 0x2000) throws -> WasmPrototypeReferenceResult {
        guard program.guestRAMBytes == 65536, registers.count == 32,
              blocks <= 100_000_000, watchAddress >= 0, watchAddress <= 65536 - 16 else {
            throw ARM64WasmError.invalid("Reference fixture requires 64 KiB RAM and a bounded budget")
        }
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeAssemblyExecutorEnabled(false)
        backend.setNativeThreadedPrototypeEnabled(false)
        let base: UInt64 = 0x40000000, ram: UInt64 = base + 0x8000
        let memory = PhysicalMemory(base: base, size: 256 * 1024)
        let vm = VirtualMachine(memory: memory, backend: backend)
        try memory.write64((base + 0x2000) | 3, at: base + 0x1000)
        try memory.write64((base + 0x3000) | 3, at: base + 0x2000)
        try memory.write64((base + 0x4000) | 3, at: base + 0x3000)
        for i in 0..<16 { try memory.write64((ram + UInt64(i * 4096)) | 0x403, at: base + 0x4000 + UInt64(i * 8)) }
        try memory.writeBytes(codeSeed(program).bytes, at: ram + program.basePC)
        vm.reset(entryPoint: program.basePC)
        vm.cpu.pstate = ARM64PState.el1h
        vm.cpu.x = Array(registers.prefix(31)); vm.cpu.sp = registers[31]
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: base + 0x1000)
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.disableInstructionTrace(); vm.enableMMIOTrace(capacity: 0); vm.enableGuestMemoryTrace(capacity: 0)
        vm.systemRegisterTraceCapacity = 0; vm.systemRegisterReadTraceCapacity = 0; vm.timerCyclesPerInstruction = 0
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try vm.run(maxSteps: Int(blocks) * program.words.count)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        guard result.steps == Int(blocks) * program.words.count,
              backend.swiftFallbackSingleInstructionSteps == 0 else {
            throw ARM64WasmError.invalid("Reference did not complete through the native interpreter: \(result.stopReason)")
        }
        let hex: (UInt64) -> String = { String(format:"%016llx", $0) }
        return WasmPrototypeReferenceResult(registers:(vm.cpu.x + [vm.cpu.sp]).map(hex), pc:hex(vm.cpu.pc),
            pstate:hex(vm.cpu.pstate), retiredInstructions:hex(UInt64(result.steps)),
            ramSample:try memory.readBytes(at:ram + UInt64(watchAddress), count:16),
            milliseconds:elapsed, nativeInstructions:backend.nativeBasicBlockSteps + backend.nativeSingleInstructionSteps,
            memoryModel:"Identity-mapped 64 KiB RAM; native C interpreter; MMU on")
    }
}
