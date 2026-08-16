import ARM64VizNative
import Foundation

public enum ARM64FallbackInterpreterPolicy {
    case nativeOnly
    case diagnosticsOnly
    case alwaysAllow
}

public final class SoftwareARM64Backend: VirtualMachineBackend {
    public let name = "software-aarch64-subset"
    public var collectPerformanceTimings = false
    public var collectCacheStatistics = false
    public var enableBasicBlockExecution = true
    public var fallbackInterpreterPolicy: ARM64FallbackInterpreterPolicy = .diagnosticsOnly
    public private(set) var decodedInstructionCacheHits = 0
    public private(set) var decodedInstructionCacheMisses = 0
    public private(set) var decodedBasicBlockCacheHits = 0
    public private(set) var decodedBasicBlockCacheMisses = 0
    public private(set) var decodedBasicBlockExecutions = 0
    public private(set) var decodedBasicBlockSteps = 0
    public private(set) var decodedBasicBlockNanoseconds: UInt64 = 0
    public private(set) var decodedBasicBlockTerminatorExecutions = 0
    public private(set) var decodedBasicBlockPCMismatchExits = 0
    public private(set) var singleInstructionSteps = 0
    public private(set) var singleInstructionNanoseconds: UInt64 = 0
    public private(set) var nativeSingleInstructionSteps = 0
    public private(set) var swiftFallbackSingleInstructionSteps = 0
    public private(set) var nativePinnedDeviceSingleInstructionSteps = 0
    public private(set) var fastRAMReadHits = 0
    public private(set) var fastRAMReadMisses = 0
    public private(set) var fastRAMWriteHits = 0
    public private(set) var fastRAMWriteMisses = 0
    public private(set) var nativeBasicBlockExecutions = 0
    public private(set) var nativeBasicBlockSteps = 0
    public private(set) var nativeBasicBlockNanoseconds: UInt64 = 0
    public private(set) var nativeBasicBlockUnsupportedExits = 0
    public private(set) var nativeDirectLinkHits = 0
    public private(set) var nativeDirectLinkMisses = 0
    public private(set) var nativeSuperblockHits = 0
    public private(set) var nativeSuperblockFrontHits = 0
    public private(set) var nativeSuperblockBlocks = 0
    public private(set) var nativeSuperblockDispatches = 0
    public private(set) var nativeGenericDispatches = 0
    public private(set) var nativeSemanticFastPathSteps = 0
    public private(set) var nativeSemanticFastPathHits = 0
    public private(set) var nativeReadTLBHits = 0
    public private(set) var nativeReadTLBMisses = 0
    public private(set) var nativeWriteTLBHits = 0
    public private(set) var nativeWriteTLBMisses = 0
    public private(set) var nativeInstructionFetchHits = 0
    public private(set) var nativeInstructionTLBHits = 0
    public private(set) var nativeInstructionTLBMisses = 0
    public private(set) var nativePageTableWalks = 0
    public private(set) var nativePageTableFaults = 0
    public private(set) var nativeTranslationCallbackWalks = 0
    public private(set) var nativePhysicalDeviceReads = 0
    public private(set) var nativePhysicalDeviceWrites = 0
    public private(set) var nativeFillHits = 0
    public private(set) var nativeFillMisses = 0
    public private(set) var nativeFastRAMReadHits = 0
    public private(set) var nativeFastRAMReadMisses = 0
    public private(set) var nativeFastRAMWriteHits = 0
    public private(set) var nativeFastRAMWriteMisses = 0
    public private(set) var nativeMemorySessionCreations = 0
    public private(set) var nativeIneligibleGadgetCounts: [String: Int] = [:]
    public private(set) var decodedFallbackGadgetCounts: [String: Int] = [:]
    public private(set) var unsupportedInstructionCounts: [UInt32: Int] = [:]

    private let decodedInstructionCache = DecodedInstructionCache()
    private let nativeInstructionCache = NativeInstructionCache()
    private let decodedBasicBlockCache = DecodedBasicBlockCache()
    private let decodedBasicBlockFrontCache = DecodedBasicBlockFrontCache()
    private let nativeBlockCache: OpaquePointer?
    private let nativeExecutionContext: OpaquePointer?
    private var nativeMemorySession: NativeMemorySession?
    private var decodedBasicBlockKeysByCodePage: [GuestAddress: Set<BasicBlockCacheKey>] = [:]
    private var codeCacheGeneration: UInt64 = 0
    private let maxBasicBlockInstructions = 32
    private let nativeChainBlockLimit: UInt64 = 1_024
    private let decodeScratch = DecodeScratch(capacity: 32)
    public init() {
        nativeBlockCache = avz_native_block_cache_create()
        nativeExecutionContext = avz_native_execution_context_create()
    }

    deinit {
        nativeMemorySession = nil
        avz_native_execution_context_destroy(nativeExecutionContext)
        avz_native_block_cache_destroy(nativeBlockCache)
    }

    public func invalidateTranslationCache(for vm: VirtualMachine) {
        guard let session = nativeMemorySession, session.vm === vm else {
            return
        }
        session.memoryContext.invalidateTranslatedPages()
    }

    public func performanceSnapshot(
        unsupportedLimit: Int = 16,
        fallbackLimit: Int = 16,
        ineligibleLimit: Int = 16
    ) -> ARM64BackendPerformanceSnapshot {
        let unsupported = unsupportedInstructionCounts
            .map { ARM64BackendInstructionCount(instruction: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.instruction < $1.instruction
                }
                return $0.count > $1.count
            }
            .prefix(max(0, unsupportedLimit))
        let fallbackGadgets = decodedFallbackGadgetCounts
            .map { ARM64BackendNamedCount(name: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.name < $1.name
                }
                return $0.count > $1.count
            }
            .prefix(max(0, fallbackLimit))
        let ineligibleGadgets = nativeIneligibleGadgetCounts
            .map { ARM64BackendNamedCount(name: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.name < $1.name
                }
                return $0.count > $1.count
            }
            .prefix(max(0, ineligibleLimit))
        let blockCacheStatistics = avz_native_block_cache_statistics(nativeBlockCache)
        return ARM64BackendPerformanceSnapshot(
            decodedBasicBlockExecutions: decodedBasicBlockExecutions,
            decodedBasicBlockSteps: decodedBasicBlockSteps,
            decodedBasicBlockNanoseconds: decodedBasicBlockNanoseconds,
            singleInstructionSteps: singleInstructionSteps,
            singleInstructionNanoseconds: singleInstructionNanoseconds,
            nativeSingleInstructionSteps: nativeSingleInstructionSteps,
            swiftFallbackSingleInstructionSteps: swiftFallbackSingleInstructionSteps,
            nativeBasicBlockExecutions: nativeBasicBlockExecutions,
            nativeBasicBlockSteps: nativeBasicBlockSteps,
            nativeBasicBlockNanoseconds: nativeBasicBlockNanoseconds,
            nativeBasicBlockUnsupportedExits: nativeBasicBlockUnsupportedExits,
            nativeDirectLinkHits: nativeDirectLinkHits,
            nativeDirectLinkMisses: nativeDirectLinkMisses,
            nativeSuperblockHits: nativeSuperblockHits,
            nativeSuperblockFrontHits: nativeSuperblockFrontHits,
            nativeSuperblockBlocks: nativeSuperblockBlocks,
            nativeSuperblockDispatches: nativeSuperblockDispatches,
            nativeGenericDispatches: nativeGenericDispatches,
            nativeReadTLBHits: nativeReadTLBHits,
            nativeReadTLBMisses: nativeReadTLBMisses,
            nativeWriteTLBHits: nativeWriteTLBHits,
            nativeWriteTLBMisses: nativeWriteTLBMisses,
            nativeInstructionFetchHits: nativeInstructionFetchHits,
            nativeInstructionTLBHits: nativeInstructionTLBHits,
            nativeInstructionTLBMisses: nativeInstructionTLBMisses,
            nativePageTableWalks: nativePageTableWalks,
            nativePageTableFaults: nativePageTableFaults,
            nativeTranslationCallbackWalks: nativeTranslationCallbackWalks,
            nativePhysicalDeviceReads: nativePhysicalDeviceReads,
            nativePhysicalDeviceWrites: nativePhysicalDeviceWrites,
            nativeFillHits: nativeFillHits,
            nativeFillMisses: nativeFillMisses,
            nativeFastRAMReadHits: nativeFastRAMReadHits,
            nativeFastRAMReadMisses: nativeFastRAMReadMisses,
            nativeFastRAMWriteHits: nativeFastRAMWriteHits,
            nativeFastRAMWriteMisses: nativeFastRAMWriteMisses,
            nativeBlockCacheHits: blockCacheStatistics.hits,
            nativeBlockCacheMisses: blockCacheStatistics.misses,
            nativeBlockCacheDecodes: blockCacheStatistics.decodes,
            nativeBlockCacheFrontHits: blockCacheStatistics.front_hits,
            nativeDirectCodeFetches: blockCacheStatistics.direct_code_fetches,
            nativeDecodeWindowHits: blockCacheStatistics.decode_window_hits,
            nativeDecodeWindowMisses: blockCacheStatistics.decode_window_misses,
            nativeBatchPrefetchedBlocks: blockCacheStatistics.batch_prefetched_blocks,
            nativeBatchPrefetchHits: blockCacheStatistics.batch_prefetch_hits,
            nativeBatchPrefetchUnused: blockCacheStatistics.batch_prefetch_unused,
            nativeBatchPrefetchLimitChanges: blockCacheStatistics.batch_prefetch_limit_changes,
            nativeBatchPrefetchLimit: blockCacheStatistics.batch_prefetch_limit,
            nativeIneligibleGadgets: Array(ineligibleGadgets),
            decodedFallbackGadgets: Array(fallbackGadgets),
            unsupportedInstructions: Array(unsupported)
        )
    }

    public func nativeHotPCSnapshot(
        limit: Int = 8
    ) -> [(pc: GuestAddress, samples: UInt64, instructions: [UInt32])] {
        guard let nativeExecutionContext, limit > 0 else {
            return []
        }
        var entries = Array(
            repeating: AVZNativeHotPC(),
            count: limit
        )
        let count = entries.withUnsafeMutableBufferPointer { buffer in
            avz_native_execution_context_copy_hot_pcs(
                nativeExecutionContext,
                buffer.baseAddress,
                buffer.count
            )
        }
        return entries.prefix(count).map { entry in
            let available = min(Int(entry.instruction_count), 4)
            let words = [
                entry.instruction0,
                entry.instruction1,
                entry.instruction2,
                entry.instruction3
            ]
            return (
                pc: GuestAddress(entry.pc),
                samples: entry.samples,
                instructions: Array(words.prefix(available))
            )
        }
    }

    public func resetNativeHotPCProfile() {
        avz_native_execution_context_reset_hot_pc_profile(nativeExecutionContext)
    }

    public func setNativeHotPCProfilingEnabled(_ enabled: Bool) {
        avz_native_execution_context_set_hot_pc_profiling(
            nativeExecutionContext,
            enabled ? 1 : 0
        )
    }

    public func invalidateCodeCache(physicalAddress: GuestAddress, byteCount: UInt64) {
        guard byteCount > 0 else {
            return
        }

        avz_native_block_cache_invalidate_physical_range(
            nativeBlockCache,
            physicalAddress,
            byteCount
        )

        // The instruction cache is keyed by raw instruction word, so writes do
        // not invalidate decoded instruction semantics. Basic blocks are keyed
        // by address and can become stale when guest code is patched.
        let endAddress = physicalAddress &+ byteCount
        var affectedKeys: Set<BasicBlockCacheKey> = []
        for page in codePages(start: physicalAddress, end: endAddress) {
            if let keys = decodedBasicBlockKeysByCodePage[page] {
                affectedKeys.formUnion(keys)
            }
        }
        guard !affectedKeys.isEmpty else {
            return
        }

        var removedAny = false
        for key in affectedKeys {
            guard let block = decodedBasicBlockCache.remove(key: key) else {
                continue
            }
            unindexCodePages(for: block)
            removedAny = true
        }
        // The direct-mapped front cache can retain a block after the main
        // cache evicts it, so any indexed code write invalidates the front.
        decodedBasicBlockFrontCache.clear()
        if removedAny {
            codeCacheGeneration &+= 1
        }
    }

    private func indexCodePages(for block: DecodedBasicBlock) {
        for range in block.physicalRanges {
            for page in codePages(start: range.start, end: range.end) {
                decodedBasicBlockKeysByCodePage[page, default: []].insert(block.key)
            }
        }
    }

    private func unindexCodePages(for block: DecodedBasicBlock) {
        for range in block.physicalRanges {
            for page in codePages(start: range.start, end: range.end) {
                guard var keys = decodedBasicBlockKeysByCodePage[page] else {
                    continue
                }
                keys.remove(block.key)
                if keys.isEmpty {
                    decodedBasicBlockKeysByCodePage.removeValue(forKey: page)
                } else {
                    decodedBasicBlockKeysByCodePage[page] = keys
                }
            }
        }
    }

    private func codePages(start: GuestAddress, end: GuestAddress) -> StrideThrough<GuestAddress> {
        let firstPage = start & ~UInt64(0xfff)
        let lastPage = ((end &- 1) & ~UInt64(0xfff))
        return stride(from: firstPage, through: lastPage, by: 0x1000)
    }

    private func recordUnsupportedInstruction(_ instruction: UInt32) {
        unsupportedInstructionCounts[instruction, default: 0] += 1
    }

    private func recordUnsupportedInstruction(from error: Error) {
        guard case let VMError.unsupportedInstruction(instruction, _) = error else {
            return
        }
        recordUnsupportedInstruction(instruction)
    }

    public func run(vm: VirtualMachine, maxSteps: Int) throws -> RunResult {
        var steps = 0
        var nextDeadlineCheckStep = 256
        let ownsRunDeadline = vm.currentRunDeadlineNanoseconds == nil
        if ownsRunDeadline {
            vm.currentRunDeadlineNanoseconds = vm.wallClockRunBudgetNanoseconds.map {
                DispatchTime.now().uptimeNanoseconds &+ $0
            }
        }
        defer {
            if ownsRunDeadline {
                vm.currentRunDeadlineNanoseconds = nil
            }
        }
        while steps < maxSteps {
            if steps >= nextDeadlineCheckStep {
                nextDeadlineCheckStep = steps + 256
                if hasReachedWallClockRunDeadline(vm, completedSteps: steps) {
                    return RunResult(steps: steps, stopReason: .maxSteps(maxSteps), lastException: vm.lastException)
                }
            }
            if vm.cpu.halted {
                return RunResult(steps: steps, stopReason: .halted, lastException: vm.lastException)
            }

            vm.updateGenericTimerInterruptsIfNeeded()
            routePendingIRQIfNeeded(vm)

            if vm.breakpoints.contains(vm.cpu.pc) {
                let remainingSkips = vm.breakpointSkipCounts[vm.cpu.pc] ?? 0
                if remainingSkips > 0 {
                    vm.breakpointSkipCounts[vm.cpu.pc] = remainingSkips - 1
                } else {
                    return RunResult(steps: steps, stopReason: .breakpoint(vm.cpu.pc), lastException: vm.lastException)
                }
            }

            if canUseDecodedBasicBlocks(vm),
               let nativeOutcome = try executeNativeBasicBlockBurst(
                vm,
                maxSteps: maxSteps - steps
               ) {
                if let unsupportedInstruction = nativeOutcome.unsupportedInstruction {
                    recordUnsupportedInstruction(unsupportedInstruction)
                }
                steps += nativeOutcome.steps
                if let stopReason = nativeOutcome.stopReason {
                    return RunResult(steps: steps, stopReason: stopReason, lastException: vm.lastException)
                }
                if nativeOutcome.shouldContinue {
                    continue
                }
            }

            if canUseDecodedBasicBlocks(vm),
               let block = try cachedDecodedBasicBlock(for: vm),
               block.instructions.count <= maxSteps - steps {
                if let nativeOutcome = executeNativeBasicBlockIfPossible(
                    block,
                    vm: vm,
                    maxSteps: maxSteps - steps
                ) {
                    if let unsupportedInstruction = nativeOutcome.unsupportedInstruction {
                        recordUnsupportedInstruction(unsupportedInstruction)
                    }
                    steps += nativeOutcome.steps
                    if let stopReason = nativeOutcome.stopReason {
                        return RunResult(steps: steps, stopReason: stopReason, lastException: vm.lastException)
                    }
                    if nativeOutcome.shouldContinue {
                        continue
                    }
                }

                /*
                 * A native block can return no progress at a timer or callback
                 * boundary even though its first instruction is fully native.
                 * Retry that instruction in C before considering the decoded
                 * compatibility path.
                 */
                let nativeRetryPC = vm.cpu.pc
                let nativeRetryPState = vm.cpu.pstate
                if block.nativeEligible,
                   try executeNativeSingleInstructionIfPossible(vm) {
                    singleInstructionSteps += 1
                    nativeSingleInstructionSteps += 1
                    steps += 1
                    if let stopReason = finishInstructionCycle(
                        vm,
                        stepNumber: steps,
                        pcBeforeInstruction: nativeRetryPC,
                        pstateBeforeInstruction: nativeRetryPState
                    ) {
                        return RunResult(
                            steps: steps,
                            stopReason: stopReason,
                            lastException: vm.lastException
                        )
                    }
                    continue
                }

                guard fallbackInterpreterAllowed(for: vm) else {
                    try throwNativeCoverageGap(for: block, vm: vm)
                }
                recordNativeCoverageDiagnostics(for: block)

                let outcome: BasicBlockExecutionOutcome
                do {
                    outcome = try executeDecodedBasicBlock(block, vm: vm, startingStep: steps + 1)
                } catch {
                    recordUnsupportedInstruction(from: error)
                    throw error
                }
                steps += outcome.steps
                if let stopReason = outcome.stopReason {
                    return RunResult(steps: steps, stopReason: stopReason, lastException: vm.lastException)
                }
                continue
            }

            let stopReason: RunStopReason?
            do {
                stopReason = try executeSingleInstructionCycle(vm, stepNumber: steps + 1)
            } catch {
                recordUnsupportedInstruction(from: error)
                throw error
            }
            if let stopReason {
                return RunResult(steps: steps + 1, stopReason: stopReason, lastException: vm.lastException)
            }
            steps += 1
        }

        return RunResult(steps: steps, stopReason: .maxSteps(maxSteps), lastException: vm.lastException)
    }

    private func fallbackInterpreterAllowed(for vm: VirtualMachine) -> Bool {
        switch fallbackInterpreterPolicy {
        case .nativeOnly:
            return false
        case .alwaysAllow:
            return true
        case .diagnosticsOnly:
            return true
        }
    }

    private func recordNativeCoverageDiagnostics(for block: DecodedBasicBlock) {
        guard !block.nativeEligible else {
            return
        }
        if let missing = block.instructions.first(where: { entry in
            !cachedNativeInstruction(for: entry.instruction).supported
        }) {
            nativeIneligibleGadgetCounts[basicBlockInstructionName(for: missing.instruction), default: 0] += 1
            recordUnsupportedInstruction(missing.instruction)
        }
    }

    private func throwNativeCoverageGap(for block: DecodedBasicBlock, vm: VirtualMachine) throws -> Never {
        if let missing = block.instructions.first(where: { entry in
            !cachedNativeInstruction(for: entry.instruction).supported
        }) {
            nativeIneligibleGadgetCounts[basicBlockInstructionName(for: missing.instruction), default: 0] += 1
            recordUnsupportedInstruction(missing.instruction)
            throw VMError.unsupportedInstruction(instruction: missing.instruction, pc: missing.pc)
        }

        let instruction = block.instructions.first?.instruction ?? 0
        recordUnsupportedInstruction(instruction)
        throw VMError.unsupportedInstruction(instruction: instruction, pc: vm.cpu.pc)
    }

    private struct BasicBlockCacheKey: Hashable {
        let pc: GuestAddress
        let currentEL: Int
        let sctlrEL1: UInt64
        let tcrEL1: UInt64
        let ttbr0EL1: UInt64
        let ttbr1EL1: UInt64
    }

    @inline(__always)
    private static func mixBasicBlockCacheHash(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed ^= mixed >> 30
        mixed &*= 0xbf58_476d_1ce4_e5b9
        mixed ^= mixed >> 27
        mixed &*= 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31
        return mixed
    }

    @inline(__always)
    private static func basicBlockCacheHash(_ key: BasicBlockCacheKey) -> UInt64 {
        var hash = mixBasicBlockCacheHash(key.pc)
        hash ^= mixBasicBlockCacheHash(UInt64(truncatingIfNeeded: key.currentEL))
        hash ^= mixBasicBlockCacheHash(key.sctlrEL1)
        hash ^= mixBasicBlockCacheHash(key.tcrEL1)
        hash ^= mixBasicBlockCacheHash(key.ttbr0EL1)
        hash ^= mixBasicBlockCacheHash(key.ttbr1EL1)
        return mixBasicBlockCacheHash(hash)
    }

    private struct DecodedBlockInstruction {
        let pc: GuestAddress
        let instruction: UInt32
        let decoded: DecodedInstruction
    }

    private final class DecodedBasicBlock {
        let key: BasicBlockCacheKey
        let instructions: [DecodedBlockInstruction]
        let nativeInstructions: [AVZNativeInstruction]
        let physicalRanges: [CodeCachePhysicalRange]
        let nativeEligible: Bool
        let usesVectorState: Bool

        init(
            key: BasicBlockCacheKey,
            instructions: [DecodedBlockInstruction],
            nativeInstructions: [AVZNativeInstruction],
            physicalRanges: [CodeCachePhysicalRange],
            nativeEligible: Bool,
            usesVectorState: Bool
        ) {
            self.key = key
            self.instructions = instructions
            self.nativeInstructions = nativeInstructions
            self.physicalRanges = physicalRanges
            self.nativeEligible = nativeEligible
            self.usesVectorState = usesVectorState
        }
    }

    private struct DecodedBasicBlockFrontCacheEntry {
        var key = BasicBlockCacheKey(
            pc: 0,
            currentEL: 0,
            sctlrEL1: 0,
            tcrEL1: 0,
            ttbr0EL1: 0,
            ttbr1EL1: 0
        )
        var block: DecodedBasicBlock?
        var valid = false
    }

    private struct DecodedBasicBlockCacheEntry {
        var key = BasicBlockCacheKey(
            pc: 0,
            currentEL: 0,
            sctlrEL1: 0,
            tcrEL1: 0,
            ttbr0EL1: 0,
            ttbr1EL1: 0
        )
        var block: DecodedBasicBlock?
        var valid = false
    }

    private final class DecodedBasicBlockFrontCache {
        private static let entryCount = 4096
        private static let indexMask = entryCount - 1

        private let entries: UnsafeMutableBufferPointer<DecodedBasicBlockFrontCacheEntry>

        init() {
            let storage = UnsafeMutablePointer<DecodedBasicBlockFrontCacheEntry>.allocate(
                capacity: Self.entryCount
            )
            storage.initialize(
                repeating: DecodedBasicBlockFrontCacheEntry(),
                count: Self.entryCount
            )
            entries = UnsafeMutableBufferPointer(start: storage, count: Self.entryCount)
        }

        deinit {
            guard let baseAddress = entries.baseAddress else {
                return
            }
            baseAddress.deinitialize(count: Self.entryCount)
            baseAddress.deallocate()
        }

        @inline(__always)
        private func index(for key: BasicBlockCacheKey) -> Int {
            Int(truncatingIfNeeded: SoftwareARM64Backend.basicBlockCacheHash(key)) & Self.indexMask
        }

        @inline(__always)
        func block(for key: BasicBlockCacheKey) -> DecodedBasicBlock? {
            let entry = entries[index(for: key)]
            guard entry.valid, entry.key == key else {
                return nil
            }
            return entry.block
        }

        @inline(__always)
        func store(_ block: DecodedBasicBlock) {
            entries[index(for: block.key)] = DecodedBasicBlockFrontCacheEntry(
                key: block.key,
                block: block,
                valid: true
            )
        }

        func clear() {
            guard let baseAddress = entries.baseAddress else {
                return
            }
            baseAddress.update(
                repeating: DecodedBasicBlockFrontCacheEntry(),
                count: Self.entryCount
            )
        }
    }

    private final class DecodedBasicBlockCache {
        private static let setCount = 32768
        private static let wayCount = 4
        private static let indexMask = setCount - 1
        private static let entryCount = setCount * wayCount

        private let entries: UnsafeMutableBufferPointer<DecodedBasicBlockCacheEntry>
        private let replacementCursor: UnsafeMutableBufferPointer<UInt8>
        private(set) var count = 0

        init() {
            let entryStorage = UnsafeMutablePointer<DecodedBasicBlockCacheEntry>.allocate(
                capacity: Self.entryCount
            )
            entryStorage.initialize(
                repeating: DecodedBasicBlockCacheEntry(),
                count: Self.entryCount
            )
            entries = UnsafeMutableBufferPointer(start: entryStorage, count: Self.entryCount)

            let cursorStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.setCount)
            cursorStorage.initialize(repeating: 0, count: Self.setCount)
            replacementCursor = UnsafeMutableBufferPointer(start: cursorStorage, count: Self.setCount)
        }

        deinit {
            if let baseAddress = entries.baseAddress {
                baseAddress.deinitialize(count: Self.entryCount)
                baseAddress.deallocate()
            }
            if let baseAddress = replacementCursor.baseAddress {
                baseAddress.deinitialize(count: Self.setCount)
                baseAddress.deallocate()
            }
        }

        @inline(__always)
        private func setIndex(for key: BasicBlockCacheKey) -> Int {
            Int(truncatingIfNeeded: SoftwareARM64Backend.basicBlockCacheHash(key)) & Self.indexMask
        }

        @inline(__always)
        private func setBaseOffset(for key: BasicBlockCacheKey) -> Int {
            setIndex(for: key) * Self.wayCount
        }

        @inline(__always)
        func block(for key: BasicBlockCacheKey) -> DecodedBasicBlock? {
            let base = setBaseOffset(for: key)
            for way in 0..<Self.wayCount {
                let entry = entries[base + way]
                guard entry.valid, entry.key == key else {
                    continue
                }
                return entry.block
            }
            return nil
        }

        @inline(__always)
        @discardableResult
        func store(_ block: DecodedBasicBlock) -> DecodedBasicBlock? {
            let base = setBaseOffset(for: block.key)
            var firstInvalidIndex: Int?
            for way in 0..<Self.wayCount {
                let index = base + way
                let entry = entries[index]
                if entry.valid {
                    if entry.key == block.key {
                        var updatedEntry = entry
                        updatedEntry.block = block
                        entries[index] = updatedEntry
                        return entry.block
                    }
                    continue
                }
                if firstInvalidIndex == nil {
                    firstInvalidIndex = index
                }
            }

            if let firstInvalidIndex {
                entries[firstInvalidIndex] = DecodedBasicBlockCacheEntry(
                    key: block.key,
                    block: block,
                    valid: true
                )
                count &+= 1
                return nil
            }

            let set = base / Self.wayCount
            let victimWay = Int(replacementCursor[set]) & (Self.wayCount - 1)
            replacementCursor[set] = UInt8((victimWay + 1) & (Self.wayCount - 1))
            let victimIndex = base + victimWay
            let evicted = entries[victimIndex].block
            entries[victimIndex] = DecodedBasicBlockCacheEntry(
                key: block.key,
                block: block,
                valid: true
            )
            return evicted
        }

        @inline(__always)
        func remove(key: BasicBlockCacheKey) -> DecodedBasicBlock? {
            let base = setBaseOffset(for: key)
            for way in 0..<Self.wayCount {
                let index = base + way
                let entry = entries[index]
                guard entry.valid, entry.key == key else {
                    continue
                }
                var clearedEntry = entry
                clearedEntry.valid = false
                clearedEntry.block = nil
                entries[index] = clearedEntry
                count &-= 1
                return entry.block
            }
            return nil
        }

        func forEachBlock(_ body: (DecodedBasicBlock) -> Void) {
            for index in 0..<Self.entryCount {
                let entry = entries[index]
                guard entry.valid else {
                    continue
                }
                if let block = entry.block {
                    body(block)
                }
            }
        }
    }

    private struct CodeCachePhysicalRange {
        let start: GuestAddress
        let end: GuestAddress
    }

    private struct BasicBlockGadget {
        let name: String
        let terminatesBlock: Bool
        let execute: (SoftwareARM64Backend, VirtualMachine, UInt32, GuestAddress) throws -> Void

        init(
            name: String,
            terminatesBlock: Bool = false,
            execute: @escaping (SoftwareARM64Backend, VirtualMachine, UInt32, GuestAddress) throws -> Void
        ) {
            self.name = name
            self.terminatesBlock = terminatesBlock
            self.execute = execute
        }
    }

    private struct BasicBlockMetadata {
        let name: String
        let terminatesBlock: Bool
    }

    private final class DecodeScratch {
        private let capacity: Int
        private let instructions: UnsafeMutableBufferPointer<DecodedBlockInstruction>
        private let nativeInstructions: UnsafeMutableBufferPointer<AVZNativeInstruction>
        private let physicalRanges: UnsafeMutableBufferPointer<CodeCachePhysicalRange>

        init(capacity: Int) {
            self.capacity = capacity

            let instructionStorage = UnsafeMutablePointer<DecodedBlockInstruction>.allocate(
                capacity: capacity
            )
            instructionStorage.initialize(
                repeating: DecodedBlockInstruction(
                    pc: 0,
                    instruction: 0,
                    decoded: .advancePC
                ),
                count: capacity
            )
            instructions = UnsafeMutableBufferPointer(start: instructionStorage, count: capacity)

            let nativeInstructionStorage = UnsafeMutablePointer<AVZNativeInstruction>.allocate(
                capacity: capacity
            )
            nativeInstructionStorage.initialize(repeating: AVZNativeInstruction(), count: capacity)
            nativeInstructions = UnsafeMutableBufferPointer(
                start: nativeInstructionStorage,
                count: capacity
            )

            let physicalRangeStorage = UnsafeMutablePointer<CodeCachePhysicalRange>.allocate(
                capacity: capacity
            )
            physicalRangeStorage.initialize(
                repeating: CodeCachePhysicalRange(start: 0, end: 0),
                count: capacity
            )
            physicalRanges = UnsafeMutableBufferPointer(start: physicalRangeStorage, count: capacity)
        }

        deinit {
            if let baseAddress = instructions.baseAddress {
                baseAddress.deinitialize(count: capacity)
                baseAddress.deallocate()
            }
            if let baseAddress = nativeInstructions.baseAddress {
                baseAddress.deinitialize(count: capacity)
                baseAddress.deallocate()
            }
            if let baseAddress = physicalRanges.baseAddress {
                baseAddress.deinitialize(count: capacity)
                baseAddress.deallocate()
            }
        }

        @inline(__always)
        func storeInstruction(_ instruction: DecodedBlockInstruction, at index: Int) {
            instructions[index] = instruction
        }

        @inline(__always)
        func storeNativeInstruction(_ instruction: AVZNativeInstruction, at index: Int) {
            nativeInstructions[index] = instruction
        }

        @inline(__always)
        func storePhysicalRange(_ range: CodeCachePhysicalRange, at index: Int) {
            physicalRanges[index] = range
        }

        @inline(__always)
        func decodedInstructionsPrefix(count: Int) -> [DecodedBlockInstruction] {
            guard let baseAddress = instructions.baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: baseAddress, count: count))
        }

        @inline(__always)
        func nativeInstructionsPrefix(count: Int) -> [AVZNativeInstruction] {
            guard let baseAddress = nativeInstructions.baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(start: baseAddress, count: count))
        }

        @inline(__always)
        func physicalRangeBuffer(count: Int) -> UnsafeBufferPointer<CodeCachePhysicalRange> {
            UnsafeBufferPointer(start: physicalRanges.baseAddress, count: count)
        }
    }

    private struct BasicBlockExecutionOutcome {
        let steps: Int
        let stopReason: RunStopReason?
    }

    private struct NativeBasicBlockExecutionOutcome {
        let steps: Int
        let stopReason: RunStopReason?
        let shouldContinue: Bool
        let unsupportedInstruction: UInt32?
        let translationFault: ARM64TranslationFault?
    }

    private final class NativePStateBox {
        var value: UInt64

        init(_ value: UInt64) {
            self.value = value
        }
    }

    private final class NativeChainCheckpointContext {
        let backend: SoftwareARM64Backend
        let vm: VirtualMachine
        let memoryContext: NativeMemoryContext
        let pstateBox: NativePStateBox
        let maxSteps: Int
        let hostPreemptionGeneration: UInt64?
        var totalSteps: Int
        var nextDeadlineCheckStep: Int
        var stopReason: RunStopReason?
        var translationFault: ARM64TranslationFault?
        var blockedPinnedDeviceAccess = false
        var shouldYield = false

        init(
            backend: SoftwareARM64Backend,
            vm: VirtualMachine,
            memoryContext: NativeMemoryContext,
            pstateBox: NativePStateBox,
            maxSteps: Int,
            totalSteps: Int,
            nextDeadlineCheckStep: Int,
            hostPreemptionGeneration: UInt64?
        ) {
            self.backend = backend
            self.vm = vm
            self.memoryContext = memoryContext
            self.pstateBox = pstateBox
            self.maxSteps = maxSteps
            self.totalSteps = totalSteps
            self.nextDeadlineCheckStep = nextDeadlineCheckStep
            self.hostPreemptionGeneration = hostPreemptionGeneration
        }

        func checkpoint(
            executionSteps: UInt64,
            executionBlocks: UInt64,
            pstate: UInt64
        ) -> UInt64 {
            pstateBox.value = pstate
            let executedSteps = Int(clamping: executionSteps)
            let executedBlocks = Int(clamping: executionBlocks)
            let fault = memoryContext.translationFault
            let accountedSteps = executedSteps + (fault == nil ? 0 : 1)

            if memoryContext.blockedPinnedDeviceAccess {
                if executedSteps > 0 {
                    backend.nativeBasicBlockExecutions += executedBlocks
                    backend.nativeBasicBlockSteps += executedSteps
                    totalSteps += executedSteps
                }
                blockedPinnedDeviceAccess = true
                return 0
            }

            if accountedSteps > 0 {
                backend.nativeBasicBlockExecutions += executedBlocks
                backend.nativeBasicBlockSteps += accountedSteps
                totalSteps += accountedSteps
            }

            if let requestedStop = vm.requestedStopReason {
                stopReason = requestedStop
                shouldYield = true
                return 0
            }
            if let hostPreemptionGeneration,
               vm.hostPreemptionGenerationProvider?() != hostPreemptionGeneration {
                stopReason = .maxSteps(maxSteps)
                shouldYield = true
                return 0
            }
            if totalSteps >= nextDeadlineCheckStep {
                nextDeadlineCheckStep = totalSteps + 4_096
                if backend.hasReachedWallClockRunDeadline(vm, completedSteps: totalSteps) {
                    shouldYield = true
                    return 0
                }
            }
            if let fault {
                translationFault = fault
                shouldYield = true
                return 0
            }
            if memoryContext.translationContextChanged {
                shouldYield = true
                return 0
            }
            if totalSteps >= maxSteps {
                shouldYield = true
                return 0
            }
            if backend.hasUnmaskedPendingIRQ(vm, pstate: pstate) {
                shouldYield = true
                return 0
            }

            memoryContext.resetTransientState()
            let limit = min(maxSteps - totalSteps, 65_536)
            if limit == 0 {
                shouldYield = true
            }
            return UInt64(limit)
        }
    }

    private let nativeChainCheckpoint: AVZNativeChainCheckpointCallback = {
        context, executionSteps, executionBlocks, _, _, pstate, _
    in
        guard let context else {
            return 0
        }
        return Unmanaged<NativeChainCheckpointContext>
            .fromOpaque(context)
            .takeUnretainedValue()
            .checkpoint(
                executionSteps: executionSteps,
                executionBlocks: executionBlocks,
                pstate: pstate
            )
    }

    private struct DecodedInstructionCacheEntry {
        var instruction: UInt32 = 0
        var decoded: DecodedInstruction = .advancePC
        var valid = false
    }

    private struct NativeInstructionCacheEntry {
        var instruction: UInt32 = 0
        var decoded = AVZNativeInstruction()
        var supported = false
        var valid = false
    }

    private final class DecodedInstructionCache {
        private static let entryCount = 8192
        private static let indexMask = entryCount - 1

        private let entries: UnsafeMutableBufferPointer<DecodedInstructionCacheEntry>

        init() {
            let storage = UnsafeMutablePointer<DecodedInstructionCacheEntry>.allocate(
                capacity: Self.entryCount
            )
            storage.initialize(repeating: DecodedInstructionCacheEntry(), count: Self.entryCount)
            entries = UnsafeMutableBufferPointer(start: storage, count: Self.entryCount)
        }

        deinit {
            guard let baseAddress = entries.baseAddress else {
                return
            }
            baseAddress.deinitialize(count: Self.entryCount)
            baseAddress.deallocate()
        }

        @inline(__always)
        private func index(for instruction: UInt32) -> Int {
            let mixed = UInt64(instruction) &* 0x9e37_79b9_7f4a_7c15
            return Int(truncatingIfNeeded: mixed >> 17) & Self.indexMask
        }

        @inline(__always)
        func decoded(for instruction: UInt32) -> DecodedInstruction? {
            let entry = entries[index(for: instruction)]
            guard entry.valid, entry.instruction == instruction else {
                return nil
            }
            return entry.decoded
        }

        @inline(__always)
        func store(_ decoded: DecodedInstruction, for instruction: UInt32) {
            entries[index(for: instruction)] = DecodedInstructionCacheEntry(
                instruction: instruction,
                decoded: decoded,
                valid: true
            )
        }
    }

    private final class NativeInstructionCache {
        private static let entryCount = 16384
        private static let indexMask = entryCount - 1

        private let entries: UnsafeMutableBufferPointer<NativeInstructionCacheEntry>

        init() {
            let storage = UnsafeMutablePointer<NativeInstructionCacheEntry>.allocate(
                capacity: Self.entryCount
            )
            storage.initialize(repeating: NativeInstructionCacheEntry(), count: Self.entryCount)
            entries = UnsafeMutableBufferPointer(start: storage, count: Self.entryCount)
        }

        deinit {
            guard let baseAddress = entries.baseAddress else {
                return
            }
            baseAddress.deinitialize(count: Self.entryCount)
            baseAddress.deallocate()
        }

        @inline(__always)
        private func index(for instruction: UInt32) -> Int {
            let mixed = UInt64(instruction) &* 0xc2b2_ae3d_27d4_eb4f
            return Int(truncatingIfNeeded: mixed >> 17) & Self.indexMask
        }

        @inline(__always)
        func decoded(for instruction: UInt32) -> (nativeInstruction: AVZNativeInstruction, supported: Bool)? {
            let entry = entries[index(for: instruction)]
            guard entry.valid, entry.instruction == instruction else {
                return nil
            }
            return (entry.decoded, entry.supported)
        }

        @inline(__always)
        func store(
            _ nativeInstruction: AVZNativeInstruction,
            supported: Bool,
            for instruction: UInt32
        ) {
            entries[index(for: instruction)] = NativeInstructionCacheEntry(
                instruction: instruction,
                decoded: nativeInstruction,
                supported: supported,
                valid: true
            )
        }
    }

    private struct NativePageCacheKey {
        let virtualPage: GuestAddress
        let access: UInt64
        let exceptionLevel: UInt64
        let sctlr: UInt64
        let tcr: UInt64
        let ttbr: UInt64
    }

    private struct NativePageCacheEntry {
        var key = NativePageCacheKey(
            virtualPage: 0,
            access: 0,
            exceptionLevel: 0,
            sctlr: 0,
            tcr: 0,
            ttbr: 0
        )
        var physicalPage: GuestAddress = 0
        var valid = false
    }

    private final class NativeTranslatedPageCache {
        private static let entryCount = 2048
        private static let indexMask = entryCount - 1

        private let entries: UnsafeMutableBufferPointer<NativePageCacheEntry>

        init() {
            let storage = UnsafeMutablePointer<NativePageCacheEntry>.allocate(
                capacity: Self.entryCount
            )
            storage.initialize(repeating: NativePageCacheEntry(), count: Self.entryCount)
            entries = UnsafeMutableBufferPointer(start: storage, count: Self.entryCount)
        }

        deinit {
            guard let baseAddress = entries.baseAddress else {
                return
            }
            baseAddress.deinitialize(count: Self.entryCount)
            baseAddress.deallocate()
        }

        @inline(__always)
        private func index(for key: NativePageCacheKey) -> Int {
            var hash = key.virtualPage >> 12
            hash ^= key.access &* 0x9e37_79b9_7f4a_7c15
            hash ^= key.exceptionLevel &* 0xc2b2_ae3d_27d4_eb4f
            hash ^= key.sctlr &* 0x1656_67b1_9e37_79f9
            hash ^= key.tcr &* 0x85eb_ca6b_27d4_eb2f
            hash ^= key.ttbr &* 0x27d4_eb2f_1656_67c5
            hash ^= hash >> 33
            return Int(truncatingIfNeeded: hash) & Self.indexMask
        }

        @inline(__always)
        func physicalPage(for key: NativePageCacheKey) -> GuestAddress? {
            let entry = entries[index(for: key)]
            guard entry.valid,
                  entry.key.virtualPage == key.virtualPage,
                  entry.key.access == key.access,
                  entry.key.exceptionLevel == key.exceptionLevel,
                  entry.key.sctlr == key.sctlr,
                  entry.key.tcr == key.tcr,
                  entry.key.ttbr == key.ttbr else {
                return nil
            }
            return entry.physicalPage
        }

        @inline(__always)
        func store(_ physicalPage: GuestAddress, for key: NativePageCacheKey) {
            entries[index(for: key)] = NativePageCacheEntry(
                key: key,
                physicalPage: physicalPage,
                valid: true
            )
        }

        func removeAll() {
            for index in entries.indices {
                entries[index].valid = false
            }
        }
    }

    private final class NativeMemoryContext {
        unowned let backend: SoftwareARM64Backend
        unowned let vm: VirtualMachine
        private let ramBase: GuestAddress
        private let ramEndExclusive: GuestAddress
        var ramBytes: UnsafeMutableRawBufferPointer?
        var fastPath: OpaquePointer?
        var allowDeviceAccessWhileRAMPinned: Bool
        let currentPStateBox: NativePStateBox?
        private let translatedPageCache: NativeTranslatedPageCache

        var translationFault: ARM64TranslationFault?
        var blockedPinnedDeviceAccess = false
        var translationContextChanged = false
        private static let outputAddressMask: UInt64 = 0x0000_ffff_ffff_f000
        private static let accessFlagBit: UInt64 = 1 << 10
        private static let readOnlyAPBit: UInt64 = 1 << 7
        private static let privilegedExecuteNeverBit: UInt64 = 1 << 53
        private static let unprivilegedExecuteNeverBit: UInt64 = 1 << 54

        init(
            backend: SoftwareARM64Backend,
            vm: VirtualMachine,
            ramBytes: UnsafeMutableRawBufferPointer?,
            translatedPageCache: NativeTranslatedPageCache,
            currentPStateBox: NativePStateBox? = nil,
            allowDeviceAccessWhileRAMPinned: Bool = true
        ) {
            self.backend = backend
            self.vm = vm
            self.ramBase = vm.memory.base
            self.ramEndExclusive = vm.memory.base &+ UInt64(vm.memory.size)
            self.ramBytes = ramBytes
            self.translatedPageCache = translatedPageCache
            self.allowDeviceAccessWhileRAMPinned = allowDeviceAccessWhileRAMPinned
            self.currentPStateBox = currentPStateBox
        }

        func resetTransientState() {
            translationFault = nil
            blockedPinnedDeviceAccess = false
            translationContextChanged = false
            avz_native_memory_fast_path_clear_translation_fault(fastPath)
        }

        func invalidateTranslatedPages() {
            translatedPageCache.removeAll()
            syncNativeTranslationState()
            avz_native_memory_fast_path_invalidate_translation(fastPath)
        }

        @inline(__always)
        func syncNativeTranslationState() {
            guard let fastPath else {
                return
            }
            var state = AVZNativeStage1TranslationState(
                sctlr_el1: vm.translationSCTLR_EL1,
                tcr_el1: vm.translationTCR_EL1,
                ttbr0_el1: vm.translationTTBR0_EL1,
                ttbr1_el1: vm.translationTTBR1_EL1,
                current_el: UInt8((currentPStateValue() >> 2) & 0x3)
            )
            avz_native_memory_fast_path_set_stage1_translation(
                fastPath,
                &state,
                backend.nativeTranslationFault
            )
        }

        @inline(__always)
        private func containsRAM(_ physicalAddress: GuestAddress, width: UInt64) -> Bool {
            guard width > 0,
                  physicalAddress >= ramBase,
                  physicalAddress <= UInt64.max - width else {
                return false
            }
            return physicalAddress &+ width <= ramEndExclusive
        }

        @inline(__always)
        func canAccessRAM(_ virtualAddress: GuestAddress, width: MMIOWidth, access: GuestMemoryAccessKind) throws -> Bool {
            if !crossesPageBoundary(virtualAddress, width: width) {
                return try ramMapping(for: virtualAddress, width: width, access: access) != nil
            }
            for byteOffset in 0..<UInt64(width.rawValue) {
                guard let physicalAddress = try translatedSinglePageAddress(
                    virtualAddress + byteOffset,
                    width: .byte,
                    access: access
                ) else {
                    return false
                }
                guard containsRAM(physicalAddress, width: 1) else {
                    return false
                }
            }
            return true
        }

        @inline(__always)
        func readRAM(_ virtualAddress: GuestAddress, width: MMIOWidth) throws -> UInt64? {
            guard let mapping = try ramMapping(for: virtualAddress, width: width, access: .dataRead) else {
                return nil
            }
            if let ramBytes {
                return readBuffer(
                    UnsafeRawBufferPointer(ramBytes),
                    offset: mapping.offset,
                    width: width
                )
            }
            return vm.memory.withUnsafeBytes { ramBytes in
                readBuffer(ramBytes, offset: mapping.offset, width: width)
            }
        }

        @inline(__always)
        func fetchInstruction(
            at virtualAddress: GuestAddress,
            physicalAddressHint: GuestAddress? = nil
        ) throws -> (physicalPC: GuestAddress, instruction: UInt32)? {
            let physicalAddress: GuestAddress
            if let physicalAddressHint,
               (virtualAddress & 0xfff) != 0 {
                physicalAddress = physicalAddressHint
            } else if let translatedAddress = try translatedSinglePageAddress(
                virtualAddress,
                width: .word,
                access: .instruction
            ) {
                physicalAddress = translatedAddress
            } else {
                return nil
            }
            if containsRAM(physicalAddress, width: 4) {
                let offset = Int(physicalAddress - ramBase)
                let word: UInt32
                if let ramBytes {
                    word = UInt32(truncatingIfNeeded: readBuffer(
                        UnsafeRawBufferPointer(ramBytes),
                        offset: offset,
                        width: .word
                    ))
                } else {
                    word = vm.memory.withUnsafeBytes { ramBytes in
                        UInt32(truncatingIfNeeded: readBuffer(ramBytes, offset: offset, width: .word))
                    }
                }
                return (physicalAddress, word)
            }
            guard !shouldBlockPinnedDeviceAccess(physicalAddress, width: .word) else {
                return nil
            }
            return (physicalAddress, UInt32(truncatingIfNeeded: try vm.readPhysical(physicalAddress, width: .word)))
        }

        @inline(__always)
        private func readBuffer(
            _ ramBytes: UnsafeRawBufferPointer,
            offset: Int,
            width: MMIOWidth
        ) -> UInt64 {
            switch width {
            case .byte:
                return UInt64(ramBytes[offset])
            case .halfword:
                var value: UInt16 = 0
                memcpy(&value, ramBytes.baseAddress!.advanced(by: offset), 2)
                return UInt64(UInt16(littleEndian: value))
            case .word:
                var value: UInt32 = 0
                memcpy(&value, ramBytes.baseAddress!.advanced(by: offset), 4)
                return UInt64(UInt32(littleEndian: value))
            case .doubleword:
                var value: UInt64 = 0
                memcpy(&value, ramBytes.baseAddress!.advanced(by: offset), 8)
                return UInt64(littleEndian: value)
            }
        }

        func readMemory(_ virtualAddress: GuestAddress, width: MMIOWidth) throws -> (value: UInt64, fastRAM: Bool)? {
            if crossesPageBoundary(virtualAddress, width: width) {
                return try readSplitMemory(virtualAddress, width: width)
            }
            if let value = try readRAM(virtualAddress, width: width) {
                return (value, true)
            }
            guard let physicalAddress = try translatedDeviceAddress(
                virtualAddress,
                width: width,
                access: .dataRead
            ) else { return nil }
            guard !shouldBlockPinnedDeviceAccess(physicalAddress, width: width) else {
                return nil
            }
            return (try vm.readPhysical(physicalAddress, width: width), false)
        }

        private func readSplitMemory(_ virtualAddress: GuestAddress, width: MMIOWidth) throws -> (value: UInt64, fastRAM: Bool)? {
            var value: UInt64 = 0
            var allFastRAM = true

            for byteOffset in 0..<UInt64(width.rawValue) {
                guard let physicalAddress = try translatedSinglePageAddress(
                    virtualAddress + byteOffset,
                    width: .byte,
                    access: .dataRead
                ) else {
                    return nil
                }

                let byte: UInt64
                if containsRAM(physicalAddress, width: 1) {
                    let offset = Int(physicalAddress - ramBase)
                    if let ramBytes {
                        byte = UInt64(ramBytes[offset])
                    } else {
                        byte = vm.memory.withUnsafeBytes { ramBytes in
                            UInt64(ramBytes[offset])
                        }
                    }
                } else {
                    guard !shouldBlockPinnedDeviceAccess(physicalAddress, width: .byte) else {
                        return nil
                    }
                    byte = try vm.readPhysical(physicalAddress, width: .byte)
                    allFastRAM = false
                }
                value |= byte << UInt64(Int(byteOffset) * 8)
            }

            return (value, allFastRAM)
        }

        func writeRAM(_ virtualAddress: GuestAddress, width: MMIOWidth, value: UInt64) throws -> Bool {
            guard let mapping = try ramMapping(for: virtualAddress, width: width, access: .dataWrite) else {
                return false
            }
            if let ramBytes {
                writeBuffer(ramBytes, offset: mapping.offset, width: width, value: value)
            } else {
                vm.memory.withUnsafeMutableBytesWithoutDirtyTracking { ramBytes in
                    writeBuffer(ramBytes, offset: mapping.offset, width: width, value: value)
                }
            }
            vm.memory.markDirty(
                at: mapping.physicalAddress,
                count: width.rawValue
            )
            backend.invalidateCodeCache(physicalAddress: mapping.physicalAddress, byteCount: UInt64(width.rawValue))
            vm.clearExclusiveReservation()
            return true
        }

        private func writeBuffer(
            _ ramBytes: UnsafeMutableRawBufferPointer,
            offset: Int,
            width: MMIOWidth,
            value: UInt64
        ) {
            switch width {
            case .byte:
                ramBytes[offset] = UInt8(truncatingIfNeeded: value)
            case .halfword:
                var encoded = UInt16(truncatingIfNeeded: value).littleEndian
                memcpy(ramBytes.baseAddress!.advanced(by: offset), &encoded, 2)
            case .word:
                var encoded = UInt32(truncatingIfNeeded: value).littleEndian
                memcpy(ramBytes.baseAddress!.advanced(by: offset), &encoded, 4)
            case .doubleword:
                var encoded = value.littleEndian
                memcpy(ramBytes.baseAddress!.advanced(by: offset), &encoded, 8)
            }
        }

        func writeMemory(_ virtualAddress: GuestAddress, width: MMIOWidth, value: UInt64) throws -> Bool? {
            if crossesPageBoundary(virtualAddress, width: width) {
                return try writeSplitMemory(virtualAddress, width: width, value: value)
            }
            if try writeRAM(virtualAddress, width: width, value: value) {
                return true
            }
            guard let physicalAddress = try translatedDeviceAddress(
                virtualAddress,
                width: width,
                access: .dataWrite
            ) else { return nil }
            guard !shouldBlockPinnedDeviceAccess(physicalAddress, width: width) else {
                return nil
            }
            try vm.writePhysical(physicalAddress, width: width, value: value)
            return false
        }

        private func writeSplitMemory(_ virtualAddress: GuestAddress, width: MMIOWidth, value: UInt64) throws -> Bool? {
            var allFastRAM = true
            var invalidatedPhysicalAddresses: [GuestAddress] = []

            for byteOffset in 0..<UInt64(width.rawValue) {
                guard let physicalAddress = try translatedSinglePageAddress(
                    virtualAddress + byteOffset,
                    width: .byte,
                    access: .dataWrite
                ) else {
                    return nil
                }
                let byte = UInt8((value >> UInt64(Int(byteOffset) * 8)) & 0xff)

                if containsRAM(physicalAddress, width: 1) {
                    let offset = Int(physicalAddress - ramBase)
                    if let ramBytes {
                        ramBytes[offset] = byte
                    } else {
                        vm.memory.withUnsafeMutableBytesWithoutDirtyTracking { ramBytes in
                            ramBytes[offset] = byte
                        }
                    }
                    invalidatedPhysicalAddresses.append(physicalAddress)
                } else {
                    guard !shouldBlockPinnedDeviceAccess(physicalAddress, width: .byte) else {
                        return nil
                    }
                    try vm.writePhysical(physicalAddress, width: .byte, value: UInt64(byte))
                    allFastRAM = false
                }
            }

            for physicalAddress in invalidatedPhysicalAddresses {
                vm.memory.markDirty(at: physicalAddress, count: 1)
                backend.invalidateCodeCache(physicalAddress: physicalAddress, byteCount: 1)
            }
            if !invalidatedPhysicalAddresses.isEmpty {
                vm.clearExclusiveReservation()
            }
            return allFastRAM
        }

        func fillRAM(
            _ virtualAddress: GuestAddress,
            byteCount: UInt64,
            pattern: UInt64,
            patternWidth: Int
        ) throws -> Bool {
            guard byteCount > 0 else {
                return true
            }
            let endAddress = virtualAddress.addingReportingOverflow(byteCount - 1)
            guard [1, 2, 4, 8].contains(patternWidth),
                  !endAddress.overflow,
                  endAddress.partialValue >= virtualAddress else {
                return false
            }

            struct Mapping {
                let physicalAddress: GuestAddress
                let offset: Int
                let byteCount: Int
                let patternOffset: Int
            }

            var mappings: [Mapping] = []
            var current = virtualAddress
            var remaining = byteCount
            var consumed: UInt64 = 0
            while remaining > 0 {
                let pageRemaining = 0x1000 - (current & 0xfff)
                let chunk = min(remaining, pageRemaining)
                guard let physicalAddress = try translatedSinglePageAddress(
                    current,
                    width: .byte,
                    access: .dataWrite
                ),
                    vm.memory.range.contains(physicalAddress, width: chunk),
                    chunk <= UInt64(Int.max) else {
                    return false
                }
                mappings.append(Mapping(
                    physicalAddress: physicalAddress,
                    offset: Int(physicalAddress - vm.memory.base),
                    byteCount: Int(chunk),
                    patternOffset: Int(consumed % UInt64(patternWidth))
                ))
                current += chunk
                consumed += chunk
                remaining -= chunk
            }

            var patternBytes = [UInt8](repeating: 0, count: patternWidth)
            for index in 0..<patternWidth {
                patternBytes[index] = UInt8((pattern >> UInt64(index * 8)) & 0xff)
            }

            func writeMappings(_ ramBytes: UnsafeMutableRawBufferPointer) {
                for mapping in mappings {
                    let destination = ramBytes.baseAddress!.advanced(by: mapping.offset)
                    if let first = patternBytes.first,
                       patternBytes.allSatisfy({ $0 == first }) {
                        memset(destination, Int32(first), mapping.byteCount)
                    } else {
                        for byteIndex in 0..<mapping.byteCount {
                            let patternIndex = (mapping.patternOffset + byteIndex) % patternWidth
                            ramBytes[mapping.offset + byteIndex] = patternBytes[patternIndex]
                        }
                    }
                }
            }
            if let ramBytes {
                writeMappings(ramBytes)
            } else {
                vm.memory.withUnsafeMutableBytesWithoutDirtyTracking { ramBytes in
                    writeMappings(ramBytes)
                }
            }
            for mapping in mappings {
                vm.memory.markDirty(
                    at: mapping.physicalAddress,
                    count: mapping.byteCount
                )
                backend.invalidateCodeCache(
                    physicalAddress: mapping.physicalAddress,
                    byteCount: UInt64(mapping.byteCount)
                )
            }
            vm.clearExclusiveReservation()
            return true
        }

        func ramMapping(
            for virtualAddress: GuestAddress,
            width: MMIOWidth,
            access: GuestMemoryAccessKind
        ) throws -> (offset: Int, physicalAddress: GuestAddress)? {
            guard let physicalAddress = try translatedSinglePageAddress(
                virtualAddress,
                width: width,
                access: access
            ) else { return nil }
            guard containsRAM(physicalAddress, width: UInt64(width.rawValue)) else {
                return nil
            }
            return (Int(physicalAddress - ramBase), physicalAddress)
        }

        @inline(__always)
        private func translatedDeviceAddress(
            _ virtualAddress: GuestAddress,
            width: MMIOWidth,
            access: GuestMemoryAccessKind
        ) throws -> GuestAddress? {
            guard let physicalAddress = try translatedSinglePageAddress(
                virtualAddress,
                width: width,
                access: access
            ) else { return nil }
            guard !containsRAM(physicalAddress, width: UInt64(width.rawValue)) else {
                return nil
            }
            return physicalAddress
        }

        private func isPinnedUnsafeDeviceAccess(_ physicalAddress: GuestAddress, width: MMIOWidth) -> Bool {
            guard ramBytes != nil,
                  let device = vm.mmio.device(containing: physicalAddress, width: width) else {
                return false
            }
            return device is VirtualVirtIODevice
        }

        private func shouldBlockPinnedDeviceAccess(_ physicalAddress: GuestAddress, width: MMIOWidth) -> Bool {
            guard ramBytes != nil,
                  !allowDeviceAccessWhileRAMPinned,
                  isPinnedUnsafeDeviceAccess(physicalAddress, width: width) else {
                return false
            }
            blockedPinnedDeviceAccess = true
            return true
        }

        @inline(__always)
        private func translatedSinglePageAddress(
            _ virtualAddress: GuestAddress,
            width: MMIOWidth,
            access: GuestMemoryAccessKind
        ) throws -> GuestAddress? {
            guard !crossesPageBoundary(virtualAddress, width: width) else {
                return nil
            }
            let sctlr = vm.translationSCTLR_EL1
            guard (sctlr & 0x1) != 0 else {
                return virtualAddress
            }

            let pageOffset = virtualAddress & 0xfff
            let virtualPage = virtualAddress & ~UInt64(0xfff)
            let usesTTBR1 = (virtualAddress >> 63) == 1
            let tcr = vm.translationTCR_EL1
            let ttbr = usesTTBR1 ? vm.translationTTBR1_EL1 : vm.translationTTBR0_EL1
            let key = NativePageCacheKey(
                virtualPage: virtualPage,
                access: access.translationCacheDiscriminator,
                exceptionLevel: (currentPStateValue() >> 2) & 0x3,
                sctlr: sctlr,
                tcr: tcr,
                ttbr: ttbr
            )
            if let physicalPage = translatedPageCache.physicalPage(for: key) {
                return physicalPage | pageOffset
            }

            let physicalAddress: GuestAddress
            if ramBytes != nil {
                physicalAddress = try translateAddressUsingPinnedRAM(
                    virtualAddress,
                    access: access,
                    tcr: tcr,
                    ttbr: ttbr
                )
            } else {
                physicalAddress = try vm.translateAddress(virtualAddress, access: access)
            }
            translatedPageCache.store(physicalAddress & ~UInt64(0xfff), for: key)
            return physicalAddress
        }

        private func translateAddressUsingPinnedRAM(
            _ virtualAddress: GuestAddress,
            access: GuestMemoryAccessKind,
            tcr: UInt64,
            ttbr: UInt64
        ) throws -> GuestAddress {
            let usesTTBR1 = (virtualAddress >> 63) == 1
            let sizeOffset = usesTTBR1 ? 16 : 0
            let tsz = Int((tcr >> UInt64(sizeOffset)) & 0x3f)
            let inputAddressSize = 64 - tsz
            guard inputAddressSize > 0, inputAddressSize <= 48 else {
                throw ARM64TranslationFault(
                    virtualAddress: virtualAddress,
                    access: access,
                    level: 0,
                    statusCode: .addressSize(level: 0)
                )
            }

            let tableBase = ttbr & Self.outputAddressMask
            guard tableBase != 0 else {
                throw ARM64TranslationFault(
                    virtualAddress: virtualAddress,
                    access: access,
                    level: 0,
                    statusCode: .translation(level: 0)
                )
            }

            let effectiveVA = virtualAddress & ((UInt64(1) << UInt64(inputAddressSize)) - 1)
            return try walkPinned4KBPageTables(
                virtualAddress: effectiveVA,
                originalVirtualAddress: virtualAddress,
                access: access,
                tableBase: tableBase
            )
        }

        private func walkPinned4KBPageTables(
            virtualAddress: GuestAddress,
            originalVirtualAddress: GuestAddress,
            access: GuestMemoryAccessKind,
            tableBase: GuestAddress
        ) throws -> GuestAddress {
            var currentTable = tableBase

            for level in 0...3 {
                let shift = 39 - (level * 9)
                let index = (virtualAddress >> UInt64(shift)) & 0x1ff
                let descriptorAddress = currentTable + index * 8
                let descriptor: UInt64
                do {
                    descriptor = try readPinnedPhysical64(descriptorAddress)
                } catch {
                    throw ARM64TranslationFault(
                        virtualAddress: originalVirtualAddress,
                        access: access,
                        level: level,
                        statusCode: .translation(level: level)
                    )
                }

                guard (descriptor & 0x1) != 0 else {
                    throw ARM64TranslationFault(
                        virtualAddress: originalVirtualAddress,
                        access: access,
                        level: level,
                        statusCode: .translation(level: level)
                    )
                }

                let descriptorType = descriptor & 0x3
                if level == 3 {
                    guard descriptorType == 0x3 else {
                        throw ARM64TranslationFault(
                            virtualAddress: originalVirtualAddress,
                            access: access,
                            level: level,
                            statusCode: .translation(level: level)
                        )
                    }
                    try validatePinnedLeafAccess(
                        descriptor: descriptor,
                        level: level,
                        originalVirtualAddress: originalVirtualAddress,
                        access: access
                    )
                    return (descriptor & Self.outputAddressMask) | (virtualAddress & 0xfff)
                }

                if descriptorType == 0x1 {
                    let offsetBits = UInt64(39 - (level * 9))
                    let offsetMask = (UInt64(1) << offsetBits) - 1
                    try validatePinnedLeafAccess(
                        descriptor: descriptor,
                        level: level,
                        originalVirtualAddress: originalVirtualAddress,
                        access: access
                    )
                    let outputBase = descriptor & Self.outputAddressMask & ~offsetMask
                    return outputBase | (virtualAddress & offsetMask)
                }

                guard descriptorType == 0x3 else {
                    throw ARM64TranslationFault(
                        virtualAddress: originalVirtualAddress,
                        access: access,
                        level: level,
                        statusCode: .translation(level: level)
                    )
                }
                currentTable = descriptor & Self.outputAddressMask
            }

            throw ARM64TranslationFault(
                virtualAddress: originalVirtualAddress,
                access: access,
                level: 3,
                statusCode: .translation(level: 3)
            )
        }

        private func validatePinnedLeafAccess(
            descriptor: UInt64,
            level: Int,
            originalVirtualAddress: GuestAddress,
            access: GuestMemoryAccessKind
        ) throws {
            if (descriptor & Self.accessFlagBit) == 0 {
                throw ARM64TranslationFault(
                    virtualAddress: originalVirtualAddress,
                    access: access,
                    level: level,
                    statusCode: .accessFlag(level: level)
                )
            }

            if access == .dataWrite, (descriptor & Self.readOnlyAPBit) != 0 {
                throw ARM64TranslationFault(
                    virtualAddress: originalVirtualAddress,
                    access: access,
                    level: level,
                    statusCode: .permission(level: level)
                )
            }

            if access == .instruction {
                let executeNever = ((currentPStateValue() >> 2) & 0x3) == 0
                    ? (descriptor & Self.unprivilegedExecuteNeverBit) != 0
                    : (descriptor & Self.privilegedExecuteNeverBit) != 0
                if executeNever {
                    throw ARM64TranslationFault(
                        virtualAddress: originalVirtualAddress,
                        access: access,
                        level: level,
                        statusCode: .permission(level: level)
                    )
                }
            }
        }

        private func readPinnedPhysical64(_ physicalAddress: GuestAddress) throws -> UInt64 {
            guard let ramBytes,
                  vm.memory.range.contains(physicalAddress, width: 8) else {
                throw VMError.invalidMemoryAccess(address: physicalAddress, width: 8)
            }
            return readBuffer(
                UnsafeRawBufferPointer(ramBytes),
                offset: Int(physicalAddress - vm.memory.base),
                width: .doubleword
            )
        }

        private func currentPStateValue() -> UInt64 {
            currentPStateBox?.value ?? vm.cpu.pstate
        }

        private func crossesPageBoundary(_ virtualAddress: GuestAddress, width: MMIOWidth) -> Bool {
            let byteCount = UInt64(width.rawValue)
            guard byteCount > 1 else {
                return false
            }
            return (virtualAddress & 0xfff) + byteCount > 0x1000
        }
    }

    private struct NativeMemoryStatistics {
        var readHits: UInt64 = 0
        var writeHits: UInt64 = 0
        var readTLBHits: UInt64 = 0
        var readTLBMisses: UInt64 = 0
        var writeTLBHits: UInt64 = 0
        var writeTLBMisses: UInt64 = 0
        var instructionFetchHits: UInt64 = 0
        var instructionTLBHits: UInt64 = 0
        var instructionTLBMisses: UInt64 = 0
        var pageTableWalks: UInt64 = 0
        var pageTableFaults: UInt64 = 0
        var translationCallbackWalks: UInt64 = 0
        var fillHits: UInt64 = 0
        var fillMisses: UInt64 = 0

        init() {}

        init(_ statistics: AVZNativeMemoryFastPathStatistics) {
            readHits = statistics.read_hits
            writeHits = statistics.write_hits
            readTLBHits = statistics.read_tlb_hits
            readTLBMisses = statistics.read_tlb_misses
            writeTLBHits = statistics.write_tlb_hits
            writeTLBMisses = statistics.write_tlb_misses
            instructionFetchHits = statistics.instruction_fetch_hits
            instructionTLBHits = statistics.instruction_tlb_hits
            instructionTLBMisses = statistics.instruction_tlb_misses
            pageTableWalks = statistics.native_page_table_walks
            pageTableFaults = statistics.native_page_table_faults
            translationCallbackWalks = statistics.translation_callback_walks
            fillHits = statistics.fill_hits
            fillMisses = statistics.fill_misses
        }

        func subtracting(_ previous: Self) -> Self {
            var result = Self()
            result.readHits = readHits &- previous.readHits
            result.writeHits = writeHits &- previous.writeHits
            result.readTLBHits = readTLBHits &- previous.readTLBHits
            result.readTLBMisses = readTLBMisses &- previous.readTLBMisses
            result.writeTLBHits = writeTLBHits &- previous.writeTLBHits
            result.writeTLBMisses = writeTLBMisses &- previous.writeTLBMisses
            result.instructionFetchHits = instructionFetchHits &- previous.instructionFetchHits
            result.instructionTLBHits = instructionTLBHits &- previous.instructionTLBHits
            result.instructionTLBMisses = instructionTLBMisses &- previous.instructionTLBMisses
            result.pageTableWalks = pageTableWalks &- previous.pageTableWalks
            result.pageTableFaults = pageTableFaults &- previous.pageTableFaults
            result.translationCallbackWalks = translationCallbackWalks &- previous.translationCallbackWalks
            result.fillHits = fillHits &- previous.fillHits
            result.fillMisses = fillMisses &- previous.fillMisses
            return result
        }
    }

    private final class NativeMemorySession {
        weak var vm: VirtualMachine?
        let pstateBox: NativePStateBox
        let memoryContext: NativeMemoryContext
        let fastPath: OpaquePointer
        private var reportedStatistics = NativeMemoryStatistics()

        init(
            vm: VirtualMachine,
            pstateBox: NativePStateBox,
            memoryContext: NativeMemoryContext,
            fastPath: OpaquePointer
        ) {
            self.vm = vm
            self.pstateBox = pstateBox
            self.memoryContext = memoryContext
            self.fastPath = fastPath
        }

        deinit {
            memoryContext.fastPath = nil
            avz_native_memory_fast_path_destroy(fastPath)
        }

        func takeStatisticsDelta() -> NativeMemoryStatistics {
            let current = NativeMemoryStatistics(
                avz_native_memory_fast_path_statistics(fastPath)
            )
            let delta = current.subtracting(reportedStatistics)
            reportedStatistics = current
            return delta
        }
    }

    private func memorySession(for vm: VirtualMachine) -> NativeMemorySession? {
        if let session = nativeMemorySession, session.vm === vm {
            return session
        }

        nativeMemorySession = nil
        let ramBytes = vm.memory.persistentMutableBytes
        guard let ramBaseAddress = ramBytes.baseAddress else {
            return nil
        }
        let pstateBox = NativePStateBox(vm.cpu.pstate)
        let memoryContext = NativeMemoryContext(
            backend: self,
            vm: vm,
            ramBytes: ramBytes,
            translatedPageCache: NativeTranslatedPageCache(),
            currentPStateBox: pstateBox,
            allowDeviceAccessWhileRAMPinned: true
        )
        let slowContext = Unmanaged.passUnretained(memoryContext).toOpaque()
        guard let fastPath = avz_native_memory_fast_path_create(
            ramBaseAddress.assumingMemoryBound(to: UInt8.self),
            vm.memory.base,
            UInt64(vm.memory.size),
            nativeBlockCache,
            slowContext,
            nativeTranslateRAM,
            nativeReadMemory,
            nativeWriteMemory,
            nativeCanAccessMemory,
            nativeFillMemory,
            nativeReadSystemRegister,
            nativeWriteSystemRegister,
            nativeExecuteSystemInstruction,
            nativeExceptionReturn,
            nativeSynchronousException,
            nativeWait
        ) else {
            return nil
        }
        guard avz_native_memory_fast_path_set_guest_memory(
            fastPath,
            vm.memory.nativeMemoryHandle
        ) != 0 else {
            avz_native_memory_fast_path_destroy(fastPath)
            return nil
        }
        memoryContext.fastPath = fastPath
        avz_native_memory_fast_path_set_instruction_translator(
            fastPath,
            nativeTranslateInstructionRAM
        )
        avz_native_memory_fast_path_set_physical_memory_callbacks(
            fastPath,
            nativeReadPhysicalMemory,
            nativeWritePhysicalMemory
        )
        memoryContext.syncNativeTranslationState()
        let session = NativeMemorySession(
            vm: vm,
            pstateBox: pstateBox,
            memoryContext: memoryContext,
            fastPath: fastPath
        )
        nativeMemorySession = session
        nativeMemorySessionCreations += 1
        return session
    }

    private func recordNativeMemoryStatistics(_ statistics: NativeMemoryStatistics) {
        let readHits = Int(clamping: statistics.readHits)
        let writeHits = Int(clamping: statistics.writeHits)
        fastRAMReadHits += readHits
        nativeFastRAMReadHits += readHits
        fastRAMWriteHits += writeHits
        nativeFastRAMWriteHits += writeHits
        nativeReadTLBHits += Int(clamping: statistics.readTLBHits)
        nativeReadTLBMisses += Int(clamping: statistics.readTLBMisses)
        nativeWriteTLBHits += Int(clamping: statistics.writeTLBHits)
        nativeWriteTLBMisses += Int(clamping: statistics.writeTLBMisses)
        nativeInstructionFetchHits += Int(clamping: statistics.instructionFetchHits)
        nativeInstructionTLBHits += Int(clamping: statistics.instructionTLBHits)
        nativeInstructionTLBMisses += Int(clamping: statistics.instructionTLBMisses)
        nativePageTableWalks += Int(clamping: statistics.pageTableWalks)
        nativePageTableFaults += Int(clamping: statistics.pageTableFaults)
        nativeTranslationCallbackWalks += Int(clamping: statistics.translationCallbackWalks)
        nativeFillHits += Int(clamping: statistics.fillHits)
        nativeFillMisses += Int(clamping: statistics.fillMisses)
    }

    private func canUseDecodedBasicBlocks(_ vm: VirtualMachine) -> Bool {
        enableBasicBlockExecution &&
            vm.traceCapacity == 0 &&
            vm.mmioTraceCapacity == 0 &&
            vm.guestMemoryTraceCapacity == 0 &&
            vm.systemRegisterTraceCapacity == 0 &&
            vm.systemRegisterReadTraceCapacity == 0 &&
            vm.breakpoints.isEmpty &&
            !vm.stopOnEL0Entry &&
            !vm.stopOnEL0Fault &&
            !vm.stopOnUARTOutput &&
            vm.stopOnGuestMemoryWriteVirtualAddress == nil &&
            vm.stopOnGuestMemoryWritePhysicalAddress == nil
    }

    private func nativeStepLimitBeforeTimerDeadline(
        _ vm: VirtualMachine,
        requestedSteps: Int,
        pstate: UInt64? = nil,
        timerStateIsCurrent: Bool = false,
        pendingIRQChecked: Bool = false
    ) -> Int {
        guard requestedSteps > 0 else {
            return 0
        }
        guard vm.timerCyclesPerInstruction > 0 else {
            return requestedSteps
        }

        if !timerStateIsCurrent {
            vm.updateGenericTimerInterruptsIfNeeded()
        }
        let effectivePState = pstate ?? vm.cpu.pstate
        guard pendingIRQChecked ||
                !hasUnmaskedPendingIRQ(vm, pstate: effectivePState) else {
            return 0
        }
        guard let deadline = vm.systemRegisters.nextUnmaskedTimerDeadline else {
            return requestedSteps
        }

        let now = vm.systemRegisters.counterTicks
        guard deadline > now else {
            vm.updateGenericTimerInterruptsIfNeeded(force: true)
            return hasUnmaskedPendingIRQ(vm, pstate: effectivePState) ? 0 : 1
        }

        let cyclesUntilDeadline = deadline &- now
        let cyclesPerInstruction = vm.timerCyclesPerInstruction
        let stepsUntilDeadline = (cyclesUntilDeadline / cyclesPerInstruction) +
            (cyclesUntilDeadline % cyclesPerInstruction == 0 ? 0 : 1)
        let boundedSteps = min(UInt64(Int.max), max(1, stepsUntilDeadline))
        return min(requestedSteps, Int(boundedSteps))
    }

    private func hasUnmaskedPendingIRQ(_ vm: VirtualMachine) -> Bool {
        hasUnmaskedPendingIRQ(vm, pstate: vm.cpu.pstate)
    }

    private func hasUnmaskedPendingIRQ(_ vm: VirtualMachine, pstate: UInt64) -> Bool {
        (pstate & ARM64PState.irqMask) == 0 &&
            vm.interruptController.peekPending(targetVCPU: vm.activeVCPUID) != nil
    }

    @inline(__always)
    private func hasReachedWallClockRunDeadline(
        _ vm: VirtualMachine,
        completedSteps: Int
    ) -> Bool {
        guard let deadline = vm.currentRunDeadlineNanoseconds else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private func advanceTimersAfterNativeExecution(_ vm: VirtualMachine, executedSteps: Int) {
        guard executedSteps > 0, vm.timerCyclesPerInstruction > 0 else {
            return
        }
        vm.systemRegisters.advance(cycles: UInt64(executedSteps) &* vm.timerCyclesPerInstruction)
        vm.updateGenericTimerInterruptsIfNeeded()
    }

    private func basicBlockCacheKey(for vm: VirtualMachine) -> BasicBlockCacheKey {
        basicBlockCacheKey(for: vm, pc: vm.cpu.pc)
    }

    private func basicBlockCacheKey(for vm: VirtualMachine, pc: GuestAddress) -> BasicBlockCacheKey {
        BasicBlockCacheKey(
            pc: pc,
            currentEL: Int((vm.cpu.pstate >> 2) & 0x3),
            sctlrEL1: vm.translationSCTLR_EL1,
            tcrEL1: vm.translationTCR_EL1,
            ttbr0EL1: vm.translationTTBR0_EL1,
            ttbr1EL1: vm.translationTTBR1_EL1
        )
    }

    @inline(__always)
    private func basicBlockCacheKey(
        for vm: VirtualMachine,
        pc: GuestAddress,
        pstate: UInt64
    ) -> BasicBlockCacheKey {
        BasicBlockCacheKey(
            pc: pc,
            currentEL: Int((pstate >> 2) & 0x3),
            sctlrEL1: vm.translationSCTLR_EL1,
            tcrEL1: vm.translationTCR_EL1,
            ttbr0EL1: vm.translationTTBR0_EL1,
            ttbr1EL1: vm.translationTTBR1_EL1
        )
    }

    private func cachedDecodedBasicBlock(for vm: VirtualMachine) throws -> DecodedBasicBlock? {
        let key = basicBlockCacheKey(for: vm)
        return try cachedDecodedBasicBlock(for: vm, key: key)
    }

    private func cachedDecodedBasicBlock(for vm: VirtualMachine, pc: GuestAddress) throws -> DecodedBasicBlock? {
        let key = basicBlockCacheKey(for: vm, pc: pc)
        return try cachedDecodedBasicBlock(for: vm, key: key)
    }

    private func cachedDecodedBasicBlock(for vm: VirtualMachine, key: BasicBlockCacheKey) throws -> DecodedBasicBlock? {
        if let block = decodedBasicBlockFrontCache.block(for: key) {
            if collectCacheStatistics {
                decodedBasicBlockCacheHits &+= 1
            }
            return block
        }
        if let block = decodedBasicBlockCache.block(for: key) {
            decodedBasicBlockFrontCache.store(block)
            if collectCacheStatistics {
                decodedBasicBlockCacheHits &+= 1
            }
            return block
        }

        guard let block = try decodeBasicBlock(for: vm, key: key) else {
            return nil
        }
        if let evicted = decodedBasicBlockCache.store(block) {
            unindexCodePages(for: evicted)
            decodedBasicBlockFrontCache.clear()
        }
        decodedBasicBlockFrontCache.store(block)
        indexCodePages(for: block)
        if collectCacheStatistics {
            decodedBasicBlockCacheMisses &+= 1
        }
        return block
    }

    @inline(__always)
    private func cachedDecodedBasicBlock(
        for vm: VirtualMachine,
        key: BasicBlockCacheKey,
        memoryContext: NativeMemoryContext
    ) throws -> DecodedBasicBlock? {
        if let block = decodedBasicBlockFrontCache.block(for: key) {
            if collectCacheStatistics {
                decodedBasicBlockCacheHits &+= 1
            }
            return block
        }
        if let block = decodedBasicBlockCache.block(for: key) {
            decodedBasicBlockFrontCache.store(block)
            if collectCacheStatistics {
                decodedBasicBlockCacheHits &+= 1
            }
            return block
        }

        guard let block = try decodeBasicBlock(for: vm, key: key, memoryContext: memoryContext) else {
            return nil
        }
        if let evicted = decodedBasicBlockCache.store(block) {
            unindexCodePages(for: evicted)
            decodedBasicBlockFrontCache.clear()
        }
        decodedBasicBlockFrontCache.store(block)
        indexCodePages(for: block)
        if collectCacheStatistics {
            decodedBasicBlockCacheMisses &+= 1
        }
        return block
    }

    private func decodeBasicBlock(for vm: VirtualMachine, key: BasicBlockCacheKey) throws -> DecodedBasicBlock? {
        let scratch = decodeScratch
        var instructionCount = 0
        var nativeEligible = true
        var usesVectorState = false
        var pc = key.pc
        var sequentialPhysicalPC: GuestAddress?

        for _ in 0..<maxBasicBlockInstructions {
            if instructionCount > 0,
               (instructionCount & 15) == 0,
               hasReachedWallClockRunDeadline(vm, completedSteps: instructionCount) {
                break
            }
            let physicalPC: GuestAddress
            let instruction: UInt32
            do {
                if let hintedPhysicalPC = sequentialPhysicalPC,
                   (pc & 0xfff) != 0 {
                    physicalPC = hintedPhysicalPC
                } else {
                    physicalPC = try vm.translateAddress(pc, access: .instruction)
                }
                instruction = UInt32(truncatingIfNeeded: try vm.readPhysical(physicalPC, width: .word))
            } catch is ARM64TranslationFault {
                return nil
            }
            sequentialPhysicalPC = physicalPC &+ 4

            guard let decoded = cachedDecodedInstruction(for: instruction) else {
                break
            }
            guard decoded.isBasicBlockEligible else {
                break
            }
            let cachedNative = cachedNativeInstruction(for: instruction)
            let nativeInstruction = cachedNative.nativeInstruction
            let nativeDecoded = cachedNative.supported
            if !nativeDecoded {
                nativeIneligibleGadgetCounts[basicBlockInstructionName(for: instruction), default: 0] += 1
                if instructionCount > 0 {
                    break
                }
            }
            nativeEligible = nativeEligible && nativeDecoded
            usesVectorState = usesVectorState || nativeInstructionUsesVectorState(nativeInstruction.kind)

            scratch.storeInstruction(DecodedBlockInstruction(
                pc: pc,
                instruction: instruction,
                decoded: decoded
            ), at: instructionCount)
            scratch.storeNativeInstruction(nativeInstruction, at: instructionCount)
            scratch.storePhysicalRange(CodeCachePhysicalRange(
                start: physicalPC,
                end: physicalPC + 4
            ), at: instructionCount)
            instructionCount += 1
            if !nativeDecoded || basicBlockTerminates(for: decoded) {
                break
            }
            pc += 4
        }

        guard instructionCount > 0 else {
            return nil
        }
        return DecodedBasicBlock(
            key: key,
            instructions: scratch.decodedInstructionsPrefix(count: instructionCount),
            nativeInstructions: scratch.nativeInstructionsPrefix(count: instructionCount),
            physicalRanges: coalescedCodeRanges(scratch.physicalRangeBuffer(count: instructionCount)),
            nativeEligible: nativeEligible,
            usesVectorState: usesVectorState
        )
    }

    private func decodeBasicBlock(
        for vm: VirtualMachine,
        key: BasicBlockCacheKey,
        memoryContext: NativeMemoryContext
    ) throws -> DecodedBasicBlock? {
        let scratch = decodeScratch
        var instructionCount = 0
        var nativeEligible = true
        var usesVectorState = false
        var pc = key.pc
        var sequentialPhysicalPC: GuestAddress?

        for _ in 0..<maxBasicBlockInstructions {
            if instructionCount > 0,
               (instructionCount & 15) == 0,
               hasReachedWallClockRunDeadline(vm, completedSteps: instructionCount) {
                break
            }
            let fetchedInstruction: (physicalPC: GuestAddress, instruction: UInt32)
            do {
                guard let fetched = try memoryContext.fetchInstruction(
                    at: pc,
                    physicalAddressHint: sequentialPhysicalPC
                ) else {
                    return nil
                }
                fetchedInstruction = fetched
            } catch is ARM64TranslationFault {
                return nil
            }
            sequentialPhysicalPC = fetchedInstruction.physicalPC &+ 4

            guard let decoded = cachedDecodedInstruction(for: fetchedInstruction.instruction) else {
                break
            }
            guard decoded.isBasicBlockEligible else {
                break
            }
            let cachedNative = cachedNativeInstruction(for: fetchedInstruction.instruction)
            let nativeInstruction = cachedNative.nativeInstruction
            let nativeDecoded = cachedNative.supported
            if !nativeDecoded {
                nativeIneligibleGadgetCounts[basicBlockInstructionName(for: fetchedInstruction.instruction), default: 0] += 1
                if instructionCount > 0 {
                    break
                }
            }
            nativeEligible = nativeEligible && nativeDecoded
            usesVectorState = usesVectorState || nativeInstructionUsesVectorState(nativeInstruction.kind)

            scratch.storeInstruction(DecodedBlockInstruction(
                pc: pc,
                instruction: fetchedInstruction.instruction,
                decoded: decoded
            ), at: instructionCount)
            scratch.storeNativeInstruction(nativeInstruction, at: instructionCount)
            scratch.storePhysicalRange(CodeCachePhysicalRange(
                start: fetchedInstruction.physicalPC,
                end: fetchedInstruction.physicalPC + 4
            ), at: instructionCount)
            instructionCount += 1
            if !nativeDecoded || basicBlockTerminates(for: decoded) {
                break
            }
            pc += 4
        }

        guard instructionCount > 0 else {
            return nil
        }

        return DecodedBasicBlock(
            key: key,
            instructions: scratch.decodedInstructionsPrefix(count: instructionCount),
            nativeInstructions: scratch.nativeInstructionsPrefix(count: instructionCount),
            physicalRanges: coalescedCodeRanges(scratch.physicalRangeBuffer(count: instructionCount)),
            nativeEligible: nativeEligible,
            usesVectorState: usesVectorState
        )
    }

    private func nativeInstructionUsesVectorState(_ kind: UInt16) -> Bool {
        switch Int(kind) {
        case AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL,
             AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE,
             AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE,
             AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE,
             AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE,
             AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR,
             AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP,
             AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC,
             AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD,
             AVZ_NATIVE_OP_FP_SCALAR_UNARY,
             AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE,
             AVZ_NATIVE_OP_FP_RECIPROCAL_STEP,
             AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE,
             AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE,
             AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY,
             AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG,
             AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD,
             AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE,
             AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL,
             AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE,
             AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG,
             AVZ_NATIVE_OP_SIMD_NARROW_HIGH,
             AVZ_NATIVE_OP_SIMD_BITWISE_NOT,
             AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT,
             AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT,
             AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_SELECT,
             AVZ_NATIVE_OP_FP_SCALAR_COMPARE,
             AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER,
             AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER,
             AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION,
             AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP,
             AVZ_NATIVE_OP_SIMD_INSERT_GENERAL_TO_ELEMENT,
             AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D,
             AVZ_NATIVE_OP_SIMD_TABLE_LOOKUP,
             AVZ_NATIVE_OP_SIMD_PERMUTE_TWO_VECTOR,
             AVZ_NATIVE_OP_SIMD_ADD_VECTOR,
             AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR,
             AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS,
             AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS,
             AVZ_NATIVE_OP_SIMD_ORR_VECTOR,
             AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL,
             AVZ_NATIVE_OP_SIMD_MOVI_ZERO,
             AVZ_NATIVE_OP_SIMD_MOVI_BYTE,
             AVZ_NATIVE_OP_SIMD_MVNI_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_MOVI_D_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET,
             AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE,
             AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE,
             AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT,
             AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE,
             AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR,
             AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER,
             AVZ_NATIVE_OP_FP_SCALAR_MINMAX,
             AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX,
             AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS,
             AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR:
            return true
        default:
            return false
        }
    }

    private func coalescedCodeRanges(_ ranges: [CodeCachePhysicalRange]) -> [CodeCachePhysicalRange] {
        guard !ranges.isEmpty else {
            return []
        }

        let sorted = ranges.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        var coalesced: [CodeCachePhysicalRange] = []
        for range in sorted {
            guard let last = coalesced.last else {
                coalesced.append(range)
                continue
            }
            if range.start <= last.end {
                coalesced[coalesced.count - 1] = CodeCachePhysicalRange(
                    start: last.start,
                    end: max(last.end, range.end)
                )
            } else {
                coalesced.append(range)
            }
        }
        return coalesced
    }

    private func coalescedCodeRanges(
        _ ranges: UnsafeBufferPointer<CodeCachePhysicalRange>
    ) -> [CodeCachePhysicalRange] {
        guard !ranges.isEmpty else {
            return []
        }

        var coalesced: [CodeCachePhysicalRange] = []
        coalesced.reserveCapacity(min(ranges.count, 4))
        for range in ranges {
            guard let last = coalesced.last else {
                coalesced.append(range)
                continue
            }
            if range.start <= last.end {
                coalesced[coalesced.count - 1] = CodeCachePhysicalRange(
                    start: last.start,
                    end: max(last.end, range.end)
                )
            } else {
                coalesced.append(range)
            }
        }
        return coalesced
    }

    private func executeNativeBasicBlockBurst(
        _ vm: VirtualMachine,
        maxSteps: Int
    ) throws -> NativeBasicBlockExecutionOutcome? {
        guard maxSteps > 0,
              !hasUnmaskedPendingIRQ(vm),
              (vm.translationSCTLR_EL1 & 0x1) != 0 else {
            return nil
        }

        var registers = vm.cpu.x
        var vectorLows = vm.cpu.v.map(\.low)
        var vectorHighs = vm.cpu.v.map(\.high)
        var sp = vm.cpu.sp
        var pc = vm.cpu.pc
        var pstate = vm.cpu.pstate
        var halted: UInt8 = vm.cpu.halted ? 1 : 0
        var exclusiveAddress = vm.cpu.exclusiveReservationAddress ?? 0
        var exclusiveSize = UInt8(vm.cpu.exclusiveReservationSize ?? 0)
        var exclusiveValid: UInt8 = vm.cpu.exclusiveReservationAddress == nil ? 0 : 1

        let outcome = try executeNativeBasicBlockBurstLoop(
            vm,
            maxSteps: maxSteps,
            registers: &registers,
            vectorLows: &vectorLows,
            vectorHighs: &vectorHighs,
            sp: &sp,
            pc: &pc,
            pstate: &pstate,
            exclusiveAddress: &exclusiveAddress,
            exclusiveSize: &exclusiveSize,
            exclusiveValid: &exclusiveValid,
            halted: &halted
        )

        guard let outcome else {
            return nil
        }
        vm.cpu.x = registers
        for index in vm.cpu.v.indices {
            vm.cpu.v[index] = ARM64VectorRegister(low: vectorLows[index], high: vectorHighs[index])
        }
        vm.cpu.sp = sp
        vm.cpu.pc = pc
        vm.cpu.pstate = pstate
        if exclusiveValid != 0 {
            vm.cpu.exclusiveReservationAddress = exclusiveAddress
            vm.cpu.exclusiveReservationSize = Int(exclusiveSize)
        } else {
            vm.cpu.exclusiveReservationAddress = nil
            vm.cpu.exclusiveReservationSize = nil
        }
        vm.cpu.halted = halted != 0
        if let fault = outcome.translationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: vm.cpu.pc)
        }
        routePendingIRQIfNeeded(vm)
        return outcome
    }

    private func executeNativeBasicBlockBurstLoop(
        _ vm: VirtualMachine,
        maxSteps: Int,
        registers: inout [UInt64],
        vectorLows: inout [UInt64],
        vectorHighs: inout [UInt64],
        sp: inout UInt64,
        pc: inout UInt64,
        pstate: inout UInt64,
        exclusiveAddress: inout UInt64,
        exclusiveSize: inout UInt8,
        exclusiveValid: inout UInt8,
        halted: inout UInt8
    ) throws -> NativeBasicBlockExecutionOutcome? {
        enum NativeBurstLoopResult {
            case yielded
            case blockedPinnedDeviceAccess
        }

        var totalSteps = 0
        let hostPreemptionGeneration = vm.hostPreemptionGenerationProvider?()
        var nextDeadlineCheckStep = 4_096
        var stopReason: RunStopReason?
        var unsupportedInstruction: UInt32?
        var translationFault: ARM64TranslationFault?
        var livePState = pstate
        guard let memorySession = memorySession(for: vm) else {
            return nil
        }
        let pstateBox = memorySession.pstateBox
        pstateBox.value = livePState
        let memoryContext = memorySession.memoryContext
        memoryContext.resetTransientState()
        memoryContext.syncNativeTranslationState()
        let fastMemoryContext = memorySession.fastPath
        var threadRegisters = AVZNativeThreadRegisterState(
            tpidr_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.tpidrEL0),
            tpidrro_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.tpidrroEL0),
            tpidr_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.tpidrEL1),
            contextidr_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.contextidrEL1),
            dirty_mask: 0
        )
        avz_native_memory_fast_path_set_thread_registers(
            fastMemoryContext,
            &threadRegisters
        )
        let initialSPUsesEL0 = CPUState.stackPointerBank(for: livePState) == .spEL0
        var architecturalState = AVZNativeArchitecturalState(
            sp_el0: initialSPUsesEL0
                ? sp
                : vm.systemRegisters.rawValue(for: ARM64SystemRegister.spEL0),
            sp_el1: initialSPUsesEL0 ? vm.cpu.spEL1 : sp,
            spsr_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.spsrEL1),
            elr_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.elrEL1),
            esr_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.esrEL1),
            far_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.farEL1),
            vbar_el1: vm.systemRegisters.rawValue(for: ARM64SystemRegister.vbarEL1),
            counter_ticks: vm.systemRegisters.counterTicks,
            cntp_ctl_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntpCtlEL0),
            cntp_cval_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntpCvalEL0),
            cntv_ctl_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntvCtlEL0),
            cntv_cval_el0: vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntvCvalEL0),
            timer_cycles_per_instruction: vm.timerCyclesPerInstruction,
            dirty_mask: 0,
            pending_irq: vm.interruptController.peekPending(targetVCPU: vm.activeVCPUID) == nil ? 0 : 1
        )
        avz_native_memory_fast_path_set_architectural_state(
            fastMemoryContext,
            &architecturalState
        )
        defer {
            recordNativeMemoryStatistics(memorySession.takeStatisticsDelta())
            avz_native_memory_fast_path_get_thread_registers(
                fastMemoryContext,
                &threadRegisters
            )
            let dirtyMask = threadRegisters.dirty_mask
            if dirtyMask & UInt32(AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL0) != 0 {
                vm.systemRegisters.writeRaw(
                    ARM64SystemRegister.tpidrEL0,
                    value: threadRegisters.tpidr_el0
                )
            }
            if dirtyMask & UInt32(AVZ_NATIVE_THREAD_REGISTER_TPIDRRO_EL0) != 0 {
                vm.systemRegisters.writeRaw(
                    ARM64SystemRegister.tpidrroEL0,
                    value: threadRegisters.tpidrro_el0
                )
            }
            if dirtyMask & UInt32(AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL1) != 0 {
                vm.systemRegisters.writeRaw(
                    ARM64SystemRegister.tpidrEL1,
                    value: threadRegisters.tpidr_el1
                )
            }
            if dirtyMask & UInt32(AVZ_NATIVE_THREAD_REGISTER_CONTEXTIDR_EL1) != 0 {
                vm.systemRegisters.writeRaw(
                    ARM64SystemRegister.contextidrEL1,
                    value: threadRegisters.contextidr_el1
                )
            }
            avz_native_memory_fast_path_get_architectural_state(
                fastMemoryContext,
                &architecturalState
            )
            let architecturalDirtyMask = architecturalState.dirty_mask
            if architecturalDirtyMask & UInt32(AVZ_NATIVE_ARCH_SP_EL0) != 0 {
                vm.systemRegisters.writeRaw(
                    ARM64SystemRegister.spEL0,
                    value: architecturalState.sp_el0
                )
            }
            if architecturalDirtyMask & UInt32(AVZ_NATIVE_ARCH_SP_EL1) != 0 {
                vm.cpu.spEL1 = architecturalState.sp_el1
            }
            let architecturalRegisters: [(UInt32, ARM64SystemRegisterKey, UInt64)] = [
                (UInt32(AVZ_NATIVE_ARCH_SPSR_EL1), ARM64SystemRegister.spsrEL1, architecturalState.spsr_el1),
                (UInt32(AVZ_NATIVE_ARCH_ELR_EL1), ARM64SystemRegister.elrEL1, architecturalState.elr_el1),
                (UInt32(AVZ_NATIVE_ARCH_ESR_EL1), ARM64SystemRegister.esrEL1, architecturalState.esr_el1),
                (UInt32(AVZ_NATIVE_ARCH_FAR_EL1), ARM64SystemRegister.farEL1, architecturalState.far_el1),
                (UInt32(AVZ_NATIVE_ARCH_VBAR_EL1), ARM64SystemRegister.vbarEL1, architecturalState.vbar_el1),
                (UInt32(AVZ_NATIVE_ARCH_CNTP_CTL_EL0), ARM64SystemRegister.cntpCtlEL0, architecturalState.cntp_ctl_el0),
                (UInt32(AVZ_NATIVE_ARCH_CNTP_CVAL_EL0), ARM64SystemRegister.cntpCvalEL0, architecturalState.cntp_cval_el0),
                (UInt32(AVZ_NATIVE_ARCH_CNTV_CTL_EL0), ARM64SystemRegister.cntvCtlEL0, architecturalState.cntv_ctl_el0),
                (UInt32(AVZ_NATIVE_ARCH_CNTV_CVAL_EL0), ARM64SystemRegister.cntvCvalEL0, architecturalState.cntv_cval_el0)
            ]
            for (mask, register, value) in architecturalRegisters
                where architecturalDirtyMask & mask != 0 {
                vm.systemRegisters.writeRaw(register, value: value)
            }
            vm.systemRegisters.synchronizeCounterTicks(architecturalState.counter_ticks)
            vm.updateGenericTimerInterruptsIfNeeded(force: true)
        }
        guard let nativeExecutionContext else {
            return nil
        }
        var fpcr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpcr)
        var fpsr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr)
        registers.withUnsafeBufferPointer { registerBuffer in
            vectorLows.withUnsafeBufferPointer { lowBuffer in
                vectorHighs.withUnsafeBufferPointer { highBuffer in
                    avz_native_execution_context_load(
                        nativeExecutionContext,
                        registerBuffer.baseAddress,
                        lowBuffer.baseAddress,
                        highBuffer.baseAddress,
                        sp,
                        pc,
                        livePState,
                        fpcr,
                        fpsr,
                        exclusiveAddress,
                        exclusiveSize,
                        exclusiveValid,
                        halted
                    )
                }
            }
        }
        nativeBurstLoop: while totalSteps < maxSteps {
            let loopResult: NativeBurstLoopResult = {
                defer {
                    registers.withUnsafeMutableBufferPointer { registerBuffer in
                        vectorLows.withUnsafeMutableBufferPointer { lowBuffer in
                            vectorHighs.withUnsafeMutableBufferPointer { highBuffer in
                                avz_native_execution_context_store(
                                    nativeExecutionContext,
                                    registerBuffer.baseAddress,
                                    lowBuffer.baseAddress,
                                    highBuffer.baseAddress,
                                    &sp,
                                    &pc,
                                    &livePState,
                                    &fpcr,
                                    &fpsr,
                                    &exclusiveAddress,
                                    &exclusiveSize,
                                    &exclusiveValid,
                                    &halted
                                )
                            }
                        }
                    }
                }

                while totalSteps < maxSteps {
                    if avz_native_execution_context_halted(nativeExecutionContext) != 0 {
                        stopReason = .halted
                        return NativeBurstLoopResult.yielded
                    }
                    let residentPState = avz_native_execution_context_pstate(nativeExecutionContext)
                    guard !hasUnmaskedPendingIRQ(vm, pstate: residentPState) else {
                        return NativeBurstLoopResult.yielded
                    }

                    var blockKey = AVZNativeBlockKey(
                        pc: 0,
                        sctlr_el1: vm.translationSCTLR_EL1,
                        tcr_el1: vm.translationTCR_EL1,
                        ttbr0_el1: vm.translationTTBR0_EL1,
                        ttbr1_el1: vm.translationTTBR1_EL1,
                        current_el: UInt8((residentPState >> 2) & 0x3)
                    )
                    let nativeStepLimit = nativeStepLimitBeforeTimerDeadline(
                        vm,
                        requestedSteps: min(maxSteps - totalSteps, 16_384),
                        pstate: residentPState
                    )
                    guard nativeStepLimit > 0 else {
                        return NativeBurstLoopResult.yielded
                    }

                    memoryContext.resetTransientState()
                    pstateBox.value = residentPState
                    memoryContext.syncNativeTranslationState()
                    let checkpoint = NativeChainCheckpointContext(
                        backend: self,
                        vm: vm,
                        memoryContext: memoryContext,
                        pstateBox: pstateBox,
                        maxSteps: maxSteps,
                        totalSteps: totalSteps,
                        nextDeadlineCheckStep: nextDeadlineCheckStep,
                        hostPreemptionGeneration: hostPreemptionGeneration
                    )
                    let nativeStart = collectPerformanceTimings ? DispatchTime.now().uptimeNanoseconds : 0
                    let result = avz_native_execution_context_run_cached_chain_checkpointed(
                        nativeExecutionContext,
                        nativeBlockCache,
                        &blockKey,
                        UInt64(nativeStepLimit),
                        UInt64(maxSteps - totalSteps),
                        nativeChainBlockLimit,
                        max(1, vm.nativeCheckpointBlockInterval),
                        nativeChainCheckpoint,
                        Unmanaged.passUnretained(checkpoint).toOpaque(),
                        avz_native_fast_fetch_instruction,
                        UnsafeMutableRawPointer(fastMemoryContext),
                        avz_native_fast_memory_read,
                        avz_native_fast_memory_write,
                        avz_native_fast_memory_can_access,
                        avz_native_fast_memory_fill,
                        avz_native_fast_read_system_register,
                        avz_native_fast_write_system_register,
                        avz_native_fast_execute_system_instruction,
                        avz_native_fast_exception_return,
                        avz_native_fast_synchronous_exception,
                        avz_native_fast_wait,
                        UnsafeMutableRawPointer(fastMemoryContext)
                    )
                    if collectPerformanceTimings {
                        nativeBasicBlockNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- nativeStart
                    }
                    nativeDirectLinkHits += Int(clamping: result.direct_link_hits)
                    nativeDirectLinkMisses += Int(clamping: result.direct_link_misses)
                    nativeSuperblockHits += Int(clamping: result.superblock_hits)
                    nativeSuperblockFrontHits += Int(clamping: result.superblock_front_hits)
                    nativeSuperblockBlocks += Int(clamping: result.superblock_blocks)
                    nativeSuperblockDispatches += Int(clamping: result.superblock_dispatches)
                    nativeGenericDispatches += Int(clamping: result.generic_dispatches)
                    nativeSemanticFastPathSteps += Int(clamping: result.fast_path_steps)
                    nativeSemanticFastPathHits += Int(clamping: result.fast_path_hits)

                    totalSteps = checkpoint.totalSteps
                    nextDeadlineCheckStep = checkpoint.nextDeadlineCheckStep
                    stopReason = checkpoint.stopReason
                    translationFault = checkpoint.translationFault ?? memoryContext.translationFault
                    if checkpoint.blockedPinnedDeviceAccess {
                        return NativeBurstLoopResult.blockedPinnedDeviceAccess
                    }
                    if translationFault != nil {
                        return NativeBurstLoopResult.yielded
                    }
                    if result.blocks == 0, let fault = memoryContext.translationFault {
                        translationFault = fault
                        return NativeBurstLoopResult.yielded
                    }
                    if translationFault == nil &&
                        result.status == UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED) {
                        nativeBasicBlockUnsupportedExits += 1
                        if result.unsupported_instruction != 0 {
                            unsupportedInstruction = result.unsupported_instruction
                            if result.decode_status == UInt32(AVZ_NATIVE_BLOCK_DECODE_UNSUPPORTED) {
                                nativeIneligibleGadgetCounts[
                                    basicBlockInstructionName(for: result.unsupported_instruction),
                                    default: 0
                                ] += 1
                            }
                        }
                        return NativeBurstLoopResult.yielded
                    }
                    if result.status == UInt32(AVZ_NATIVE_STATUS_HALTED) {
                        stopReason = .halted
                        return NativeBurstLoopResult.yielded
                    }
                    if result.status == UInt32(AVZ_NATIVE_STATUS_YIELDED) {
                        stopReason = .yielded
                        return NativeBurstLoopResult.yielded
                    }
                    if checkpoint.shouldYield || result.steps == 0 {
                        return NativeBurstLoopResult.yielded
                    }
                }

                return NativeBurstLoopResult.yielded
            }()

            switch loopResult {
            case .yielded:
                break nativeBurstLoop

            case .blockedPinnedDeviceAccess:
                nativePinnedDeviceSingleInstructionSteps += 1
                storeNativeCPUState(
                    vm,
                    registers: registers,
                    vectorLows: vectorLows,
                    vectorHighs: vectorHighs,
                    sp: sp,
                    pc: pc,
                    pstate: livePState,
                    exclusiveAddress: exclusiveAddress,
                    exclusiveSize: exclusiveSize,
                    exclusiveValid: exclusiveValid,
                    halted: halted
                )
                let singleStepStop: RunStopReason?
                do {
                    singleStepStop = try executeSingleInstructionCycle(vm, stepNumber: totalSteps + 1)
                } catch {
                    recordUnsupportedInstruction(from: error)
                    throw error
                }
                totalSteps += 1
                loadNativeCPUState(
                    from: vm,
                    registers: &registers,
                    vectorLows: &vectorLows,
                    vectorHighs: &vectorHighs,
                    sp: &sp,
                    pc: &pc,
                    pstate: &livePState,
                    exclusiveAddress: &exclusiveAddress,
                    exclusiveSize: &exclusiveSize,
                    exclusiveValid: &exclusiveValid,
                    halted: &halted
                )
                pstateBox.value = livePState
                registers.withUnsafeBufferPointer { registerBuffer in
                    vectorLows.withUnsafeBufferPointer { lowBuffer in
                        vectorHighs.withUnsafeBufferPointer { highBuffer in
                            avz_native_execution_context_load(
                                nativeExecutionContext,
                                registerBuffer.baseAddress,
                                lowBuffer.baseAddress,
                                highBuffer.baseAddress,
                                sp,
                                pc,
                                livePState,
                                fpcr,
                                fpsr,
                                exclusiveAddress,
                                exclusiveSize,
                                exclusiveValid,
                                halted
                            )
                        }
                    }
                }
                if let singleStepStop {
                    stopReason = singleStepStop
                    break nativeBurstLoop
                }
                if totalSteps >= nextDeadlineCheckStep {
                    nextDeadlineCheckStep = totalSteps + 64
                    if hasReachedWallClockRunDeadline(vm, completedSteps: totalSteps) {
                        break nativeBurstLoop
                    }
                }
            }
        }

        vm.systemRegisters.writeRaw(ARM64SystemRegister.fpcr, value: fpcr)
        vm.systemRegisters.writeRaw(ARM64SystemRegister.fpsr, value: fpsr)
        pstate = livePState
        guard totalSteps > 0 else {
            return nil
        }
        return NativeBasicBlockExecutionOutcome(
            steps: totalSteps,
            stopReason: stopReason,
            shouldContinue: stopReason == nil,
            unsupportedInstruction: unsupportedInstruction,
            translationFault: translationFault
        )
    }

    private func storeNativeCPUState(
        _ vm: VirtualMachine,
        registers: [UInt64],
        vectorLows: [UInt64],
        vectorHighs: [UInt64],
        sp: UInt64,
        pc: UInt64,
        pstate: UInt64,
        exclusiveAddress: UInt64,
        exclusiveSize: UInt8,
        exclusiveValid: UInt8,
        halted: UInt8
    ) {
        vm.cpu.x = registers
        for index in vm.cpu.v.indices {
            vm.cpu.v[index] = ARM64VectorRegister(low: vectorLows[index], high: vectorHighs[index])
        }
        vm.cpu.sp = sp
        vm.cpu.pc = pc
        vm.cpu.pstate = pstate
        if exclusiveValid != 0 {
            vm.cpu.exclusiveReservationAddress = exclusiveAddress
            vm.cpu.exclusiveReservationSize = Int(exclusiveSize)
        } else {
            vm.cpu.exclusiveReservationAddress = nil
            vm.cpu.exclusiveReservationSize = nil
        }
        vm.cpu.halted = halted != 0
    }

    private func loadNativeCPUState(
        from vm: VirtualMachine,
        registers: inout [UInt64],
        vectorLows: inout [UInt64],
        vectorHighs: inout [UInt64],
        sp: inout UInt64,
        pc: inout UInt64,
        pstate: inout UInt64,
        exclusiveAddress: inout UInt64,
        exclusiveSize: inout UInt8,
        exclusiveValid: inout UInt8,
        halted: inout UInt8
    ) {
        registers = vm.cpu.x
        vectorLows = vm.cpu.v.map(\.low)
        vectorHighs = vm.cpu.v.map(\.high)
        sp = vm.cpu.sp
        pc = vm.cpu.pc
        pstate = vm.cpu.pstate
        if let reservedAddress = vm.cpu.exclusiveReservationAddress,
           let reservedSize = vm.cpu.exclusiveReservationSize {
            exclusiveAddress = reservedAddress
            exclusiveSize = UInt8(reservedSize)
            exclusiveValid = 1
        } else {
            exclusiveAddress = 0
            exclusiveSize = 0
            exclusiveValid = 0
        }
        halted = vm.cpu.halted ? 1 : 0
    }

    private func executeNativeBasicBlockIfPossible(
        _ block: DecodedBasicBlock,
        vm: VirtualMachine,
        maxSteps: Int
    ) -> NativeBasicBlockExecutionOutcome? {
        guard maxSteps > 0,
              block.nativeEligible,
              vm.cpu.pc == block.key.pc,
              !hasUnmaskedPendingIRQ(vm) else {
            return nil
        }

        var registers = vm.cpu.x
        var vectorLows = vm.cpu.v.map(\.low)
        var vectorHighs = vm.cpu.v.map(\.high)
        var sp = vm.cpu.sp
        var pc = vm.cpu.pc
        var pstate = vm.cpu.pstate
        var halted: UInt8 = vm.cpu.halted ? 1 : 0
        var exclusiveAddress = vm.cpu.exclusiveReservationAddress ?? 0
        var exclusiveSize = UInt8(vm.cpu.exclusiveReservationSize ?? 0)
        var exclusiveValid: UInt8 = vm.cpu.exclusiveReservationAddress == nil ? 0 : 1
        let nativeStepLimit = nativeStepLimitBeforeTimerDeadline(vm, requestedSteps: maxSteps)
        guard nativeStepLimit > 0 else {
            return nil
        }

        let nativeStart = collectPerformanceTimings ? DispatchTime.now().uptimeNanoseconds : 0
        let memoryContext = NativeMemoryContext(
            backend: self,
            vm: vm,
            ramBytes: nil,
            translatedPageCache: NativeTranslatedPageCache()
        )
        let result = block.nativeInstructions.withUnsafeBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                runNativeDecodedBlock(
                    instructions: instructionBuffer,
                    basePC: block.key.pc,
                    maxSteps: nativeStepLimit,
                    registers: registerBuffer,
                    vectorLows: &vectorLows,
                    vectorHighs: &vectorHighs,
                    usesVectorState: block.usesVectorState,
                    sp: &sp,
                    pc: &pc,
                    pstate: &pstate,
                    exclusiveAddress: &exclusiveAddress,
                    exclusiveSize: &exclusiveSize,
                    exclusiveValid: &exclusiveValid,
                    halted: &halted,
                    memoryContext: memoryContext
                )
            }
        }
        if collectPerformanceTimings {
            nativeBasicBlockNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- nativeStart
        }

        let executedSteps = Int(result.steps)
        let nativeTranslationFault = memoryContext.translationFault
        let accountedSteps = executedSteps + (nativeTranslationFault == nil ? 0 : 1)
        guard accountedSteps > 0 else {
            if result.status == AVZ_NATIVE_STATUS_UNSUPPORTED {
                nativeBasicBlockUnsupportedExits += 1
                if result.unsupported_instruction != 0 {
                    recordUnsupportedInstruction(result.unsupported_instruction)
                }
            }
            return nil
        }

        vm.cpu.x = registers
        for index in vm.cpu.v.indices {
            vm.cpu.v[index] = ARM64VectorRegister(low: vectorLows[index], high: vectorHighs[index])
        }
        vm.cpu.sp = sp
        vm.cpu.pc = pc
        vm.cpu.pstate = pstate
        if exclusiveValid != 0 {
            vm.cpu.exclusiveReservationAddress = exclusiveAddress
            vm.cpu.exclusiveReservationSize = Int(exclusiveSize)
        } else {
            vm.cpu.exclusiveReservationAddress = nil
            vm.cpu.exclusiveReservationSize = nil
        }
        vm.cpu.halted = halted != 0
        if let nativeTranslationFault {
            routeTranslationFault(vm, fault: nativeTranslationFault, returnAddress: vm.cpu.pc)
        }
        advanceTimersAfterNativeExecution(vm, executedSteps: accountedSteps)
        routePendingIRQIfNeeded(vm)
        nativeBasicBlockExecutions += 1
        nativeBasicBlockSteps += accountedSteps
        let unsupportedInstruction = nativeTranslationFault == nil &&
            result.status == UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED) &&
            result.unsupported_instruction != 0
            ? result.unsupported_instruction
            : nil

        if let requestedStop = vm.requestedStopReason {
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: requestedStop,
                shouldContinue: false,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nativeTranslationFault
            )
        }

        if let nativeTranslationFault {
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: nil,
                shouldContinue: true,
                unsupportedInstruction: nil,
                translationFault: nativeTranslationFault
            )
        }

        switch result.status {
        case UInt32(AVZ_NATIVE_STATUS_HALTED):
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: .halted,
                shouldContinue: false,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nil
            )
        case UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED):
            nativeBasicBlockUnsupportedExits += 1
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: nil,
                shouldContinue: true,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nil
            )
        case UInt32(AVZ_NATIVE_STATUS_MAX_STEPS):
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: nil,
                shouldContinue: true,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nil
            )
        case UInt32(AVZ_NATIVE_STATUS_YIELDED):
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: .yielded,
                shouldContinue: false,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nil
            )
        default:
            return NativeBasicBlockExecutionOutcome(
                steps: accountedSteps,
                stopReason: nil,
                shouldContinue: true,
                unsupportedInstruction: unsupportedInstruction,
                translationFault: nil
            )
        }
    }

    private func runNativeDecodedBlock(
        instructions: UnsafeBufferPointer<AVZNativeInstruction>,
        basePC: GuestAddress,
        maxSteps: Int,
        registers: UnsafeMutableBufferPointer<UInt64>,
        vectorLows: inout [UInt64],
        vectorHighs: inout [UInt64],
        usesVectorState: Bool,
        sp: inout UInt64,
        pc: inout UInt64,
        pstate: inout UInt64,
        exclusiveAddress: inout UInt64,
        exclusiveSize: inout UInt8,
        exclusiveValid: inout UInt8,
        halted: inout UInt8,
        memoryContext: NativeMemoryContext
    ) -> AVZNativeBlockResult {
        var fpcr = memoryContext.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpcr)
        var fpsr = memoryContext.vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr)
        let result: AVZNativeBlockResult
        let readMemory: AVZNativeMemoryReadCallback
        let writeMemory: AVZNativeMemoryWriteCallback
        let canAccessMemory: AVZNativeMemoryCanAccessCallback
        let fillMemory: AVZNativeMemoryFillCallback
        let readSystemRegister: AVZNativeSystemRegisterReadCallback
        let writeSystemRegister: AVZNativeSystemRegisterWriteCallback
        let executeSystemInstruction: AVZNativeSystemInstructionCallback
        let exceptionReturn: AVZNativeExceptionReturnCallback
        let synchronousException: AVZNativeSynchronousExceptionCallback
        let wait: AVZNativeWaitCallback
        let callbackContext: UnsafeMutableRawPointer
        if let fastPath = memoryContext.fastPath {
            readMemory = avz_native_fast_memory_read
            writeMemory = avz_native_fast_memory_write
            canAccessMemory = avz_native_fast_memory_can_access
            fillMemory = avz_native_fast_memory_fill
            readSystemRegister = avz_native_fast_read_system_register
            writeSystemRegister = avz_native_fast_write_system_register
            executeSystemInstruction = avz_native_fast_execute_system_instruction
            exceptionReturn = avz_native_fast_exception_return
            synchronousException = avz_native_fast_synchronous_exception
            wait = avz_native_fast_wait
            callbackContext = UnsafeMutableRawPointer(fastPath)
        } else {
            readMemory = nativeReadMemory
            writeMemory = nativeWriteMemory
            canAccessMemory = nativeCanAccessMemory
            fillMemory = nativeFillMemory
            readSystemRegister = nativeReadSystemRegister
            writeSystemRegister = nativeWriteSystemRegister
            executeSystemInstruction = nativeExecuteSystemInstruction
            exceptionReturn = nativeExceptionReturn
            synchronousException = nativeSynchronousException
            wait = nativeWait
            callbackContext = Unmanaged.passUnretained(memoryContext).toOpaque()
        }
        if usesVectorState {
            result = vectorLows.withUnsafeMutableBufferPointer { vectorLowBuffer in
                vectorHighs.withUnsafeMutableBufferPointer { vectorHighBuffer in
                    avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
                        instructions.baseAddress,
                        instructions.count,
                        basePC,
                        UInt64(maxSteps),
                        registers.baseAddress,
                        vectorLowBuffer.baseAddress,
                        vectorHighBuffer.baseAddress,
                        &sp,
                        &pc,
                        &pstate,
                        &fpcr,
                        &fpsr,
                        &exclusiveAddress,
                        &exclusiveSize,
                        &exclusiveValid,
                        &halted,
                        readMemory,
                        writeMemory,
                        canAccessMemory,
                        fillMemory,
                        readSystemRegister,
                        writeSystemRegister,
                        executeSystemInstruction,
                        exceptionReturn,
                        synchronousException,
                        wait,
                        callbackContext
                    )
                }
            }
        } else {
            result = avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
                instructions.baseAddress,
                instructions.count,
                basePC,
                UInt64(maxSteps),
                registers.baseAddress,
                nil,
                nil,
                &sp,
                &pc,
                &pstate,
                &fpcr,
                &fpsr,
                &exclusiveAddress,
                &exclusiveSize,
                &exclusiveValid,
                &halted,
                readMemory,
                writeMemory,
                canAccessMemory,
                fillMemory,
                readSystemRegister,
                writeSystemRegister,
                executeSystemInstruction,
                exceptionReturn,
                synchronousException,
                wait,
                callbackContext
            )
        }
        memoryContext.vm.systemRegisters.writeRaw(ARM64SystemRegister.fpcr, value: fpcr)
        memoryContext.vm.systemRegisters.writeRaw(ARM64SystemRegister.fpsr, value: fpsr)
        return result
    }

    private let nativeFetchInstruction: AVZNativeInstructionFetchCallback = {
        context,
        virtualAddress,
        physicalAddress,
        instruction
    in
        guard let context, let physicalAddress, let instruction else {
            return 0
        }
        let memoryContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        do {
            guard let fetched = try memoryContext.fetchInstruction(at: virtualAddress) else {
                return 0
            }
            physicalAddress.pointee = fetched.physicalPC
            instruction.pointee = fetched.instruction
            return 1
        } catch {
            if let fault = error as? ARM64TranslationFault {
                memoryContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeReadMemory: AVZNativeMemoryReadCallback = { context, virtualAddress, rawWidth, value in
        guard let context, let value, let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        do {
            if let loaded = try nativeContext.readMemory(virtualAddress, width: width) {
                value.pointee = loaded.value
                if loaded.fastRAM {
                    nativeContext.backend.fastRAMReadHits += 1
                    nativeContext.backend.nativeFastRAMReadHits += 1
                } else {
                    nativeContext.backend.fastRAMReadMisses += 1
                    nativeContext.backend.nativeFastRAMReadMisses += 1
                }
                return 1
            }
            nativeContext.backend.fastRAMReadMisses += 1
            nativeContext.backend.nativeFastRAMReadMisses += 1
            return 0
        } catch {
            nativeContext.backend.fastRAMReadMisses += 1
            nativeContext.backend.nativeFastRAMReadMisses += 1
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeTranslationFault: AVZNativeMemoryTranslationFaultCallback = {
        context,
        virtualAddress,
        rawAccess,
        rawLevel,
        rawStatusCode
    in
        guard let context,
              let statusCode = ARM64FaultStatusCode(
                rawValue: UInt64(rawStatusCode)
              ) else {
            return
        }
        let access: GuestMemoryAccessKind
        switch rawAccess {
        case UInt8(AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION):
            access = .instruction
        case UInt8(AVZ_NATIVE_MEMORY_ACCESS_READ):
            access = .dataRead
        case UInt8(AVZ_NATIVE_MEMORY_ACCESS_WRITE):
            access = .dataWrite
        default:
            return
        }
        let nativeContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        nativeContext.translationFault = ARM64TranslationFault(
            virtualAddress: virtualAddress,
            access: access,
            level: Int(rawLevel),
            statusCode: statusCode
        )
    }

    private let nativeReadPhysicalMemory: AVZNativePhysicalMemoryReadCallback = {
        context,
        physicalAddress,
        rawWidth,
        value
    in
        guard let context,
              let value,
              let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        do {
            value.pointee = try nativeContext.vm.readPhysical(
                physicalAddress,
                width: width
            )
            nativeContext.backend.nativePhysicalDeviceReads += 1
            nativeContext.backend.fastRAMReadMisses += 1
            nativeContext.backend.nativeFastRAMReadMisses += 1
            return 1
        } catch {
            return 0
        }
    }

    private let nativeWritePhysicalMemory: AVZNativePhysicalMemoryWriteCallback = {
        context,
        physicalAddress,
        rawWidth,
        value
    in
        guard let context,
              let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        do {
            try nativeContext.vm.writePhysical(
                physicalAddress,
                width: width,
                value: value
            )
            nativeContext.backend.nativePhysicalDeviceWrites += 1
            nativeContext.backend.fastRAMWriteMisses += 1
            nativeContext.backend.nativeFastRAMWriteMisses += 1
            return 1
        } catch {
            return 0
        }
    }

    private let nativeTranslateRAM: AVZNativeMemoryTranslateRAMCallback = {
        context,
        virtualAddress,
        rawWidth,
        isWrite,
        physicalAddress
    in
        guard let context,
              let physicalAddress,
              let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        do {
            guard let mapping = try nativeContext.ramMapping(
                for: virtualAddress,
                width: width,
                access: isWrite == 0 ? .dataRead : .dataWrite
            ) else {
                return 0
            }
            physicalAddress.pointee = mapping.physicalAddress
            return 1
        } catch {
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeTranslateInstructionRAM: AVZNativeMemoryTranslateRAMCallback = {
        context,
        virtualAddress,
        rawWidth,
        _,
        physicalAddress
    in
        guard let context,
              let physicalAddress,
              let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>
            .fromOpaque(context)
            .takeUnretainedValue()
        do {
            guard let mapping = try nativeContext.ramMapping(
                for: virtualAddress,
                width: width,
                access: .instruction
            ) else {
                return 0
            }
            physicalAddress.pointee = mapping.physicalAddress
            return 1
        } catch {
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeWriteMemory: AVZNativeMemoryWriteCallback = { context, virtualAddress, rawWidth, value in
        guard let context, let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        do {
            if let fastRAM = try nativeContext.writeMemory(virtualAddress, width: width, value: value) {
                if fastRAM {
                    nativeContext.backend.fastRAMWriteHits += 1
                    nativeContext.backend.nativeFastRAMWriteHits += 1
                } else {
                    nativeContext.backend.fastRAMWriteMisses += 1
                    nativeContext.backend.nativeFastRAMWriteMisses += 1
                }
                return 1
            }
            nativeContext.backend.fastRAMWriteMisses += 1
            nativeContext.backend.nativeFastRAMWriteMisses += 1
            return 0
        } catch {
            nativeContext.backend.fastRAMWriteMisses += 1
            nativeContext.backend.nativeFastRAMWriteMisses += 1
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeCanAccessMemory: AVZNativeMemoryCanAccessCallback = { context, virtualAddress, rawWidth, isWrite in
        guard let context, let width = MMIOWidth(rawValue: Int(rawWidth)) else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        do {
            return try nativeContext.canAccessRAM(
                virtualAddress,
                width: width,
                access: isWrite == 0 ? .dataRead : .dataWrite
            )
                ? 1
                : 0
        } catch {
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeFillMemory: AVZNativeMemoryFillCallback = { context, virtualAddress, byteCount, pattern, patternWidth in
        guard let context else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        do {
            guard try nativeContext.fillRAM(
                virtualAddress,
                byteCount: byteCount,
                pattern: pattern,
                patternWidth: Int(patternWidth)
            ) else {
                nativeContext.backend.fastRAMWriteMisses += 1
                nativeContext.backend.nativeFastRAMWriteMisses += 1
                return 0
            }
            let writeUnits = max(1, Int(min(byteCount / UInt64(max(1, patternWidth)), UInt64(Int.max))))
            nativeContext.backend.fastRAMWriteHits += writeUnits
            nativeContext.backend.nativeFastRAMWriteHits += writeUnits
            return 1
        } catch {
            nativeContext.backend.fastRAMWriteMisses += 1
            nativeContext.backend.nativeFastRAMWriteMisses += 1
            if let fault = error as? ARM64TranslationFault {
                nativeContext.translationFault = fault
            }
            return 0
        }
    }

    private let nativeReadSystemRegister: AVZNativeSystemRegisterReadCallback = {
        context,
        instruction,
        pc,
        pstate,
        sp,
        value
    in
        guard let context, let value else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let key = ARM64SystemRegisterKey(instruction: instruction)
        value.pointee = nativeContext.vm.systemRegisters.read(
            key,
            sp: sp,
            pstate: pstate
        )
        nativeContext.vm.recordSystemRegisterRead(pc: pc, key: key, value: value.pointee)
        return 1
    }

    private let nativeWriteSystemRegister: AVZNativeSystemRegisterWriteCallback = {
        context,
        instruction,
        pc,
        value,
        pstate,
        sp
    in
        guard let context, let pstate, let sp else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let key = ARM64SystemRegisterKey(instruction: instruction)
        var residentPState = pstate.pointee
        var residentSP = sp.pointee
        let previousValue = nativeContext.vm.systemRegisters.read(
            key,
            sp: residentSP,
            pstate: residentPState
        )
        nativeContext.vm.systemRegisters.write(
            key,
            value: value,
            pstate: &residentPState,
            sp: &residentSP
        )
        nativeContext.vm.didWriteSystemRegister(key)
        switch key.rawValue {
        case ARM64SystemRegister.sctlrEL1.rawValue,
             ARM64SystemRegister.tcrEL1.rawValue,
             ARM64SystemRegister.ttbr0EL1.rawValue,
             ARM64SystemRegister.ttbr1EL1.rawValue:
            nativeContext.translationContextChanged = true
        default:
            break
        }
        nativeContext.vm.recordSystemRegisterWrite(
            pc: pc,
            key: key,
            previousValue: previousValue,
            newValue: nativeContext.vm.systemRegisters.read(
                key,
                sp: residentSP,
                pstate: residentPState
            )
        )
        pstate.pointee = residentPState
        sp.pointee = residentSP
        return 1
    }

    private let nativeExecuteSystemInstruction: AVZNativeSystemInstructionCallback = {
        context,
        instruction,
        operand
    in
        guard let context else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let op1 = (instruction >> 16) & 0x7
        let crn = (instruction >> 12) & 0xf
        let crm = (instruction >> 8) & 0xf
        let op2 = (instruction >> 5) & 0x7

        if op1 == 3, crn == 7, crm == 4, op2 == 1 {
            let dczid = nativeContext.vm.systemRegisters.rawValue(for: ARM64SystemRegister.dczidEL0)
            guard (dczid & 0x10) == 0 else {
                return 1
            }
            let blockSize = UInt64(4) << UInt64(dczid & 0xf)
            do {
                return try nativeContext.fillRAM(
                    operand & ~(blockSize - 1),
                    byteCount: blockSize,
                    pattern: 0,
                    patternWidth: 8
                ) ? 1 : 0
            } catch {
                if let fault = error as? ARM64TranslationFault {
                    nativeContext.translationFault = fault
                }
                return 0
            }
        }

        nativeContext.vm.executeSystemMaintenanceInstruction(instruction)
        return 1
    }

    private let nativeExceptionReturn: AVZNativeExceptionReturnCallback = {
        context,
        pstate,
        sp,
        pc
    in
        guard let context, let pstate, let sp, let pc else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let vm = nativeContext.vm
        let oldPState = pstate.pointee
        let newPState = vm.systemRegisters.rawValue(for: ARM64SystemRegister.spsrEL1)

        switch CPUState.stackPointerBank(for: oldPState) {
        case .spEL0:
            vm.systemRegisters.writeRaw(ARM64SystemRegister.spEL0, value: sp.pointee)
        case .spEL1:
            vm.cpu.spEL1 = sp.pointee
        }

        switch CPUState.stackPointerBank(for: newPState) {
        case .spEL0:
            sp.pointee = vm.systemRegisters.rawValue(for: ARM64SystemRegister.spEL0)
        case .spEL1:
            sp.pointee = vm.cpu.spEL1
        }
        pstate.pointee = newPState
        pc.pointee = vm.systemRegisters.rawValue(for: ARM64SystemRegister.elrEL1)
        nativeContext.currentPStateBox?.value = newPState
        if ((oldPState >> 2) & 0x3) != ((newPState >> 2) & 0x3) {
            nativeContext.syncNativeTranslationState()
        }
        return 1
    }

    private let nativeSynchronousException: AVZNativeSynchronousExceptionCallback = {
        context,
        instruction,
        registers,
        pstate,
        sp,
        pc
    in
        guard let context, let registers, let pstate, let sp, let pc else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let vm = nativeContext.vm
        for index in 0..<31 {
            vm.cpu.x[index] = registers[index]
        }
        vm.cpu.pstate = pstate.pointee
        vm.cpu.sp = sp.pointee
        vm.cpu.pc = pc.pointee

        if (instruction & 0xffe0_001f) == 0xd400_0001 {
            nativeContext.backend.routeSupervisorCall(vm, instruction: instruction)
        } else if (instruction & 0xffe0_001f) == 0xd400_0002 ||
                    (instruction & 0xffe0_001f) == 0xd400_0003 {
            guard vm.handleFirmwareCall(instruction: instruction) else {
                return 0
            }
        } else if (instruction & 0xffe0_001f) == 0xd420_0000 {
            nativeContext.backend.routeBreakpointException(vm, instruction: instruction)
        } else {
            return 0
        }

        for index in 0..<31 {
            registers[index] = vm.cpu.x[index]
        }
        pstate.pointee = vm.cpu.pstate
        sp.pointee = vm.cpu.sp
        pc.pointee = vm.cpu.pc
        nativeContext.currentPStateBox?.value = vm.cpu.pstate
        nativeContext.syncNativeTranslationState()
        return 1
    }

    private let nativeWait: AVZNativeWaitCallback = {
        context,
        instruction,
        pc
    in
        guard let context, let pc else {
            return 0
        }
        let nativeContext = Unmanaged<NativeMemoryContext>.fromOpaque(context).takeUnretainedValue()
        let vm = nativeContext.vm
        vm.cpu.pc = pc.pointee
        let yielded: Bool
        if instruction == 0xd503_205f {
            nativeContext.backend.executeWaitForEvent(vm)
            yielded = false
        } else if instruction == 0xd503_207f {
            yielded = nativeContext.backend.executeWaitForInterrupt(vm)
        } else {
            return 0
        }
        pc.pointee = vm.cpu.pc
        return yielded ? Int32(AVZ_NATIVE_WAIT_YIELD) : Int32(AVZ_NATIVE_WAIT_CONTINUE)
    }

    private func executeDecodedBasicBlock(
        _ block: DecodedBasicBlock,
        vm: VirtualMachine,
        startingStep: Int
    ) throws -> BasicBlockExecutionOutcome {
        let fallbackStart = collectPerformanceTimings ? DispatchTime.now().uptimeNanoseconds : 0
        decodedBasicBlockExecutions += 1
        var executedSteps = 0
        defer {
            decodedBasicBlockSteps += executedSteps
            if collectPerformanceTimings {
                decodedBasicBlockNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- fallbackStart
            }
        }

        for entry in block.instructions {
            guard vm.cpu.pc == entry.pc else {
                decodedBasicBlockPCMismatchExits += 1
                break
            }

            let pcBeforeInstruction = vm.cpu.pc
            let pstateBeforeInstruction = vm.cpu.pstate
            decodedFallbackGadgetCounts[basicBlockInstructionName(for: entry.instruction), default: 0] += 1
            vm.recordInstruction(pc: entry.pc, instruction: entry.instruction)
            try executeDecodedInstruction(entry.decoded, vm: vm, instruction: entry.instruction, pc: entry.pc)
            if basicBlockTerminates(for: entry.decoded) {
                decodedBasicBlockTerminatorExecutions += 1
            }

            if let stopReason = finishInstructionCycle(
                vm,
                stepNumber: startingStep + executedSteps,
                pcBeforeInstruction: pcBeforeInstruction,
                pstateBeforeInstruction: pstateBeforeInstruction
            ) {
                executedSteps += 1
                return BasicBlockExecutionOutcome(steps: executedSteps, stopReason: stopReason)
            }
            executedSteps += 1
        }

        return BasicBlockExecutionOutcome(steps: executedSteps, stopReason: nil)
    }

    private func executeSingleInstructionCycle(_ vm: VirtualMachine, stepNumber: Int) throws -> RunStopReason? {
        let instructionStart = collectPerformanceTimings ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if collectPerformanceTimings {
                singleInstructionNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- instructionStart
            }
        }
        let pcBeforeInstruction = vm.cpu.pc
        let pstateBeforeInstruction = vm.cpu.pstate
        if try executeNativeSingleInstructionIfPossible(vm) {
            singleInstructionSteps += 1
            nativeSingleInstructionSteps += 1
            return finishInstructionCycle(
                vm,
                stepNumber: stepNumber,
                pcBeforeInstruction: pcBeforeInstruction,
                pstateBeforeInstruction: pstateBeforeInstruction
            )
        }

        guard fallbackInterpreterAllowed(for: vm) else {
            try throwNativeSingleInstructionCoverageGap(vm)
        }

        try step(vm)
        singleInstructionSteps += 1
        swiftFallbackSingleInstructionSteps += 1
        return finishInstructionCycle(
            vm,
            stepNumber: stepNumber,
            pcBeforeInstruction: pcBeforeInstruction,
            pstateBeforeInstruction: pstateBeforeInstruction
        )
    }

    private func executeNativeSingleInstructionIfPossible(_ vm: VirtualMachine) throws -> Bool {
        let pc = vm.cpu.pc
        let instruction: UInt32
        do {
            instruction = UInt32(try vm.readGuest(pc, width: .word, access: .instruction))
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
            return true
        }
        _ = cachedDecodedInstruction(for: instruction)

        if (instruction & 0xffff_f0ff) == 0xd503_305f {
            return false
        }

        let cachedNative = cachedNativeInstruction(for: instruction)
        guard cachedNative.supported else {
            return false
        }

        let nativeInstructions = [cachedNative.nativeInstruction]
        var registers = vm.cpu.x
        var vectorLows = vm.cpu.v.map(\.low)
        var vectorHighs = vm.cpu.v.map(\.high)
        var sp = vm.cpu.sp
        var nativePC = pc
        var pstate = vm.cpu.pstate
        var exclusiveAddress = vm.cpu.exclusiveReservationAddress ?? 0
        var exclusiveSize = UInt8(vm.cpu.exclusiveReservationSize ?? 0)
        var exclusiveValid: UInt8 = vm.cpu.exclusiveReservationAddress == nil ? 0 : 1
        var halted: UInt8 = vm.cpu.halted ? 1 : 0
        let memoryContext = NativeMemoryContext(
            backend: self,
            vm: vm,
            ramBytes: nil,
            translatedPageCache: NativeTranslatedPageCache()
        )

        vm.recordInstruction(pc: pc, instruction: instruction)
        let result = nativeInstructions.withUnsafeBufferPointer { instructionBuffer in
            registers.withUnsafeMutableBufferPointer { registerBuffer in
                runNativeDecodedBlock(
                    instructions: instructionBuffer,
                    basePC: pc,
                    maxSteps: 1,
                    registers: registerBuffer,
                    vectorLows: &vectorLows,
                    vectorHighs: &vectorHighs,
                    usesVectorState: nativeInstructionUsesVectorState(cachedNative.nativeInstruction.kind),
                    sp: &sp,
                    pc: &nativePC,
                    pstate: &pstate,
                    exclusiveAddress: &exclusiveAddress,
                    exclusiveSize: &exclusiveSize,
                    exclusiveValid: &exclusiveValid,
                    halted: &halted,
                    memoryContext: memoryContext
                )
            }
        }

        guard result.steps > 0 || memoryContext.translationFault != nil else {
            if result.status == UInt32(AVZ_NATIVE_STATUS_UNSUPPORTED), result.unsupported_instruction != 0 {
                recordUnsupportedInstruction(result.unsupported_instruction)
            }
            return false
        }

        vm.cpu.x = registers
        for index in vm.cpu.v.indices {
            vm.cpu.v[index] = ARM64VectorRegister(low: vectorLows[index], high: vectorHighs[index])
        }
        vm.cpu.sp = sp
        vm.cpu.pc = nativePC
        vm.cpu.pstate = pstate
        if exclusiveValid != 0 {
            vm.cpu.exclusiveReservationAddress = exclusiveAddress
            vm.cpu.exclusiveReservationSize = Int(exclusiveSize)
        } else {
            vm.cpu.exclusiveReservationAddress = nil
            vm.cpu.exclusiveReservationSize = nil
        }
        vm.cpu.halted = halted != 0

        if let translationFault = memoryContext.translationFault {
            routeTranslationFault(vm, fault: translationFault, returnAddress: pc)
        }
        return true
    }

    private func throwNativeSingleInstructionCoverageGap(_ vm: VirtualMachine) throws -> Never {
        let pc = vm.cpu.pc
        let instruction: UInt32
        do {
            instruction = UInt32(try vm.readGuest(pc, width: .word, access: .instruction))
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
            throw VMError.unsupportedInstruction(instruction: 0, pc: pc)
        }
        recordUnsupportedInstruction(instruction)
        throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
    }

    private func finishInstructionCycle(
        _ vm: VirtualMachine,
        stepNumber: Int,
        pcBeforeInstruction: GuestAddress,
        pstateBeforeInstruction: UInt64
    ) -> RunStopReason? {
        vm.completeLastInstructionTrace(pstateAfter: vm.cpu.pstate)
        let instructionTransition = vm.recordExceptionLevelTransitionIfNeeded(
            step: stepNumber,
            reason: .instruction,
            previousPC: pcBeforeInstruction,
            previousPState: pstateBeforeInstruction
        )
        if let requestedStop = vm.requestedStopReason {
            return requestedStop
        }
        if vm.stopOnEL0Entry, let transition = instructionTransition, transition.newEL == 0 {
            return .el0Entry(transition.newPC)
        }

        vm.systemRegisters.advance(cycles: vm.timerCyclesPerInstruction)
        vm.updateGenericTimerInterruptsIfNeeded()
        let pcBeforeIRQ = vm.cpu.pc
        let pstateBeforeIRQ = vm.cpu.pstate
        routePendingIRQIfNeeded(vm)
        vm.recordExceptionLevelTransitionIfNeeded(
            step: stepNumber,
            reason: .irq,
            previousPC: pcBeforeIRQ,
            previousPState: pstateBeforeIRQ
        )

        if let requestedStop = vm.requestedStopReason {
            return requestedStop
        }

        if let exceptionLoop = vm.exceptionLoop {
            return .exceptionLoop(exceptionLoop.vectorAddress)
        }

        if let exceptionStorm = vm.exceptionStorm {
            return .exceptionStorm(exceptionStorm.entry.returnAddress, exceptionStorm.count)
        }

        if vm.activeVirtualCPUIsWaitingForInterrupt {
            return .yielded
        }

        return nil
    }

    public func step(_ vm: VirtualMachine) throws {
        let pc = vm.cpu.pc
        let instruction: UInt32
        do {
            instruction = UInt32(try vm.readGuest(pc, width: .word, access: .instruction))
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
            return
        }
        vm.recordInstruction(pc: pc, instruction: instruction)

        if let decoded = cachedDecodedInstruction(for: instruction) {
            try executeDecodedInstruction(decoded, vm: vm, instruction: instruction, pc: pc)
            return
        }

        if instruction == 0xd503_201f {
            vm.cpu.pc = pc + 4
            return
        }

        if instruction == 0xd503_205f {
            executeWaitForEvent(vm)
            return
        }

        if instruction == 0xd503_207f {
            executeWaitForInterrupt(vm)
            return
        }

        if instruction == 0xd503_209f || instruction == 0xd503_20bf {
            vm.cpu.pc = pc + 4
            return
        }

        if (instruction & 0xffff_f01f) == 0xd503_201f {
            vm.cpu.pc = pc + 4
            return
        }

        if (instruction & 0xffe0_001f) == 0xd440_0000 {
            vm.cpu.pc = pc + 4
            vm.cpu.halted = true
            return
        }

        if instruction == 0xd69f_03e0 {
            executeExceptionReturn(vm)
            return
        }

        if (instruction & 0xffe0_001f) == 0xd400_0001 {
            routeSupervisorCall(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffe0_001f) == 0xd400_0002 ||
            (instruction & 0xffe0_001f) == 0xd400_0003 {
            guard vm.handleFirmwareCall(instruction: instruction) else {
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            return
        }

        if (instruction & 0xffe0_001f) == 0xd420_0000 {
            routeBreakpointException(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffff_f0ff) == 0xd503_305f {
            vm.clearExclusiveReservation()
            vm.cpu.pc = pc + 4
            return
        }

        if executePStateImmediateIfNeeded(vm, instruction: instruction) {
            return
        }

        if isBarrier(instruction) {
            vm.cpu.pc = pc + 4
            return
        }

        if isSystemInstruction(instruction) {
            executeSystemInstruction(vm, instruction: instruction)
            return
        }

        switch instruction & 0xfff0_0000 {
        case 0xd530_0000:
            executeSystemRegisterRead(vm, instruction: instruction)
            return
        case 0xd510_0000:
            executeSystemRegisterWrite(vm, instruction: instruction)
            return
        default:
            break
        }

        switch instruction & 0x9f00_0000 {
        case 0x1000_0000:
            executePCRelativeAddress(vm, instruction: instruction, page: false)
            return
        case 0x9000_0000:
            executePCRelativeAddress(vm, instruction: instruction, page: true)
            return
        default:
            break
        }

        if (instruction & 0x3b00_0000) == 0x1800_0000 {
            try executeLoadLiteral(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7e00_0000) == 0x3400_0000 {
            executeCompareAndBranch(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7e00_0000) == 0x3600_0000 {
            executeTestAndBranch(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3fe0_0c10) == 0x3a40_0000 {
            executeConditionalCompareRegister(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3fe0_0c10) == 0x3a40_0800 {
            executeConditionalCompareImmediate(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1fe0_fc00) == 0x1a00_0000 {
            executeAddSubtractWithCarry(vm, instruction: instruction)
            return
        }

        if (instruction & 0xff00_0010) == 0x5400_0000 {
            executeConditionalBranch(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1fe0_0800) == 0x1a80_0000 {
            try executeConditionalSelect(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffff_fc1f) == 0xd65f_0000 {
            executeRegisterBranch(vm, instruction: instruction, link: false)
            return
        }

        if (instruction & 0xffff_fc1f) == 0xd61f_0000 {
            executeRegisterBranch(vm, instruction: instruction, link: false)
            return
        }

        if (instruction & 0xffff_fc1f) == 0xd63f_0000 {
            executeRegisterBranch(vm, instruction: instruction, link: true)
            return
        }

        if (instruction & 0x1f80_0000) == 0x1200_0000 {
            try executeLogicalImmediate(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f00_0000) == 0x0a00_0000 {
            try executeLogicalShiftedRegister(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f80_0000) == 0x1300_0000 {
            try executeBitfieldMove(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7fa0_0000) == 0x1380_0000 {
            try executeExtractRegister(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7fe0_0000) == 0x1b00_0000 {
            executeMultiplyAddSubtract(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7fe0_0000) == 0x1b20_0000 {
            executeSignedMultiplyLongAddSubtract(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7fe0_0000) == 0x1ba0_0000 {
            executeUnsignedMultiplyLongAddSubtract(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffe0_fc00) == 0x9b40_7c00 {
            executeSignedMultiplyHigh(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffe0_fc00) == 0x9bc0_7c00 {
            executeUnsignedMultiplyHigh(vm, instruction: instruction)
            return
        }

        if (instruction & 0x5fe0_0000) == 0x5ac0_0000 {
            try executeDataProcessingOneSource(vm, instruction: instruction)
            return
        }

        if (instruction & 0x7fe0_c000) == 0x1ac0_0000 {
            try executeDataProcessingTwoSource(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f20_0000) == 0x0b00_0000 {
            try executeAddSubShiftedRegister(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f20_0000) == 0x0b20_0000 {
            try executeAddSubExtendedRegister(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f80_0000) == 0x1280_0000 {
            try executeMoveWide(vm, instruction: instruction)
            return
        }

        if (instruction & 0x1f00_0000) == 0x1100_0000 {
            try executeAddSubImmediate(
                vm,
                instruction: instruction,
                subtract: ((instruction >> 30) & 0x1) == 1,
                setFlags: ((instruction >> 29) & 0x1) == 1,
                is64Bit: ((instruction >> 31) & 0x1) == 1
            )
            return
        }

        if (instruction & 0x3fa0_0000) == 0x0820_0000 {
            try executeLoadStoreExclusivePair(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3fa0_7c00) == 0x0800_7c00 {
            try executeLoadStoreExclusive(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3fa0_fc00) == 0x0880_fc00 {
            try executeLoadAcquireStoreRelease(vm, instruction: instruction)
            return
        }

        switch instruction & 0xffc0_0000 {
        case 0x3d00_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: false, bytes: 1)
            return
        case 0x3d40_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: true, bytes: 1)
            return
        case 0x7d00_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: false, bytes: 2)
            return
        case 0x7d40_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: true, bytes: 2)
            return
        case 0xbd00_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: false, bytes: 4)
            return
        case 0xbd40_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: true, bytes: 4)
            return
        case 0xfd00_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: false, bytes: 8)
            return
        case 0xfd40_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: true, bytes: 8)
            return
        case 0x3d80_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: false, bytes: 16)
            return
        case 0x3dc0_0000:
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: true, bytes: 16)
            return
        default:
            break
        }

        if isSIMDFPQSignedImmediateLoadStore(instruction) {
            try executeSIMDFPQSignedImmediateLoadStore(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffff_fc00) == 0x4e08_3c00 {
            executeSIMDMoveVectorElementToGeneral(vm, instruction: instruction)
            return
        }

        if isFPScalarGeneralMove(instruction) {
            executeFPScalarGeneralMove(vm, instruction: instruction)
            return
        }

        if isFPScalarRegisterMove(instruction) {
            executeFPScalarRegisterMove(vm, instruction: instruction)
            return
        }

        if isFPScalarImmediateMove(instruction) {
            executeFPScalarImmediateMove(vm, instruction: instruction)
            return
        }

        if isFPIntegerToScalarFP(instruction) {
            executeFPIntegerToScalarFP(vm, instruction: instruction)
            return
        }

        if isFPScalarAdd(instruction) {
            executeFPScalarAdd(vm, instruction: instruction)
            return
        }

        if isFPScalarSubtract(instruction) {
            executeFPScalarSubtract(vm, instruction: instruction)
            return
        }

        if isFPScalarMultiply(instruction) {
            executeFPScalarMultiply(vm, instruction: instruction)
            return
        }

        if isFPScalarDivide(instruction) {
            executeFPScalarDivide(vm, instruction: instruction)
            return
        }

        if isFPScalarConditionalSelect(instruction) {
            executeFPScalarConditionalSelect(vm, instruction: instruction)
            return
        }

        if isFPScalarCompareZero(instruction) {
            executeFPScalarCompareZero(vm, instruction: instruction)
            return
        }

        if isFPScalarCompareRegister(instruction) {
            executeFPScalarCompareRegister(vm, instruction: instruction)
            return
        }

        if isFPScalarConvertToSignedInteger(instruction) {
            executeFPScalarConvertToSignedInteger(vm, instruction: instruction)
            return
        }

        if isFPScalarConvertToUnsignedIntegerRegister(instruction) {
            executeFPScalarConvertToUnsignedIntegerRegister(vm, instruction: instruction)
            return
        }

        if isSIMDScalarSignedIntegerToFP(instruction) {
            executeSIMDScalarSignedIntegerToFP(vm, instruction: instruction)
            return
        }

        if (instruction & 0xffe0_fc00) == 0x4e00_1c00 {
            try executeSIMDInsertGeneralToElement(vm, instruction: instruction)
            return
        }

        if isSIMDInsertVectorElement(instruction) {
            try executeSIMDInsertVectorElement(vm, instruction: instruction)
            return
        }

        if (instruction & 0xbff8_fc00) == 0x0f20_a400 {
            try executeSIMDSignedShiftLongSToD(vm, instruction: instruction)
            return
        }

        if isSIMDTableLookup(instruction) {
            executeSIMDTableLookup(vm, instruction: instruction)
            return
        }

        if isSIMDPermuteTwoVector(instruction) {
            try executeSIMDPermuteTwoVector(vm, instruction: instruction)
            return
        }

        if isSIMDAddVector(instruction) {
            try executeSIMDAddVector(vm, instruction: instruction)
            return
        }

        if isSIMDUnsignedMaxPairwise(instruction) {
            try executeSIMDUnsignedMaxPairwise(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3b20_0c00) == 0x3820_0800 {
            try executeLoadStoreRegisterOffset(vm, instruction: instruction)
            return
        }

        if (instruction & 0x3b00_0000) == 0x3800_0000 {
            try executeLoadStoreSignedImmediate(vm, instruction: instruction)
            return
        }

        if (instruction & 0xbfe0_fc00) == 0x0e00_0c00 {
            try executeSIMDDuplicateGeneral(vm, instruction: instruction)
            return
        }

        if isSIMDMoveImmediateZero(instruction) {
            executeSIMDMoveImmediateZero(vm, instruction: instruction)
            return
        }

        if isSIMDMoveImmediateByte(instruction) {
            executeSIMDMoveImmediateByte(vm, instruction: instruction)
            return
        }

        if isSIMDMoveInvertedImmediate(instruction) {
            try executeSIMDMoveInvertedImmediate(vm, instruction: instruction)
            return
        }

        switch instruction & 0xffc0_0000 {
        case 0x3d00_0000:
            try executeSIMDFPScalarByteUnsignedImmediate(vm, instruction: instruction, load: false)
            return
        case 0x3d40_0000:
            try executeSIMDFPScalarByteUnsignedImmediate(vm, instruction: instruction, load: true)
            return
        case 0x2c80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 4)
            return
        case 0x2cc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 4)
            return
        case 0x2d00_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 4)
            return
        case 0x2d40_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 4)
            return
        case 0x2d80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 4)
            return
        case 0x2dc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 4)
            return
        case 0x6c80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 8)
            return
        case 0x6cc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 8)
            return
        case 0x6d00_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 8)
            return
        case 0x6d40_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 8)
            return
        case 0x6d80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 8)
            return
        case 0x6dc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 8)
            return
        case 0xac80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 16)
            return
        case 0xacc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .postIndex, registerBytes: 16)
            return
        case 0xad00_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 16)
            return
        case 0xad40_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .signedOffset, registerBytes: 16)
            return
        case 0xad80_0000:
            try executeStorePairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 16)
            return
        case 0xadc0_0000:
            try executeLoadPairSIMD(vm, instruction: instruction, addressingMode: .preIndex, registerBytes: 16)
            return
        case 0x3900_0000:
            try executeStoreByte(vm, instruction: instruction)
            return
        case 0x3940_0000:
            try executeLoadByte(vm, instruction: instruction)
            return
        case 0x3980_0000:
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: .byte, resultBits: 64)
            return
        case 0x39c0_0000:
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: .byte, resultBits: 32)
            return
        case 0x7900_0000:
            try executeStoreHalfword(vm, instruction: instruction)
            return
        case 0x7940_0000:
            try executeLoadHalfword(vm, instruction: instruction)
            return
        case 0x7980_0000:
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: .halfword, resultBits: 64)
            return
        case 0x79c0_0000:
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: .halfword, resultBits: 32)
            return
        case 0xb900_0000:
            try executeStore32(vm, instruction: instruction)
            return
        case 0xb940_0000:
            try executeLoad32(vm, instruction: instruction)
            return
        case 0xb980_0000:
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: .word, resultBits: 64)
            return
        case 0xf900_0000:
            try executeStore64(vm, instruction: instruction)
            return
        case 0xf940_0000:
            try executeLoad64(vm, instruction: instruction)
            return
        case 0xf980_0000:
            vm.cpu.pc += 4
            return
        case 0x2800_0000:
            try executeStorePair32(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0x2840_0000:
            try executeLoadPair32(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0x2880_0000:
            try executeStorePair32(vm, instruction: instruction, addressingMode: .postIndex)
            return
        case 0x28c0_0000:
            try executeLoadPair32(vm, instruction: instruction, addressingMode: .postIndex)
            return
        case 0x2900_0000:
            try executeStorePair32(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0x2940_0000:
            try executeLoadPair32(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0x2980_0000:
            try executeStorePair32(vm, instruction: instruction, addressingMode: .preIndex)
            return
        case 0x29c0_0000:
            try executeLoadPair32(vm, instruction: instruction, addressingMode: .preIndex)
            return
        case 0x68c0_0000:
            try executeLoadPairSignedWord(vm, instruction: instruction, addressingMode: .postIndex)
            return
        case 0x6940_0000:
            try executeLoadPairSignedWord(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0x69c0_0000:
            try executeLoadPairSignedWord(vm, instruction: instruction, addressingMode: .preIndex)
            return
        case 0xa800_0000:
            try executeStorePair64(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0xa840_0000:
            try executeLoadPair64(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0xa880_0000:
            try executeStorePair64(vm, instruction: instruction, addressingMode: .postIndex)
            return
        case 0xa8c0_0000:
            try executeLoadPair64(vm, instruction: instruction, addressingMode: .postIndex)
            return
        case 0xa900_0000:
            try executeStorePair64(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0xa940_0000:
            try executeLoadPair64(vm, instruction: instruction, addressingMode: .signedOffset)
            return
        case 0xa980_0000:
            try executeStorePair64(vm, instruction: instruction, addressingMode: .preIndex)
            return
        case 0xa9c0_0000:
            try executeLoadPair64(vm, instruction: instruction, addressingMode: .preIndex)
            return
        default:
            break
        }

        switch instruction & 0xfc00_0000 {
        case 0x1400_0000:
            executeBranch(vm, instruction: instruction, link: false)
            return
        case 0x9400_0000:
            executeBranch(vm, instruction: instruction, link: true)
            return
        default:
            break
        }

        throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
    }

    private enum DecodedInstruction: Hashable {
        case advancePC
        case waitForEvent
        case waitForInterrupt
        case halt
        case exceptionReturn
        case supervisorCall
        case firmwareCall
        case breakpoint
        case clearExclusive
        case barrier
        case systemInstruction
        case systemRegisterRead
        case systemRegisterWrite
        case pcRelativeAddress(page: Bool)
        case loadLiteral
        case compareAndBranch
        case testAndBranch
        case conditionalCompareRegister
        case conditionalCompareImmediate
        case addSubtractWithCarry
        case conditionalBranch
        case conditionalSelect
        case registerBranch(link: Bool)
        case logicalImmediate
        case logicalShiftedRegister
        case bitfieldMove
        case extractRegister
        case multiplyAddSubtract
        case signedMultiplyLongAddSubtract
        case unsignedMultiplyLongAddSubtract
        case signedMultiplyHigh
        case unsignedMultiplyHigh
        case dataProcessingOneSource
        case dataProcessingTwoSource
        case addSubShiftedRegister
        case addSubExtendedRegister
        case moveWide
        case addSubImmediate
        case loadStoreExclusivePair
        case loadStoreExclusive
        case loadAcquireStoreRelease
        case simdFPLoadStoreUnsignedImmediate(load: Bool, bytes: Int)
        case simdFPQSignedImmediateLoadStore
        case simdMoveVectorElementToGeneral
        case fpScalarGeneralMove
        case fpScalarRegisterMove
        case fpScalarImmediateMove
        case fpIntegerToScalarFP
        case fpScalarAdd
        case fpScalarSubtract
        case fpScalarMultiply
        case fpScalarDivide
        case fpScalarNegatedMultiply
        case fpScalarFusedMultiplyAdd
        case fpScalarUnary
        case fpScalarRoundIntegral
        case simdScalarFPAbsoluteDifference
        case fpScalarConditionalSelect
        case fpScalarConditionalCompare
        case fpScalarCompareZero
        case fpScalarCompareRegister
        case fpScalarConvertToSignedInteger
        case fpScalarConvertToUnsignedIntegerRegister
        case simdScalarSignedIntegerToFP
        case simdInsertGeneralToElement
        case simdInsertVectorElement
        case simdSignedShiftLongSToD
        case simdTableLookup
        case simdPermuteTwoVector
        case simdAddVector
        case simdIntegerNegate
        case simdShiftLeftImmediate
        case simdMultiplyLong
        case simdNarrowHigh
        case simdBitwiseNot
        case simdSaturatingAddSubtract
        case simdShiftRightImmediate
        case simdPairwiseAddLong
        case simdUnsignedMaxPairwise
        case loadStoreRegisterOffset
        case loadStoreSignedImmediate
        case simdDuplicateGeneral
        case simdMoveImmediateZero
        case simdMoveImmediateByte
        case simdMoveImmediateWord
        case simdMoveDImmediate
        case simdFPImmediateMove
        case simdMoveInvertedImmediate
        case simdFPScalarByteUnsignedImmediate(load: Bool)
        case storePairSIMD(addressingMode: PairAddressingMode, registerBytes: Int)
        case loadPairSIMD(addressingMode: PairAddressingMode, registerBytes: Int)
        case storeByte
        case loadByte
        case loadSignedUnsignedImmediate(width: MMIOWidth, resultBits: Int)
        case storeHalfword
        case loadHalfword
        case store32
        case load32
        case store64
        case load64
        case storePair32(addressingMode: PairAddressingMode)
        case loadPair32(addressingMode: PairAddressingMode)
        case loadPairSignedWord(addressingMode: PairAddressingMode)
        case storePair64(addressingMode: PairAddressingMode)
        case loadPair64(addressingMode: PairAddressingMode)
        case branch(link: Bool)

        var isBasicBlockEligible: Bool {
            switch self {
            case .advancePC,
                 .pcRelativeAddress,
                 .loadLiteral,
                 .compareAndBranch,
                 .testAndBranch,
                 .conditionalCompareRegister,
                 .conditionalCompareImmediate,
                 .addSubtractWithCarry,
                 .conditionalBranch,
                 .conditionalSelect,
                 .registerBranch,
                 .logicalImmediate,
                 .logicalShiftedRegister,
                 .bitfieldMove,
                 .extractRegister,
                 .multiplyAddSubtract,
                 .signedMultiplyLongAddSubtract,
                 .unsignedMultiplyLongAddSubtract,
                 .signedMultiplyHigh,
                 .unsignedMultiplyHigh,
                 .dataProcessingOneSource,
                 .dataProcessingTwoSource,
                 .addSubShiftedRegister,
                 .addSubExtendedRegister,
                 .moveWide,
                 .addSubImmediate,
                 .loadStoreExclusivePair,
                 .loadStoreExclusive,
                 .loadAcquireStoreRelease,
                 .simdFPLoadStoreUnsignedImmediate,
                 .simdFPQSignedImmediateLoadStore,
                 .fpScalarGeneralMove,
                 .fpScalarRegisterMove,
                 .fpIntegerToScalarFP,
                 .fpScalarAdd,
                 .fpScalarSubtract,
                 .fpScalarMultiply,
                 .fpScalarNegatedMultiply,
                 .fpScalarFusedMultiplyAdd,
                 .fpScalarUnary,
                 .fpScalarRoundIntegral,
                 .simdScalarFPAbsoluteDifference,
                 .fpScalarConditionalSelect,
                 .fpScalarConditionalCompare,
                 .fpScalarCompareZero,
                 .fpScalarCompareRegister,
                 .fpScalarConvertToSignedInteger,
                 .fpScalarConvertToUnsignedIntegerRegister,
                 .simdScalarSignedIntegerToFP,
                 .simdMoveVectorElementToGeneral,
                 .simdInsertGeneralToElement,
                 .simdInsertVectorElement,
                 .simdSignedShiftLongSToD,
                 .simdTableLookup,
                 .simdPermuteTwoVector,
                 .simdAddVector,
                 .simdIntegerNegate,
                 .simdShiftLeftImmediate,
                 .simdMultiplyLong,
                 .simdNarrowHigh,
                 .simdBitwiseNot,
                 .simdSaturatingAddSubtract,
                 .simdShiftRightImmediate,
                 .simdPairwiseAddLong,
                 .loadStoreSignedImmediate,
                 .loadStoreRegisterOffset,
                 .simdFPScalarByteUnsignedImmediate,
                 .storePairSIMD,
                 .loadPairSIMD,
                 .simdDuplicateGeneral,
                 .simdMoveImmediateZero,
                 .simdMoveImmediateByte,
                 .simdMoveDImmediate,
                 .simdFPImmediateMove,
                 .simdMoveInvertedImmediate,
                 .storeByte,
                 .loadByte,
                 .loadSignedUnsignedImmediate,
                 .storeHalfword,
                 .loadHalfword,
                 .store32,
                 .load32,
                 .store64,
                 .load64,
                 .storePair32,
                 .loadPair32,
                 .loadPairSignedWord,
                 .storePair64,
                 .loadPair64,
                 .branch:
                return true
            default:
                return false
            }
        }

        @inline(__always)
        var terminatesBasicBlock: Bool {
            switch self {
            case .compareAndBranch,
                 .testAndBranch,
                 .conditionalBranch,
                 .registerBranch,
                 .branch:
                return true
            default:
                return false
            }
        }
    }

    @inline(__always)
    private func basicBlockInstructionName(for instruction: UInt32) -> String {
        ARM64InstructionClassifier.classify(instruction)
    }

    @inline(__always)
    private func basicBlockTerminates(for decoded: DecodedInstruction) -> Bool {
        decoded.terminatesBasicBlock
    }

    private func basicBlockGadget(for decoded: DecodedInstruction) -> BasicBlockGadget? {
        switch decoded {
        case .advancePC:
            return BasicBlockGadget(name: "advance-pc") { _, vm, _, pc in
                vm.cpu.pc = pc + 4
            }
        case let .pcRelativeAddress(page):
            return BasicBlockGadget(name: page ? "adrp" : "adr") { backend, vm, instruction, _ in
                backend.executePCRelativeAddress(vm, instruction: instruction, page: page)
            }
        case .loadLiteral:
            return BasicBlockGadget(name: "load-literal") { backend, vm, instruction, _ in
                try backend.executeLoadLiteralFast(vm, instruction: instruction)
            }
        case .compareAndBranch:
            return BasicBlockGadget(name: "compare-and-branch", terminatesBlock: true) { backend, vm, instruction, _ in
                backend.executeCompareAndBranch(vm, instruction: instruction)
            }
        case .testAndBranch:
            return BasicBlockGadget(name: "test-and-branch", terminatesBlock: true) { backend, vm, instruction, _ in
                backend.executeTestAndBranch(vm, instruction: instruction)
            }
        case .conditionalCompareRegister:
            return BasicBlockGadget(name: "ccmp-register") { backend, vm, instruction, _ in
                backend.executeConditionalCompareRegister(vm, instruction: instruction)
            }
        case .conditionalCompareImmediate:
            return BasicBlockGadget(name: "ccmp-immediate") { backend, vm, instruction, _ in
                backend.executeConditionalCompareImmediate(vm, instruction: instruction)
            }
        case .addSubtractWithCarry:
            return BasicBlockGadget(name: "add-sub-carry") { backend, vm, instruction, _ in
                backend.executeAddSubtractWithCarry(vm, instruction: instruction)
            }
        case .conditionalBranch:
            return BasicBlockGadget(name: "conditional-branch", terminatesBlock: true) { backend, vm, instruction, _ in
                backend.executeConditionalBranch(vm, instruction: instruction)
            }
        case .conditionalSelect:
            return BasicBlockGadget(name: "csel") { backend, vm, instruction, _ in
                try backend.executeConditionalSelect(vm, instruction: instruction)
            }
        case let .registerBranch(link):
            return BasicBlockGadget(name: link ? "blr" : "br-ret", terminatesBlock: true) { backend, vm, instruction, _ in
                backend.executeRegisterBranch(vm, instruction: instruction, link: link)
            }
        case .logicalImmediate:
            return BasicBlockGadget(name: "logical-immediate") { backend, vm, instruction, _ in
                try backend.executeLogicalImmediate(vm, instruction: instruction)
            }
        case .logicalShiftedRegister:
            return BasicBlockGadget(name: "logical-shifted-register") { backend, vm, instruction, _ in
                try backend.executeLogicalShiftedRegister(vm, instruction: instruction)
            }
        case .bitfieldMove:
            return BasicBlockGadget(name: "bitfield-move") { backend, vm, instruction, _ in
                try backend.executeBitfieldMove(vm, instruction: instruction)
            }
        case .extractRegister:
            return BasicBlockGadget(name: "extract-register") { backend, vm, instruction, _ in
                try backend.executeExtractRegister(vm, instruction: instruction)
            }
        case .multiplyAddSubtract:
            return BasicBlockGadget(name: "madd-msub") { backend, vm, instruction, _ in
                backend.executeMultiplyAddSubtract(vm, instruction: instruction)
            }
        case .signedMultiplyLongAddSubtract:
            return BasicBlockGadget(name: "smaddl-smsubl") { backend, vm, instruction, _ in
                backend.executeSignedMultiplyLongAddSubtract(vm, instruction: instruction)
            }
        case .unsignedMultiplyLongAddSubtract:
            return BasicBlockGadget(name: "umaddl-umsubl") { backend, vm, instruction, _ in
                backend.executeUnsignedMultiplyLongAddSubtract(vm, instruction: instruction)
            }
        case .signedMultiplyHigh:
            return BasicBlockGadget(name: "smulh") { backend, vm, instruction, _ in
                backend.executeSignedMultiplyHigh(vm, instruction: instruction)
            }
        case .unsignedMultiplyHigh:
            return BasicBlockGadget(name: "umulh") { backend, vm, instruction, _ in
                backend.executeUnsignedMultiplyHigh(vm, instruction: instruction)
            }
        case .dataProcessingOneSource:
            return BasicBlockGadget(name: "data-processing-one-source") { backend, vm, instruction, _ in
                try backend.executeDataProcessingOneSource(vm, instruction: instruction)
            }
        case .dataProcessingTwoSource:
            return BasicBlockGadget(name: "data-processing-two-source") { backend, vm, instruction, _ in
                try backend.executeDataProcessingTwoSource(vm, instruction: instruction)
            }
        case .addSubShiftedRegister:
            return BasicBlockGadget(name: "add-sub-shifted-register") { backend, vm, instruction, _ in
                try backend.executeAddSubShiftedRegister(vm, instruction: instruction)
            }
        case .addSubExtendedRegister:
            return BasicBlockGadget(name: "add-sub-extended-register") { backend, vm, instruction, _ in
                try backend.executeAddSubExtendedRegister(vm, instruction: instruction)
            }
        case .moveWide:
            return BasicBlockGadget(name: "move-wide") { backend, vm, instruction, _ in
                try backend.executeMoveWide(vm, instruction: instruction)
            }
        case .addSubImmediate:
            return BasicBlockGadget(name: "add-sub-immediate") { backend, vm, instruction, _ in
                try backend.executeAddSubImmediate(
                    vm,
                    instruction: instruction,
                    subtract: ((instruction >> 30) & 0x1) == 1,
                    setFlags: ((instruction >> 29) & 0x1) == 1,
                    is64Bit: ((instruction >> 31) & 0x1) == 1
                )
            }
        case .fpScalarGeneralMove:
            return BasicBlockGadget(name: "fp-general-move") { backend, vm, instruction, _ in
                backend.executeFPScalarGeneralMove(vm, instruction: instruction)
            }
        case .fpScalarRegisterMove:
            return BasicBlockGadget(name: "fp-register-move") { backend, vm, instruction, _ in
                backend.executeFPScalarRegisterMove(vm, instruction: instruction)
            }
        case .fpScalarImmediateMove:
            return BasicBlockGadget(name: "fp-immediate-move") { backend, vm, instruction, _ in
                backend.executeFPScalarImmediateMove(vm, instruction: instruction)
            }
        case .fpIntegerToScalarFP:
            return BasicBlockGadget(name: "fp-integer-to-scalar") { backend, vm, instruction, _ in
                backend.executeFPIntegerToScalarFP(vm, instruction: instruction)
            }
        case .fpScalarAdd:
            return BasicBlockGadget(name: "fp-add") { backend, vm, instruction, _ in
                backend.executeFPScalarAdd(vm, instruction: instruction)
            }
        case .fpScalarSubtract:
            return BasicBlockGadget(name: "fp-sub") { backend, vm, instruction, _ in
                backend.executeFPScalarSubtract(vm, instruction: instruction)
            }
        case .fpScalarMultiply:
            return BasicBlockGadget(name: "fp-mul") { backend, vm, instruction, _ in
                backend.executeFPScalarMultiply(vm, instruction: instruction)
            }
        case .fpScalarDivide:
            return BasicBlockGadget(name: "fp-div") { backend, vm, instruction, _ in
                backend.executeFPScalarDivide(vm, instruction: instruction)
            }
        case .fpScalarNegatedMultiply:
            return BasicBlockGadget(name: "fp-negated-multiply") { backend, vm, instruction, _ in
                backend.executeFPScalarNegatedMultiply(vm, instruction: instruction)
            }
        case .fpScalarFusedMultiplyAdd:
            return BasicBlockGadget(name: "fp-fused-multiply-add") { backend, vm, instruction, _ in
                backend.executeFPScalarFusedMultiplyAdd(vm, instruction: instruction)
            }
        case .fpScalarUnary:
            return BasicBlockGadget(name: "fp-unary") { backend, vm, instruction, _ in
                backend.executeFPScalarUnary(vm, instruction: instruction)
            }
        case .fpScalarRoundIntegral:
            return BasicBlockGadget(name: "fp-round-integral") { backend, vm, instruction, _ in
                backend.executeFPScalarRoundIntegral(vm, instruction: instruction)
            }
        case .simdScalarFPAbsoluteDifference:
            return BasicBlockGadget(name: "simd-scalar-fp-absolute-difference") { backend, vm, instruction, _ in
                backend.executeSIMDScalarFPAbsoluteDifference(vm, instruction: instruction)
            }
        case .fpScalarConditionalSelect:
            return BasicBlockGadget(name: "fp-csel") { backend, vm, instruction, _ in
                backend.executeFPScalarConditionalSelect(vm, instruction: instruction)
            }
        case .fpScalarConditionalCompare:
            return BasicBlockGadget(name: "fp-conditional-compare") { backend, vm, instruction, _ in
                backend.executeFPScalarConditionalCompare(vm, instruction: instruction)
            }
        case .fpScalarCompareZero:
            return BasicBlockGadget(name: "fp-cmp-zero") { backend, vm, instruction, _ in
                backend.executeFPScalarCompareZero(vm, instruction: instruction)
            }
        case .fpScalarCompareRegister:
            return BasicBlockGadget(name: "fp-cmp-register") { backend, vm, instruction, _ in
                backend.executeFPScalarCompareRegister(vm, instruction: instruction)
            }
        case .fpScalarConvertToSignedInteger:
            return BasicBlockGadget(name: "fp-to-signed-int") { backend, vm, instruction, _ in
                backend.executeFPScalarConvertToSignedInteger(vm, instruction: instruction)
            }
        case .fpScalarConvertToUnsignedIntegerRegister:
            return BasicBlockGadget(name: "fp-to-unsigned-int") { backend, vm, instruction, _ in
                backend.executeFPScalarConvertToUnsignedIntegerRegister(vm, instruction: instruction)
            }
        case .simdScalarSignedIntegerToFP:
            return BasicBlockGadget(name: "simd-signed-int-to-fp") { backend, vm, instruction, _ in
                backend.executeSIMDScalarSignedIntegerToFP(vm, instruction: instruction)
            }
        case .simdMoveVectorElementToGeneral:
            return BasicBlockGadget(name: "simd-element-to-general") { backend, vm, instruction, _ in
                backend.executeSIMDMoveVectorElementToGeneral(vm, instruction: instruction)
            }
        case .simdInsertGeneralToElement:
            return BasicBlockGadget(name: "simd-general-to-element") { backend, vm, instruction, _ in
                try backend.executeSIMDInsertGeneralToElement(vm, instruction: instruction)
            }
        case .simdInsertVectorElement:
            return BasicBlockGadget(name: "simd-element-to-element") { backend, vm, instruction, _ in
                try backend.executeSIMDInsertVectorElement(vm, instruction: instruction)
            }
        case .simdSignedShiftLongSToD:
            return BasicBlockGadget(name: "simd-sshll") { backend, vm, instruction, _ in
                try backend.executeSIMDSignedShiftLongSToD(vm, instruction: instruction)
            }
        case .simdTableLookup:
            return BasicBlockGadget(name: "simd-table-lookup") { backend, vm, instruction, _ in
                backend.executeSIMDTableLookup(vm, instruction: instruction)
            }
        case .simdPermuteTwoVector:
            return BasicBlockGadget(name: "simd-permute-two-vector") { backend, vm, instruction, _ in
                try backend.executeSIMDPermuteTwoVector(vm, instruction: instruction)
            }
        case .simdAddVector:
            return BasicBlockGadget(name: "simd-add-vector") { backend, vm, instruction, _ in
                try backend.executeSIMDAddVector(vm, instruction: instruction)
            }
        case .simdIntegerNegate:
            return BasicBlockGadget(name: "simd-integer-negate") { backend, vm, instruction, _ in
                try backend.executeSIMDIntegerNegate(vm, instruction: instruction)
            }
        case .simdShiftLeftImmediate:
            return BasicBlockGadget(name: "simd-shift-left-immediate") { backend, vm, instruction, _ in
                try backend.executeSIMDShiftLeftImmediate(vm, instruction: instruction)
            }
        case .simdMultiplyLong:
            return BasicBlockGadget(name: "simd-multiply-long") { backend, vm, instruction, _ in
                try backend.executeSIMDMultiplyLong(vm, instruction: instruction)
            }
        case .simdNarrowHigh:
            return BasicBlockGadget(name: "simd-narrow-high") { backend, vm, instruction, _ in
                try backend.executeSIMDNarrowHigh(vm, instruction: instruction)
            }
        case .simdBitwiseNot:
            return BasicBlockGadget(name: "simd-bitwise-not") { backend, vm, instruction, _ in
                backend.executeSIMDBitwiseNot(vm, instruction: instruction)
            }
        case .simdSaturatingAddSubtract:
            return BasicBlockGadget(name: "simd-saturating-add-subtract") { backend, vm, instruction, _ in
                try backend.executeSIMDSaturatingAddSubtract(vm, instruction: instruction)
            }
        case .simdShiftRightImmediate:
            return BasicBlockGadget(name: "simd-shift-right-immediate") { backend, vm, instruction, _ in
                try backend.executeSIMDShiftRightImmediate(vm, instruction: instruction)
            }
        case .simdPairwiseAddLong:
            return BasicBlockGadget(name: "simd-pairwise-add-long") { backend, vm, instruction, _ in
                backend.executeSIMDPairwiseAddLong(vm, instruction: instruction)
            }
        case .simdUnsignedMaxPairwise:
            return BasicBlockGadget(name: "simd-unsigned-max-pairwise") { backend, vm, instruction, _ in
                try backend.executeSIMDUnsignedMaxPairwise(vm, instruction: instruction)
            }
        case .loadStoreSignedImmediate:
            return BasicBlockGadget(name: "load-store-signed-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadStoreSignedImmediateFast(vm, instruction: instruction)
            }
        case .loadStoreRegisterOffset:
            return BasicBlockGadget(name: "load-store-register-offset") { backend, vm, instruction, _ in
                try backend.executeLoadStoreRegisterOffsetFast(vm, instruction: instruction)
            }
        case .loadStoreExclusivePair:
            return BasicBlockGadget(name: "load-store-exclusive-pair") { backend, vm, instruction, _ in
                try backend.executeLoadStoreExclusivePair(vm, instruction: instruction)
            }
        case .loadStoreExclusive:
            return BasicBlockGadget(name: "load-store-exclusive") { backend, vm, instruction, _ in
                try backend.executeLoadStoreExclusive(vm, instruction: instruction)
            }
        case .loadAcquireStoreRelease:
            return BasicBlockGadget(name: "load-acquire-store-release") { backend, vm, instruction, _ in
                try backend.executeLoadAcquireStoreReleaseFast(vm, instruction: instruction)
            }
        case let .simdFPLoadStoreUnsignedImmediate(load, bytes):
            return BasicBlockGadget(name: "simd-fp-load-store-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeSIMDFPLoadStoreUnsignedImmediate(
                    vm,
                    instruction: instruction,
                    load: load,
                    bytes: UInt64(bytes)
                )
            }
        case .simdFPQSignedImmediateLoadStore:
            return BasicBlockGadget(name: "simd-fp-q-signed-immediate") { backend, vm, instruction, _ in
                try backend.executeSIMDFPQSignedImmediateLoadStore(vm, instruction: instruction)
            }
        case let .simdFPScalarByteUnsignedImmediate(load):
            return BasicBlockGadget(name: "simd-fp-byte-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeSIMDFPScalarByteUnsignedImmediate(vm, instruction: instruction, load: load)
            }
        case let .storePairSIMD(addressingMode, registerBytes):
            return BasicBlockGadget(name: "simd-store-pair") { backend, vm, instruction, _ in
                try backend.executeStorePairSIMD(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    registerBytes: Int64(registerBytes)
                )
            }
        case let .loadPairSIMD(addressingMode, registerBytes):
            return BasicBlockGadget(name: "simd-load-pair") { backend, vm, instruction, _ in
                try backend.executeLoadPairSIMD(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    registerBytes: Int64(registerBytes)
                )
            }
        case .simdDuplicateGeneral:
            return BasicBlockGadget(name: "simd-dup-general") { backend, vm, instruction, _ in
                try backend.executeSIMDDuplicateGeneral(vm, instruction: instruction)
            }
        case .simdMoveImmediateZero:
            return BasicBlockGadget(name: "simd-movi-zero") { backend, vm, instruction, _ in
                backend.executeSIMDMoveImmediateZero(vm, instruction: instruction)
            }
        case .simdMoveImmediateByte:
            return BasicBlockGadget(name: "simd-movi-byte") { backend, vm, instruction, _ in
                backend.executeSIMDMoveImmediateByte(vm, instruction: instruction)
            }
        case .simdMoveImmediateWord:
            return BasicBlockGadget(name: "simd-movi-word") { backend, vm, instruction, _ in
                try backend.executeSIMDMoveImmediateWord(vm, instruction: instruction)
            }
        case .simdMoveDImmediate:
            return BasicBlockGadget(name: "simd-movi-d") { backend, vm, instruction, _ in
                backend.executeSIMDMoveDImmediate(vm, instruction: instruction)
            }
        case .simdFPImmediateMove:
            return BasicBlockGadget(name: "simd-fmov-immediate") { backend, vm, instruction, _ in
                backend.executeSIMDFPImmediateMove(vm, instruction: instruction)
            }
        case .simdMoveInvertedImmediate:
            return BasicBlockGadget(name: "simd-mvni") { backend, vm, instruction, _ in
                try backend.executeSIMDMoveInvertedImmediate(vm, instruction: instruction)
            }
        case .storeByte:
            return BasicBlockGadget(name: "strb-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeStoreUnsignedImmediateFast(vm, instruction: instruction, width: .byte)
            }
        case .loadByte:
            return BasicBlockGadget(name: "ldrb-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadUnsignedImmediateFast(vm, instruction: instruction, width: .byte)
            }
        case let .loadSignedUnsignedImmediate(width, resultBits):
            return BasicBlockGadget(name: "ldrs-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadSignedUnsignedImmediateFast(
                    vm,
                    instruction: instruction,
                    width: width,
                    resultBits: resultBits
                )
            }
        case .storeHalfword:
            return BasicBlockGadget(name: "strh-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeStoreUnsignedImmediateFast(vm, instruction: instruction, width: .halfword)
            }
        case .loadHalfword:
            return BasicBlockGadget(name: "ldrh-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadUnsignedImmediateFast(vm, instruction: instruction, width: .halfword)
            }
        case .store32:
            return BasicBlockGadget(name: "str32-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeStoreUnsignedImmediateFast(vm, instruction: instruction, width: .word)
            }
        case .load32:
            return BasicBlockGadget(name: "ldr32-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadUnsignedImmediateFast(vm, instruction: instruction, width: .word)
            }
        case .store64:
            return BasicBlockGadget(name: "str64-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeStoreUnsignedImmediateFast(vm, instruction: instruction, width: .doubleword)
            }
        case .load64:
            return BasicBlockGadget(name: "ldr64-unsigned-immediate") { backend, vm, instruction, _ in
                try backend.executeLoadUnsignedImmediateFast(vm, instruction: instruction, width: .doubleword)
            }
        case let .storePair32(addressingMode):
            return BasicBlockGadget(name: "stp32") { backend, vm, instruction, _ in
                try backend.executeStorePairFast(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    width: .word
                )
            }
        case let .loadPair32(addressingMode):
            return BasicBlockGadget(name: "ldp32") { backend, vm, instruction, _ in
                try backend.executeLoadPairFast(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    width: .word,
                    signExtendWords: false
                )
            }
        case let .loadPairSignedWord(addressingMode):
            return BasicBlockGadget(name: "ldpsw") { backend, vm, instruction, _ in
                try backend.executeLoadPairFast(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    width: .word,
                    signExtendWords: true
                )
            }
        case let .storePair64(addressingMode):
            return BasicBlockGadget(name: "stp64") { backend, vm, instruction, _ in
                try backend.executeStorePairFast(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    width: .doubleword
                )
            }
        case let .loadPair64(addressingMode):
            return BasicBlockGadget(name: "ldp64") { backend, vm, instruction, _ in
                try backend.executeLoadPairFast(
                    vm,
                    instruction: instruction,
                    addressingMode: addressingMode,
                    width: .doubleword,
                    signExtendWords: false
                )
            }
        case let .branch(link):
            return BasicBlockGadget(name: link ? "bl" : "b", terminatesBlock: true) { backend, vm, instruction, _ in
                backend.executeBranch(vm, instruction: instruction, link: link)
            }
        default:
            return nil
        }
    }

    private func readGuestFastOrFallback(
        _ vm: VirtualMachine,
        address: GuestAddress,
        width: MMIOWidth,
        access: GuestMemoryAccessKind = .dataRead
    ) throws -> UInt64 {
        if let value = try vm.readGuestRAMFast(address, width: width, access: access) {
            fastRAMReadHits += 1
            return value
        }
        fastRAMReadMisses += 1
        return try vm.readGuest(address, width: width, access: access)
    }

    private func writeGuestFastOrFallback(
        _ vm: VirtualMachine,
        address: GuestAddress,
        width: MMIOWidth,
        value: UInt64
    ) throws {
        if try vm.writeGuestRAMFast(address, width: width, value: value) {
            fastRAMWriteHits += 1
            return
        }
        fastRAMWriteMisses += 1
        try vm.writeGuest(address, width: width, value: value)
    }

    private func executeLoadLiteralFast(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let opcode = (instruction >> 30) & 0x3
        let rt = Int(instruction & 0x1f)
        let offset = signExtend((instruction >> 5) & 0x7ffff, bits: 19) << 2
        let address = addSignedOffset(pc, offset)

        do {
            switch opcode {
            case 0:
                writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: .word))
            case 1:
                writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: .doubleword))
            case 2:
                let value = try readGuestFastOrFallback(vm, address: address, width: .word)
                writeRegister(vm, rt, signExtendLoaded(value, bits: 32))
            case 3:
                break
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStoreUnsignedImmediateFast(
        _ vm: VirtualMachine,
        instruction: UInt32,
        width: MMIOWidth
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * UInt64(width.rawValue))

        do {
            try writeGuestFastOrFallback(
                vm,
                address: address,
                width: width,
                value: readRegister(vm, rt) & maskForBits(width.rawValue * 8)
            )
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadUnsignedImmediateFast(
        _ vm: VirtualMachine,
        instruction: UInt32,
        width: MMIOWidth
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * UInt64(width.rawValue))

        do {
            writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: width))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadSignedUnsignedImmediateFast(
        _ vm: VirtualMachine,
        instruction: UInt32,
        width: MMIOWidth,
        resultBits: Int
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * UInt64(width.rawValue))

        do {
            let loaded = try readGuestFastOrFallback(vm, address: address, width: width)
            let extended = signExtendLoaded(loaded, bits: width.rawValue * 8)
            writeRegister(vm, rt, resultBits == 32 ? extended & 0xffff_ffff : extended)
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadStoreSignedImmediateFast(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let opcode = (instruction >> 22) & 0x3
        let imm9 = signExtend((instruction >> 12) & 0x1ff, bits: 9)
        let mode = (instruction >> 10) & 0x3
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let base = baseRegister(vm, rn)
        let width = loadStoreWidth(size: size)

        let address: UInt64
        let writeback: UInt64?
        switch mode {
        case 0, 2:
            address = addSignedOffset(base, imm9)
            writeback = nil
        case 1:
            address = base
            writeback = addSignedOffset(base, imm9)
        case 3:
            address = addSignedOffset(base, imm9)
            writeback = address
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            switch opcode {
            case 0:
                try writeGuestFastOrFallback(
                    vm,
                    address: address,
                    width: width,
                    value: readRegister(vm, rt) & maskForBits(width.rawValue * 8)
                )
            case 1:
                writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: width))
            case 2:
                guard size <= 2 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(
                        try readGuestFastOrFallback(vm, address: address, width: width),
                        bits: width.rawValue * 8
                    )
                )
            case 3:
                guard size <= 1 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(
                        try readGuestFastOrFallback(vm, address: address, width: width),
                        bits: width.rawValue * 8
                    ) & 0xffff_ffff
                )
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadStoreRegisterOffsetFast(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let opcode = (instruction >> 22) & 0x3
        let rm = Int((instruction >> 16) & 0x1f)
        let option = UInt8((instruction >> 13) & 0x7)
        let shift = ((instruction >> 12) & 0x1) == 1 ? size : 0
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let width = loadStoreWidth(size: size)

        guard option == 0x2 || option == 0x3 || option == 0x6 || option == 0x7 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let offset = extendedRegisterValue(readRegister(vm, rm), option: option) << UInt64(shift)
        let address = baseRegister(vm, rn) &+ offset

        do {
            switch opcode {
            case 0:
                try writeGuestFastOrFallback(
                    vm,
                    address: address,
                    width: width,
                    value: readRegister(vm, rt) & maskForBits(width.rawValue * 8)
                )
            case 1:
                writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: width))
            case 2 where size == 3:
                break
            case 2:
                guard size <= 2 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                let bits = width.rawValue * 8
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(try readGuestFastOrFallback(vm, address: address, width: width), bits: bits)
                )
            case 3:
                guard size <= 1 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                let bits = width.rawValue * 8
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(try readGuestFastOrFallback(vm, address: address, width: width), bits: bits) & 0xffff_ffff
                )
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadAcquireStoreReleaseFast(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let rs = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let width = loadStoreWidth(size: size)
        let address = baseRegister(vm, rn)

        guard rs == 31 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            if isLoad {
                writeRegister(vm, rt, try readGuestFastOrFallback(vm, address: address, width: width))
            } else {
                try writeGuestFastOrFallback(
                    vm,
                    address: address,
                    width: width,
                    value: readRegister(vm, rt) & maskForBits(width.rawValue * 8)
                )
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStorePairFast(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode,
        width: MMIOWidth
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let imm7 = signExtend((instruction >> 15) & 0x7f, bits: 7)
        let stride = Int64(width.rawValue)
        let offset = imm7 * stride
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let mask = maskForBits(width.rawValue * 8)

        do {
            try writeGuestFastOrFallback(vm, address: address, width: width, value: readRegister(vm, rt) & mask)
            try writeGuestFastOrFallback(vm, address: address + UInt64(width.rawValue), width: width, value: readRegister(vm, rt2) & mask)
            if let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode) {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadPairFast(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode,
        width: MMIOWidth,
        signExtendWords: Bool
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let imm7 = signExtend((instruction >> 15) & 0x7f, bits: 7)
        let stride = Int64(width.rawValue)
        let offset = imm7 * stride
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)

        do {
            let first = try readGuestFastOrFallback(vm, address: address, width: width)
            let second = try readGuestFastOrFallback(vm, address: address + UInt64(width.rawValue), width: width)
            if signExtendWords {
                writeRegister(vm, rt, signExtendLoaded(first, bits: 32))
                writeRegister(vm, rt2, signExtendLoaded(second, bits: 32))
            } else {
                writeRegister(vm, rt, first)
                writeRegister(vm, rt2, second)
            }
            if let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode) {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    @inline(__always)
    private func cachedDecodedInstruction(for instruction: UInt32) -> DecodedInstruction? {
        if let decoded = decodedInstructionCache.decoded(for: instruction) {
            if collectCacheStatistics {
                decodedInstructionCacheHits &+= 1
            }
            return decoded
        }
        guard let decoded = decodeInstruction(instruction) else {
            return nil
        }
        decodedInstructionCache.store(decoded, for: instruction)
        if collectCacheStatistics {
            decodedInstructionCacheMisses &+= 1
        }
        return decoded
    }

    @inline(__always)
    private func cachedNativeInstruction(
        for instruction: UInt32
    ) -> (nativeInstruction: AVZNativeInstruction, supported: Bool) {
        if let cached = nativeInstructionCache.decoded(for: instruction) {
            return cached
        }
        var nativeInstruction = AVZNativeInstruction()
        let supported = avz_native_decode_instruction(instruction, &nativeInstruction) != 0
        nativeInstructionCache.store(nativeInstruction, supported: supported, for: instruction)
        return (nativeInstruction, supported)
    }

    private func decodeInstruction(_ instruction: UInt32) -> DecodedInstruction? {
        if instruction == 0xd503_201f { return .advancePC }
        if instruction == 0xd503_205f { return .waitForEvent }
        if instruction == 0xd503_207f { return .waitForInterrupt }
        if instruction == 0xd503_209f || instruction == 0xd503_20bf { return .advancePC }
        if (instruction & 0xffff_f01f) == 0xd503_201f { return .advancePC }
        if (instruction & 0xffe0_001f) == 0xd440_0000 { return .halt }
        if instruction == 0xd69f_03e0 { return .exceptionReturn }
        if (instruction & 0xffe0_001f) == 0xd400_0001 { return .supervisorCall }
        if (instruction & 0xffe0_001f) == 0xd400_0002 ||
            (instruction & 0xffe0_001f) == 0xd400_0003 { return .firmwareCall }
        if (instruction & 0xffe0_001f) == 0xd420_0000 { return .breakpoint }
        if (instruction & 0xffff_f0ff) == 0xd503_305f { return .clearExclusive }
        if isBarrier(instruction) { return .barrier }
        if isSystemInstruction(instruction) { return .systemInstruction }

        switch instruction & 0xfff0_0000 {
        case 0xd530_0000:
            return .systemRegisterRead
        case 0xd510_0000:
            return .systemRegisterWrite
        default:
            break
        }

        switch instruction & 0x9f00_0000 {
        case 0x1000_0000:
            return .pcRelativeAddress(page: false)
        case 0x9000_0000:
            return .pcRelativeAddress(page: true)
        default:
            break
        }

        if (instruction & 0x3b00_0000) == 0x1800_0000 { return .loadLiteral }
        if (instruction & 0x7e00_0000) == 0x3400_0000 { return .compareAndBranch }
        if (instruction & 0x7e00_0000) == 0x3600_0000 { return .testAndBranch }
        if (instruction & 0x3fe0_0c10) == 0x3a40_0000 { return .conditionalCompareRegister }
        if (instruction & 0x3fe0_0c10) == 0x3a40_0800 { return .conditionalCompareImmediate }
        if (instruction & 0x1fe0_fc00) == 0x1a00_0000 { return .addSubtractWithCarry }
        if (instruction & 0xff00_0010) == 0x5400_0000 { return .conditionalBranch }
        if (instruction & 0x1fe0_0800) == 0x1a80_0000 { return .conditionalSelect }
        if (instruction & 0xffff_fc1f) == 0xd65f_0000 { return .registerBranch(link: false) }
        if (instruction & 0xffff_fc1f) == 0xd61f_0000 { return .registerBranch(link: false) }
        if (instruction & 0xffff_fc1f) == 0xd63f_0000 { return .registerBranch(link: true) }
        if (instruction & 0x1f80_0000) == 0x1200_0000 { return .logicalImmediate }
        if (instruction & 0x1f00_0000) == 0x0a00_0000 { return .logicalShiftedRegister }
        if (instruction & 0x1f80_0000) == 0x1300_0000 { return .bitfieldMove }
        if (instruction & 0x7fa0_0000) == 0x1380_0000 { return .extractRegister }
        if (instruction & 0x7fe0_0000) == 0x1b00_0000 { return .multiplyAddSubtract }
        if (instruction & 0x7fe0_0000) == 0x1b20_0000 { return .signedMultiplyLongAddSubtract }
        if (instruction & 0x7fe0_0000) == 0x1ba0_0000 { return .unsignedMultiplyLongAddSubtract }
        if (instruction & 0xffe0_fc00) == 0x9b40_7c00 { return .signedMultiplyHigh }
        if (instruction & 0xffe0_fc00) == 0x9bc0_7c00 { return .unsignedMultiplyHigh }
        if (instruction & 0x5fe0_0000) == 0x5ac0_0000 { return .dataProcessingOneSource }
        if (instruction & 0x7fe0_c000) == 0x1ac0_0000 { return .dataProcessingTwoSource }
        if (instruction & 0x1f20_0000) == 0x0b00_0000 { return .addSubShiftedRegister }
        if (instruction & 0x1f20_0000) == 0x0b20_0000 { return .addSubExtendedRegister }
        if (instruction & 0x1f80_0000) == 0x1280_0000 { return .moveWide }
        if (instruction & 0x1f00_0000) == 0x1100_0000 { return .addSubImmediate }
        if (instruction & 0x3fa0_0000) == 0x0820_0000 { return .loadStoreExclusivePair }
        if (instruction & 0x3fa0_7c00) == 0x0800_7c00 { return .loadStoreExclusive }
        if (instruction & 0x3fa0_fc00) == 0x0880_fc00 { return .loadAcquireStoreRelease }

        switch instruction & 0xffc0_0000 {
        case 0x3d00_0000: return .simdFPLoadStoreUnsignedImmediate(load: false, bytes: 1)
        case 0x3d40_0000: return .simdFPLoadStoreUnsignedImmediate(load: true, bytes: 1)
        case 0x7d00_0000: return .simdFPLoadStoreUnsignedImmediate(load: false, bytes: 2)
        case 0x7d40_0000: return .simdFPLoadStoreUnsignedImmediate(load: true, bytes: 2)
        case 0xbd00_0000: return .simdFPLoadStoreUnsignedImmediate(load: false, bytes: 4)
        case 0xbd40_0000: return .simdFPLoadStoreUnsignedImmediate(load: true, bytes: 4)
        case 0xfd00_0000: return .simdFPLoadStoreUnsignedImmediate(load: false, bytes: 8)
        case 0xfd40_0000: return .simdFPLoadStoreUnsignedImmediate(load: true, bytes: 8)
        case 0x3d80_0000: return .simdFPLoadStoreUnsignedImmediate(load: false, bytes: 16)
        case 0x3dc0_0000: return .simdFPLoadStoreUnsignedImmediate(load: true, bytes: 16)
        default: break
        }

        if isSIMDFPQSignedImmediateLoadStore(instruction) { return .simdFPQSignedImmediateLoadStore }
        if (instruction & 0xffff_fc00) == 0x4e08_3c00 { return .simdMoveVectorElementToGeneral }
        if isFPScalarGeneralMove(instruction) { return .fpScalarGeneralMove }
        if isFPScalarRegisterMove(instruction) { return .fpScalarRegisterMove }
        if isFPScalarImmediateMove(instruction) { return .fpScalarImmediateMove }
        if isFPIntegerToScalarFP(instruction) { return .fpIntegerToScalarFP }
        if isFPScalarAdd(instruction) { return .fpScalarAdd }
        if isFPScalarSubtract(instruction) { return .fpScalarSubtract }
        if isFPScalarMultiply(instruction) { return .fpScalarMultiply }
        if isFPScalarDivide(instruction) { return .fpScalarDivide }
        if isFPScalarNegatedMultiply(instruction) { return .fpScalarNegatedMultiply }
        if isFPScalarFusedMultiplyAdd(instruction) { return .fpScalarFusedMultiplyAdd }
        if isFPScalarUnary(instruction) { return .fpScalarUnary }
        if isFPScalarRoundIntegral(instruction) { return .fpScalarRoundIntegral }
        if isSIMDScalarFPAbsoluteDifference(instruction) { return .simdScalarFPAbsoluteDifference }
        if isFPScalarConditionalSelect(instruction) { return .fpScalarConditionalSelect }
        if isFPScalarConditionalCompare(instruction) { return .fpScalarConditionalCompare }
        if isFPScalarCompareZero(instruction) { return .fpScalarCompareZero }
        if isFPScalarCompareRegister(instruction) { return .fpScalarCompareRegister }
        if isFPScalarConvertToSignedInteger(instruction) { return .fpScalarConvertToSignedInteger }
        if isFPScalarConvertToUnsignedIntegerRegister(instruction) { return .fpScalarConvertToUnsignedIntegerRegister }
        if isSIMDScalarSignedIntegerToFP(instruction) { return .simdScalarSignedIntegerToFP }
        if (instruction & 0xffe0_fc00) == 0x4e00_1c00 { return .simdInsertGeneralToElement }
        if isSIMDInsertVectorElement(instruction) { return .simdInsertVectorElement }
        if (instruction & 0xbff8_fc00) == 0x0f20_a400 { return .simdSignedShiftLongSToD }
        if isSIMDTableLookup(instruction) { return .simdTableLookup }
        if isSIMDPermuteTwoVector(instruction) { return .simdPermuteTwoVector }
        if isSIMDAddVector(instruction) { return .simdAddVector }
        if isSIMDIntegerNegate(instruction) { return .simdIntegerNegate }
        if isSIMDShiftLeftImmediate(instruction) { return .simdShiftLeftImmediate }
        if isSIMDMultiplyLong(instruction) { return .simdMultiplyLong }
        if isSIMDNarrowHigh(instruction) { return .simdNarrowHigh }
        if isSIMDBitwiseNot(instruction) { return .simdBitwiseNot }
        if isSIMDSaturatingAddSubtract(instruction) { return .simdSaturatingAddSubtract }
        if isSIMDShiftRightImmediate(instruction) { return .simdShiftRightImmediate }
        if isSIMDPairwiseAddLong(instruction) { return .simdPairwiseAddLong }
        if isSIMDUnsignedMaxPairwise(instruction) { return .simdUnsignedMaxPairwise }
        if (instruction & 0x3b20_0c00) == 0x3820_0800 { return .loadStoreRegisterOffset }
        if (instruction & 0x3b00_0000) == 0x3800_0000 { return .loadStoreSignedImmediate }
        if (instruction & 0xbfe0_fc00) == 0x0e00_0c00 { return .simdDuplicateGeneral }
        if isSIMDFPImmediateMove(instruction) { return .simdFPImmediateMove }
        if isSIMDMoveImmediateZero(instruction) { return .simdMoveImmediateZero }
        if isSIMDMoveImmediateWord(instruction) { return .simdMoveImmediateWord }
        if isSIMDMoveImmediateByte(instruction) { return .simdMoveImmediateByte }
        if isSIMDMoveDImmediate(instruction) { return .simdMoveDImmediate }
        if isSIMDMoveInvertedImmediate(instruction) { return .simdMoveInvertedImmediate }

        switch instruction & 0xffc0_0000 {
        case 0x3d00_0000: return .simdFPScalarByteUnsignedImmediate(load: false)
        case 0x3d40_0000: return .simdFPScalarByteUnsignedImmediate(load: true)
        case 0x2c80_0000: return .storePairSIMD(addressingMode: .postIndex, registerBytes: 4)
        case 0x2cc0_0000: return .loadPairSIMD(addressingMode: .postIndex, registerBytes: 4)
        case 0x2d00_0000: return .storePairSIMD(addressingMode: .signedOffset, registerBytes: 4)
        case 0x2d40_0000: return .loadPairSIMD(addressingMode: .signedOffset, registerBytes: 4)
        case 0x2d80_0000: return .storePairSIMD(addressingMode: .preIndex, registerBytes: 4)
        case 0x2dc0_0000: return .loadPairSIMD(addressingMode: .preIndex, registerBytes: 4)
        case 0x6c80_0000: return .storePairSIMD(addressingMode: .postIndex, registerBytes: 8)
        case 0x6cc0_0000: return .loadPairSIMD(addressingMode: .postIndex, registerBytes: 8)
        case 0x6d00_0000: return .storePairSIMD(addressingMode: .signedOffset, registerBytes: 8)
        case 0x6d40_0000: return .loadPairSIMD(addressingMode: .signedOffset, registerBytes: 8)
        case 0x6d80_0000: return .storePairSIMD(addressingMode: .preIndex, registerBytes: 8)
        case 0x6dc0_0000: return .loadPairSIMD(addressingMode: .preIndex, registerBytes: 8)
        case 0xac80_0000: return .storePairSIMD(addressingMode: .postIndex, registerBytes: 16)
        case 0xacc0_0000: return .loadPairSIMD(addressingMode: .postIndex, registerBytes: 16)
        case 0xad00_0000: return .storePairSIMD(addressingMode: .signedOffset, registerBytes: 16)
        case 0xad40_0000: return .loadPairSIMD(addressingMode: .signedOffset, registerBytes: 16)
        case 0xad80_0000: return .storePairSIMD(addressingMode: .preIndex, registerBytes: 16)
        case 0xadc0_0000: return .loadPairSIMD(addressingMode: .preIndex, registerBytes: 16)
        case 0x3900_0000: return .storeByte
        case 0x3940_0000: return .loadByte
        case 0x3980_0000: return .loadSignedUnsignedImmediate(width: .byte, resultBits: 64)
        case 0x39c0_0000: return .loadSignedUnsignedImmediate(width: .byte, resultBits: 32)
        case 0x7900_0000: return .storeHalfword
        case 0x7940_0000: return .loadHalfword
        case 0x7980_0000: return .loadSignedUnsignedImmediate(width: .halfword, resultBits: 64)
        case 0x79c0_0000: return .loadSignedUnsignedImmediate(width: .halfword, resultBits: 32)
        case 0xb900_0000: return .store32
        case 0xb940_0000: return .load32
        case 0xb980_0000: return .loadSignedUnsignedImmediate(width: .word, resultBits: 64)
        case 0xf900_0000: return .store64
        case 0xf940_0000: return .load64
        case 0xf980_0000: return .advancePC
        case 0x2800_0000: return .storePair32(addressingMode: .signedOffset)
        case 0x2840_0000: return .loadPair32(addressingMode: .signedOffset)
        case 0x2880_0000: return .storePair32(addressingMode: .postIndex)
        case 0x28c0_0000: return .loadPair32(addressingMode: .postIndex)
        case 0x2900_0000: return .storePair32(addressingMode: .signedOffset)
        case 0x2940_0000: return .loadPair32(addressingMode: .signedOffset)
        case 0x2980_0000: return .storePair32(addressingMode: .preIndex)
        case 0x29c0_0000: return .loadPair32(addressingMode: .preIndex)
        case 0x68c0_0000: return .loadPairSignedWord(addressingMode: .postIndex)
        case 0x6940_0000: return .loadPairSignedWord(addressingMode: .signedOffset)
        case 0x69c0_0000: return .loadPairSignedWord(addressingMode: .preIndex)
        case 0xa800_0000: return .storePair64(addressingMode: .signedOffset)
        case 0xa840_0000: return .loadPair64(addressingMode: .signedOffset)
        case 0xa880_0000: return .storePair64(addressingMode: .postIndex)
        case 0xa8c0_0000: return .loadPair64(addressingMode: .postIndex)
        case 0xa900_0000: return .storePair64(addressingMode: .signedOffset)
        case 0xa940_0000: return .loadPair64(addressingMode: .signedOffset)
        case 0xa980_0000: return .storePair64(addressingMode: .preIndex)
        case 0xa9c0_0000: return .loadPair64(addressingMode: .preIndex)
        default: break
        }

        switch instruction & 0xfc00_0000 {
        case 0x1400_0000:
            return .branch(link: false)
        case 0x9400_0000:
            return .branch(link: true)
        default:
            return nil
        }
    }

    private func executeDecodedInstruction(
        _ decoded: DecodedInstruction,
        vm: VirtualMachine,
        instruction: UInt32,
        pc: GuestAddress
    ) throws {
        switch decoded {
        case .advancePC:
            vm.cpu.pc = pc + 4
        case .waitForEvent:
            executeWaitForEvent(vm)
        case .waitForInterrupt:
            executeWaitForInterrupt(vm)
        case .halt:
            vm.cpu.pc = pc + 4
            vm.cpu.halted = true
        case .exceptionReturn:
            executeExceptionReturn(vm)
        case .supervisorCall:
            routeSupervisorCall(vm, instruction: instruction)
        case .firmwareCall:
            guard vm.handleFirmwareCall(instruction: instruction) else {
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
        case .breakpoint:
            routeBreakpointException(vm, instruction: instruction)
        case .clearExclusive:
            vm.clearExclusiveReservation()
            vm.cpu.pc = pc + 4
        case .barrier:
            vm.cpu.pc = pc + 4
        case .systemInstruction:
            executeSystemInstruction(vm, instruction: instruction)
        case .systemRegisterRead:
            executeSystemRegisterRead(vm, instruction: instruction)
        case .systemRegisterWrite:
            executeSystemRegisterWrite(vm, instruction: instruction)
        case let .pcRelativeAddress(page):
            executePCRelativeAddress(vm, instruction: instruction, page: page)
        case .loadLiteral:
            try executeLoadLiteral(vm, instruction: instruction)
        case .compareAndBranch:
            executeCompareAndBranch(vm, instruction: instruction)
        case .testAndBranch:
            executeTestAndBranch(vm, instruction: instruction)
        case .conditionalCompareRegister:
            executeConditionalCompareRegister(vm, instruction: instruction)
        case .conditionalCompareImmediate:
            executeConditionalCompareImmediate(vm, instruction: instruction)
        case .addSubtractWithCarry:
            executeAddSubtractWithCarry(vm, instruction: instruction)
        case .conditionalBranch:
            executeConditionalBranch(vm, instruction: instruction)
        case .conditionalSelect:
            try executeConditionalSelect(vm, instruction: instruction)
        case let .registerBranch(link):
            executeRegisterBranch(vm, instruction: instruction, link: link)
        case .logicalImmediate:
            try executeLogicalImmediate(vm, instruction: instruction)
        case .logicalShiftedRegister:
            try executeLogicalShiftedRegister(vm, instruction: instruction)
        case .bitfieldMove:
            try executeBitfieldMove(vm, instruction: instruction)
        case .extractRegister:
            try executeExtractRegister(vm, instruction: instruction)
        case .multiplyAddSubtract:
            executeMultiplyAddSubtract(vm, instruction: instruction)
        case .signedMultiplyLongAddSubtract:
            executeSignedMultiplyLongAddSubtract(vm, instruction: instruction)
        case .unsignedMultiplyLongAddSubtract:
            executeUnsignedMultiplyLongAddSubtract(vm, instruction: instruction)
        case .signedMultiplyHigh:
            executeSignedMultiplyHigh(vm, instruction: instruction)
        case .unsignedMultiplyHigh:
            executeUnsignedMultiplyHigh(vm, instruction: instruction)
        case .dataProcessingOneSource:
            try executeDataProcessingOneSource(vm, instruction: instruction)
        case .dataProcessingTwoSource:
            try executeDataProcessingTwoSource(vm, instruction: instruction)
        case .addSubShiftedRegister:
            try executeAddSubShiftedRegister(vm, instruction: instruction)
        case .addSubExtendedRegister:
            try executeAddSubExtendedRegister(vm, instruction: instruction)
        case .moveWide:
            try executeMoveWide(vm, instruction: instruction)
        case .addSubImmediate:
            try executeAddSubImmediate(
                vm,
                instruction: instruction,
                subtract: ((instruction >> 30) & 0x1) == 1,
                setFlags: ((instruction >> 29) & 0x1) == 1,
                is64Bit: ((instruction >> 31) & 0x1) == 1
            )
        case .loadStoreExclusivePair:
            try executeLoadStoreExclusivePair(vm, instruction: instruction)
        case .loadStoreExclusive:
            try executeLoadStoreExclusive(vm, instruction: instruction)
        case .loadAcquireStoreRelease:
            try executeLoadAcquireStoreRelease(vm, instruction: instruction)
        case let .simdFPLoadStoreUnsignedImmediate(load, bytes):
            try executeSIMDFPLoadStoreUnsignedImmediate(vm, instruction: instruction, load: load, bytes: UInt64(bytes))
        case .simdFPQSignedImmediateLoadStore:
            try executeSIMDFPQSignedImmediateLoadStore(vm, instruction: instruction)
        case .simdMoveVectorElementToGeneral:
            executeSIMDMoveVectorElementToGeneral(vm, instruction: instruction)
        case .fpScalarGeneralMove:
            executeFPScalarGeneralMove(vm, instruction: instruction)
        case .fpScalarRegisterMove:
            executeFPScalarRegisterMove(vm, instruction: instruction)
        case .fpScalarImmediateMove:
            executeFPScalarImmediateMove(vm, instruction: instruction)
        case .fpIntegerToScalarFP:
            executeFPIntegerToScalarFP(vm, instruction: instruction)
        case .fpScalarAdd:
            executeFPScalarAdd(vm, instruction: instruction)
        case .fpScalarSubtract:
            executeFPScalarSubtract(vm, instruction: instruction)
        case .fpScalarMultiply:
            executeFPScalarMultiply(vm, instruction: instruction)
        case .fpScalarDivide:
            executeFPScalarDivide(vm, instruction: instruction)
        case .fpScalarNegatedMultiply:
            executeFPScalarNegatedMultiply(vm, instruction: instruction)
        case .fpScalarFusedMultiplyAdd:
            executeFPScalarFusedMultiplyAdd(vm, instruction: instruction)
        case .fpScalarUnary:
            executeFPScalarUnary(vm, instruction: instruction)
        case .fpScalarRoundIntegral:
            executeFPScalarRoundIntegral(vm, instruction: instruction)
        case .simdScalarFPAbsoluteDifference:
            executeSIMDScalarFPAbsoluteDifference(vm, instruction: instruction)
        case .fpScalarConditionalSelect:
            executeFPScalarConditionalSelect(vm, instruction: instruction)
        case .fpScalarConditionalCompare:
            executeFPScalarConditionalCompare(vm, instruction: instruction)
        case .fpScalarCompareZero:
            executeFPScalarCompareZero(vm, instruction: instruction)
        case .fpScalarCompareRegister:
            executeFPScalarCompareRegister(vm, instruction: instruction)
        case .fpScalarConvertToSignedInteger:
            executeFPScalarConvertToSignedInteger(vm, instruction: instruction)
        case .fpScalarConvertToUnsignedIntegerRegister:
            executeFPScalarConvertToUnsignedIntegerRegister(vm, instruction: instruction)
        case .simdScalarSignedIntegerToFP:
            executeSIMDScalarSignedIntegerToFP(vm, instruction: instruction)
        case .simdInsertGeneralToElement:
            try executeSIMDInsertGeneralToElement(vm, instruction: instruction)
        case .simdInsertVectorElement:
            try executeSIMDInsertVectorElement(vm, instruction: instruction)
        case .simdSignedShiftLongSToD:
            try executeSIMDSignedShiftLongSToD(vm, instruction: instruction)
        case .simdTableLookup:
            executeSIMDTableLookup(vm, instruction: instruction)
        case .simdPermuteTwoVector:
            try executeSIMDPermuteTwoVector(vm, instruction: instruction)
        case .simdAddVector:
            try executeSIMDAddVector(vm, instruction: instruction)
        case .simdIntegerNegate:
            try executeSIMDIntegerNegate(vm, instruction: instruction)
        case .simdShiftLeftImmediate:
            try executeSIMDShiftLeftImmediate(vm, instruction: instruction)
        case .simdMultiplyLong:
            try executeSIMDMultiplyLong(vm, instruction: instruction)
        case .simdNarrowHigh:
            try executeSIMDNarrowHigh(vm, instruction: instruction)
        case .simdBitwiseNot:
            executeSIMDBitwiseNot(vm, instruction: instruction)
        case .simdSaturatingAddSubtract:
            try executeSIMDSaturatingAddSubtract(vm, instruction: instruction)
        case .simdShiftRightImmediate:
            try executeSIMDShiftRightImmediate(vm, instruction: instruction)
        case .simdPairwiseAddLong:
            executeSIMDPairwiseAddLong(vm, instruction: instruction)
        case .simdUnsignedMaxPairwise:
            try executeSIMDUnsignedMaxPairwise(vm, instruction: instruction)
        case .loadStoreRegisterOffset:
            try executeLoadStoreRegisterOffset(vm, instruction: instruction)
        case .loadStoreSignedImmediate:
            try executeLoadStoreSignedImmediate(vm, instruction: instruction)
        case .simdDuplicateGeneral:
            try executeSIMDDuplicateGeneral(vm, instruction: instruction)
        case .simdMoveImmediateZero:
            executeSIMDMoveImmediateZero(vm, instruction: instruction)
        case .simdMoveImmediateByte:
            executeSIMDMoveImmediateByte(vm, instruction: instruction)
        case .simdMoveImmediateWord:
            try executeSIMDMoveImmediateWord(vm, instruction: instruction)
        case .simdMoveDImmediate:
            executeSIMDMoveDImmediate(vm, instruction: instruction)
        case .simdFPImmediateMove:
            executeSIMDFPImmediateMove(vm, instruction: instruction)
        case .simdMoveInvertedImmediate:
            try executeSIMDMoveInvertedImmediate(vm, instruction: instruction)
        case let .simdFPScalarByteUnsignedImmediate(load):
            try executeSIMDFPScalarByteUnsignedImmediate(vm, instruction: instruction, load: load)
        case let .storePairSIMD(addressingMode, registerBytes):
            try executeStorePairSIMD(
                vm,
                instruction: instruction,
                addressingMode: addressingMode,
                registerBytes: Int64(registerBytes)
            )
        case let .loadPairSIMD(addressingMode, registerBytes):
            try executeLoadPairSIMD(
                vm,
                instruction: instruction,
                addressingMode: addressingMode,
                registerBytes: Int64(registerBytes)
            )
        case .storeByte:
            try executeStoreByte(vm, instruction: instruction)
        case .loadByte:
            try executeLoadByte(vm, instruction: instruction)
        case let .loadSignedUnsignedImmediate(width, resultBits):
            try executeLoadSignedUnsignedImmediate(vm, instruction: instruction, width: width, resultBits: resultBits)
        case .storeHalfword:
            try executeStoreHalfword(vm, instruction: instruction)
        case .loadHalfword:
            try executeLoadHalfword(vm, instruction: instruction)
        case .store32:
            try executeStore32(vm, instruction: instruction)
        case .load32:
            try executeLoad32(vm, instruction: instruction)
        case .store64:
            try executeStore64(vm, instruction: instruction)
        case .load64:
            try executeLoad64(vm, instruction: instruction)
        case let .storePair32(addressingMode):
            try executeStorePair32(vm, instruction: instruction, addressingMode: addressingMode)
        case let .loadPair32(addressingMode):
            try executeLoadPair32(vm, instruction: instruction, addressingMode: addressingMode)
        case let .loadPairSignedWord(addressingMode):
            try executeLoadPairSignedWord(vm, instruction: instruction, addressingMode: addressingMode)
        case let .storePair64(addressingMode):
            try executeStorePair64(vm, instruction: instruction, addressingMode: addressingMode)
        case let .loadPair64(addressingMode):
            try executeLoadPair64(vm, instruction: instruction, addressingMode: addressingMode)
        case let .branch(link):
            executeBranch(vm, instruction: instruction, link: link)
        }
    }

    private func routeSupervisorCall(_ vm: VirtualMachine, instruction: UInt32) {
        let immediate = UInt64((instruction >> 5) & 0xffff)
        routeSynchronousException(
            vm,
            source: .supervisorCall,
            exceptionClass: .supervisorCallAArch64,
            iss: immediate,
            returnAddress: vm.cpu.pc + 4,
            faultAddress: nil
        )
    }

    private func routeBreakpointException(_ vm: VirtualMachine, instruction: UInt32) {
        let immediate = UInt64((instruction >> 5) & 0xffff)
        routeSynchronousException(
            vm,
            source: .breakpoint,
            exceptionClass: .breakpointAArch64,
            iss: immediate,
            returnAddress: vm.cpu.pc,
            faultAddress: nil
        )
    }

    private func routeTranslationFault(_ vm: VirtualMachine, fault: ARM64TranslationFault, returnAddress: GuestAddress) {
        let sameEL = vm.cpu.currentExceptionLevel == 1
        let exceptionClass: ARM64ExceptionClass
        switch fault.access {
        case .instruction:
            exceptionClass = sameEL ? .instructionAbortSameEL : .instructionAbortLowerEL
        case .dataRead, .dataWrite:
            exceptionClass = sameEL ? .dataAbortSameEL : .dataAbortLowerEL
        }

        routeSynchronousException(
            vm,
            source: .translationFault,
            exceptionClass: exceptionClass,
            iss: fault.syndromeISS,
            returnAddress: returnAddress,
            faultAddress: fault.virtualAddress,
            access: fault.access,
            faultLevel: fault.level,
            faultStatusCode: fault.statusCode
        )
    }

    private func routePendingIRQIfNeeded(_ vm: VirtualMachine) {
        guard (vm.cpu.pstate & ARM64PState.irqMask) == 0 else {
            return
        }
        guard vm.interruptController.peekPending(targetVCPU: vm.activeVCPUID) != nil else {
            return
        }

        let previousPState = vm.cpu.pstate
        let vectorBase = vm.systemRegisters.rawValue(for: ARM64SystemRegister.vbarEL1)
        let vectorOffset = irqVectorOffset(for: vm.cpu)
        let vectorAddress = vectorBase + vectorOffset
        let newPState = ARM64PState.el1hMasked

        vm.systemRegisters.writeRaw(ARM64SystemRegister.spsrEL1, value: previousPState)
        vm.systemRegisters.writeRaw(ARM64SystemRegister.elrEL1, value: vm.cpu.pc)
        vm.systemRegisters.writeRaw(ARM64SystemRegister.esrEL1, value: 0)

        vm.recordException(ARM64ExceptionTraceEntry(
            source: .irq,
            exceptionClass: .unknown,
            iss: 0,
            syndrome: 0,
            returnAddress: vm.cpu.pc,
            faultAddress: nil,
            vectorBase: vectorBase,
            vectorOffset: vectorOffset,
            vectorAddress: vectorAddress,
            previousPState: previousPState,
            newPState: newPState,
            currentEL: Int(vm.cpu.currentExceptionLevel),
            irqLine: vm.interruptController.peekPending(targetVCPU: vm.activeVCPUID)
        ))

        vm.switchActiveStackPointer(from: previousPState, to: newPState)
        vm.cpu.pstate = newPState
        vm.cpu.pc = vectorAddress
    }

    private func executeWaitForEvent(_ vm: VirtualMachine) {
        vm.recordWaitForEvent()
        vm.cpu.pc += 4
    }

    @discardableResult
    private func executeWaitForInterrupt(_ vm: VirtualMachine) -> Bool {
        vm.recordWaitForInterrupt()
        vm.cpu.pc += 4
        if vm.interruptController.peekPending(targetVCPU: vm.activeVCPUID) == nil {
            _ = vm.fastForwardGenericTimerToNextDeadline()
        }
        vm.updateGenericTimerInterruptsIfNeeded(force: true)
        return vm.suspendActiveVirtualCPUForWaitForInterrupt()
    }

    private func routeSynchronousException(
        _ vm: VirtualMachine,
        source: ARM64ExceptionSource,
        exceptionClass: ARM64ExceptionClass,
        iss: UInt64,
        returnAddress: GuestAddress,
        faultAddress: GuestAddress?,
        access: GuestMemoryAccessKind? = nil,
        faultLevel: Int? = nil,
        faultStatusCode: ARM64FaultStatusCode? = nil
    ) {
        let previousPState = vm.cpu.pstate
        let vectorBase = vm.systemRegisters.rawValue(for: ARM64SystemRegister.vbarEL1)
        let vectorOffset = synchronousVectorOffset(for: vm.cpu)
        let vectorAddress = vectorBase + vectorOffset
        let syndrome = exceptionClass.syndrome(iss: iss)
        let newPState = ARM64PState.el1hMasked

        vm.systemRegisters.writeRaw(ARM64SystemRegister.spsrEL1, value: previousPState)
        vm.systemRegisters.writeRaw(ARM64SystemRegister.elrEL1, value: returnAddress)
        vm.systemRegisters.writeRaw(ARM64SystemRegister.esrEL1, value: syndrome)
        if let faultAddress {
            vm.systemRegisters.writeRaw(ARM64SystemRegister.farEL1, value: faultAddress)
        }

        vm.recordException(ARM64ExceptionTraceEntry(
            source: source,
            exceptionClass: exceptionClass,
            iss: iss,
            syndrome: syndrome,
            returnAddress: returnAddress,
            faultAddress: faultAddress,
            vectorBase: vectorBase,
            vectorOffset: vectorOffset,
            vectorAddress: vectorAddress,
            previousPState: previousPState,
            newPState: newPState,
            currentEL: Int(vm.cpu.currentExceptionLevel),
            access: access,
            faultLevel: faultLevel,
            faultStatusCode: faultStatusCode
        ))

        vm.switchActiveStackPointer(from: previousPState, to: newPState)
        vm.cpu.pstate = newPState
        vm.cpu.pc = vectorAddress
    }

    private func executeExceptionReturn(_ vm: VirtualMachine) {
        let previousPState = vm.cpu.pstate
        let newPState = vm.systemRegisters.rawValue(for: ARM64SystemRegister.spsrEL1)
        vm.switchActiveStackPointer(from: previousPState, to: newPState)
        vm.cpu.pc = vm.systemRegisters.rawValue(for: ARM64SystemRegister.elrEL1)
        vm.cpu.pstate = newPState
    }

    private func synchronousVectorOffset(for cpu: CPUState) -> UInt64 {
        if cpu.currentExceptionLevel == 0 {
            return 0x400
        }
        return (cpu.pstate & 0x1) == 0 ? 0x000 : 0x200
    }

    private func irqVectorOffset(for cpu: CPUState) -> UInt64 {
        if cpu.currentExceptionLevel == 0 {
            return 0x480
        }
        return (cpu.pstate & 0x1) == 0 ? 0x080 : 0x280
    }

    private func executeSystemRegisterRead(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let key = ARM64SystemRegisterKey(instruction: instruction)
        let value = vm.systemRegisters.read(key, cpu: vm.cpu)

        writeRegister(vm, rt, value)
        vm.recordSystemRegisterRead(pc: pc, key: key, value: value)
        vm.cpu.pc = pc + 4
    }

    private func executeSystemRegisterWrite(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let key = ARM64SystemRegisterKey(instruction: instruction)
        let previousValue = vm.systemRegisters.read(key, cpu: vm.cpu)
        vm.writeSystemRegister(key, value: readRegister(vm, rt))
        vm.recordSystemRegisterWrite(
            pc: pc,
            key: key,
            previousValue: previousValue,
            newValue: vm.systemRegisters.read(key, cpu: vm.cpu)
        )
        vm.cpu.pc = pc + 4
    }

    private func executeSystemInstruction(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let op1 = (instruction >> 16) & 0x7
        let crn = (instruction >> 12) & 0xf
        let crm = (instruction >> 8) & 0xf
        let op2 = (instruction >> 5) & 0x7

        if op1 == 3, crn == 7, crm == 4, op2 == 1 {
            executeDataCacheZeroByVA(vm, instruction: instruction)
            return
        }

        vm.executeSystemMaintenanceInstruction(instruction)
        vm.cpu.pc = pc + 4
    }

    private func executeDataCacheZeroByVA(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let dczid = vm.systemRegisters.rawValue(for: ARM64SystemRegister.dczidEL0)
        guard (dczid & 0x10) == 0 else {
            vm.cpu.pc = pc + 4
            return
        }

        let blockSize = UInt64(4) << UInt64(dczid & 0xf)
        let blockBase = readRegister(vm, rt) & ~(blockSize - 1)

        do {
            var offset: UInt64 = 0
            while offset < blockSize {
                try vm.writeGuest(blockBase + offset, width: .doubleword, value: 0)
                offset += 8
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        } catch {
            vm.cpu.halted = true
        }
    }

    private func executePStateImmediateIfNeeded(_ vm: VirtualMachine, instruction: UInt32) -> Bool {
        guard (instruction & 0xffff_f01f) == 0xd503_401f else {
            return false
        }

        let op2 = (instruction >> 5) & 0x7
        guard op2 == 0x6 || op2 == 0x7 else {
            return false
        }

        let mask = UInt64((instruction >> 8) & 0xf) << 6
        if op2 == 0x6 {
            vm.cpu.pstate |= mask
        } else {
            vm.cpu.pstate &= ~mask
        }
        vm.cpu.pc += 4
        return true
    }

    private func executePCRelativeAddress(_ vm: VirtualMachine, instruction: UInt32, page: Bool) {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let immlo = (instruction >> 29) & 0x3
        let immhi = (instruction >> 5) & 0x7_ffff
        let imm21 = (immhi << 2) | immlo
        let offset = signExtend(imm21, bits: 21) << (page ? 12 : 0)
        let base = page ? pc & ~UInt64(0xfff) : pc

        writeRegister(vm, rd, addSignedOffset(base, offset))
        vm.cpu.pc = pc + 4
    }

    private func executeLoadLiteral(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let opcode = (instruction >> 30) & 0x3
        let rt = Int(instruction & 0x1f)
        let offset = signExtend((instruction >> 5) & 0x7ffff, bits: 19) << 2
        let address = addSignedOffset(pc, offset)

        do {
            switch opcode {
            case 0:
                writeRegister(vm, rt, try vm.readGuest(address, width: .word))
            case 1:
                writeRegister(vm, rt, try vm.readGuest(address, width: .doubleword))
            case 2:
                let value = try vm.readGuest(address, width: .word)
                writeRegister(vm, rt, signExtendLoaded(value, bits: 32))
            case 3:
                break
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeCompareAndBranch(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let value = ((instruction >> 31) & 0x1) == 1 ? readRegister(vm, rt) : readRegister(vm, rt) & 0xffff_ffff
        let branchesOnNonZero = ((instruction >> 24) & 0x1) == 1
        let shouldBranch = (value != 0) == branchesOnNonZero
        let offset = signExtend((instruction >> 5) & 0x7_ffff, bits: 19) << 2

        vm.cpu.pc = shouldBranch ? addSignedOffset(pc, offset) : pc + 4
    }

    private func executeTestAndBranch(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let bitNumber = Int(((instruction >> 31) & 0x1) << 5 | ((instruction >> 19) & 0x1f))
        let bitIsSet = ((readRegister(vm, rt) >> UInt64(bitNumber)) & 0x1) == 1
        let branchesOnNonZero = ((instruction >> 24) & 0x1) == 1
        let shouldBranch = bitIsSet == branchesOnNonZero
        let offset = signExtend((instruction >> 5) & 0x3fff, bits: 14) << 2

        vm.cpu.pc = shouldBranch ? addSignedOffset(pc, offset) : pc + 4
    }

    private func executeConditionalCompareRegister(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let subtract = ((instruction >> 30) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let condition = UInt8((instruction >> 12) & 0xf)
        let rn = Int((instruction >> 5) & 0x1f)
        let fallbackNZCV = UInt64(instruction & 0xf) << 28

        if conditionHolds(condition, pstate: vm.cpu.pstate) {
            let bits = is64Bit ? 64 : 32
            let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
            let rhs = maskedOperand(readRegister(vm, rm), bits: bits)
            let flags = subtract
                ? subtractNZCV(lhs: lhs, rhs: rhs, bits: bits)
                : addNZCV(lhs: lhs, rhs: rhs, bits: bits)
            setNZCV(flags, in: vm)
        } else {
            setNZCV(fallbackNZCV, in: vm)
        }

        vm.cpu.pc = pc + 4
    }

    private func executeConditionalCompareImmediate(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let subtract = ((instruction >> 30) & 0x1) == 1
        let imm5 = UInt64((instruction >> 16) & 0x1f)
        let condition = UInt8((instruction >> 12) & 0xf)
        let rn = Int((instruction >> 5) & 0x1f)
        let fallbackNZCV = UInt64(instruction & 0xf) << 28

        if conditionHolds(condition, pstate: vm.cpu.pstate) {
            let bits = is64Bit ? 64 : 32
            let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
            let rhs = maskedOperand(imm5, bits: bits)
            let flags = subtract
                ? subtractNZCV(lhs: lhs, rhs: rhs, bits: bits)
                : addNZCV(lhs: lhs, rhs: rhs, bits: bits)
            setNZCV(flags, in: vm)
        } else {
            setNZCV(fallbackNZCV, in: vm)
        }

        vm.cpu.pc = pc + 4
    }

    private func executeConditionalBranch(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let offset = signExtend((instruction >> 5) & 0x7_ffff, bits: 19) << 2
        let condition = UInt8(instruction & 0xf)

        vm.cpu.pc = conditionHolds(condition, pstate: vm.cpu.pstate) ? addSignedOffset(pc, offset) : pc + 4
    }

    private func executeAddSubtractWithCarry(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let subtract = ((instruction >> 30) & 0x1) == 1
        let setFlags = ((instruction >> 29) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let mask = maskForBits(bits)
        let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
        let rhs = maskedOperand(readRegister(vm, rm), bits: bits)
        let carryIn = (vm.cpu.pstate & 0x2000_0000) != 0
        let addend = subtract ? ~rhs & mask : rhs
        let (result, flags) = addWithCarryNZCV(lhs: lhs, rhs: addend, carryIn: carryIn, bits: bits)

        if setFlags {
            setNZCV(flags, in: vm)
        }

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeConditionalSelect(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let invertOrNegate = ((instruction >> 30) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let condition = UInt8((instruction >> 12) & 0xf)
        let operation = (instruction >> 10) & 0x3
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard operation <= 1 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let value: UInt64
        if conditionHolds(condition, pstate: vm.cpu.pstate) {
            value = readRegister(vm, rn)
        } else {
            let fallback = readRegister(vm, rm)
            if operation == 0 {
                value = invertOrNegate ? ~fallback : fallback
            } else {
                value = invertOrNegate ? 0 &- fallback : fallback &+ 1
            }
        }

        writeRegister(vm, rd, maskedOperand(value, bits: bits))
        vm.cpu.pc = pc + 4
    }

    private func executeRegisterBranch(_ vm: VirtualMachine, instruction: UInt32, link: Bool) {
        let rn = Int((instruction >> 5) & 0x1f)
        if link {
            vm.cpu.x[30] = vm.cpu.pc + 4
        }
        vm.cpu.pc = readRegister(vm, rn)
    }

    private func executeMoveWide(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let opcode = (instruction >> 29) & 0x3
        let rd = Int(instruction & 0x1f)
        let hw = (instruction >> 21) & 0x3
        guard is64Bit || hw <= 1 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let shift = UInt64(hw * 16)
        let imm = UInt64((instruction >> 5) & 0xffff) << shift
        let mask = maskForBits(bits)

        switch opcode {
        case 0:
            writeRegister(vm, rd, ~imm & mask)
        case 2:
            writeRegister(vm, rd, imm & mask)
        case 3:
            let fieldMask = (UInt64(0xffff) << shift) & mask
            writeRegister(vm, rd, (readRegister(vm, rd) & ~fieldMask & mask) | (imm & fieldMask))
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        vm.cpu.pc = pc + 4
    }

    private func executeLogicalImmediate(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let opcode = (instruction >> 29) & 0x3
        let n = UInt8((instruction >> 22) & 0x1)
        let immr = UInt8((instruction >> 16) & 0x3f)
        let imms = UInt8((instruction >> 10) & 0x3f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard let immediate = decodeLogicalImmediate(n: n, immr: immr, imms: imms, bits: bits) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
        let result: UInt64
        switch opcode {
        case 0:
            result = lhs & immediate
        case 1:
            result = lhs | immediate
        case 2:
            result = lhs ^ immediate
        case 3:
            result = lhs & immediate
            setNZCV(
                nzcv(
                    negative: (result & (UInt64(1) << UInt64(bits - 1))) != 0,
                    zero: result == 0,
                    carry: false,
                    overflow: false
                ),
                in: vm
            )
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeRegister(vm, rd, maskedOperand(result, bits: bits))
        vm.cpu.pc = pc + 4
    }

    private func executeLogicalShiftedRegister(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let opcode = (instruction >> 29) & 0x3
        let shiftType = UInt8((instruction >> 22) & 0x3)
        let invertOperand = ((instruction >> 21) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let shift = Int((instruction >> 10) & 0x3f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard is64Bit || shift < 32 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let mask = maskForBits(bits)
        let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
        var rhs = shiftedRegisterValue(readRegister(vm, rm), shiftType: shiftType, amount: shift, bits: bits)
        if invertOperand {
            rhs = ~rhs & mask
        }

        let result: UInt64
        switch opcode {
        case 0:
            result = lhs & rhs
        case 1:
            result = lhs | rhs
        case 2:
            result = lhs ^ rhs
        case 3:
            result = lhs & rhs
            setNZCV(
                nzcv(
                    negative: (result & (UInt64(1) << UInt64(bits - 1))) != 0,
                    zero: result == 0,
                    carry: false,
                    overflow: false
                ),
                in: vm
            )
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeRegister(vm, rd, result & mask)
        vm.cpu.pc = pc + 4
    }

    private func executeBitfieldMove(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let opcode = (instruction >> 29) & 0x3
        let n = UInt8((instruction >> 22) & 0x1)
        let immr = UInt8((instruction >> 16) & 0x3f)
        let imms = UInt8((instruction >> 10) & 0x3f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard opcode != 3, let masks = decodeBitfieldMasks(n: n, immr: immr, imms: imms, bits: bits) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let source = maskedOperand(readRegister(vm, rn), bits: bits)
        let rotated = rotateRight(source, by: Int(immr), width: bits)
        let result: UInt64
        switch opcode {
        case 0:
            let partial = (rotated & masks.writeMask) & masks.topMask
            let signBit = (source >> UInt64(Int(imms) & (bits - 1))) & 0x1
            let signFill = signBit == 1 ? maskForBits(bits) : 0
            result = (signFill & ~masks.topMask) | partial
        case 1:
            let insert = bitfieldInsert(source: source, immr: immr, imms: imms, bits: bits)
            result = (readRegister(vm, rd) & ~insert.mask & maskForBits(bits)) | (insert.value & insert.mask)
        case 2:
            result = (rotated & masks.writeMask) & masks.topMask
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeExtractRegister(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let n = ((instruction >> 22) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let lsb = Int((instruction >> 10) & 0x3f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard n == is64Bit, lsb < bits else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let low = maskedOperand(readRegister(vm, rm), bits: bits)
        let high = maskedOperand(readRegister(vm, rn), bits: bits)
        let result: UInt64
        if lsb == 0 {
            result = low
        } else {
            result = ((high << UInt64(bits - lsb)) | (low >> UInt64(lsb))) & maskForBits(bits)
        }

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeMultiplyAddSubtract(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let rm = Int((instruction >> 16) & 0x1f)
        let subtract = ((instruction >> 15) & 0x1) == 1
        let ra = Int((instruction >> 10) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
        let rhs = maskedOperand(readRegister(vm, rm), bits: bits)
        let addend = maskedOperand(readRegister(vm, ra), bits: bits)
        let product = maskedOperand(lhs &* rhs, bits: bits)
        let result = maskedOperand(subtract ? addend &- product : addend &+ product, bits: bits)

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeSignedMultiplyLongAddSubtract(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rm = Int((instruction >> 16) & 0x1f)
        let subtract = ((instruction >> 15) & 0x1) == 1
        let ra = Int((instruction >> 10) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let lhs = Int64(Int32(truncatingIfNeeded: readRegister(vm, rn)))
        let rhs = Int64(Int32(truncatingIfNeeded: readRegister(vm, rm)))
        let addend = readRegister(vm, ra)
        let product = UInt64(bitPattern: lhs &* rhs)
        let result = subtract ? addend &- product : addend &+ product

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeUnsignedMultiplyLongAddSubtract(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rm = Int((instruction >> 16) & 0x1f)
        let subtract = ((instruction >> 15) & 0x1) == 1
        let ra = Int((instruction >> 10) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let lhs = UInt64(UInt32(truncatingIfNeeded: readRegister(vm, rn)))
        let rhs = UInt64(UInt32(truncatingIfNeeded: readRegister(vm, rm)))
        let addend = readRegister(vm, ra)
        let product = lhs &* rhs
        let result = subtract ? addend &- product : addend &+ product

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeSignedMultiplyHigh(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rm = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let lhs = Int64(bitPattern: readRegister(vm, rn))
        let rhs = Int64(bitPattern: readRegister(vm, rm))
        let product = lhs.multipliedFullWidth(by: rhs)

        writeRegister(vm, rd, UInt64(bitPattern: product.high))
        vm.cpu.pc = pc + 4
    }

    private func executeUnsignedMultiplyHigh(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rm = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let lhs = readRegister(vm, rn)
        let rhs = readRegister(vm, rm)
        let product = lhs.multipliedFullWidth(by: rhs)

        writeRegister(vm, rd, product.high)
        vm.cpu.pc = pc + 4
    }

    private func executeDataProcessingOneSource(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let opcode = (instruction >> 10) & 0x3f
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let source = maskedOperand(readRegister(vm, rn), bits: bits)
        let result: UInt64

        switch opcode {
        case 0x00:
            result = reverseBits(source, bits: bits)
        case 0x01:
            result = reverseBytes(source, groupBytes: 2, bits: bits)
        case 0x02:
            result = reverseBytes(source, groupBytes: 4, bits: bits)
        case 0x03 where is64Bit:
            result = reverseBytes(source, groupBytes: 8, bits: bits)
        case 0x04:
            result = UInt64(countLeadingZeros(source, bits: bits))
        case 0x05:
            result = UInt64(countLeadingSignBits(source, bits: bits))
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeDataProcessingTwoSource(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let rm = Int((instruction >> 16) & 0x1f)
        let opcode = (instruction >> 10) & 0x3f
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)
        let amount = Int(readRegister(vm, rm) & UInt64(bits - 1))
        let source = readRegister(vm, rn)
        let shiftType: UInt8

        switch opcode {
        case 0x02:
            let dividend = maskedOperand(readRegister(vm, rn), bits: bits)
            let divisor = maskedOperand(readRegister(vm, rm), bits: bits)
            let result = divisor == 0 ? 0 : dividend / divisor
            writeRegister(vm, rd, maskedOperand(result, bits: bits))
            vm.cpu.pc = pc + 4
            return
        case 0x03:
            writeRegister(vm, rd, signedDivide(readRegister(vm, rn), by: readRegister(vm, rm), bits: bits))
            vm.cpu.pc = pc + 4
            return
        case 0x08:
            shiftType = 0
        case 0x09:
            shiftType = 1
        case 0x0a:
            shiftType = 2
        case 0x0b:
            shiftType = 3
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeRegister(vm, rd, shiftedRegisterValue(source, shiftType: shiftType, amount: amount, bits: bits))
        vm.cpu.pc = pc + 4
    }

    private func signedDivide(_ dividend: UInt64, by divisor: UInt64, bits: Int) -> UInt64 {
        if bits == 32 {
            let lhs = Int32(bitPattern: UInt32(truncatingIfNeeded: dividend))
            let rhs = Int32(bitPattern: UInt32(truncatingIfNeeded: divisor))
            guard rhs != 0 else {
                return 0
            }
            if lhs == Int32.min && rhs == -1 {
                return UInt64(UInt32(bitPattern: Int32.min))
            }
            return UInt64(UInt32(bitPattern: lhs / rhs))
        }

        let lhs = Int64(bitPattern: dividend)
        let rhs = Int64(bitPattern: divisor)
        guard rhs != 0 else {
            return 0
        }
        if lhs == Int64.min && rhs == -1 {
            return UInt64(bitPattern: Int64.min)
        }
        return UInt64(bitPattern: lhs / rhs)
    }

    private func executeAddSubShiftedRegister(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let subtract = ((instruction >> 30) & 0x1) == 1
        let setFlags = ((instruction >> 29) & 0x1) == 1
        let shiftType = UInt8((instruction >> 22) & 0x3)
        let rm = Int((instruction >> 16) & 0x1f)
        let shift = Int((instruction >> 10) & 0x3f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard shiftType <= 2, is64Bit || shift < 32 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let lhs = maskedOperand(readRegister(vm, rn), bits: bits)
        let rhs = shiftedRegisterValue(readRegister(vm, rm), shiftType: shiftType, amount: shift, bits: bits)
        let result = maskedOperand(subtract ? lhs &- rhs : lhs &+ rhs, bits: bits)

        if setFlags {
            let flags = subtract
                ? subtractNZCV(lhs: lhs, rhs: rhs, bits: bits)
                : addNZCV(lhs: lhs, rhs: rhs, bits: bits)
            setNZCV(flags, in: vm)
        }

        writeRegister(vm, rd, result)
        vm.cpu.pc = pc + 4
    }

    private func executeAddSubExtendedRegister(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let is64Bit = ((instruction >> 31) & 0x1) == 1
        let bits = is64Bit ? 64 : 32
        let subtract = ((instruction >> 30) & 0x1) == 1
        let setFlags = ((instruction >> 29) & 0x1) == 1
        let rm = Int((instruction >> 16) & 0x1f)
        let option = UInt8((instruction >> 13) & 0x7)
        let shift = Int((instruction >> 10) & 0x7)
        let rn = Int((instruction >> 5) & 0x1f)
        let rd = Int(instruction & 0x1f)

        guard shift <= 4 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let lhs = maskedOperand(baseRegister(vm, rn), bits: bits)
        let rhs = maskedOperand(extendedRegisterValue(readRegister(vm, rm), option: option) << UInt64(shift), bits: bits)
        let result = maskedOperand(subtract ? lhs &- rhs : lhs &+ rhs, bits: bits)

        if setFlags {
            let flags = subtract
                ? subtractNZCV(lhs: lhs, rhs: rhs, bits: bits)
                : addNZCV(lhs: lhs, rhs: rhs, bits: bits)
            setNZCV(flags, in: vm)
            writeRegister(vm, rd, result)
        } else {
            writeBaseRegister(vm, rd, result)
        }

        vm.cpu.pc = pc + 4
    }

    private func executeAddSubImmediate(
        _ vm: VirtualMachine,
        instruction: UInt32,
        subtract: Bool,
        setFlags: Bool,
        is64Bit: Bool
    ) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let shift = ((instruction >> 22) & 0x1) == 1 ? 12 : 0
        let operand = imm12 << UInt64(shift)
        let bits = is64Bit ? 64 : 32
        let lhs = maskedOperand(baseRegister(vm, rn), bits: bits)
        let rhs = maskedOperand(operand, bits: bits)
        let result = maskedOperand(subtract ? lhs &- rhs : lhs &+ rhs, bits: bits)

        if setFlags {
            let flags = subtract
                ? subtractNZCV(lhs: lhs, rhs: rhs, bits: bits)
                : addNZCV(lhs: lhs, rhs: rhs, bits: bits)
            setNZCV(flags, in: vm)
            writeRegister(vm, rd, result)
        } else {
            writeBaseRegister(vm, rd, result)
        }
        vm.cpu.pc = pc + 4
    }

    private func executeStoreByte(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + imm12
        do {
            try vm.writeGuest(address, width: .byte, value: readRegister(vm, rt) & 0xff)
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadByte(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + imm12
        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .byte))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStoreHalfword(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 2)
        do {
            try vm.writeGuest(address, width: .halfword, value: readRegister(vm, rt) & 0xffff)
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadHalfword(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 2)
        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .halfword))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStore32(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 4)
        do {
            try vm.writeGuest(address, width: .word, value: readRegister(vm, rt) & 0xffff_ffff)
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoad32(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 4)
        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .word))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadSignedUnsignedImmediate(
        _ vm: VirtualMachine,
        instruction: UInt32,
        width: MMIOWidth,
        resultBits: Int
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * UInt64(width.rawValue))

        do {
            let loaded = try vm.readGuest(address, width: width)
            let extended = signExtendLoaded(loaded, bits: width.rawValue * 8)
            writeRegister(vm, rt, resultBits == 32 ? extended & 0xffff_ffff : extended)
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStore64(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 8)
        do {
            try vm.writeGuest(address, width: .doubleword, value: readRegister(vm, rt))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoad64(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let address = baseRegister(vm, rn) + (imm12 * 8)
        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .doubleword))
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeSIMDFPLoadStoreUnsignedImmediate(
        _ vm: VirtualMachine,
        instruction: UInt32,
        load: Bool,
        bytes: UInt64
    ) throws {
        let pc = vm.cpu.pc
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let address = baseRegister(vm, rn) &+ (imm12 * bytes)

        do {
            switch (load, bytes) {
            case (true, 1):
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .byte),
                    high: 0
                )
            case (false, 1):
                try vm.writeGuest(address, width: .byte, value: vm.cpu.v[rt].low & 0xff)
            case (true, 2):
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .halfword),
                    high: 0
                )
            case (false, 2):
                try vm.writeGuest(address, width: .halfword, value: vm.cpu.v[rt].low & 0xffff)
            case (true, 4):
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .word),
                    high: 0
                )
            case (false, 4):
                try vm.writeGuest(address, width: .word, value: vm.cpu.v[rt].low & 0xffff_ffff)
            case (true, 8):
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .doubleword),
                    high: 0
                )
            case (false, 8):
                try vm.writeGuest(address, width: .doubleword, value: vm.cpu.v[rt].low)
            case (true, 16):
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .doubleword),
                    high: try vm.readGuest(address + 8, width: .doubleword)
                )
            case (false, 16):
                let value = vm.cpu.v[rt]
                try vm.writeGuest(address, width: .doubleword, value: value.low)
                try vm.writeGuest(address + 8, width: .doubleword, value: value.high)
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeSIMDFPScalarByteUnsignedImmediate(
        _ vm: VirtualMachine,
        instruction: UInt32,
        load: Bool
    ) throws {
        let pc = vm.cpu.pc
        let imm12 = UInt64((instruction >> 10) & 0xfff)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let address = baseRegister(vm, rn) &+ imm12

        do {
            if load {
                vm.cpu.v[rt] = ARM64VectorRegister(low: try vm.readGuest(address, width: .byte), high: 0)
            } else {
                try vm.writeGuest(address, width: .byte, value: vm.cpu.v[rt].low & 0xff)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeSIMDFPQSignedImmediateLoadStore(
        _ vm: VirtualMachine,
        instruction: UInt32
    ) throws {
        let pc = vm.cpu.pc
        let opcode = (instruction >> 22) & 0x3
        let mode = (instruction >> 10) & 0x3
        let offset = signExtend((instruction >> 12) & 0x1ff, bits: 9)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let base = baseRegister(vm, rn)
        let address: UInt64
        let writeback: UInt64?

        switch mode {
        case 0:
            address = addSignedOffset(base, offset)
            writeback = nil
        case 1:
            address = base
            writeback = addSignedOffset(base, offset)
        case 3:
            address = addSignedOffset(base, offset)
            writeback = address
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            if opcode == 3 {
                vm.cpu.v[rt] = ARM64VectorRegister(
                    low: try vm.readGuest(address, width: .doubleword),
                    high: try vm.readGuest(address + 8, width: .doubleword)
                )
            } else {
                let value = vm.cpu.v[rt]
                try vm.writeGuest(address, width: .doubleword, value: value.low)
                try vm.writeGuest(address + 8, width: .doubleword, value: value.high)
            }
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeSIMDDuplicateGeneral(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm5 = (instruction >> 16) & 0x1f
        let writesFullVector = ((instruction >> 30) & 0x1) == 1

        guard imm5 != 0 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let elementBits = 8 << imm5.trailingZeroBitCount
        guard elementBits <= 64, writesFullVector || elementBits < 64 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let element = readRegister(vm, rn) & maskForBits(elementBits)
        vm.cpu.v[rd] = duplicateSIMDElement(element, elementBits: elementBits, writesFullVector: writesFullVector)
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDMoveVectorElementToGeneral(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)

        writeRegister(vm, rd, vm.cpu.v[rn].low)
        vm.cpu.pc += 4
    }

    private func executeFPScalarGeneralMove(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)

        switch instruction & 0xffff_fc00 {
        case 0x1e27_0000:
            vm.cpu.v[rd] = ARM64VectorRegister(low: readRegister(vm, rn) & 0xffff_ffff, high: 0)
        case 0x1e26_0000:
            writeRegister(vm, rd, vm.cpu.v[rn].low & 0xffff_ffff)
        case 0x9e67_0000:
            vm.cpu.v[rd] = ARM64VectorRegister(low: readRegister(vm, rn), high: 0)
        case 0x9e66_0000:
            writeRegister(vm, rd, vm.cpu.v[rn].low)
        case 0x9eaf_0000:
            vm.cpu.v[rd].high = readRegister(vm, rn)
        case 0x9eae_0000:
            writeRegister(vm, rd, vm.cpu.v[rn].high)
        default:
            break
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarRegisterMove(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            vm.cpu.v[rd] = ARM64VectorRegister(low: vm.cpu.v[rn].low, high: 0)
        } else {
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(UInt32(truncatingIfNeeded: vm.cpu.v[rn].low)), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarImmediateMove(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let imm8 = UInt64((instruction >> 13) & 0xff)
        let isDouble = ((instruction >> 22) & 1) == 1
        let bits = expandFPImmediate(imm8, elementBits: isDouble ? 64 : 32)
        vm.cpu.v[rd] = ARM64VectorRegister(low: bits, high: 0)

        vm.cpu.pc += 4
    }

    private func executeFPIntegerToScalarFP(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let is64BitSource = ((instruction >> 31) & 0x1) == 1
        let isDoubleDestination = ((instruction >> 22) & 0x1) == 1
        let isSigned = ((instruction >> 16) & 0x1) == 0
        let source = readRegister(vm, rn)
        let isFixedPoint = (instruction & 0x7f3f_0000) == 0x1e02_0000 ||
            (instruction & 0x7f3f_0000) == 0x1e03_0000
        let fractionalBits = isFixedPoint ? 64 - Int((instruction >> 10) & 0x3f) : 0
        let divisor = pow(2.0, Double(fractionalBits))

        if isDoubleDestination {
            let value: Double
            if isSigned {
                value = (is64BitSource ? Double(Int64(bitPattern: source)) : Double(Int32(bitPattern: UInt32(source)))) / divisor
            } else {
                value = (is64BitSource ? Double(source) : Double(UInt32(source))) / divisor
            }
            vm.cpu.v[rd] = ARM64VectorRegister(low: value.bitPattern, high: 0)
        } else {
            let value: Float
            if isSigned {
                value = (is64BitSource ? Float(Int64(bitPattern: source)) : Float(Int32(bitPattern: UInt32(source)))) / Float(divisor)
            } else {
                value = (is64BitSource ? Float(source) : Float(UInt32(source))) / Float(divisor)
            }
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(value.bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarAdd(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (lhs + rhs).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64((lhs + rhs).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarSubtract(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (lhs - rhs).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64((lhs - rhs).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarMultiply(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (lhs * rhs).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64((lhs * rhs).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarDivide(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (lhs / rhs).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64((lhs / rhs).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarNegatedMultiply(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (-(lhs * rhs)).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64((-(lhs * rhs)).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarFusedMultiplyAdd(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let ra = Int((instruction >> 10) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let subtractAddend = ((instruction >> 15) & 0x1) == 1
        let negateResult = ((instruction >> 21) & 0x1) == 1
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            let accumulator = Double(bitPattern: vm.cpu.v[ra].low)
            let addend = subtractAddend ? -accumulator : accumulator
            let result = addend.addingProduct(lhs, rhs)
            vm.cpu.v[rd] = ARM64VectorRegister(low: (negateResult ? -result : result).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            let accumulator = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[ra].low))
            let addend = subtractAddend ? -accumulator : accumulator
            let result = addend.addingProduct(lhs, rhs)
            vm.cpu.v[rd] = ARM64VectorRegister(
                low: UInt64((negateResult ? -result : result).bitPattern),
                high: 0
            )
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarUnary(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let opcode = instruction & 0xffff_fc00
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let source = Double(bitPattern: vm.cpu.v[rn].low)
            let result: Double
            switch opcode {
            case 0x1e60_c000: result = abs(source)
            case 0x1e61_4000: result = -source
            case 0x1e61_c000: result = source.squareRoot()
            default: return
            }
            vm.cpu.v[rd] = ARM64VectorRegister(low: result.bitPattern, high: 0)
        } else {
            let source = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let result: Float
            switch opcode {
            case 0x1e20_c000: result = abs(source)
            case 0x1e21_4000: result = -source
            case 0x1e21_c000: result = source.squareRoot()
            default: return
            }
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(result.bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarRoundIntegral(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1
        let rule = fpIntegralRoundingRule(
            instruction: instruction,
            fpcr: vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpcr)
        )

        if isDouble {
            let source = Double(bitPattern: vm.cpu.v[rn].low)
            let bits = source.isFinite ? source.rounded(rule).bitPattern : source.bitPattern
            vm.cpu.v[rd] = ARM64VectorRegister(low: bits, high: 0)
        } else {
            let source = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let bits = source.isFinite ? source.rounded(rule).bitPattern : source.bitPattern
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(bits), high: 0)
        }
        vm.cpu.pc += 4
    }

    private func fpIntegralRoundingRule(instruction: UInt32, fpcr: UInt64) -> FloatingPointRoundingRule {
        switch instruction & 0xffff_fc00 {
        case 0x1e24_4000, 0x1e64_4000:
            return .toNearestOrEven
        case 0x1e24_c000, 0x1e64_c000:
            return .up
        case 0x1e25_4000, 0x1e65_4000:
            return .down
        case 0x1e25_c000, 0x1e65_c000:
            return .towardZero
        case 0x1e26_4000, 0x1e66_4000:
            return .toNearestOrAwayFromZero
        default:
            switch (fpcr >> 22) & 0x3 {
            case 1: return .up
            case 2: return .down
            case 3: return .towardZero
            default: return .toNearestOrEven
            }
        }
    }

    private func executeSIMDScalarFPAbsoluteDifference(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            vm.cpu.v[rd] = ARM64VectorRegister(low: abs(lhs - rhs).bitPattern, high: 0)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(abs(lhs - rhs).bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarConditionalSelect(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let condition = UInt8((instruction >> 12) & 0xf)
        let isDouble = ((instruction >> 22) & 0x1) == 1
        let source = conditionHolds(condition, pstate: vm.cpu.pstate) ? vm.cpu.v[rn] : vm.cpu.v[rm]

        if isDouble {
            vm.cpu.v[rd] = ARM64VectorRegister(low: source.low, high: 0)
        } else {
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(UInt32(truncatingIfNeeded: source.low)), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarConditionalCompare(_ vm: VirtualMachine, instruction: UInt32) {
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let condition = UInt8((instruction >> 12) & 0xf)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if conditionHolds(condition, pstate: vm.cpu.pstate) {
            if isDouble {
                let lhs = Double(bitPattern: vm.cpu.v[rn].low)
                let rhs = Double(bitPattern: vm.cpu.v[rm].low)
                setNZCV(fpCompareNZCV(lhs, rhs), in: vm)
            } else {
                let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
                let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
                setNZCV(fpCompareNZCV(lhs, rhs), in: vm)
            }
        } else {
            setNZCV(UInt64(instruction & 0xf) << 28, in: vm)
        }
        vm.cpu.pc += 4
    }

    private func executeFPScalarCompareZero(_ vm: VirtualMachine, instruction: UInt32) {
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let value = Double(bitPattern: vm.cpu.v[rn].low)
            setNZCV(fpCompareNZCV(value, 0), in: vm)
        } else {
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            setNZCV(fpCompareNZCV(value, 0), in: vm)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarCompareRegister(_ vm: VirtualMachine, instruction: UInt32) {
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1

        if isDouble {
            let lhs = Double(bitPattern: vm.cpu.v[rn].low)
            let rhs = Double(bitPattern: vm.cpu.v[rm].low)
            setNZCV(fpCompareNZCV(lhs, rhs), in: vm)
        } else {
            let lhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            let rhs = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rm].low))
            setNZCV(fpCompareNZCV(lhs, rhs), in: vm)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarConvertToSignedInteger(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1
        let writesGeneralRegister = (instruction & 0x4000_0000) == 0
        let bits = (instruction & 0x8000_0000) == 0 ? 32 : 64
        let converted: UInt64

        if isDouble {
            let value = Double(bitPattern: vm.cpu.v[rn].low)
            converted = signedIntegerBitsFromFP(
                roundedFPToInteger(value, instruction: instruction),
                bits: writesGeneralRegister ? bits : 64
            )
        } else {
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            converted = signedIntegerBitsFromFP(
                roundedFPToInteger(Double(value), instruction: instruction),
                bits: 32
            )
        }

        if writesGeneralRegister {
            vm.cpu.x[rd] = bits == 32 ? UInt64(UInt32(truncatingIfNeeded: converted)) : converted
        } else {
            vm.cpu.v[rd] = ARM64VectorRegister(low: converted, high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeFPScalarConvertToUnsignedIntegerRegister(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1
        let writesVectorRegister = (instruction & 0x4000_0000) != 0
        let bits = writesVectorRegister
            ? (isDouble ? 64 : 32)
            : ((instruction & 0x8000_0000) == 0 ? 32 : 64)
        let converted: UInt64

        if isDouble {
            converted = unsignedIntegerBitsFromFP(
                roundedFPToInteger(Double(bitPattern: vm.cpu.v[rn].low), instruction: instruction),
                bits: bits
            )
        } else {
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: vm.cpu.v[rn].low))
            converted = unsignedIntegerBitsFromFP(
                roundedFPToInteger(Double(value), instruction: instruction),
                bits: bits
            )
        }

        if writesVectorRegister {
            vm.cpu.v[rd] = ARM64VectorRegister(
                low: bits == 32 ? UInt64(UInt32(truncatingIfNeeded: converted)) : converted,
                high: 0
            )
        } else {
            vm.cpu.x[rd] = bits == 32 ? UInt64(UInt32(truncatingIfNeeded: converted)) : converted
        }
        vm.cpu.pc += 4
    }

    private func executeSIMDScalarSignedIntegerToFP(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let isDouble = ((instruction >> 22) & 0x1) == 1
        let isUnsigned = ((instruction >> 29) & 0x1) == 1

        if isDouble {
            let value = isUnsigned
                ? Double(vm.cpu.v[rn].low)
                : Double(Int64(bitPattern: vm.cpu.v[rn].low))
            vm.cpu.v[rd] = ARM64VectorRegister(low: value.bitPattern, high: 0)
        } else {
            let source = UInt32(truncatingIfNeeded: vm.cpu.v[rn].low)
            let value = isUnsigned ? Float(source) : Float(Int32(bitPattern: source))
            vm.cpu.v[rd] = ARM64VectorRegister(low: UInt64(value.bitPattern), high: 0)
        }

        vm.cpu.pc += 4
    }

    private func executeSIMDInsertGeneralToElement(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm5 = (instruction >> 16) & 0x1f

        guard imm5 != 0 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let elementBits = 8 << imm5.trailingZeroBitCount
        let lane = Int(imm5 >> UInt32(imm5.trailingZeroBitCount + 1))
        guard elementBits <= 64, lane < 128 / elementBits else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        writeVectorElement(
            vm,
            vector: rd,
            lane: lane,
            elementBits: elementBits,
            value: readRegister(vm, rn)
        )
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDInsertVectorElement(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let imm5 = (instruction >> 16) & 0x1f
        let imm4 = (instruction >> 11) & 0x0f
        guard imm5 != 0 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let trailing = imm5.trailingZeroBitCount
        let elementBits = 8 << trailing
        let destinationLane = Int(imm5 >> UInt32(trailing + 1))
        let sourceLane = Int(imm4 >> UInt32(trailing))
        let laneCount = 128 / elementBits
        let alignmentMask = (UInt32(1) << UInt32(trailing)) - 1
        guard elementBits <= 64,
              (imm4 & alignmentMask) == 0,
              destinationLane < laneCount,
              sourceLane < laneCount else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let value = readVectorElement(vm.cpu.v[rn], lane: sourceLane, elementBits: elementBits)
        writeVectorElement(vm, vector: rd, lane: destinationLane, elementBits: elementBits, value: value)
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDSignedShiftLongSToD(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let shift = Int((instruction >> 16) & 0x7)
        let sourceLaneBase = ((instruction >> 30) & 0x1) == 1 ? 2 : 0

        guard shift < 32 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let first = signExtendVectorElement(vm.cpu.v[rn], lane: sourceLaneBase, elementBits: 32) << UInt64(shift)
        let second = signExtendVectorElement(vm.cpu.v[rn], lane: sourceLaneBase + 1, elementBits: 32) << UInt64(shift)
        vm.cpu.v[rd] = ARM64VectorRegister(low: first, high: second)
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDTableLookup(_ vm: VirtualMachine, instruction: UInt32) {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let preserveDestination = ((instruction >> 12) & 0x1) == 1
        let tableRegisterCount = Int(((instruction >> 13) & 0x3) + 1)
        let tableByteCount = tableRegisterCount * 16
        var result = ARM64VectorRegister()
        if preserveDestination {
            result = ARM64VectorRegister(
                low: vm.cpu.v[rd].low,
                high: q ? vm.cpu.v[rd].high : 0
            )
        }

        for lane in 0..<(q ? 16 : 8) {
            let index = Int(readVectorElement(vm.cpu.v[rm], lane: lane, elementBits: 8))
            let byte: UInt64
            if index < tableByteCount {
                let sourceRegister = (rn + (index / 16)) & 0x1f
                byte = readVectorElement(vm.cpu.v[sourceRegister], lane: index & 0xf, elementBits: 8)
            } else if preserveDestination {
                byte = readVectorElement(vm.cpu.v[rd], lane: lane, elementBits: 8)
            } else {
                byte = 0
            }
            writeVectorElement(&result, lane: lane, elementBits: 8, value: byte)
        }

        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDPermuteTwoVector(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let size = Int((instruction >> 22) & 0x3)
        let op = Int((instruction >> 12) & 0x7)
        let elementBits = 8 << size
        let vectorBits = q ? 128 : 64
        let laneCount = vectorBits / elementBits
        let halfLaneCount = laneCount / 2
        let operation = op & 0x3
        let secondPart = (op & 0x4) != 0
        var result = ARM64VectorRegister()

        guard laneCount >= 2, operation != 0 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        for lane in 0..<laneCount {
            let source: (register: Int, lane: Int)
            switch operation {
            case 1:
                if lane < halfLaneCount {
                    source = (rn, lane * 2 + (secondPart ? 1 : 0))
                } else {
                    source = (rm, (lane - halfLaneCount) * 2 + (secondPart ? 1 : 0))
                }
            case 2:
                source = (
                    (lane & 1) == 0 ? rn : rm,
                    (lane / 2) * 2 + (secondPart ? 1 : 0)
                )
            case 3:
                source = (
                    (lane & 1) == 0 ? rn : rm,
                    (lane / 2) + (secondPart ? halfLaneCount : 0)
                )
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }

            writeVectorElement(
                &result,
                lane: lane,
                elementBits: elementBits,
                value: readVectorElement(vm.cpu.v[source.register], lane: source.lane, elementBits: elementBits)
            )
        }

        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDAddVector(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let size = Int((instruction >> 22) & 0x3)
        let elementBits = 8 << size
        let vectorBits = q ? 128 : 64

        guard elementBits <= 64, !(elementBits == 64 && !q) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let laneMask = maskForBits(elementBits)
        var result = ARM64VectorRegister()
        for lane in 0..<(vectorBits / elementBits) {
            let sum = (readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: elementBits) &+
                readVectorElement(vm.cpu.v[rm], lane: lane, elementBits: elementBits)) & laneMask
            writeVectorElement(&result, lane: lane, elementBits: elementBits, value: sum)
        }

        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDIntegerNegate(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let elementBits = 8 << Int((instruction >> 22) & 0x3)
        let vectorBits = q ? 128 : 64

        guard elementBits <= 64, !(elementBits == 64 && !q) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let laneMask = maskForBits(elementBits)
        var result = ARM64VectorRegister()
        for lane in 0..<(vectorBits / elementBits) {
            let source = readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: elementBits)
            writeVectorElement(
                &result,
                lane: lane,
                elementBits: elementBits,
                value: (0 &- source) & laneMask
            )
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDShiftLeftImmediate(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let encodedShift = Int((instruction >> 16) & 0x7f)
        guard encodedShift >= 8 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let elementBits: Int
        switch encodedShift {
        case 8..<16: elementBits = 8
        case 16..<32: elementBits = 16
        case 32..<64: elementBits = 32
        default: elementBits = 64
        }
        guard elementBits != 64 || q else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let shift = encodedShift - elementBits
        let vectorBits = q ? 128 : 64
        let laneMask = maskForBits(elementBits)
        var result = ARM64VectorRegister()
        for lane in 0..<(vectorBits / elementBits) {
            let source = readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: elementBits)
            writeVectorElement(
                &result,
                lane: lane,
                elementBits: elementBits,
                value: (source << UInt64(shift)) & laneMask
            )
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDMultiplyLong(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let size = Int((instruction >> 22) & 0x3)
        guard size <= 2 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let sourceBits = 8 << size
        let destinationBits = sourceBits * 2
        let sourceLaneBase = ((instruction >> 30) & 0x1) == 1 ? 64 / sourceBits : 0
        let isUnsigned = ((instruction >> 29) & 0x1) == 1
        var result = ARM64VectorRegister()

        for lane in 0..<(128 / destinationBits) {
            let sourceLane = sourceLaneBase + lane
            let product: UInt64
            if isUnsigned {
                let lhs = readVectorElement(vm.cpu.v[rn], lane: sourceLane, elementBits: sourceBits)
                let rhs = readVectorElement(vm.cpu.v[rm], lane: sourceLane, elementBits: sourceBits)
                product = lhs * rhs
            } else {
                let lhs = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rn], lane: sourceLane, elementBits: sourceBits
                ))
                let rhs = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rm], lane: sourceLane, elementBits: sourceBits
                ))
                product = UInt64(bitPattern: lhs * rhs)
            }
            writeVectorElement(&result, lane: lane, elementBits: destinationBits, value: product)
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDNarrowHigh(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let size = Int((instruction >> 22) & 0x3)
        guard size <= 2 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let sourceBits = 16 << size
        let destinationBits = sourceBits / 2
        let laneCount = 128 / sourceBits
        let writesUpperHalf = ((instruction >> 30) & 0x1) == 1
        let rounds = ((instruction >> 29) & 0x1) == 1
        let subtracts = ((instruction >> 13) & 0x1) == 1
        let sourceMask = maskForBits(sourceBits)
        let rounding = rounds ? UInt64(1) << UInt64(destinationBits - 1) : 0
        var result = writesUpperHalf ? vm.cpu.v[rd] : ARM64VectorRegister()

        for lane in 0..<laneCount {
            let lhs = readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: sourceBits)
            let rhs = readVectorElement(vm.cpu.v[rm], lane: lane, elementBits: sourceBits)
            let arithmeticResult = subtracts ? lhs &- rhs : lhs &+ rhs
            let narrowed = ((arithmeticResult &+ rounding) & sourceMask) >> UInt64(destinationBits)
            writeVectorElement(
                &result,
                lane: lane + (writesUpperHalf ? laneCount : 0),
                elementBits: destinationBits,
                value: narrowed
            )
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDBitwiseNot(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let writesFullVector = ((instruction >> 30) & 0x1) == 1
        vm.cpu.v[rd] = ARM64VectorRegister(
            low: ~vm.cpu.v[rn].low,
            high: writesFullVector ? ~vm.cpu.v[rn].high : 0
        )
        vm.cpu.pc += 4
    }

    private func executeSIMDSaturatingAddSubtract(
        _ vm: VirtualMachine,
        instruction: UInt32
    ) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let q = ((instruction >> 30) & 0x1) == 1
        let elementBits = 8 << Int((instruction >> 22) & 0x3)
        guard elementBits <= 64, elementBits != 64 || q else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let isUnsigned = ((instruction >> 29) & 0x1) == 1
        let subtracts = ((instruction >> 13) & 0x1) == 1
        let vectorBits = q ? 128 : 64
        let elementMask = maskForBits(elementBits)
        var saturated = false
        var result = ARM64VectorRegister()

        for lane in 0..<(vectorBits / elementBits) {
            let lhsBits = readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: elementBits)
            let rhsBits = readVectorElement(vm.cpu.v[rm], lane: lane, elementBits: elementBits)
            let value: UInt64
            if isUnsigned {
                if subtracts {
                    if lhsBits < rhsBits {
                        value = 0
                        saturated = true
                    } else {
                        value = lhsBits - rhsBits
                    }
                } else if lhsBits > elementMask - rhsBits {
                    value = elementMask
                    saturated = true
                } else {
                    value = lhsBits + rhsBits
                }
            } else {
                let lhs = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rn], lane: lane, elementBits: elementBits
                ))
                let rhs = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rm], lane: lane, elementBits: elementBits
                ))
                let minimum = elementBits == 64 ? Int64.min : -(Int64(1) << Int64(elementBits - 1))
                let maximum = elementBits == 64 ? Int64.max : (Int64(1) << Int64(elementBits - 1)) - 1
                let signedValue: Int64
                if subtracts {
                    if rhs < 0, lhs > maximum + rhs {
                        signedValue = maximum
                        saturated = true
                    } else if rhs > 0, lhs < minimum + rhs {
                        signedValue = minimum
                        saturated = true
                    } else {
                        signedValue = lhs - rhs
                    }
                } else if rhs > 0, lhs > maximum - rhs {
                    signedValue = maximum
                    saturated = true
                } else if rhs < 0, lhs < minimum - rhs {
                    signedValue = minimum
                    saturated = true
                } else {
                    signedValue = lhs + rhs
                }
                value = UInt64(bitPattern: signedValue) & elementMask
            }
            writeVectorElement(&result, lane: lane, elementBits: elementBits, value: value)
        }

        if saturated {
            let fpsr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.fpsr)
            vm.systemRegisters.writeRaw(ARM64SystemRegister.fpsr, value: fpsr | (UInt64(1) << 27))
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDShiftRightImmediate(
        _ vm: VirtualMachine,
        instruction: UInt32
    ) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let encodedShift = Int((instruction >> 16) & 0x7f)
        guard encodedShift >= 8 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let elementBits: Int
        switch encodedShift {
        case 8..<16: elementBits = 8
        case 16..<32: elementBits = 16
        case 32..<64: elementBits = 32
        default: elementBits = 64
        }
        let isScalar = (instruction & 0x1000_0000) != 0
        let q = ((instruction >> 30) & 0x1) == 1
        guard (!isScalar || elementBits == 64), (isScalar || elementBits != 64 || q) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        let shift = elementBits * 2 - encodedShift
        let isUnsigned = ((instruction >> 29) & 0x1) == 1
        let vectorBits = isScalar ? 64 : (q ? 128 : 64)
        let elementMask = maskForBits(elementBits)
        let signBit = UInt64(1) << UInt64(elementBits - 1)
        var result = ARM64VectorRegister()

        for lane in 0..<(vectorBits / elementBits) {
            let source = readVectorElement(vm.cpu.v[rn], lane: lane, elementBits: elementBits)
            var value = shift == elementBits ? 0 : source >> UInt64(shift)
            if !isUnsigned, (source & signBit) != 0 {
                let signFill = shift == elementBits
                    ? elementMask
                    : elementMask ^ (elementMask >> UInt64(shift))
                value |= signFill
            }
            writeVectorElement(&result, lane: lane, elementBits: elementBits, value: value)
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDPairwiseAddLong(_ vm: VirtualMachine, instruction: UInt32) {
        let q = ((instruction >> 30) & 0x1) == 1
        let isUnsigned = ((instruction >> 29) & 0x1) == 1
        let sourceBits = 8 << Int((instruction >> 22) & 0x3)
        let destinationBits = sourceBits * 2
        let sourceLaneCount = (q ? 128 : 64) / sourceBits
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        var result = ARM64VectorRegister()

        for lane in 0..<(sourceLaneCount / 2) {
            let firstLane = lane * 2
            let sum: UInt64
            if isUnsigned {
                let first = readVectorElement(vm.cpu.v[rn], lane: firstLane, elementBits: sourceBits)
                let second = readVectorElement(vm.cpu.v[rn], lane: firstLane + 1, elementBits: sourceBits)
                sum = first + second
            } else {
                let first = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rn],
                    lane: firstLane,
                    elementBits: sourceBits
                ))
                let second = Int64(bitPattern: signExtendVectorElement(
                    vm.cpu.v[rn],
                    lane: firstLane + 1,
                    elementBits: sourceBits
                ))
                sum = UInt64(bitPattern: first + second)
            }
            writeVectorElement(&result, lane: lane, elementBits: destinationBits, value: sum)
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc += 4
    }

    private func executeSIMDUnsignedMaxPairwise(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let rd = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rm = Int((instruction >> 16) & 0x1f)
        let elementBits = 8 << Int((instruction >> 22) & 0x3)
        let vectorBits = ((instruction >> 30) & 1) == 1 ? 128 : 64
        guard elementBits <= 32 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let halfLanes = vectorBits / elementBits / 2
        var result = ARM64VectorRegister()
        for lane in 0..<halfLanes {
            let left0 = readVectorElement(vm.cpu.v[rn], lane: lane * 2, elementBits: elementBits)
            let left1 = readVectorElement(vm.cpu.v[rn], lane: lane * 2 + 1, elementBits: elementBits)
            let right0 = readVectorElement(vm.cpu.v[rm], lane: lane * 2, elementBits: elementBits)
            let right1 = readVectorElement(vm.cpu.v[rm], lane: lane * 2 + 1, elementBits: elementBits)
            writeVectorElement(&result, lane: lane, elementBits: elementBits, value: max(left0, left1))
            writeVectorElement(&result, lane: halfLanes + lane, elementBits: elementBits, value: max(right0, right1))
        }
        vm.cpu.v[rd] = result
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDMoveImmediateZero(_ vm: VirtualMachine, instruction: UInt32) {
        let rd = Int(instruction & 0x1f)
        vm.cpu.v[rd] = ARM64VectorRegister()
        vm.cpu.pc += 4
    }

    private func executeSIMDMoveImmediateByte(_ vm: VirtualMachine, instruction: UInt32) {
        let q = ((instruction >> 30) & 0x1) == 1
        let rd = Int(instruction & 0x1f)
        let byte = UInt64((((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f))
        var repeated: UInt64 = 0

        for lane in 0..<8 {
            repeated |= byte << UInt64(lane * 8)
        }

        vm.cpu.v[rd] = ARM64VectorRegister(low: repeated, high: q ? repeated : 0)
        vm.cpu.pc += 4
    }

    private func executeSIMDMoveImmediateWord(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let q = ((instruction >> 30) & 0x1) == 1
        let rd = Int(instruction & 0x1f)
        guard let value = simdMoveImmediateWordValue(instruction) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let repeated = value | (value << 32)
        vm.cpu.v[rd] = ARM64VectorRegister(low: repeated, high: q ? repeated : 0)
        vm.cpu.pc = pc + 4
    }

    private func executeSIMDMoveDImmediate(_ vm: VirtualMachine, instruction: UInt32) {
        let q = ((instruction >> 30) & 0x1) == 1
        let rd = Int(instruction & 0x1f)
        let imm8 = UInt64((((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f))
        let value = expandSIMDMoveDImmediate(imm8)

        vm.cpu.v[rd] = ARM64VectorRegister(low: value, high: q ? value : 0)
        vm.cpu.pc += 4
    }

    private func executeSIMDFPImmediateMove(_ vm: VirtualMachine, instruction: UInt32) {
        let q = ((instruction >> 30) & 0x1) == 1
        let elementBits = ((instruction >> 29) & 0x1) == 1 ? 64 : 32
        let rd = Int(instruction & 0x1f)
        let imm8 = UInt64((((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f))
        vm.cpu.v[rd] = duplicateSIMDElement(
            expandFPImmediate(imm8, elementBits: elementBits),
            elementBits: elementBits,
            writesFullVector: q
        )
        vm.cpu.pc += 4
    }

    private func executeSIMDMoveInvertedImmediate(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let q = ((instruction >> 30) & 0x1) == 1
        let rd = Int(instruction & 0x1f)

        guard let immediate = simdMoveInvertedImmediateElement(instruction) else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        vm.cpu.v[rd] = duplicateSIMDElement(
            immediate.value,
            elementBits: immediate.elementBits,
            writesFullVector: q
        )
        vm.cpu.pc = pc + 4
    }

    private enum PairAddressingMode: Hashable {
        case postIndex
        case signedOffset
        case preIndex
    }

    private func executeLoadStoreSignedImmediate(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let opcode = (instruction >> 22) & 0x3
        let imm9 = signExtend((instruction >> 12) & 0x1ff, bits: 9)
        let mode = (instruction >> 10) & 0x3
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let base = baseRegister(vm, rn)
        let width: MMIOWidth

        switch size {
        case 0:
            width = .byte
        case 1:
            width = .halfword
        case 2:
            width = .word
        default:
            width = .doubleword
        }

        let address: UInt64
        let writeback: UInt64?
        switch mode {
        case 0, 2:
            address = addSignedOffset(base, imm9)
            writeback = nil
        case 1:
            address = base
            writeback = addSignedOffset(base, imm9)
        case 3:
            address = addSignedOffset(base, imm9)
            writeback = address
        default:
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            switch opcode {
            case 0:
                try vm.writeGuest(address, width: width, value: readRegister(vm, rt) & maskForBits(width.rawValue * 8))
            case 1:
                writeRegister(vm, rt, try vm.readGuest(address, width: width))
            case 2:
                guard size <= 2 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(try vm.readGuest(address, width: width), bits: width.rawValue * 8)
                )
            case 3:
                guard size <= 1 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                writeRegister(
                    vm,
                    rt,
                    signExtendLoaded(try vm.readGuest(address, width: width), bits: width.rawValue * 8) & 0xffff_ffff
                )
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadStoreRegisterOffset(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let opcode = (instruction >> 22) & 0x3
        let rm = Int((instruction >> 16) & 0x1f)
        let option = UInt8((instruction >> 13) & 0x7)
        let shift = ((instruction >> 12) & 0x1) == 1 ? size : 0
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let width = loadStoreWidth(size: size)

        guard option == 0x2 || option == 0x3 || option == 0x6 || option == 0x7 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let offset = extendedRegisterValue(readRegister(vm, rm), option: option) << UInt64(shift)
        let address = baseRegister(vm, rn) &+ offset

        do {
            switch opcode {
            case 0:
                try vm.writeGuest(address, width: width, value: readRegister(vm, rt) & maskForBits(width.rawValue * 8))
            case 1:
                writeRegister(vm, rt, try vm.readGuest(address, width: width))
            case 2 where size == 3:
                break
            case 2:
                guard size <= 2 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                let bits = width.rawValue * 8
                writeRegister(vm, rt, signExtendLoaded(try vm.readGuest(address, width: width), bits: bits))
            case 3:
                guard size <= 1 else {
                    throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
                }
                let bits = width.rawValue * 8
                writeRegister(vm, rt, signExtendLoaded(try vm.readGuest(address, width: width), bits: bits) & 0xffff_ffff)
            default:
                throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadStoreExclusive(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let rs = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let width = loadStoreWidth(size: size)
        let address = baseRegister(vm, rn)

        guard !isLoad || rs == 31 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            if isLoad {
                let physicalAddress = try vm.translateAddress(address, access: .dataRead)
                writeRegister(vm, rt, try vm.readPhysical(physicalAddress, width: width))
                vm.cpu.exclusiveReservationAddress = physicalAddress
                vm.cpu.exclusiveReservationSize = width.rawValue
            } else {
                let physicalAddress = try vm.translateAddress(address, access: .dataWrite)
                let reservationMatches = vm.cpu.exclusiveReservationAddress == physicalAddress &&
                    vm.cpu.exclusiveReservationSize == width.rawValue

                if reservationMatches {
                    try vm.writePhysical(
                        physicalAddress,
                        width: width,
                        value: readRegister(vm, rt) & maskForBits(width.rawValue * 8)
                    )
                }
                writeRegister(vm, rs, reservationMatches ? 0 : 1)
                vm.clearExclusiveReservation()
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadStoreExclusivePair(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let rs = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let address = baseRegister(vm, rn)

        guard size >= 2 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }
        guard !isLoad || rs == 31 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        let width: MMIOWidth = size == 2 ? .word : .doubleword
        let stride = UInt64(width.rawValue)
        let reservationSize = width.rawValue * 2

        do {
            if isLoad {
                let firstPhysicalAddress = try vm.translateAddress(address, access: .dataRead)
                let secondPhysicalAddress = try vm.translateAddress(address &+ stride, access: .dataRead)
                writeRegister(vm, rt, try vm.readPhysical(firstPhysicalAddress, width: width))
                writeRegister(vm, rt2, try vm.readPhysical(secondPhysicalAddress, width: width))
                vm.cpu.exclusiveReservationAddress = firstPhysicalAddress
                vm.cpu.exclusiveReservationSize = reservationSize
            } else {
                let firstPhysicalAddress = try vm.translateAddress(address, access: .dataWrite)
                let secondPhysicalAddress = try vm.translateAddress(address &+ stride, access: .dataWrite)
                let reservationMatches = vm.cpu.exclusiveReservationAddress == firstPhysicalAddress &&
                    vm.cpu.exclusiveReservationSize == reservationSize

                if reservationMatches {
                    let mask = maskForBits(width.rawValue * 8)
                    try vm.writePhysical(firstPhysicalAddress, width: width, value: readRegister(vm, rt) & mask)
                    try vm.writePhysical(secondPhysicalAddress, width: width, value: readRegister(vm, rt2) & mask)
                }
                writeRegister(vm, rs, reservationMatches ? 0 : 1)
                vm.clearExclusiveReservation()
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadAcquireStoreRelease(_ vm: VirtualMachine, instruction: UInt32) throws {
        let pc = vm.cpu.pc
        let size = Int((instruction >> 30) & 0x3)
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let rs = Int((instruction >> 16) & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt = Int(instruction & 0x1f)
        let width = loadStoreWidth(size: size)
        let address = baseRegister(vm, rn)

        guard rs == 31 else {
            throw VMError.unsupportedInstruction(instruction: instruction, pc: pc)
        }

        do {
            if isLoad {
                writeRegister(vm, rt, try vm.readGuest(address, width: width))
            } else {
                try vm.writeGuest(address, width: width, value: readRegister(vm, rt) & maskForBits(width.rawValue * 8))
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStorePair64(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * 8
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)

        do {
            try vm.writeGuest(address, width: .doubleword, value: readRegister(vm, rt))
            try vm.writeGuest(address + 8, width: .doubleword, value: readRegister(vm, rt2))
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStorePair32(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * 4
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)

        do {
            try vm.writeGuest(address, width: .word, value: readRegister(vm, rt) & 0xffff_ffff)
            try vm.writeGuest(address + 4, width: .word, value: readRegister(vm, rt2) & 0xffff_ffff)
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadPair64(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * 8
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)

        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .doubleword))
            writeRegister(vm, rt2, try vm.readGuest(address + 8, width: .doubleword))
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadPair32(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * 4
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)

        do {
            writeRegister(vm, rt, try vm.readGuest(address, width: .word))
            writeRegister(vm, rt2, try vm.readGuest(address + 4, width: .word))
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadPairSignedWord(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * 4
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)

        do {
            writeRegister(vm, rt, signExtendLoaded(try vm.readGuest(address, width: .word), bits: 32))
            writeRegister(vm, rt2, signExtendLoaded(try vm.readGuest(address + 4, width: .word), bits: 32))
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeStorePairSIMD(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode,
        registerBytes: Int64
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * registerBytes
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)
        let first = vm.cpu.v[rt]
        let second = vm.cpu.v[rt2]
        let stride = UInt64(registerBytes)
        let scalarWidth: MMIOWidth = registerBytes == 4 ? .word : .doubleword

        do {
            try vm.writeGuest(address, width: scalarWidth, value: first.low)
            if registerBytes == 16 {
                try vm.writeGuest(address + 8, width: .doubleword, value: first.high)
            }
            try vm.writeGuest(address + stride, width: scalarWidth, value: second.low)
            if registerBytes == 16 {
                try vm.writeGuest(address + stride + 8, width: .doubleword, value: second.high)
            }
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func executeLoadPairSIMD(
        _ vm: VirtualMachine,
        instruction: UInt32,
        addressingMode: PairAddressingMode,
        registerBytes: Int64
    ) throws {
        let pc = vm.cpu.pc
        let rt = Int(instruction & 0x1f)
        let rn = Int((instruction >> 5) & 0x1f)
        let rt2 = Int((instruction >> 10) & 0x1f)
        let offset = signExtend((instruction >> 15) & 0x7f, bits: 7) * registerBytes
        let base = baseRegister(vm, rn)
        let address = pairAddress(base: base, offset: offset, addressingMode: addressingMode)
        let writeback = pairWriteback(base: base, address: address, offset: offset, addressingMode: addressingMode)
        let stride = UInt64(registerBytes)
        let scalarWidth: MMIOWidth = registerBytes == 4 ? .word : .doubleword

        do {
            vm.cpu.v[rt] = ARM64VectorRegister(
                low: try vm.readGuest(address, width: scalarWidth),
                high: registerBytes == 16 ? try vm.readGuest(address + 8, width: .doubleword) : 0
            )
            vm.cpu.v[rt2] = ARM64VectorRegister(
                low: try vm.readGuest(address + stride, width: scalarWidth),
                high: registerBytes == 16 ? try vm.readGuest(address + stride + 8, width: .doubleword) : 0
            )
            if let writeback {
                writeBaseRegister(vm, rn, writeback)
            }
            vm.cpu.pc = pc + 4
        } catch let fault as ARM64TranslationFault {
            routeTranslationFault(vm, fault: fault, returnAddress: pc)
        }
    }

    private func pairAddress(base: UInt64, offset: Int64, addressingMode: PairAddressingMode) -> UInt64 {
        switch addressingMode {
        case .postIndex:
            return base
        case .signedOffset, .preIndex:
            return addSignedOffset(base, offset)
        }
    }

    private func pairWriteback(
        base: UInt64,
        address: UInt64,
        offset: Int64,
        addressingMode: PairAddressingMode
    ) -> UInt64? {
        switch addressingMode {
        case .postIndex:
            return addSignedOffset(base, offset)
        case .preIndex:
            return address
        case .signedOffset:
            return nil
        }
    }

    private func executeBranch(_ vm: VirtualMachine, instruction: UInt32, link: Bool) {
        let pc = vm.cpu.pc
        let imm26 = instruction & 0x03ff_ffff
        let offset = signExtend(imm26, bits: 26) << 2
        if link {
            vm.cpu.x[30] = pc + 4
        }
        let nextPC = Int64(bitPattern: pc) &+ offset
        vm.cpu.pc = UInt64(bitPattern: nextPC)
    }

    private func readRegister(_ vm: VirtualMachine, _ index: Int) -> UInt64 {
        index == 31 ? 0 : vm.cpu.x[index]
    }

    private func writeRegister(_ vm: VirtualMachine, _ index: Int, _ value: UInt64) {
        if index != 31 {
            vm.cpu.x[index] = value
        }
    }

    private func writeBaseRegister(_ vm: VirtualMachine, _ index: Int, _ value: UInt64) {
        if index == 31 {
            vm.cpu.sp = value
        } else {
            vm.cpu.x[index] = value
        }
    }

    private func baseRegister(_ vm: VirtualMachine, _ index: Int) -> UInt64 {
        index == 31 ? vm.cpu.sp : vm.cpu.x[index]
    }

    private func loadStoreWidth(size: Int) -> MMIOWidth {
        switch size {
        case 0:
            return .byte
        case 1:
            return .halfword
        case 2:
            return .word
        default:
            return .doubleword
        }
    }

    private func addSignedOffset(_ base: UInt64, _ offset: Int64) -> UInt64 {
        UInt64(bitPattern: Int64(bitPattern: base) &+ offset)
    }

    private func extendedRegisterValue(_ value: UInt64, option: UInt8) -> UInt64 {
        switch option {
        case 0:
            return value & 0xff
        case 1:
            return value & 0xffff
        case 2:
            return value & 0xffff_ffff
        case 3:
            return value
        case 4:
            return UInt64(bitPattern: signExtend(UInt32(value & 0xff), bits: 8))
        case 5:
            return UInt64(bitPattern: signExtend(UInt32(value & 0xffff), bits: 16))
        case 6:
            return UInt64(bitPattern: signExtend(UInt32(value & 0xffff_ffff), bits: 32))
        default:
            return value
        }
    }

    private func reverseBits(_ value: UInt64, bits: Int) -> UInt64 {
        var result: UInt64 = 0
        for bit in 0..<bits {
            if ((value >> UInt64(bit)) & 0x1) == 1 {
                result |= UInt64(1) << UInt64(bits - 1 - bit)
            }
        }
        return result & maskForBits(bits)
    }

    private func reverseBytes(_ value: UInt64, groupBytes: Int, bits: Int) -> UInt64 {
        let byteCount = bits / 8
        var result: UInt64 = 0

        for byteIndex in 0..<byteCount {
            let groupStart = (byteIndex / groupBytes) * groupBytes
            let offsetInGroup = byteIndex - groupStart
            let reversedIndex = groupStart + groupBytes - 1 - offsetInGroup
            let byte = (value >> UInt64(byteIndex * 8)) & 0xff
            result |= byte << UInt64(reversedIndex * 8)
        }

        return result & maskForBits(bits)
    }

    private func countLeadingZeros(_ value: UInt64, bits: Int) -> Int {
        let value = maskedOperand(value, bits: bits)
        if bits == 32 {
            return UInt32(value).leadingZeroBitCount
        }
        return value.leadingZeroBitCount
    }

    private func countLeadingSignBits(_ value: UInt64, bits: Int) -> Int {
        let sign = (value >> UInt64(bits - 1)) & 0x1
        var count = 0
        guard bits > 1 else {
            return 0
        }

        for bit in stride(from: bits - 2, through: 0, by: -1) {
            if ((value >> UInt64(bit)) & 0x1) == sign {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    private func conditionHolds(_ condition: UInt8, pstate: UInt64) -> Bool {
        let n = (pstate & 0x8000_0000) != 0
        let z = (pstate & 0x4000_0000) != 0
        let c = (pstate & 0x2000_0000) != 0
        let v = (pstate & 0x1000_0000) != 0
        let baseCondition = condition >> 1
        let baseResult: Bool

        switch baseCondition {
        case 0:
            baseResult = z
        case 1:
            baseResult = c
        case 2:
            baseResult = n
        case 3:
            baseResult = v
        case 4:
            baseResult = c && !z
        case 5:
            baseResult = n == v
        case 6:
            baseResult = !z && n == v
        default:
            return true
        }

        if (condition & 0x1) == 1 && condition != 0xf {
            return !baseResult
        }
        return baseResult
    }

    private func addNZCV(lhs: UInt64, rhs: UInt64, bits: Int) -> UInt64 {
        let mask = maskForBits(bits)
        let result = (lhs &+ rhs) & mask
        let signBit = UInt64(1) << UInt64(bits - 1)
        let negative = (result & signBit) != 0
        let zero = result == 0
        let carry = bits == 64 ? lhs > UInt64.max &- rhs : lhs + rhs > mask
        let overflow = (~(lhs ^ rhs) & (lhs ^ result) & signBit) != 0

        return nzcv(negative: negative, zero: zero, carry: carry, overflow: overflow)
    }

    private func subtractNZCV(lhs: UInt64, rhs: UInt64, bits: Int) -> UInt64 {
        let mask = maskForBits(bits)
        let result = (lhs &- rhs) & mask
        let signBit = UInt64(1) << UInt64(bits - 1)
        let negative = (result & signBit) != 0
        let zero = result == 0
        let carry = lhs >= rhs
        let overflow = ((lhs ^ rhs) & (lhs ^ result) & signBit) != 0

        return nzcv(negative: negative, zero: zero, carry: carry, overflow: overflow)
    }

    private func addWithCarryNZCV(lhs: UInt64, rhs: UInt64, carryIn: Bool, bits: Int) -> (UInt64, UInt64) {
        let mask = maskForBits(bits)
        let carryValue: UInt64 = carryIn ? 1 : 0
        let lhs = lhs & mask
        let rhs = rhs & mask
        let sum = (lhs &+ rhs &+ carryValue) & mask
        let carry: Bool

        if bits == 64 {
            let (partial, overflow1) = lhs.addingReportingOverflow(rhs)
            let (_, overflow2) = partial.addingReportingOverflow(carryValue)
            carry = overflow1 || overflow2
        } else {
            carry = lhs + rhs + carryValue > mask
        }

        let signBit = UInt64(1) << UInt64(bits - 1)
        let negative = (sum & signBit) != 0
        let zero = sum == 0
        let overflow = (~(lhs ^ rhs) & (lhs ^ sum) & signBit) != 0

        return (sum, nzcv(negative: negative, zero: zero, carry: carry, overflow: overflow))
    }

    private func fpCompareNZCV<T: BinaryFloatingPoint>(_ lhs: T, _ rhs: T) -> UInt64 {
        if lhs.isNaN || rhs.isNaN {
            return nzcv(negative: false, zero: false, carry: true, overflow: true)
        }
        if lhs == rhs {
            return nzcv(negative: false, zero: true, carry: true, overflow: false)
        }
        if lhs < rhs {
            return nzcv(negative: true, zero: false, carry: false, overflow: false)
        }
        return nzcv(negative: false, zero: false, carry: true, overflow: false)
    }

    private func signedIntegerBitsFromFP(_ value: Double, bits: Int) -> UInt64 {
        guard value.isFinite else {
            if value.isNaN {
                return 0
            }
            if bits == 32 {
                return value.sign == .minus ? UInt64(UInt32(bitPattern: Int32.min)) : UInt64(UInt32(bitPattern: Int32.max))
            }
            return value.sign == .minus ? signedIntegerBitPattern(Int64.min, bits: bits) : signedIntegerBitPattern(Int64.max, bits: bits)
        }

        if bits == 32 {
            if value >= Double(Int32.max) {
                return UInt64(UInt32(bitPattern: Int32.max))
            }
            if value <= Double(Int32.min) {
                return UInt64(UInt32(bitPattern: Int32.min))
            }
            return UInt64(UInt32(bitPattern: Int32(value.rounded(.towardZero))))
        }

        if value >= Double(Int64.max) {
            return UInt64(bitPattern: Int64.max)
        }
        if value <= Double(Int64.min) {
            return UInt64(bitPattern: Int64.min)
        }
        return UInt64(bitPattern: Int64(value.rounded(.towardZero)))
    }

    private func roundedFPToInteger(_ value: Double, instruction: UInt32) -> Double {
        let rule: FloatingPointRoundingRule
        switch instruction & 0x7f3f_fc00 {
        case 0x1e20_0000, 0x1e21_0000:
            rule = .toNearestOrEven
        case 0x1e28_0000, 0x1e29_0000:
            rule = .up
        case 0x1e30_0000, 0x1e31_0000:
            rule = .down
        case 0x1e24_0000, 0x1e25_0000:
            rule = .toNearestOrAwayFromZero
        default:
            rule = .towardZero
        }
        return value.rounded(rule)
    }

    private func unsignedIntegerBitsFromFP(_ value: Double, bits: Int) -> UInt64 {
        guard value.isFinite else {
            if value.isNaN || value.sign == .minus {
                return 0
            }
            return bits == 32 ? UInt64(UInt32.max) : UInt64.max
        }

        if value <= 0 {
            return 0
        }

        if bits == 32 {
            if value >= Double(UInt32.max) {
                return UInt64(UInt32.max)
            }
            return UInt64(value.rounded(.towardZero))
        }

        if value >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(value.rounded(.towardZero))
    }

    private func signedIntegerBitPattern(_ value: Int64, bits: Int) -> UInt64 {
        bits == 32 ? UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: value))) : UInt64(bitPattern: value)
    }

    private func nzcv(negative: Bool, zero: Bool, carry: Bool, overflow: Bool) -> UInt64 {
        (negative ? 0x8000_0000 : 0) |
            (zero ? 0x4000_0000 : 0) |
            (carry ? 0x2000_0000 : 0) |
            (overflow ? 0x1000_0000 : 0)
    }

    private func maskedOperand(_ value: UInt64, bits: Int) -> UInt64 {
        value & maskForBits(bits)
    }

    private func maskForBits(_ bits: Int) -> UInt64 {
        bits == 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1
    }

    private func duplicateSIMDElement(
        _ element: UInt64,
        elementBits: Int,
        writesFullVector: Bool
    ) -> ARM64VectorRegister {
        var low: UInt64 = 0
        let laneCount = 64 / elementBits

        for lane in 0..<laneCount {
            low |= element << UInt64(lane * elementBits)
        }

        return ARM64VectorRegister(low: low, high: writesFullVector ? low : 0)
    }

    private func writeVectorElement(
        _ vm: VirtualMachine,
        vector index: Int,
        lane: Int,
        elementBits: Int,
        value: UInt64
    ) {
        let bitOffset = lane * elementBits
        let laneMask = maskForBits(elementBits)
        let maskedValue = value & laneMask
        var vector = vm.cpu.v[index]

        if bitOffset < 64 {
            let shiftedMask = laneMask << UInt64(bitOffset)
            vector.low = (vector.low & ~shiftedMask) | (maskedValue << UInt64(bitOffset))
        } else {
            let highOffset = bitOffset - 64
            let shiftedMask = laneMask << UInt64(highOffset)
            vector.high = (vector.high & ~shiftedMask) | (maskedValue << UInt64(highOffset))
        }

        vm.cpu.v[index] = vector
    }

    private func writeVectorElement(
        _ vector: inout ARM64VectorRegister,
        lane: Int,
        elementBits: Int,
        value: UInt64
    ) {
        let bitOffset = lane * elementBits
        let laneMask = maskForBits(elementBits)
        let maskedValue = value & laneMask

        if bitOffset < 64 {
            let shiftedMask = laneMask << UInt64(bitOffset)
            vector.low = (vector.low & ~shiftedMask) | (maskedValue << UInt64(bitOffset))
        } else {
            let highOffset = bitOffset - 64
            let shiftedMask = laneMask << UInt64(highOffset)
            vector.high = (vector.high & ~shiftedMask) | (maskedValue << UInt64(highOffset))
        }
    }

    private func readVectorElement(_ vector: ARM64VectorRegister, lane: Int, elementBits: Int) -> UInt64 {
        let bitOffset = lane * elementBits
        let laneMask = maskForBits(elementBits)
        if bitOffset < 64 {
            return (vector.low >> UInt64(bitOffset)) & laneMask
        }
        return (vector.high >> UInt64(bitOffset - 64)) & laneMask
    }

    private func signExtendVectorElement(_ vector: ARM64VectorRegister, lane: Int, elementBits: Int) -> UInt64 {
        UInt64(bitPattern: signExtend(UInt32(readVectorElement(vector, lane: lane, elementBits: elementBits)), bits: elementBits))
    }

    private func isSIMDAddVector(_ instruction: UInt32) -> Bool {
        (instruction & 0xbf20_fc00) == 0x0e20_8400
    }

    private func isSIMDIntegerNegate(_ instruction: UInt32) -> Bool {
        guard (instruction & 0xbf3f_fc00) == 0x2e20_b800 else {
            return false
        }
        return ((instruction >> 22) & 0x3) != 3 || ((instruction >> 30) & 0x1) == 1
    }

    private func isSIMDShiftLeftImmediate(_ instruction: UInt32) -> Bool {
        guard (instruction & 0xbf80_fc00) == 0x0f00_5400 else {
            return false
        }
        let encodedShift = (instruction >> 16) & 0x7f
        return encodedShift >= 8 && (encodedShift < 64 || ((instruction >> 30) & 0x1) == 1)
    }

    private func isSIMDMultiplyLong(_ instruction: UInt32) -> Bool {
        (instruction & 0x9f20_fc00) == 0x0e20_c000 && ((instruction >> 22) & 0x3) <= 2
    }

    private func isSIMDNarrowHigh(_ instruction: UInt32) -> Bool {
        (instruction & 0x9f20_dc00) == 0x0e20_4000 && ((instruction >> 22) & 0x3) <= 2
    }

    private func isSIMDBitwiseNot(_ instruction: UInt32) -> Bool {
        (instruction & 0xbfff_fc00) == 0x2e20_5800
    }

    private func isSIMDSaturatingAddSubtract(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x9f20_dc00) == 0x0e20_0c00 else {
            return false
        }
        let elementBits = 8 << Int((instruction >> 22) & 0x3)
        return elementBits < 64 || ((instruction >> 30) & 0x1) == 1
    }

    private func isSIMDInsertVectorElement(_ instruction: UInt32) -> Bool {
        guard (instruction & 0xff20_8400) == 0x6e00_0400 else {
            return false
        }
        let imm5 = (instruction >> 16) & 0x1f
        guard imm5 != 0 else {
            return false
        }
        let trailing = imm5.trailingZeroBitCount
        let elementBits = 8 << trailing
        let imm4 = (instruction >> 11) & 0x0f
        let alignmentMask = (UInt32(1) << UInt32(trailing)) - 1
        return elementBits <= 64 && (imm4 & alignmentMask) == 0
    }

    private func isSIMDShiftRightImmediate(_ instruction: UInt32) -> Bool {
        let isScalar = (instruction & 0xdf80_fc00) == 0x5f00_0400
        let isVector = (instruction & 0x9f80_fc00) == 0x0f00_0400
        guard isScalar || isVector else {
            return false
        }
        let encodedShift = Int((instruction >> 16) & 0x7f)
        guard encodedShift >= 8 else {
            return false
        }
        let elementBits: Int
        switch encodedShift {
        case 8..<16: elementBits = 8
        case 16..<32: elementBits = 16
        case 32..<64: elementBits = 32
        default: elementBits = 64
        }
        return isScalar
            ? elementBits == 64
            : elementBits != 64 || ((instruction >> 30) & 0x1) == 1
    }

    private func isSIMDPairwiseAddLong(_ instruction: UInt32) -> Bool {
        (instruction & 0x9f3f_fc00) == 0x0e20_2800 && ((instruction >> 22) & 0x3) <= 2
    }

    private func isSIMDUnsignedMaxPairwise(_ instruction: UInt32) -> Bool {
        (instruction & 0xbf20_fc00) == 0x2e20_a400 && ((instruction >> 22) & 3) != 3
    }

    private func isSIMDTableLookup(_ instruction: UInt32) -> Bool {
        (instruction & 0xbfe0_8c00) == 0x0e00_0000
    }

    private func isSIMDPermuteTwoVector(_ instruction: UInt32) -> Bool {
        guard (instruction & 0xbf20_0c00) == 0x0e00_0800 else {
            return false
        }

        let q = ((instruction >> 30) & 0x1) == 1
        let size = Int((instruction >> 22) & 0x3)
        let op = Int((instruction >> 12) & 0x7)
        let elementBits = 8 << size
        let vectorBits = q ? 128 : 64

        return op != 0 && op != 4 && elementBits <= vectorBits / 2
    }

    private func isSIMDMoveImmediateZero(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        let imm8 = (((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f)

        guard o2 == 0, imm8 == 0 else {
            return false
        }
        if op == 0 {
            return cmode <= 0xb || cmode == 0xe
        }
        return cmode == 0xe
    }

    private func isSIMDFPImmediateMove(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }
        let q = (instruction >> 30) & 0x1
        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        return cmode == 0xf && o2 == 0 && (op == 0 || q == 1)
    }

    private func isSIMDMoveImmediateByte(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1

        return op == 0 && cmode == 0xe && o2 == 0
    }

    private func isSIMDMoveImmediateWord(_ instruction: UInt32) -> Bool {
        simdMoveImmediateWordValue(instruction) != nil
    }

    private func simdMoveImmediateWordValue(_ instruction: UInt32) -> UInt64? {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return nil
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        guard op == 0, o2 == 0, cmode <= 6, cmode & 1 == 0 else {
            return nil
        }

        let imm8 = UInt64((((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f))
        return imm8 << UInt64((cmode >> 1) * 8)
    }

    private func isFPScalarGeneralMove(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x1e27_0000, 0x1e26_0000, 0x9e67_0000, 0x9e66_0000, 0x9eaf_0000, 0x9eae_0000:
            return true
        default:
            return false
        }
    }

    private func isFPScalarRegisterMove(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x1e20_4000, 0x1e60_4000:
            return true
        default:
            return false
        }
    }

    private func isFPScalarImmediateMove(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_1fe0 {
        case 0x1e20_1000, 0x1e60_1000:
            return true
        default:
            return false
        }
    }

    private func isFPIntegerToScalarFP(_ instruction: UInt32) -> Bool {
        switch instruction & 0x7f3f_0000 {
        case 0x1e02_0000, 0x1e03_0000:
            let sourceBits = ((instruction >> 31) & 1) == 1 ? 64 : 32
            let fractionalBits = 64 - Int((instruction >> 10) & 0x3f)
            return fractionalBits > 0 && fractionalBits <= sourceBits
        default:
            break
        }
        switch instruction & 0x7fbf_fc00 {
        case 0x1e22_0000, 0x1e23_0000:
            return true
        default:
            return false
        }
    }

    private func isFPScalarAdd(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_2800, 0x1e60_2800:
            return true
        default:
            return false
        }
    }

    private func isFPScalarSubtract(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_3800, 0x1e60_3800:
            return true
        default:
            return false
        }
    }

    private func isFPScalarMultiply(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_0800, 0x1e60_0800:
            return true
        default:
            return false
        }
    }

    private func isFPScalarDivide(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_1800, 0x1e60_1800:
            return true
        default:
            return false
        }
    }

    private func isFPScalarNegatedMultiply(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_8800, 0x1e60_8800:
            return true
        default:
            return false
        }
    }

    private func isFPScalarFusedMultiplyAdd(_ instruction: UInt32) -> Bool {
        (instruction & 0xff80_0000) == 0x1f00_0000
    }

    private func isFPScalarUnary(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x1e20_c000, 0x1e60_c000,
             0x1e21_4000, 0x1e61_4000,
             0x1e21_c000, 0x1e61_c000:
            return true
        default:
            return false
        }
    }

    private func isFPScalarRoundIntegral(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x1e24_4000, 0x1e64_4000,
             0x1e24_c000, 0x1e64_c000,
             0x1e25_4000, 0x1e65_4000,
             0x1e25_c000, 0x1e65_c000,
             0x1e26_4000, 0x1e66_4000,
             0x1e27_4000, 0x1e67_4000,
             0x1e27_c000, 0x1e67_c000:
            return true
        default:
            return false
        }
    }

    private func isSIMDScalarFPAbsoluteDifference(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc00 {
        case 0x7ea0_d400, 0x7ee0_d400:
            return true
        default:
            return false
        }
    }

    private func isFPScalarConditionalSelect(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_0c00 {
        case 0x1e20_0c00, 0x1e60_0c00:
            return true
        default:
            return false
        }
    }

    private func isFPScalarConditionalCompare(_ instruction: UInt32) -> Bool {
        (instruction & 0xff20_0c00) == 0x1e20_0400
    }

    private func isFPScalarCompareZero(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_ffff {
        case 0x1e20_2018, 0x1e60_2018:
            return true
        default:
            return false
        }
    }

    private func isFPScalarCompareRegister(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffe0_fc1f {
        case 0x1e20_2000, 0x1e20_2010,
             0x1e60_2000, 0x1e60_2010:
            return true
        default:
            return false
        }
    }

    private func isFPScalarConvertToSignedInteger(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x5ea1_b800, 0x5ee1_b800:
            return true
        default:
            break
        }
        switch instruction & 0x7f3f_fc00 {
        case 0x1e20_0000, 0x1e28_0000, 0x1e30_0000, 0x1e24_0000, 0x1e38_0000:
            return true
        default:
            return false
        }
    }

    private func isFPScalarConvertToUnsignedIntegerRegister(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x7ea1_b800, 0x7ee1_b800:
            return true
        default:
            break
        }
        switch instruction & 0x7f3f_fc00 {
        case 0x1e21_0000, 0x1e29_0000, 0x1e31_0000, 0x1e25_0000, 0x1e39_0000:
            return true
        default:
            return false
        }
    }

    private func isSIMDScalarSignedIntegerToFP(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_fc00 {
        case 0x5e21_d800, 0x5e61_d800,
             0x7e21_d800, 0x7e61_d800:
            return true
        default:
            return false
        }
    }

    private func isSIMDMoveInvertedImmediate(_ instruction: UInt32) -> Bool {
        simdMoveInvertedImmediateElement(instruction) != nil
    }

    private func isSIMDMoveDImmediate(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        let imm8 = (((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f)

        return op == 1 && cmode == 0xe && o2 == 0 && imm8 != 0
    }

    private func expandSIMDMoveDImmediate(_ imm8: UInt64) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 where ((imm8 >> UInt64(byte)) & 1) != 0 {
            value |= 0xff << UInt64(byte * 8)
        }
        return value
    }

    private func expandFPImmediate(_ imm8: UInt64, elementBits: Int) -> UInt64 {
        let immediate = imm8 & 0xff
        let sign = immediate >> 7
        let repeated = (immediate >> 6) & 1
        let exponentLow = (immediate >> 4) & 3
        let fraction = immediate & 0xf
        if elementBits == 64 {
            let exponent = ((repeated ^ 1) << 10) | (repeated == 1 ? 0x3fc : 0) | exponentLow
            return (sign << 63) | (exponent << 52) | (fraction << 48)
        }
        let exponent = ((repeated ^ 1) << 7) | (repeated == 1 ? 0x7c : 0) | exponentLow
        return (sign << 31) | (exponent << 23) | (fraction << 19)
    }

    private func simdMoveInvertedImmediateElement(_ instruction: UInt32) -> (value: UInt64, elementBits: Int)? {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return nil
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        let imm8 = UInt64((((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f))

        guard op == 1, o2 == 0 else {
            return nil
        }

        switch cmode {
        case 0x0, 0x2, 0x4, 0x6:
            let shift = Int(cmode / 2) * 8
            let lane = UInt64(UInt32.max ^ UInt32(imm8 << UInt64(shift)))
            return (lane, 32)
        case 0x8, 0xa:
            let shift = cmode == 0x8 ? 0 : 8
            let lane = UInt64(UInt16.max ^ UInt16(imm8 << UInt64(shift)))
            return (lane, 16)
        default:
            return nil
        }
    }

    private func isSIMDFPQSignedImmediateLoadStore(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x3b00_0000) == 0x3800_0000 else {
            return false
        }

        let vector = ((instruction >> 26) & 0x1) == 1
        let size = (instruction >> 30) & 0x3
        let opcode = (instruction >> 22) & 0x3
        let mode = (instruction >> 10) & 0x3

        return vector && size == 0 && (opcode == 2 || opcode == 3) && mode != 2
    }

    private func decodeLogicalImmediate(n: UInt8, immr: UInt8, imms: UInt8, bits: Int) -> UInt64? {
        if bits == 32 && n != 0 {
            return nil
        }

        let encodedLength = (Int(n) << 6) | Int((~imms) & 0x3f)
        guard let length = highestSetBit(encodedLength), length >= 1 else {
            return nil
        }

        let levels = (1 << length) - 1
        guard (Int(imms) & levels) != levels else {
            return nil
        }

        let size = 1 << length
        guard size <= bits else {
            return nil
        }

        let setBits = (Int(imms) & levels) + 1
        let rotate = Int(immr) & levels
        let element = rotateRight(ones(setBits), by: rotate, width: size)

        var result: UInt64 = 0
        var shift = 0
        while shift < bits {
            result |= element << UInt64(shift)
            shift += size
        }
        return result & maskForBits(bits)
    }

    private func decodeBitfieldMasks(n: UInt8, immr: UInt8, imms: UInt8, bits: Int) -> (writeMask: UInt64, topMask: UInt64)? {
        if bits == 32 && n != 0 {
            return nil
        }
        if bits == 64 && n != 1 {
            return nil
        }

        let encodedLength = (Int(n) << 6) | Int((~imms) & 0x3f)
        guard let length = highestSetBit(encodedLength), length >= 1 else {
            return nil
        }

        let levels = (1 << length) - 1
        let size = 1 << length
        guard size <= bits else {
            return nil
        }

        let setBits = Int(imms) & levels
        let rotate = Int(immr) & levels
        let diff = (setBits &- rotate) & levels
        let writeElement = rotateRight(ones(setBits + 1), by: rotate, width: size)
        let topElement = ones(diff + 1)

        var writeMask: UInt64 = 0
        var topMask: UInt64 = 0
        var shift = 0
        while shift < bits {
            writeMask |= writeElement << UInt64(shift)
            topMask |= topElement << UInt64(shift)
            shift += size
        }

        let registerMask = maskForBits(bits)
        return (writeMask & registerMask, topMask & registerMask)
    }

    private func bitfieldInsert(source: UInt64, immr: UInt8, imms: UInt8, bits: Int) -> (value: UInt64, mask: UInt64) {
        let rotate = Int(immr)
        let setBits = Int(imms)
        let registerMask = maskForBits(bits)

        if setBits >= rotate {
            let width = setBits - rotate + 1
            let fieldMask = ones(width)
            return ((source >> UInt64(rotate)) & fieldMask, fieldMask)
        }

        let width = setBits + 1
        let lsb = bits - rotate
        let fieldMask = (ones(width) << UInt64(lsb)) & registerMask
        return (((source & ones(width)) << UInt64(lsb)) & registerMask, fieldMask)
    }

    private func highestSetBit(_ value: Int) -> Int? {
        var bit = 6
        while bit >= 0 {
            if (value & (1 << bit)) != 0 {
                return bit
            }
            bit -= 1
        }
        return nil
    }

    private func ones(_ count: Int) -> UInt64 {
        count >= 64 ? UInt64.max : (UInt64(1) << UInt64(count)) - 1
    }

    private func rotateRight(_ value: UInt64, by amount: Int, width: Int) -> UInt64 {
        let mask = maskForBits(width)
        let rotation = amount % width
        let maskedValue = value & mask
        guard rotation != 0 else {
            return maskedValue
        }
        return ((maskedValue >> UInt64(rotation)) | (maskedValue << UInt64(width - rotation))) & mask
    }

    private func shiftedRegisterValue(_ value: UInt64, shiftType: UInt8, amount: Int, bits: Int) -> UInt64 {
        let mask = maskForBits(bits)
        let maskedValue = value & mask
        switch shiftType {
        case 0:
            return (maskedValue << UInt64(amount)) & mask
        case 1:
            return maskedValue >> UInt64(amount)
        case 2:
            guard amount > 0 else {
                return maskedValue
            }
            let signBit = UInt64(1) << UInt64(bits - 1)
            let shifted = maskedValue >> UInt64(amount)
            if (maskedValue & signBit) == 0 {
                return shifted
            }
            return (shifted | (mask << UInt64(bits - amount))) & mask
        default:
            return rotateRight(maskedValue, by: amount, width: bits)
        }
    }

    private func setNZCV(_ flags: UInt64, in vm: VirtualMachine) {
        vm.cpu.pstate = (vm.cpu.pstate & ~UInt64(0xf000_0000)) | (flags & 0xf000_0000)
    }

    private func isBarrier(_ instruction: UInt32) -> Bool {
        switch instruction & 0xffff_f0ff {
        case 0xd503_309f, 0xd503_30bf, 0xd503_30df:
            return true
        default:
            return false
        }
    }

    private func isSystemInstruction(_ instruction: UInt32) -> Bool {
        (instruction & 0xfff8_0000) == 0xd508_0000
    }

    private func signExtend(_ value: UInt32, bits: Int) -> Int64 {
        let shift = 64 - bits
        let shifted = Int64(bitPattern: UInt64(value) << UInt64(shift))
        return shifted >> shift
    }

    private func signExtendLoaded(_ value: UInt64, bits: Int) -> UInt64 {
        let shift = 64 - bits
        return UInt64(bitPattern: Int64(bitPattern: value << UInt64(shift)) >> UInt64(shift))
    }
}
