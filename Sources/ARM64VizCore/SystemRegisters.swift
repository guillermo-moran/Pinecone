public struct ARM64SystemRegisterKey: Hashable, Codable, CustomStringConvertible {
    public let op0: UInt8
    public let op1: UInt8
    public let crn: UInt8
    public let crm: UInt8
    public let op2: UInt8

    public init(op0: UInt8, op1: UInt8, crn: UInt8, crm: UInt8, op2: UInt8) {
        self.op0 = op0 & 0x3
        self.op1 = op1 & 0x7
        self.crn = crn & 0xf
        self.crm = crm & 0xf
        self.op2 = op2 & 0x7
    }

    public init(instruction: UInt32) {
        self.init(
            op0: UInt8((instruction >> 19) & 0x3),
            op1: UInt8((instruction >> 16) & 0x7),
            crn: UInt8((instruction >> 12) & 0xf),
            crm: UInt8((instruction >> 8) & 0xf),
            op2: UInt8((instruction >> 5) & 0x7)
        )
    }

    public var rawValue: UInt16 {
        UInt16(op0) << 14 |
            UInt16(op1) << 11 |
            UInt16(crn) << 7 |
            UInt16(crm) << 3 |
            UInt16(op2)
    }

    public var description: String {
        ARM64SystemRegister.name(for: self) ?? "S\(op0)_\(op1)_C\(crn)_C\(crm)_\(op2)"
    }
}

public enum ARM64SystemRegister {
    public static let midrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 0, op2: 0)
    public static let ctrEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 0, crm: 0, op2: 1)
    public static let dczidEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 0, crm: 0, op2: 7)
    public static let mpidrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 0, op2: 5)
    public static let revidrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 0, op2: 6)

    public static let idAA64PFR0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 4, op2: 0)
    public static let idAA64PFR1EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 4, op2: 1)
    public static let idAA64DFR0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 5, op2: 0)
    public static let idAA64ISAR0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 6, op2: 0)
    public static let idAA64ISAR1EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 6, op2: 1)
    public static let idAA64MMFR0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 7, op2: 0)
    public static let idAA64MMFR1EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 0, crm: 7, op2: 1)

    public static let sctlrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 1, crm: 0, op2: 0)
    public static let actlrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 1, crm: 0, op2: 1)
    public static let cpacrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 1, crm: 0, op2: 2)

    public static let ttbr0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 2, crm: 0, op2: 0)
    public static let ttbr1EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 2, crm: 0, op2: 1)
    public static let tcrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 2, crm: 0, op2: 2)

    public static let spsrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 4, crm: 0, op2: 0)
    public static let elrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 4, crm: 0, op2: 1)
    public static let spEL0 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 4, crm: 1, op2: 0)
    public static let currentEL = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 4, crm: 2, op2: 2)
    public static let nzcv = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 4, crm: 2, op2: 0)
    public static let daif = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 4, crm: 2, op2: 1)
    public static let fpcr = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 4, crm: 4, op2: 0)
    public static let fpsr = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 4, crm: 4, op2: 1)

    public static let afsr0EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 5, crm: 1, op2: 0)
    public static let afsr1EL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 5, crm: 1, op2: 1)
    public static let esrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 5, crm: 2, op2: 0)
    public static let farEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 6, crm: 0, op2: 0)
    public static let parEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 7, crm: 4, op2: 0)

    public static let mairEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 10, crm: 2, op2: 0)
    public static let amairEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 10, crm: 3, op2: 0)
    public static let vbarEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 12, crm: 0, op2: 0)
    public static let contextidrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 13, crm: 0, op2: 1)
    public static let tpidrEL1 = ARM64SystemRegisterKey(op0: 3, op1: 0, crn: 13, crm: 0, op2: 4)
    public static let tpidrEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 13, crm: 0, op2: 2)
    public static let tpidrroEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 13, crm: 0, op2: 3)

    public static let cntfrqEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 0, op2: 0)
    public static let cntpctEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 0, op2: 1)
    public static let cntvctEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 0, op2: 2)
    public static let cntpTvalEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 2, op2: 0)
    public static let cntpCtlEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 2, op2: 1)
    public static let cntpCvalEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 2, op2: 2)
    public static let cntvTvalEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 3, op2: 0)
    public static let cntvCtlEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 3, op2: 1)
    public static let cntvCvalEL0 = ARM64SystemRegisterKey(op0: 3, op1: 3, crn: 14, crm: 3, op2: 2)

    public static func name(for key: ARM64SystemRegisterKey) -> String? {
        namesByRawValue[key.rawValue]
    }

    private static let namesByRawValue: [UInt16: String] = [
        midrEL1.rawValue: "MIDR_EL1",
        ctrEL0.rawValue: "CTR_EL0",
        dczidEL0.rawValue: "DCZID_EL0",
        mpidrEL1.rawValue: "MPIDR_EL1",
        revidrEL1.rawValue: "REVIDR_EL1",
        idAA64PFR0EL1.rawValue: "ID_AA64PFR0_EL1",
        idAA64PFR1EL1.rawValue: "ID_AA64PFR1_EL1",
        idAA64DFR0EL1.rawValue: "ID_AA64DFR0_EL1",
        idAA64ISAR0EL1.rawValue: "ID_AA64ISAR0_EL1",
        idAA64ISAR1EL1.rawValue: "ID_AA64ISAR1_EL1",
        idAA64MMFR0EL1.rawValue: "ID_AA64MMFR0_EL1",
        idAA64MMFR1EL1.rawValue: "ID_AA64MMFR1_EL1",
        sctlrEL1.rawValue: "SCTLR_EL1",
        actlrEL1.rawValue: "ACTLR_EL1",
        cpacrEL1.rawValue: "CPACR_EL1",
        ttbr0EL1.rawValue: "TTBR0_EL1",
        ttbr1EL1.rawValue: "TTBR1_EL1",
        tcrEL1.rawValue: "TCR_EL1",
        spsrEL1.rawValue: "SPSR_EL1",
        elrEL1.rawValue: "ELR_EL1",
        spEL0.rawValue: "SP_EL0",
        currentEL.rawValue: "CurrentEL",
        nzcv.rawValue: "NZCV",
        daif.rawValue: "DAIF",
        fpcr.rawValue: "FPCR",
        fpsr.rawValue: "FPSR",
        afsr0EL1.rawValue: "AFSR0_EL1",
        afsr1EL1.rawValue: "AFSR1_EL1",
        esrEL1.rawValue: "ESR_EL1",
        farEL1.rawValue: "FAR_EL1",
        parEL1.rawValue: "PAR_EL1",
        mairEL1.rawValue: "MAIR_EL1",
        amairEL1.rawValue: "AMAIR_EL1",
        vbarEL1.rawValue: "VBAR_EL1",
        contextidrEL1.rawValue: "CONTEXTIDR_EL1",
        tpidrEL1.rawValue: "TPIDR_EL1",
        tpidrEL0.rawValue: "TPIDR_EL0",
        tpidrroEL0.rawValue: "TPIDRRO_EL0",
        cntfrqEL0.rawValue: "CNTFRQ_EL0",
        cntpctEL0.rawValue: "CNTPCT_EL0",
        cntvctEL0.rawValue: "CNTVCT_EL0",
        cntpTvalEL0.rawValue: "CNTP_TVAL_EL0",
        cntpCtlEL0.rawValue: "CNTP_CTL_EL0",
        cntpCvalEL0.rawValue: "CNTP_CVAL_EL0",
        cntvTvalEL0.rawValue: "CNTV_TVAL_EL0",
        cntvCtlEL0.rawValue: "CNTV_CTL_EL0",
        cntvCvalEL0.rawValue: "CNTV_CVAL_EL0"
    ]
}

public struct ARM64SystemRegisterBank: Codable, Equatable {
    public private(set) var storage: [UInt16: UInt64]
    public private(set) var counterTicks: UInt64
    private var knownValues: [UInt64]

    public init() {
        self.storage = [:]
        self.counterTicks = 0
        self.knownValues = [UInt64](
            repeating: 0,
            count: Self.knownRegisterCount
        )
        reset()
    }

    private enum CodingKeys: String, CodingKey {
        case storage
        case counterTicks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decode([UInt16: UInt64].self, forKey: .storage)
        counterTicks = try container.decode(UInt64.self, forKey: .counterTicks)
        knownValues = [UInt64](repeating: 0, count: Self.knownRegisterCount)
        refreshKnownSystemRegisters()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage, forKey: .storage)
        try container.encode(counterTicks, forKey: .counterTicks)
    }

    public mutating func reset() {
        storage = Self.defaultValues
        counterTicks = 0
        refreshKnownSystemRegisters()
    }

    public mutating func advance(cycles: UInt64 = 1) {
        counterTicks &+= cycles
    }

    public func rawValue(for key: ARM64SystemRegisterKey) -> UInt64 {
        let rawKey = key.rawValue
        if let index = Self.knownRegisterIndex(rawKey) {
            return knownValues[index]
        }
        return storage[rawKey] ?? 0
    }

    public mutating func writeRaw(_ key: ARM64SystemRegisterKey, value: UInt64) {
        setStoredValue(rawKey: key.rawValue, value: value)
    }

    public func read(_ key: ARM64SystemRegisterKey, cpu: CPUState) -> UInt64 {
        read(key, sp: cpu.sp, pstate: cpu.pstate)
    }

    public func read(
        _ key: ARM64SystemRegisterKey,
        sp: UInt64,
        pstate: UInt64
    ) -> UInt64 {
        switch key.rawValue {
        case ARM64SystemRegister.currentEL.rawValue:
            return pstate & 0xc
        case ARM64SystemRegister.daif.rawValue:
            return pstate & 0x3c0
        case ARM64SystemRegister.nzcv.rawValue:
            return pstate & 0xf000_0000
        case ARM64SystemRegister.spEL0.rawValue:
            return CPUState.stackPointerBank(for: pstate) == .spEL0
                ? sp
                : rawValue(for: key)
        case ARM64SystemRegister.cntpctEL0.rawValue, ARM64SystemRegister.cntvctEL0.rawValue:
            return counterTicks
        case ARM64SystemRegister.cntpTvalEL0.rawValue:
            return timerValue(fromCompare: rawValue(for: ARM64SystemRegister.cntpCvalEL0))
        case ARM64SystemRegister.cntvTvalEL0.rawValue:
            return timerValue(fromCompare: rawValue(for: ARM64SystemRegister.cntvCvalEL0))
        case ARM64SystemRegister.cntpCtlEL0.rawValue:
            return timerControlValue(rawValue(for: ARM64SystemRegister.cntpCtlEL0), compare: rawValue(for: ARM64SystemRegister.cntpCvalEL0))
        case ARM64SystemRegister.cntvCtlEL0.rawValue:
            return timerControlValue(rawValue(for: ARM64SystemRegister.cntvCtlEL0), compare: rawValue(for: ARM64SystemRegister.cntvCvalEL0))
        default:
            return rawValue(for: key)
        }
    }

    public mutating func write(_ key: ARM64SystemRegisterKey, value: UInt64, cpu: inout CPUState) {
        write(key, value: value, pstate: &cpu.pstate, sp: &cpu.sp)
    }

    public mutating func write(
        _ key: ARM64SystemRegisterKey,
        value: UInt64,
        pstate: inout UInt64,
        sp: inout UInt64
    ) {
        switch key.rawValue {
        case ARM64SystemRegister.currentEL.rawValue,
             ARM64SystemRegister.midrEL1.rawValue,
             ARM64SystemRegister.ctrEL0.rawValue,
             ARM64SystemRegister.dczidEL0.rawValue,
             ARM64SystemRegister.mpidrEL1.rawValue,
             ARM64SystemRegister.revidrEL1.rawValue,
             ARM64SystemRegister.idAA64PFR0EL1.rawValue,
             ARM64SystemRegister.idAA64PFR1EL1.rawValue,
             ARM64SystemRegister.idAA64DFR0EL1.rawValue,
             ARM64SystemRegister.idAA64ISAR0EL1.rawValue,
             ARM64SystemRegister.idAA64ISAR1EL1.rawValue,
             ARM64SystemRegister.idAA64MMFR0EL1.rawValue,
             ARM64SystemRegister.idAA64MMFR1EL1.rawValue,
             ARM64SystemRegister.cntfrqEL0.rawValue,
             ARM64SystemRegister.cntpctEL0.rawValue,
             ARM64SystemRegister.cntvctEL0.rawValue:
            return
        case ARM64SystemRegister.daif.rawValue:
            pstate = (pstate & ~UInt64(0x3c0)) | (value & 0x3c0)
        case ARM64SystemRegister.nzcv.rawValue:
            pstate = (pstate & ~UInt64(0xf000_0000)) | (value & 0xf000_0000)
        case ARM64SystemRegister.spEL0.rawValue:
            if CPUState.stackPointerBank(for: pstate) == .spEL0 {
                sp = value
            } else {
                setStoredValue(rawKey: key.rawValue, value: value)
            }
        case ARM64SystemRegister.cntpTvalEL0.rawValue:
            setStoredValue(rawKey: ARM64SystemRegister.cntpCvalEL0.rawValue, value: addTimerValueOffset(value))
        case ARM64SystemRegister.cntvTvalEL0.rawValue:
            setStoredValue(rawKey: ARM64SystemRegister.cntvCvalEL0.rawValue, value: addTimerValueOffset(value))
        case ARM64SystemRegister.cntpCtlEL0.rawValue:
            setStoredValue(rawKey: key.rawValue, value: value & 0x3)
        case ARM64SystemRegister.cntvCtlEL0.rawValue:
            setStoredValue(rawKey: key.rawValue, value: value & 0x3)
        default:
            setStoredValue(rawKey: key.rawValue, value: value)
        }
    }

    public var physicalTimerInterruptAsserted: Bool {
        timerInterruptAsserted(
            control: rawValue(for: ARM64SystemRegister.cntpCtlEL0),
            compare: rawValue(for: ARM64SystemRegister.cntpCvalEL0)
        )
    }

    public var virtualTimerInterruptAsserted: Bool {
        timerInterruptAsserted(
            control: rawValue(for: ARM64SystemRegister.cntvCtlEL0),
            compare: rawValue(for: ARM64SystemRegister.cntvCvalEL0)
        )
    }

    public var nextUnmaskedTimerDeadline: UInt64? {
        let physical = nextTimerDeadline(
            control: rawValue(for: ARM64SystemRegister.cntpCtlEL0),
            compare: rawValue(for: ARM64SystemRegister.cntpCvalEL0)
        )
        let virtual = nextTimerDeadline(
            control: rawValue(for: ARM64SystemRegister.cntvCtlEL0),
            compare: rawValue(for: ARM64SystemRegister.cntvCvalEL0)
        )

        switch (physical, virtual) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func timerInterruptAsserted(control: UInt64, compare: UInt64) -> Bool {
        let enabled = (control & 0x1) != 0
        let masked = (control & 0x2) != 0
        return enabled && !masked && counterTicks >= compare
    }

    private func nextTimerDeadline(control: UInt64, compare: UInt64) -> UInt64? {
        let enabled = (control & 0x1) != 0
        let masked = (control & 0x2) != 0
        guard enabled && !masked else {
            return nil
        }
        return compare <= counterTicks ? counterTicks &+ 1 : compare
    }

    private func timerControlValue(_ control: UInt64, compare: UInt64) -> UInt64 {
        (control & 0x3) | (counterTicks >= compare ? 0x4 : 0)
    }

    private func timerValue(fromCompare compare: UInt64) -> UInt64 {
        UInt64(UInt32(truncatingIfNeeded: compare &- counterTicks))
    }

    private func addTimerValueOffset(_ value: UInt64) -> UInt64 {
        let offset = Int64(Int32(bitPattern: UInt32(value & 0xffff_ffff)))
        return UInt64(bitPattern: Int64(bitPattern: counterTicks) &+ offset)
    }

    private mutating func refreshKnownSystemRegisters() {
        knownValues = [UInt64](repeating: 0, count: Self.knownRegisterCount)
        for (rawKey, value) in storage {
            if let index = Self.knownRegisterIndex(rawKey) {
                knownValues[index] = value
            }
        }
    }

    private mutating func setStoredValue(rawKey: UInt16, value: UInt64) {
        storage[rawKey] = value
        if let index = Self.knownRegisterIndex(rawKey) {
            knownValues[index] = value
        }
    }

    private static let knownRegisterCount = 47

    @inline(__always)
    private static func knownRegisterIndex(_ rawKey: UInt16) -> Int? {
        switch rawKey {
        case ARM64SystemRegister.midrEL1.rawValue: return 0
        case ARM64SystemRegister.ctrEL0.rawValue: return 1
        case ARM64SystemRegister.dczidEL0.rawValue: return 2
        case ARM64SystemRegister.mpidrEL1.rawValue: return 3
        case ARM64SystemRegister.revidrEL1.rawValue: return 4
        case ARM64SystemRegister.idAA64PFR0EL1.rawValue: return 5
        case ARM64SystemRegister.idAA64PFR1EL1.rawValue: return 6
        case ARM64SystemRegister.idAA64DFR0EL1.rawValue: return 7
        case ARM64SystemRegister.idAA64ISAR0EL1.rawValue: return 8
        case ARM64SystemRegister.idAA64ISAR1EL1.rawValue: return 9
        case ARM64SystemRegister.idAA64MMFR0EL1.rawValue: return 10
        case ARM64SystemRegister.idAA64MMFR1EL1.rawValue: return 11
        case ARM64SystemRegister.sctlrEL1.rawValue: return 12
        case ARM64SystemRegister.actlrEL1.rawValue: return 13
        case ARM64SystemRegister.cpacrEL1.rawValue: return 14
        case ARM64SystemRegister.ttbr0EL1.rawValue: return 15
        case ARM64SystemRegister.ttbr1EL1.rawValue: return 16
        case ARM64SystemRegister.tcrEL1.rawValue: return 17
        case ARM64SystemRegister.spsrEL1.rawValue: return 18
        case ARM64SystemRegister.elrEL1.rawValue: return 19
        case ARM64SystemRegister.spEL0.rawValue: return 20
        case ARM64SystemRegister.currentEL.rawValue: return 21
        case ARM64SystemRegister.nzcv.rawValue: return 22
        case ARM64SystemRegister.daif.rawValue: return 23
        case ARM64SystemRegister.fpcr.rawValue: return 24
        case ARM64SystemRegister.fpsr.rawValue: return 25
        case ARM64SystemRegister.afsr0EL1.rawValue: return 26
        case ARM64SystemRegister.afsr1EL1.rawValue: return 27
        case ARM64SystemRegister.esrEL1.rawValue: return 28
        case ARM64SystemRegister.farEL1.rawValue: return 29
        case ARM64SystemRegister.parEL1.rawValue: return 30
        case ARM64SystemRegister.mairEL1.rawValue: return 31
        case ARM64SystemRegister.amairEL1.rawValue: return 32
        case ARM64SystemRegister.vbarEL1.rawValue: return 33
        case ARM64SystemRegister.contextidrEL1.rawValue: return 34
        case ARM64SystemRegister.tpidrEL1.rawValue: return 35
        case ARM64SystemRegister.tpidrEL0.rawValue: return 36
        case ARM64SystemRegister.tpidrroEL0.rawValue: return 37
        case ARM64SystemRegister.cntfrqEL0.rawValue: return 38
        case ARM64SystemRegister.cntpctEL0.rawValue: return 39
        case ARM64SystemRegister.cntvctEL0.rawValue: return 40
        case ARM64SystemRegister.cntpTvalEL0.rawValue: return 41
        case ARM64SystemRegister.cntpCtlEL0.rawValue: return 42
        case ARM64SystemRegister.cntpCvalEL0.rawValue: return 43
        case ARM64SystemRegister.cntvTvalEL0.rawValue: return 44
        case ARM64SystemRegister.cntvCtlEL0.rawValue: return 45
        case ARM64SystemRegister.cntvCvalEL0.rawValue: return 46
        default: return nil
        }
    }

    private static let defaultValues: [UInt16: UInt64] = [
        ARM64SystemRegister.midrEL1.rawValue: 0x410f_d034,
        ARM64SystemRegister.ctrEL0.rawValue: 0x8444_c004,
        ARM64SystemRegister.dczidEL0.rawValue: 0x4,
        ARM64SystemRegister.mpidrEL1.rawValue: 0x8000_0000,
        ARM64SystemRegister.revidrEL1.rawValue: 0,
        // EL0/EL1 are AArch64; FP and Advanced SIMD are implemented so Linux
        // enables FPSIMD context management for userspace.
        ARM64SystemRegister.idAA64PFR0EL1.rawValue: 0x0000_0000_0000_0011,
        ARM64SystemRegister.idAA64PFR1EL1.rawValue: 0,
        ARM64SystemRegister.idAA64DFR0EL1.rawValue: 0,
        ARM64SystemRegister.idAA64ISAR0EL1.rawValue: 0,
        ARM64SystemRegister.idAA64ISAR1EL1.rawValue: 0,
        ARM64SystemRegister.idAA64MMFR0EL1.rawValue: 0,
        // HAFDBS is not advertised until hardware Access Flag updates have
        // completed full Linux stress validation. Linux then uses its normal
        // software access-flag fault path instead of enabling TCR_EL1.HA.
        ARM64SystemRegister.idAA64MMFR1EL1.rawValue: 0,
        ARM64SystemRegister.cntfrqEL0.rawValue: 24_000_000,
        ARM64SystemRegister.sctlrEL1.rawValue: 0,
        ARM64SystemRegister.tcrEL1.rawValue: 0,
        ARM64SystemRegister.ttbr0EL1.rawValue: 0,
        ARM64SystemRegister.ttbr1EL1.rawValue: 0,
        ARM64SystemRegister.mairEL1.rawValue: 0,
        ARM64SystemRegister.vbarEL1.rawValue: 0,
        ARM64SystemRegister.cntpCtlEL0.rawValue: 0,
        ARM64SystemRegister.cntpCvalEL0.rawValue: 0,
        ARM64SystemRegister.cntvCtlEL0.rawValue: 0,
        ARM64SystemRegister.cntvCvalEL0.rawValue: 0
    ]
}
