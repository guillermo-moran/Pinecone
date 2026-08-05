public struct InstructionTraceEntry: Codable, Equatable {
    public let step: Int
    public let pc: GuestAddress
    public let instruction: UInt32
    public let decode: String
    public let pstateBefore: UInt64
    public let pstateAfter: UInt64?

    public init(
        step: Int,
        pc: GuestAddress,
        instruction: UInt32,
        decode: String,
        pstateBefore: UInt64 = 0,
        pstateAfter: UInt64? = nil
    ) {
        self.step = step
        self.pc = pc
        self.instruction = instruction
        self.decode = decode
        self.pstateBefore = pstateBefore
        self.pstateAfter = pstateAfter
    }

    func completed(pstateAfter: UInt64) -> InstructionTraceEntry {
        InstructionTraceEntry(
            step: step,
            pc: pc,
            instruction: instruction,
            decode: decode,
            pstateBefore: pstateBefore,
            pstateAfter: pstateAfter
        )
    }
}

public enum ARM64InstructionClassifier {
    public static func classify(_ instruction: UInt32) -> String {
        if instruction == 0xd503_201f {
            return "nop"
        }
        if instruction == 0xd503_205f {
            return "wfe"
        }
        if instruction == 0xd503_207f {
            return "wfi"
        }
        if instruction == 0xd503_209f {
            return "sev"
        }
        if instruction == 0xd503_20bf {
            return "sevl"
        }
        if (instruction & 0xffff_f01f) == 0xd503_201f {
            return "hint"
        }
        if instruction == 0xd69f_03e0 {
            return "eret"
        }
        if (instruction & 0xffe0_001f) == 0xd400_0001 {
            return "svc"
        }
        if (instruction & 0xffe0_001f) == 0xd420_0000 {
            return "brk"
        }
        if (instruction & 0xffe0_001f) == 0xd440_0000 {
            return "hlt"
        }
        if (instruction & 0xffff_f0ff) == 0xd503_305f {
            return "clrex"
        }
        if (instruction & 0x1f80_0000) == 0x1280_0000 {
            switch (instruction >> 29) & 0x3 {
            case 0:
                return "movn"
            case 2:
                return "movz"
            case 3:
                return "movk"
            default:
                return "move-wide"
            }
        }
        if (instruction & 0x3fe0_0c10) == 0x3a40_0000 {
            return ((instruction >> 30) & 0x1) == 1 ? "ccmp-register" : "ccmn-register"
        }
        if (instruction & 0x3fe0_0c10) == 0x3a40_0800 {
            return ((instruction >> 30) & 0x1) == 1 ? "ccmp-immediate" : "ccmn-immediate"
        }
        if (instruction & 0x1fe0_fc00) == 0x1a00_0000 {
            let subtract = ((instruction >> 30) & 0x1) == 1
            let setFlags = ((instruction >> 29) & 0x1) == 1
            switch (subtract, setFlags) {
            case (false, false):
                return "adc"
            case (false, true):
                return "adcs"
            case (true, false):
                return "sbc"
            case (true, true):
                return "sbcs"
            }
        }
        if (instruction & 0x1f80_0000) == 0x1200_0000 {
            switch (instruction >> 29) & 0x3 {
            case 0:
                return "and-immediate"
            case 1:
                return "orr-immediate"
            case 2:
                return "eor-immediate"
            default:
                return "ands-immediate"
            }
        }
        if (instruction & 0x1f00_0000) == 0x0a00_0000 {
            let opcode = (instruction >> 29) & 0x3
            let invertOperand = ((instruction >> 21) & 0x1) == 1
            let shiftType = (instruction >> 22) & 0x3
            let shift = (instruction >> 10) & 0x3f
            let rn = (instruction >> 5) & 0x1f
            if opcode == 1 && !invertOperand && rn == 31 && shiftType == 0 && shift == 0 {
                return "mov-register"
            }
            switch (opcode, invertOperand) {
            case (0, false):
                return "and-shifted-register"
            case (0, true):
                return "bic-shifted-register"
            case (1, false):
                return "orr-shifted-register"
            case (1, true):
                return "orn-shifted-register"
            case (2, false):
                return "eor-shifted-register"
            case (2, true):
                return "eon-shifted-register"
            case (3, false):
                return "ands-shifted-register"
            default:
                return "bics-shifted-register"
            }
        }
        if (instruction & 0x1f80_0000) == 0x1300_0000 {
            switch (instruction >> 29) & 0x3 {
            case 0:
                return "sbfm"
            case 1:
                return "bfm"
            case 2:
                return "ubfm"
            default:
                return "bitfield-move"
            }
        }
        if (instruction & 0x7fa0_0000) == 0x1380_0000 {
            let rn = (instruction >> 5) & 0x1f
            let rm = (instruction >> 16) & 0x1f
            return rn == rm ? "ror-immediate" : "extr"
        }
        if (instruction & 0x7fe0_0000) == 0x1b00_0000 {
            let subtract = ((instruction >> 15) & 0x1) == 1
            let ra = (instruction >> 10) & 0x1f
            if ra == 31 {
                return subtract ? "mneg" : "mul"
            }
            return subtract ? "msub" : "madd"
        }
        if (instruction & 0x7fe0_0000) == 0x1b20_0000 {
            let subtract = ((instruction >> 15) & 0x1) == 1
            let ra = (instruction >> 10) & 0x1f
            if ra == 31 {
                return subtract ? "smnegl" : "smull"
            }
            return subtract ? "smsubl" : "smaddl"
        }
        if (instruction & 0x7fe0_0000) == 0x1ba0_0000 {
            let subtract = ((instruction >> 15) & 0x1) == 1
            let ra = (instruction >> 10) & 0x1f
            if ra == 31 {
                return subtract ? "umnegl" : "umull"
            }
            return subtract ? "umsubl" : "umaddl"
        }
        if (instruction & 0xffe0_fc00) == 0x9b40_7c00 {
            return "smulh"
        }
        if (instruction & 0xffe0_fc00) == 0x9bc0_7c00 {
            return "umulh"
        }
        if (instruction & 0x5fe0_0000) == 0x5ac0_0000 {
            let is64Bit = ((instruction >> 31) & 0x1) == 1
            switch (instruction >> 10) & 0x3f {
            case 0x00:
                return "rbit"
            case 0x01:
                return "rev16"
            case 0x02:
                return is64Bit ? "rev32" : "rev"
            case 0x03 where is64Bit:
                return "rev"
            case 0x04:
                return "clz"
            case 0x05:
                return "cls"
            default:
                return "data-processing-1src"
            }
        }
        if (instruction & 0x7fe0_c000) == 0x1ac0_0000 {
            switch (instruction >> 10) & 0x3f {
            case 0x02:
                return "udiv"
            case 0x03:
                return "sdiv"
            case 0x08:
                return "lslv"
            case 0x09:
                return "lsrv"
            case 0x0a:
                return "asrv"
            case 0x0b:
                return "rorv"
            default:
                return "data-processing-2src"
            }
        }
        if (instruction & 0x1f20_0000) == 0x0b00_0000 {
            let subtract = ((instruction >> 30) & 0x1) == 1
            let setFlags = ((instruction >> 29) & 0x1) == 1
            switch (subtract, setFlags) {
            case (false, false):
                return "add-shifted-register"
            case (true, false):
                return "sub-shifted-register"
            case (false, true):
                return "adds-shifted-register"
            case (true, true):
                return "subs-shifted-register"
            }
        }
        if (instruction & 0x1f20_0000) == 0x0b20_0000 {
            let subtract = ((instruction >> 30) & 0x1) == 1
            let setFlags = ((instruction >> 29) & 0x1) == 1
            switch (subtract, setFlags) {
            case (false, false):
                return "add-extended-register"
            case (true, false):
                return "sub-extended-register"
            case (false, true):
                return "adds-extended-register"
            case (true, true):
                return "subs-extended-register"
            }
        }
        if (instruction & 0x1f00_0000) == 0x1100_0000 {
            let subtract = ((instruction >> 30) & 0x1) == 1
            let setFlags = ((instruction >> 29) & 0x1) == 1
            switch (subtract, setFlags) {
            case (false, false):
                return "add-immediate"
            case (true, false):
                return "sub-immediate"
            case (false, true):
                return "adds-immediate"
            case (true, true):
                return "subs-immediate"
            }
        }
        if (instruction & 0xffc0_0000) == 0x3d80_0000 {
            return "str-q-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3dc0_0000 {
            return "ldr-q-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xbd00_0000 {
            return "str-s-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xbd40_0000 {
            return "ldr-s-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xfd00_0000 {
            return "str-d-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xfd40_0000 {
            return "ldr-d-unsigned-immediate"
        }
        if isSIMDFPQSignedImmediateLoadStore(instruction) {
            return simdFPQSignedImmediateLoadStoreName(instruction)
        }
        if (instruction & 0xffff_fc00) == 0x4e08_3c00 {
            return "mov-vector-element-to-general"
        }
        if let fpGeneralMove = fpScalarGeneralMoveName(instruction) {
            return fpGeneralMove
        }
        if let fpRegisterMove = fpScalarRegisterMoveName(instruction) {
            return fpRegisterMove
        }
        if let fpImmediateMove = fpScalarImmediateMoveName(instruction) {
            return fpImmediateMove
        }
        if let fpConvert = fpIntegerToScalarFPName(instruction) {
            return fpConvert
        }
        if let fpAdd = fpScalarAddName(instruction) {
            return fpAdd
        }
        if let fpSubtract = fpScalarSubtractName(instruction) {
            return fpSubtract
        }
        if let fpMultiply = fpScalarMultiplyName(instruction) {
            return fpMultiply
        }
        if let fpSelect = fpScalarConditionalSelectName(instruction) {
            return fpSelect
        }
        if let fpCompare = fpScalarCompareZeroName(instruction) {
            return fpCompare
        }
        if let fpCompare = fpScalarCompareRegisterName(instruction) {
            return fpCompare
        }
        if let fpConvert = fpScalarConvertToSignedIntegerName(instruction) {
            return fpConvert
        }
        if let fpConvert = fpScalarConvertToUnsignedIntegerRegisterName(instruction) {
            return fpConvert
        }
        if let fpConvert = simdScalarSignedIntegerToFPName(instruction) {
            return fpConvert
        }
        if (instruction & 0xffe0_fc00) == 0x4e00_1c00 {
            return "mov-general-to-vector-element"
        }
        if (instruction & 0xbff8_fc00) == 0x0f20_a400 {
            return ((instruction >> 30) & 0x1) == 1 ? "sshll2-s-to-d" : "sshll-s-to-d"
        }
        if isSIMDTableLookup(instruction) {
            return ((instruction >> 12) & 0x1) == 1 ? "tbx-vector" : "tbl-vector"
        }
        if let permute = simdPermuteTwoVectorName(instruction) {
            return permute
        }
        if isSIMDAddSubtractVector(instruction) {
            return ((instruction >> 29) & 0x1) == 1 ? "sub-vector" : "add-vector"
        }
        if (instruction & 0xbf20_fc00) == 0x2e20_4400 {
            return "ushl-vector"
        }
        if (instruction & 0xbf20_fc00) == 0x0e20_8c00 {
            return "cmtst-vector"
        }
        if (instruction & 0xbfe0_fc00) == 0x2e20_1c00 {
            return "eor-vector"
        }
        if (instruction & 0xbf20_fc00) == 0x2e20_a400, ((instruction >> 22) & 3) != 3 {
            return "umaxp-vector"
        }
        if (instruction & 0xffff_fc00) == 0x5ef1_b800 {
            return "addp-scalar-2d"
        }
        if (instruction & 0xffc0_0000) == 0x6c80_0000 {
            return "stp-d-post-index"
        }
        if (instruction & 0xffc0_0000) == 0x6cc0_0000 {
            return "ldp-d-post-index"
        }
        if (instruction & 0xffc0_0000) == 0x6d00_0000 {
            return "stp-d-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0x6d40_0000 {
            return "ldp-d-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0x6d80_0000 {
            return "stp-d-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0x6dc0_0000 {
            return "ldp-d-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0xac80_0000 {
            return "stp-q-post-index"
        }
        if (instruction & 0xffc0_0000) == 0xacc0_0000 {
            return "ldp-q-post-index"
        }
        if (instruction & 0xffc0_0000) == 0xad00_0000 {
            return "stp-q-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0xad40_0000 {
            return "ldp-q-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0xad80_0000 {
            return "stp-q-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0xadc0_0000 {
            return "ldp-q-pre-index"
        }
        if (instruction & 0xbfe0_fc00) == 0x0e00_0c00 {
            let imm5 = (instruction >> 16) & 0x1f
            if imm5 != 0 {
                let elementBits = 8 << imm5.trailingZeroBitCount
                if elementBits <= 64, ((instruction >> 30) & 0x1) == 1 || elementBits < 64 {
                    return "dup-vector-general"
                }
            }
        }
        if (instruction & 0x1f00_0000) == 0x0f00_0000 {
            let op = (instruction >> 29) & 0x1
            let cmode = (instruction >> 12) & 0xf
            let o2 = (instruction >> 11) & 0x1
            let imm8 = (((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f)

            if o2 == 0, imm8 == 0, (op == 0 && (cmode <= 0xb || cmode == 0xe) || op == 1 && cmode == 0xe) {
                return "movi-vector-zero"
            }
        }
        if isSIMDMoveImmediateWord(instruction) {
            return "movi-vector-word"
        }
        if isSIMDMoveImmediateByte(instruction) {
            return "movi-vector-byte"
        }
        if isSIMDMoveDImmediate(instruction) {
            return "movi-d-immediate"
        }
        if isSIMDMoveInvertedImmediate(instruction) {
            return "mvni-vector-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3d00_0000 {
            return "str-b-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3d40_0000 {
            return "ldr-b-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3900_0000 {
            return "strb-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3940_0000 {
            return "ldrb-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x3980_0000 {
            return "ldrsb-64-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x39c0_0000 {
            return "ldrsb-32-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x7900_0000 {
            return "strh-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x7940_0000 {
            return "ldrh-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x7980_0000 {
            return "ldrsh-64-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0x79c0_0000 {
            return "ldrsh-32-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xb900_0000 {
            return "str-32-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xb940_0000 {
            return "ldr-32-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xb980_0000 {
            return "ldrsw-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xf900_0000 {
            return "str-64-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xf940_0000 {
            return "ldr-64-unsigned-immediate"
        }
        if (instruction & 0xffc0_0000) == 0xf980_0000 {
            return "prfm-unsigned-immediate"
        }
        if (instruction & 0x3fa0_0000) == 0x0820_0000 {
            return loadStoreExclusivePairName(instruction)
        }
        if (instruction & 0x3fa0_7c00) == 0x0800_7c00 {
            return loadStoreExclusiveName(instruction)
        }
        if (instruction & 0x3fa0_fc00) == 0x0880_fc00 {
            return loadAcquireStoreReleaseName(instruction)
        }
        if (instruction & 0x3b20_0c00) == 0x3820_0800 {
            return loadStoreRegisterOffsetName(instruction)
        }
        if (instruction & 0x3b00_0000) == 0x3800_0000 {
            return loadStoreSignedImmediateName(instruction)
        }
        if (instruction & 0xfc00_0000) == 0x1400_0000 {
            return "b"
        }
        if (instruction & 0xfc00_0000) == 0x9400_0000 {
            return "bl"
        }
        if (instruction & 0x9f00_0000) == 0x1000_0000 {
            return "adr"
        }
        if (instruction & 0x9f00_0000) == 0x9000_0000 {
            return "adrp"
        }
        if (instruction & 0x3b00_0000) == 0x1800_0000 {
            switch (instruction >> 30) & 0x3 {
            case 0:
                return "ldr-32-literal"
            case 1:
                return "ldr-64-literal"
            case 2:
                return "ldrsw-literal"
            default:
                return "prfm-literal"
            }
        }
        if (instruction & 0x7c00_0000) == 0x3400_0000 {
            return ((instruction & 0x0100_0000) == 0) ? "cbz" : "cbnz"
        }
        if (instruction & 0x7f00_0000) == 0x3600_0000 {
            return ((instruction & 0x0100_0000) == 0) ? "tbz" : "tbnz"
        }
        if (instruction & 0xff00_0010) == 0x5400_0000 {
            return "b.cond"
        }
        if (instruction & 0x1fe0_0800) == 0x1a80_0000 {
            let invertOrNegate = ((instruction >> 30) & 0x1) == 1
            let operation = (instruction >> 10) & 0x3
            switch (invertOrNegate, operation) {
            case (false, 0):
                return "csel"
            case (false, 1):
                return "csinc"
            case (true, 0):
                return "csinv"
            case (true, 1):
                return "csneg"
            default:
                return "conditional-select"
            }
        }
        if (instruction & 0xffff_fc1f) == 0xd65f_0000 {
            return "ret"
        }
        if (instruction & 0xffff_fc1f) == 0xd61f_0000 {
            return "br"
        }
        if (instruction & 0xffff_fc1f) == 0xd63f_0000 {
            return "blr"
        }
        if (instruction & 0xffc0_0000) == 0x2800_0000 {
            return "stnp-32"
        }
        if (instruction & 0xffc0_0000) == 0x2840_0000 {
            return "ldnp-32"
        }
        if (instruction & 0xffc0_0000) == 0x2880_0000 {
            return "stp-32-post-index"
        }
        if (instruction & 0xffc0_0000) == 0x28c0_0000 {
            return "ldp-32-post-index"
        }
        if (instruction & 0xffc0_0000) == 0x2900_0000 {
            return "stp-32-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0x2940_0000 {
            return "ldp-32-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0x2980_0000 {
            return "stp-32-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0x29c0_0000 {
            return "ldp-32-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0x68c0_0000 {
            return "ldpsw-post-index"
        }
        if (instruction & 0xffc0_0000) == 0x6940_0000 {
            return "ldpsw-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0x69c0_0000 {
            return "ldpsw-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0xa800_0000 {
            return "stnp-64"
        }
        if (instruction & 0xffc0_0000) == 0xa840_0000 {
            return "ldnp-64"
        }
        if (instruction & 0xffc0_0000) == 0xa880_0000 {
            return "stp-64-post-index"
        }
        if (instruction & 0xffc0_0000) == 0xa8c0_0000 {
            return "ldp-64-post-index"
        }
        if (instruction & 0xffc0_0000) == 0xa900_0000 {
            return "stp-64-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0xa940_0000 {
            return "ldp-64-signed-offset"
        }
        if (instruction & 0xffc0_0000) == 0xa980_0000 {
            return "stp-64-pre-index"
        }
        if (instruction & 0xffc0_0000) == 0xa9c0_0000 {
            return "ldp-64-pre-index"
        }
        if (instruction & 0xfff0_0000) == 0xd530_0000 {
            return "mrs"
        }
        if (instruction & 0xfff0_0000) == 0xd510_0000 {
            return "msr"
        }
        if (instruction & 0xffff_f01f) == 0xd503_401f {
            let op2 = (instruction >> 5) & 0x7
            if op2 == 0x6 {
                return "msr-daifset"
            }
            if op2 == 0x7 {
                return "msr-daifclr"
            }
        }
        if (instruction & 0xfff8_0000) == 0xd508_0000 {
            let op1 = (instruction >> 16) & 0x7
            let crn = (instruction >> 12) & 0xf
            let crm = (instruction >> 8) & 0xf
            let op2 = (instruction >> 5) & 0x7
            if op1 == 3, crn == 7, crm == 4, op2 == 1 {
                return "dc-zva"
            }
            return "sys"
        }
        if (instruction & 0xffff_f0ff) == 0xd503_309f {
            return "dsb"
        }
        if (instruction & 0xffff_f0ff) == 0xd503_30bf {
            return "dmb"
        }
        if (instruction & 0xffff_f0ff) == 0xd503_30df {
            return "isb"
        }
        return "unknown"
    }

    private static func loadStoreSignedImmediateName(_ instruction: UInt32) -> String {
        let size = (instruction >> 30) & 0x3
        let opcode = (instruction >> 22) & 0x3
        let mode = (instruction >> 10) & 0x3
        let access: String

        switch (opcode, size) {
        case (0, 0):
            access = "strb"
        case (1, 0):
            access = "ldrb"
        case (0, 1):
            access = "strh"
        case (1, 1):
            access = "ldrh"
        case (0, 2):
            access = "str-32"
        case (1, 2):
            access = "ldr-32"
        case (2, 2):
            access = "ldrsw"
        case (0, 3):
            access = "str-64"
        case (1, 3):
            access = "ldr-64"
        case (2, 0):
            access = "ldrsb-64"
        case (3, 0):
            access = "ldrsb-32"
        case (2, 1):
            access = "ldrsh-64"
        case (3, 1):
            access = "ldrsh-32"
        default:
            access = "load-store"
        }

        switch mode {
        case 0:
            return "\(access)-unscaled-immediate"
        case 1:
            return "\(access)-post-index"
        case 3:
            return "\(access)-pre-index"
        default:
            return "\(access)-unprivileged"
        }
    }

    private static func isSIMDFPQSignedImmediateLoadStore(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x3b00_0000) == 0x3800_0000 else {
            return false
        }

        let vector = ((instruction >> 26) & 0x1) == 1
        let size = (instruction >> 30) & 0x3
        let opcode = (instruction >> 22) & 0x3
        let mode = (instruction >> 10) & 0x3

        return vector && size == 0 && (opcode == 2 || opcode == 3) && mode != 2
    }

    private static func isSIMDMoveImmediateByte(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1

        return op == 0 && cmode == 0xe && o2 == 0
    }

    private static func isSIMDAddSubtractVector(_ instruction: UInt32) -> Bool {
        (instruction & 0x9f20_fc00) == 0x0e20_8400
    }

    private static func isSIMDTableLookup(_ instruction: UInt32) -> Bool {
        (instruction & 0xbfe0_8c00) == 0x0e00_0000
    }

    private static func simdPermuteTwoVectorName(_ instruction: UInt32) -> String? {
        guard (instruction & 0xbf20_0c00) == 0x0e00_0800 else {
            return nil
        }

        let q = ((instruction >> 30) & 0x1) == 1
        let size = Int((instruction >> 22) & 0x3)
        let op = Int((instruction >> 12) & 0x7)
        let elementBits = 8 << size
        let vectorBits = q ? 128 : 64

        guard op != 0, op != 4, elementBits <= vectorBits / 2 else {
            return nil
        }

        switch op {
        case 1: return "uzp1-vector"
        case 2: return "trn1-vector"
        case 3: return "zip1-vector"
        case 5: return "uzp2-vector"
        case 6: return "trn2-vector"
        case 7: return "zip2-vector"
        default: return nil
        }
    }

    private static func fpScalarGeneralMoveName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffff_fc00 {
        case 0x1e27_0000:
            return "fmov-general-to-single"
        case 0x1e26_0000:
            return "fmov-single-to-general"
        case 0x9e67_0000:
            return "fmov-general-to-double"
        case 0x9e66_0000:
            return "fmov-double-to-general"
        case 0x9eaf_0000:
            return "fmov-general-to-vector-high-double"
        case 0x9eae_0000:
            return "fmov-vector-high-double-to-general"
        default:
            return nil
        }
    }

    private static func fpScalarRegisterMoveName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffff_fc00 {
        case 0x1e20_4000:
            return "fmov-single"
        case 0x1e60_4000:
            return "fmov-double"
        default:
            return nil
        }
    }

    private static func fpScalarImmediateMoveName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_1fe0 {
        case 0x1e20_1000:
            return "fmov-single-immediate"
        case 0x1e60_1000:
            return "fmov-double-immediate"
        default:
            return nil
        }
    }

    private static func fpIntegerToScalarFPName(_ instruction: UInt32) -> String? {
        switch instruction & 0x7fbf_fc00 {
        case 0x1e22_0000:
            return ((instruction >> 22) & 0x1) == 1 ? "scvtf-general-to-double" : "scvtf-general-to-single"
        case 0x1e23_0000:
            return ((instruction >> 22) & 0x1) == 1 ? "ucvtf-general-to-double" : "ucvtf-general-to-single"
        default:
            return nil
        }
    }

    private static func fpScalarAddName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_2800:
            return "fadd-single"
        case 0x1e60_2800:
            return "fadd-double"
        default:
            return nil
        }
    }

    private static func fpScalarSubtractName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_3800:
            return "fsub-single"
        case 0x1e60_3800:
            return "fsub-double"
        default:
            return nil
        }
    }

    private static func fpScalarMultiplyName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_fc00 {
        case 0x1e20_0800:
            return "fmul-single"
        case 0x1e60_0800:
            return "fmul-double"
        case 0x1e20_1800:
            return "fdiv-single"
        case 0x1e60_1800:
            return "fdiv-double"
        default:
            return nil
        }
    }

    private static func fpScalarConditionalSelectName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_0c00 {
        case 0x1e20_0c00:
            return "fcsel-single"
        case 0x1e60_0c00:
            return "fcsel-double"
        default:
            return nil
        }
    }

    private static func fpScalarCompareZeroName(_ instruction: UInt32) -> String? {
        switch instruction {
        case 0x1e20_2018:
            return "fcmpe-single-zero"
        case 0x1e60_2018:
            return "fcmpe-double-zero"
        default:
            return nil
        }
    }

    private static func fpScalarCompareRegisterName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffe0_fc1f {
        case 0x1e20_2010:
            return "fcmpe-single"
        case 0x1e60_2010:
            return "fcmpe-double"
        default:
            return nil
        }
    }

    private static func fpScalarConvertToSignedIntegerName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffff_fc00 {
        case 0x5ea1_b800:
            return "fcvtzs-single-to-signed"
        case 0x5ee1_b800:
            return "fcvtzs-double-to-signed"
        default:
            return nil
        }
    }

    private static func fpScalarConvertToUnsignedIntegerRegisterName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffff_fc00 {
        case 0x1e39_0000:
            return "fcvtzu-single-to-unsigned32"
        case 0x1e79_0000:
            return "fcvtzu-double-to-unsigned32"
        case 0x9e39_0000:
            return "fcvtzu-single-to-unsigned64"
        case 0x9e79_0000:
            return "fcvtzu-double-to-unsigned64"
        default:
            return nil
        }
    }

    private static func simdScalarSignedIntegerToFPName(_ instruction: UInt32) -> String? {
        switch instruction & 0xffff_fc00 {
        case 0x5e21_d800:
            return "scvtf-signed-to-single"
        case 0x5e61_d800:
            return "scvtf-signed-to-double"
        default:
            return nil
        }
    }

    private static func isSIMDMoveInvertedImmediate(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1

        guard op == 1, o2 == 0 else {
            return false
        }

        return cmode == 0x0 || cmode == 0x2 || cmode == 0x4 || cmode == 0x6 ||
            cmode == 0x8 || cmode == 0xa
    }

    private static func isSIMDMoveImmediateWord(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        return op == 0 && o2 == 0 && cmode <= 6 && cmode & 1 == 0
    }

    private static func isSIMDMoveDImmediate(_ instruction: UInt32) -> Bool {
        guard (instruction & 0x1f00_0000) == 0x0f00_0000 else {
            return false
        }

        let op = (instruction >> 29) & 0x1
        let cmode = (instruction >> 12) & 0xf
        let o2 = (instruction >> 11) & 0x1
        let imm8 = (((instruction >> 16) & 0x7) << 5) | ((instruction >> 5) & 0x1f)

        return op == 1 && cmode == 0xe && o2 == 0 && imm8 != 0
    }

    private static func simdFPQSignedImmediateLoadStoreName(_ instruction: UInt32) -> String {
        let access = ((instruction >> 22) & 0x3) == 3 ? "ldur-q" : "stur-q"
        let mode = (instruction >> 10) & 0x3

        switch mode {
        case 0:
            return "\(access)-unscaled-immediate"
        case 1:
            return "\(access)-post-index"
        case 3:
            return "\(access)-pre-index"
        default:
            return "\(access)-signed-immediate"
        }
    }

    private static func loadStoreRegisterOffsetName(_ instruction: UInt32) -> String {
        let size = (instruction >> 30) & 0x3
        let opcode = (instruction >> 22) & 0x3
        let access: String

        switch (opcode, size) {
        case (0, 0):
            access = "strb"
        case (1, 0):
            access = "ldrb"
        case (2, 0):
            access = "ldrsb-64"
        case (3, 0):
            access = "ldrsb-32"
        case (0, 1):
            access = "strh"
        case (1, 1):
            access = "ldrh"
        case (2, 1):
            access = "ldrsh-64"
        case (3, 1):
            access = "ldrsh-32"
        case (0, 2):
            access = "str-32"
        case (1, 2):
            access = "ldr-32"
        case (2, 2):
            access = "ldrsw"
        case (0, 3):
            access = "str-64"
        case (1, 3):
            access = "ldr-64"
        case (2, 3):
            access = "prfm"
        default:
            access = "load-store"
        }

        return "\(access)-register-offset"
    }

    private static func loadStoreExclusiveName(_ instruction: UInt32) -> String {
        let size = (instruction >> 30) & 0x3
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let ordered = ((instruction >> 15) & 0x1) == 1
        let suffix: String

        switch size {
        case 0:
            suffix = "byte"
        case 1:
            suffix = "halfword"
        case 2:
            suffix = "32"
        default:
            suffix = "64"
        }

        switch (isLoad, ordered) {
        case (true, false):
            return "ldxr-\(suffix)"
        case (true, true):
            return "ldaxr-\(suffix)"
        case (false, false):
            return "stxr-\(suffix)"
        case (false, true):
            return "stlxr-\(suffix)"
        }
    }

    private static func loadStoreExclusivePairName(_ instruction: UInt32) -> String {
        let size = (instruction >> 30) & 0x3
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let ordered = ((instruction >> 15) & 0x1) == 1
        let suffix = size == 2 ? "32" : "64"

        switch (isLoad, ordered) {
        case (true, false):
            return "ldxp-\(suffix)"
        case (true, true):
            return "ldaxp-\(suffix)"
        case (false, false):
            return "stxp-\(suffix)"
        case (false, true):
            return "stlxp-\(suffix)"
        }
    }

    private static func loadAcquireStoreReleaseName(_ instruction: UInt32) -> String {
        let size = (instruction >> 30) & 0x3
        let isLoad = ((instruction >> 22) & 0x1) == 1
        let suffix: String

        switch size {
        case 0:
            suffix = "byte"
        case 1:
            suffix = "halfword"
        case 2:
            suffix = "32"
        default:
            suffix = "64"
        }

        return isLoad ? "ldar-\(suffix)" : "stlr-\(suffix)"
    }
}
