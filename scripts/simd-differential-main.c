#include "ARM64VizNative.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*HostSIMDCase)(
    const AVZNativeVectorRegister *input,
    AVZNativeVectorRegister *output,
    uint64_t *fpsr
);

typedef struct {
    uint32_t opcode;
    uint16_t expected_kind;
    HostSIMDCase execute;
} SIMDCase;

#include "simd-differential-cases.inc"

static const uint64_t test_patterns[] = {
    UINT64_C(0x0000000000000000),
    UINT64_C(0xffffffffffffffff),
    UINT64_C(0x8080808080808080),
    UINT64_C(0x7f7f7f7f7f7f7f7f),
    UINT64_C(0x8000800080008000),
    UINT64_C(0x7fff7fff7fff7fff),
    UINT64_C(0x8000000080000000),
    UINT64_C(0x7fffffff7fffffff),
    UINT64_C(0x0123456789abcdef),
    UINT64_C(0xfedcba9876543210),
    UINT64_C(0x00ff01fe02fd03fc),
    UINT64_C(0xff00fe01fd02fc03),
};

static uint64_t rotate_left(uint64_t value, unsigned amount) {
    amount &= 63u;
    if (amount == 0u) {
        return value;
    }
    return (value << amount) | (value >> (64u - amount));
}

static void initialize_vectors(AVZNativeVectorRegister *vectors, unsigned seed) {
    const size_t pattern_count = sizeof(test_patterns) / sizeof(test_patterns[0]);
    for (unsigned reg = 0; reg < 32; reg++) {
        uint64_t low = test_patterns[(reg + seed) % pattern_count];
        uint64_t high = test_patterns[(reg * 3u + seed + 5u) % pattern_count];
        vectors[reg].low = rotate_left(low, reg + seed * 7u);
        vectors[reg].high = rotate_left(high, reg * 5u + seed * 11u);
    }
}

static int kind_uses_floating_point(uint16_t kind) {
    switch (kind) {
    case AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE:
    case AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP:
    case AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC:
    case AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE:
    case AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION:
    case AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD:
    case AVZ_NATIVE_OP_FP_SCALAR_UNARY:
    case AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE:
    case AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE:
    case AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY:
    case AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL:
    case AVZ_NATIVE_OP_FP_SCALAR_MINMAX:
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_NARROW_WIDEN:
    case AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR:
    case AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE:
    case AVZ_NATIVE_OP_FP_RECIPROCAL_STEP:
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER:
        return 1;
    default:
        return 0;
    }
}

static void initialize_finite_fp_vectors(
    AVZNativeVectorRegister *vectors,
    unsigned seed
) {
    static const uint32_t finite_float_bits[] = {
        UINT32_C(0x00000000),
        UINT32_C(0x3e800000),
        UINT32_C(0xbf000000),
        UINT32_C(0x3fc00000),
        UINT32_C(0xc0000000),
        UINT32_C(0x40500000),
        UINT32_C(0xc0900000),
        UINT32_C(0x41200000)
    };
    const size_t value_count =
        sizeof(finite_float_bits) / sizeof(finite_float_bits[0]);
    for (unsigned reg = 0; reg < 32; reg++) {
        uint32_t lane0 = finite_float_bits[(reg + seed) % value_count];
        uint32_t lane1 = finite_float_bits[(reg * 3u + seed + 1u) % value_count];
        uint32_t lane2 = finite_float_bits[(reg * 5u + seed + 2u) % value_count];
        uint32_t lane3 = finite_float_bits[(reg * 7u + seed + 3u) % value_count];
        vectors[reg].low = (uint64_t)lane0 | ((uint64_t)lane1 << 32);
        vectors[reg].high = (uint64_t)lane2 | ((uint64_t)lane3 << 32);
    }
}

static int run_interpreter(
    const SIMDCase *test_case,
    const AVZNativeVectorRegister *input,
    AVZNativeVectorRegister *output,
    uint64_t *fpsr_output,
    AVZNativeInstruction *decoded_output
) {
    AVZNativeInstruction decoded;
    if (!avz_native_decode_instruction(test_case->opcode, &decoded)) {
        fprintf(stderr, "decoder rejected audited opcode %08" PRIx32 "\n", test_case->opcode);
        return 0;
    }
    uint64_t x[31] = {0};
    uint64_t vector_low[32];
    uint64_t vector_high[32];
    for (unsigned reg = 0; reg < 32; reg++) {
        vector_low[reg] = input[reg].low;
        vector_high[reg] = input[reg].high;
    }

    uint64_t sp = UINT64_C(0x000000007fff0000);
    uint64_t pc = UINT64_C(0x1000);
    uint64_t pstate = 0;
    uint64_t fpcr = 0;
    uint64_t fpsr = 0;
    uint8_t halted = 0;
    AVZNativeBlockResult result = avz_native_run_threaded_decoded_block_full_registers(
        &decoded,
        1,
        pc,
        1,
        x,
        vector_low,
        vector_high,
        &sp,
        &pc,
        &pstate,
        &fpcr,
        &fpsr,
        &halted,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );
    if (result.steps != 1 ||
        (result.status != AVZ_NATIVE_STATUS_OUTSIDE_BLOCK &&
         result.status != AVZ_NATIVE_STATUS_MAX_STEPS)) {
        fprintf(
            stderr,
            "interpreter failed %08" PRIx32 ": steps=%" PRIu64 " status=%u\n",
            test_case->opcode,
            result.steps,
            result.status
        );
        return 0;
    }

    for (unsigned reg = 0; reg < 32; reg++) {
        output[reg].low = vector_low[reg];
        output[reg].high = vector_high[reg];
    }
    *fpsr_output = fpsr;
    *decoded_output = decoded;
    return 1;
}

int main(void) {
    const size_t case_count = sizeof(simd_cases) / sizeof(simd_cases[0]);
    unsigned mismatch_count = 0;
    unsigned execution_count = 0;

    for (size_t case_index = 0; case_index < case_count; case_index++) {
        const SIMDCase *test_case = &simd_cases[case_index];
        for (unsigned seed = 0; seed < 16; seed++) {
            int case_mismatched = 0;
            AVZNativeVectorRegister input[32];
            AVZNativeVectorRegister host_output[32];
            AVZNativeVectorRegister interpreter_output[32];
            uint64_t host_fpsr = 0;
            uint64_t interpreter_fpsr = 0;
            AVZNativeInstruction decoded;

            if (kind_uses_floating_point(test_case->expected_kind)) {
                initialize_finite_fp_vectors(input, seed);
            } else {
                initialize_vectors(input, seed);
            }
            memcpy(host_output, input, sizeof(host_output));
            memcpy(interpreter_output, input, sizeof(interpreter_output));
            test_case->execute(input, host_output, &host_fpsr);
            if (!run_interpreter(
                    test_case,
                    input,
                    interpreter_output,
                    &interpreter_fpsr,
                    &decoded)) {
                return 2;
            }
            execution_count++;

            for (unsigned reg = 0; reg < 32; reg++) {
                if (host_output[reg].low == interpreter_output[reg].low &&
                    host_output[reg].high == interpreter_output[reg].high) {
                    continue;
                }
                fprintf(
                    stderr,
                    "mismatch opcode=%08" PRIx32 " kind=%u seed=%u v%u\n"
                    "  decode rd=%u rn=%u rm=%u bits=%u flags=%u shift=%u condition=%u\n"
                    "  host        %016" PRIx64 " %016" PRIx64 "\n"
                    "  interpreter %016" PRIx64 " %016" PRIx64 "\n",
                    test_case->opcode,
                    decoded.kind,
                    seed,
                    reg,
                    decoded.rd,
                    decoded.rn,
                    decoded.rm,
                    decoded.bits,
                    decoded.flags,
                    decoded.shift_amount,
                    decoded.condition,
                    host_output[reg].high,
                    host_output[reg].low,
                    interpreter_output[reg].high,
                    interpreter_output[reg].low
                );
                mismatch_count++;
                case_mismatched = 1;
                break;
            }
            if ((host_fpsr & (UINT64_C(1) << 27)) !=
                (interpreter_fpsr & (UINT64_C(1) << 27))) {
                fprintf(
                    stderr,
                    "FPSR.QC mismatch opcode=%08" PRIx32 " kind=%u seed=%u host=%016" PRIx64
                    " interpreter=%016" PRIx64 "\n",
                    test_case->opcode,
                    decoded.kind,
                    seed,
                    host_fpsr,
                    interpreter_fpsr
                );
                mismatch_count++;
                case_mismatched = 1;
            }
            if (mismatch_count >= 200) {
                fprintf(stderr, "stopping after 200 mismatches\n");
                return 1;
            }
            if (case_mismatched) {
                break;
            }
        }
    }

    printf(
        "compared %u executions across %zu unique rendering opcodes; mismatches=%u\n",
        execution_count,
        case_count,
        mismatch_count
    );
    return mismatch_count == 0 ? 0 : 1;
}
