public typealias GuestAddress = UInt64

public struct AddressRange: Equatable {
    public let start: GuestAddress
    public let length: UInt64

    public init(start: GuestAddress, length: UInt64) {
        precondition(length > 0, "Address ranges must not be empty")
        precondition(start <= UInt64.max - length, "Address range overflows UInt64")
        self.start = start
        self.length = length
    }

    public var endExclusive: GuestAddress {
        start + length
    }

    public func contains(_ address: GuestAddress, width: UInt64 = 1) -> Bool {
        guard width > 0 else { return false }
        guard address >= start else { return false }
        guard address <= UInt64.max - width else { return false }
        return address + width <= endExclusive
    }

    public func offset(of address: GuestAddress) -> UInt64? {
        contains(address) ? address - start : nil
    }

    public func overlaps(_ other: AddressRange) -> Bool {
        start < other.endExclusive && other.start < endExclusive
    }
}

public enum MMIOWidth: Int, Hashable {
    case byte = 1
    case halfword = 2
    case word = 4
    case doubleword = 8
}

public struct ARM64BackendInstructionCount: Codable, Equatable {
    public let instruction: UInt32
    public let count: Int

    public init(instruction: UInt32, count: Int) {
        self.instruction = instruction
        self.count = count
    }
}

public struct ARM64BackendNamedCount: Codable, Equatable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct ARM64BackendExecutionTotals: Codable, Equatable, Sendable {
    public let nativeSteps: Int
    public let fallbackSteps: Int

    public init(nativeSteps: Int, fallbackSteps: Int) {
        self.nativeSteps = nativeSteps
        self.fallbackSteps = fallbackSteps
    }
}

public struct ARM64BackendPerformanceSnapshot: Codable, Equatable {
    public let decodedBasicBlockExecutions: Int
    public let decodedBasicBlockSteps: Int
    public let decodedBasicBlockNanoseconds: UInt64
    public let singleInstructionSteps: Int
    public let singleInstructionNanoseconds: UInt64
    public let nativeSingleInstructionSteps: Int
    public let swiftFallbackSingleInstructionSteps: Int
    public let nativeBasicBlockExecutions: Int
    public let nativeBasicBlockSteps: Int
    public let nativeBasicBlockNanoseconds: UInt64
    public let nativeBasicBlockUnsupportedExits: Int
    public let nativeDirectLinkHits: Int
    public let nativeDirectLinkMisses: Int
    public let nativeSuperblockHits: Int
    public let nativeSuperblockFrontHits: Int
    public let nativeSuperblockBlocks: Int
    public let nativeSuperblockDispatches: Int
    public let nativeGenericDispatches: Int
    public let nativeReadTLBHits: Int
    public let nativeReadTLBMisses: Int
    public let nativeWriteTLBHits: Int
    public let nativeWriteTLBMisses: Int
    public let nativeInstructionFetchHits: Int
    public let nativeInstructionTLBHits: Int
    public let nativeInstructionTLBMisses: Int
    public let nativeInstructionTLBHotHits: Int
    public let nativeInstructionTLBColdMisses: Int
    public let nativeInstructionTLBConflictMisses: Int
    public let nativeInstructionTLBInvalidationMisses: Int
    public let nativePageTableWalks: Int
    public let nativePageTableFaults: Int
    public let nativeTranslationCallbackWalks: Int
    public let nativePhysicalDeviceReads: Int
    public let nativePhysicalDeviceWrites: Int
    public let nativeFillHits: Int
    public let nativeFillMisses: Int
    public let nativeFastRAMReadHits: Int
    public let nativeFastRAMReadMisses: Int
    public let nativeFastRAMWriteHits: Int
    public let nativeFastRAMWriteMisses: Int
    public let nativeBlockCacheHits: UInt64
    public let nativeBlockCacheMisses: UInt64
    public let nativeBlockCacheDecodes: UInt64
    public let nativeBlockCacheFrontHits: UInt64
    public let nativeDirectCodeFetches: UInt64
    public let nativeDecodeWindowHits: UInt64
    public let nativeDecodeWindowMisses: UInt64
    public let nativeBatchPrefetchedBlocks: UInt64
    public let nativeBatchPrefetchHits: UInt64
    public let nativeBatchPrefetchUnused: UInt64
    public let nativeBatchPrefetchLimitChanges: UInt64
    public let nativeBatchPrefetchLimit: UInt32
    public let nativeIneligibleGadgets: [ARM64BackendNamedCount]
    public let decodedFallbackGadgets: [ARM64BackendNamedCount]
    public let unsupportedInstructions: [ARM64BackendInstructionCount]

    public init(
        decodedBasicBlockExecutions: Int,
        decodedBasicBlockSteps: Int,
        decodedBasicBlockNanoseconds: UInt64,
        singleInstructionSteps: Int,
        singleInstructionNanoseconds: UInt64,
        nativeSingleInstructionSteps: Int,
        swiftFallbackSingleInstructionSteps: Int,
        nativeBasicBlockExecutions: Int,
        nativeBasicBlockSteps: Int,
        nativeBasicBlockNanoseconds: UInt64,
        nativeBasicBlockUnsupportedExits: Int,
        nativeDirectLinkHits: Int,
        nativeDirectLinkMisses: Int,
        nativeSuperblockHits: Int,
        nativeSuperblockFrontHits: Int,
        nativeSuperblockBlocks: Int,
        nativeSuperblockDispatches: Int,
        nativeGenericDispatches: Int,
        nativeReadTLBHits: Int,
        nativeReadTLBMisses: Int,
        nativeWriteTLBHits: Int,
        nativeWriteTLBMisses: Int,
        nativeInstructionFetchHits: Int,
        nativeInstructionTLBHits: Int,
        nativeInstructionTLBMisses: Int,
        nativeInstructionTLBHotHits: Int,
        nativeInstructionTLBColdMisses: Int,
        nativeInstructionTLBConflictMisses: Int,
        nativeInstructionTLBInvalidationMisses: Int,
        nativePageTableWalks: Int,
        nativePageTableFaults: Int,
        nativeTranslationCallbackWalks: Int,
        nativePhysicalDeviceReads: Int,
        nativePhysicalDeviceWrites: Int,
        nativeFillHits: Int,
        nativeFillMisses: Int,
        nativeFastRAMReadHits: Int,
        nativeFastRAMReadMisses: Int,
        nativeFastRAMWriteHits: Int,
        nativeFastRAMWriteMisses: Int,
        nativeBlockCacheHits: UInt64,
        nativeBlockCacheMisses: UInt64,
        nativeBlockCacheDecodes: UInt64,
        nativeBlockCacheFrontHits: UInt64,
        nativeDirectCodeFetches: UInt64,
        nativeDecodeWindowHits: UInt64,
        nativeDecodeWindowMisses: UInt64,
        nativeBatchPrefetchedBlocks: UInt64,
        nativeBatchPrefetchHits: UInt64,
        nativeBatchPrefetchUnused: UInt64,
        nativeBatchPrefetchLimitChanges: UInt64,
        nativeBatchPrefetchLimit: UInt32,
        nativeIneligibleGadgets: [ARM64BackendNamedCount],
        decodedFallbackGadgets: [ARM64BackendNamedCount],
        unsupportedInstructions: [ARM64BackendInstructionCount]
    ) {
        self.decodedBasicBlockExecutions = decodedBasicBlockExecutions
        self.decodedBasicBlockSteps = decodedBasicBlockSteps
        self.decodedBasicBlockNanoseconds = decodedBasicBlockNanoseconds
        self.singleInstructionSteps = singleInstructionSteps
        self.singleInstructionNanoseconds = singleInstructionNanoseconds
        self.nativeSingleInstructionSteps = nativeSingleInstructionSteps
        self.swiftFallbackSingleInstructionSteps = swiftFallbackSingleInstructionSteps
        self.nativeBasicBlockExecutions = nativeBasicBlockExecutions
        self.nativeBasicBlockSteps = nativeBasicBlockSteps
        self.nativeBasicBlockNanoseconds = nativeBasicBlockNanoseconds
        self.nativeBasicBlockUnsupportedExits = nativeBasicBlockUnsupportedExits
        self.nativeDirectLinkHits = nativeDirectLinkHits
        self.nativeDirectLinkMisses = nativeDirectLinkMisses
        self.nativeSuperblockHits = nativeSuperblockHits
        self.nativeSuperblockFrontHits = nativeSuperblockFrontHits
        self.nativeSuperblockBlocks = nativeSuperblockBlocks
        self.nativeSuperblockDispatches = nativeSuperblockDispatches
        self.nativeGenericDispatches = nativeGenericDispatches
        self.nativeReadTLBHits = nativeReadTLBHits
        self.nativeReadTLBMisses = nativeReadTLBMisses
        self.nativeWriteTLBHits = nativeWriteTLBHits
        self.nativeWriteTLBMisses = nativeWriteTLBMisses
        self.nativeInstructionFetchHits = nativeInstructionFetchHits
        self.nativeInstructionTLBHits = nativeInstructionTLBHits
        self.nativeInstructionTLBMisses = nativeInstructionTLBMisses
        self.nativeInstructionTLBHotHits = nativeInstructionTLBHotHits
        self.nativeInstructionTLBColdMisses = nativeInstructionTLBColdMisses
        self.nativeInstructionTLBConflictMisses = nativeInstructionTLBConflictMisses
        self.nativeInstructionTLBInvalidationMisses = nativeInstructionTLBInvalidationMisses
        self.nativePageTableWalks = nativePageTableWalks
        self.nativePageTableFaults = nativePageTableFaults
        self.nativeTranslationCallbackWalks = nativeTranslationCallbackWalks
        self.nativePhysicalDeviceReads = nativePhysicalDeviceReads
        self.nativePhysicalDeviceWrites = nativePhysicalDeviceWrites
        self.nativeFillHits = nativeFillHits
        self.nativeFillMisses = nativeFillMisses
        self.nativeFastRAMReadHits = nativeFastRAMReadHits
        self.nativeFastRAMReadMisses = nativeFastRAMReadMisses
        self.nativeFastRAMWriteHits = nativeFastRAMWriteHits
        self.nativeFastRAMWriteMisses = nativeFastRAMWriteMisses
        self.nativeBlockCacheHits = nativeBlockCacheHits
        self.nativeBlockCacheMisses = nativeBlockCacheMisses
        self.nativeBlockCacheDecodes = nativeBlockCacheDecodes
        self.nativeBlockCacheFrontHits = nativeBlockCacheFrontHits
        self.nativeDirectCodeFetches = nativeDirectCodeFetches
        self.nativeDecodeWindowHits = nativeDecodeWindowHits
        self.nativeDecodeWindowMisses = nativeDecodeWindowMisses
        self.nativeBatchPrefetchedBlocks = nativeBatchPrefetchedBlocks
        self.nativeBatchPrefetchHits = nativeBatchPrefetchHits
        self.nativeBatchPrefetchUnused = nativeBatchPrefetchUnused
        self.nativeBatchPrefetchLimitChanges = nativeBatchPrefetchLimitChanges
        self.nativeBatchPrefetchLimit = nativeBatchPrefetchLimit
        self.nativeIneligibleGadgets = nativeIneligibleGadgets
        self.decodedFallbackGadgets = decodedFallbackGadgets
        self.unsupportedInstructions = unsupportedInstructions
    }
}

public enum VMError: Error, CustomStringConvertible {
    case invalidMemoryAccess(address: GuestAddress, width: Int)
    case invalidMMIOAccess(address: GuestAddress, width: Int)
    case overlappingMMIORange(device: String, existing: String)
    case unsupportedInstruction(instruction: UInt32, pc: GuestAddress)
    case maxStepsExceeded(Int)
    case invalidRegister(Int)
    case invalidSnapshot(String)
    case policyViolation(String)
    case unsupportedGuest(String)
    case deviceError(String)

    public var description: String {
        switch self {
        case let .invalidMemoryAccess(address, width):
            return "invalid memory access at \(address.hexString) width=\(width)"
        case let .invalidMMIOAccess(address, width):
            return "invalid MMIO access at \(address.hexString) width=\(width)"
        case let .overlappingMMIORange(device, existing):
            return "MMIO range for \(device) overlaps \(existing)"
        case let .unsupportedInstruction(instruction, pc):
            return "unsupported instruction \(instruction.hexString) at \(pc.hexString)"
        case let .maxStepsExceeded(count):
            return "maximum step count exceeded: \(count)"
        case let .invalidRegister(index):
            return "invalid register index: \(index)"
        case let .invalidSnapshot(reason):
            return "invalid snapshot: \(reason)"
        case let .policyViolation(reason):
            return "policy violation: \(reason)"
        case let .unsupportedGuest(reason):
            return "unsupported guest: \(reason)"
        case let .deviceError(reason):
            return "device error: \(reason)"
        }
    }
}

extension UInt64 {
    var hexString: String {
        "0x" + String(self, radix: 16)
    }
}

extension UInt32 {
    var hexString: String {
        "0x" + String(self, radix: 16)
    }
}
