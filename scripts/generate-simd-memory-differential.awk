BEGIN {
    allowed[65] = 1  # SIMD load/store single structure lane
    allowed[74] = 1  # SIMD load/store multiple structures
}

$3 ~ /^kind=/ {
    delete fields
    for (field_index = 3; field_index <= NF; field_index++) {
        split($field_index, pair, "=")
        fields[pair[1]] = pair[2] + 0
    }

    kind = fields["kind"]
    opcode = tolower($2)
    rn = fields["rn"]
    rm = fields["rm"]
    flags = fields["flags"]

    # A register post-index using the base register as its offset is
    # constrained-unpredictable. Do not execute such encodings on the host.
    overlaps_writeback = bit_is_set(flags, 16) && rn == rm
    if (allowed[kind] && !overlaps_writeback &&
        opcode ~ /^[0-9a-f]{8}$/ && !seen[opcode]) {
        seen[opcode] = 1
        opcodes[++count] = opcode
        kinds[count] = kind
        base_registers[count] = rn
        offset_registers[count] = rm
        instruction_flags[count] = flags
    }
}

function scratch_register(excluded_a, excluded_b, candidate) {
    for (candidate = 9; candidate <= 17; candidate++) {
        if (candidate != excluded_a && candidate != excluded_b) {
            return candidate
        }
    }
    return 18
}

function bit_is_set(value, bit) {
    return int(value / bit) % 2
}

END {
    if (mode == "assembly") {
        print ".text"
        for (i = 1; i <= count; i++) {
            symbol = sprintf("_avz_host_simd_memory_case_%05d", i)
            rn = base_registers[i]
            rm = offset_registers[i]
            flags = instruction_flags[i]
            scratch = scratch_register(rn, rm)
            scratch2 = scratch_register(rn, scratch)

            print ".p2align 2"
            print ".globl " symbol
            print symbol ":"
            print "    sub sp, sp, #192"
            print "    stp d8, d9, [sp, #0]"
            print "    stp d10, d11, [sp, #16]"
            print "    stp d12, d13, [sp, #32]"
            print "    stp d14, d15, [sp, #48]"
            print "    stp x19, x20, [sp, #64]"
            print "    stp x21, x22, [sp, #80]"
            print "    stp x23, x24, [sp, #96]"
            print "    stp x25, x26, [sp, #112]"
            print "    stp x27, x28, [sp, #128]"
            print "    stp x29, x30, [sp, #144]"
            print "    str x1, [sp, #160]"
            print "    str x2, [sp, #168]"
            print "    str x3, [sp, #176]"
            print "    str x4, [sp, #184]"
            for (reg = 0; reg < 32; reg++) {
                print "    ldr q" reg ", [x0, #" reg * 16 "]"
            }

            if (bit_is_set(flags, 16)) {
                print "    ldr x" rm ", [sp, #184]"
            }
            if (rn == 31) {
                print "    ldr x" scratch2 ", [sp, #160]"
                print "    mov x" scratch ", sp"
                print "    mov sp, x" scratch2
                print "    .inst 0x" opcodes[i]
                print "    mov x" scratch2 ", sp"
                print "    mov sp, x" scratch
                print "    ldr x" scratch ", [sp, #176]"
                print "    str x" scratch2 ", [x" scratch "]"
            } else {
                print "    ldr x" rn ", [sp, #160]"
                print "    .inst 0x" opcodes[i]
                print "    ldr x" scratch ", [sp, #176]"
                print "    str x" rn ", [x" scratch "]"
            }

            print "    ldr x" scratch ", [sp, #168]"
            for (reg = 0; reg < 32; reg++) {
                print "    str q" reg ", [x" scratch ", #" reg * 16 "]"
            }
            print "    ldp x29, x30, [sp, #144]"
            print "    ldp x27, x28, [sp, #128]"
            print "    ldp x25, x26, [sp, #112]"
            print "    ldp x23, x24, [sp, #96]"
            print "    ldp x21, x22, [sp, #80]"
            print "    ldp x19, x20, [sp, #64]"
            print "    ldp d14, d15, [sp, #48]"
            print "    ldp d12, d13, [sp, #32]"
            print "    ldp d10, d11, [sp, #16]"
            print "    ldp d8, d9, [sp, #0]"
            print "    add sp, sp, #192"
            print "    ret"
        }
    } else if (mode == "include") {
        for (i = 1; i <= count; i++) {
            printf("extern void avz_host_simd_memory_case_%05d(\n", i)
            print "    const AVZNativeVectorRegister *input,"
            print "    uint8_t *memory_base,"
            print "    AVZNativeVectorRegister *output,"
            print "    uint64_t *base_after,"
            print "    uint64_t post_index);"
        }
        print ""
        print "static const SIMDMemoryCase simd_memory_cases[] = {"
        for (i = 1; i <= count; i++) {
            printf("    {UINT32_C(0x%s), %u, avz_host_simd_memory_case_%05d},\n",
                opcodes[i], kinds[i], i)
        }
        print "};"
    } else {
        print "generate-simd-memory-differential.awk: set -v mode=assembly or -v mode=include" > "/dev/stderr"
        exit 2
    }
}
