public enum GuestMemoryAccessKind: Codable, Equatable, Hashable {
    case instruction
    case dataRead
    case dataWrite

    public var rawValue: String {
        switch self {
        case .instruction:
            return "instruction"
        case .dataRead:
            return "dataRead"
        case .dataWrite:
            return "dataWrite"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "instruction":
            self = .instruction
        case "dataRead":
            self = .dataRead
        case "dataWrite":
            self = .dataWrite
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown guest memory access kind: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var translationCacheDiscriminator: UInt64 {
        switch self {
        case .instruction:
            return 0
        case .dataRead:
            return 1
        case .dataWrite:
            return 2
        }
    }
}

struct ARM64TranslationCacheKey: Hashable {
    let virtualPage: GuestAddress
    let access: UInt64
    let exceptionLevel: UInt64
    let sctlr: UInt64
    let tcr: UInt64
    let ttbr: UInt64
}

public enum ARM64Stage1Translator {
    private static let outputAddressMask: UInt64 = 0x0000_ffff_ffff_f000
    private static let accessFlagBit: UInt64 = 1 << 10
    private static let readOnlyAPBit: UInt64 = 1 << 7
    private static let privilegedExecuteNeverBit: UInt64 = 1 << 53
    private static let unprivilegedExecuteNeverBit: UInt64 = 1 << 54

    public static func translate(
        virtualAddress: GuestAddress,
        access: GuestMemoryAccessKind,
        vm: VirtualMachine
    ) throws -> GuestAddress {
        let sctlr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.sctlrEL1)
        guard (sctlr & 0x1) != 0 else {
            return virtualAddress
        }

        let usesTTBR1 = (virtualAddress >> 63) == 1
        let tcr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.tcrEL1)
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

        let ttbrKey = usesTTBR1 ? ARM64SystemRegister.ttbr1EL1 : ARM64SystemRegister.ttbr0EL1
        let tableBase = vm.systemRegisters.rawValue(for: ttbrKey) & outputAddressMask
        guard tableBase != 0 else {
            throw ARM64TranslationFault(
                virtualAddress: virtualAddress,
                access: access,
                level: 0,
                statusCode: .translation(level: 0)
            )
        }

        let effectiveVA = inputAddressSize == 64
            ? virtualAddress
            : virtualAddress & ((UInt64(1) << UInt64(inputAddressSize)) - 1)
        return try walk4KBPageTables(
            virtualAddress: effectiveVA,
            originalVirtualAddress: virtualAddress,
            access: access,
            tableBase: tableBase,
            vm: vm
        )
    }

    private static func walk4KBPageTables(
        virtualAddress: GuestAddress,
        originalVirtualAddress: GuestAddress,
        access: GuestMemoryAccessKind,
        tableBase: GuestAddress,
        vm: VirtualMachine
    ) throws -> GuestAddress {
        var currentTable = tableBase

        for level in 0...3 {
            let shift = 39 - (level * 9)
            let index = (virtualAddress >> UInt64(shift)) & 0x1ff
            let descriptorAddress = currentTable + index * 8
            let descriptor: UInt64
            do {
                descriptor = try vm.readPhysical(descriptorAddress, width: .doubleword)
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
                try validateLeafAccess(
                    descriptor: descriptor,
                    level: level,
                    originalVirtualAddress: originalVirtualAddress,
                    access: access,
                    vm: vm
                )
                return (descriptor & outputAddressMask) | (virtualAddress & 0xfff)
            }

            if descriptorType == 0x1 {
                let offsetBits = UInt64(39 - (level * 9))
                let offsetMask = (UInt64(1) << offsetBits) - 1
                try validateLeafAccess(
                    descriptor: descriptor,
                    level: level,
                    originalVirtualAddress: originalVirtualAddress,
                    access: access,
                    vm: vm
                )
                let outputBase = descriptor & outputAddressMask & ~offsetMask
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
            currentTable = descriptor & outputAddressMask
        }

        throw ARM64TranslationFault(
            virtualAddress: originalVirtualAddress,
            access: access,
            level: 3,
            statusCode: .translation(level: 3)
        )
    }

    private static func validateLeafAccess(
        descriptor: UInt64,
        level: Int,
        originalVirtualAddress: GuestAddress,
        access: GuestMemoryAccessKind,
        vm: VirtualMachine
    ) throws {
        if (descriptor & accessFlagBit) == 0 {
            throw ARM64TranslationFault(
                virtualAddress: originalVirtualAddress,
                access: access,
                level: level,
                statusCode: .accessFlag(level: level)
            )
        }

        if access == .dataWrite, (descriptor & readOnlyAPBit) != 0 {
            throw ARM64TranslationFault(
                virtualAddress: originalVirtualAddress,
                access: access,
                level: level,
                statusCode: .permission(level: level)
            )
        }

        if access == .instruction {
            let executeNever = ((vm.cpu.pstate >> 2) & 0x3) == 0
                ? (descriptor & unprivilegedExecuteNeverBit) != 0
                : (descriptor & privilegedExecuteNeverBit) != 0
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
}
