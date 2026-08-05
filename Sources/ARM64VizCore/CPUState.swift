public struct CPUState: Codable, Equatable {
    public var x: [UInt64]
    public var v: [ARM64VectorRegister]
    public var sp: UInt64
    public var spEL1: UInt64
    public var pc: UInt64
    public var pstate: UInt64
    public var halted: Bool
    public var exclusiveReservationAddress: UInt64?
    public var exclusiveReservationSize: Int?

    public init(
        x: [UInt64] = Array(repeating: 0, count: 31),
        v: [ARM64VectorRegister] = Array(repeating: ARM64VectorRegister(), count: 32),
        sp: UInt64 = 0,
        spEL1: UInt64 = 0,
        pc: UInt64 = 0,
        pstate: UInt64 = 0,
        halted: Bool = false,
        exclusiveReservationAddress: UInt64? = nil,
        exclusiveReservationSize: Int? = nil
    ) {
        precondition(x.count == 31, "ARM64 CPU state stores X0...X30")
        precondition(v.count == 32, "ARM64 CPU state stores V0...V31")
        self.x = x
        self.v = v
        self.sp = sp
        self.spEL1 = spEL1
        self.pc = pc
        self.pstate = pstate
        self.halted = halted
        self.exclusiveReservationAddress = exclusiveReservationAddress
        self.exclusiveReservationSize = exclusiveReservationSize
    }

    public subscript(register index: Int) -> UInt64 {
        get {
            precondition((0..<31).contains(index), "register index out of range")
            return x[index]
        }
        set {
            precondition((0..<31).contains(index), "register index out of range")
            x[index] = newValue
        }
    }

    public var currentExceptionLevel: UInt8 {
        UInt8((pstate >> 2) & 0x3)
    }

    public var activeStackPointerBank: ARM64StackPointerBank {
        Self.stackPointerBank(for: pstate)
    }

    public static func stackPointerBank(for pstate: UInt64) -> ARM64StackPointerBank {
        let exceptionLevel = (pstate >> 2) & 0x3
        if exceptionLevel == 0 {
            return .spEL0
        }
        if exceptionLevel == 1, (pstate & 0x1) == 0 {
            return .spEL0
        }
        return .spEL1
    }
}

public enum ARM64StackPointerBank: Codable, Equatable {
    case spEL0
    case spEL1
}

public struct ARM64VectorRegister: Codable, Equatable {
    public var low: UInt64
    public var high: UInt64

    public init(low: UInt64 = 0, high: UInt64 = 0) {
        self.low = low
        self.high = high
    }
}

public enum ARM64PState {
    public static let el0t: UInt64 = 0x0
    public static let el1h: UInt64 = 0x5
    public static let el1hMasked: UInt64 = 0x3c5
    public static let el2h: UInt64 = 0x9
    public static let el2hMasked: UInt64 = 0x3c9
    public static let irqMask: UInt64 = 0x80
}
