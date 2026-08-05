BEGIN {
    allowed[36] = 1  # FP scalar register move
    allowed[37] = 1  # SIMD scalar signed integer to FP
    allowed[39] = 1  # SSHLL/USHLL
    allowed[40] = 1  # Integer vector add/sub and widening variants
    allowed[42] = 1  # MOVI zero
    allowed[43] = 1  # MOVI byte
    allowed[44] = 1  # MVNI
    allowed[45] = 1  # MOVI D
    allowed[46] = 1  # TBL/TBX
    allowed[47] = 1  # ZIP/UZP/TRN
    allowed[53] = 1  # FP scalar arithmetic
    allowed[57] = 1  # Integer compare
    allowed[58] = 1  # CNT
    allowed[59] = 1  # Bitwise vector operations
    allowed[60] = 1  # FP scalar immediate move
    allowed[61] = 1  # UMAXP
    allowed[62] = 1  # MOVI word
    allowed[64] = 1  # FP scalar precision conversion
    allowed[75] = 1  # DUP vector element
    allowed[76] = 1  # SIMD scalar immediate shift
    allowed[77] = 1  # ADDV
    allowed[78] = 1  # FP scalar fused multiply-add
    allowed[79] = 1  # FP scalar unary
    allowed[80] = 1  # SIMD scalar FP absolute difference
    allowed[81] = 1  # SIMD FP immediate move
    allowed[82] = 1  # FP scalar negated multiply
    allowed[83] = 1  # SADDLV/UADDLV
    allowed[85] = 1  # FP scalar round to integral
    allowed[86] = 1  # NEG
    allowed[87] = 1  # SHL/SLI
    allowed[88] = 1  # Multiply and widening multiply families
    allowed[89] = 1  # Narrowing families
    allowed[90] = 1  # NOT
    allowed[91] = 1  # Saturating add/subtract
    allowed[92] = 1  # Immediate right-shift families
    allowed[93] = 1  # INS vector element
    allowed[94] = 1  # USHL
    allowed[95] = 1  # FP scalar min/max
    allowed[96] = 1  # Integer min/max
    allowed[97] = 1  # REV
    allowed[98] = 1  # EXT
    allowed[99] = 1  # FP narrow/widen conversion
    allowed[100] = 1 # FP vector compare
    allowed[101] = 1 # Pairwise integer add
    allowed[102] = 1 # FP reciprocal estimate
    allowed[103] = 1 # FP reciprocal step
    allowed[104] = 1 # FP vector convert to integer
}

$3 ~ /^kind=/ {
    split($3, kind_field, "=")
    kind = kind_field[2] + 0
    opcode = tolower($2)
    if (allowed[kind] && opcode ~ /^[0-9a-f]{8}$/ && !seen[opcode]) {
        seen[opcode] = 1
        opcodes[++count] = opcode
        kinds[count] = kind
    }
}

END {
    if (mode == "assembly") {
        print ".text"
        for (i = 1; i <= count; i++) {
            symbol = sprintf("_avz_host_simd_case_%05d", i)
            print ".p2align 2"
            print ".globl " symbol
            print symbol ":"
            print "    sub sp, sp, #80"
            print "    stp d8, d9, [sp, #0]"
            print "    stp d10, d11, [sp, #16]"
            print "    stp d12, d13, [sp, #32]"
            print "    stp d14, d15, [sp, #48]"
            print "    mrs x9, fpsr"
            print "    str x9, [sp, #64]"
            print "    msr fpsr, xzr"
            for (reg = 0; reg < 32; reg++) {
                print "    ldr q" reg ", [x0, #" reg * 16 "]"
            }
            print "    .inst 0x" opcodes[i]
            for (reg = 0; reg < 32; reg++) {
                print "    str q" reg ", [x1, #" reg * 16 "]"
            }
            print "    mrs x10, fpsr"
            print "    str x10, [x2]"
            print "    ldr x9, [sp, #64]"
            print "    msr fpsr, x9"
            print "    ldp d8, d9, [sp, #0]"
            print "    ldp d10, d11, [sp, #16]"
            print "    ldp d12, d13, [sp, #32]"
            print "    ldp d14, d15, [sp, #48]"
            print "    add sp, sp, #80"
            print "    ret"
        }
    } else if (mode == "include") {
        for (i = 1; i <= count; i++) {
            printf("extern void avz_host_simd_case_%05d(\n", i)
            print "    const AVZNativeVectorRegister *input,"
            print "    AVZNativeVectorRegister *output,"
            print "    uint64_t *fpsr);"
        }
        print ""
        print "static const SIMDCase simd_cases[] = {"
        for (i = 1; i <= count; i++) {
            printf("    {UINT32_C(0x%s), %u, avz_host_simd_case_%05d},\n", opcodes[i], kinds[i], i)
        }
        print "};"
    } else {
        print "generate-simd-differential.awk: set -v mode=assembly or -v mode=include" > "/dev/stderr"
        exit 2
    }
}
