// Integer vector operations on caller-saved v0-v2. Reading destination first
// preserves BSL/BIT/BIF masks and every guest source/destination alias.
.macro SIMD_LOGIC name, instruction, width
HANDLER simd_\name\width
    ldrh w9, [x20, #O_DST]
    add x9, x19, x9
    ldrh w10, [x20, #O_SRC]
    add x10, x19, x10
    ldrh w11, [x20, #O_AUX]
    add x11, x19, x11
.if \width == 128
    ldr q0, [x9]
    ldr q1, [x10]
    ldr q2, [x11]
    \instruction v0.16b, v1.16b, v2.16b
.else
    ldr d0, [x9]
    ldr d1, [x10]
    ldr d2, [x11]
    \instruction v0.8b, v1.8b, v2.8b
.endif
    str q0, [x9]
    NEXT
.endm
.macro SIMD_LOGIC_WIDTHS name, instruction
    SIMD_LOGIC \name, \instruction, 64
    SIMD_LOGIC \name, \instruction, 128
.endm
SIMD_LOGIC_WIDTHS orr, orr
SIMD_LOGIC_WIDTHS eor, eor
SIMD_LOGIC_WIDTHS bsl, bsl
SIMD_LOGIC_WIDTHS bit, bit
SIMD_LOGIC_WIDTHS bif, bif
SIMD_LOGIC_WIDTHS and, and
SIMD_LOGIC_WIDTHS bic, bic
SIMD_LOGIC_WIDTHS orn, orn
.macro SIMD_NOT width
HANDLER simd_not\width
    ldrh w9, [x20, #O_DST]
    add x9, x19, x9
    ldrh w10, [x20, #O_SRC]
    add x10, x19, x10
.if \width == 128
    ldr q0, [x10]
    mvn v0.16b, v0.16b
.else
    ldr d0, [x10]
    mvn v0.8b, v0.8b
.endif
    str q0, [x9]
    NEXT
.endm
SIMD_NOT 64
SIMD_NOT 128
