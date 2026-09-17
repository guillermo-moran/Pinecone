import ARM64VizNative
@testable import ARM64VizCore
import Dispatch
import XCTest

private final class ScopedTLBIRig {
    let memory: OpaquePointer
    let cache: OpaquePointer
    let fast: OpaquePointer
    var state = AVZNativeStage1TranslationState(
        sctlr_el1: 1, tcr_el1: 16 | (16 << 16) | (2 << 30),
        ttbr0_el1: (1 << 48) | 0x1000, ttbr1_el1: 0x1000, current_el: 1
    )

    init(sharing memory: OpaquePointer? = nil) throws {
        ownsMemory = memory == nil
        self.memory = try XCTUnwrap(memory ?? avz_guest_memory_create(0x800000))
        cache = try XCTUnwrap(avz_native_block_cache_create())
        fast = try XCTUnwrap(avz_native_memory_fast_path_create(
            avz_guest_memory_bytes(self.memory), 0, 0x800000, cache, UnsafeMutableRawPointer(self.memory),
            { _, _, _, _, _ in XCTFail("Unexpected translation callback"); return 0 },
            nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
        ))
        XCTAssertEqual(avz_native_memory_fast_path_set_guest_memory(fast, self.memory), 1)
        avz_native_memory_fast_path_set_detailed_statistics_enabled(fast, 1)
        if ownsMemory {
            store(0x2003, at: 0x1000)
            store(0x3003, at: 0x2000)
            store(0x4003, at: 0x3000)
            map(0x4000, to: 0x8000)
            map(0x5000, to: 0x9000)
            map(0x6000, to: 0xa000, global: true)
            store(11, at: 0x8000)
            store(22, at: 0x9000)
            store(33, at: 0xa000)
            store(44, at: 0xb000)
        }
        sync()
    }

    private let ownsMemory: Bool
    deinit {
        avz_native_memory_fast_path_destroy(fast)
        avz_native_block_cache_destroy(cache)
        if ownsMemory { avz_guest_memory_destroy(memory) }
    }

    func store(_ value: UInt64, at offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) {
            avz_guest_memory_bytes(memory)!.advanced(by: offset).update(
                from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 8
            )
        }
    }

    func map(_ va: UInt64, to pa: UInt64, global: Bool = false, contiguous: Bool = false) {
        store(pa | 0x403 | (global ? 0 : 0x800) | (contiguous ? 1 << 52 : 0),
              at: 0x4000 + Int((va >> 12) & 0x1ff) * 8)
    }

    func sync() { avz_native_memory_fast_path_set_stage1_translation(fast, &state, nil) }

    func read(_ va: UInt64) -> UInt64 {
        var value: UInt64 = 0
        XCTAssertEqual(avz_native_fast_memory_read(UnsafeMutableRawPointer(fast), va, 8, &value), 1)
        return value
    }

    func fetch(_ va: UInt64) -> UInt64 {
        var pa: UInt64 = 0
        var instruction: UInt32 = 0
        XCTAssertEqual(avz_native_fast_fetch_instruction(
            UnsafeMutableRawPointer(fast), va, &pa, &instruction), 1)
        return pa
    }

    var walks: UInt64 { avz_native_memory_fast_path_statistics(fast).native_page_table_walks }

    func tlbi(_ instruction: UInt32, va: UInt64 = 0, asid: UInt64 = 1) {
        let operand = (asid << 48) | ((va >> 12) & 0x0000_0fff_ffff_ffff)
        let invalidation = avz_native_decode_tlbi(instruction, operand, state.tcr_el1)
        if invalidation.broadcast != 0 { avz_guest_memory_publish_tlbi(memory, invalidation) }
        avz_native_memory_fast_path_apply_tlbi(fast, invalidation)
    }
}

final class ARM64ScopedTLBITests: XCTestCase {
    func testDecodeSupportedScopesAndConservativeFallback() {
        for crm: UInt32 in [1, 3, 7] {
            for (op2, kind): (UInt32, Int) in [
                (0, AVZ_TLBI_ALL), (1, AVZ_TLBI_VA_ASID), (2, AVZ_TLBI_ASID),
                (3, AVZ_TLBI_VA_ALL_ASIDS), (5, AVZ_TLBI_VA_ASID), (7, AVZ_TLBI_VA_ALL_ASIDS)
            ] {
                let decoded = avz_native_decode_tlbi(
                    0xd508_8000 | crm << 8 | op2 << 5,
                    0x1234_fabc_def0_1234, 1 << 36
                )
                XCTAssertEqual(decoded.kind, UInt8(kind))
                XCTAssertEqual(decoded.broadcast, crm == 7 ? 0 : 1)
                XCTAssertEqual(decoded.asid, 0x1234)
                XCTAssertEqual(decoded.virtual_address, 0x00ab_cdef_0123_4000)
            }
        }
        XCTAssertEqual(avz_native_decode_tlbi(0xd508_8720, 0xab12 << 48, 0).asid, 0x12)
        for instruction: UInt32 in [0xd50c_8720, 0xd508_8220, 0xd508_8780, 0xd508_9320] {
            let decoded = avz_native_decode_tlbi(instruction, 0, 0)
            XCTAssertEqual(decoded.kind, UInt8(AVZ_TLBI_ALL))
            XCTAssertEqual(decoded.broadcast, 1)
        }
    }

    func testVAInvalidatesReadWriteInstructionAndRetainsUnrelatedEntries() throws {
        let rig = try ScopedTLBIRig()
        XCTAssertEqual(rig.read(0x4000), 11)
        XCTAssertEqual(rig.read(0x5000), 22)
        XCTAssertEqual(rig.fetch(0x4000), 0x8000)
        XCTAssertEqual(rig.fetch(0x5000), 0x9000)
        XCTAssertEqual(avz_native_fast_memory_write(
            UnsafeMutableRawPointer(rig.fast), 0x4000, 8, 11), 1)
        rig.map(0x4000, to: 0xb000)
        rig.map(0x5000, to: 0xb000)
        rig.tlbi(0xd508_8720, va: 0x4000)
        let walks = rig.walks
        XCTAssertEqual(rig.read(0x5000), 22)
        XCTAssertEqual(rig.fetch(0x5000), 0x9000)
        XCTAssertEqual(rig.walks, walks)
        XCTAssertEqual(rig.read(0x4000), 44)
        XCTAssertEqual(rig.fetch(0x4000), 0xb000)
        XCTAssertEqual(avz_native_fast_memory_write(
            UnsafeMutableRawPointer(rig.fast), 0x4000, 8, 55), 1)
        XCTAssertEqual(rig.read(0x4000), 55)
        XCTAssertEqual(rig.walks, walks + 3)
    }

    func testASIDRetainsGlobalsAndOtherASIDsAndVAInvalidatesGlobals() throws {
        let rig = try ScopedTLBIRig()
        XCTAssertEqual(rig.read(0x4000), 11)
        XCTAssertEqual(rig.read(0x6000), 33)
        rig.state.ttbr0_el1 = (2 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.map(0x4000, to: 0xb000)
        rig.map(0x6000, to: 0xb000, global: true)
        rig.tlbi(0xd508_8740, asid: 1)
        let walks = rig.walks
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.state.ttbr0_el1 = (1 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x6000), 33)
        XCTAssertEqual(rig.walks, walks)
        XCTAssertEqual(rig.read(0x4000), 44)
        rig.tlbi(0xd508_87a0, va: 0x6000, asid: 99) // VALE1, global ignores ASID.
        XCTAssertEqual(rig.read(0x6000), 44)
        rig.state.ttbr0_el1 = (2 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.tlbi(0xd508_8760, va: 0x4000, asid: 99)
        XCTAssertEqual(rig.read(0x4000), 44)
    }

    func testA1AndSixteenBitASIDArePartOfContext() throws {
        let rig = try ScopedTLBIRig()
        rig.state.tcr_el1 |= (1 << 22) | (1 << 36)
        rig.state.ttbr1_el1 = (0x101 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.map(0x4000, to: 0xb000)
        rig.state.ttbr1_el1 = (0x201 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x4000), 44)
        rig.state.ttbr1_el1 = (0x101 << 48) | 0x1000
        rig.sync()
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.tlbi(0xd508_8740, asid: 1)
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.tlbi(0xd508_8740, asid: 0x101)
        XCTAssertEqual(rig.read(0x4000), 44)
    }

    func testVAFormMatrixAcrossScopesGlobalsASIDsAndAddressHalves() throws {
        for crm: UInt32 in [1, 3, 7] {
            for op2: UInt32 in [1, 3, 5, 7] {
                for global in [false, true] {
                    for matchesASID in [false, true] {
                        for upper in [false, true] {
                            let rig = try ScopedTLBIRig()
                            let peer = try ScopedTLBIRig(sharing: rig.memory)
                            let va: UInt64 = upper ? 0xffff_0000_0000_4000 : 0x4000
                            rig.map(va, to: 0x8000, global: global)
                            for cpu in [rig, peer] {
                                XCTAssertEqual(cpu.read(va), 11)
                                XCTAssertEqual(cpu.fetch(va), 0x8000)
                                XCTAssertEqual(cpu.read(va + 0x1000), 22)
                                XCTAssertEqual(avz_native_fast_memory_write(
                                    UnsafeMutableRawPointer(cpu.fast), va, 8, 11), 1)
                            }
                            rig.map(va, to: 0xb000, global: global)
                            rig.tlbi(0xd508_8000 | crm << 8 | op2 << 5,
                                     va: va, asid: matchesASID ? 1 : 2)
                            let matches = global || matchesASID || op2 == 3 || op2 == 7
                            for (cpu, affected) in [(rig, matches), (peer, crm != 7 && matches)] {
                                let walks = cpu.walks
                                XCTAssertEqual(cpu.read(va + 0x1000), 22)
                                XCTAssertEqual(cpu.walks, walks)
                                XCTAssertEqual(cpu.read(va), affected ? 44 : 11)
                                XCTAssertEqual(cpu.fetch(va), affected ? 0xb000 : 0x8000)
                                XCTAssertEqual(cpu.walks, walks + (affected ? 2 : 0))
                            }
                        }
                    }
                }
            }
        }
    }

    func testASIDFormMatrixAcrossScopesWidthSelectionAndGlobals() throws {
        for crm: UInt32 in [1, 3, 7] {
            for wide in [false, true] {
                for a1 in [false, true] {
                    for global in [false, true] {
                        for matches in [false, true] {
                            let rig = try ScopedTLBIRig()
                            let peer = try ScopedTLBIRig(sharing: rig.memory)
                            rig.map(0x4000, to: 0x8000, global: global)
                            for cpu in [rig, peer] {
                                cpu.state.tcr_el1 |= (wide ? 1 << 36 : 0) | (a1 ? 1 << 22 : 0)
                                cpu.state.ttbr0_el1 = ((a1 ? 0x302 : 0x101) << 48) | 0x1000
                                cpu.state.ttbr1_el1 = ((a1 ? 0x101 : 0x302) << 48) | 0x1000
                                cpu.sync()
                                XCTAssertEqual(cpu.read(0x4000), 11)
                                XCTAssertEqual(cpu.fetch(0x4000), 0x8000)
                            }
                            rig.map(0x4000, to: 0xb000, global: global)
                            rig.tlbi(0xd508_8040 | crm << 8, asid: matches ? 0x101 : 0x302)
                            let affected = matches && !global
                            for (cpu, refresh) in [(rig, affected), (peer, affected && crm != 7)] {
                                let walks = cpu.walks
                                XCTAssertEqual(cpu.read(0x4000), refresh ? 44 : 11)
                                XCTAssertEqual(cpu.fetch(0x4000), refresh ? 0xb000 : 0x8000)
                                XCTAssertEqual(cpu.walks, walks + (refresh ? 2 : 0))
                            }
                        }
                    }
                }
            }
        }
    }

    func testJournalCapacityBoundaryRetainsUnrelatedMappings() throws {
        let rig = try ScopedTLBIRig()
        XCTAssertEqual(rig.read(0x4000), 11)
        XCTAssertEqual(rig.read(0x5000), 22)
        rig.map(0x4000, to: 0xb000)
        rig.map(0x5000, to: 0xb000)
        for _ in 0..<64 {
            avz_guest_memory_publish_tlbi(rig.memory, avz_native_decode_tlbi(
                0xd508_8320, (1 << 48) | 4, rig.state.tcr_el1))
        }
        let walks = rig.walks
        XCTAssertEqual(rig.read(0x5000), 22)
        XCTAssertEqual(rig.walks, walks)
        XCTAssertEqual(rig.read(0x4000), 44)
    }

    func testOrderedSMPRemapsAreObservedWithoutFlushingUnrelatedData() throws {
        let writer = try ScopedTLBIRig()
        let reader = try ScopedTLBIRig(sharing: writer.memory)
        let ready = DispatchSemaphore(value: 0)
        let acknowledged = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        XCTAssertEqual(reader.read(0x5000), 22)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for index in 0..<256 {
                guard ready.wait(timeout: .now() + 10) == .success else {
                    XCTFail("Publisher timed out"); return
                }
                let walks = reader.walks
                XCTAssertEqual(reader.read(0x5000), 22)
                XCTAssertEqual(reader.walks, walks)
                XCTAssertEqual(reader.read(0x4000), index % 2 == 0 ? 44 : 11)
                XCTAssertEqual(reader.fetch(0x4000), index % 2 == 0 ? 0xb000 : 0x8000)
                acknowledged.signal()
            }
        }
        for index in 0..<256 {
            writer.map(0x4000, to: index % 2 == 0 ? 0xb000 : 0x8000)
            writer.tlbi(0xd508_8320, va: 0x4000)
            ready.signal()
            XCTAssertEqual(acknowledged.wait(timeout: .now() + 10), .success)
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }

    func testUpperVAAndContiguousExtent() throws {
        let rig = try ScopedTLBIRig()
        rig.map(0x4000, to: 0x8000, contiguous: true)
        rig.map(0x5000, to: 0x9000, contiguous: true)
        let va: UInt64 = 0xffff_0000_0000_4000
        XCTAssertEqual(rig.read(va), 11)
        XCTAssertEqual(rig.read(va + 0x1000), 22)
        rig.map(0x4000, to: 0xb000)
        rig.map(0x5000, to: 0xb000)
        rig.tlbi(0xd508_87e0, va: va) // VAALE1.
        XCTAssertEqual(rig.read(va), 44)
        XCTAssertEqual(rig.read(va + 0x1000), 44)
    }

    func testBlockExtentInvalidatesAllCachedSubpages() throws {
        let rig = try ScopedTLBIRig()
        rig.store(0x200000 | 0xc01, at: 0x3000)
        rig.store(11, at: 0x204000)
        rig.store(22, at: 0x205000)
        rig.store(33, at: 0x404000)
        rig.store(44, at: 0x405000)
        XCTAssertEqual(rig.read(0x4000), 11)
        XCTAssertEqual(rig.read(0x5000), 22)
        rig.store(0x400000 | 0xc01, at: 0x3000)
        rig.tlbi(0xd508_8720, va: 0x4000)
        XCTAssertEqual(rig.read(0x4000), 33)
        XCTAssertEqual(rig.read(0x5000), 44)
    }

    func testSharedShootdownRetainsUnrelatedMappingsAndLocalDoesNotBroadcast() throws {
        let first = try ScopedTLBIRig()
        let peer = try ScopedTLBIRig(sharing: first.memory)
        XCTAssertEqual(first.read(0x4000), 11)
        XCTAssertEqual(peer.read(0x4000), 11)
        XCTAssertEqual(peer.read(0x5000), 22)
        XCTAssertEqual(peer.fetch(0x4000), 0x8000)
        first.map(0x4000, to: 0xb000)
        let epoch = avz_guest_memory_translation_epoch(first.memory)
        first.tlbi(0xd508_8720, va: 0x4000)
        XCTAssertEqual(avz_guest_memory_translation_epoch(first.memory), epoch)
        XCTAssertEqual(first.read(0x4000), 44)
        XCTAssertEqual(peer.read(0x4000), 11)
        first.tlbi(0xd508_8320, va: 0x4000)
        let walks = peer.walks
        XCTAssertEqual(peer.read(0x5000), 22)
        XCTAssertEqual(peer.walks, walks)
        XCTAssertEqual(peer.read(0x4000), 44)
        XCTAssertEqual(peer.fetch(0x4000), 0xb000)
        first.map(0x4000, to: 0x8000)
        first.tlbi(0xd508_8120, va: 0x4000) // Outer Shareable, same modeled domain.
        XCTAssertEqual(peer.read(0x4000), 11)
    }

    func testJournalOverflowAndUnsupportedFormsFlushConservatively() throws {
        let rig = try ScopedTLBIRig()
        XCTAssertEqual(rig.read(0x4000), 11)
        rig.map(0x4000, to: 0xb000)
        for _ in 0..<65 {
            avz_guest_memory_publish_tlbi(rig.memory, avz_native_decode_tlbi(
                0xd508_8320, (1 << 48) | 5, rig.state.tcr_el1))
        }
        XCTAssertEqual(rig.read(0x4000), 44)
        rig.map(0x4000, to: 0x8000)
        rig.tlbi(0xd508_8220) // Range form is deliberately unsupported.
        XCTAssertEqual(rig.read(0x4000), 11)
    }

    func testConcurrentPublishersDoNotLoseInvalidations() throws {
        let rig = try ScopedTLBIRig()
        XCTAssertEqual(rig.read(0x4000), 11)
        XCTAssertEqual(rig.read(0x5000), 22)
        rig.map(0x4000, to: 0xb000)
        rig.map(0x5000, to: 0xb000)
        let epoch = avz_guest_memory_translation_epoch(rig.memory)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            avz_guest_memory_publish_tlbi(rig.memory, avz_native_decode_tlbi(
                0xd508_8320, (1 << 48) | UInt64(4 + index % 2), rig.state.tcr_el1))
        }
        XCTAssertEqual(avz_guest_memory_translation_epoch(rig.memory), epoch + 32)
        XCTAssertEqual(rig.read(0x4000), 44)
        XCTAssertEqual(rig.read(0x5000), 44)
    }

    func testDecodedMappingsRefreshEvenAfterInstructionTLBEviction() throws {
        for shared in [false, true] {
            let rig = try ScopedTLBIRig()
            rig.store(0x1400_0000, at: 0x8000) // b .
            rig.store(0x1400_0001, at: 0xb000) // b .+4
            var key = AVZNativeBlockKey(
                pc: 0x4000, sctlr_el1: rig.state.sctlr_el1,
                tcr_el1: rig.state.tcr_el1, ttbr0_el1: rig.state.ttbr0_el1,
                ttbr1_el1: rig.state.ttbr1_el1, current_el: 1
            )
            func decodedInstruction() throws -> UInt32 {
                var status: UInt32 = 0
                var unsupported: UInt32 = 0
                let block = try XCTUnwrap(avz_native_block_cache_get_or_decode(
                    rig.cache, &key, avz_native_fast_fetch_instruction,
                    UnsafeMutableRawPointer(rig.fast), &status, &unsupported
                ))
                XCTAssertEqual(status, UInt32(AVZ_NATIVE_BLOCK_DECODE_OK))
                return try XCTUnwrap(avz_native_decoded_block_instructions(block)).pointee.raw
            }
            XCTAssertEqual(try decodedInstruction(), 0x1400_0000)
            // Keep decoded code alive, but erase its TLB tracking.
            avz_native_memory_fast_path_set_instruction_translator(rig.fast, nil)
            rig.map(0x4000, to: 0xb000)
            if shared {
                avz_guest_memory_publish_tlbi(rig.memory, avz_native_decode_tlbi(
                    0xd508_8320, (1 << 48) | 4, rig.state.tcr_el1))
                // Native chains must observe this without any data/fetch callback.
                _ = avz_native_memory_fast_path_advance_time(rig.fast, 1, 0x3c5)
            } else {
                rig.tlbi(0xd508_8720, va: 0x4000)
            }
            XCTAssertEqual(try decodedInstruction(), 0x1400_0001)
        }
    }

    func testTLBIRetainsDecodedContentsAndPhysicalCodeGenerations() throws {
        let rig = try ScopedTLBIRig()
        rig.store(0x1400_0000, at: 0x8000)
        var key = AVZNativeBlockKey(
            pc: 0x4000, sctlr_el1: rig.state.sctlr_el1,
            tcr_el1: rig.state.tcr_el1, ttbr0_el1: rig.state.ttbr0_el1,
            ttbr1_el1: rig.state.ttbr1_el1, current_el: 1
        )
        func block() throws -> OpaquePointer {
            try XCTUnwrap(avz_native_block_cache_get_or_decode(
                rig.cache, &key, avz_native_fast_fetch_instruction,
                UnsafeMutableRawPointer(rig.fast), nil, nil))
        }
        let initial = try block()
        let serial = avz_native_decoded_block_serial(rig.cache, initial)
        let before = avz_native_block_cache_statistics(rig.cache)
        for _ in 0..<256 {
            rig.tlbi(0xd508_8720, va: 0x5000)
            XCTAssertEqual(avz_native_decoded_block_serial(rig.cache, try block()), serial)
        }
        let after = avz_native_block_cache_statistics(rig.cache)
        XCTAssertEqual(after.decodes, before.decodes)
        XCTAssertEqual(after.code_page_generation_bumps, before.code_page_generation_bumps)
        XCTAssertEqual(after.invalidation_checks, before.invalidation_checks)
        // Even a targeted invalidation retains decoded bytes when the PA and
        // execute permission remain unchanged after retranslation.
        rig.tlbi(0xd508_8720, va: 0x4000)
        XCTAssertEqual(avz_native_decoded_block_serial(rig.cache, try block()), serial)
        // Same PA with newly revoked execute permission must not reuse code.
        rig.store(0x8000 | 0xc03 | (1 << 53), at: 0x4020)
        rig.tlbi(0xd508_8720, va: 0x4000)
        XCTAssertNil(avz_native_block_cache_get_or_decode(
            rig.cache, &key, avz_native_fast_fetch_instruction,
            UnsafeMutableRawPointer(rig.fast), nil, nil))
    }

    func testWarmedNativeTraceAndDecodedBlocksObserveLocalAndSharedVARemap() throws {
        for shared in [false, true] {
            let rig = try ScopedTLBIRig()
            rig.store(0x1400_03ff_9100_0400, at: 0x8000) // add x0,#1; b 0x5000
            rig.store(0x17ff_fbff_9100_0421, at: 0x9000) // add x1,#1; b 0x4000
            rig.store(0x17ff_fbff_9100_0821, at: 0xb000) // add x1,#2; b 0x4000
            let execution = try XCTUnwrap(avz_native_execution_context_create())
            defer { avz_native_execution_context_destroy(execution) }
            var key = AVZNativeBlockKey(
                pc: 0, sctlr_el1: rig.state.sctlr_el1,
                tcr_el1: rig.state.tcr_el1, ttbr0_el1: rig.state.ttbr0_el1,
                ttbr1_el1: rig.state.ttbr1_el1, current_el: 1
            )
            func run(_ steps: UInt64) -> (AVZNativeChainResult, [UInt64]) {
                var registers = [UInt64](repeating: 0, count: 31)
                registers.withUnsafeBufferPointer {
                    avz_native_execution_context_load(
                        execution, $0.baseAddress, nil, nil,
                        0x7000, 0x4000, 0x5, 0, 0, 0, 0, 0, 0)
                }
                let result = avz_native_execution_context_run_cached_chain_checkpointed_fast_memory(
                    execution, rig.cache, &key, steps, steps, steps, steps,
                    { _, _, _, _, _, _, _ in 64 }, nil,
                    avz_native_fast_fetch_instruction, UnsafeMutableRawPointer(rig.fast),
                    avz_native_fast_memory_read, avz_native_fast_memory_write,
                    avz_native_fast_memory_can_access, avz_native_fast_memory_fill,
                    nil, nil, nil, nil, nil, nil, UnsafeMutableRawPointer(rig.fast))
                var sp: UInt64 = 0, pc: UInt64 = 0, pstate: UInt64 = 0
                var fpcr: UInt64 = 0, fpsr: UInt64 = 0, exclusiveAddress: UInt64 = 0
                var exclusiveSize: UInt8 = 0, exclusiveValid: UInt8 = 0, halted: UInt8 = 0
                registers.withUnsafeMutableBufferPointer {
                    avz_native_execution_context_store(
                        execution, $0.baseAddress, nil, nil,
                        &sp, &pc, &pstate, &fpcr, &fpsr,
                        &exclusiveAddress, &exclusiveSize, &exclusiveValid, &halted)
                }
                return (result, registers)
            }
            _ = run(64)
            let trained = run(64)
            XCTAssertGreaterThan(trained.0.superblock_dispatches, 0)
            XCTAssertEqual(trained.1[0], 16)
            XCTAssertEqual(trained.1[1], 16)
            let generations = avz_native_block_cache_statistics(rig.cache).code_page_generation_bumps
            rig.map(0x5000, to: 0xb000)
            if shared {
                avz_guest_memory_publish_tlbi(rig.memory, avz_native_decode_tlbi(
                    0xd508_8320, (1 << 48) | 5, rig.state.tcr_el1))
                // The native block-boundary synchronization is the same hook
                // used before following cached successors on an active peer.
                _ = avz_native_memory_fast_path_advance_time(rig.fast, 0, 0x5)
            } else {
                rig.tlbi(0xd508_8720, va: 0x5000)
            }
            let remapped = run(8)
            XCTAssertEqual(remapped.1[0], 2)
            XCTAssertEqual(remapped.1[1], 4)
            XCTAssertEqual(avz_native_block_cache_statistics(rig.cache).code_page_generation_bumps, generations)
        }
    }

    func testScopedTLBIWorkingSetBenchmark() throws {
        let rig = try ScopedTLBIRig()
        for page: UInt64 in 16..<48 { rig.map(page << 12, to: 0x9000) }
        let scoped = avz_native_decode_tlbi(0xd508_8720, (1 << 48) | 4, rig.state.tcr_el1)
        let full = avz_native_decode_tlbi(0xd508_871f, 0, rig.state.tcr_el1)
        var times: [UInt64] = []
        for invalidation in [full, scoped] {
            var best = UInt64.max
            for _ in 0..<3 {
                for page: UInt64 in 16..<48 { _ = rig.read(page << 12) }
                var sum: UInt64 = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<4_096 {
                    avz_native_memory_fast_path_apply_tlbi(rig.fast, invalidation)
                    for page: UInt64 in 16..<48 {
                        var value: UInt64 = 0
                        _ = avz_native_fast_memory_read(UnsafeMutableRawPointer(rig.fast), page << 12, 8, &value)
                        sum &+= value
                    }
                }
                best = min(best, DispatchTime.now().uptimeNanoseconds - start)
                XCTAssertEqual(sum, 4_096 * 32 * 22)
            }
            times.append(best)
        }
        print("TLBI 4096 operations/32-page working set: full=\(times[0])ns scoped=\(times[1])ns")
    }

    func testNativeCallbackForwardsOperandWithoutSwiftFallback() throws {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let vm = machine.vm
        let base = ARM64VizMachineLayout.ramBase
        let code = ARM64VizMachineLayout.toyEntryPoint
        let dataA = code + 0x1000
        let dataB = code + 0x2000
        for index in 1...3 {
            try vm.memory.write64(base + UInt64(index + 1) * 0x1000 | 3,
                                  at: base + UInt64(index) * 0x1000)
        }
        try vm.memory.write64(code | 0x403, at: base + 0x4008)
        try vm.memory.write64(dataA | 0xc03, at: base + 0x4010)
        try vm.memory.write64(base + 0x4000 | 0x403, at: base + 0x4018)
        let words: [UInt32] = [
            0xf940_0020, // ldr x0, [x1]
            0xf900_0043, // str x3, [x2]
            0xd508_8325, // tlbi vae1is, x5 (not VA zero)
            0xf940_0024, // ldr x4, [x1]
            0xd440_0000
        ]
        try vm.loadBinary(words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }, at: code)
        try vm.memory.write64(11, at: dataA)
        try vm.memory.write64(44, at: dataB)
        vm.reset(entryPoint: 0x1000)
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: base + 0x1000 | (1 << 48))
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.timerCyclesPerInstruction = 0
        vm.cpu.x[1] = 0x2000
        vm.cpu.x[2] = 0x3010
        vm.cpu.x[3] = dataB | 0xc03
        vm.cpu.x[5] = (1 << 48) | 2
        XCTAssertEqual(try vm.run(maxSteps: 16).stopReason, .halted)
        XCTAssertEqual(vm.cpu.x[0], 11)
        XCTAssertEqual(vm.cpu.x[4], 44)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(backend.decodedBasicBlockSteps, 0)
    }
}
