import ARM64VizNative
import XCTest

private final class KernelSymbolScanFetch {
    var words: [UInt64: UInt32] = [:]
}

private let kernelSymbolScanFetch: AVZNativeInstructionFetchCallback = {
    context, virtualAddress, physicalAddress, instruction in
    guard let context, let physicalAddress, let instruction else { return 0 }
    let fetch = Unmanaged<KernelSymbolScanFetch>
        .fromOpaque(context)
        .takeUnretainedValue()
    guard let word = fetch.words[virtualAddress] else { return 0 }
    physicalAddress.pointee = 0x4_000 + (virtualAddress - 0x8_000)
    instruction.pointee = word
    return 1
}

private final class KernelSymbolScanCheckpoint {
    let stepLimit: UInt64
    init(stepLimit: UInt64) { self.stepLimit = stepLimit }
}

private let kernelSymbolScanCheckpoint: AVZNativeChainCheckpointCallback = {
    context, _, _, _, _, _, remainingSteps in
    guard let context else { return 0 }
    let checkpoint = Unmanaged<KernelSymbolScanCheckpoint>
        .fromOpaque(context)
        .takeUnretainedValue()
    return min(checkpoint.stepLimit, remainingSteps)
}

private let kernelSymbolScanIdentityTranslate: AVZNativeMemoryTranslateRAMCallback = {
    _, virtualAddress, _, _, physicalAddress in
    guard let physicalAddress else { return 0 }
    physicalAddress.pointee = virtualAddress
    return 1
}

private final class KernelSymbolScanSlowContext {}

private func storeKernelScan32(
    _ value: UInt32,
    in bytes: UnsafeMutableBufferPointer<UInt8>,
    at address: Int
) {
    for index in 0..<4 {
        bytes[address + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
    }
}

private func storeKernelScan64(
    _ value: UInt64,
    in bytes: UnsafeMutableBufferPointer<UInt8>,
    at address: Int
) {
    for index in 0..<8 {
        bytes[address + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
    }
}

final class NativeKernelSymbolScanTests: XCTestCase {
    private let loopPC: UInt64 = 0x8_000

    private func makeFetch() -> KernelSymbolScanFetch {
        let fetch = KernelSymbolScanFetch()
        let words: [(UInt64, UInt32)] = [
            (0x00, 0x1100_06b5), (0x04, 0x6b16_02bf),
            (0x08, 0x5400_04c0), (0x0c, 0x6b17_02bf),
            (0x10, 0xaa13_03e8), (0x14, 0x2a17_03e9),
            (0x18, 0x5400_00c2), (0x1c, 0xaa13_03e8),
            (0x20, 0xf940_4908), (0x24, 0xb940_9909),
            (0x28, 0x6b09_02bf), (0x2c, 0x54ff_ffa3),
            (0x30, 0xb940_490a), (0x34, 0x4b09_02a9),
            (0x38, 0x6b0a_013f), (0x3c, 0x5400_0082),
            (0x40, 0xf940_0508), (0x44, 0xf869_5908),
            (0x48, 0x1400_0002), (0x4c, 0xaa1f_03e8),
            (0x50, 0x3940_1d09), (0x54, 0x1200_1129),
            (0x58, 0x6b18_013f), (0x5c, 0x54ff_fd21),
            (0xa0, 0xd440_0000)
        ]
        for (offset, word) in words {
            fetch.words[loopPC + offset] = word
        }
        return fetch
    }

    private func initializeSegmentedSymbols(
        in ram: UnsafeMutableBufferPointer<UInt8>,
        matchingIndex: Int? = nil
    ) {
        let root = 0x10_000
        let older = 0x11_000
        let rootTable = 0x12_000
        let olderTable = 0x13_000
        storeKernelScan64(UInt64(rootTable), in: ram, at: root + 0x08)
        storeKernelScan32(1, in: ram, at: root + 0x48)
        storeKernelScan64(UInt64(older), in: ram, at: root + 0x90)
        storeKernelScan32(8, in: ram, at: root + 0x98)
        storeKernelScan64(UInt64(olderTable), in: ram, at: older + 0x08)
        storeKernelScan32(8, in: ram, at: older + 0x48)
        storeKernelScan64(0, in: ram, at: older + 0x90)
        storeKernelScan32(0, in: ram, at: older + 0x98)

        for index in 0...8 {
            let symbol = 0x14_000 + index * 0x20
            if index == 8 {
                storeKernelScan64(UInt64(symbol), in: ram, at: rootTable)
            } else {
                storeKernelScan64(
                    UInt64(symbol), in: ram,
                    at: olderTable + index * 8
                )
            }
            ram[symbol + 7] = index == matchingIndex ? 2 : 1
        }
    }

    func testMappedSegmentedTypeScanBatchesOnlyMismatchIterations() throws {
        let fetch = makeFetch()
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        XCTAssertNotEqual(
            avz_native_block_cache_configure_physical_range(cache, 0x4_000, 0x1_000),
            0
        )
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let slowContext = KernelSymbolScanSlowContext()
        var ram = [UInt8](repeating: 0, count: 0x20_000)
        var key = AVZNativeBlockKey(
            pc: 0, sctlr_el1: 1, tcr_el1: 0,
            ttbr0_el1: 0, ttbr1_el1: 0, current_el: 1
        )

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            initializeSegmentedSymbols(in: ramBuffer)
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress, 0, UInt64(ramBuffer.count), nil,
                Unmanaged.passUnretained(slowContext).toOpaque(),
                kernelSymbolScanIdentityTranslate,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            for run in 0..<4 {
                var registers = [UInt64](repeating: 0, count: 31)
                registers[19] = 0x10_000
                registers[21] = 0
                registers[22] = 9
                registers[23] = 8
                registers[24] = 2
                registers.withUnsafeBufferPointer {
                    avz_native_execution_context_load(
                        execution, $0.baseAddress, nil, nil,
                        0x20_000, loopPC, 0x5, 0, 0, 0, 0, 0, 0
                    )
                }
                let checkpoint = KernelSymbolScanCheckpoint(stepLimit: 512)
                let result = avz_native_execution_context_run_cached_chain_checkpointed(
                    execution, cache, &key, 512, 512, 64, 64,
                    kernelSymbolScanCheckpoint,
                    Unmanaged.passUnretained(checkpoint).toOpaque(),
                    kernelSymbolScanFetch,
                    Unmanaged.passUnretained(fetch).toOpaque(),
                    avz_native_fast_memory_read, avz_native_fast_memory_write,
                    avz_native_fast_memory_can_access, avz_native_fast_memory_fill,
                    nil, nil, nil, nil, nil, nil,
                    UnsafeMutableRawPointer(fastPath)
                )
                if run == 3 {
                    XCTAssertGreaterThan(result.superblock_dispatches, 0)
                    XCTAssertEqual(result.fast_path_hits, 1)
                    // Seven older-segment iterations cost 23 steps each;
                    // the root-segment iteration costs 18.
                    XCTAssertEqual(result.fast_path_steps, 179)
                    XCTAssertEqual(result.steps, 182)
                    XCTAssertEqual(avz_native_execution_context_pc(execution), loopPC + 0xa0)
                }
            }
        }
    }

    func testMappedSegmentedTypeScanStopsBeforeTypeMatch() throws {
        let fetch = makeFetch()
        let cache = try XCTUnwrap(avz_native_block_cache_create())
        defer { avz_native_block_cache_destroy(cache) }
        let execution = try XCTUnwrap(avz_native_execution_context_create())
        defer { avz_native_execution_context_destroy(execution) }
        let slowContext = KernelSymbolScanSlowContext()
        var ram = [UInt8](repeating: 0, count: 0x20_000)
        var key = AVZNativeBlockKey(
            pc: 0, sctlr_el1: 1, tcr_el1: 0,
            ttbr0_el1: 0, ttbr1_el1: 0, current_el: 1
        )

        try ram.withUnsafeMutableBufferPointer { ramBuffer in
            initializeSegmentedSymbols(in: ramBuffer)
            let fastPath = try XCTUnwrap(avz_native_memory_fast_path_create(
                ramBuffer.baseAddress, 0, UInt64(ramBuffer.count), nil,
                Unmanaged.passUnretained(slowContext).toOpaque(),
                kernelSymbolScanIdentityTranslate,
                nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
            ))
            defer { avz_native_memory_fast_path_destroy(fastPath) }

            func loadAndRun(maxSteps: UInt64) -> AVZNativeChainResult {
                var registers = [UInt64](repeating: 0, count: 31)
                registers[19] = 0x10_000
                registers[22] = 9
                registers[23] = 8
                registers[24] = 2
                registers.withUnsafeBufferPointer {
                    avz_native_execution_context_load(
                        execution, $0.baseAddress, nil, nil,
                        0x20_000, loopPC, 0x5, 0, 0, 0, 0, 0, 0
                    )
                }
                let checkpoint = KernelSymbolScanCheckpoint(stepLimit: maxSteps)
                return avz_native_execution_context_run_cached_chain_checkpointed(
                    execution, cache, &key, maxSteps, maxSteps, 64, 64,
                    kernelSymbolScanCheckpoint,
                    Unmanaged.passUnretained(checkpoint).toOpaque(),
                    kernelSymbolScanFetch,
                    Unmanaged.passUnretained(fetch).toOpaque(),
                    avz_native_fast_memory_read, avz_native_fast_memory_write,
                    avz_native_fast_memory_can_access, avz_native_fast_memory_fill,
                    nil, nil, nil, nil, nil, nil,
                    UnsafeMutableRawPointer(fastPath)
                )
            }

            _ = loadAndRun(maxSteps: 512)
            _ = loadAndRun(maxSteps: 512)
            initializeSegmentedSymbols(in: ramBuffer, matchingIndex: 5)
            let matched = loadAndRun(maxSteps: 512)

            var registers = [UInt64](repeating: 0, count: 31)
            var sp: UInt64 = 0
            var pc: UInt64 = 0
            var pstate: UInt64 = 0
            var fpcr: UInt64 = 0
            var fpsr: UInt64 = 0
            var exclusiveAddress: UInt64 = 0
            var exclusiveSize: UInt8 = 0
            var exclusiveValid: UInt8 = 0
            var halted: UInt8 = 0
            registers.withUnsafeMutableBufferPointer {
                avz_native_execution_context_store(
                    execution, $0.baseAddress, nil, nil,
                    &sp, &pc, &pstate, &fpcr, &fpsr,
                    &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
                )
            }

            XCTAssertGreaterThan(matched.fast_path_hits, 0)
            XCTAssertEqual(registers[21], 5, "matching iteration executes normally")
            XCTAssertEqual(registers[9], 2)
            XCTAssertNotEqual(pstate & 0x4000_0000, 0, "matching type compare sets Z")
            XCTAssertEqual(pc, loopPC + 0x60)

            initializeSegmentedSymbols(in: ramBuffer)
            // Candidate index 1 is olderTable[1]. Point it outside RAM so the
            // speculative semantic read fails before any state is committed.
            storeKernelScan64(0x30_000, in: ramBuffer, at: 0x13_000 + 8)
            let faulted = loadAndRun(maxSteps: 512)
            registers = [UInt64](repeating: 0, count: 31)
            pc = 0
            pstate = 0
            registers.withUnsafeMutableBufferPointer {
                avz_native_execution_context_store(
                    execution, $0.baseAddress, nil, nil,
                    &sp, &pc, &pstate, &fpcr, &fpsr,
                    &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted
                )
            }
            XCTAssertEqual(faulted.fast_path_hits, 0)
            XCTAssertEqual(registers[21], 1)
            XCTAssertEqual(registers[8], 0x30_000)
            XCTAssertEqual(pc, loopPC + 0x50)
        }
    }
}
