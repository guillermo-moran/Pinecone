public enum ARM64ExceptionClass: UInt64, Codable, Equatable {
    case unknown = 0x00
    case supervisorCallAArch64 = 0x15
    case instructionAbortLowerEL = 0x20
    case instructionAbortSameEL = 0x21
    case dataAbortLowerEL = 0x24
    case dataAbortSameEL = 0x25
    case breakpointAArch64 = 0x3c

    public func syndrome(il: Bool = true, iss: UInt64 = 0) -> UInt64 {
        (rawValue << 26) | (il ? (1 << 25) : 0) | (iss & 0x01ff_ffff)
    }
}

public enum ARM64FaultStatusCode: UInt64, Codable, Equatable {
    case addressSizeLevel0 = 0b000000
    case addressSizeLevel1 = 0b000001
    case addressSizeLevel2 = 0b000010
    case addressSizeLevel3 = 0b000011
    case translationLevel0 = 0b000100
    case translationLevel1 = 0b000101
    case translationLevel2 = 0b000110
    case translationLevel3 = 0b000111
    case accessFlagLevel0 = 0b001000
    case accessFlagLevel1 = 0b001001
    case accessFlagLevel2 = 0b001010
    case accessFlagLevel3 = 0b001011
    case permissionLevel0 = 0b001100
    case permissionLevel1 = 0b001101
    case permissionLevel2 = 0b001110
    case permissionLevel3 = 0b001111

    public static func translation(level: Int) -> ARM64FaultStatusCode {
        switch level {
        case 0:
            return .translationLevel0
        case 1:
            return .translationLevel1
        case 2:
            return .translationLevel2
        default:
            return .translationLevel3
        }
    }

    public static func addressSize(level: Int) -> ARM64FaultStatusCode {
        switch level {
        case 0:
            return .addressSizeLevel0
        case 1:
            return .addressSizeLevel1
        case 2:
            return .addressSizeLevel2
        default:
            return .addressSizeLevel3
        }
    }

    public static func accessFlag(level: Int) -> ARM64FaultStatusCode {
        switch level {
        case 0:
            return .accessFlagLevel0
        case 1:
            return .accessFlagLevel1
        case 2:
            return .accessFlagLevel2
        default:
            return .accessFlagLevel3
        }
    }

    public static func permission(level: Int) -> ARM64FaultStatusCode {
        switch level {
        case 0:
            return .permissionLevel0
        case 1:
            return .permissionLevel1
        case 2:
            return .permissionLevel2
        default:
            return .permissionLevel3
        }
    }
}

public struct ARM64TranslationFault: Error, Codable, Equatable, CustomStringConvertible {
    public let virtualAddress: GuestAddress
    public let access: GuestMemoryAccessKind
    public let level: Int
    public let statusCode: ARM64FaultStatusCode

    public init(
        virtualAddress: GuestAddress,
        access: GuestMemoryAccessKind,
        level: Int,
        statusCode: ARM64FaultStatusCode
    ) {
        self.virtualAddress = virtualAddress
        self.access = access
        self.level = level
        self.statusCode = statusCode
    }

    public var syndromeISS: UInt64 {
        var iss = statusCode.rawValue
        if access == .dataWrite {
            iss |= 1 << 6
        }
        return iss
    }

    public var description: String {
        "translation fault \(statusCode) level=\(level) access=\(access.rawValue) va=\(virtualAddress.hexString)"
    }
}
