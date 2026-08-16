#include "ARM64VizNative.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif

static uint64_t mask_for_bits(unsigned bits) {
    if (bits == 0u) {
        return 0;
    }
    return bits >= 64u ? UINT64_MAX : ((UINT64_C(1) << bits) - 1u);
}

static uint64_t sign_bit_for_bits(unsigned bits) {
    if (bits == 0u) {
        return 0;
    }
    return UINT64_C(1) << ((bits >= 64u ? 64u : bits) - 1u);
}

static int64_t sign_extend_u64(uint64_t value, unsigned bits) {
    if (bits == 0u) {
        return 0;
    }
    if (bits >= 64u) {
        return (int64_t)value;
    }
    uint64_t sign_bit = sign_bit_for_bits(bits);
    uint64_t mask = mask_for_bits(bits);
    uint64_t extended = (value & mask) ^ sign_bit;
    return (int64_t)(extended - sign_bit);
}

static int64_t decode_scaled_signed_immediate(
    uint64_t encoded,
    unsigned bits,
    int64_t scale
) {
    return sign_extend_u64(encoded, bits) * scale;
}

static uint64_t add_signed_offset(uint64_t base, int64_t offset) {
    return base + (uint64_t)offset;
}

static uint64_t read_register(const AVZNativeCPU *cpu, unsigned index) {
    return index == 31 ? 0 : cpu->x[index];
}

static uint8_t popcount_u8(uint8_t value) {
    value = (uint8_t)(value - ((value >> 1) & 0x55u));
    value = (uint8_t)((value & 0x33u) + ((value >> 2) & 0x33u));
    return (uint8_t)((value + (value >> 4)) & 0x0fu);
}

static uint64_t read_base_register(const AVZNativeCPU *cpu, unsigned index) {
    return index == 31 ? cpu->sp : cpu->x[index];
}

static void write_register(AVZNativeCPU *cpu, unsigned index, uint64_t value) {
    if (index != 31) {
        cpu->x[index] = value;
    }
}

static void write_base_register(AVZNativeCPU *cpu, unsigned index, uint64_t value) {
    if (index == 31) {
        cpu->sp = value;
    } else {
        cpu->x[index] = value;
    }
}

static void clear_exclusive_reservation(AVZNativeCPU *cpu) {
    cpu->exclusive_address = 0;
    cpu->exclusive_generation = 0;
    cpu->exclusive_size = 0;
    cpu->exclusive_valid = 0;
}

static uint64_t read_vector_element(const AVZNativeCPU *cpu, unsigned vector, unsigned lane, unsigned element_bits) {
    unsigned bit_offset = lane * element_bits;
    uint64_t lane_mask = mask_for_bits(element_bits);
    if (bit_offset < 64) {
        return (cpu->v[vector].low >> bit_offset) & lane_mask;
    }
    return (cpu->v[vector].high >> (bit_offset - 64)) & lane_mask;
}

static void write_vector_element(
    AVZNativeVectorRegister *vector,
    unsigned lane,
    unsigned element_bits,
    uint64_t value
) {
    unsigned bit_offset = lane * element_bits;
    uint64_t lane_mask = mask_for_bits(element_bits);
    uint64_t masked_value = value & lane_mask;

    if (bit_offset < 64) {
        uint64_t shifted_mask = lane_mask << bit_offset;
        vector->low = (vector->low & ~shifted_mask) | (masked_value << bit_offset);
    } else {
        unsigned high_offset = bit_offset - 64;
        uint64_t shifted_mask = lane_mask << high_offset;
        vector->high = (vector->high & ~shifted_mask) | (masked_value << high_offset);
    }
}

#if defined(__aarch64__) && defined(__ARM_NEON)
static int pack_four_interleaved_vectors_neon(
    const AVZNativeVectorRegister *vectors,
    unsigned vector_bytes,
    unsigned element_bytes,
    uint8_t *destination
) {
    if (vector_bytes == 8) {
        switch (element_bytes) {
        case 1: {
            uint8x8x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1_u8((const uint8_t *)&vectors[index]);
            }
            vst4_u8(destination, value);
            return 1;
        }
        case 2: {
            uint16x4x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1_u16((const uint16_t *)&vectors[index]);
            }
            vst4_u16((uint16_t *)destination, value);
            return 1;
        }
        case 4: {
            uint32x2x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1_u32((const uint32_t *)&vectors[index]);
            }
            vst4_u32((uint32_t *)destination, value);
            return 1;
        }
        case 8: {
            uint64x1x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1_u64((const uint64_t *)&vectors[index]);
            }
            vst4_u64((uint64_t *)destination, value);
            return 1;
        }
        default:
            return 0;
        }
    }

    if (vector_bytes == 16) {
        switch (element_bytes) {
        case 1: {
            uint8x16x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1q_u8((const uint8_t *)&vectors[index]);
            }
            vst4q_u8(destination, value);
            return 1;
        }
        case 2: {
            uint16x8x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1q_u16((const uint16_t *)&vectors[index]);
            }
            vst4q_u16((uint16_t *)destination, value);
            return 1;
        }
        case 4: {
            uint32x4x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1q_u32((const uint32_t *)&vectors[index]);
            }
            vst4q_u32((uint32_t *)destination, value);
            return 1;
        }
        case 8: {
            uint64x2x4_t value;
            for (unsigned index = 0; index < 4; index++) {
                value.val[index] = vld1q_u64((const uint64_t *)&vectors[index]);
            }
            vst4q_u64((uint64_t *)destination, value);
            return 1;
        }
        default:
            return 0;
        }
    }

    return 0;
}

static int unpack_four_interleaved_vectors_neon(
    const uint8_t *source,
    unsigned vector_bytes,
    unsigned element_bytes,
    AVZNativeVectorRegister *vectors
) {
    if (vector_bytes == 8) {
        switch (element_bytes) {
        case 1: {
            uint8x8x4_t value = vld4_u8(source);
            for (unsigned index = 0; index < 4; index++) {
                vst1_u8((uint8_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 2: {
            uint16x4x4_t value = vld4_u16((const uint16_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1_u16((uint16_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 4: {
            uint32x2x4_t value = vld4_u32((const uint32_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1_u32((uint32_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 8: {
            uint64x1x4_t value = vld4_u64((const uint64_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1_u64((uint64_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        default:
            return 0;
        }
    }

    if (vector_bytes == 16) {
        switch (element_bytes) {
        case 1: {
            uint8x16x4_t value = vld4q_u8(source);
            for (unsigned index = 0; index < 4; index++) {
                vst1q_u8((uint8_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 2: {
            uint16x8x4_t value = vld4q_u16((const uint16_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1q_u16((uint16_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 4: {
            uint32x4x4_t value = vld4q_u32((const uint32_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1q_u32((uint32_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        case 8: {
            uint64x2x4_t value = vld4q_u64((const uint64_t *)source);
            for (unsigned index = 0; index < 4; index++) {
                vst1q_u64((uint64_t *)&vectors[index], value.val[index]);
            }
            return 1;
        }
        default:
            return 0;
        }
    }

    return 0;
}
#endif

static int pack_interleaved_vectors(
    const AVZNativeVectorRegister *vectors,
    unsigned register_count,
    unsigned lane_count,
    unsigned element_bytes,
    uint8_t *destination
) {
    if (vectors == NULL || destination == NULL || register_count == 0 ||
        register_count > 4 || lane_count == 0 ||
        (element_bytes != 1 && element_bytes != 2 &&
         element_bytes != 4 && element_bytes != 8)) {
        return 0;
    }

#if defined(__aarch64__) && defined(__ARM_NEON)
    if (register_count == 4 &&
        pack_four_interleaved_vectors_neon(
            vectors,
            lane_count * element_bytes,
            element_bytes,
            destination
        )) {
        return 1;
    }
#endif

    for (unsigned lane = 0; lane < lane_count; lane++) {
        for (unsigned structure = 0; structure < register_count; structure++) {
            const uint8_t *source =
                (const uint8_t *)&vectors[structure] + lane * element_bytes;
            uint8_t *output = destination +
                ((size_t)lane * register_count + structure) * element_bytes;
            switch (element_bytes) {
            case 1:
                output[0] = source[0];
                break;
            case 2:
                memcpy(output, source, 2);
                break;
            case 4:
                memcpy(output, source, 4);
                break;
            case 8:
                memcpy(output, source, 8);
                break;
            default:
                return 0;
            }
        }
    }
    return 1;
}

static int unpack_interleaved_vectors(
    const uint8_t *source,
    unsigned register_count,
    unsigned lane_count,
    unsigned element_bytes,
    AVZNativeVectorRegister *vectors
) {
    if (source == NULL || vectors == NULL || register_count == 0 ||
        register_count > 4 || lane_count == 0 ||
        (element_bytes != 1 && element_bytes != 2 &&
         element_bytes != 4 && element_bytes != 8)) {
        return 0;
    }

#if defined(__aarch64__) && defined(__ARM_NEON)
    if (register_count == 4 &&
        unpack_four_interleaved_vectors_neon(
            source,
            lane_count * element_bytes,
            element_bytes,
            vectors
        )) {
        return 1;
    }
#endif

    for (unsigned lane = 0; lane < lane_count; lane++) {
        for (unsigned structure = 0; structure < register_count; structure++) {
            const uint8_t *input = source +
                ((size_t)lane * register_count + structure) * element_bytes;
            uint8_t *destination =
                (uint8_t *)&vectors[structure] + lane * element_bytes;
            switch (element_bytes) {
            case 1:
                destination[0] = input[0];
                break;
            case 2:
                memcpy(destination, input, 2);
                break;
            case 4:
                memcpy(destination, input, 4);
                break;
            case 8:
                memcpy(destination, input, 8);
                break;
            default:
                return 0;
            }
        }
    }
    return 1;
}

#if defined(__aarch64__) && defined(__ARM_NEON)
static int execute_simd_multiply_long_neon(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    unsigned element_bits = instruction->bits;
    int same_width = (instruction->flags & 4u) != 0u;
    int by_element = (instruction->flags & 64u) != 0u;

    if (same_width) {
        unsigned vector_bits = (instruction->flags & 8u) != 0u ? 128u : 64u;
        unsigned operation = (instruction->flags >> 4) & 3u;
        AVZNativeVectorRegister result = {0, 0};

        switch (element_bits) {
        case 8: {
            uint8x16_t lhs = vld1q_u8((const uint8_t *)&cpu->v[instruction->rn]);
            uint8x16_t rhs = by_element
                ? vdupq_n_u8((uint8_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 8
                ))
                : vld1q_u8((const uint8_t *)&cpu->v[instruction->rm]);
            uint8x16_t product = vmulq_u8(lhs, rhs);
            if (operation != 0u) {
                uint8x16_t accumulator = vld1q_u8(
                    (const uint8_t *)&cpu->v[instruction->rd]
                );
                product = operation == 1u
                    ? vaddq_u8(accumulator, product)
                    : vsubq_u8(accumulator, product);
            }
            vst1q_u8((uint8_t *)&result, product);
            break;
        }
        case 16: {
            uint16x8_t lhs = vld1q_u16((const uint16_t *)&cpu->v[instruction->rn]);
            uint16x8_t rhs = by_element
                ? vdupq_n_u16((uint16_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 16
                ))
                : vld1q_u16((const uint16_t *)&cpu->v[instruction->rm]);
            uint16x8_t product = vmulq_u16(lhs, rhs);
            if (operation != 0u) {
                uint16x8_t accumulator = vld1q_u16(
                    (const uint16_t *)&cpu->v[instruction->rd]
                );
                product = operation == 1u
                    ? vaddq_u16(accumulator, product)
                    : vsubq_u16(accumulator, product);
            }
            vst1q_u16((uint16_t *)&result, product);
            break;
        }
        case 32: {
            uint32x4_t lhs = vld1q_u32((const uint32_t *)&cpu->v[instruction->rn]);
            uint32x4_t rhs = by_element
                ? vdupq_n_u32((uint32_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 32
                ))
                : vld1q_u32((const uint32_t *)&cpu->v[instruction->rm]);
            uint32x4_t product = vmulq_u32(lhs, rhs);
            if (operation != 0u) {
                uint32x4_t accumulator = vld1q_u32(
                    (const uint32_t *)&cpu->v[instruction->rd]
                );
                product = operation == 1u
                    ? vaddq_u32(accumulator, product)
                    : vsubq_u32(accumulator, product);
            }
            vst1q_u32((uint32_t *)&result, product);
            break;
        }
        default:
            return 0;
        }

        if (vector_bits == 64u) {
            result.high = 0;
        }
        cpu->v[instruction->rd] = result;
        return 1;
    }

    unsigned source_lane_base =
        (instruction->flags & 1u) != 0u ? 64u / element_bits : 0u;
    int is_unsigned = (instruction->flags & 2u) != 0u;
    int accumulates = (instruction->flags & 8u) != 0u;
    int subtracts = (instruction->flags & 16u) != 0u;

    switch (element_bits) {
    case 8: {
        uint8x16_t lhs_full = vld1q_u8(
            (const uint8_t *)&cpu->v[instruction->rn]
        );
        uint8x8_t lhs = source_lane_base != 0u
            ? vget_high_u8(lhs_full)
            : vget_low_u8(lhs_full);
        uint16x8_t product;
        if (is_unsigned) {
            uint8x8_t rhs = by_element
                ? vdup_n_u8((uint8_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 8
                ))
                : (source_lane_base != 0u
                    ? vget_high_u8(vld1q_u8((const uint8_t *)&cpu->v[instruction->rm]))
                    : vget_low_u8(vld1q_u8((const uint8_t *)&cpu->v[instruction->rm])));
            product = vmull_u8(lhs, rhs);
        } else {
            int8x8_t rhs = by_element
                ? vdup_n_s8((int8_t)sign_extend_u64(
                    read_vector_element(
                        cpu, instruction->rm, instruction->condition, 8
                    ),
                    8
                ))
                : (source_lane_base != 0u
                    ? vget_high_s8(vld1q_s8((const int8_t *)&cpu->v[instruction->rm]))
                    : vget_low_s8(vld1q_s8((const int8_t *)&cpu->v[instruction->rm])));
            product = vreinterpretq_u16_s16(vmull_s8(vreinterpret_s8_u8(lhs), rhs));
        }
        if (accumulates) {
            uint16x8_t accumulator = vld1q_u16(
                (const uint16_t *)&cpu->v[instruction->rd]
            );
            product = subtracts
                ? vsubq_u16(accumulator, product)
                : vaddq_u16(accumulator, product);
        }
        vst1q_u16((uint16_t *)&cpu->v[instruction->rd], product);
        return 1;
    }
    case 16: {
        uint16x8_t lhs_full = vld1q_u16(
            (const uint16_t *)&cpu->v[instruction->rn]
        );
        uint16x4_t lhs = source_lane_base != 0u
            ? vget_high_u16(lhs_full)
            : vget_low_u16(lhs_full);
        uint32x4_t product;
        if (is_unsigned) {
            uint16x4_t rhs = by_element
                ? vdup_n_u16((uint16_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 16
                ))
                : (source_lane_base != 0u
                    ? vget_high_u16(vld1q_u16((const uint16_t *)&cpu->v[instruction->rm]))
                    : vget_low_u16(vld1q_u16((const uint16_t *)&cpu->v[instruction->rm])));
            product = vmull_u16(lhs, rhs);
        } else {
            int16x4_t rhs = by_element
                ? vdup_n_s16((int16_t)sign_extend_u64(
                    read_vector_element(
                        cpu, instruction->rm, instruction->condition, 16
                    ),
                    16
                ))
                : (source_lane_base != 0u
                    ? vget_high_s16(vld1q_s16((const int16_t *)&cpu->v[instruction->rm]))
                    : vget_low_s16(vld1q_s16((const int16_t *)&cpu->v[instruction->rm])));
            product = vreinterpretq_u32_s32(vmull_s16(vreinterpret_s16_u16(lhs), rhs));
        }
        if (accumulates) {
            uint32x4_t accumulator = vld1q_u32(
                (const uint32_t *)&cpu->v[instruction->rd]
            );
            product = subtracts
                ? vsubq_u32(accumulator, product)
                : vaddq_u32(accumulator, product);
        }
        vst1q_u32((uint32_t *)&cpu->v[instruction->rd], product);
        return 1;
    }
    case 32: {
        uint32x4_t lhs_full = vld1q_u32(
            (const uint32_t *)&cpu->v[instruction->rn]
        );
        uint32x2_t lhs = source_lane_base != 0u
            ? vget_high_u32(lhs_full)
            : vget_low_u32(lhs_full);
        uint64x2_t product;
        if (is_unsigned) {
            uint32x2_t rhs = by_element
                ? vdup_n_u32((uint32_t)read_vector_element(
                    cpu, instruction->rm, instruction->condition, 32
                ))
                : (source_lane_base != 0u
                    ? vget_high_u32(vld1q_u32((const uint32_t *)&cpu->v[instruction->rm]))
                    : vget_low_u32(vld1q_u32((const uint32_t *)&cpu->v[instruction->rm])));
            product = vmull_u32(lhs, rhs);
        } else {
            int32x2_t rhs = by_element
                ? vdup_n_s32((int32_t)sign_extend_u64(
                    read_vector_element(
                        cpu, instruction->rm, instruction->condition, 32
                    ),
                    32
                ))
                : (source_lane_base != 0u
                    ? vget_high_s32(vld1q_s32((const int32_t *)&cpu->v[instruction->rm]))
                    : vget_low_s32(vld1q_s32((const int32_t *)&cpu->v[instruction->rm])));
            product = vreinterpretq_u64_s64(vmull_s32(vreinterpret_s32_u32(lhs), rhs));
        }
        if (accumulates) {
            uint64x2_t accumulator = vld1q_u64(
                (const uint64_t *)&cpu->v[instruction->rd]
            );
            product = subtracts
                ? vsubq_u64(accumulator, product)
                : vaddq_u64(accumulator, product);
        }
        vst1q_u64((uint64_t *)&cpu->v[instruction->rd], product);
        return 1;
    }
    default:
        return 0;
    }
}

static int execute_simd_narrow_high_neon(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    unsigned source_bits = instruction->bits;
    unsigned writes_upper_half = instruction->flags & 1u;
    uint64_t narrowed = 0;

    if ((instruction->flags & 32u) != 0u) {
        switch (source_bits) {
        case 16: {
            uint8x8_t value = vmovn_u16(vld1q_u16(
                (const uint16_t *)&cpu->v[instruction->rn]
            ));
            vst1_u8((uint8_t *)&narrowed, value);
            break;
        }
        case 32: {
            uint16x4_t value = vmovn_u32(vld1q_u32(
                (const uint32_t *)&cpu->v[instruction->rn]
            ));
            vst1_u16((uint16_t *)&narrowed, value);
            break;
        }
        case 64: {
            uint32x2_t value = vmovn_u64(vld1q_u64(
                (const uint64_t *)&cpu->v[instruction->rn]
            ));
            vst1_u32((uint32_t *)&narrowed, value);
            break;
        }
        default:
            return 0;
        }
    } else if ((instruction->flags & 8u) != 0u) {
        int rounds = (instruction->flags & 16u) != 0u;
        switch (source_bits) {
        case 16: {
            uint16x8_t source = vld1q_u16(
                (const uint16_t *)&cpu->v[instruction->rn]
            );
            int16x8_t shifts = vdupq_n_s16(-(int16_t)instruction->shift_amount);
            uint16x8_t shifted = rounds
                ? vrshlq_u16(source, shifts)
                : vshlq_u16(source, shifts);
            vst1_u8((uint8_t *)&narrowed, vmovn_u16(shifted));
            break;
        }
        case 32: {
            uint32x4_t source = vld1q_u32(
                (const uint32_t *)&cpu->v[instruction->rn]
            );
            int32x4_t shifts = vdupq_n_s32(-(int32_t)instruction->shift_amount);
            uint32x4_t shifted = rounds
                ? vrshlq_u32(source, shifts)
                : vshlq_u32(source, shifts);
            vst1_u16((uint16_t *)&narrowed, vmovn_u32(shifted));
            break;
        }
        case 64: {
            uint64x2_t source = vld1q_u64(
                (const uint64_t *)&cpu->v[instruction->rn]
            );
            int64x2_t shifts = vdupq_n_s64(-(int64_t)instruction->shift_amount);
            uint64x2_t shifted = rounds
                ? vrshlq_u64(source, shifts)
                : vshlq_u64(source, shifts);
            vst1_u32((uint32_t *)&narrowed, vmovn_u64(shifted));
            break;
        }
        default:
            return 0;
        }
    } else {
        int rounds = (instruction->flags & 2u) != 0u;
        int subtracts = (instruction->flags & 4u) != 0u;
        switch (source_bits) {
        case 16: {
            uint16x8_t lhs = vld1q_u16((const uint16_t *)&cpu->v[instruction->rn]);
            uint16x8_t rhs = vld1q_u16((const uint16_t *)&cpu->v[instruction->rm]);
            uint8x8_t value = subtracts
                ? (rounds ? vrsubhn_u16(lhs, rhs) : vsubhn_u16(lhs, rhs))
                : (rounds ? vraddhn_u16(lhs, rhs) : vaddhn_u16(lhs, rhs));
            vst1_u8((uint8_t *)&narrowed, value);
            break;
        }
        case 32: {
            uint32x4_t lhs = vld1q_u32((const uint32_t *)&cpu->v[instruction->rn]);
            uint32x4_t rhs = vld1q_u32((const uint32_t *)&cpu->v[instruction->rm]);
            uint16x4_t value = subtracts
                ? (rounds ? vrsubhn_u32(lhs, rhs) : vsubhn_u32(lhs, rhs))
                : (rounds ? vraddhn_u32(lhs, rhs) : vaddhn_u32(lhs, rhs));
            vst1_u16((uint16_t *)&narrowed, value);
            break;
        }
        case 64: {
            uint64x2_t lhs = vld1q_u64((const uint64_t *)&cpu->v[instruction->rn]);
            uint64x2_t rhs = vld1q_u64((const uint64_t *)&cpu->v[instruction->rm]);
            uint32x2_t value = subtracts
                ? (rounds ? vrsubhn_u64(lhs, rhs) : vsubhn_u64(lhs, rhs))
                : (rounds ? vraddhn_u64(lhs, rhs) : vaddhn_u64(lhs, rhs));
            vst1_u32((uint32_t *)&narrowed, value);
            break;
        }
        default:
            return 0;
        }
    }

    if (writes_upper_half != 0u) {
        cpu->v[instruction->rd].high = narrowed;
    } else {
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){narrowed, 0};
    }
    return 1;
}

static int execute_simd_saturating_add_subtract_neon(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    if ((instruction->flags & 8u) != 0u) {
        return 0;
    }
    unsigned element_bits = instruction->bits;
    unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
    int is_unsigned = (instruction->flags & 2u) != 0;
    int subtracts = (instruction->flags & 4u) != 0;
    uint8x16_t result;
    uint8x16_t wrapping;

    if (is_unsigned) {
        switch (element_bits) {
        case 8: {
            uint8x16_t lhs = vld1q_u8((const uint8_t *)&cpu->v[instruction->rn]);
            uint8x16_t rhs = vld1q_u8((const uint8_t *)&cpu->v[instruction->rm]);
            result = subtracts ? vqsubq_u8(lhs, rhs) : vqaddq_u8(lhs, rhs);
            wrapping = subtracts ? vsubq_u8(lhs, rhs) : vaddq_u8(lhs, rhs);
            break;
        }
        case 16: {
            uint16x8_t lhs = vld1q_u16((const uint16_t *)&cpu->v[instruction->rn]);
            uint16x8_t rhs = vld1q_u16((const uint16_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_u16(
                subtracts ? vqsubq_u16(lhs, rhs) : vqaddq_u16(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_u16(
                subtracts ? vsubq_u16(lhs, rhs) : vaddq_u16(lhs, rhs)
            );
            break;
        }
        case 32: {
            uint32x4_t lhs = vld1q_u32((const uint32_t *)&cpu->v[instruction->rn]);
            uint32x4_t rhs = vld1q_u32((const uint32_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_u32(
                subtracts ? vqsubq_u32(lhs, rhs) : vqaddq_u32(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_u32(
                subtracts ? vsubq_u32(lhs, rhs) : vaddq_u32(lhs, rhs)
            );
            break;
        }
        case 64: {
            uint64x2_t lhs = vld1q_u64((const uint64_t *)&cpu->v[instruction->rn]);
            uint64x2_t rhs = vld1q_u64((const uint64_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_u64(
                subtracts ? vqsubq_u64(lhs, rhs) : vqaddq_u64(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_u64(
                subtracts ? vsubq_u64(lhs, rhs) : vaddq_u64(lhs, rhs)
            );
            break;
        }
        default:
            return 0;
        }
    } else {
        switch (element_bits) {
        case 8: {
            int8x16_t lhs = vld1q_s8((const int8_t *)&cpu->v[instruction->rn]);
            int8x16_t rhs = vld1q_s8((const int8_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_s8(
                subtracts ? vqsubq_s8(lhs, rhs) : vqaddq_s8(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_s8(
                subtracts ? vsubq_s8(lhs, rhs) : vaddq_s8(lhs, rhs)
            );
            break;
        }
        case 16: {
            int16x8_t lhs = vld1q_s16((const int16_t *)&cpu->v[instruction->rn]);
            int16x8_t rhs = vld1q_s16((const int16_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_s16(
                subtracts ? vqsubq_s16(lhs, rhs) : vqaddq_s16(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_s16(
                subtracts ? vsubq_s16(lhs, rhs) : vaddq_s16(lhs, rhs)
            );
            break;
        }
        case 32: {
            int32x4_t lhs = vld1q_s32((const int32_t *)&cpu->v[instruction->rn]);
            int32x4_t rhs = vld1q_s32((const int32_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_s32(
                subtracts ? vqsubq_s32(lhs, rhs) : vqaddq_s32(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_s32(
                subtracts ? vsubq_s32(lhs, rhs) : vaddq_s32(lhs, rhs)
            );
            break;
        }
        case 64: {
            int64x2_t lhs = vld1q_s64((const int64_t *)&cpu->v[instruction->rn]);
            int64x2_t rhs = vld1q_s64((const int64_t *)&cpu->v[instruction->rm]);
            result = vreinterpretq_u8_s64(
                subtracts ? vqsubq_s64(lhs, rhs) : vqaddq_s64(lhs, rhs)
            );
            wrapping = vreinterpretq_u8_s64(
                subtracts ? vsubq_s64(lhs, rhs) : vaddq_s64(lhs, rhs)
            );
            break;
        }
        default:
            return 0;
        }
    }

    uint8x16_t difference = veorq_u8(result, wrapping);
    int saturated = vector_bits == 64u
        ? vmaxv_u8(vget_low_u8(difference)) != 0
        : vmaxvq_u8(difference) != 0;
    if (saturated) {
        cpu->fpsr |= UINT64_C(1) << 27;
    }
    if (vector_bits == 64u) {
        vst1_u8((uint8_t *)&cpu->v[instruction->rd], vget_low_u8(result));
        cpu->v[instruction->rd].high = 0;
    } else {
        vst1q_u8((uint8_t *)&cpu->v[instruction->rd], result);
    }
    return 1;
}

static int execute_simd_shift_right_immediate_neon(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    if ((instruction->flags & 4u) != 0u || instruction->shift_amount == 0u) {
        return 0;
    }

    unsigned element_bits = instruction->bits;
    unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
    int is_unsigned = (instruction->flags & 2u) != 0u;
    int inserts = (instruction->flags & 8u) != 0u;
    int rounds = (instruction->flags & 16u) != 0u;
    int accumulates = (instruction->flags & 32u) != 0u;
    uint64_t element_mask = mask_for_bits(element_bits);
    uint64_t preserved_mask = instruction->shift_amount == element_bits
        ? element_mask
        : element_mask ^ (element_mask >> instruction->shift_amount);
    uint8x16_t result;

    switch (element_bits) {
    case 8: {
        uint8x16_t source = vld1q_u8((const uint8_t *)&cpu->v[instruction->rn]);
        int8x16_t shifts = vdupq_n_s8(-(int8_t)instruction->shift_amount);
        uint8x16_t value = is_unsigned
            ? (rounds ? vrshlq_u8(source, shifts) : vshlq_u8(source, shifts))
            : vreinterpretq_u8_s8(rounds
                ? vrshlq_s8(vreinterpretq_s8_u8(source), shifts)
                : vshlq_s8(vreinterpretq_s8_u8(source), shifts));
        uint8x16_t destination = vld1q_u8((const uint8_t *)&cpu->v[instruction->rd]);
        if (inserts) {
            value = vorrq_u8(
                value,
                vandq_u8(destination, vdupq_n_u8((uint8_t)preserved_mask))
            );
        } else if (accumulates) {
            value = vaddq_u8(value, destination);
        }
        result = value;
        break;
    }
    case 16: {
        uint16x8_t source = vld1q_u16((const uint16_t *)&cpu->v[instruction->rn]);
        int16x8_t shifts = vdupq_n_s16(-(int16_t)instruction->shift_amount);
        uint16x8_t value = is_unsigned
            ? (rounds ? vrshlq_u16(source, shifts) : vshlq_u16(source, shifts))
            : vreinterpretq_u16_s16(rounds
                ? vrshlq_s16(vreinterpretq_s16_u16(source), shifts)
                : vshlq_s16(vreinterpretq_s16_u16(source), shifts));
        uint16x8_t destination = vld1q_u16((const uint16_t *)&cpu->v[instruction->rd]);
        if (inserts) {
            value = vorrq_u16(
                value,
                vandq_u16(destination, vdupq_n_u16((uint16_t)preserved_mask))
            );
        } else if (accumulates) {
            value = vaddq_u16(value, destination);
        }
        result = vreinterpretq_u8_u16(value);
        break;
    }
    case 32: {
        uint32x4_t source = vld1q_u32((const uint32_t *)&cpu->v[instruction->rn]);
        int32x4_t shifts = vdupq_n_s32(-(int32_t)instruction->shift_amount);
        uint32x4_t value = is_unsigned
            ? (rounds ? vrshlq_u32(source, shifts) : vshlq_u32(source, shifts))
            : vreinterpretq_u32_s32(rounds
                ? vrshlq_s32(vreinterpretq_s32_u32(source), shifts)
                : vshlq_s32(vreinterpretq_s32_u32(source), shifts));
        uint32x4_t destination = vld1q_u32((const uint32_t *)&cpu->v[instruction->rd]);
        if (inserts) {
            value = vorrq_u32(
                value,
                vandq_u32(destination, vdupq_n_u32((uint32_t)preserved_mask))
            );
        } else if (accumulates) {
            value = vaddq_u32(value, destination);
        }
        result = vreinterpretq_u8_u32(value);
        break;
    }
    case 64: {
        uint64x2_t source = vld1q_u64((const uint64_t *)&cpu->v[instruction->rn]);
        int64x2_t shifts = vdupq_n_s64(-(int64_t)instruction->shift_amount);
        uint64x2_t value = is_unsigned
            ? (rounds ? vrshlq_u64(source, shifts) : vshlq_u64(source, shifts))
            : vreinterpretq_u64_s64(rounds
                ? vrshlq_s64(vreinterpretq_s64_u64(source), shifts)
                : vshlq_s64(vreinterpretq_s64_u64(source), shifts));
        uint64x2_t destination = vld1q_u64((const uint64_t *)&cpu->v[instruction->rd]);
        if (inserts) {
            value = vorrq_u64(
                value,
                vandq_u64(destination, vdupq_n_u64(preserved_mask))
            );
        } else if (accumulates) {
            value = vaddq_u64(value, destination);
        }
        result = vreinterpretq_u8_u64(value);
        break;
    }
    default:
        return 0;
    }

    if (vector_bits == 64u) {
        vst1_u8((uint8_t *)&cpu->v[instruction->rd], vget_low_u8(result));
        cpu->v[instruction->rd].high = 0;
    } else {
        vst1q_u8((uint8_t *)&cpu->v[instruction->rd], result);
    }
    return 1;
}
#endif

static uint64_t sign_extend_vector_element(
    const AVZNativeCPU *cpu,
    unsigned vector,
    unsigned lane,
    unsigned element_bits
) {
    return (uint64_t)sign_extend_u64(read_vector_element(cpu, vector, lane, element_bits), element_bits);
}

static AVZNativeVectorRegister duplicate_simd_element(
    uint64_t element,
    unsigned element_bits,
    int writes_full_vector
) {
    AVZNativeVectorRegister result = {0, 0};
    if (element_bits == 0u || element_bits > 64u || (64u % element_bits) != 0u) {
        return result;
    }
    uint64_t lane_mask = mask_for_bits(element_bits);
    uint64_t masked_element = element & lane_mask;
    unsigned lane_count = 64 / element_bits;

    for (unsigned lane = 0; lane < lane_count; lane++) {
        result.low |= masked_element << (lane * element_bits);
    }
    result.high = writes_full_vector ? result.low : 0;
    return result;
}

static int read_simd_fp_register_memory(
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t address,
    uint8_t byte_count,
    AVZNativeVectorRegister *value_out
) {
    uint64_t low = 0;
    uint64_t high = 0;
    if (value_out == 0 || read_memory == 0) {
        return 0;
    }

    switch (byte_count) {
    case 1:
    case 2:
    case 4:
        if (!read_memory(memory_context, address, byte_count, &low)) {
            return 0;
        }
        *value_out = (AVZNativeVectorRegister){low & mask_for_bits((unsigned)byte_count * 8u), 0};
        return 1;
    case 8:
        if (!read_memory(memory_context, address, 8, &low)) {
            return 0;
        }
        *value_out = (AVZNativeVectorRegister){low, 0};
        return 1;
    case 16:
        if (!read_memory(memory_context, address, 8, &low) ||
            !read_memory(memory_context, address + 8u, 8, &high)) {
            return 0;
        }
        *value_out = (AVZNativeVectorRegister){low, high};
        return 1;
    default:
        return 0;
    }
}

static int write_simd_fp_register_memory(
    AVZNativeMemoryWriteCallback write_memory,
    void *memory_context,
    uint64_t address,
    uint8_t byte_count,
    AVZNativeVectorRegister value
) {
    if (write_memory == 0) {
        return 0;
    }

    switch (byte_count) {
    case 1:
    case 2:
    case 4:
        return write_memory(memory_context, address, byte_count, value.low & mask_for_bits((unsigned)byte_count * 8u));
    case 8:
        return write_memory(memory_context, address, 8, value.low);
    case 16:
        return write_memory(memory_context, address, 8, value.low) &&
            write_memory(memory_context, address + 8u, 8, value.high);
    default:
        return 0;
    }
}

static int try_execute_simd_multiple_structure_bulk(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    void *memory_context
) {
    unsigned register_count = instruction->condition;
    if ((instruction->flags & 32u) == 0u ||
        register_count < 1u || register_count > 4u ||
        (instruction->width != 8u && instruction->width != 16u)) {
        return 0;
    }

    unsigned element_bytes = instruction->bits / 8u;
    unsigned lane_count = (instruction->width * 8u) / instruction->bits;
    size_t transfer_size =
        (size_t)lane_count * register_count * element_bytes;
    AVZNativeVectorRegister vectors[4] = {
        {0, 0}, {0, 0}, {0, 0}, {0, 0}
    };
    uint8_t transfer[64];
    uint8_t *mapped_address = NULL;
    uint64_t mapped_physical_address = 0;
    uint64_t base = read_base_register(cpu, instruction->rn);

    if ((instruction->flags & 1u) != 0u) {
        if (read_memory != avz_native_fast_memory_read) {
            return 0;
        }
        if (avz_native_fast_memory_map_span(
                memory_context,
                base,
                transfer_size,
                0,
                &mapped_address,
                &mapped_physical_address
            )) {
            if (!unpack_interleaved_vectors(
                    mapped_address,
                    register_count,
                    lane_count,
                    element_bytes,
                    vectors
                )) {
                return 0;
            }
        } else {
            if (!avz_native_fast_memory_read_bytes(
                    memory_context, base, transfer, transfer_size
                ) ||
                !unpack_interleaved_vectors(
                    transfer,
                    register_count,
                    lane_count,
                    element_bytes,
                    vectors
                )) {
                return 0;
            }
        }
        for (unsigned structure = 0; structure < register_count; structure++) {
            cpu->v[(instruction->rt + structure) & 0x1fu] = vectors[structure];
        }
    } else {
        if (write_memory != avz_native_fast_memory_write) {
            return 0;
        }
        for (unsigned structure = 0; structure < register_count; structure++) {
            vectors[structure] =
                cpu->v[(instruction->rt + structure) & 0x1fu];
        }
        if (avz_native_fast_memory_map_span(
                memory_context,
                base,
                transfer_size,
                1,
                &mapped_address,
                &mapped_physical_address
            )) {
            if (!pack_interleaved_vectors(
                    vectors,
                    register_count,
                    lane_count,
                    element_bytes,
                    mapped_address
                )) {
                return 0;
            }
            avz_native_fast_memory_commit_write_span(
                memory_context,
                mapped_physical_address,
                transfer_size
            );
        } else {
            if (!pack_interleaved_vectors(
                    vectors,
                    register_count,
                    lane_count,
                    element_bytes,
                    transfer
                ) ||
                !avz_native_fast_memory_write_bytes(
                    memory_context, base, transfer, transfer_size
                )) {
                return 0;
            }
        }
        clear_exclusive_reservation(cpu);
    }

    if ((instruction->flags & 8u) != 0u) {
        uint64_t increment = (instruction->flags & 16u) != 0u
            ? read_register(cpu, instruction->rm)
            : (uint64_t)instruction->width * register_count;
        write_base_register(cpu, instruction->rn, base + increment);
    }
    cpu->pc += 4;
    return 1;
}

static uint64_t masked_operand(uint64_t value, unsigned bits) {
    return bits == 64 ? value : (value & UINT64_C(0xffffffff));
}

static uint64_t rotate_right_width(uint64_t value, unsigned amount, unsigned width);
static int try_execute_store_pair_fill_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context,
    uint64_t *executed_steps
);
static int try_execute_simd_solid_fill_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context,
    uint64_t *executed_steps
);
static int try_execute_pixman_source_over_prefix(
    const AVZNativeInstruction *instructions,
    const uint64_t *instruction_pcs,
    size_t instruction_count,
    uint8_t *validated_hint,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    void *memory_context,
    uint64_t *executed_steps
);
static int try_execute_pixman_source_over_tail(
    const AVZNativeInstruction *instructions,
    const uint64_t *instruction_pcs,
    size_t instruction_count,
    uint8_t *validated_hint,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps
);

static uint64_t shifted_register_value(uint64_t value, uint8_t shift_type, uint8_t amount, unsigned bits) {
    uint64_t mask = mask_for_bits(bits);
    value &= mask;
    switch (shift_type) {
    case 0:
        return (value << amount) & mask;
    case 1:
        return amount == 0 ? value : (value >> amount);
    case 2:
        if (amount == 0) {
            return value;
        }
        if (bits == 64) {
            return (uint64_t)(((int64_t)value) >> amount) & mask;
        }
        return (uint64_t)(((int32_t)(uint32_t)value) >> amount) & mask;
    case 3:
        return rotate_right_width(value, amount, bits);
    default:
        return value;
    }
}

static uint64_t reverse_bits_width(uint64_t value, unsigned bits) {
    uint64_t result = 0;
    bits = bits > 64u ? 64u : bits;
    value &= mask_for_bits(bits);
    for (unsigned bit = 0; bit < bits; ++bit) {
        if (((value >> bit) & 1u) != 0) {
            result |= UINT64_C(1) << (bits - 1u - bit);
        }
    }
    return result & mask_for_bits(bits);
}

static uint64_t reverse_bytes_group(uint64_t value, unsigned group_bytes, unsigned bits) {
    bits = bits > 64u ? 64u : bits;
    unsigned byte_count = bits / 8u;
    uint64_t result = 0;
    if (group_bytes == 0u || byte_count == 0u || group_bytes > byte_count ||
        (byte_count % group_bytes) != 0u) {
        return value & mask_for_bits(bits);
    }
    value &= mask_for_bits(bits);
    for (unsigned byte_index = 0; byte_index < byte_count; ++byte_index) {
        unsigned group_start = (byte_index / group_bytes) * group_bytes;
        unsigned offset_in_group = byte_index - group_start;
        unsigned reversed_index = group_start + group_bytes - 1u - offset_in_group;
        uint64_t byte = (value >> (byte_index * 8u)) & UINT64_C(0xff);
        result |= byte << (reversed_index * 8u);
    }
    return result & mask_for_bits(bits);
}

static unsigned count_leading_zeros_width(uint64_t value, unsigned bits) {
    bits = bits > 64u ? 64u : bits;
    value &= mask_for_bits(bits);
    unsigned count = 0;
    for (int bit = (int)bits - 1; bit >= 0; --bit) {
        if (((value >> (unsigned)bit) & 1u) != 0) {
            break;
        }
        ++count;
    }
    return count;
}

static unsigned count_leading_sign_bits_width(uint64_t value, unsigned bits) {
    bits = bits > 64u ? 64u : bits;
    if (bits == 0u) {
        return 0u;
    }
    value &= mask_for_bits(bits);
    unsigned sign = (unsigned)((value >> (bits - 1u)) & 1u);
    unsigned count = 0;
    for (int bit = (int)bits - 2; bit >= 0; --bit) {
        if (((value >> (unsigned)bit) & 1u) != sign) {
            break;
        }
        ++count;
    }
    return count;
}

static int highest_set_bit(unsigned value) {
    for (int bit = 31; bit >= 0; --bit) {
        if ((value & (1u << bit)) != 0) {
            return bit;
        }
    }
    return -1;
}

static uint64_t rotate_right_width(uint64_t value, unsigned amount, unsigned width) {
    uint64_t mask = mask_for_bits(width);
    value &= mask;
    amount %= width;
    if (amount == 0) {
        return value;
    }
    return ((value >> amount) | (value << (width - amount))) & mask;
}

static int decode_logical_immediate(uint8_t n, uint8_t immr, uint8_t imms, unsigned bits, uint64_t *immediate_out) {
    if ((bits == 32 && n != 0) || immediate_out == 0) {
        return 0;
    }

    unsigned encoded_length = ((unsigned)n << 6) | ((~(unsigned)imms) & 0x3f);
    int length = highest_set_bit(encoded_length);
    if (length < 1) {
        return 0;
    }

    unsigned levels = (1u << (unsigned)length) - 1u;
    if (((unsigned)imms & levels) == levels) {
        return 0;
    }

    unsigned size = 1u << (unsigned)length;
    if (size > bits) {
        return 0;
    }

    unsigned set_bits = ((unsigned)imms & levels) + 1u;
    unsigned rotate = (unsigned)immr & levels;
    uint64_t element = rotate_right_width(mask_for_bits(set_bits), rotate, size);
    uint64_t result = 0;
    for (unsigned shift = 0; shift < bits; shift += size) {
        result |= element << shift;
    }
    *immediate_out = result & mask_for_bits(bits);
    return 1;
}

static int decode_bitfield_masks(
    uint8_t n,
    uint8_t immr,
    uint8_t imms,
    unsigned bits,
    uint64_t *write_mask_out,
    uint64_t *top_mask_out
) {
    if ((bits == 32 && n != 0) || (bits == 64 && n != 1) ||
        write_mask_out == 0 || top_mask_out == 0) {
        return 0;
    }

    unsigned encoded_length = ((unsigned)n << 6) | ((~(unsigned)imms) & 0x3f);
    int length = highest_set_bit(encoded_length);
    if (length < 1) {
        return 0;
    }

    unsigned levels = (1u << (unsigned)length) - 1u;
    unsigned size = 1u << (unsigned)length;
    if (size > bits) {
        return 0;
    }

    unsigned set_bits = (unsigned)imms & levels;
    unsigned rotate = (unsigned)immr & levels;
    unsigned diff = (set_bits - rotate) & levels;
    uint64_t write_element = rotate_right_width(mask_for_bits(set_bits + 1u), rotate, size);
    uint64_t top_element = mask_for_bits(diff + 1u);
    uint64_t write_mask = 0;
    uint64_t top_mask = 0;

    for (unsigned shift = 0; shift < bits; shift += size) {
        write_mask |= write_element << shift;
        top_mask |= top_element << shift;
    }

    uint64_t register_mask = mask_for_bits(bits);
    *write_mask_out = write_mask & register_mask;
    *top_mask_out = top_mask & register_mask;
    return 1;
}

static void bitfield_insert(
    uint64_t source,
    uint8_t immr,
    uint8_t imms,
    unsigned bits,
    uint64_t *value_out,
    uint64_t *mask_out
) {
    unsigned rotate = immr;
    unsigned set_bits = imms;
    uint64_t register_mask = mask_for_bits(bits);

    if (set_bits >= rotate) {
        unsigned width = set_bits - rotate + 1u;
        uint64_t field_mask = mask_for_bits(width);
        *value_out = (source >> rotate) & field_mask;
        *mask_out = field_mask;
        return;
    }

    unsigned width = set_bits + 1u;
    unsigned lsb = bits - rotate;
    uint64_t field_mask = (mask_for_bits(width) << lsb) & register_mask;
    *value_out = ((source & mask_for_bits(width)) << lsb) & register_mask;
    *mask_out = field_mask;
}

static uint64_t signed_divide_width(uint64_t dividend, uint64_t divisor, unsigned bits) {
    if (bits == 32) {
        int32_t lhs = (int32_t)(uint32_t)dividend;
        int32_t rhs = (int32_t)(uint32_t)divisor;
        if (rhs == 0) {
            return 0;
        }
        if (lhs == INT32_MIN && rhs == -1) {
            return (uint64_t)(uint32_t)INT32_MIN;
        }
        return (uint64_t)(uint32_t)(lhs / rhs);
    }

    int64_t lhs = (int64_t)dividend;
    int64_t rhs = (int64_t)divisor;
    if (rhs == 0) {
        return 0;
    }
    if (lhs == INT64_MIN && rhs == -1) {
        return (uint64_t)INT64_MIN;
    }
    return (uint64_t)(lhs / rhs);
}

static uint64_t sign_extend_loaded(uint64_t value, unsigned bits) {
    if (bits >= 64 || (value & sign_bit_for_bits(bits)) == 0) {
        return value;
    }
    return value | ~mask_for_bits(bits);
}

static uint64_t extended_register_value(uint64_t value, uint8_t option) {
    switch (option) {
    case 0:
        return value & UINT64_C(0xff);
    case 1:
        return value & UINT64_C(0xffff);
    case 2:
        return value & UINT64_C(0xffffffff);
    case 3:
        return value;
    case 4:
        return sign_extend_loaded(value & UINT64_C(0xff), 8);
    case 5:
        return sign_extend_loaded(value & UINT64_C(0xffff), 16);
    case 6:
        return sign_extend_loaded(value & UINT64_C(0xffffffff), 32);
    case 7:
        return value;
    default:
        return value;
    }
}

static uint64_t add_with_carry_nzcv(uint64_t lhs, uint64_t rhs, int carry_in, unsigned bits, uint64_t *result_out) {
    uint64_t mask = mask_for_bits(bits);
    uint64_t result = (lhs + rhs + (carry_in ? 1 : 0)) & mask;
    unsigned __int128 unsigned_sum = (unsigned __int128)lhs + (unsigned __int128)rhs + (carry_in ? 1 : 0);
    uint64_t sign = sign_bit_for_bits(bits);
    int lhs_negative = (lhs & sign) != 0;
    int rhs_negative = (rhs & sign) != 0;
    int result_negative = (result & sign) != 0;
    uint64_t flags = 0;

    if (result_negative) {
        flags |= UINT64_C(0x80000000);
    }
    if (result == 0) {
        flags |= UINT64_C(0x40000000);
    }
    if ((unsigned_sum >> bits) != 0) {
        flags |= UINT64_C(0x20000000);
    }
    if (lhs_negative == rhs_negative && lhs_negative != result_negative) {
        flags |= UINT64_C(0x10000000);
    }

    *result_out = result;
    return flags;
}

static uint64_t fp_compare_nzcv_double(double lhs, double rhs) {
    if (lhs != lhs || rhs != rhs) {
        return UINT64_C(0x30000000);
    }
    if (lhs == rhs) {
        return UINT64_C(0x60000000);
    }
    if (lhs < rhs) {
        return UINT64_C(0x80000000);
    }
    return UINT64_C(0x20000000);
}

static uint64_t fp_compare_nzcv_float(float lhs, float rhs) {
    if (lhs != lhs || rhs != rhs) {
        return UINT64_C(0x30000000);
    }
    if (lhs == rhs) {
        return UINT64_C(0x60000000);
    }
    if (lhs < rhs) {
        return UINT64_C(0x80000000);
    }
    return UINT64_C(0x20000000);
}

static uint64_t signed_integer_bits_from_fp(double value, unsigned bits) {
    if (value != value) {
        return 0;
    }
    if (bits == 32) {
        if (value >= 2147483647.0) {
            return (uint64_t)(uint32_t)INT32_MAX;
        }
        if (value <= -2147483648.0) {
            return (uint64_t)(uint32_t)INT32_MIN;
        }
        return (uint64_t)(uint32_t)(int32_t)value;
    }
    if (value >= 9223372036854775807.0) {
        return (uint64_t)INT64_MAX;
    }
    if (value <= -9223372036854775808.0) {
        return (uint64_t)INT64_MIN;
    }
    return (uint64_t)(int64_t)value;
}

static uint64_t unsigned_integer_bits_from_fp(double value, unsigned bits) {
    if (value != value || value <= 0.0) {
        return 0;
    }
    if (bits == 32) {
        if (value >= 4294967295.0) {
            return UINT64_C(0xffffffff);
        }
        return (uint64_t)(uint32_t)value;
    }
    if (value >= 18446744073709551615.0) {
        return UINT64_MAX;
    }
    return (uint64_t)value;
}

static double round_fp_to_integral(double value, unsigned mode) {
    double rounded;
    switch (mode) {
    case 0:
        rounded = trunc(value);
        break;
    case 1: {
        if (!isfinite(value)) {
            return value;
        }
        double lower = floor(value);
        double fraction = value - lower;
        if (fraction < 0.5) {
            rounded = lower;
        } else if (fraction > 0.5) {
            rounded = lower + 1.0;
        } else {
            rounded = fmod(fabs(lower), 2.0) == 0.0 ? lower : lower + 1.0;
        }
        break;
    }
    case 2:
        rounded = ceil(value);
        break;
    case 3:
        rounded = floor(value);
        break;
    case 4:
        rounded = round(value);
        break;
    default:
        return value;
    }
    return rounded == 0.0 ? copysign(0.0, value) : rounded;
}

static int condition_holds(uint8_t condition, uint64_t pstate) {
    int n = (pstate & UINT64_C(0x80000000)) != 0;
    int z = (pstate & UINT64_C(0x40000000)) != 0;
    int c = (pstate & UINT64_C(0x20000000)) != 0;
    int v = (pstate & UINT64_C(0x10000000)) != 0;
    int result;

    switch (condition >> 1) {
    case 0:
        result = z;
        break;
    case 1:
        result = c;
        break;
    case 2:
        result = n;
        break;
    case 3:
        result = v;
        break;
    case 4:
        result = c && !z;
        break;
    case 5:
        result = n == v;
        break;
    case 6:
        result = !z && n == v;
        break;
    case 7:
        result = 1;
        break;
    default:
        result = 0;
        break;
    }

    if ((condition & 1) != 0 && condition != 0xf) {
        result = !result;
    }
    return result;
}

static int execute_add_sub_immediate(AVZNativeCPU *cpu, uint32_t instruction) {
    uint64_t pc = cpu->pc;
    int is_64 = ((instruction >> 31) & 1) != 0;
    int subtract = ((instruction >> 30) & 1) != 0;
    int set_flags = ((instruction >> 29) & 1) != 0;
    uint64_t imm = (uint64_t)((instruction >> 10) & 0xfff);
    unsigned shift = ((instruction >> 22) & 3) == 1 ? 12 : 0;
    unsigned rn = (instruction >> 5) & 0x1f;
    unsigned rd = instruction & 0x1f;
    unsigned bits = is_64 ? 64 : 32;
    uint64_t lhs = masked_operand(read_base_register(cpu, rn), bits);
    uint64_t rhs = masked_operand(imm << shift, bits);
    uint64_t result;

    if (subtract) {
        rhs = (~rhs) & mask_for_bits(bits);
    }
    uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &result);
    if (set_flags) {
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
    }
    if (set_flags) {
        write_register(cpu, rd, result);
    } else {
        write_base_register(cpu, rd, result);
    }
    cpu->pc = pc + 4;
    return 1;
}

static int execute_move_wide(AVZNativeCPU *cpu, uint32_t instruction) {
    int is_64 = ((instruction >> 31) & 1) != 0;
    uint32_t opcode = (instruction >> 29) & 3;
    unsigned rd = instruction & 0x1f;
    uint32_t hw = (instruction >> 21) & 3;
    uint64_t shift = (uint64_t)hw * 16;
    uint64_t imm = (uint64_t)((instruction >> 5) & 0xffff) << shift;
    unsigned bits = is_64 ? 64 : 32;
    uint64_t mask = mask_for_bits(bits);
    uint64_t value;

    if (!is_64 && hw > 1) {
        return 0;
    }

    switch (opcode) {
    case 0:
        value = (~imm) & mask;
        break;
    case 2:
        value = imm & mask;
        break;
    case 3: {
        uint64_t current = read_register(cpu, rd);
        uint64_t field_mask = (UINT64_C(0xffff) << shift) & mask;
        value = (current & ~field_mask) | (imm & field_mask);
        value &= mask;
        break;
    }
    default:
        return 0;
    }

    write_register(cpu, rd, value);
    cpu->pc += 4;
    return 1;
}

static int execute_add_sub_shifted_register(AVZNativeCPU *cpu, uint32_t instruction) {
    int is_64 = ((instruction >> 31) & 1) != 0;
    int subtract = ((instruction >> 30) & 1) != 0;
    int set_flags = ((instruction >> 29) & 1) != 0;
    unsigned shift_type = (instruction >> 22) & 3;
    unsigned shift_amount = (instruction >> 10) & 0x3f;
    unsigned rm = (instruction >> 16) & 0x1f;
    unsigned rn = (instruction >> 5) & 0x1f;
    unsigned rd = instruction & 0x1f;
    unsigned bits = is_64 ? 64 : 32;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_register(cpu, rn), bits);
    uint64_t rhs = masked_operand(read_register(cpu, rm), bits);
    uint64_t result;

    if (!is_64 && shift_amount >= 32) {
        return 0;
    }

    switch (shift_type) {
    case 0:
        rhs = (rhs << shift_amount) & mask;
        break;
    case 1:
        rhs >>= shift_amount;
        break;
    case 2:
        if (shift_amount > 0) {
            if (bits == 64) {
                rhs = (uint64_t)(((int64_t)rhs) >> shift_amount);
            } else {
                rhs = (uint64_t)(((int32_t)(uint32_t)rhs) >> shift_amount);
            }
        }
        rhs &= mask;
        break;
    default:
        return 0;
    }

    if (subtract) {
        rhs = (~rhs) & mask;
    }
    uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &result);
    if (set_flags) {
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
    }
    write_register(cpu, rd, result);
    cpu->pc += 4;
    return 1;
}

static int is_simd_modified_immediate(uint32_t instruction) {
    /* Q and op vary; bits 31, 28:19, and 10 identify this encoding class. */
    return (instruction & UINT32_C(0x9ff80400)) == UINT32_C(0x0f000400);
}

static int decode_simd_movi_zero(uint32_t instruction) {
    if (!is_simd_modified_immediate(instruction)) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    uint32_t imm8 = (((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu);

    if (o2 != 0 || imm8 != 0) {
        return 0;
    }
    if (op == 0) {
        return (cmode <= 0xa && (cmode & 1u) == 0u) ||
            cmode == 0xc || cmode == 0xd || cmode == 0xe;
    }
    return cmode == 0xe;
}

static int decode_simd_movi_byte(uint32_t instruction, uint64_t *byte_out, int *writes_full_vector_out) {
    if (!is_simd_modified_immediate(instruction) ||
        byte_out == 0 || writes_full_vector_out == 0) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    if (op != 0 || cmode != 0xe || o2 != 0) {
        return 0;
    }

    *byte_out = (uint64_t)((((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu));
    *writes_full_vector_out = ((instruction >> 30) & 1u) != 0;
    return 1;
}

static int decode_simd_movi_word_immediate(
    uint32_t instruction,
    uint64_t *value_out,
    unsigned *element_bits_out,
    int *writes_full_vector_out
) {
    if (!is_simd_modified_immediate(instruction) || value_out == 0 ||
        element_bits_out == 0 || writes_full_vector_out == 0) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    if (op != 0 || o2 != 0) {
        return 0;
    }

    uint32_t imm8 = (((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu);
    if (cmode <= 6u && (cmode & 1u) == 0u) {
        *value_out = (uint64_t)(imm8 << ((cmode >> 1) * 8u));
        *element_bits_out = 32u;
    } else if (cmode == 8u || cmode == 10u) {
        *value_out = (uint64_t)(uint16_t)(imm8 << (cmode == 8u ? 0u : 8u));
        *element_bits_out = 16u;
    } else if (cmode == 12u || cmode == 13u) {
        unsigned shift = cmode == 12u ? 8u : 16u;
        *value_out = (uint64_t)((imm8 << shift) | ((UINT32_C(1) << shift) - 1u));
        *element_bits_out = 32u;
    } else {
        return 0;
    }
    *writes_full_vector_out = ((instruction >> 30) & 1u) != 0;
    return 1;
}

static int decode_simd_logical_word_immediate(
    uint32_t instruction,
    uint64_t *value_out,
    unsigned *element_bits_out,
    int *writes_full_vector_out,
    int *is_bic_out
) {
    if (!is_simd_modified_immediate(instruction) || value_out == 0 ||
        element_bits_out == 0 || writes_full_vector_out == 0 || is_bic_out == 0) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    if (o2 != 0u || (cmode & 1u) == 0u || cmode > 11u) {
        return 0;
    }

    uint32_t imm8 = (((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu);
    if (cmode <= 7u) {
        *value_out = (uint64_t)(imm8 << ((cmode >> 1) * 8u));
        *element_bits_out = 32u;
    } else {
        *value_out = (uint64_t)(uint16_t)(imm8 << (cmode == 9u ? 0u : 8u));
        *element_bits_out = 16u;
    }
    *writes_full_vector_out = ((instruction >> 30) & 1u) != 0u;
    *is_bic_out = op != 0u;
    return 1;
}

static uint64_t expand_simd_movi_d_immediate(uint32_t imm8) {
    uint64_t value = 0;
    for (unsigned byte = 0; byte < 8; byte++) {
        if ((imm8 & (1u << byte)) != 0) {
            value |= UINT64_C(0xff) << (byte * 8u);
        }
    }
    return value;
}

static uint64_t expand_fp_immediate_bits(uint32_t imm8, unsigned bits) {
    uint64_t immediate = (uint64_t)imm8 & UINT64_C(0xff);
    uint64_t sign = immediate >> 7;
    uint64_t repeated = (immediate >> 6) & 1u;
    uint64_t exponent_low = (immediate >> 4) & 3u;
    uint64_t fraction = immediate & 0xfu;
    if (bits == 64) {
        uint64_t exponent = ((repeated ^ 1u) << 10) |
            (repeated != 0 ? UINT64_C(0x3fc) : 0) |
            exponent_low;
        return (sign << 63) | (exponent << 52) | (fraction << 48);
    }
    if (bits == 32) {
        uint64_t exponent = ((repeated ^ 1u) << 7) |
            (repeated != 0 ? UINT64_C(0x7c) : 0) |
            exponent_low;
        return (sign << 31) | (exponent << 23) | (fraction << 19);
    }
    return 0;
}

static int decode_simd_fp_immediate(
    uint32_t instruction,
    uint64_t *value_out,
    unsigned *element_bits_out,
    int *writes_full_vector_out
) {
    if (!is_simd_modified_immediate(instruction) ||
        value_out == 0 || element_bits_out == 0 || writes_full_vector_out == 0) {
        return 0;
    }

    unsigned q = (instruction >> 30) & 1u;
    unsigned op = (instruction >> 29) & 1u;
    unsigned cmode = (instruction >> 12) & 0xfu;
    unsigned o2 = (instruction >> 11) & 1u;
    if (cmode != 0xf || o2 != 0 || (op != 0 && q == 0)) {
        return 0;
    }

    unsigned bits = op != 0 ? 64u : 32u;
    uint32_t imm8 = (((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu);
    *value_out = expand_fp_immediate_bits(imm8, bits);
    *element_bits_out = bits;
    *writes_full_vector_out = q != 0;
    return 1;
}

static int decode_simd_movi_d_immediate(
    uint32_t instruction,
    uint64_t *value_out,
    int *writes_full_vector_out
) {
    if (!is_simd_modified_immediate(instruction) ||
        value_out == 0 || writes_full_vector_out == 0) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    uint32_t imm8 = (((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu);

    if (op != 1 || cmode != 0xe || o2 != 0) {
        return 0;
    }

    *value_out = expand_simd_movi_d_immediate(imm8);
    *writes_full_vector_out = ((instruction >> 30) & 1u) != 0;
    return 1;
}

static int decode_simd_mvni_immediate(
    uint32_t instruction,
    uint64_t *value_out,
    unsigned *element_bits_out,
    int *writes_full_vector_out
) {
    if (!is_simd_modified_immediate(instruction) ||
        value_out == 0 || element_bits_out == 0 || writes_full_vector_out == 0) {
        return 0;
    }

    uint32_t op = (instruction >> 29) & 1u;
    uint32_t cmode = (instruction >> 12) & 0xfu;
    uint32_t o2 = (instruction >> 11) & 1u;
    uint64_t imm8 = (uint64_t)((((instruction >> 16) & 0x7u) << 5) | ((instruction >> 5) & 0x1fu));

    if (op != 1 || o2 != 0) {
        return 0;
    }

    switch (cmode) {
    case 0x0:
    case 0x2:
    case 0x4:
    case 0x6: {
        unsigned shift = (cmode / 2u) * 8u;
        *value_out = (uint64_t)(UINT32_MAX ^ (uint32_t)(imm8 << shift));
        *element_bits_out = 32;
        break;
    }
    case 0x8:
    case 0xa: {
        unsigned shift = cmode == 0x8 ? 0 : 8;
        *value_out = (uint64_t)(UINT16_MAX ^ (uint16_t)(imm8 << shift));
        *element_bits_out = 16;
        break;
    }
    case 0xc:
    case 0xd: {
        unsigned shift = cmode == 0xc ? 8u : 16u;
        uint32_t shifted_ones = (uint32_t)(imm8 << shift) |
            ((UINT32_C(1) << shift) - 1u);
        *value_out = (uint64_t)(~shifted_ones);
        *element_bits_out = 32u;
        break;
    }
    default:
        return 0;
    }

    *writes_full_vector_out = ((instruction >> 30) & 1u) != 0;
    return 1;
}

int avz_native_decode_instruction(uint32_t instruction, AVZNativeInstruction *decoded) {
    if (decoded == 0) {
        return 0;
    }

    *decoded = (AVZNativeInstruction){
        .raw = instruction,
        .kind = 0,
        .rd = 0,
        .rn = 0,
        .rm = 0,
        .rt = 0,
        .width = 0,
        .bits = 0,
        .flags = 0,
        .condition = 0,
        .shift_type = 0,
        .shift_amount = 0,
        .immediate = 0,
        .immediate2 = 0
    };

    if (instruction == UINT32_C(0xd503205f) || instruction == UINT32_C(0xd503207f)) {
        decoded->kind = AVZ_NATIVE_OP_WAIT;
        decoded->flags = instruction == UINT32_C(0xd503207f) ? 1 : 0;
        return 1;
    }

    if (instruction == UINT32_C(0xd503201f) ||
        instruction == UINT32_C(0xd503209f) ||
        instruction == UINT32_C(0xd50320bf) ||
        (instruction & UINT32_C(0xfffff01f)) == UINT32_C(0xd503201f)) {
        decoded->kind = AVZ_NATIVE_OP_NOP;
        return 1;
    }

    if ((instruction & UINT32_C(0xfffff0ff)) == UINT32_C(0xd503309f) ||
        (instruction & UINT32_C(0xfffff0ff)) == UINT32_C(0xd50330bf) ||
        (instruction & UINT32_C(0xfffff0ff)) == UINT32_C(0xd50330df)) {
        decoded->kind = AVZ_NATIVE_OP_BARRIER;
        decoded->flags = (instruction >> 5) & 0x7;
        return 1;
    }

    if ((instruction & UINT32_C(0xfffff01f)) == UINT32_C(0xd503401f)) {
        uint8_t operation = (instruction >> 5) & 0x7;
        if (operation != 0x6 && operation != 0x7) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_PSTATE_IMMEDIATE;
        decoded->flags = operation;
        decoded->immediate = (int64_t)(((instruction >> 8) & 0xf) << 6);
        return 1;
    }

    if ((instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4400000)) {
        decoded->kind = AVZ_NATIVE_OP_HALT;
        return 1;
    }

    if (instruction == UINT32_C(0xd69f03e0)) {
        decoded->kind = AVZ_NATIVE_OP_EXCEPTION_RETURN;
        return 1;
    }

    if ((instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4000001) ||
        (instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4000002) ||
        (instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4000003) ||
        (instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4200000)) {
        decoded->kind = AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION;
        return 1;
    }

    if ((instruction & UINT32_C(0xfff00000)) == UINT32_C(0xd5300000)) {
        decoded->kind = AVZ_NATIVE_OP_SYSTEM_REGISTER_READ;
        decoded->rt = instruction & 0x1f;
        return 1;
    }

    if ((instruction & UINT32_C(0xfff00000)) == UINT32_C(0xd5100000)) {
        decoded->kind = AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE;
        decoded->rt = instruction & 0x1f;
        return 1;
    }

    if ((instruction & UINT32_C(0xfff80000)) == UINT32_C(0xd5080000)) {
        decoded->kind = AVZ_NATIVE_OP_SYSTEM_INSTRUCTION;
        decoded->rt = instruction & 0x1f;
        return 1;
    }

    if ((instruction & UINT32_C(0x9f000000)) == UINT32_C(0x10000000) ||
        (instruction & UINT32_C(0x9f000000)) == UINT32_C(0x90000000)) {
        int page = (instruction & UINT32_C(0x9f000000)) == UINT32_C(0x90000000);
        uint64_t immlo = (instruction >> 29) & 3;
        uint64_t immhi = (instruction >> 5) & 0x7ffff;
        int64_t offset = sign_extend_u64((immhi << 2) | immlo, 21);
        decoded->kind = AVZ_NATIVE_OP_ADR;
        decoded->rd = instruction & 0x1f;
        decoded->flags = page ? 1 : 0;
        decoded->immediate = page ? offset * INT64_C(4096) : offset;
        return 1;
    }

    if ((instruction & UINT32_C(0x7e000000)) == UINT32_C(0x34000000)) {
        decoded->kind = AVZ_NATIVE_OP_CBZ;
        decoded->rt = instruction & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->flags = ((instruction >> 24) & 1) ? 1 : 0;
        decoded->immediate = decode_scaled_signed_immediate(
            (instruction >> 5) & 0x7ffff,
            19,
            4
        );
        return 1;
    }

    if ((instruction & UINT32_C(0x7e000000)) == UINT32_C(0x36000000)) {
        decoded->kind = AVZ_NATIVE_OP_TBZ;
        decoded->rt = instruction & 0x1f;
        decoded->shift_amount = (uint8_t)((((instruction >> 31) & 1) << 5) | ((instruction >> 19) & 0x1f));
        decoded->flags = ((instruction >> 24) & 1) ? 1 : 0;
        decoded->immediate = decode_scaled_signed_immediate(
            (instruction >> 5) & 0x3fff,
            14,
            4
        );
        return 1;
    }

    if ((instruction & UINT32_C(0xff000010)) == UINT32_C(0x54000000)) {
        decoded->kind = AVZ_NATIVE_OP_BCOND;
        decoded->condition = instruction & 0xf;
        decoded->immediate = decode_scaled_signed_immediate(
            (instruction >> 5) & 0x7ffff,
            19,
            4
        );
        return 1;
    }

    if ((instruction & UINT32_C(0x3fe00c10)) == UINT32_C(0x3a400000)) {
        decoded->kind = AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->condition = (instruction >> 12) & 0xf;
        decoded->flags = (uint8_t)((instruction >> 30) & 1);
        decoded->immediate = (int64_t)((instruction & 0xf) << 28);
        return 1;
    }

    if ((instruction & UINT32_C(0x3fe00c10)) == UINT32_C(0x3a400800)) {
        decoded->kind = AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->condition = (instruction >> 12) & 0xf;
        decoded->flags = (uint8_t)((instruction >> 30) & 1);
        decoded->immediate = (int64_t)((instruction >> 16) & 0x1f);
        decoded->immediate2 = (int64_t)((instruction & 0xf) << 28);
        return 1;
    }

    if ((instruction & UINT32_C(0x1fe00800)) == UINT32_C(0x1a800000)) {
        uint8_t operation = (instruction >> 10) & 3;
        if (operation > 1) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_CONDITIONAL_SELECT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->condition = (instruction >> 12) & 0xf;
        decoded->flags = (uint8_t)(operation | (((instruction >> 30) & 1) ? 4 : 0));
        return 1;
    }

    if ((instruction & UINT32_C(0x1f200000)) == UINT32_C(0x0b000000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        uint8_t shift_amount = (instruction >> 10) & 0x3f;
        if (!is_64 && shift_amount >= 32) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = is_64 ? 64 : 32;
        decoded->shift_type = (instruction >> 22) & 3;
        decoded->shift_amount = shift_amount;
        decoded->flags = (((instruction >> 30) & 1) ? 1 : 0) |
            (((instruction >> 29) & 1) ? 2 : 0);
        return decoded->shift_type <= 2;
    }

    if ((instruction & UINT32_C(0x1fe0fc00)) == UINT32_C(0x1a000000)) {
        decoded->kind = AVZ_NATIVE_OP_ADD_SUB_CARRY;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->flags = (uint8_t)((((instruction >> 30) & 1) ? 1 : 0) |
            (((instruction >> 29) & 1) ? 2 : 0));
        return 1;
    }

    if ((instruction & UINT32_C(0x1f000000)) == UINT32_C(0x0a000000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        uint8_t shift_amount = (instruction >> 10) & 0x3f;
        uint8_t shift_type = (instruction >> 22) & 3;
        if (!is_64 && shift_amount >= 32) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = is_64 ? 64 : 32;
        decoded->shift_type = shift_type;
        decoded->shift_amount = shift_amount;
        decoded->flags = (uint8_t)(((instruction >> 29) & 3) |
            (((instruction >> 21) & 1) ? 4 : 0));
        return 1;
    }

    if ((instruction & UINT32_C(0x7fa00000)) == UINT32_C(0x13800000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        unsigned bits = is_64 ? 64 : 32;
        uint8_t n = (instruction >> 22) & 1;
        uint8_t lsb = (instruction >> 10) & 0x3f;
        if ((n != 0) != is_64 || lsb >= bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_EXTRACT_REGISTER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)bits;
        decoded->shift_amount = lsb;
        return 1;
    }

    if ((instruction & UINT32_C(0x1f800000)) == UINT32_C(0x12000000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        unsigned bits = is_64 ? 64 : 32;
        uint64_t immediate = 0;
        if (!decode_logical_immediate(
                (instruction >> 22) & 1,
                (instruction >> 16) & 0x3f,
                (instruction >> 10) & 0x3f,
                bits,
                &immediate
            )) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_LOGICAL_IMMEDIATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)bits;
        decoded->flags = (instruction >> 29) & 3;
        decoded->immediate = (int64_t)immediate;
        return 1;
    }

    if ((instruction & UINT32_C(0xfffffc1f)) == UINT32_C(0xd65f0000) ||
        (instruction & UINT32_C(0xfffffc1f)) == UINT32_C(0xd61f0000) ||
        (instruction & UINT32_C(0xfffffc1f)) == UINT32_C(0xd63f0000)) {
        decoded->kind = AVZ_NATIVE_OP_REGISTER_BRANCH;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = ((instruction & UINT32_C(0xfffffc1f)) == UINT32_C(0xd63f0000)) ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0x1f800000)) == UINT32_C(0x13000000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        unsigned bits = is_64 ? 64 : 32;
        uint8_t opcode = (instruction >> 29) & 3;
        uint8_t n = (instruction >> 22) & 1;
        uint8_t immr = (instruction >> 16) & 0x3f;
        uint8_t imms = (instruction >> 10) & 0x3f;
        uint64_t write_mask = 0;
        uint64_t top_mask = 0;
        if (opcode == 3 || !decode_bitfield_masks(n, immr, imms, bits, &write_mask, &top_mask)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_BITFIELD_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)bits;
        decoded->flags = opcode;
        decoded->shift_amount = immr;
        decoded->condition = imms;
        decoded->immediate = (int64_t)write_mask;
        decoded->immediate2 = (int64_t)top_mask;
        return 1;
    }

    if ((instruction & UINT32_C(0x5fe00000)) == UINT32_C(0x5ac00000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        uint8_t opcode = (instruction >> 10) & 0x3f;
        if (!(opcode == 0x00 || opcode == 0x01 || opcode == 0x02 ||
              (opcode == 0x03 && is_64) || opcode == 0x04 || opcode == 0x05)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_DATA_PROCESSING_ONE_SOURCE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = is_64 ? 64 : 32;
        decoded->flags = opcode;
        return 1;
    }

    if ((instruction & UINT32_C(0x7fe0c000)) == UINT32_C(0x1ac00000)) {
        uint8_t opcode = (instruction >> 10) & 0x3f;
        if (!(opcode == 0x02 || opcode == 0x03 ||
              opcode == 0x08 || opcode == 0x09 || opcode == 0x0a || opcode == 0x0b)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_DATA_PROCESSING_TWO_SOURCE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->flags = opcode;
        return 1;
    }

    if ((instruction & UINT32_C(0x7fe00000)) == UINT32_C(0x1b000000)) {
        decoded->kind = AVZ_NATIVE_OP_MULTIPLY_ADD_SUBTRACT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->rt = (instruction >> 10) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->flags = ((instruction >> 15) & 1) ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0x7fe00000)) == UINT32_C(0x1b200000)) {
        decoded->kind = AVZ_NATIVE_OP_SIGNED_MULTIPLY_LONG_ADD_SUBTRACT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->rt = (instruction >> 10) & 0x1f;
        decoded->flags = ((instruction >> 15) & 1) ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0x7fe00000)) == UINT32_C(0x1ba00000)) {
        decoded->kind = AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_LONG_ADD_SUBTRACT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->rt = (instruction >> 10) & 0x1f;
        decoded->flags = ((instruction >> 15) & 1) ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0xffe0fc00)) == UINT32_C(0x9b407c00)) {
        decoded->kind = AVZ_NATIVE_OP_SIGNED_MULTIPLY_HIGH;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        return 1;
    }

    if ((instruction & UINT32_C(0xffe0fc00)) == UINT32_C(0x9bc07c00)) {
        decoded->kind = AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_HIGH;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        return 1;
    }

    if ((instruction & UINT32_C(0x1f200000)) == UINT32_C(0x0b200000)) {
        uint8_t shift = (instruction >> 10) & 7;
        if (shift > 4) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1) ? 64 : 32;
        decoded->condition = (instruction >> 13) & 7;
        decoded->shift_amount = shift;
        decoded->flags = (((instruction >> 30) & 1) ? 1 : 0) |
            (((instruction >> 29) & 1) ? 2 : 0);
        return 1;
    }

    if ((instruction & UINT32_C(0x3b000000)) == UINT32_C(0x18000000)) {
        decoded->kind = AVZ_NATIVE_OP_LOAD_LITERAL;
        decoded->rt = instruction & 0x1f;
        decoded->flags = (instruction >> 30) & 3;
        decoded->immediate = decode_scaled_signed_immediate(
            (instruction >> 5) & 0x7ffff,
            19,
            4
        );
        decoded->width = decoded->flags == 1 ? 8 : 4;
        decoded->bits = (uint8_t)(decoded->width * 8);
        return 1;
    }

    if ((instruction & UINT32_C(0x1f800000)) == UINT32_C(0x12800000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        uint32_t opcode = (instruction >> 29) & 3;
        uint32_t hw = (instruction >> 21) & 3;
        if ((!is_64 && hw > 1) || opcode == 1) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_MOVE_WIDE;
        decoded->rd = instruction & 0x1f;
        decoded->bits = is_64 ? 64 : 32;
        decoded->flags = (uint8_t)opcode;
        decoded->shift_amount = (uint8_t)(hw * 16);
        decoded->immediate = (int64_t)((uint64_t)((instruction >> 5) & 0xffff) << decoded->shift_amount);
        return 1;
    }

    if ((instruction & UINT32_C(0x1f000000)) == UINT32_C(0x11000000)) {
        int is_64 = ((instruction >> 31) & 1) != 0;
        uint64_t imm = (uint64_t)((instruction >> 10) & 0xfff);
        unsigned shift = ((instruction >> 22) & 3) == 1 ? 12 : 0;
        decoded->kind = AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = is_64 ? 64 : 32;
        decoded->flags = (((instruction >> 30) & 1) ? 1 : 0) |
            (((instruction >> 29) & 1) ? 2 : 0);
        decoded->immediate = (int64_t)(imm << shift);
        return 1;
    }

    switch (instruction & UINT32_C(0xffc00000)) {
    case UINT32_C(0x39000000):
    case UINT32_C(0x39400000):
    case UINT32_C(0x39800000):
    case UINT32_C(0x39c00000):
    case UINT32_C(0x79000000):
    case UINT32_C(0x79400000):
    case UINT32_C(0x79800000):
    case UINT32_C(0x79c00000):
    case UINT32_C(0xb9000000):
    case UINT32_C(0xb9400000):
    case UINT32_C(0xb9800000):
    case UINT32_C(0xf9000000):
    case UINT32_C(0xf9400000):
    case UINT32_C(0xf9800000): {
        uint32_t masked = instruction & UINT32_C(0xffc00000);
        if (masked == UINT32_C(0xf9800000)) {
            decoded->kind = AVZ_NATIVE_OP_NOP;
            return 1;
        }
        uint8_t size = (instruction >> 30) & 3;
        uint8_t width = (uint8_t)(1u << size);
        uint8_t sign_extend = 0;
        uint8_t result32 = 0;
        uint8_t is_load = ((instruction >> 22) & 1) != 0;
        uint64_t imm12 = (instruction >> 10) & 0xfff;
        switch (masked) {
        case UINT32_C(0x39800000):
        case UINT32_C(0x79800000):
        case UINT32_C(0xb9800000):
            sign_extend = 1;
            is_load = 1;
            break;
        case UINT32_C(0x39c00000):
        case UINT32_C(0x79c00000):
            sign_extend = 1;
            result32 = 1;
            is_load = 1;
            break;
        default:
            break;
        }
        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8);
        decoded->flags = (is_load ? 1 : 0) |
            (sign_extend ? 2 : 0) |
            (result32 ? 4 : 0);
        decoded->immediate = (int64_t)(imm12 * width);
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0x3b000000)) == UINT32_C(0x38000000)) {
        uint8_t vector = (instruction >> 26) & 1;
        uint8_t size = (instruction >> 30) & 3;
        uint8_t opcode = (instruction >> 22) & 3;
        uint8_t mode = (instruction >> 10) & 3;
        uint8_t scale = (uint8_t)(size | ((opcode & 2u) << 1u));
        if (vector != 0 && scale <= 4 && mode != 2) {
            int64_t imm9 = sign_extend_u64((instruction >> 12) & 0x1ff, 9);
            int64_t address_offset = imm9;
            int64_t writeback_offset = 0;
            uint8_t writeback = 0;
            if (mode == 1) {
                address_offset = 0;
                writeback_offset = imm9;
                writeback = 1;
            } else if (mode == 3) {
                writeback_offset = imm9;
                writeback = 1;
            }
            decoded->kind = AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE;
            decoded->rt = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->width = (uint8_t)(1u << scale);
            decoded->bits = (uint8_t)(decoded->width * 8u);
            decoded->flags = ((opcode & 1u) != 0 ? 1 : 0) | (writeback ? 8 : 0);
            decoded->immediate = address_offset;
            decoded->immediate2 = writeback_offset;
            return 1;
        }
    }

    if (((instruction >> 26) & 1u) == 0 &&
        (instruction & UINT32_C(0x3b000000)) == UINT32_C(0x38000000) &&
        (instruction & UINT32_C(0x3b200c00)) != UINT32_C(0x38200800)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t opcode = (instruction >> 22) & 3;
        int64_t imm9 = sign_extend_u64((instruction >> 12) & 0x1ff, 9);
        uint8_t mode = (instruction >> 10) & 3;
        uint8_t width = (uint8_t)(1u << size);
        int64_t address_offset;
        int64_t writeback_offset = 0;
        uint8_t writeback = 0;

        if (opcode == 2u && size == 3u && mode == 0u) {
            decoded->kind = AVZ_NATIVE_OP_NOP;
            return 1;
        }

        switch (mode) {
        case 0:
        case 2:
            address_offset = imm9;
            break;
        case 1:
            address_offset = 0;
            writeback_offset = imm9;
            writeback = 1;
            break;
        case 3:
            address_offset = imm9;
            writeback_offset = imm9;
            writeback = 1;
            break;
        default:
            return 0;
        }

        if (opcode == 2 && size > 2) {
            return 0;
        }
        if (opcode == 3 && size > 1) {
            return 0;
        }

        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8);
        decoded->flags = (opcode != 0 ? 1 : 0) |
            (opcode >= 2 ? 2 : 0) |
            (opcode == 3 ? 4 : 0) |
            (writeback ? 8 : 0);
        decoded->immediate = address_offset;
        decoded->immediate2 = writeback_offset;
        return 1;
    }

    if ((instruction & UINT32_C(0x3f200c00)) == UINT32_C(0x3c200800)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t opcode = (instruction >> 22) & 3;
        uint8_t option = (instruction >> 13) & 7;
        uint8_t scale = (uint8_t)(size | ((opcode & 2u) << 1u));

        if (!(option == 2 || option == 3 || option == 6 || option == 7) || scale > 4) {
            return 0;
        }

        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->width = (uint8_t)(1u << scale);
        decoded->bits = (uint8_t)(decoded->width * 8u);
        decoded->condition = option;
        decoded->shift_amount = ((instruction >> 12) & 1) ? scale : 0;
        decoded->flags = opcode & 1u;
        return 1;
    }

    if ((instruction & UINT32_C(0x3b200c00)) == UINT32_C(0x38200800)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t opcode = (instruction >> 22) & 3;
        uint8_t option = (instruction >> 13) & 7;
        uint8_t shift = ((instruction >> 12) & 1) ? size : 0;
        uint8_t width = (uint8_t)(1u << size);

        if (!(option == 2 || option == 3 || option == 6 || option == 7)) {
            return 0;
        }
        if (opcode == 2 && size == 3) {
            decoded->kind = AVZ_NATIVE_OP_NOP;
            return 1;
        }
        if (opcode == 2 && size > 2) {
            return 0;
        }
        if (opcode == 3 && size > 1) {
            return 0;
        }

        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8);
        decoded->condition = option;
        decoded->shift_amount = shift;
        decoded->flags = (opcode != 0 ? 1 : 0) |
            (opcode >= 2 ? 2 : 0) |
            (opcode == 3 ? 4 : 0);
        return 1;
    }

    if ((instruction & UINT32_C(0x3fa0fc00)) == UINT32_C(0x0880fc00)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t rs = (instruction >> 16) & 0x1f;
        if (rs != 31) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = (uint8_t)(1u << size);
        decoded->bits = (uint8_t)(decoded->width * 8);
        decoded->flags = ((instruction >> 22) & 1) ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0x3fa07c00)) == UINT32_C(0x08007c00)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t rs = (instruction >> 16) & 0x1f;
        uint8_t is_load = ((instruction >> 22) & 1) != 0;
        if (is_load && rs != 31) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rd = rs;
        decoded->width = (uint8_t)(1u << size);
        decoded->bits = (uint8_t)(decoded->width * 8u);
        decoded->flags = is_load ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0x3fa00000)) == UINT32_C(0x08200000)) {
        uint8_t size = (instruction >> 30) & 3;
        uint8_t rs = (instruction >> 16) & 0x1f;
        uint8_t is_load = ((instruction >> 22) & 1) != 0;
        if (size < 2 || (is_load && rs != 31)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE_PAIR;
        decoded->rt = instruction & 0x1f;
        decoded->rd = (instruction >> 10) & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = rs;
        decoded->width = size == 2 ? 4 : 8;
        decoded->bits = (uint8_t)(decoded->width * 8u);
        decoded->flags = is_load ? 1 : 0;
        return 1;
    }

    switch (instruction & UINT32_C(0xffc00000)) {
    case UINT32_C(0x3d000000):
    case UINT32_C(0x3d400000):
    case UINT32_C(0x7d000000):
    case UINT32_C(0x7d400000):
    case UINT32_C(0xbd000000):
    case UINT32_C(0xbd400000):
    case UINT32_C(0xfd000000):
    case UINT32_C(0xfd400000):
    case UINT32_C(0x3d800000):
    case UINT32_C(0x3dc00000): {
        uint32_t masked = instruction & UINT32_C(0xffc00000);
        uint8_t width = 1;
        if (masked == UINT32_C(0x7d000000) || masked == UINT32_C(0x7d400000)) {
            width = 2;
        } else if (masked == UINT32_C(0xbd000000) || masked == UINT32_C(0xbd400000)) {
            width = 4;
        } else if (masked == UINT32_C(0xfd000000) || masked == UINT32_C(0xfd400000)) {
            width = 8;
        } else if (masked == UINT32_C(0x3d800000) || masked == UINT32_C(0x3dc00000)) {
            width = 16;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8u);
        decoded->flags = (masked & UINT32_C(0x00400000)) != 0 ? 1 : 0;
        decoded->immediate = (int64_t)((uint64_t)((instruction >> 10) & 0xfff) * width);
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0e003c00)) {
        uint32_t imm5 = (instruction >> 16) & 0x1f;
        uint32_t q = (instruction >> 30) & 1u;
        if (imm5 == 0) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        unsigned lane = imm5 >> (trailing + 1u);
        if (element_bits > 64 || (element_bits == 64) != (q != 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->condition = (uint8_t)lane;
        return 1;
    }

    if ((instruction & UINT32_C(0xffe0fc00)) == UINT32_C(0x5e000400)) {
        unsigned imm5 = (instruction >> 16) & 0x1fu;
        if (imm5 == 0u) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        unsigned lane = imm5 >> (trailing + 1u);
        if (element_bits > 64u || lane >= 128u / element_bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->condition = (uint8_t)lane;
        decoded->flags = 2u;
        return 1;
    }

    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x0e000400)) {
        unsigned imm5 = (instruction >> 16) & 0x1fu;
        unsigned q = (instruction >> 30) & 1u;
        if (imm5 == 0) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        unsigned lane = imm5 >> (trailing + 1u);
        unsigned vector_bits = q != 0 ? 128u : 64u;
        if (element_bits > 64 || element_bits > vector_bits || lane >= 128u / element_bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->condition = (uint8_t)lane;
        decoded->flags = (uint8_t)q;
        return 1;
    }

    if ((instruction & UINT32_C(0xff80fc00)) == UINT32_C(0x5f005400)) {
        unsigned encoded_shift = (instruction >> 16) & 0x7fu;
        if (encoded_shift < 64u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = 64;
        decoded->shift_amount = (uint8_t)(encoded_shift - 64u);
        return 1;
    }

    if ((instruction & UINT32_C(0xbf80fc00)) == UINT32_C(0x0f005400) ||
        (instruction & UINT32_C(0xbf80fc00)) == UINT32_C(0x2f005400)) {
        unsigned encoded_shift = (instruction >> 16) & 0x7fu;
        unsigned q = (instruction >> 30) & 1u;
        if (encoded_shift < 8u) {
            return 0;
        }
        unsigned element_bits = 64u;
        if (encoded_shift < 16u) {
            element_bits = 8u;
        } else if (encoded_shift < 32u) {
            element_bits = 16u;
        } else if (encoded_shift < 64u) {
            element_bits = 32u;
        }
        if (element_bits == 64u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->shift_amount = (uint8_t)(encoded_shift - element_bits);
        decoded->flags = (uint8_t)(q |
            ((((instruction >> 29) & 1u) != 0u) ? 2u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf80f400)) == UINT32_C(0x0f008400)) {
        unsigned encoded_shift = (instruction >> 16) & 0x7fu;
        unsigned source_bits = 0u;
        if (encoded_shift >= 8u && encoded_shift < 16u) {
            source_bits = 16u;
        } else if (encoded_shift >= 16u && encoded_shift < 32u) {
            source_bits = 32u;
        } else if (encoded_shift >= 32u && encoded_shift < 64u) {
            source_bits = 64u;
        }
        if (source_bits != 0u) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_NARROW_HIGH;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->bits = (uint8_t)source_bits;
            decoded->shift_amount = (uint8_t)(source_bits - encoded_shift);
            decoded->flags = (uint8_t)(8u |
                ((instruction >> 30) & 1u) |
                ((((instruction >> 11) & 1u) != 0u) ? 16u : 0u));
            return 1;
        }
    }

    {
        uint32_t scalar_masked = instruction & UINT32_C(0xdf80fc00);
        uint32_t vector_masked = instruction & UINT32_C(0x9f80fc00);
        int is_scalar = scalar_masked == UINT32_C(0x5f000400) ||
            scalar_masked == UINT32_C(0x5f001400) ||
            scalar_masked == UINT32_C(0x5f002400) ||
            scalar_masked == UINT32_C(0x5f003400);
        int is_vector = vector_masked == UINT32_C(0x0f000400) ||
            vector_masked == UINT32_C(0x0f001400) ||
            vector_masked == UINT32_C(0x0f002400) ||
            vector_masked == UINT32_C(0x0f003400) ||
            vector_masked == UINT32_C(0x0f004400);
        if (is_scalar || is_vector) {
            unsigned encoded_shift = (instruction >> 16) & 0x7fu;
            unsigned element_bits = 64u;
            if (encoded_shift < 8u) {
                element_bits = 0u;
            } else if (encoded_shift < 16u) {
                element_bits = 8u;
            } else if (encoded_shift < 32u) {
                element_bits = 16u;
            } else if (encoded_shift < 64u) {
                element_bits = 32u;
            }
            unsigned q = (instruction >> 30) & 1u;
            if (element_bits != 0u &&
                (!is_scalar || element_bits == 64u) &&
                (!is_vector || element_bits != 64u || q != 0u)) {
                decoded->kind = AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE;
                decoded->rd = instruction & 0x1f;
                decoded->rn = (instruction >> 5) & 0x1f;
                decoded->bits = (uint8_t)element_bits;
                decoded->shift_amount = (uint8_t)(element_bits * 2u - encoded_shift);
                uint32_t operation = is_scalar ? scalar_masked : vector_masked;
                decoded->flags = (uint8_t)((is_vector && q != 0u ? 1u : 0u) |
                    (((instruction >> 29) & 1u) != 0 ? 2u : 0u) |
                    (is_scalar ? 4u : 0u) |
                    (operation == UINT32_C(0x0f004400) ? 8u : 0u) |
                    ((operation == UINT32_C(0x0f002400) ||
                      operation == UINT32_C(0x0f003400) ||
                      operation == UINT32_C(0x5f002400) ||
                      operation == UINT32_C(0x5f003400)) ? 16u : 0u) |
                    ((operation == UINT32_C(0x0f001400) ||
                      operation == UINT32_C(0x0f003400) ||
                      operation == UINT32_C(0x5f001400) ||
                      operation == UINT32_C(0x5f003400)) ? 32u : 0u));
                return 1;
            }
        }
    }

    if ((instruction & UINT32_C(0x9f3efc00)) == UINT32_C(0x0e30a800)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u || (size == 2u && q == 0u)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(q |
            ((((instruction >> 29) & 1u) != 0) ? 4u : 0u) |
            8u |
            ((((instruction >> 16) & 1u) != 0) ? 16u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf3ffc00)) == UINT32_C(0x0e31b800)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2 || (size == 2 && q == 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)q;
        return 1;
    }

    if ((instruction & UINT32_C(0x9f3ffc00)) == UINT32_C(0x0e303800)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u || (size == 2u && q == 0u)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(q | 2u |
            ((((instruction >> 29) & 1u) != 0) ? 4u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0x9f3ffc00)) == UINT32_C(0x0e202800)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf200000)) == UINT32_C(0x0d000000)) {
        unsigned post_index = (instruction >> 23) & 1u;
        unsigned offset_register = (instruction >> 16) & 0x1f;
        unsigned opcode = (instruction >> 13) & 7u;
        unsigned s = (instruction >> 12) & 1u;
        unsigned size = (instruction >> 10) & 3u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned width;
        unsigned lane;

        if (!post_index && offset_register != 0) {
            return 0;
        }
        if (opcode == 0) {
            width = 1;
            lane = (q << 3) | (s << 2) | size;
        } else if (opcode == 2 && (size & 1u) == 0) {
            width = 2;
            lane = (q << 2) | (s << 1) | (size >> 1);
        } else if (opcode == 4 && size == 0) {
            width = 4;
            lane = (q << 1) | s;
        } else if (opcode == 4 && size == 1 && s == 0) {
            width = 8;
            lane = q;
        } else {
            return 0;
        }

        decoded->kind = AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = offset_register;
        decoded->width = (uint8_t)width;
        decoded->bits = (uint8_t)(width * 8u);
        decoded->condition = (uint8_t)lane;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (post_index != 0 ? 8u : 0u) |
            (post_index != 0 && offset_register != 31 ? 16u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf200000)) == UINT32_C(0x0c000000)) {
        unsigned post_index = (instruction >> 23) & 1u;
        unsigned offset_register = (instruction >> 16) & 0x1f;
        unsigned opcode = (instruction >> 12) & 0xfu;
        unsigned register_count;

        switch (opcode) {
        case 0:
            register_count = 4;
            break;
        case 4:
            register_count = 3;
            break;
        case 8:
            register_count = 2;
            break;
        case 7:
            register_count = 1;
            break;
        case 10:
            register_count = 2;
            break;
        case 6:
            register_count = 3;
            break;
        case 2:
            register_count = 4;
            break;
        default:
            return 0;
        }
        if (!post_index && offset_register != 0) {
            return 0;
        }

        decoded->kind = AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE;
        decoded->rt = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = offset_register;
        decoded->width = ((instruction >> 30) & 1u) != 0 ? 16 : 8;
        decoded->bits = (uint8_t)(8u << ((instruction >> 10) & 3u));
        decoded->condition = (uint8_t)register_count;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (post_index != 0 ? 8u : 0u) |
            (post_index != 0 && offset_register != 31 ? 16u : 0u) |
            ((opcode == 0 || opcode == 4 || opcode == 8) ? 32u : 0u));
        return 1;
    }

    switch (instruction & UINT32_C(0xfffffc00)) {
    case UINT32_C(0x1e270000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 0;
        return 1;
    case UINT32_C(0x1e260000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 1;
        return 1;
    case UINT32_C(0x9e670000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 2;
        return 1;
    case UINT32_C(0x9e660000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 3;
        return 1;
    case UINT32_C(0x9eaf0000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 4;
        return 1;
    case UINT32_C(0x9eae0000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 5;
        return 1;
    case UINT32_C(0x1e204000):
    case UINT32_C(0x1e604000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = ((instruction >> 22) & 1) ? 1 : 0;
        return 1;
    case UINT32_C(0x1e624000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 0;
        return 1;
    case UINT32_C(0x1e22c000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = 1;
        return 1;
    case UINT32_C(0x1e20c000):
    case UINT32_C(0x1e60c000):
    case UINT32_C(0x1e214000):
    case UINT32_C(0x1e614000):
    case UINT32_C(0x1e21c000):
    case UINT32_C(0x1e61c000): {
        uint32_t masked = instruction & UINT32_C(0xfffffc00);
        uint8_t operation = 0;
        if (masked == UINT32_C(0x1e214000) || masked == UINT32_C(0x1e614000)) {
            operation = 1;
        } else if (masked == UINT32_C(0x1e21c000) || masked == UINT32_C(0x1e61c000)) {
            operation = 2;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_UNARY;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)(operation | (((instruction >> 22) & 1u) != 0 ? 4u : 0u));
        return 1;
    }
    case UINT32_C(0x1e244000):
    case UINT32_C(0x1e644000):
    case UINT32_C(0x1e24c000):
    case UINT32_C(0x1e64c000):
    case UINT32_C(0x1e254000):
    case UINT32_C(0x1e654000):
    case UINT32_C(0x1e25c000):
    case UINT32_C(0x1e65c000):
    case UINT32_C(0x1e264000):
    case UINT32_C(0x1e664000):
    case UINT32_C(0x1e274000):
    case UINT32_C(0x1e674000):
    case UINT32_C(0x1e27c000):
    case UINT32_C(0x1e67c000): {
        uint32_t masked = instruction & UINT32_C(0xfffffc00);
        unsigned operation;
        if (masked == UINT32_C(0x1e244000) || masked == UINT32_C(0x1e644000)) {
            operation = 1;
        } else if (masked == UINT32_C(0x1e24c000) || masked == UINT32_C(0x1e64c000)) {
            operation = 2;
        } else if (masked == UINT32_C(0x1e254000) || masked == UINT32_C(0x1e654000)) {
            operation = 3;
        } else if (masked == UINT32_C(0x1e25c000) || masked == UINT32_C(0x1e65c000)) {
            operation = 0;
        } else if (masked == UINT32_C(0x1e264000) || masked == UINT32_C(0x1e664000)) {
            operation = 4;
        } else {
            operation = 5;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)(operation | (((instruction >> 22) & 1u) != 0 ? 8u : 0u));
        return 1;
    }
    case UINT32_C(0x5e21d800):
    case UINT32_C(0x5e61d800):
    case UINT32_C(0x7e21d800):
    case UINT32_C(0x7e61d800):
        decoded->kind = AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u));
        return 1;
    default:
        break;
    }

    switch (instruction & UINT32_C(0xbffffc00)) {
    case UINT32_C(0x0e616800): /* FCVTN/FCVTN2 */
    case UINT32_C(0x0e617800): /* FCVTL/FCVTL2 */
        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_CONVERT_NARROW_WIDEN;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)(
            (((instruction & UINT32_C(0x00001000)) != 0u) ? 1u : 0u) |
            ((((instruction >> 30) & 1u) != 0u) ? 2u : 0u)
        );
        return 1;
    case UINT32_C(0x0e21d800):
    case UINT32_C(0x0e61d800):
    case UINT32_C(0x2e21d800):
    case UINT32_C(0x2e61d800): {
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)(is_double |
            ((((instruction >> 29) & 1u) != 0u) ? 2u : 0u) |
            4u | (q << 3));
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0xffe01fe0)) == UINT32_C(0x1e201000) ||
        (instruction & UINT32_C(0xffe01fe0)) == UINT32_C(0x1e601000)) {
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE;
        decoded->rd = instruction & 0x1f;
        decoded->immediate = (instruction >> 13) & 0xff;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1u : 0u;
        return 1;
    }

    switch (instruction & UINT32_C(0x7f3f0000)) {
    case UINT32_C(0x1e020000):
    case UINT32_C(0x1e030000): {
        unsigned source_bits = ((instruction >> 31) & 1u) != 0 ? 64u : 32u;
        unsigned fractional_bits = 64u - ((instruction >> 10) & 0x3fu);
        if (fractional_bits == 0 || fractional_bits > source_bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->shift_amount = (uint8_t)fractional_bits;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 31) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 16) & 1u) != 0 ? 4u : 0u));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0x7fbffc00)) {
    case UINT32_C(0x1e220000):
    case UINT32_C(0x1e230000):
        decoded->kind = AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 31) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 16) & 1u) != 0 ? 4u : 0u));
        return 1;
    default:
        break;
    }

    if ((instruction & UINT32_C(0xff800000)) == UINT32_C(0x1f000000)) {
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rt = (instruction >> 10) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 15) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 21) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 22) & 1u) != 0 ? 4u : 0u));
        return 1;
    }

    switch (instruction & UINT32_C(0xffe0fc00)) {
    case UINT32_C(0x7ea0d400):
    case UINT32_C(0x7ee0d400):
        decoded->kind = AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1u : 0u;
        return 1;
    default:
        break;
    }

    if ((instruction & UINT32_C(0x9f20f400)) == UINT32_C(0x0e206400)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size == 3u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(((instruction >> 30) & 1u) |
            ((((instruction >> 29) & 1u) != 0u) ? 2u : 0u) |
            ((((instruction >> 11) & 1u) != 0u) ? 4u : 0u));
        return 1;
    }

    switch (instruction & UINT32_C(0xbfa0fc00)) {
    case UINT32_C(0x0e20c400):
    case UINT32_C(0x0ea0c400):
    case UINT32_C(0x0e20f400):
    case UINT32_C(0x0ea0f400): {
        uint32_t masked = instruction & UINT32_C(0xbfa0fc00);
        unsigned operation = masked == UINT32_C(0x0e20c400) ? 0u
            : masked == UINT32_C(0x0ea0c400) ? 1u
            : masked == UINT32_C(0x0e20f400) ? 2u : 3u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_MINMAX;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)(operation | (is_double << 2) | 8u | (q << 4));
        return 1;
    }
    default:
        break;
    }

    /* FRECPE/FRSQRTE, scalar and vector single/double-precision forms. */
    switch (instruction & UINT32_C(0xbfbffc00)) {
    case UINT32_C(0x0ea1d800):
    case UINT32_C(0x2ea1d800): {
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 29) & 1u) != 0u ? 1u : 0u) |
            (is_double << 1) | 4u | (q << 3));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffbffc00)) {
    case UINT32_C(0x5ea1d800):
    case UINT32_C(0x7ea1d800):
        decoded->kind = AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 29) & 1u) != 0u ? 1u : 0u) |
            ((((instruction >> 22) & 1u) != 0u) ? 2u : 0u));
        return 1;
    default:
        break;
    }

    /* FRECPS/FRSQRTS, scalar and vector single/double-precision forms. */
    switch (instruction & UINT32_C(0xbfa0fc00)) {
    case UINT32_C(0x0e20fc00):
    case UINT32_C(0x0ea0fc00): {
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_RECIPROCAL_STEP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 23) & 1u) != 0u ? 1u : 0u) |
            (is_double << 1) | 4u | (q << 3));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffa0fc00)) {
    case UINT32_C(0x5e20fc00):
    case UINT32_C(0x5ea0fc00):
        decoded->kind = AVZ_NATIVE_OP_FP_RECIPROCAL_STEP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 23) & 1u) != 0u ? 1u : 0u) |
            ((((instruction >> 22) & 1u) != 0u) ? 2u : 0u));
        return 1;
    default:
        break;
    }

    /* FMLA/FMLS (vector), for the base single- and double-precision forms. */
    switch (instruction & UINT32_C(0xbfa0fc00)) {
    case UINT32_C(0x0e20cc00):
    case UINT32_C(0x0ea0cc00): {
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->rt = decoded->rd;
        decoded->bits = (uint8_t)(is_double != 0u ? 64u : 32u);
        decoded->flags = (uint8_t)((((instruction >> 23) & 1u) != 0u ? 1u : 0u) |
            (is_double << 2) | 8u | (q << 4));
        return 1;
    }
    default:
        break;
    }

    /* FABS/FNEG/FSQRT (vector), excluding the separate FP16 encodings. */
    switch (instruction & UINT32_C(0xbfbffc00)) {
    case UINT32_C(0x0ea0f800):
    case UINT32_C(0x2ea0f800):
    case UINT32_C(0x2ea1f800): {
        uint32_t masked = instruction & UINT32_C(0xbfbffc00);
        unsigned operation = masked == UINT32_C(0x0ea0f800) ? 0u
            : masked == UINT32_C(0x2ea0f800) ? 1u : 2u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_UNARY;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(is_double != 0u ? 64u : 32u);
        decoded->flags = (uint8_t)(operation | (is_double << 2) | 8u | (q << 4));
        return 1;
    }
    default:
        break;
    }

    /*
     * FMLA/FMLS (vector, by element): fuse each destination lane with Vn and
     * one selected FP element from Vm. FP16 and scalar forms stay excluded.
     * Private flags on the existing fused-operation kind are:
     *   bit 0: subtract product (FMLS)
     *   bit 2: double precision
     *   bit 3: vector form
     *   bit 4: Q
     *   bit 5: selected-element source
     */
    if ((instruction & UINT32_C(0xbf00b400)) == UINT32_C(0x0f001000)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned l = (instruction >> 21) & 1u;
        unsigned h = (instruction >> 11) & 1u;
        unsigned element_bits = 0u;
        unsigned source_lane = 0u;

        if (size == 2u) {
            element_bits = 32u;
            source_lane = (h << 1) | l;
        } else if (size == 3u && q != 0u && l == 0u) {
            element_bits = 64u;
            source_lane = h;
        }

        if (element_bits != 0u) {
            decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->rm = (instruction >> 16) & 0x1f;
            decoded->rt = decoded->rd;
            decoded->bits = (uint8_t)element_bits;
            decoded->condition = (uint8_t)source_lane;
            decoded->flags = (uint8_t)((((instruction >> 14) & 1u) != 0u ? 1u : 0u) |
                (element_bits == 64u ? 4u : 0u) | 8u | (q << 4) | 32u);
            return 1;
        }
    }

    /*
     * FMUL (vector, by element): multiply every FP lane in Vn by one selected
     * FP element from Vm.  Only the base Armv8 single- and double-precision
     * arrangements are accepted here; FP16, scalar by-element forms, and
     * FMULX remain outside this narrowly gated family.
     *
     * Reuse AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC so the existing Swift ABI and
     * vector-state classification remain unchanged. Private flag bit 5 marks
     * the by-element vector form; condition carries the selected source lane.
     */
    if ((instruction & UINT32_C(0xbf80f400)) == UINT32_C(0x0f809000)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned l = (instruction >> 21) & 1u;
        unsigned h = (instruction >> 11) & 1u;
        unsigned element_bits = 0u;
        unsigned source_lane = 0u;

        if (size == 2u) {
            element_bits = 32u;
            source_lane = (h << 1) | l;
        } else if (size == 3u && q != 0u && l == 0u) {
            /* The D form is 2D only and uses H as its one-bit lane index. */
            element_bits = 64u;
            source_lane = h;
        }

        if (element_bits != 0u) {
            decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->rm = (instruction >> 16) & 0x1f;
            decoded->bits = (uint8_t)element_bits;
            decoded->condition = (uint8_t)source_lane;
            decoded->flags = (uint8_t)(2u | ((element_bits == 64u) ? 4u : 0u) |
                8u | (q << 4) | 32u);
            return 1;
        }
        /* Neighboring encodings continue through the existing decoder. */
    }

    switch (instruction & UINT32_C(0xbfa0fc00)) {
    case UINT32_C(0x0e20d400):
    case UINT32_C(0x0ea0d400):
    case UINT32_C(0x2e20dc00):
    case UINT32_C(0x2e20fc00): {
        uint32_t masked = instruction & UINT32_C(0xbfa0fc00);
        unsigned operation = masked == UINT32_C(0x0e20d400) ? 0u
            : masked == UINT32_C(0x0ea0d400) ? 1u
            : masked == UINT32_C(0x2e20dc00) ? 2u : 3u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)(operation | (is_double << 2) | 8u | (q << 4));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffe0fc00)) {
    case UINT32_C(0x1e202800):
    case UINT32_C(0x1e602800):
    case UINT32_C(0x1e203800):
    case UINT32_C(0x1e603800):
    case UINT32_C(0x1e200800):
    case UINT32_C(0x1e600800):
    case UINT32_C(0x1e201800):
    case UINT32_C(0x1e601800): {
        uint8_t operation = 0;
        uint32_t masked = instruction & UINT32_C(0xffe0fc00);
        if (masked == UINT32_C(0x1e203800) || masked == UINT32_C(0x1e603800)) {
            operation = 1;
        } else if (masked == UINT32_C(0x1e200800) || masked == UINT32_C(0x1e600800)) {
            operation = 2;
        } else if (masked == UINT32_C(0x1e201800) || masked == UINT32_C(0x1e601800)) {
            operation = 3;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = operation | (((instruction >> 22) & 1u) != 0 ? 4u : 0u);
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffe0fc00)) {
    case UINT32_C(0x1e206800):
    case UINT32_C(0x1e606800):
    case UINT32_C(0x1e207800):
    case UINT32_C(0x1e607800):
    case UINT32_C(0x1e204800):
    case UINT32_C(0x1e604800):
    case UINT32_C(0x1e205800):
    case UINT32_C(0x1e605800): {
        uint32_t masked = instruction & UINT32_C(0xffe0fc00);
        uint8_t operation;
        if (masked == UINT32_C(0x1e206800) || masked == UINT32_C(0x1e606800)) {
            operation = 0; // FMAXNM
        } else if (masked == UINT32_C(0x1e207800) || masked == UINT32_C(0x1e607800)) {
            operation = 1; // FMINNM
        } else if (masked == UINT32_C(0x1e204800) || masked == UINT32_C(0x1e604800)) {
            operation = 2; // FMAX
        } else {
            operation = 3; // FMIN
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_MINMAX;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = operation | (((instruction >> 22) & 1u) != 0 ? 4u : 0u);
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffe0fc00)) {
    case UINT32_C(0x1e208800):
    case UINT32_C(0x1e608800):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1u : 0u;
        return 1;
    default:
        break;
    }

    if ((instruction & UINT32_C(0xffe00c00)) == UINT32_C(0x1e200c00) ||
        (instruction & UINT32_C(0xffe00c00)) == UINT32_C(0x1e600c00)) {
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_SELECT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->condition = (instruction >> 12) & 0xf;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1 : 0;
        return 1;
    }

    if ((instruction & UINT32_C(0xff200c00)) == UINT32_C(0x1e200400)) {
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->condition = (instruction >> 12) & 0xf;
        decoded->immediate = instruction & 0xf;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 4) & 1u) != 0 ? 2u : 0u));
        return 1;
    }

    switch (instruction & UINT32_C(0xffe0fc1f)) {
    case UINT32_C(0x1e202008):
    case UINT32_C(0x1e202018):
    case UINT32_C(0x1e602008):
    case UINT32_C(0x1e602018):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_COMPARE;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) | 2u);
        return 1;
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffe0fc1f)) {
    case UINT32_C(0x1e202000):
    case UINT32_C(0x1e202010):
    case UINT32_C(0x1e602000):
    case UINT32_C(0x1e602010):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_COMPARE;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1 : 0;
        return 1;
    default:
        break;
    }

    switch (instruction & UINT32_C(0x7f3f0000)) {
    case UINT32_C(0x1e180000):
    case UINT32_C(0x1e190000): {
        unsigned destination_bits =
            ((instruction >> 31) & 1u) != 0 ? 64u : 32u;
        unsigned fractional_bits =
            64u - ((instruction >> 10) & 0x3fu);
        if (fractional_bits == 0u ||
            fractional_bits > destination_bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)destination_bits;
        decoded->shift_amount = (uint8_t)fractional_bits;
        decoded->flags = (uint8_t)(
            (((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 16) & 1u) != 0 ? 4u : 0u)
        );
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0x7f3ffc00)) {
    case UINT32_C(0x1e200000):
    case UINT32_C(0x1e210000):
    case UINT32_C(0x1e280000):
    case UINT32_C(0x1e290000):
    case UINT32_C(0x1e300000):
    case UINT32_C(0x1e310000):
    case UINT32_C(0x1e240000):
    case UINT32_C(0x1e250000):
    case UINT32_C(0x1e380000):
    case UINT32_C(0x1e390000): {
        uint32_t masked = instruction & UINT32_C(0x7f3ffc00);
        unsigned rounding_mode;
        if (masked == UINT32_C(0x1e200000) || masked == UINT32_C(0x1e210000)) {
            rounding_mode = 1;
        } else if (masked == UINT32_C(0x1e280000) || masked == UINT32_C(0x1e290000)) {
            rounding_mode = 2;
        } else if (masked == UINT32_C(0x1e300000) || masked == UINT32_C(0x1e310000)) {
            rounding_mode = 3;
        } else if (masked == UINT32_C(0x1e240000) || masked == UINT32_C(0x1e250000)) {
            rounding_mode = 4;
        } else {
            rounding_mode = 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1u) != 0 ? 64 : 32;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 16) & 1u) != 0 ? 4u : 0u) |
            (rounding_mode << 4));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xfffffc00)) {
    case UINT32_C(0x5ea1b800):
    case UINT32_C(0x5ee1b800):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 22) & 1u) != 0 ? 64 : 32;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) | 8u);
        return 1;
    case UINT32_C(0x7ea1b800):
    case UINT32_C(0x7ee1b800):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 22) & 1u) != 0 ? 64 : 32;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) | 4u | 8u);
        return 1;
    case UINT32_C(0x1e390000):
    case UINT32_C(0x1e790000):
    case UINT32_C(0x9e390000):
    case UINT32_C(0x9e790000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1u) != 0 ? 64 : 32;
        decoded->flags = (uint8_t)((((instruction >> 22) & 1u) != 0 ? 1u : 0u) | 4u);
        return 1;
    case UINT32_C(0x1e380000):
    case UINT32_C(0x1e780000):
    case UINT32_C(0x9e380000):
    case UINT32_C(0x9e780000):
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = ((instruction >> 31) & 1u) != 0 ? 64 : 32;
        decoded->flags = ((instruction >> 22) & 1u) != 0 ? 1u : 0u;
        return 1;
    default:
        break;
    }

    /* AdvSIMD FCVT[NPMZA][SU], with an opcode-encoded rounding mode. */
    switch (instruction & UINT32_C(0x9fbffc00)) {
    case UINT32_C(0x0e21a800):
    case UINT32_C(0x0ea1a800):
    case UINT32_C(0x0e21b800):
    case UINT32_C(0x0ea1b800):
    case UINT32_C(0x0e21c800): {
        uint32_t masked = instruction & UINT32_C(0x9fbffc00);
        unsigned rounding_mode = masked == UINT32_C(0x0e21a800) ? 1u
            : masked == UINT32_C(0x0ea1a800) ? 2u
            : masked == UINT32_C(0x0e21b800) ? 3u
            : masked == UINT32_C(0x0ea1b800) ? 0u : 4u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(is_double != 0u ? 64u : 32u);
        decoded->flags = (uint8_t)(is_double |
            ((((instruction >> 29) & 1u) != 0u) ? 2u : 0u) |
            (q << 2) | (rounding_mode << 3));
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0xffe0fc00)) == UINT32_C(0x4e001c00)) {
        uint32_t imm5 = (instruction >> 16) & 0x1f;
        if (imm5 == 0) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        unsigned lane = imm5 >> (trailing + 1u);
        if (element_bits > 64 || lane >= 128 / element_bits) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_INSERT_GENERAL_TO_ELEMENT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->condition = (uint8_t)lane;
        return 1;
    }

    if ((instruction & UINT32_C(0xff208400)) == UINT32_C(0x6e000400)) {
        unsigned imm5 = (instruction >> 16) & 0x1fu;
        unsigned imm4 = (instruction >> 11) & 0x0fu;
        if (imm5 == 0u) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        unsigned destination_lane = imm5 >> (trailing + 1u);
        unsigned source_lane = imm4 >> trailing;
        unsigned lane_count = 128u / element_bits;
        if (element_bits > 64u || (imm4 & ((1u << trailing) - 1u)) != 0u ||
            destination_lane >= lane_count || source_lane >= lane_count) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->condition = (uint8_t)destination_lane;
        decoded->shift_amount = (uint8_t)source_lane;
        return 1;
    }

    /*
     * SSHLL/SSHLL2 and USHLL/USHLL2 (shift left long by immediate).
     *
     * immh:immb encodes both the source element width and shift:
     *   0b0001xxx =>  8-bit source, shift 0...7
     *   0b001xxxx => 16-bit source, shift 0...15
     *   0b01xxxxx => 32-bit source, shift 0...31
     * Values with no set immh bit or a 64-bit source are reserved because
     * widening would require a 128-bit destination element.
     *
     * Preserve the legacy decoded representation for the already-supported
     * 32->64, shift 0...7 encodings so existing cache/decoder parity remains
     * byte-for-byte stable. New variants set bits to the source element width.
     */
    if ((instruction & UINT32_C(0x9f80fc00)) == UINT32_C(0x0f00a400)) {
        unsigned encoded_shift = (instruction >> 16) & 0x7fu;
        unsigned source_bits = 0u;

        if (encoded_shift >= 32u && encoded_shift < 64u) {
            source_bits = 32u;
        } else if (encoded_shift >= 16u && encoded_shift < 32u) {
            source_bits = 16u;
        } else if (encoded_shift >= 8u && encoded_shift < 16u) {
            source_bits = 8u;
        }

        if (source_bits != 0u) {
            unsigned shift = encoded_shift - source_bits;
            unsigned source_lane_count = 64u / source_bits;
            unsigned upper_half = (instruction >> 30) & 1u;

            decoded->kind = AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->flags = (uint8_t)((instruction >> 29) & 1u);
            decoded->shift_amount = (uint8_t)shift;
            decoded->condition = (uint8_t)(upper_half ? source_lane_count : 0u);

            if (!(source_bits == 32u && shift < 8u)) {
                decoded->bits = (uint8_t)source_bits;
            }
            return 1;
        }
    }

    /*
     * SHLL/SHLL2 widen unsigned lanes and shift each result by the complete
     * source element width. This is a separate two-register encoding from
     * USHLL even though both operations share the same widening datapath.
     */
    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x2e203800)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size < 3u) {
            unsigned source_bits = 8u << size;
            unsigned source_lane_count = 64u / source_bits;
            unsigned upper_half = (instruction >> 30) & 1u;

            decoded->kind = AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->bits = (uint8_t)source_bits;
            decoded->flags = 1u;
            decoded->shift_amount = (uint8_t)source_bits;
            decoded->condition = (uint8_t)(upper_half ? source_lane_count : 0u);
            return 1;
        }
    }

    if ((instruction & UINT32_C(0xbfe08400)) == UINT32_C(0x2e000000)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned byte_offset = (instruction >> 11) & 0x0fu;
        if (q == 0u && byte_offset >= 8u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->shift_amount = (uint8_t)byte_offset;
        decoded->flags = (uint8_t)q;
        return 1;
    }

    if ((instruction & UINT32_C(0xbfe08c00)) == UINT32_C(0x0e000000)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_TABLE_LOOKUP;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->condition = (uint8_t)(((instruction >> 13) & 3u) + 1u);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 12) & 1u) != 0 ? 2u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf200c00)) == UINT32_C(0x0e000800)) {
        unsigned op = (instruction >> 12) & 7u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned element_bits = 8u << size;
        unsigned vector_bits = q != 0 ? 128u : 64u;
        if (op == 0 || op == 4 || element_bits > vector_bits / 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_PERMUTE_TWO_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)op;
        decoded->condition = (uint8_t)q;
        return 1;
    }

    /*
     * SADDL/UADDL/SSUBL/USUBL and SADDW/UADDW/SSUBW/USUBW. Private flag bit
     * 2 marks widening, bit 3 selects unsigned extension, and bit 4 indicates
     * that Rn already contains widened elements (the *W forms).
     */
    if ((instruction & UINT32_C(0x9f20cc00)) == UINT32_C(0x0e200000)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0u ? 1u : 0u) |
            (((instruction >> 13) & 1u) != 0u ? 2u : 0u) |
            4u |
            (((instruction >> 29) & 1u) != 0u ? 8u : 0u) |
            (((instruction >> 12) & 1u) != 0u ? 16u : 0u));
        return 1;
    }

    /* ADD/SUB (Advanced SIMD scalar): the only allocated element is D. */
    if ((instruction & UINT32_C(0xdf20fc00)) == UINT32_C(0x5e208400)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size != 3u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = 64;
        decoded->flags = (uint8_t)((((instruction >> 29) & 1u) != 0u) ? 2u : 0u);
        return 1;
    }

    if ((instruction & UINT32_C(0x9f20fc00)) == UINT32_C(0x0e208400)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned subtract = (instruction >> 29) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned element_bits = 8u << size;
        if (element_bits > 64 || (element_bits == 64 && q == 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ADD_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q | (subtract << 1));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x2e204400)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned element_bits = 8u << size;
        if (element_bits > 64 || (element_bits == 64 && q == 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)q;
        return 1;
    }

    switch (instruction & UINT32_C(0xbfbffc00)) {
    case UINT32_C(0x0e218800):
    case UINT32_C(0x0ea18800):
    case UINT32_C(0x0e219800):
    case UINT32_C(0x0ea19800):
    case UINT32_C(0x2e218800):
    case UINT32_C(0x2e219800):
    case UINT32_C(0x2ea19800): {
        uint32_t masked = instruction & UINT32_C(0xbfbffc00);
        unsigned operation;
        if (masked == UINT32_C(0x0e218800)) {
            operation = 1u; /* FRINTN */
        } else if (masked == UINT32_C(0x0ea18800)) {
            operation = 2u; /* FRINTP */
        } else if (masked == UINT32_C(0x0e219800)) {
            operation = 3u; /* FRINTM */
        } else if (masked == UINT32_C(0x0ea19800)) {
            operation = 0u; /* FRINTZ */
        } else if (masked == UINT32_C(0x2e218800)) {
            operation = 4u; /* FRINTA */
        } else {
            operation = 5u; /* FRINTX/FRINTI: same numerical result */
        }
        unsigned q = (instruction >> 30) & 1u;
        unsigned is_double = (instruction >> 22) & 1u;
        if (is_double != 0u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)(operation | (is_double << 3) | 16u | (q << 5));
        return 1;
    }
    default:
        break;
    }

    {
        uint32_t masked = instruction & UINT32_C(0xbf3ffc00);
        unsigned container_bits = 0u;
        unsigned maximum_size = 0u;
        if (masked == UINT32_C(0x0e201800)) {
            container_bits = 16u;
            maximum_size = 0u;
        } else if (masked == UINT32_C(0x2e200800)) {
            container_bits = 32u;
            maximum_size = 1u;
        } else if (masked == UINT32_C(0x0e200800)) {
            container_bits = 64u;
            maximum_size = 2u;
        }
        if (container_bits != 0u) {
            unsigned size = (instruction >> 22) & 3u;
            if (size > maximum_size) {
                return 0;
            }
            decoded->kind = AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->bits = (uint8_t)(8u << size);
            decoded->shift_amount = (uint8_t)container_bits;
            decoded->flags = (uint8_t)((instruction >> 30) & 1u);
            return 1;
        }
    }

    if ((instruction & UINT32_C(0x9f20fc00)) == UINT32_C(0x0e208c00)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned test_bits = ((instruction >> 29) & 1u) == 0;
        unsigned size = (instruction >> 22) & 3u;
        unsigned element_bits = 8u << size;
        if (element_bits > 64 || (element_bits == 64 && q == 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q | (test_bits << 1));
        return 1;
    }

    switch (instruction & UINT32_C(0xbf20fc00)) {
    case UINT32_C(0x0e209800):
    case UINT32_C(0x0e208800):
    case UINT32_C(0x2e208800):
    case UINT32_C(0x0e20a800):
    case UINT32_C(0x2e209800): {
        uint32_t masked = instruction & UINT32_C(0xbf20fc00);
        unsigned comparison;
        if (masked == UINT32_C(0x0e209800)) {
            comparison = 4; // CMEQ #0
        } else if (masked == UINT32_C(0x0e208800)) {
            comparison = 5; // CMGT #0
        } else if (masked == UINT32_C(0x2e208800)) {
            comparison = 6; // CMGE #0
        } else if (masked == UINT32_C(0x0e20a800)) {
            comparison = 7; // CMLT #0
        } else {
            comparison = 8; // CMLE #0
        }
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = 8u << ((instruction >> 22) & 3u);
        if (element_bits > 64u || (element_bits == 64u && q == 0u)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q | (comparison << 1));
        return 1;
    }
    default:
        break;
    }

    /* Integer compare with zero (Advanced SIMD scalar, 64-bit D forms). */
    switch (instruction & UINT32_C(0xfffffc00)) {
    case UINT32_C(0x5ee09800): /* CMEQ */
    case UINT32_C(0x5ee08800): /* CMGT */
    case UINT32_C(0x7ee08800): /* CMGE */
    case UINT32_C(0x5ee0a800): /* CMLT */
    case UINT32_C(0x7ee09800): { /* CMLE */
        uint32_t masked = instruction & UINT32_C(0xfffffc00);
        unsigned comparison;
        if (masked == UINT32_C(0x5ee09800)) {
            comparison = 4u;
        } else if (masked == UINT32_C(0x5ee08800)) {
            comparison = 5u;
        } else if (masked == UINT32_C(0x7ee08800)) {
            comparison = 6u;
        } else if (masked == UINT32_C(0x5ee0a800)) {
            comparison = 7u;
        } else {
            comparison = 8u;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = 64;
        decoded->flags = (uint8_t)(comparison << 1);
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0x9f20f400)) == UINT32_C(0x0e203400)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned compare_or_same = (instruction >> 11) & 1u;
        unsigned is_unsigned = (instruction >> 29) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned element_bits = 8u << size;
        if (element_bits > 64 || (element_bits == 64 && q == 0)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        unsigned comparison = is_unsigned != 0
            ? 2u + compare_or_same
            : 9u + compare_or_same;
        decoded->flags = (uint8_t)(q | (comparison << 1));
        return 1;
    }

    switch (instruction & UINT32_C(0xbfa0fc00)) {
    case UINT32_C(0x0e20e400): /* FCMEQ */
    case UINT32_C(0x2ea0e400): /* FCMGT */
    case UINT32_C(0x2e20e400): /* FCMGE */
    case UINT32_C(0x2ea0ec00): /* FACGT */
    case UINT32_C(0x2e20ec00): { /* FACGE */
        uint32_t masked = instruction & UINT32_C(0xbfa0fc00);
        unsigned comparison;
        if (masked == UINT32_C(0x0e20e400)) {
            comparison = 0u;
        } else if (masked == UINT32_C(0x2ea0e400)) {
            comparison = 1u;
        } else if (masked == UINT32_C(0x2e20e400)) {
            comparison = 2u;
        } else if (masked == UINT32_C(0x2ea0ec00)) {
            comparison = 3u;
        } else {
            comparison = 4u;
        }
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = ((instruction >> 22) & 1u) != 0u ? 64u : 32u;
        if (element_bits == 64u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q | (comparison << 1));
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xbfbffc00)) {
    case UINT32_C(0x0ea0d800): /* FCMEQ #0 */
    case UINT32_C(0x0ea0c800): /* FCMGT #0 */
    case UINT32_C(0x2ea0c800): /* FCMGE #0 */
    case UINT32_C(0x0ea0e800): /* FCMLT #0 */
    case UINT32_C(0x2ea0d800): { /* FCMLE #0 */
        uint32_t masked = instruction & UINT32_C(0xbfbffc00);
        unsigned comparison;
        if (masked == UINT32_C(0x0ea0d800)) {
            comparison = 5u;
        } else if (masked == UINT32_C(0x0ea0c800)) {
            comparison = 6u;
        } else if (masked == UINT32_C(0x2ea0c800)) {
            comparison = 7u;
        } else if (masked == UINT32_C(0x0ea0e800)) {
            comparison = 8u;
        } else {
            comparison = 9u;
        }
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = ((instruction >> 22) & 1u) != 0u ? 64u : 32u;
        if (element_bits == 64u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = 0;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q | (comparison << 1));
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0xbffffc00)) == UINT32_C(0x0e205800)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = 8;
        decoded->flags = (uint8_t)((instruction >> 30) & 1u);
        return 1;
    }

    /* CLZ (Advanced SIMD), integer vector forms with 8/16/32-bit lanes. */
    if ((instruction & UINT32_C(0xbf3ffc00)) == UINT32_C(0x2e204800)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = 8u << ((instruction >> 22) & 3u);
        if (element_bits > 32u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)q;
        return 1;
    }

    if ((instruction & UINT32_C(0xbffffc00)) == UINT32_C(0x2e205800)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_BITWISE_NOT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->flags = (uint8_t)((instruction >> 30) & 1u);
        return 1;
    }

    if ((instruction & UINT32_C(0xfffffc00)) == UINT32_C(0x7ee0b800)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = 64;
        decoded->flags = 2u;
        return 1;
    }

    if ((instruction & UINT32_C(0xbf3ffc00)) == UINT32_C(0x2e20b800)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = 8u << ((instruction >> 22) & 3u);
        if (element_bits > 64u || (element_bits == 64u && q == 0u)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)q;
        return 1;
    }

    /*
     * SMLAL/UMLAL/SMLSL/UMLSL: widen each product and add it to or subtract
     * it from the existing destination lane. Flag bits 3 and 4 distinguish
     * accumulation and subtraction from the existing SMULL/UMULL path.
     */
    if ((instruction & UINT32_C(0x9f20dc00)) == UINT32_C(0x0e208000)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0u ? 1u : 0u) |
            (((instruction >> 29) & 1u) != 0u ? 2u : 0u) |
            8u |
            (((instruction >> 13) & 1u) != 0u ? 16u : 0u));
        return 1;
    }

    /*
     * SMULL/UMULL, SMLAL/UMLAL, and SMLSL/UMLSL (vector, by element).
     * Halfword forms encode H:L:M as the selected lane and restrict Vm to
     * V0...V15. Word forms encode H:L as the lane and use M as Vm[4].
     */
    {
        uint32_t masked = instruction & UINT32_C(0x9f00f400);
        if (masked == UINT32_C(0x0f00a000) ||
            masked == UINT32_C(0x0f002000) ||
            masked == UINT32_C(0x0f006000)) {
            unsigned size = (instruction >> 22) & 3u;
            unsigned l = (instruction >> 21) & 1u;
            unsigned m = (instruction >> 20) & 1u;
            unsigned h = (instruction >> 11) & 1u;
            unsigned rm = (instruction >> 16) & 0x0fu;
            unsigned source_lane;

            if (size == 1u) {
                source_lane = (h << 2) | (l << 1) | m;
            } else if (size == 2u) {
                source_lane = (h << 1) | l;
                rm |= m << 4;
            } else {
                return 0;
            }

            unsigned accumulates = masked != UINT32_C(0x0f00a000);
            unsigned subtracts = masked == UINT32_C(0x0f006000);
            decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
            decoded->rd = instruction & 0x1f;
            decoded->rn = (instruction >> 5) & 0x1f;
            decoded->rm = (uint8_t)rm;
            decoded->bits = (uint8_t)(8u << size);
            decoded->condition = (uint8_t)source_lane;
            decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0u ? 1u : 0u) |
                (((instruction >> 29) & 1u) != 0u ? 2u : 0u) |
                (accumulates != 0u ? 8u : 0u) |
                (subtracts != 0u ? 16u : 0u) |
                64u);
            return 1;
        }
    }

    /*
     * MLA/MLS (vector): lane-wise multiply-accumulate/subtract modulo the
     * element width. These share the same private non-widening flag scheme as
     * MUL below. Private operation bits 4..5: 1 = MLA, 2 = MLS.
     */
    if ((instruction & UINT32_C(0x9f20fc00)) == UINT32_C(0x0e209400)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned subtract = (instruction >> 29) & 1u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(4u | (q << 3) |
            ((subtract != 0u ? 2u : 1u) << 4));
        return 1;
    }

    /*
     * MUL/MLA/MLS (vector, by element). Halfword forms encode H:L:M as the
     * lane and restrict Vm to V0...V15; word forms encode H:L as the lane and
     * use M as Vm[4]. Private flag bit 6 marks the selected-element source.
     */
    if ((instruction & UINT32_C(0xbf00f400)) == UINT32_C(0x0f008000) ||
        (instruction & UINT32_C(0xbf00b400)) == UINT32_C(0x2f000000)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        unsigned l = (instruction >> 21) & 1u;
        unsigned m = (instruction >> 20) & 1u;
        unsigned h = (instruction >> 11) & 1u;
        unsigned rm = (instruction >> 16) & 0x0fu;
        unsigned source_lane;
        unsigned operation;

        if (size == 1u) {
            source_lane = (h << 2) | (l << 1) | m;
        } else if (size == 2u) {
            source_lane = (h << 1) | l;
            rm |= m << 4;
        } else {
            return 0;
        }

        if (((instruction >> 29) & 1u) == 0u) {
            operation = 0u;
        } else {
            operation = ((instruction >> 14) & 1u) != 0u ? 2u : 1u;
        }

        decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (uint8_t)rm;
        decoded->bits = (uint8_t)(8u << size);
        decoded->condition = (uint8_t)source_lane;
        decoded->flags = (uint8_t)(4u | (q << 3) | (operation << 4) | 64u);
        return 1;
    }

    /*
     * MUL (vector): integer lane-wise multiply modulo the element width.
     *
     * Reuse AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG with a private decoded flag so
     * the public ABI and Swift vector-state classification remain unchanged:
     *   bit 2: non-widening MUL
     *   bit 3: Q (0 = 64-bit vector, 1 = 128-bit vector)
     */
    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x0e209c00)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(4u | (q << 3));
        return 1;
    }

    if ((instruction & UINT32_C(0x9f20fc00)) == UINT32_C(0x0e20c000)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u));
        return 1;
    }

    /* XTN/XTN2: truncate each source lane to half its width. */
    if ((instruction & UINT32_C(0xbf3ffc00)) == UINT32_C(0x0e212800)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_NARROW_HIGH;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)(16u << size);
        decoded->flags = (uint8_t)(32u | ((instruction >> 30) & 1u));
        return 1;
    }

    if ((instruction & UINT32_C(0x9f20dc00)) == UINT32_C(0x0e204000)) {
        unsigned size = (instruction >> 22) & 3u;
        if (size > 2u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_NARROW_HIGH;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(16u << size);
        decoded->flags = (uint8_t)((((instruction >> 30) & 1u) != 0 ? 1u : 0u) |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 13) & 1u) != 0 ? 4u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xdf20dc00)) == UINT32_C(0x5e200c00)) {
        unsigned size = (instruction >> 22) & 3u;
        decoded->kind = AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)(8u |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 13) & 1u) != 0 ? 4u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0x9f20dc00)) == UINT32_C(0x0e200c00)) {
        unsigned size = (instruction >> 22) & 3u;
        unsigned q = (instruction >> 30) & 1u;
        unsigned element_bits = 8u << size;
        if (element_bits > 64u || (element_bits == 64u && q == 0u)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)(q |
            (((instruction >> 29) & 1u) != 0 ? 2u : 0u) |
            (((instruction >> 13) & 1u) != 0 ? 4u : 0u));
        return 1;
    }

    if ((instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0ea01c00)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_ORR_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)((instruction >> 30) & 1u);
        return 1;
    }

    if ((instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0e201c00) ||
        (instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0e601c00) ||
        (instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0ee01c00)) {
        uint32_t masked = instruction & UINT32_C(0xbfe0fc00);
        unsigned operation = masked == UINT32_C(0x0e201c00)
            ? 5u
            : (masked == UINT32_C(0x0e601c00) ? 6u : 7u);
        decoded->kind = AVZ_NATIVE_OP_SIMD_ORR_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)(((instruction >> 30) & 1u) | (operation << 1));
        return 1;
    }

    if ((instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x2e201c00)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_ORR_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)(((instruction >> 30) & 1u) | 2u);
        return 1;
    }

    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x2e201c00)) {
        unsigned opcode = (instruction >> 21) & 7u;
        if (opcode != 3u && opcode != 5u && opcode != 7u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_ORR_VECTOR;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->flags = (uint8_t)(((instruction >> 30) & 1u) | (((opcode + 1u) / 2u) << 1));
        return 1;
    }

    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x2e20a400)) {
        unsigned element_bits = 8u << ((instruction >> 22) & 3u);
        if (element_bits > 32) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = (uint8_t)((instruction >> 30) & 1u);
        return 1;
    }

    if ((instruction & UINT32_C(0xbfe0fc00)) == UINT32_C(0x0e000c00)) {
        uint32_t imm5 = (instruction >> 16) & 0x1f;
        if (imm5 == 0) {
            return 0;
        }
        unsigned trailing = 0;
        while (((imm5 >> trailing) & 1u) == 0u) {
            trailing++;
        }
        unsigned element_bits = 8u << trailing;
        int writes_full_vector = ((instruction >> 30) & 1u) != 0;
        if (element_bits > 64 || (!writes_full_vector && element_bits >= 64)) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->bits = (uint8_t)element_bits;
        decoded->flags = writes_full_vector ? 1 : 0;
        return 1;
    }

    if (decode_simd_movi_zero(instruction)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_MOVI_ZERO;
        decoded->rd = instruction & 0x1f;
        return 1;
    }

    {
        uint64_t value = 0;
        unsigned element_bits = 0;
        int writes_full_vector = 0;
        if (decode_simd_fp_immediate(instruction, &value, &element_bits, &writes_full_vector)) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE;
            decoded->rd = instruction & 0x1f;
            decoded->bits = (uint8_t)element_bits;
            decoded->flags = writes_full_vector ? 1 : 0;
            decoded->immediate = (int64_t)value;
            return 1;
        }
    }

    {
        uint64_t value = 0;
        unsigned element_bits = 0;
        int writes_full_vector = 0;
        int is_bic = 0;
        if (decode_simd_logical_word_immediate(
            instruction, &value, &element_bits, &writes_full_vector, &is_bic
        )) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE;
            decoded->rd = instruction & 0x1f;
            decoded->bits = (uint8_t)element_bits;
            decoded->flags = (uint8_t)((writes_full_vector ? 1u : 0u) |
                (is_bic ? 4u : 2u));
            decoded->immediate = (int64_t)value;
            return 1;
        }
    }

    {
        uint64_t value = 0;
        unsigned element_bits = 0;
        int writes_full_vector = 0;
        if (decode_simd_movi_word_immediate(
            instruction, &value, &element_bits, &writes_full_vector
        )) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE;
            decoded->rd = instruction & 0x1f;
            decoded->bits = (uint8_t)element_bits;
            decoded->flags = writes_full_vector ? 1 : 0;
            decoded->immediate = (int64_t)value;
            return 1;
        }
    }

    {
        uint64_t byte = 0;
        int writes_full_vector = 0;
        if (decode_simd_movi_byte(instruction, &byte, &writes_full_vector)) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_MOVI_BYTE;
            decoded->rd = instruction & 0x1f;
            decoded->immediate = (int64_t)byte;
            decoded->flags = writes_full_vector ? 1 : 0;
            return 1;
        }
    }

    {
        uint64_t value = 0;
        int writes_full_vector = 0;
        if (decode_simd_movi_d_immediate(instruction, &value, &writes_full_vector)) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_MOVI_D_IMMEDIATE;
            decoded->rd = instruction & 0x1f;
            decoded->bits = 64;
            decoded->flags = writes_full_vector ? 1 : 0;
            decoded->immediate = (int64_t)value;
            return 1;
        }
    }

    {
        uint64_t value = 0;
        unsigned element_bits = 0;
        int writes_full_vector = 0;
        if (decode_simd_mvni_immediate(instruction, &value, &element_bits, &writes_full_vector)) {
            decoded->kind = AVZ_NATIVE_OP_SIMD_MVNI_IMMEDIATE;
            decoded->rd = instruction & 0x1f;
            decoded->bits = (uint8_t)element_bits;
            decoded->flags = writes_full_vector ? 1 : 0;
            decoded->immediate = (int64_t)value;
            return 1;
        }
    }

    switch (instruction & UINT32_C(0xffc00000)) {
    case UINT32_C(0x2c800000):
    case UINT32_C(0x2cc00000):
    case UINT32_C(0x2d000000):
    case UINT32_C(0x2d400000):
    case UINT32_C(0x2d800000):
    case UINT32_C(0x2dc00000):
    case UINT32_C(0x6c800000):
    case UINT32_C(0x6cc00000):
    case UINT32_C(0x6d000000):
    case UINT32_C(0x6d400000):
    case UINT32_C(0x6d800000):
    case UINT32_C(0x6dc00000):
    case UINT32_C(0xac800000):
    case UINT32_C(0xacc00000):
    case UINT32_C(0xad000000):
    case UINT32_C(0xad400000):
    case UINT32_C(0xad800000):
    case UINT32_C(0xadc00000): {
        uint32_t masked = instruction & UINT32_C(0xffc00000);
        uint8_t load = ((masked & UINT32_C(0x00400000)) != 0) ? 1 : 0;
        uint8_t width = (uint8_t)(4u << ((instruction >> 30) & 3u));
        uint8_t writeback = (masked == UINT32_C(0x2c800000) ||
            masked == UINT32_C(0x2cc00000) ||
            masked == UINT32_C(0x2d800000) ||
            masked == UINT32_C(0x2dc00000) ||
            masked == UINT32_C(0x6c800000) ||
            masked == UINT32_C(0x6cc00000) ||
            masked == UINT32_C(0x6d800000) ||
            masked == UINT32_C(0x6dc00000) ||
            masked == UINT32_C(0xac800000) ||
            masked == UINT32_C(0xacc00000) ||
            masked == UINT32_C(0xad800000) ||
            masked == UINT32_C(0xadc00000)) ? 1 : 0;
        uint8_t post_index = (masked == UINT32_C(0x2c800000) ||
            masked == UINT32_C(0x2cc00000) ||
            masked == UINT32_C(0x6c800000) ||
            masked == UINT32_C(0x6cc00000) ||
            masked == UINT32_C(0xac800000) ||
            masked == UINT32_C(0xacc00000)) ? 1 : 0;
        int64_t imm7 = sign_extend_u64((instruction >> 15) & 0x7f, 7);
        int64_t offset = imm7 * width;

        decoded->kind = AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR;
        decoded->rt = instruction & 0x1f;
        decoded->rd = (instruction >> 10) & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8u);
        decoded->flags = (load ? 1 : 0) | (writeback ? 8 : 0);
        decoded->immediate = post_index ? 0 : offset;
        decoded->immediate2 = offset;
        return 1;
    }
    default:
        break;
    }

    switch (instruction & UINT32_C(0xffc00000)) {
    case UINT32_C(0x28000000):
    case UINT32_C(0x28400000):
    case UINT32_C(0x28800000):
    case UINT32_C(0x28c00000):
    case UINT32_C(0x29000000):
    case UINT32_C(0x29400000):
    case UINT32_C(0x29800000):
    case UINT32_C(0x29c00000):
    case UINT32_C(0x68c00000):
    case UINT32_C(0x69400000):
    case UINT32_C(0x69c00000):
    case UINT32_C(0xa8000000):
    case UINT32_C(0xa8400000):
    case UINT32_C(0xa8800000):
    case UINT32_C(0xa8c00000):
    case UINT32_C(0xa9000000):
    case UINT32_C(0xa9400000):
    case UINT32_C(0xa9800000):
    case UINT32_C(0xa9c00000): {
        uint32_t masked = instruction & UINT32_C(0xffc00000);
        uint8_t load = ((masked & UINT32_C(0x00400000)) != 0) ? 1 : 0;
        uint8_t width = (masked & UINT32_C(0x80000000)) != 0 ? 8 : 4;
        uint8_t sign_extend_words = (masked == UINT32_C(0x68c00000) ||
            masked == UINT32_C(0x69400000) ||
            masked == UINT32_C(0x69c00000)) ? 1 : 0;
        uint8_t writeback = (masked == UINT32_C(0x28800000) ||
            masked == UINT32_C(0x28c00000) ||
            masked == UINT32_C(0x29800000) ||
            masked == UINT32_C(0x29c00000) ||
            masked == UINT32_C(0x68c00000) ||
            masked == UINT32_C(0x69c00000) ||
            masked == UINT32_C(0xa8800000) ||
            masked == UINT32_C(0xa8c00000) ||
            masked == UINT32_C(0xa9800000) ||
            masked == UINT32_C(0xa9c00000)) ? 1 : 0;
        uint8_t post_index = (masked == UINT32_C(0x28800000) ||
            masked == UINT32_C(0x28c00000) ||
            masked == UINT32_C(0x68c00000) ||
            masked == UINT32_C(0xa8800000) ||
            masked == UINT32_C(0xa8c00000)) ? 1 : 0;
        int64_t imm7 = sign_extend_u64((instruction >> 15) & 0x7f, 7);
        int64_t offset = imm7 * width;

        decoded->kind = AVZ_NATIVE_OP_LOAD_STORE_PAIR;
        decoded->rt = instruction & 0x1f;
        decoded->rd = (instruction >> 10) & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->width = width;
        decoded->bits = (uint8_t)(width * 8);
        decoded->flags = (load ? 1 : 0) |
            (sign_extend_words ? 2 : 0) |
            (writeback ? 8 : 0);
        decoded->immediate = post_index ? 0 : offset;
        decoded->immediate2 = offset;
        return 1;
    }
    default:
        break;
    }

    if ((instruction & UINT32_C(0xfffffc00)) == UINT32_C(0x5ef1b800)) {
        decoded->kind = AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = 0;
        decoded->bits = 64;
        decoded->flags = 2u;
        return 1;
    }

    if ((instruction & UINT32_C(0xbf20fc00)) == UINT32_C(0x0e20bc00)) {
        unsigned q = (instruction >> 30) & 1u;
        unsigned size = (instruction >> 22) & 3u;
        if (size == 3u && q == 0u) {
            return 0;
        }
        decoded->kind = AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD;
        decoded->rd = instruction & 0x1f;
        decoded->rn = (instruction >> 5) & 0x1f;
        decoded->rm = (instruction >> 16) & 0x1f;
        decoded->bits = (uint8_t)(8u << size);
        decoded->flags = (uint8_t)q;
        return 1;
    }

    if ((instruction & UINT32_C(0xfc000000)) == UINT32_C(0x14000000) ||
        (instruction & UINT32_C(0xfc000000)) == UINT32_C(0x94000000)) {
        decoded->kind = AVZ_NATIVE_OP_BRANCH;
        decoded->flags = ((instruction & UINT32_C(0xfc000000)) == UINT32_C(0x94000000)) ? 1 : 0;
        decoded->immediate = decode_scaled_signed_immediate(
            instruction & UINT32_C(0x03ffffff),
            26,
            4
        );
        return 1;
    }

    return 0;
}

int avz_native_instruction_supported(uint32_t instruction) {
    AVZNativeInstruction decoded;
    return avz_native_decode_instruction(instruction, &decoded);
}

AVZNativeBlockResult avz_native_run_block(
    const uint32_t *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    AVZNativeCPU *cpu
) {
    AVZNativeBlockResult result = {
        .steps = 0,
        .generic_dispatches = 0,
        .fast_path_steps = 0,
        .fast_path_hits = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .unsupported_instruction = 0
    };

    while (result.steps < max_steps) {
        if (cpu->halted) {
            result.status = AVZ_NATIVE_STATUS_HALTED;
            return result;
        }
        if (cpu->pc < base_pc || ((cpu->pc - base_pc) & 3) != 0) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            return result;
        }
        uint64_t index64 = (cpu->pc - base_pc) >> 2;
        if (index64 >= instruction_count) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            return result;
        }

        uint32_t instruction = instructions[index64];
        uint64_t pc = cpu->pc;

        if (instruction == UINT32_C(0xd503201f) ||
            instruction == UINT32_C(0xd503209f) ||
            instruction == UINT32_C(0xd50320bf) ||
            (instruction & UINT32_C(0xfffff01f)) == UINT32_C(0xd503201f)) {
            cpu->pc = pc + 4;
        } else if ((instruction & UINT32_C(0xffe0001f)) == UINT32_C(0xd4400000)) {
            cpu->pc = pc + 4;
            cpu->halted = 1;
            result.steps++;
            result.status = AVZ_NATIVE_STATUS_HALTED;
            return result;
        } else if ((instruction & UINT32_C(0x9f000000)) == UINT32_C(0x10000000) ||
                   (instruction & UINT32_C(0x9f000000)) == UINT32_C(0x90000000)) {
            int page = (instruction & UINT32_C(0x9f000000)) == UINT32_C(0x90000000);
            unsigned rd = instruction & 0x1f;
            uint64_t immlo = (instruction >> 29) & 3;
            uint64_t immhi = (instruction >> 5) & 0x7ffff;
            int64_t offset = sign_extend_u64((immhi << 2) | immlo, 21);
            uint64_t base = page ? (pc & ~UINT64_C(0xfff)) : pc;
            if (page) {
                offset *= INT64_C(4096);
            }
            write_register(cpu, rd, add_signed_offset(base, offset));
            cpu->pc = pc + 4;
        } else if ((instruction & UINT32_C(0x7e000000)) == UINT32_C(0x34000000)) {
            unsigned rt = instruction & 0x1f;
            uint64_t value = ((instruction >> 31) & 1) ? read_register(cpu, rt) : (read_register(cpu, rt) & UINT64_C(0xffffffff));
            int branch_non_zero = ((instruction >> 24) & 1) != 0;
            int64_t offset = decode_scaled_signed_immediate(
                (instruction >> 5) & 0x7ffff,
                19,
                4
            );
            cpu->pc = ((value != 0) == branch_non_zero)
                ? add_signed_offset(pc, offset)
                : pc + 4;
        } else if ((instruction & UINT32_C(0x7e000000)) == UINT32_C(0x36000000)) {
            unsigned rt = instruction & 0x1f;
            unsigned bit = (unsigned)(((instruction >> 31) & 1) << 5) | ((instruction >> 19) & 0x1f);
            int bit_set = ((read_register(cpu, rt) >> bit) & 1) != 0;
            int branch_non_zero = ((instruction >> 24) & 1) != 0;
            int64_t offset = decode_scaled_signed_immediate(
                (instruction >> 5) & 0x3fff,
                14,
                4
            );
            cpu->pc = (bit_set == branch_non_zero)
                ? add_signed_offset(pc, offset)
                : pc + 4;
        } else if ((instruction & UINT32_C(0xff000010)) == UINT32_C(0x54000000)) {
            int64_t offset = decode_scaled_signed_immediate(
                (instruction >> 5) & 0x7ffff,
                19,
                4
            );
            uint8_t condition = instruction & 0xf;
            cpu->pc = condition_holds(condition, cpu->pstate)
                ? add_signed_offset(pc, offset)
                : pc + 4;
        } else if ((instruction & UINT32_C(0x1f200000)) == UINT32_C(0x0b000000)) {
            if (!execute_add_sub_shifted_register(cpu, instruction)) {
                result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
                result.unsupported_instruction = instruction;
                return result;
            }
        } else if ((instruction & UINT32_C(0x1f800000)) == UINT32_C(0x12800000)) {
            if (!execute_move_wide(cpu, instruction)) {
                result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
                result.unsupported_instruction = instruction;
                return result;
            }
        } else if ((instruction & UINT32_C(0x1f000000)) == UINT32_C(0x11000000)) {
            if (!execute_add_sub_immediate(cpu, instruction)) {
                result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
                result.unsupported_instruction = instruction;
                return result;
            }
        } else if ((instruction & UINT32_C(0xfc000000)) == UINT32_C(0x14000000) ||
                   (instruction & UINT32_C(0xfc000000)) == UINT32_C(0x94000000)) {
            int link = (instruction & UINT32_C(0xfc000000)) == UINT32_C(0x94000000);
            int64_t offset = decode_scaled_signed_immediate(
                instruction & UINT32_C(0x03ffffff),
                26,
                4
            );
            if (link) {
                cpu->x[30] = pc + 4;
            }
            cpu->pc = add_signed_offset(pc, offset);
        } else {
            result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
            result.unsupported_instruction = instruction;
            return result;
        }

        result.steps++;
    }

    result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    return result;
}

static int execute_simd_shift_left_immediate_portable(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    unsigned element_bits = instruction->bits;
    unsigned shift = instruction->shift_amount;
    if ((element_bits != 8u && element_bits != 16u &&
         element_bits != 32u && element_bits != 64u) ||
        shift >= element_bits) {
        return 0;
    }
    unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
    uint64_t lane_mask = mask_for_bits(element_bits);
    int inserts = (instruction->flags & 2u) != 0u;
    AVZNativeVectorRegister result = {0, 0};
    for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
        uint64_t source = read_vector_element(cpu, instruction->rn, lane, element_bits);
        uint64_t value = (source << shift) & lane_mask;
        if (inserts && shift != 0u) {
            uint64_t destination = read_vector_element(
                cpu, instruction->rd, lane, element_bits
            );
            value |= destination & ((UINT64_C(1) << shift) - 1u);
        }
        write_vector_element(&result, lane, element_bits, value);
    }
    cpu->v[instruction->rd] = result;
    return 1;
}

static int execute_simd_saturating_add_subtract_portable(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    unsigned element_bits = instruction->bits;
    unsigned vector_bits = (instruction->flags & 8u) != 0u
        ? element_bits
        : ((instruction->flags & 1u) != 0 ? 128u : 64u);
    unsigned is_unsigned = instruction->flags & 2u;
    unsigned subtracts = instruction->flags & 4u;
    uint64_t element_mask = mask_for_bits(element_bits);
    int saturated = 0;
    AVZNativeVectorRegister result = {0, 0};

    for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
        uint64_t lhs_bits = read_vector_element(
            cpu,
            instruction->rn,
            lane,
            element_bits
        );
        uint64_t rhs_bits = read_vector_element(
            cpu,
            instruction->rm,
            lane,
            element_bits
        );
        uint64_t value;
        if (is_unsigned != 0) {
            if (subtracts != 0) {
                if (lhs_bits < rhs_bits) {
                    value = 0;
                    saturated = 1;
                } else {
                    value = lhs_bits - rhs_bits;
                }
            } else if (lhs_bits > element_mask - rhs_bits) {
                value = element_mask;
                saturated = 1;
            } else {
                value = lhs_bits + rhs_bits;
            }
        } else {
            int64_t lhs = (int64_t)sign_extend_vector_element(
                cpu,
                instruction->rn,
                lane,
                element_bits
            );
            int64_t rhs = (int64_t)sign_extend_vector_element(
                cpu,
                instruction->rm,
                lane,
                element_bits
            );
            uint64_t signed_limit = sign_bit_for_bits(element_bits);
            int64_t minimum = element_bits >= 64u
                ? INT64_MIN
                : -(int64_t)signed_limit;
            int64_t maximum = element_bits >= 64u
                ? INT64_MAX
                : (int64_t)(signed_limit - 1u);
            int64_t signed_value;
            if (subtracts != 0) {
                if (rhs < 0 && lhs > maximum + rhs) {
                    signed_value = maximum;
                    saturated = 1;
                } else if (rhs > 0 && lhs < minimum + rhs) {
                    signed_value = minimum;
                    saturated = 1;
                } else {
                    signed_value = lhs - rhs;
                }
            } else if (rhs > 0 && lhs > maximum - rhs) {
                signed_value = maximum;
                saturated = 1;
            } else if (rhs < 0 && lhs < minimum - rhs) {
                signed_value = minimum;
                saturated = 1;
            } else {
                signed_value = lhs + rhs;
            }
            value = (uint64_t)signed_value & element_mask;
        }
        write_vector_element(&result, lane, element_bits, value);
    }
    if (saturated) {
        cpu->fpsr |= UINT64_C(1) << 27;
    }
    cpu->v[instruction->rd] = result;
    return 1;
}

static int execute_simd_shift_right_immediate_portable(
    AVZNativeCPU *cpu,
    const AVZNativeInstruction *instruction
) {
    unsigned element_bits = instruction->bits;
    unsigned shift = instruction->shift_amount;
    unsigned is_scalar = instruction->flags & 4u;
    unsigned vector_bits = is_scalar != 0
        ? 64u
        : ((instruction->flags & 1u) != 0 ? 128u : 64u);
    unsigned is_unsigned = instruction->flags & 2u;
    unsigned inserts = instruction->flags & 8u;
    unsigned rounds = instruction->flags & 16u;
    unsigned accumulates = instruction->flags & 32u;
    uint64_t element_mask = mask_for_bits(element_bits);
    AVZNativeVectorRegister result = {0, 0};

    if (element_bits == 0 || shift == 0 || shift > element_bits) {
        return 0;
    }
    for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
        uint64_t source = read_vector_element(
            cpu,
            instruction->rn,
            lane,
            element_bits
        );
        uint64_t value;
        if (rounds != 0u) {
            if (is_unsigned != 0u) {
                __uint128_t wide = source;
                wide += ((__uint128_t)1u) << (shift - 1u);
                value = (uint64_t)(wide >> shift);
            } else {
                __int128 wide = (__int128)sign_extend_u64(source, element_bits);
                wide += ((__int128)1) << (shift - 1u);
                value = (uint64_t)(wide >> shift);
            }
        } else if (is_unsigned != 0u) {
            value = shift == element_bits ? 0u : source >> shift;
        } else {
            value = (uint64_t)(
                (__int128)sign_extend_u64(source, element_bits) >> shift
            );
        }
        if (inserts != 0u) {
            uint64_t destination = read_vector_element(
                cpu,
                instruction->rd,
                lane,
                element_bits
            );
            uint64_t preserved_mask = shift == element_bits
                ? element_mask
                : element_mask ^ (element_mask >> shift);
            value |= destination & preserved_mask;
        } else if (accumulates != 0u) {
            value += read_vector_element(
                cpu,
                instruction->rd,
                lane,
                element_bits
            );
        }
        write_vector_element(
            &result,
            lane,
            element_bits,
            value & element_mask
        );
    }
    cpu->v[instruction->rd] = result;
    return 1;
}

static inline uint16_t decoded_system_register_key(uint32_t raw) {
    return (uint16_t)(
        (((raw >> 19) & 0x3u) << 14) |
        (((raw >> 16) & 0x7u) << 11) |
        (((raw >> 12) & 0xfu) << 7) |
        (((raw >> 8) & 0xfu) << 3) |
        ((raw >> 5) & 0x7u)
    );
}

static int execute_decoded_instruction(
    const AVZNativeInstruction *instruction,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
) {
    uint64_t pc = cpu->pc;
    uint16_t system_register_key;

    switch (instruction->kind) {
    case AVZ_NATIVE_OP_NOP:
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_HALT:
        cpu->pc = pc + 4;
        cpu->halted = 1;
        return 1;
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ: {
        uint64_t value = 0;
        int use_local_system_registers =
            read_system_register == 0 ||
            read_system_register == avz_native_fast_read_system_register;
        system_register_key = decoded_system_register_key(instruction->raw);
        switch (use_local_system_registers ? system_register_key : UINT16_MAX) {
        case (3u << 14) | (0u << 11) | (4u << 7) | (2u << 3) | 2u:
            value = cpu->pstate & UINT64_C(0xc);
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 0u:
            value = cpu->pstate & UINT64_C(0xf0000000);
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 1u:
            value = cpu->pstate & UINT64_C(0x3c0);
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 0u:
            value = cpu->fpcr;
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 1u:
            value = cpu->fpsr;
            break;
        default:
            if (read_system_register == 0 ||
                !read_system_register(
                    memory_context,
                    instruction->raw,
                    pc,
                    cpu->pstate,
                    cpu->sp,
                    &value
                )) {
                return 0;
            }
            break;
        }
        write_register(cpu, instruction->rt, value);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE: {
        uint64_t value = read_register(cpu, instruction->rt);
        int use_local_system_registers =
            write_system_register == 0 ||
            write_system_register == avz_native_fast_write_system_register;
        system_register_key = decoded_system_register_key(instruction->raw);
        switch (use_local_system_registers ? system_register_key : UINT16_MAX) {
        case (3u << 14) | (0u << 11) | (4u << 7) | (2u << 3) | 2u:
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 0u:
            cpu->pstate =
                (cpu->pstate & ~UINT64_C(0xf0000000)) |
                (value & UINT64_C(0xf0000000));
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 1u:
            cpu->pstate =
                (cpu->pstate & ~UINT64_C(0x3c0)) |
                (value & UINT64_C(0x3c0));
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 0u:
            cpu->fpcr = value;
            break;
        case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 1u:
            cpu->fpsr = value;
            break;
        default:
            if (write_system_register == 0 ||
                !write_system_register(
                    memory_context,
                    instruction->raw,
                    pc,
                    value,
                    &cpu->pstate,
                    &cpu->sp
                )) {
                return 0;
            }
            break;
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_BARRIER:
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
        if (execute_system_instruction == 0 ||
            !execute_system_instruction(
                memory_context,
                instruction->raw,
                read_register(cpu, instruction->rt)
            )) {
            return 0;
        }
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_EXCEPTION_RETURN:
        return exception_return != 0 &&
            exception_return(memory_context, &cpu->pstate, &cpu->sp, &cpu->pc);
    case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
        if (instruction->flags == 0x6) {
            cpu->pstate |= (uint64_t)instruction->immediate;
        } else {
            cpu->pstate &= ~(uint64_t)instruction->immediate;
        }
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
        return synchronous_exception != 0 &&
            synchronous_exception(
                memory_context,
                instruction->raw,
                cpu->x,
                &cpu->pstate,
                &cpu->sp,
                &cpu->pc
            );
    case AVZ_NATIVE_OP_WAIT:
        return wait != 0 && wait(memory_context, instruction->raw, &cpu->pc);
    case AVZ_NATIVE_OP_ADR: {
        uint64_t base = (instruction->flags & 1) ? (pc & ~UINT64_C(0xfff)) : pc;
        write_register(
            cpu,
            instruction->rd,
            add_signed_offset(base, instruction->immediate)
        );
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_CBZ: {
        uint64_t value = instruction->bits == 64
            ? read_register(cpu, instruction->rt)
            : (read_register(cpu, instruction->rt) & UINT64_C(0xffffffff));
        int branch_non_zero = (instruction->flags & 1) != 0;
        cpu->pc = ((value != 0) == branch_non_zero)
            ? add_signed_offset(pc, instruction->immediate)
            : pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_TBZ: {
        int bit_set = ((read_register(cpu, instruction->rt) >> instruction->shift_amount) & 1) != 0;
        int branch_non_zero = (instruction->flags & 1) != 0;
        cpu->pc = (bit_set == branch_non_zero)
            ? add_signed_offset(pc, instruction->immediate)
            : pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_BCOND:
        cpu->pc = condition_holds(instruction->condition, cpu->pstate)
            ? add_signed_offset(pc, instruction->immediate)
            : pc + 4;
        return 1;
    case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER: {
        unsigned bits = instruction->bits;
        uint64_t flags;
        if (condition_holds(instruction->condition, cpu->pstate)) {
            uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
            uint64_t rhs = masked_operand(read_register(cpu, instruction->rm), bits);
            uint64_t result = 0;
            if ((instruction->flags & 1) != 0) {
                rhs = (~rhs) & mask_for_bits(bits);
            }
            flags = add_with_carry_nzcv(lhs, rhs, (instruction->flags & 1) != 0, bits, &result);
        } else {
            flags = (uint64_t)instruction->immediate;
        }
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE: {
        unsigned bits = instruction->bits;
        uint64_t flags;
        if (condition_holds(instruction->condition, cpu->pstate)) {
            uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
            uint64_t rhs = masked_operand((uint64_t)instruction->immediate, bits);
            uint64_t result = 0;
            if ((instruction->flags & 1) != 0) {
                rhs = (~rhs) & mask_for_bits(bits);
            }
            flags = add_with_carry_nzcv(lhs, rhs, (instruction->flags & 1) != 0, bits, &result);
        } else {
            flags = (uint64_t)instruction->immediate2;
        }
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE: {
        unsigned bits = instruction->bits;
        int subtract = (instruction->flags & 1) != 0;
        int set_flags = (instruction->flags & 2) != 0;
        uint64_t lhs = masked_operand(read_base_register(cpu, instruction->rn), bits);
        uint64_t rhs = masked_operand((uint64_t)instruction->immediate, bits);
        uint64_t result;
        if (subtract) {
            rhs = (~rhs) & mask_for_bits(bits);
        }
        uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &result);
        if (set_flags) {
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
            write_register(cpu, instruction->rd, result);
        } else {
            write_base_register(cpu, instruction->rd, result);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_MOVE_WIDE: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t imm = (uint64_t)instruction->immediate;
        uint64_t value;
        switch (instruction->flags) {
        case 0:
            value = (~imm) & mask;
            break;
        case 2:
            value = imm & mask;
            break;
        case 3: {
            uint64_t field_mask = (UINT64_C(0xffff) << instruction->shift_amount) & mask;
            value = (read_register(cpu, instruction->rd) & ~field_mask) | (imm & field_mask);
            value &= mask;
            break;
        }
        default:
            return 0;
        }
        write_register(cpu, instruction->rd, value);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t rhs = masked_operand(read_register(cpu, instruction->rm), bits);
        uint64_t result;
        switch (instruction->shift_type) {
        case 0:
            rhs = (rhs << instruction->shift_amount) & mask;
            break;
        case 1:
            rhs >>= instruction->shift_amount;
            break;
        case 2:
            if (instruction->shift_amount > 0) {
                if (bits == 64) {
                    rhs = (uint64_t)(((int64_t)rhs) >> instruction->shift_amount);
                } else {
                    rhs = (uint64_t)(((int32_t)(uint32_t)rhs) >> instruction->shift_amount);
                }
            }
            rhs &= mask;
            break;
        default:
            return 0;
        }
        int subtract = (instruction->flags & 1) != 0;
        int set_flags = (instruction->flags & 2) != 0;
        if (subtract) {
            rhs = (~rhs) & mask;
        }
        uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &result);
        if (set_flags) {
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        }
        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_ADD_SUB_CARRY: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t rhs = masked_operand(read_register(cpu, instruction->rm), bits);
        uint64_t result;
        int subtract = (instruction->flags & 1) != 0;
        int set_flags = (instruction->flags & 2) != 0;
        int carry_in = (cpu->pstate & UINT64_C(0x20000000)) != 0;
        if (subtract) {
            rhs = (~rhs) & mask;
        }
        uint64_t flags = add_with_carry_nzcv(lhs, rhs, carry_in, bits, &result);
        if (set_flags) {
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        }
        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t lhs = masked_operand(read_base_register(cpu, instruction->rn), bits);
        uint64_t rhs = masked_operand(
            extended_register_value(read_register(cpu, instruction->rm), instruction->condition)
                << instruction->shift_amount,
            bits
        );
        uint64_t result;
        int subtract = (instruction->flags & 1) != 0;
        int set_flags = (instruction->flags & 2) != 0;
        if (subtract) {
            rhs = (~rhs) & mask;
        }
        uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &result);
        if (set_flags) {
            cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
            write_register(cpu, instruction->rd, result);
        } else {
            write_base_register(cpu, instruction->rd, result);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t rhs = shifted_register_value(
            read_register(cpu, instruction->rm),
            instruction->shift_type,
            instruction->shift_amount,
            bits
        );
        uint8_t opcode = instruction->flags & 3;
        if ((instruction->flags & 4) != 0) {
            rhs = (~rhs) & mask;
        }

        uint64_t result;
        switch (opcode) {
        case 0:
            result = lhs & rhs;
            break;
        case 1:
            result = lhs | rhs;
            break;
        case 2:
            result = lhs ^ rhs;
            break;
        case 3:
            result = lhs & rhs;
            cpu->pstate &= ~UINT64_C(0xf0000000);
            if ((result & sign_bit_for_bits(bits)) != 0) {
                cpu->pstate |= UINT64_C(0x80000000);
            }
            if (result == 0) {
                cpu->pstate |= UINT64_C(0x40000000);
            }
            break;
        default:
            return 0;
        }

        write_register(cpu, instruction->rd, result & mask);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_EXTRACT_REGISTER: {
        unsigned bits = instruction->bits;
        unsigned lsb = instruction->shift_amount;
        uint64_t mask = mask_for_bits(bits);
        uint64_t low = masked_operand(read_register(cpu, instruction->rm), bits);
        uint64_t high = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t result = lsb == 0
            ? low
            : ((high << (bits - lsb)) | (low >> lsb)) & mask;
        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOGICAL_IMMEDIATE: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t immediate = ((uint64_t)instruction->immediate) & mask;
        uint8_t opcode = instruction->flags & 3;
        uint64_t result;
        switch (opcode) {
        case 0:
            result = lhs & immediate;
            break;
        case 1:
            result = lhs | immediate;
            break;
        case 2:
            result = lhs ^ immediate;
            break;
        case 3:
            result = lhs & immediate;
            cpu->pstate &= ~UINT64_C(0xf0000000);
            if ((result & sign_bit_for_bits(bits)) != 0) {
                cpu->pstate |= UINT64_C(0x80000000);
            }
            if (result == 0) {
                cpu->pstate |= UINT64_C(0x40000000);
            }
            break;
        default:
            return 0;
        }
        if (opcode == 3) {
            write_register(cpu, instruction->rd, result & mask);
        } else {
            write_base_register(cpu, instruction->rd, result & mask);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_REGISTER_BRANCH:
        if ((instruction->flags & 1) != 0) {
            cpu->x[30] = pc + 4;
        }
        cpu->pc = read_register(cpu, instruction->rn);
        return 1;
    case AVZ_NATIVE_OP_CONDITIONAL_SELECT: {
        unsigned bits = instruction->bits;
        uint64_t value;
        uint8_t operation = instruction->flags & 3;
        int invert_or_negate = (instruction->flags & 4) != 0;

        if (condition_holds(instruction->condition, cpu->pstate)) {
            value = read_register(cpu, instruction->rn);
        } else {
            uint64_t fallback = read_register(cpu, instruction->rm);
            if (operation == 0) {
                value = invert_or_negate ? ~fallback : fallback;
            } else if (operation == 1) {
                value = invert_or_negate ? (UINT64_C(0) - fallback) : (fallback + 1);
            } else {
                return 0;
            }
        }

        write_register(cpu, instruction->rd, masked_operand(value, bits));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_BITFIELD_MOVE: {
        unsigned bits = instruction->bits;
        uint64_t mask = mask_for_bits(bits);
        uint8_t opcode = instruction->flags & 3;
        uint8_t immr = instruction->shift_amount;
        uint8_t imms = instruction->condition;
        uint64_t source = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t rotated = rotate_right_width(source, immr, bits);
        uint64_t write_mask = ((uint64_t)instruction->immediate) & mask;
        uint64_t top_mask = ((uint64_t)instruction->immediate2) & mask;
        uint64_t result;

        switch (opcode) {
        case 0: {
            uint64_t partial = (rotated & write_mask) & top_mask;
            uint64_t sign_bit = (source >> (imms & (bits - 1))) & 1;
            uint64_t sign_fill = sign_bit ? mask : 0;
            result = (sign_fill & ~top_mask) | partial;
            break;
        }
        case 1: {
            uint64_t insert_value = 0;
            uint64_t insert_mask = 0;
            bitfield_insert(source, immr, imms, bits, &insert_value, &insert_mask);
            result = (read_register(cpu, instruction->rd) & ~insert_mask & mask) |
                (insert_value & insert_mask);
            break;
        }
        case 2:
            result = (rotated & write_mask) & top_mask;
            break;
        default:
            return 0;
        }

        write_register(cpu, instruction->rd, result & mask);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_DATA_PROCESSING_ONE_SOURCE: {
        unsigned bits = instruction->bits;
        uint64_t source = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t result;

        switch (instruction->flags) {
        case 0x00:
            result = reverse_bits_width(source, bits);
            break;
        case 0x01:
            result = reverse_bytes_group(source, 2, bits);
            break;
        case 0x02:
            result = reverse_bytes_group(source, 4, bits);
            break;
        case 0x03:
            if (bits != 64) {
                return 0;
            }
            result = reverse_bytes_group(source, 8, bits);
            break;
        case 0x04:
            result = count_leading_zeros_width(source, bits);
            break;
        case 0x05:
            result = count_leading_sign_bits_width(source, bits);
            break;
        default:
            return 0;
        }

        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_DATA_PROCESSING_TWO_SOURCE: {
        unsigned bits = instruction->bits;
        uint64_t source = read_register(cpu, instruction->rn);
        uint64_t rhs = read_register(cpu, instruction->rm);
        uint64_t result;

        switch (instruction->flags) {
        case 0x02:
            source = masked_operand(source, bits);
            rhs = masked_operand(rhs, bits);
            result = rhs == 0 ? 0 : source / rhs;
            break;
        case 0x03:
            result = signed_divide_width(source, rhs, bits);
            break;
        case 0x08:
            result = shifted_register_value(source, 0, (uint8_t)(rhs & (bits - 1u)), bits);
            break;
        case 0x09:
            result = shifted_register_value(source, 1, (uint8_t)(rhs & (bits - 1u)), bits);
            break;
        case 0x0a:
            result = shifted_register_value(source, 2, (uint8_t)(rhs & (bits - 1u)), bits);
            break;
        case 0x0b:
            result = rotate_right_width(source, (unsigned)(rhs & (bits - 1u)), bits);
            break;
        default:
            return 0;
        }

        write_register(cpu, instruction->rd, masked_operand(result, bits));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_LITERAL: {
        if (instruction->flags == 3) {
            cpu->pc = pc + 4;
            return 1;
        }
        uint64_t address = add_signed_offset(pc, instruction->immediate);
        uint64_t value = 0;
        if (read_memory == 0 || !read_memory(memory_context, address, instruction->width, &value)) {
            return 0;
        }
        if (instruction->flags == 2) {
            value = sign_extend_loaded(value, 32);
        }
        write_register(cpu, instruction->rt, value);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_MULTIPLY_ADD_SUBTRACT: {
        unsigned bits = instruction->bits;
        uint64_t lhs = masked_operand(read_register(cpu, instruction->rn), bits);
        uint64_t rhs = masked_operand(read_register(cpu, instruction->rm), bits);
        uint64_t addend = masked_operand(read_register(cpu, instruction->rt), bits);
        uint64_t product = (lhs * rhs) & mask_for_bits(bits);
        uint64_t result = (instruction->flags & 1) != 0
            ? (addend - product)
            : (addend + product);
        write_register(cpu, instruction->rd, masked_operand(result, bits));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIGNED_MULTIPLY_LONG_ADD_SUBTRACT: {
        int64_t lhs = (int64_t)(int32_t)(uint32_t)read_register(cpu, instruction->rn);
        int64_t rhs = (int64_t)(int32_t)(uint32_t)read_register(cpu, instruction->rm);
        uint64_t addend = read_register(cpu, instruction->rt);
        uint64_t product = (uint64_t)(lhs * rhs);
        uint64_t result = (instruction->flags & 1) != 0
            ? (addend - product)
            : (addend + product);
        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_LONG_ADD_SUBTRACT: {
        uint64_t lhs = read_register(cpu, instruction->rn) & UINT64_C(0xffffffff);
        uint64_t rhs = read_register(cpu, instruction->rm) & UINT64_C(0xffffffff);
        uint64_t addend = read_register(cpu, instruction->rt);
        uint64_t product = lhs * rhs;
        uint64_t result = (instruction->flags & 1) != 0
            ? (addend - product)
            : (addend + product);
        write_register(cpu, instruction->rd, result);
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIGNED_MULTIPLY_HIGH: {
        int64_t lhs = (int64_t)read_register(cpu, instruction->rn);
        int64_t rhs = (int64_t)read_register(cpu, instruction->rm);
        __int128 product = (__int128)lhs * (__int128)rhs;
        write_register(cpu, instruction->rd, (uint64_t)(product >> 64));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_HIGH: {
        uint64_t lhs = read_register(cpu, instruction->rn);
        uint64_t rhs = read_register(cpu, instruction->rm);
        unsigned __int128 product = (unsigned __int128)lhs * (unsigned __int128)rhs;
        write_register(cpu, instruction->rd, (uint64_t)(product >> 64));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_BRANCH:
        if ((instruction->flags & 1) != 0) {
            cpu->x[30] = pc + 4;
        }
        cpu->pc = add_signed_offset(pc, instruction->immediate);
        return 1;
    case AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE: {
        uint64_t address = read_base_register(cpu, instruction->rn) +
            (uint64_t)instruction->immediate;
        uint64_t value = 0;
        if ((instruction->flags & 1u) != 0u) {
            if (read_memory == NULL ||
                !read_memory(memory_context, address, instruction->width, &value)) {
                return 0;
            }
            if ((instruction->flags & 2u) != 0u) {
                value = sign_extend_loaded(value, instruction->bits);
                if ((instruction->flags & 4u) != 0u) {
                    value &= UINT64_C(0xffffffff);
                }
            }
            write_register(cpu, instruction->rt, value);
        } else {
            value = read_register(cpu, instruction->rt) &
                mask_for_bits(instruction->bits);
            if (write_memory == NULL ||
                !write_memory(
                    memory_context,
                    address,
                    instruction->width,
                    value
                )) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE: {
        uint64_t address = read_base_register(cpu, instruction->rn);
        uint64_t value = 0;
        if ((instruction->flags & 1) != 0) {
            if (read_memory == 0 || !read_memory(memory_context, address, instruction->width, &value)) {
                return 0;
            }
            write_register(cpu, instruction->rt, value);
        } else {
            if (write_memory == 0 ||
                !write_memory(
                    memory_context,
                    address,
                    instruction->width,
                    read_register(cpu, instruction->rt) & mask_for_bits(instruction->bits)
                )) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL:
        write_register(
            cpu,
            instruction->rd,
            read_vector_element(cpu, instruction->rn, instruction->condition, instruction->bits)
        );
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_FP_SCALAR_GENERAL_MOVE:
        switch (instruction->flags) {
        case 0:
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){read_register(cpu, instruction->rn) & UINT64_C(0xffffffff), 0};
            break;
        case 1:
            write_register(cpu, instruction->rd, cpu->v[instruction->rn].low & UINT64_C(0xffffffff));
            break;
        case 2:
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){read_register(cpu, instruction->rn), 0};
            break;
        case 3:
            write_register(cpu, instruction->rd, cpu->v[instruction->rn].low);
            break;
        case 4:
            cpu->v[instruction->rd].high = read_register(cpu, instruction->rn);
            break;
        case 5:
            write_register(cpu, instruction->rd, cpu->v[instruction->rn].high);
            break;
        default:
            return 0;
        }
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_FP_SCALAR_REGISTER_MOVE:
        if ((instruction->flags & 1) != 0) {
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){cpu->v[instruction->rn].low, 0};
        } else {
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){cpu->v[instruction->rn].low & UINT64_C(0xffffffff), 0};
        }
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_FP_SCALAR_CONVERT_PRECISION:
        if ((instruction->flags & 1u) != 0) {
            union { uint32_t bits; float value; } source = {
                (uint32_t)cpu->v[instruction->rn].low
            };
            union { double value; uint64_t bits; } result = {
                (double)source.value
            };
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint64_t bits; double value; } source = {
                cpu->v[instruction->rn].low
            };
            union { float value; uint32_t bits; } result = {
                (float)source.value
            };
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_NARROW_WIDEN: {
        AVZNativeVectorRegister source = cpu->v[instruction->rn];
        unsigned use_upper_half = (instruction->flags >> 1) & 1u;
        if ((instruction->flags & 1u) == 0u) {
            union { uint64_t bits; double value; } source0 = {source.low};
            union { uint64_t bits; double value; } source1 = {source.high};
            union { float value; uint32_t bits; } result0 = {(float)source0.value};
            union { float value; uint32_t bits; } result1 = {(float)source1.value};
            uint64_t packed = (uint64_t)result0.bits | ((uint64_t)result1.bits << 32);
            if (use_upper_half != 0u) {
                cpu->v[instruction->rd].high = packed;
            } else {
                cpu->v[instruction->rd] = (AVZNativeVectorRegister){packed, 0};
            }
        } else {
            uint64_t packed = use_upper_half != 0u ? source.high : source.low;
            union { uint32_t bits; float value; } source0 = {(uint32_t)packed};
            union { uint32_t bits; float value; } source1 = {(uint32_t)(packed >> 32)};
            union { double value; uint64_t bits; } result0 = {(double)source0.value};
            union { double value; uint64_t bits; } result1 = {(double)source1.value};
            cpu->v[instruction->rd] =
                (AVZNativeVectorRegister){result0.bits, result1.bits};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_IMMEDIATE_MOVE: {
        if ((instruction->flags & 1) != 0) {
            uint64_t bits = expand_fp_immediate_bits((uint32_t)instruction->immediate, 64);
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){bits, 0};
        } else {
            uint64_t bits = expand_fp_immediate_bits((uint32_t)instruction->immediate, 32);
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_INTEGER_TO_SCALAR_FP: {
        int source64 = (instruction->flags & 2) != 0;
        int destination_double = (instruction->flags & 1) != 0;
        int is_unsigned = (instruction->flags & 4) != 0;
        uint64_t source = read_register(cpu, instruction->rn);
        if (destination_double) {
            union { double value; uint64_t bits; } converted;
            if (is_unsigned) {
                converted.value = source64 ? (double)source : (double)(uint32_t)source;
            } else {
                converted.value = source64 ? (double)(int64_t)source : (double)(int32_t)(uint32_t)source;
            }
            if (instruction->shift_amount != 0) {
                converted.value = ldexp(converted.value, -(int)instruction->shift_amount);
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){converted.bits, 0};
        } else {
            union { float value; uint32_t bits; } converted;
            if (is_unsigned) {
                converted.value = source64 ? (float)source : (float)(uint32_t)source;
            } else {
                converted.value = source64 ? (float)(int64_t)source : (float)(int32_t)(uint32_t)source;
            }
            if (instruction->shift_amount != 0) {
                converted.value = ldexpf(converted.value, -(int)instruction->shift_amount);
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)converted.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_ARITHMETIC: {
        int is_double = (instruction->flags & 4) != 0;
        uint8_t operation = instruction->flags & 3u;
        if ((instruction->flags & 8u) != 0u) {
            unsigned element_bits = is_double ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 16u) != 0u ? 128u : 64u;
            int by_element = (instruction->flags & 32u) != 0u;
            uint64_t selected_rhs_bits = by_element
                ? read_vector_element(
                    cpu,
                    instruction->rm,
                    instruction->condition,
                    element_bits
                )
                : 0u;
            AVZNativeVectorRegister vector_result = {0, 0};
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                uint64_t lhs_bits = read_vector_element(cpu, instruction->rn, lane, element_bits);
                uint64_t rhs_bits = by_element
                    ? selected_rhs_bits
                    : read_vector_element(cpu, instruction->rm, lane, element_bits);
                uint64_t result_bits;
                if (is_double) {
                    union { uint64_t bits; double value; } lhs = {lhs_bits};
                    union { uint64_t bits; double value; } rhs = {rhs_bits};
                    union { double value; uint64_t bits; } value;
                    value.value = operation == 0u ? lhs.value + rhs.value
                        : operation == 1u ? lhs.value - rhs.value
                        : operation == 2u ? lhs.value * rhs.value
                        : lhs.value / rhs.value;
                    result_bits = value.bits;
                } else {
                    union { uint32_t bits; float value; } lhs = {(uint32_t)lhs_bits};
                    union { uint32_t bits; float value; } rhs = {(uint32_t)rhs_bits};
                    union { float value; uint32_t bits; } value;
                    value.value = operation == 0u ? lhs.value + rhs.value
                        : operation == 1u ? lhs.value - rhs.value
                        : operation == 2u ? lhs.value * rhs.value
                        : lhs.value / rhs.value;
                    result_bits = value.bits;
                }
                write_vector_element(&vector_result, lane, element_bits, result_bits);
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
        }
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
            union { double value; uint64_t bits; } result;
            if (operation == 0) {
                result.value = lhs.value + rhs.value;
            } else if (operation == 1) {
                result.value = lhs.value - rhs.value;
            } else if (operation == 2) {
                result.value = lhs.value * rhs.value;
            } else if (operation == 3) {
                result.value = lhs.value / rhs.value;
            } else {
                return 0;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
            union { float value; uint32_t bits; } result;
            if (operation == 0) {
                result.value = lhs.value + rhs.value;
            } else if (operation == 1) {
                result.value = lhs.value - rhs.value;
            } else if (operation == 2) {
                result.value = lhs.value * rhs.value;
            } else if (operation == 3) {
                result.value = lhs.value / rhs.value;
            } else {
                return 0;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_INTEGER_MINMAX: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
        int is_unsigned = (instruction->flags & 2u) != 0u;
        int select_minimum = (instruction->flags & 4u) != 0u;
        AVZNativeVectorRegister vector_result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t lhs = read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t rhs = read_vector_element(cpu, instruction->rm, lane, element_bits);
            int select_lhs;
            if (is_unsigned) {
                select_lhs = select_minimum ? lhs < rhs : lhs > rhs;
            } else {
                int64_t signed_lhs = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                int64_t signed_rhs = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rm, lane, element_bits
                );
                select_lhs = select_minimum ? signed_lhs < signed_rhs : signed_lhs > signed_rhs;
            }
            write_vector_element(
                &vector_result, lane, element_bits, select_lhs ? lhs : rhs
            );
        }
        cpu->v[instruction->rd] = vector_result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_MINMAX: {
        uint8_t operation = instruction->flags & 3u;
        int is_double = (instruction->flags & 4u) != 0;
        int numeric = operation < 2u;
        int minimum = (operation & 1u) != 0;
        if ((instruction->flags & 8u) != 0u) {
            unsigned element_bits = is_double ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 16u) != 0u ? 128u : 64u;
            AVZNativeVectorRegister vector_result = {0, 0};
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                uint64_t lhs_bits = read_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                uint64_t rhs_bits = read_vector_element(
                    cpu, instruction->rm, lane, element_bits
                );
                uint64_t result_bits;
                if (is_double) {
                    union { uint64_t bits; double value; } lhs = {lhs_bits};
                    union { uint64_t bits; double value; } rhs = {rhs_bits};
                    union { double value; uint64_t bits; } result;
                    if (!numeric && (isnan(lhs.value) || isnan(rhs.value))) {
                        result.value = NAN;
                    } else {
                        result.value = minimum
                            ? fmin(lhs.value, rhs.value)
                            : fmax(lhs.value, rhs.value);
                    }
                    result_bits = result.bits;
                } else {
                    union { uint32_t bits; float value; } lhs = {(uint32_t)lhs_bits};
                    union { uint32_t bits; float value; } rhs = {(uint32_t)rhs_bits};
                    union { float value; uint32_t bits; } result;
                    if (!numeric && (isnan(lhs.value) || isnan(rhs.value))) {
                        result.value = NAN;
                    } else {
                        result.value = minimum
                            ? fminf(lhs.value, rhs.value)
                            : fmaxf(lhs.value, rhs.value);
                    }
                    result_bits = result.bits;
                }
                write_vector_element(
                    &vector_result, lane, element_bits, result_bits
                );
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
        }
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
            union { double value; uint64_t bits; } result;
            if (!numeric && (isnan(lhs.value) || isnan(rhs.value))) {
                result.value = NAN;
            } else {
                result.value = minimum ? fmin(lhs.value, rhs.value) : fmax(lhs.value, rhs.value);
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
            union { float value; uint32_t bits; } result;
            if (!numeric && (isnan(lhs.value) || isnan(rhs.value))) {
                result.value = NAN;
            } else {
                result.value = minimum ? fminf(lhs.value, rhs.value) : fmaxf(lhs.value, rhs.value);
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_NEGATED_MULTIPLY: {
        int is_double = (instruction->flags & 1u) != 0;
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
            union { double value; uint64_t bits; } result = {-(lhs.value * rhs.value)};
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
            union { float value; uint32_t bits; } result = {-(lhs.value * rhs.value)};
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_FUSED_MULTIPLY_ADD: {
        int subtract_product = (instruction->flags & 1u) != 0;
        int negate_result = (instruction->flags & 2u) != 0;
        int is_double = (instruction->flags & 4u) != 0;
        if ((instruction->flags & 8u) != 0u) {
            unsigned element_bits = is_double ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 16u) != 0u ? 128u : 64u;
            int selected_element = (instruction->flags & 32u) != 0u;
            AVZNativeVectorRegister vector_result = {0, 0};
#if defined(__aarch64__) && defined(__ARM_NEON)
            if (is_double) {
                float64x2_t addend;
                float64x2_t lhs;
                float64x2_t rhs;
                memcpy(&addend, &cpu->v[instruction->rd], sizeof(addend));
                memcpy(&lhs, &cpu->v[instruction->rn], sizeof(lhs));
                if (selected_element) {
                    uint64_t rhs_bits = read_vector_element(
                        cpu, instruction->rm, instruction->condition, 64u
                    );
                    double rhs_scalar;
                    memcpy(&rhs_scalar, &rhs_bits, sizeof(rhs_scalar));
                    rhs = vdupq_n_f64(rhs_scalar);
                } else {
                    memcpy(&rhs, &cpu->v[instruction->rm], sizeof(rhs));
                }
                float64x2_t result = subtract_product
                    ? vfmsq_f64(addend, lhs, rhs)
                    : vfmaq_f64(addend, lhs, rhs);
                memcpy(&vector_result, &result, sizeof(result));
            } else if (vector_bits == 128u) {
                float32x4_t addend;
                float32x4_t lhs;
                float32x4_t rhs;
                memcpy(&addend, &cpu->v[instruction->rd], sizeof(addend));
                memcpy(&lhs, &cpu->v[instruction->rn], sizeof(lhs));
                if (selected_element) {
                    uint32_t rhs_bits = (uint32_t)read_vector_element(
                        cpu, instruction->rm, instruction->condition, 32u
                    );
                    float rhs_scalar;
                    memcpy(&rhs_scalar, &rhs_bits, sizeof(rhs_scalar));
                    rhs = vdupq_n_f32(rhs_scalar);
                } else {
                    memcpy(&rhs, &cpu->v[instruction->rm], sizeof(rhs));
                }
                float32x4_t result = subtract_product
                    ? vfmsq_f32(addend, lhs, rhs)
                    : vfmaq_f32(addend, lhs, rhs);
                memcpy(&vector_result, &result, sizeof(result));
            } else {
                float32x2_t addend;
                float32x2_t lhs;
                float32x2_t rhs;
                memcpy(&addend, &cpu->v[instruction->rd].low, sizeof(addend));
                memcpy(&lhs, &cpu->v[instruction->rn].low, sizeof(lhs));
                if (selected_element) {
                    uint32_t rhs_bits = (uint32_t)read_vector_element(
                        cpu, instruction->rm, instruction->condition, 32u
                    );
                    float rhs_scalar;
                    memcpy(&rhs_scalar, &rhs_bits, sizeof(rhs_scalar));
                    rhs = vdup_n_f32(rhs_scalar);
                } else {
                    memcpy(&rhs, &cpu->v[instruction->rm].low, sizeof(rhs));
                }
                float32x2_t result = subtract_product
                    ? vfms_f32(addend, lhs, rhs)
                    : vfma_f32(addend, lhs, rhs);
                memcpy(&vector_result.low, &result, sizeof(result));
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
#endif
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                unsigned source_lane = selected_element ? instruction->condition : lane;
                uint64_t lhs_bits = read_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                uint64_t rhs_bits = read_vector_element(
                    cpu, instruction->rm, source_lane, element_bits
                );
                uint64_t addend_bits = read_vector_element(
                    cpu, instruction->rd, lane, element_bits
                );
                uint64_t result_bits;
                if (is_double) {
                    union { uint64_t bits; double value; } lhs = {lhs_bits};
                    union { uint64_t bits; double value; } rhs = {rhs_bits};
                    union { uint64_t bits; double value; } addend = {addend_bits};
                    union { double value; uint64_t bits; } value;
                    value.value = subtract_product
                        ? fma(-lhs.value, rhs.value, addend.value)
                        : fma(lhs.value, rhs.value, addend.value);
                    result_bits = value.bits;
                } else {
                    union { uint32_t bits; float value; } lhs = {(uint32_t)lhs_bits};
                    union { uint32_t bits; float value; } rhs = {(uint32_t)rhs_bits};
                    union { uint32_t bits; float value; } addend = {(uint32_t)addend_bits};
                    union { float value; uint32_t bits; } value;
                    value.value = subtract_product
                        ? fmaf(-lhs.value, rhs.value, addend.value)
                        : fmaf(lhs.value, rhs.value, addend.value);
                    result_bits = value.bits;
                }
                write_vector_element(&vector_result, lane, element_bits, result_bits);
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
        }
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
            union { uint64_t bits; double value; } addend = {cpu->v[instruction->rt].low};
            union { double value; uint64_t bits; } result;
            result.value = fma(
                subtract_product ? -lhs.value : lhs.value,
                rhs.value,
                addend.value
            );
            if (negate_result) {
                result.value = -result.value;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
            union { uint32_t bits; float value; } addend = {(uint32_t)cpu->v[instruction->rt].low};
            union { float value; uint32_t bits; } result;
            result.value = fmaf(
                subtract_product ? -lhs.value : lhs.value,
                rhs.value,
                addend.value
            );
            if (negate_result) {
                result.value = -result.value;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_UNARY: {
        uint8_t operation = instruction->flags & 3u;
        int is_double = (instruction->flags & 4u) != 0;
        if ((instruction->flags & 8u) != 0u) {
            unsigned element_bits = is_double ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 16u) != 0u ? 128u : 64u;
            AVZNativeVectorRegister vector_result = {0, 0};
#if defined(__aarch64__) && defined(__ARM_NEON)
            if (is_double) {
                float64x2_t source;
                float64x2_t result;
                memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
                result = operation == 0u ? vabsq_f64(source)
                    : operation == 1u ? vnegq_f64(source) : vsqrtq_f64(source);
                memcpy(&vector_result, &result, sizeof(result));
            } else if (vector_bits == 128u) {
                float32x4_t source;
                float32x4_t result;
                memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
                result = operation == 0u ? vabsq_f32(source)
                    : operation == 1u ? vnegq_f32(source) : vsqrtq_f32(source);
                memcpy(&vector_result, &result, sizeof(result));
            } else {
                float32x2_t source;
                float32x2_t result;
                memcpy(&source, &cpu->v[instruction->rn].low, sizeof(source));
                result = operation == 0u ? vabs_f32(source)
                    : operation == 1u ? vneg_f32(source) : vsqrt_f32(source);
                memcpy(&vector_result.low, &result, sizeof(result));
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
#endif
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                uint64_t source_bits = read_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                uint64_t result_bits;
                if (operation == 0u) {
                    result_bits = source_bits & ~sign_bit_for_bits(element_bits);
                } else if (operation == 1u) {
                    result_bits = source_bits ^ sign_bit_for_bits(element_bits);
                } else if (is_double) {
                    union { uint64_t bits; double value; } source = {source_bits};
                    union { double value; uint64_t bits; } result = {sqrt(source.value)};
                    result_bits = result.bits;
                } else {
                    union { uint32_t bits; float value; } source = {(uint32_t)source_bits};
                    union { float value; uint32_t bits; } result = {sqrtf(source.value)};
                    result_bits = result.bits;
                }
                write_vector_element(&vector_result, lane, element_bits, result_bits);
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
        }
        if (is_double) {
            union { uint64_t bits; double value; } source = {cpu->v[instruction->rn].low};
            union { double value; uint64_t bits; } result;
            if (operation == 0) {
                result.value = fabs(source.value);
            } else if (operation == 1) {
                result.value = -source.value;
            } else if (operation == 2) {
                result.value = sqrt(source.value);
            } else {
                return 0;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } source = {(uint32_t)cpu->v[instruction->rn].low};
            union { float value; uint32_t bits; } result;
            if (operation == 0) {
                result.value = fabsf(source.value);
            } else if (operation == 1) {
                result.value = -source.value;
            } else if (operation == 2) {
                result.value = sqrtf(source.value);
            } else {
                return 0;
            }
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_RECIPROCAL_ESTIMATE: {
        int reciprocal_square_root = (instruction->flags & 1u) != 0u;
        int is_double = (instruction->flags & 2u) != 0u;
        int is_vector = (instruction->flags & 4u) != 0u;
        int is_q = (instruction->flags & 8u) != 0u;
        AVZNativeVectorRegister result = {0, 0};
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (is_double) {
            if (is_vector) {
                float64x2_t source;
                float64x2_t estimate;
                memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
                estimate = reciprocal_square_root
                    ? vrsqrteq_f64(source)
                    : vrecpeq_f64(source);
                memcpy(&result, &estimate, sizeof(result));
            } else {
                float64x1_t source;
                float64x1_t estimate;
                memcpy(&source, &cpu->v[instruction->rn].low, sizeof(source));
                estimate = reciprocal_square_root
                    ? vrsqrte_f64(source)
                    : vrecpe_f64(source);
                memcpy(&result.low, &estimate, sizeof(estimate));
            }
        } else if (is_vector && is_q) {
            float32x4_t source;
            float32x4_t estimate;
            memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
            estimate = reciprocal_square_root
                ? vrsqrteq_f32(source)
                : vrecpeq_f32(source);
            memcpy(&result, &estimate, sizeof(result));
        } else {
            float32x2_t source;
            float32x2_t estimate;
            memcpy(&source, &cpu->v[instruction->rn].low, sizeof(source));
            estimate = reciprocal_square_root
                ? vrsqrte_f32(source)
                : vrecpe_f32(source);
            memcpy(&result.low, &estimate, sizeof(estimate));
            if (!is_vector) {
                result.low &= UINT64_C(0xffffffff);
            }
        }
#else
        unsigned element_bits = is_double ? 64u : 32u;
        unsigned lane_count = is_vector ? ((is_q ? 128u : 64u) / element_bits) : 1u;
        for (unsigned lane = 0; lane < lane_count; lane++) {
            uint64_t source_bits = read_vector_element(
                cpu, instruction->rn, lane, element_bits
            );
            uint64_t result_bits;
            if (is_double) {
                union { uint64_t bits; double value; } source = {source_bits};
                union { double value; uint64_t bits; } estimate;
                estimate.value = reciprocal_square_root
                    ? 1.0 / sqrt(source.value)
                    : 1.0 / source.value;
                result_bits = estimate.bits;
            } else {
                union { uint32_t bits; float value; } source = {(uint32_t)source_bits};
                union { float value; uint32_t bits; } estimate;
                estimate.value = reciprocal_square_root
                    ? 1.0f / sqrtf(source.value)
                    : 1.0f / source.value;
                result_bits = estimate.bits;
            }
            write_vector_element(&result, lane, element_bits, result_bits);
        }
#endif
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_RECIPROCAL_STEP: {
        int reciprocal_square_root = (instruction->flags & 1u) != 0u;
        int is_double = (instruction->flags & 2u) != 0u;
        int is_vector = (instruction->flags & 4u) != 0u;
        int is_q = (instruction->flags & 8u) != 0u;
        AVZNativeVectorRegister result = {0, 0};
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (is_double) {
            if (is_vector) {
                float64x2_t lhs;
                float64x2_t rhs;
                float64x2_t step;
                memcpy(&lhs, &cpu->v[instruction->rn], sizeof(lhs));
                memcpy(&rhs, &cpu->v[instruction->rm], sizeof(rhs));
                step = reciprocal_square_root
                    ? vrsqrtsq_f64(lhs, rhs)
                    : vrecpsq_f64(lhs, rhs);
                memcpy(&result, &step, sizeof(result));
            } else {
                float64x1_t lhs;
                float64x1_t rhs;
                float64x1_t step;
                memcpy(&lhs, &cpu->v[instruction->rn].low, sizeof(lhs));
                memcpy(&rhs, &cpu->v[instruction->rm].low, sizeof(rhs));
                step = reciprocal_square_root
                    ? vrsqrts_f64(lhs, rhs)
                    : vrecps_f64(lhs, rhs);
                memcpy(&result.low, &step, sizeof(step));
            }
        } else if (is_vector && is_q) {
            float32x4_t lhs;
            float32x4_t rhs;
            float32x4_t step;
            memcpy(&lhs, &cpu->v[instruction->rn], sizeof(lhs));
            memcpy(&rhs, &cpu->v[instruction->rm], sizeof(rhs));
            step = reciprocal_square_root
                ? vrsqrtsq_f32(lhs, rhs)
                : vrecpsq_f32(lhs, rhs);
            memcpy(&result, &step, sizeof(result));
        } else {
            float32x2_t lhs;
            float32x2_t rhs;
            float32x2_t step;
            memcpy(&lhs, &cpu->v[instruction->rn].low, sizeof(lhs));
            memcpy(&rhs, &cpu->v[instruction->rm].low, sizeof(rhs));
            step = reciprocal_square_root
                ? vrsqrts_f32(lhs, rhs)
                : vrecps_f32(lhs, rhs);
            memcpy(&result.low, &step, sizeof(step));
            if (!is_vector) {
                result.low &= UINT64_C(0xffffffff);
            }
        }
#else
        unsigned element_bits = is_double ? 64u : 32u;
        unsigned lane_count = is_vector ? ((is_q ? 128u : 64u) / element_bits) : 1u;
        for (unsigned lane = 0; lane < lane_count; lane++) {
            uint64_t lhs_bits = read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t rhs_bits = read_vector_element(cpu, instruction->rm, lane, element_bits);
            uint64_t result_bits;
            if (is_double) {
                union { uint64_t bits; double value; } lhs = {lhs_bits};
                union { uint64_t bits; double value; } rhs = {rhs_bits};
                union { double value; uint64_t bits; } step;
                step.value = reciprocal_square_root
                    ? fma(-lhs.value, rhs.value, 3.0) * 0.5
                    : fma(-lhs.value, rhs.value, 2.0);
                result_bits = step.bits;
            } else {
                union { uint32_t bits; float value; } lhs = {(uint32_t)lhs_bits};
                union { uint32_t bits; float value; } rhs = {(uint32_t)rhs_bits};
                union { float value; uint32_t bits; } step;
                step.value = reciprocal_square_root
                    ? fmaf(-lhs.value, rhs.value, 3.0f) * 0.5f
                    : fmaf(-lhs.value, rhs.value, 2.0f);
                result_bits = step.bits;
            }
            write_vector_element(&result, lane, element_bits, result_bits);
        }
#endif
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_ROUND_INTEGRAL: {
        unsigned rounding_mode = instruction->flags & 7u;
        int is_double = (instruction->flags & 8u) != 0;
        if (rounding_mode == 5) {
            static const unsigned fpcr_rounding_modes[4] = {1, 2, 3, 0};
            rounding_mode = fpcr_rounding_modes[(cpu->fpcr >> 22) & 3u];
        }
        if ((instruction->flags & 16u) != 0u) {
            unsigned element_bits = is_double ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 32u) != 0u ? 128u : 64u;
            AVZNativeVectorRegister vector_result = {0, 0};
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                uint64_t source_bits = read_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                uint64_t result_bits;
                if (is_double) {
                    union { uint64_t bits; double value; } source = {source_bits};
                    union { double value; uint64_t bits; } result;
                    result.value = isfinite(source.value)
                        ? round_fp_to_integral(source.value, rounding_mode)
                        : source.value;
                    result_bits = result.bits;
                } else {
                    union { uint32_t bits; float value; } source = {(uint32_t)source_bits};
                    union { float value; uint32_t bits; } result;
                    result.value = isfinite(source.value)
                        ? (float)round_fp_to_integral((double)source.value, rounding_mode)
                        : source.value;
                    result_bits = result.bits;
                }
                write_vector_element(&vector_result, lane, element_bits, result_bits);
            }
            cpu->v[instruction->rd] = vector_result;
            cpu->pc = pc + 4;
            return 1;
        }
        if (is_double) {
            union { uint64_t bits; double value; } source = {cpu->v[instruction->rn].low};
            if (!isfinite(source.value)) {
                cpu->v[instruction->rd] = (AVZNativeVectorRegister){source.bits, 0};
            } else {
                union { double value; uint64_t bits; } result = {
                    round_fp_to_integral(source.value, rounding_mode)
                };
                cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
            }
        } else {
            union { uint32_t bits; float value; } source = {(uint32_t)cpu->v[instruction->rn].low};
            if (!isfinite(source.value)) {
                cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)source.bits, 0};
            } else {
                union { float value; uint32_t bits; } result = {
                    (float)round_fp_to_integral((double)source.value, rounding_mode)
                };
                cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
            }
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SCALAR_FP_ABSOLUTE_DIFFERENCE: {
        int is_double = (instruction->flags & 1u) != 0;
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
            union { double value; uint64_t bits; } result = {fabs(lhs.value - rhs.value)};
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){result.bits, 0};
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
            union { float value; uint32_t bits; } result = {fabsf(lhs.value - rhs.value)};
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)result.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_IMMEDIATE_MOVE:
        cpu->v[instruction->rd] = duplicate_simd_element(
            (uint64_t)instruction->immediate,
            instruction->bits,
            (instruction->flags & 1u) != 0
        );
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_SELECT: {
        int is_double = (instruction->flags & 1) != 0;
        AVZNativeVectorRegister source = condition_holds(instruction->condition, cpu->pstate)
            ? cpu->v[instruction->rn]
            : cpu->v[instruction->rm];
        cpu->v[instruction->rd] = is_double
            ? (AVZNativeVectorRegister){source.low, 0}
            : (AVZNativeVectorRegister){source.low & UINT64_C(0xffffffff), 0};
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_CONDITIONAL_COMPARE: {
        uint64_t flags;
        if (condition_holds(instruction->condition, cpu->pstate)) {
            if ((instruction->flags & 1u) != 0) {
                union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
                union { uint64_t bits; double value; } rhs = {cpu->v[instruction->rm].low};
                flags = fp_compare_nzcv_double(lhs.value, rhs.value);
            } else {
                union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
                union { uint32_t bits; float value; } rhs = {(uint32_t)cpu->v[instruction->rm].low};
                flags = fp_compare_nzcv_float(lhs.value, rhs.value);
            }
        } else {
            flags = ((uint64_t)instruction->immediate & UINT64_C(0xf)) << 28;
        }
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | flags;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_COMPARE: {
        int is_double = (instruction->flags & 1) != 0;
        int compare_zero = (instruction->flags & 2) != 0;
        uint64_t flags;
        if (is_double) {
            union { uint64_t bits; double value; } lhs = {cpu->v[instruction->rn].low};
            union { uint64_t bits; double value; } rhs = {compare_zero ? 0 : cpu->v[instruction->rm].low};
            flags = fp_compare_nzcv_double(lhs.value, rhs.value);
        } else {
            union { uint32_t bits; float value; } lhs = {(uint32_t)cpu->v[instruction->rn].low};
            union { uint32_t bits; float value; } rhs = {compare_zero ? 0 : (uint32_t)cpu->v[instruction->rm].low};
            flags = fp_compare_nzcv_float(lhs.value, rhs.value);
        }
        cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_FP_SCALAR_CONVERT_TO_INTEGER: {
        int is_double = (instruction->flags & 1) != 0;
        int is_unsigned = (instruction->flags & 4) != 0;
        int vector_destination = (instruction->flags & 8) != 0;
        unsigned bits = instruction->bits == 0 ? 64 : instruction->bits;
        double value;
        if (is_double) {
            union { uint64_t bits; double value; } source = {cpu->v[instruction->rn].low};
            value = source.value;
        } else {
            union { uint32_t bits; float value; } source = {(uint32_t)cpu->v[instruction->rn].low};
            value = (double)source.value;
        }
        if (instruction->shift_amount != 0u) {
            value = ldexp(value, instruction->shift_amount);
        }
        value = round_fp_to_integral(value, (instruction->flags >> 4) & 7u);
        uint64_t converted = is_unsigned
            ? unsigned_integer_bits_from_fp(value, bits)
            : signed_integer_bits_from_fp(value, bits);
        if (bits == 32) {
            converted &= UINT64_C(0xffffffff);
        }
        if (vector_destination) {
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){converted, 0};
        } else {
            write_register(cpu, instruction->rd, converted);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_CONVERT_TO_INTEGER: {
        int is_double = (instruction->flags & 1u) != 0u;
        int is_unsigned = (instruction->flags & 2u) != 0u;
        int is_q = (instruction->flags & 4u) != 0u;
        unsigned rounding_mode = (instruction->flags >> 3) & 7u;
        AVZNativeVectorRegister result = {0, 0};
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (is_double) {
            float64x2_t source;
            memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
            if (is_unsigned) {
                uint64x2_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtnq_u64_f64(source); break;
                case 2: converted = vcvtpq_u64_f64(source); break;
                case 3: converted = vcvtmq_u64_f64(source); break;
                case 4: converted = vcvtaq_u64_f64(source); break;
                default: converted = vcvtq_u64_f64(source); break;
                }
                memcpy(&result, &converted, sizeof(result));
            } else {
                int64x2_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtnq_s64_f64(source); break;
                case 2: converted = vcvtpq_s64_f64(source); break;
                case 3: converted = vcvtmq_s64_f64(source); break;
                case 4: converted = vcvtaq_s64_f64(source); break;
                default: converted = vcvtq_s64_f64(source); break;
                }
                memcpy(&result, &converted, sizeof(result));
            }
        } else if (is_q) {
            float32x4_t source;
            memcpy(&source, &cpu->v[instruction->rn], sizeof(source));
            if (is_unsigned) {
                uint32x4_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtnq_u32_f32(source); break;
                case 2: converted = vcvtpq_u32_f32(source); break;
                case 3: converted = vcvtmq_u32_f32(source); break;
                case 4: converted = vcvtaq_u32_f32(source); break;
                default: converted = vcvtq_u32_f32(source); break;
                }
                memcpy(&result, &converted, sizeof(result));
            } else {
                int32x4_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtnq_s32_f32(source); break;
                case 2: converted = vcvtpq_s32_f32(source); break;
                case 3: converted = vcvtmq_s32_f32(source); break;
                case 4: converted = vcvtaq_s32_f32(source); break;
                default: converted = vcvtq_s32_f32(source); break;
                }
                memcpy(&result, &converted, sizeof(result));
            }
        } else {
            float32x2_t source;
            memcpy(&source, &cpu->v[instruction->rn].low, sizeof(source));
            if (is_unsigned) {
                uint32x2_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtn_u32_f32(source); break;
                case 2: converted = vcvtp_u32_f32(source); break;
                case 3: converted = vcvtm_u32_f32(source); break;
                case 4: converted = vcvta_u32_f32(source); break;
                default: converted = vcvt_u32_f32(source); break;
                }
                memcpy(&result.low, &converted, sizeof(converted));
            } else {
                int32x2_t converted;
                switch (rounding_mode) {
                case 1: converted = vcvtn_s32_f32(source); break;
                case 2: converted = vcvtp_s32_f32(source); break;
                case 3: converted = vcvtm_s32_f32(source); break;
                case 4: converted = vcvta_s32_f32(source); break;
                default: converted = vcvt_s32_f32(source); break;
                }
                memcpy(&result.low, &converted, sizeof(converted));
            }
        }
#else
        unsigned element_bits = is_double ? 64u : 32u;
        unsigned vector_bits = is_q ? 128u : 64u;
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t source_bits = read_vector_element(
                cpu, instruction->rn, lane, element_bits
            );
            double value;
            if (is_double) {
                union { uint64_t bits; double value; } source = {source_bits};
                value = source.value;
            } else {
                union { uint32_t bits; float value; } source = {(uint32_t)source_bits};
                value = (double)source.value;
            }
            value = round_fp_to_integral(value, rounding_mode);
            uint64_t converted = is_unsigned
                ? unsigned_integer_bits_from_fp(value, element_bits)
                : signed_integer_bits_from_fp(value, element_bits);
            write_vector_element(&result, lane, element_bits, converted);
        }
#endif
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SCALAR_SIGNED_INTEGER_TO_FP: {
        int is_unsigned = (instruction->flags & 2) != 0;
        if ((instruction->flags & 4u) != 0u) {
            unsigned element_bits = (instruction->flags & 1u) != 0u ? 64u : 32u;
            unsigned vector_bits = (instruction->flags & 8u) != 0u ? 128u : 64u;
            AVZNativeVectorRegister converted_vector = {0, 0};
            for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
                uint64_t source = read_vector_element(cpu, instruction->rn, lane, element_bits);
                uint64_t converted_bits;
                if (element_bits == 64u) {
                    union { double value; uint64_t bits; } converted;
                    converted.value = is_unsigned ? (double)source : (double)(int64_t)source;
                    converted_bits = converted.bits;
                } else {
                    union { float value; uint32_t bits; } converted;
                    converted.value = is_unsigned
                        ? (float)(uint32_t)source
                        : (float)(int32_t)(uint32_t)source;
                    converted_bits = converted.bits;
                }
                write_vector_element(&converted_vector, lane, element_bits, converted_bits);
            }
            cpu->v[instruction->rd] = converted_vector;
            cpu->pc = pc + 4;
            return 1;
        }
        if ((instruction->flags & 1) != 0) {
            union { double value; uint64_t bits; } converted;
            converted.value = is_unsigned
                ? (double)cpu->v[instruction->rn].low
                : (double)(int64_t)cpu->v[instruction->rn].low;
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){converted.bits, 0};
        } else {
            union { float value; uint32_t bits; } converted;
            converted.value = is_unsigned
                ? (float)(uint32_t)cpu->v[instruction->rn].low
                : (float)(int32_t)(uint32_t)cpu->v[instruction->rn].low;
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){(uint64_t)converted.bits, 0};
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_INSERT_GENERAL_TO_ELEMENT: {
        AVZNativeVectorRegister vector = cpu->v[instruction->rd];
        write_vector_element(
            &vector,
            instruction->condition,
            instruction->bits,
            read_register(cpu, instruction->rn)
        );
        cpu->v[instruction->rd] = vector;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_INSERT_VECTOR_ELEMENT: {
        uint64_t value = read_vector_element(
            cpu,
            instruction->rn,
            instruction->shift_amount,
            instruction->bits
        );
        AVZNativeVectorRegister vector = cpu->v[instruction->rd];
        write_vector_element(
            &vector,
            instruction->condition,
            instruction->bits,
            value
        );
        cpu->v[instruction->rd] = vector;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SIGNED_SHIFT_LONG_S_TO_D: {
        unsigned shift = instruction->shift_amount;
        unsigned source_lane_base = instruction->condition;
        unsigned source_bits = instruction->bits != 0 ? instruction->bits : 32u;
        unsigned destination_bits = source_bits * 2u;
        unsigned destination_lane_count = 128u / destination_bits;
        AVZNativeVectorRegister result = {0, 0};

        if (!(source_bits == 8u || source_bits == 16u || source_bits == 32u) ||
            shift > source_bits) {
            return 0;
        }

        for (unsigned lane = 0; lane < destination_lane_count; lane++) {
            uint64_t source = (instruction->flags & 1u) != 0u
                ? read_vector_element(
                    cpu, instruction->rn, source_lane_base + lane, source_bits
                )
                : sign_extend_vector_element(
                    cpu, instruction->rn, source_lane_base + lane, source_bits
                );
            uint64_t value = source << shift;
            write_vector_element(&result, lane, destination_bits, value);
        }

        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_TABLE_LOOKUP: {
        unsigned lane_count = (instruction->flags & 1) != 0 ? 16u : 8u;
        unsigned table_register_count = instruction->condition;
        unsigned table_byte_count = table_register_count * 16u;
        int preserve_destination = (instruction->flags & 2) != 0;
        AVZNativeVectorRegister result = {0, 0};
        if (preserve_destination) {
            result.low = cpu->v[instruction->rd].low;
            result.high = lane_count == 16u ? cpu->v[instruction->rd].high : 0;
        }

        for (unsigned lane = 0; lane < lane_count; lane++) {
            uint64_t index = read_vector_element(cpu, instruction->rm, lane, 8);
            uint64_t byte = 0;
            if (index < table_byte_count) {
                unsigned table_register_offset = (unsigned)(index >> 4);
                unsigned table_lane = (unsigned)(index & 0xfu);
                unsigned source_register = (instruction->rn + table_register_offset) & 0x1fu;
                byte = read_vector_element(cpu, source_register, table_lane, 8);
            } else if (preserve_destination) {
                byte = read_vector_element(cpu, instruction->rd, lane, 8);
            }
            write_vector_element(&result, lane, 8, byte);
        }

        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_EXTRACT_VECTOR: {
        unsigned byte_count = (instruction->flags & 1u) != 0 ? 16u : 8u;
        unsigned byte_offset = instruction->shift_amount;
        AVZNativeVectorRegister first = cpu->v[instruction->rn];
        AVZNativeVectorRegister second = cpu->v[instruction->rm];
        AVZNativeVectorRegister result = {0, 0};

        if (byte_count == 8u) {
            if (byte_offset == 0u) {
                result.low = first.low;
            } else {
                unsigned shift = byte_offset * 8u;
                result.low = (first.low >> shift) | (second.low << (64u - shift));
            }
        } else if (byte_offset == 0u) {
            result = first;
        } else if (byte_offset < 8u) {
            unsigned shift = byte_offset * 8u;
            result.low = (first.low >> shift) | (first.high << (64u - shift));
            result.high = (first.high >> shift) | (second.low << (64u - shift));
        } else if (byte_offset == 8u) {
            result.low = first.high;
            result.high = second.low;
        } else {
            unsigned shift = (byte_offset - 8u) * 8u;
            result.low = (first.high >> shift) | (second.low << (64u - shift));
            result.high = (second.low >> shift) | (second.high << (64u - shift));
        }

        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_PERMUTE_TWO_VECTOR: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = instruction->condition != 0 ? 128u : 64u;
        unsigned lane_count = vector_bits / element_bits;
        unsigned half_lane_count = lane_count / 2u;
        unsigned op = instruction->flags & 7u;
        unsigned operation = op & 3u;
        unsigned second_part = (op & 4u) != 0;
        AVZNativeVectorRegister result = {0, 0};

        if (lane_count < 2u || operation == 0u) {
            return 0;
        }

        for (unsigned lane = 0; lane < lane_count; lane++) {
            unsigned source_register = instruction->rn;
            unsigned source_lane = 0;
            switch (operation) {
            case 1u:
                if (lane < half_lane_count) {
                    source_lane = lane * 2u + second_part;
                } else {
                    source_register = instruction->rm;
                    source_lane = (lane - half_lane_count) * 2u + second_part;
                }
                break;
            case 2u:
                source_register = (lane & 1u) == 0 ? instruction->rn : instruction->rm;
                source_lane = (lane / 2u) * 2u + second_part;
                break;
            case 3u:
                source_register = (lane & 1u) == 0 ? instruction->rn : instruction->rm;
                source_lane = (lane / 2u) + (second_part ? half_lane_count : 0u);
                break;
            default:
                return 0;
            }

            write_vector_element(
                &result,
                lane,
                element_bits,
                read_vector_element(cpu, source_register, source_lane, element_bits)
            );
        }

        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_ADD_VECTOR: {
        unsigned element_bits = instruction->bits;
        if ((instruction->flags & 4u) != 0u) {
            unsigned destination_bits = element_bits * 2u;
            unsigned lane_count = 128u / destination_bits;
            unsigned source_lane_base = (instruction->flags & 1u) != 0u
                ? 64u / element_bits
                : 0u;
            int subtract = (instruction->flags & 2u) != 0u;
            int is_unsigned = (instruction->flags & 8u) != 0u;
            int lhs_is_wide = (instruction->flags & 16u) != 0u;
            uint64_t destination_mask = mask_for_bits(destination_bits);
            AVZNativeVectorRegister result = {0, 0};

            for (unsigned lane = 0; lane < lane_count; lane++) {
                uint64_t lhs = lhs_is_wide
                    ? read_vector_element(cpu, instruction->rn, lane, destination_bits)
                    : (is_unsigned
                        ? read_vector_element(
                            cpu, instruction->rn, source_lane_base + lane, element_bits
                        )
                        : sign_extend_vector_element(
                            cpu, instruction->rn, source_lane_base + lane, element_bits
                        ));
                uint64_t rhs = is_unsigned
                    ? read_vector_element(
                        cpu, instruction->rm, source_lane_base + lane, element_bits
                    )
                    : sign_extend_vector_element(
                        cpu, instruction->rm, source_lane_base + lane, element_bits
                    );
                uint64_t value = subtract ? lhs - rhs : lhs + rhs;
                write_vector_element(
                    &result, lane, destination_bits, value & destination_mask
                );
            }

            cpu->v[instruction->rd] = result;
            cpu->pc = pc + 4;
            return 1;
        }
        unsigned vector_bits = (instruction->flags & 1) != 0 ? 128 : 64;
        int subtract = (instruction->flags & 2u) != 0;
        uint64_t lane_mask = mask_for_bits(element_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t lhs = read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t rhs = read_vector_element(cpu, instruction->rm, lane, element_bits);
            uint64_t value = subtract ? lhs - rhs : lhs + rhs;
            write_vector_element(&result, lane, element_bits, value & lane_mask);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_UNSIGNED_SHIFT_REGISTER: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
        uint64_t lane_mask = mask_for_bits(element_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t value = read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t raw_shift = read_vector_element(cpu, instruction->rm, lane, element_bits);
            int shift = (int)(int8_t)(raw_shift & UINT64_C(0xff));
            uint64_t shifted = 0;
            if (shift >= 0) {
                shifted = (unsigned)shift < element_bits
                    ? (value << (unsigned)shift) & lane_mask
                    : 0;
            } else {
                unsigned magnitude = (unsigned)(-shift);
                shifted = magnitude < element_bits ? value >> magnitude : 0;
            }
            write_vector_element(&result, lane, element_bits, shifted);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_INTEGER_NEGATE: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 2u) != 0u
            ? 64u
            : ((instruction->flags & 1u) != 0u ? 128u : 64u);
        uint64_t lane_mask = mask_for_bits(element_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t source = read_vector_element(cpu, instruction->rn, lane, element_bits);
            write_vector_element(&result, lane, element_bits, (UINT64_C(0) - source) & lane_mask);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE: {
        if (!execute_simd_shift_left_immediate_portable(cpu, instruction)) {
            return 0;
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG: {
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (execute_simd_multiply_long_neon(cpu, instruction)) {
            cpu->pc = pc + 4;
            return 1;
        }
#endif
        if ((instruction->flags & 4u) != 0u) {
            unsigned element_bits = instruction->bits;
            unsigned vector_bits = (instruction->flags & 8u) != 0u ? 128u : 64u;
            unsigned lane_count = vector_bits / element_bits;
            uint64_t lane_mask = mask_for_bits(element_bits);
            unsigned operation = (instruction->flags >> 4) & 3u;
            int by_element = (instruction->flags & 64u) != 0u;
            uint64_t selected_rhs = by_element
                ? read_vector_element(
                    cpu,
                    instruction->rm,
                    instruction->condition,
                    element_bits
                )
                : 0u;
            AVZNativeVectorRegister result = {0, 0};
            for (unsigned lane = 0; lane < lane_count; lane++) {
                uint64_t lhs = read_vector_element(
                    cpu, instruction->rn, lane, element_bits
                );
                uint64_t rhs = by_element
                    ? selected_rhs
                    : read_vector_element(cpu, instruction->rm, lane, element_bits);
                uint64_t value = (lhs * rhs) & lane_mask;
                if (operation != 0u) {
                    uint64_t accumulator = read_vector_element(
                        cpu, instruction->rd, lane, element_bits
                    );
                    value = operation == 1u
                        ? (accumulator + value) & lane_mask
                        : (accumulator - value) & lane_mask;
                }
                write_vector_element(
                    &result,
                    lane,
                    element_bits,
                    value
                );
            }
            cpu->v[instruction->rd] = result;
            cpu->pc = pc + 4;
            return 1;
        }

        unsigned source_bits = instruction->bits;
        unsigned destination_bits = source_bits * 2u;
        unsigned source_lane_base = (instruction->flags & 1u) != 0 ? 64u / source_bits : 0u;
        unsigned destination_lanes = 128u / destination_bits;
        int is_unsigned = (instruction->flags & 2u) != 0;
        int accumulates = (instruction->flags & 8u) != 0;
        int subtracts = (instruction->flags & 16u) != 0;
        int by_element = (instruction->flags & 64u) != 0;
        uint64_t selected_rhs = by_element
            ? read_vector_element(
                cpu, instruction->rm, instruction->condition, source_bits
            )
            : 0u;
        uint64_t destination_mask = mask_for_bits(destination_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < destination_lanes; lane++) {
            unsigned source_lane = source_lane_base + lane;
            uint64_t product;
            if (is_unsigned) {
                uint64_t lhs = read_vector_element(cpu, instruction->rn, source_lane, source_bits);
                uint64_t rhs = by_element
                    ? selected_rhs
                    : read_vector_element(cpu, instruction->rm, source_lane, source_bits);
                product = lhs * rhs;
            } else {
                int64_t lhs = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, source_lane, source_bits
                );
                int64_t rhs = by_element
                    ? sign_extend_u64(selected_rhs, source_bits)
                    : (int64_t)sign_extend_vector_element(
                        cpu, instruction->rm, source_lane, source_bits
                    );
                product = (uint64_t)(lhs * rhs);
            }
            if (accumulates) {
                uint64_t accumulator = read_vector_element(
                    cpu, instruction->rd, lane, destination_bits
                );
                product = subtracts
                    ? (accumulator - product) & destination_mask
                    : (accumulator + product) & destination_mask;
            }
            write_vector_element(&result, lane, destination_bits, product);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_NARROW_HIGH: {
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (execute_simd_narrow_high_neon(cpu, instruction)) {
            cpu->pc = pc + 4;
            return 1;
        }
#endif
        unsigned source_bits = instruction->bits;
        unsigned destination_bits = source_bits / 2u;
        unsigned lane_count = 128u / source_bits;
        unsigned writes_upper_half = instruction->flags & 1u;
        if ((instruction->flags & 32u) != 0u) {
            AVZNativeVectorRegister result = writes_upper_half != 0u
                ? cpu->v[instruction->rd]
                : (AVZNativeVectorRegister){0, 0};
            for (unsigned lane = 0; lane < lane_count; lane++) {
                write_vector_element(
                    &result,
                    lane + (writes_upper_half != 0u ? lane_count : 0u),
                    destination_bits,
                    read_vector_element(cpu, instruction->rn, lane, source_bits)
                );
            }
            cpu->v[instruction->rd] = result;
            cpu->pc = pc + 4;
            return 1;
        }
        if ((instruction->flags & 8u) != 0) {
            uint64_t source_mask = mask_for_bits(source_bits);
            uint64_t rounding = (instruction->flags & 16u) != 0u
                ? UINT64_C(1) << (instruction->shift_amount - 1u)
                : 0u;
            AVZNativeVectorRegister result = writes_upper_half != 0
                ? cpu->v[instruction->rd]
                : (AVZNativeVectorRegister){0, 0};
            for (unsigned lane = 0; lane < lane_count; lane++) {
                uint64_t value = read_vector_element(cpu, instruction->rn, lane, source_bits);
                value = ((value + rounding) & source_mask) >> instruction->shift_amount;
                write_vector_element(
                    &result,
                    lane + (writes_upper_half != 0 ? lane_count : 0u),
                    destination_bits,
                    value
                );
            }
            cpu->v[instruction->rd] = result;
            cpu->pc = pc + 4;
            return 1;
        }
        unsigned rounds = instruction->flags & 2u;
        unsigned subtracts = instruction->flags & 4u;
        uint64_t source_mask = mask_for_bits(source_bits);
        uint64_t rounding = rounds != 0 ? UINT64_C(1) << (destination_bits - 1u) : 0;
        AVZNativeVectorRegister result = writes_upper_half != 0
            ? cpu->v[instruction->rd]
            : (AVZNativeVectorRegister){0, 0};

        for (unsigned lane = 0; lane < lane_count; lane++) {
            uint64_t lhs = read_vector_element(cpu, instruction->rn, lane, source_bits);
            uint64_t rhs = read_vector_element(cpu, instruction->rm, lane, source_bits);
            uint64_t wide_result = subtracts != 0 ? lhs - rhs : lhs + rhs;
            wide_result = (wide_result + rounding) & source_mask;
            write_vector_element(
                &result,
                lane + (writes_upper_half != 0 ? lane_count : 0u),
                destination_bits,
                wide_result >> destination_bits
            );
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1) != 0 ? 128 : 64;
        unsigned comparison = instruction->flags >> 1;
        uint64_t lane_mask = mask_for_bits(element_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t lhs = read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t rhs = read_vector_element(cpu, instruction->rm, lane, element_bits);
            int matches;
            switch (comparison) {
            case 0:
                matches = lhs == rhs;
                break;
            case 1:
                matches = (lhs & rhs) != 0;
                break;
            case 2:
                matches = lhs > rhs;
                break;
            case 3:
                matches = lhs >= rhs;
                break;
            case 4:
                matches = lhs == 0;
                break;
            case 5:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) > 0;
                break;
            case 6:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) >= 0;
                break;
            case 7:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) < 0;
                break;
            case 8:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) <= 0;
                break;
            case 9:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) > (int64_t)sign_extend_vector_element(
                    cpu, instruction->rm, lane, element_bits
                );
                break;
            case 10:
                matches = (int64_t)sign_extend_vector_element(
                    cpu, instruction->rn, lane, element_bits
                ) >= (int64_t)sign_extend_vector_element(
                    cpu, instruction->rm, lane, element_bits
                );
                break;
            default:
                return 0;
            }
            write_vector_element(&result, lane, element_bits, matches ? lane_mask : 0);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_COMPARE_VECTOR: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
        unsigned comparison = instruction->flags >> 1;
        uint64_t lane_mask = mask_for_bits(element_bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t lhs_bits =
                read_vector_element(cpu, instruction->rn, lane, element_bits);
            uint64_t rhs_bits = comparison >= 5u
                ? 0u
                : read_vector_element(cpu, instruction->rm, lane, element_bits);
            int matches;
            if (element_bits == 32u) {
                union { uint32_t bits; float value; } lhs = {(uint32_t)lhs_bits};
                union { uint32_t bits; float value; } rhs = {(uint32_t)rhs_bits};
                switch (comparison) {
                case 0: matches = lhs.value == rhs.value; break;
                case 1: matches = lhs.value > rhs.value; break;
                case 2: matches = lhs.value >= rhs.value; break;
                case 3: matches = fabsf(lhs.value) > fabsf(rhs.value); break;
                case 4: matches = fabsf(lhs.value) >= fabsf(rhs.value); break;
                case 5: matches = lhs.value == 0.0f; break;
                case 6: matches = lhs.value > 0.0f; break;
                case 7: matches = lhs.value >= 0.0f; break;
                case 8: matches = lhs.value < 0.0f; break;
                case 9: matches = lhs.value <= 0.0f; break;
                default: return 0;
                }
            } else {
                union { uint64_t bits; double value; } lhs = {lhs_bits};
                union { uint64_t bits; double value; } rhs = {rhs_bits};
                switch (comparison) {
                case 0: matches = lhs.value == rhs.value; break;
                case 1: matches = lhs.value > rhs.value; break;
                case 2: matches = lhs.value >= rhs.value; break;
                case 3: matches = fabs(lhs.value) > fabs(rhs.value); break;
                case 4: matches = fabs(lhs.value) >= fabs(rhs.value); break;
                case 5: matches = lhs.value == 0.0; break;
                case 6: matches = lhs.value > 0.0; break;
                case 7: matches = lhs.value >= 0.0; break;
                case 8: matches = lhs.value < 0.0; break;
                case 9: matches = lhs.value <= 0.0; break;
                default: return 0;
                }
            }
            write_vector_element(
                &result,
                lane,
                element_bits,
                matches ? lane_mask : 0u
            );
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_REVERSE_ELEMENTS: {
        unsigned element_bits = instruction->bits;
        unsigned container_bits = instruction->shift_amount;
        unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
        unsigned elements_per_container = container_bits / element_bits;
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            unsigned container_start = (lane / elements_per_container) * elements_per_container;
            unsigned offset = lane % elements_per_container;
            unsigned source_lane = container_start + elements_per_container - 1u - offset;
            write_vector_element(
                &result,
                lane,
                element_bits,
                read_vector_element(cpu, instruction->rn, source_lane, element_bits)
            );
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS: {
        unsigned vector_bits = (instruction->flags & 1) != 0 ? 128 : 64;
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / 8u; lane++) {
            uint8_t byte = (uint8_t)read_vector_element(cpu, instruction->rn, lane, 8);
            write_vector_element(&result, lane, 8, popcount_u8(byte));
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
            uint64_t value = read_vector_element(
                cpu, instruction->rn, lane, element_bits
            );
            write_vector_element(
                &result, lane, element_bits,
                count_leading_zeros_width(value, element_bits)
            );
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_BITWISE_NOT:
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){
            ~cpu->v[instruction->rn].low,
            (instruction->flags & 1u) != 0 ? ~cpu->v[instruction->rn].high : 0
        };
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT: {
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (execute_simd_saturating_add_subtract_neon(cpu, instruction)) {
            cpu->pc = pc + 4;
            return 1;
        }
#endif
        if (!execute_simd_saturating_add_subtract_portable(cpu, instruction)) {
            return 0;
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE: {
#if defined(__aarch64__) && defined(__ARM_NEON)
        if (execute_simd_shift_right_immediate_neon(cpu, instruction)) {
            cpu->pc = pc + 4;
            return 1;
        }
#endif
        if (!execute_simd_shift_right_immediate_portable(cpu, instruction)) {
            return 0;
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_ORR_VECTOR: {
        unsigned operation = instruction->flags >> 1;
        AVZNativeVectorRegister destination = cpu->v[instruction->rd];
        AVZNativeVectorRegister lhs = cpu->v[instruction->rn];
        AVZNativeVectorRegister rhs = cpu->v[instruction->rm];
        AVZNativeVectorRegister result = {0, 0};
        switch (operation) {
        case 0:
            result.low = lhs.low | rhs.low;
            break;
        case 1:
            result.low = lhs.low ^ rhs.low;
            break;
        case 2:
            result.low = (destination.low & lhs.low) | (~destination.low & rhs.low);
            break;
        case 3:
            result.low = (destination.low & ~rhs.low) | (lhs.low & rhs.low);
            break;
        case 4:
            result.low = (destination.low & rhs.low) | (lhs.low & ~rhs.low);
            break;
        case 5:
            result.low = lhs.low & rhs.low;
            break;
        case 6:
            result.low = lhs.low & ~rhs.low;
            break;
        case 7:
            result.low = lhs.low | ~rhs.low;
            break;
        default:
            return 0;
        }
        if ((instruction->flags & 1u) != 0) {
            switch (operation) {
            case 0:
                result.high = lhs.high | rhs.high;
                break;
            case 1:
                result.high = lhs.high ^ rhs.high;
                break;
            case 2:
                result.high = (destination.high & lhs.high) | (~destination.high & rhs.high);
                break;
            case 3:
                result.high = (destination.high & ~rhs.high) | (lhs.high & rhs.high);
                break;
            case 4:
                result.high = (destination.high & rhs.high) | (lhs.high & ~rhs.high);
                break;
            case 5:
                result.high = lhs.high & rhs.high;
                break;
            case 6:
                result.high = lhs.high & ~rhs.high;
                break;
            case 7:
                result.high = lhs.high | ~rhs.high;
                break;
            }
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_UNSIGNED_MAX_PAIRWISE: {
        unsigned element_bits = instruction->bits;
        unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128 : 64;
        unsigned source_lanes = vector_bits / element_bits;
        unsigned half_lanes = source_lanes / 2u;
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < half_lanes; lane++) {
            uint64_t lhs0 = read_vector_element(cpu, instruction->rn, lane * 2u, element_bits);
            uint64_t lhs1 = read_vector_element(cpu, instruction->rn, lane * 2u + 1u, element_bits);
            uint64_t rhs0 = read_vector_element(cpu, instruction->rm, lane * 2u, element_bits);
            uint64_t rhs1 = read_vector_element(cpu, instruction->rm, lane * 2u + 1u, element_bits);
            write_vector_element(&result, lane, element_bits, lhs0 > lhs1 ? lhs0 : lhs1);
            write_vector_element(&result, half_lanes + lane, element_bits, rhs0 > rhs1 ? rhs0 : rhs1);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_DUPLICATE_GENERAL:
        cpu->v[instruction->rd] = duplicate_simd_element(
            read_register(cpu, instruction->rn),
            instruction->bits,
            (instruction->flags & 1) != 0
        );
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_MOVI_ZERO:
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){0, 0};
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_MOVI_BYTE: {
        uint64_t byte = (uint64_t)instruction->immediate & UINT64_C(0xff);
        uint64_t repeated = 0;
        for (unsigned lane = 0; lane < 8; lane++) {
            repeated |= byte << (lane * 8u);
        }
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){
            repeated,
            (instruction->flags & 1) != 0 ? repeated : 0
        };
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_MOVI_WORD_IMMEDIATE: {
        AVZNativeVectorRegister immediate = duplicate_simd_element(
            (uint64_t)instruction->immediate,
            instruction->bits,
            (instruction->flags & 1) != 0
        );
        if ((instruction->flags & 2u) != 0u) {
            cpu->v[instruction->rd].low |= immediate.low;
            if ((instruction->flags & 1u) != 0u) {
                cpu->v[instruction->rd].high |= immediate.high;
            } else {
                cpu->v[instruction->rd].high = 0;
            }
        } else if ((instruction->flags & 4u) != 0u) {
            cpu->v[instruction->rd].low &= ~immediate.low;
            if ((instruction->flags & 1u) != 0u) {
                cpu->v[instruction->rd].high &= ~immediate.high;
            } else {
                cpu->v[instruction->rd].high = 0;
            }
        } else {
            cpu->v[instruction->rd] = immediate;
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_MVNI_IMMEDIATE:
        cpu->v[instruction->rd] = duplicate_simd_element(
            (uint64_t)instruction->immediate,
            instruction->bits,
            (instruction->flags & 1) != 0
        );
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_MOVI_D_IMMEDIATE:
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){
            (uint64_t)instruction->immediate,
            (instruction->flags & 1) != 0 ? (uint64_t)instruction->immediate : 0
        };
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        uint64_t address = add_signed_offset(base, instruction->immediate);
        uint64_t value = 0;
        if ((instruction->flags & 1u) != 0u) {
            if (read_memory == NULL ||
                !read_memory(memory_context, address, instruction->width, &value)) {
                return 0;
            }
            if ((instruction->flags & 2u) != 0u) {
                value = sign_extend_loaded(value, instruction->bits);
                if ((instruction->flags & 4u) != 0u) {
                    value &= UINT64_C(0xffffffff);
                }
            }
            write_register(cpu, instruction->rt, value);
        } else {
            value = read_register(cpu, instruction->rt) &
                mask_for_bits(instruction->bits);
            if (write_memory == NULL ||
                !write_memory(
                    memory_context,
                    address,
                    instruction->width,
                    value
                )) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8u) != 0u) {
            write_base_register(
                cpu,
                instruction->rn,
                add_signed_offset(base, instruction->immediate2)
            );
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET: {
        uint64_t offset = extended_register_value(read_register(cpu, instruction->rm), instruction->condition)
            << instruction->shift_amount;
        uint64_t address = read_base_register(cpu, instruction->rn) + offset;
        uint64_t value = 0;
        if ((instruction->flags & 1u) != 0u) {
            if (read_memory == NULL ||
                !read_memory(memory_context, address, instruction->width, &value)) {
                return 0;
            }
            if ((instruction->flags & 2u) != 0u) {
                value = sign_extend_loaded(value, instruction->bits);
                if ((instruction->flags & 4u) != 0u) {
                    value &= UINT64_C(0xffffffff);
                }
            }
            write_register(cpu, instruction->rt, value);
        } else {
            value = read_register(cpu, instruction->rt) &
                mask_for_bits(instruction->bits);
            if (write_memory == NULL ||
                !write_memory(
                    memory_context,
                    address,
                    instruction->width,
                    value
                )) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_STORE_PAIR: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        uint64_t first_address = add_signed_offset(base, instruction->immediate);
        uint64_t second_address = first_address + instruction->width;
        if (can_access_memory == 0 ||
            !can_access_memory(memory_context, first_address, instruction->width, (instruction->flags & 1) == 0) ||
            !can_access_memory(memory_context, second_address, instruction->width, (instruction->flags & 1) == 0)) {
            return 0;
        }

        if ((instruction->flags & 1) != 0) {
            uint64_t first = 0;
            uint64_t second = 0;
            if (read_memory == 0 ||
                !read_memory(memory_context, first_address, instruction->width, &first) ||
                !read_memory(memory_context, second_address, instruction->width, &second)) {
                return 0;
            }
            if ((instruction->flags & 2) != 0) {
                first = sign_extend_loaded(first, 32);
                second = sign_extend_loaded(second, 32);
            }
            write_register(cpu, instruction->rt, first);
            write_register(cpu, instruction->rd, second);
        } else {
            if (write_memory == 0 ||
                !write_memory(
                    memory_context,
                    first_address,
                    instruction->width,
                    read_register(cpu, instruction->rt) & mask_for_bits(instruction->bits)
                ) ||
                !write_memory(
                    memory_context,
                    second_address,
                    instruction->width,
                    read_register(cpu, instruction->rd) & mask_for_bits(instruction->bits)
                )) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8) != 0) {
            write_base_register(
                cpu,
                instruction->rn,
                add_signed_offset(base, instruction->immediate2)
            );
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE: {
        uint64_t address = read_base_register(cpu, instruction->rn);
        uint64_t value = 0;
        if ((instruction->flags & 1) != 0) {
            if (read_memory == avz_native_fast_memory_read) {
                if (!avz_native_fast_memory_exclusive_read(
                        memory_context,
                        address,
                        instruction->width,
                        &value,
                        &cpu->exclusive_generation
                    )) {
                    return 0;
                }
            } else if (read_memory == 0 ||
                       !read_memory(memory_context, address, instruction->width, &value)) {
                return 0;
            }
            write_register(cpu, instruction->rt, value & mask_for_bits(instruction->bits));
            cpu->exclusive_address = address;
            cpu->exclusive_size = instruction->width;
            cpu->exclusive_valid = 1;
        } else {
            int reservation_matches = cpu->exclusive_valid != 0 &&
                cpu->exclusive_address == address &&
                cpu->exclusive_size == instruction->width;
            if (reservation_matches) {
                uint64_t store_value = read_register(cpu, instruction->rt) &
                    mask_for_bits(instruction->bits);
                if (write_memory == avz_native_fast_memory_write) {
                    int exclusive_result = avz_native_fast_memory_exclusive_write(
                        memory_context,
                        address,
                        instruction->width,
                        store_value,
                        cpu->exclusive_generation
                    );
                    if (exclusive_result < 0) {
                        return 0;
                    }
                    reservation_matches = exclusive_result;
                } else if (write_memory == 0 ||
                           !write_memory(
                               memory_context,
                               address,
                               instruction->width,
                               store_value
                           )) {
                    return 0;
                }
            }
            write_register(cpu, instruction->rd, reservation_matches ? 0 : 1);
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE_PAIR: {
        uint64_t address = read_base_register(cpu, instruction->rn);
        uint64_t second_address = address + instruction->width;
        uint8_t reservation_size = (uint8_t)(instruction->width * 2u);
        if ((instruction->flags & 1) != 0) {
            uint64_t first = 0;
            uint64_t second = 0;
            if (read_memory == avz_native_fast_memory_read) {
                if (!avz_native_fast_memory_exclusive_read_pair(
                        memory_context,
                        address,
                        instruction->width,
                        &first,
                        &second,
                        &cpu->exclusive_generation
                    )) {
                    return 0;
                }
            } else if (read_memory == 0 ||
                       !read_memory(memory_context, address, instruction->width, &first) ||
                       !read_memory(memory_context, second_address, instruction->width, &second)) {
                return 0;
            }
            write_register(cpu, instruction->rt, first & mask_for_bits(instruction->bits));
            write_register(cpu, instruction->rd, second & mask_for_bits(instruction->bits));
            cpu->exclusive_address = address;
            cpu->exclusive_size = reservation_size;
            cpu->exclusive_valid = 1;
        } else {
            int reservation_matches = cpu->exclusive_valid != 0 &&
                cpu->exclusive_address == address &&
                cpu->exclusive_size == reservation_size;
            if (reservation_matches) {
                uint64_t mask = mask_for_bits(instruction->bits);
                uint64_t first_value = read_register(cpu, instruction->rt) & mask;
                uint64_t second_value = read_register(cpu, instruction->rd) & mask;
                if (write_memory == avz_native_fast_memory_write) {
                    int exclusive_result =
                        avz_native_fast_memory_exclusive_write_pair(
                            memory_context,
                            address,
                            instruction->width,
                            first_value,
                            second_value,
                            cpu->exclusive_generation
                        );
                    if (exclusive_result < 0) {
                        return 0;
                    }
                    reservation_matches = exclusive_result;
                } else if (write_memory == 0 ||
                           !write_memory(
                               memory_context,
                               address,
                               instruction->width,
                               first_value
                           ) ||
                           !write_memory(
                               memory_context,
                               second_address,
                               instruction->width,
                               second_value
                           )) {
                    return 0;
                }
            }
            write_register(cpu, instruction->rm, reservation_matches ? 0 : 1);
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_IMMEDIATE: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        uint64_t address = add_signed_offset(base, instruction->immediate);
        if ((instruction->flags & 1) != 0) {
            AVZNativeVectorRegister value;
            if (!read_simd_fp_register_memory(read_memory, memory_context, address, instruction->width, &value)) {
                return 0;
            }
            cpu->v[instruction->rt] = value;
        } else if (!write_simd_fp_register_memory(
            write_memory,
            memory_context,
            address,
            instruction->width,
            cpu->v[instruction->rt]
        )) {
            return 0;
        } else {
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8) != 0) {
            write_base_register(
                cpu,
                instruction->rn,
                add_signed_offset(base, instruction->immediate2)
            );
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_REGISTER_OFFSET: {
        uint64_t offset = extended_register_value(
            read_register(cpu, instruction->rm),
            instruction->condition
        ) << instruction->shift_amount;
        uint64_t address = read_base_register(cpu, instruction->rn) + offset;
        if ((instruction->flags & 1) != 0) {
            AVZNativeVectorRegister value;
            if (!read_simd_fp_register_memory(
                read_memory,
                memory_context,
                address,
                instruction->width,
                &value
            )) {
                return 0;
            }
            cpu->v[instruction->rt] = value;
        } else if (!write_simd_fp_register_memory(
            write_memory,
            memory_context,
            address,
            instruction->width,
            cpu->v[instruction->rt]
        )) {
            return 0;
        } else {
            clear_exclusive_reservation(cpu);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_FP_LOAD_STORE_PAIR: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        uint64_t first_address = add_signed_offset(base, instruction->immediate);
        uint64_t second_address = first_address + instruction->width;
        if ((instruction->flags & 1) != 0) {
            AVZNativeVectorRegister first;
            AVZNativeVectorRegister second;
            if (!read_simd_fp_register_memory(read_memory, memory_context, first_address, instruction->width, &first) ||
                !read_simd_fp_register_memory(read_memory, memory_context, second_address, instruction->width, &second)) {
                return 0;
            }
            cpu->v[instruction->rt] = first;
            cpu->v[instruction->rd] = second;
        } else if (!write_simd_fp_register_memory(
                write_memory,
                memory_context,
                first_address,
                instruction->width,
                cpu->v[instruction->rt]
            ) ||
            !write_simd_fp_register_memory(
                write_memory,
                memory_context,
                second_address,
                instruction->width,
                cpu->v[instruction->rd]
            )) {
            return 0;
        } else {
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8) != 0) {
            write_base_register(
                cpu,
                instruction->rn,
                add_signed_offset(base, instruction->immediate2)
            );
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_LOAD_STORE_SINGLE_STRUCTURE_LANE: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        if ((instruction->flags & 1u) != 0) {
            uint64_t value;
            if (read_memory == 0 ||
                !read_memory(memory_context, base, instruction->width, &value)) {
                return 0;
            }
            AVZNativeVectorRegister vector = cpu->v[instruction->rt];
            write_vector_element(
                &vector,
                instruction->condition,
                instruction->bits,
                value
            );
            cpu->v[instruction->rt] = vector;
        } else {
            uint64_t value = read_vector_element(
                cpu,
                instruction->rt,
                instruction->condition,
                instruction->bits
            );
            if (write_memory == 0 ||
                !write_memory(memory_context, base, instruction->width, value)) {
                return 0;
            }
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8u) != 0) {
            uint64_t increment = (instruction->flags & 16u) != 0
                ? read_register(cpu, instruction->rm)
                : instruction->width;
            write_base_register(cpu, instruction->rn, base + increment);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE: {
        uint64_t base = read_base_register(cpu, instruction->rn);
        unsigned register_count = instruction->condition;
        if (register_count < 1 || register_count > 4 ||
            (instruction->width != 8 && instruction->width != 16)) {
            return 0;
        }

        if (try_execute_simd_multiple_structure_bulk(
                cpu,
                instruction,
                read_memory,
                write_memory,
                memory_context
            )) {
            return 1;
        }

        if ((instruction->flags & 32u) != 0) {
            unsigned element_bits = instruction->bits;
            unsigned element_bytes = element_bits / 8u;
            unsigned lane_count = (instruction->width * 8u) / element_bits;
            AVZNativeVectorRegister vectors[4] = {{0, 0}, {0, 0}, {0, 0}, {0, 0}};
            size_t transfer_size =
                (size_t)lane_count * register_count * element_bytes;
            uint8_t transfer[64];
            int used_bulk_access = 0;
            if ((instruction->flags & 1u) != 0 &&
                read_memory == avz_native_fast_memory_read) {
                used_bulk_access = avz_native_fast_memory_read_bytes(
                    memory_context,
                    base,
                    transfer,
                    transfer_size
                );
            } else if ((instruction->flags & 1u) == 0 &&
                       write_memory == avz_native_fast_memory_write) {
                for (unsigned structure = 0; structure < register_count; structure++) {
                    vectors[structure] =
                        cpu->v[(instruction->rt + structure) & 0x1fu];
                }
                if (pack_interleaved_vectors(
                        vectors,
                        register_count,
                        lane_count,
                        element_bytes,
                        transfer
                    )) {
                    used_bulk_access = avz_native_fast_memory_write_bytes(
                        memory_context,
                        base,
                        transfer,
                        transfer_size
                    );
                }
            }

            if (used_bulk_access) {
                if ((instruction->flags & 1u) != 0) {
                    if (!unpack_interleaved_vectors(
                            transfer,
                            register_count,
                            lane_count,
                            element_bytes,
                            vectors
                        )) {
                        return 0;
                    }
                    for (unsigned structure = 0; structure < register_count; structure++) {
                        cpu->v[(instruction->rt + structure) & 0x1fu] =
                            vectors[structure];
                    }
                } else {
                    clear_exclusive_reservation(cpu);
                }
                if ((instruction->flags & 8u) != 0) {
                    uint64_t increment = (instruction->flags & 16u) != 0
                        ? read_register(cpu, instruction->rm)
                        : (uint64_t)instruction->width * register_count;
                    write_base_register(cpu, instruction->rn, base + increment);
                }
                cpu->pc = pc + 4;
                return 1;
            }

            if ((instruction->flags & 1u) == 0) {
                for (unsigned structure = 0; structure < register_count; structure++) {
                    vectors[structure] = cpu->v[(instruction->rt + structure) & 0x1fu];
                }
            }
            for (unsigned lane = 0; lane < lane_count; lane++) {
                for (unsigned structure = 0; structure < register_count; structure++) {
                    uint64_t address = base +
                        ((uint64_t)lane * register_count + structure) * element_bytes;
                    if ((instruction->flags & 1u) != 0) {
                        uint64_t value;
                        if (read_memory == 0 ||
                            !read_memory(memory_context, address, (uint8_t)element_bytes, &value)) {
                            return 0;
                        }
                        write_vector_element(&vectors[structure], lane, element_bits, value);
                    } else {
                        uint64_t value = read_vector_element(
                            cpu,
                            (instruction->rt + structure) & 0x1fu,
                            lane,
                            element_bits
                        );
                        if (write_memory == 0 ||
                            !write_memory(memory_context, address, (uint8_t)element_bytes, value)) {
                            return 0;
                        }
                    }
                }
            }
            if ((instruction->flags & 1u) != 0) {
                for (unsigned structure = 0; structure < register_count; structure++) {
                    cpu->v[(instruction->rt + structure) & 0x1fu] = vectors[structure];
                }
            } else {
                clear_exclusive_reservation(cpu);
            }
            if ((instruction->flags & 8u) != 0) {
                uint64_t increment = (instruction->flags & 16u) != 0
                    ? read_register(cpu, instruction->rm)
                    : (uint64_t)instruction->width * register_count;
                write_base_register(cpu, instruction->rn, base + increment);
            }
            cpu->pc = pc + 4;
            return 1;
        }

        for (unsigned index = 0; index < register_count; index++) {
            unsigned vector_register = (instruction->rt + index) & 0x1fu;
            uint64_t address = base + (uint64_t)index * instruction->width;
            if ((instruction->flags & 1u) != 0) {
                AVZNativeVectorRegister value;
                if (!read_simd_fp_register_memory(
                    read_memory,
                    memory_context,
                    address,
                    instruction->width,
                    &value
                )) {
                    return 0;
                }
                cpu->v[vector_register] = value;
            } else if (!write_simd_fp_register_memory(
                write_memory,
                memory_context,
                address,
                instruction->width,
                cpu->v[vector_register]
            )) {
                return 0;
            }
        }
        if ((instruction->flags & 1u) == 0) {
            clear_exclusive_reservation(cpu);
        }
        if ((instruction->flags & 8u) != 0) {
            uint64_t increment = (instruction->flags & 16u) != 0
                ? read_register(cpu, instruction->rm)
                : (uint64_t)instruction->width * register_count;
            write_base_register(cpu, instruction->rn, base + increment);
        }
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_DUPLICATE_VECTOR_ELEMENT: {
        uint64_t element = read_vector_element(
            cpu,
            instruction->rn,
            instruction->condition,
            instruction->bits
        );
        cpu->v[instruction->rd] = (instruction->flags & 2u) != 0
            ? (AVZNativeVectorRegister){element, 0}
            : duplicate_simd_element(
                element,
                instruction->bits,
                (instruction->flags & 1u) != 0
            );
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_SCALAR_SHIFT_LEFT_IMMEDIATE:
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){
            cpu->v[instruction->rn].low << instruction->shift_amount,
            0
        };
        cpu->pc = pc + 4;
        return 1;
    case AVZ_NATIVE_OP_SIMD_ADD_ACROSS_VECTOR: {
        unsigned vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
        unsigned lane_count = vector_bits / instruction->bits;
        unsigned widens = instruction->flags & 2u;
        unsigned is_unsigned = instruction->flags & 4u;
        unsigned result_bits = widens != 0 ? instruction->bits * 2u : instruction->bits;
        uint64_t result = 0;
        if ((instruction->flags & 8u) != 0) {
            int is_minimum = (instruction->flags & 16u) != 0;
            result = read_vector_element(cpu, instruction->rn, 0, instruction->bits);
            for (unsigned lane = 1; lane < lane_count; lane++) {
                uint64_t element = read_vector_element(cpu, instruction->rn, lane, instruction->bits);
                if (is_unsigned != 0) {
                    if ((is_minimum && element < result) || (!is_minimum && element > result)) {
                        result = element;
                    }
                } else {
                    int64_t signed_result = sign_extend_u64(result, instruction->bits);
                    int64_t signed_element = sign_extend_u64(element, instruction->bits);
                    if ((is_minimum && signed_element < signed_result) ||
                        (!is_minimum && signed_element > signed_result)) {
                        result = element;
                    }
                }
            }
        } else {
            for (unsigned lane = 0; lane < lane_count; lane++) {
                result += widens != 0 && is_unsigned == 0
                    ? sign_extend_vector_element(cpu, instruction->rn, lane, instruction->bits)
                    : read_vector_element(cpu, instruction->rn, lane, instruction->bits);
            }
        }
        cpu->v[instruction->rd] = (AVZNativeVectorRegister){
            result & mask_for_bits(result_bits),
            0
        };
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD_LONG: {
        unsigned source_vector_bits = (instruction->flags & 1u) != 0 ? 128u : 64u;
        unsigned source_lane_count = source_vector_bits / instruction->bits;
        unsigned destination_bits = instruction->bits * 2u;
        int is_unsigned = (instruction->flags & 2u) != 0;
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < source_lane_count / 2u; lane++) {
            uint64_t sum;
            if (is_unsigned) {
                uint64_t first = read_vector_element(cpu, instruction->rn, lane * 2u, instruction->bits);
                uint64_t second = read_vector_element(cpu, instruction->rn, lane * 2u + 1u, instruction->bits);
                sum = first + second;
            } else {
                int64_t first = (int64_t)sign_extend_vector_element(
                    cpu,
                    instruction->rn,
                    lane * 2u,
                    instruction->bits
                );
                int64_t second = (int64_t)sign_extend_vector_element(
                    cpu,
                    instruction->rn,
                    lane * 2u + 1u,
                    instruction->bits
                );
                sum = (uint64_t)(first + second);
            }
            write_vector_element(&result, lane, destination_bits, sum);
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    case AVZ_NATIVE_OP_SIMD_PAIRWISE_ADD: {
        if ((instruction->flags & 2u) != 0u) {
            cpu->v[instruction->rd] = (AVZNativeVectorRegister){
                cpu->v[instruction->rn].low + cpu->v[instruction->rn].high,
                0
            };
            cpu->pc = pc + 4;
            return 1;
        }
        unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
        unsigned lane_count = vector_bits / instruction->bits;
        unsigned result_half = lane_count / 2u;
        uint64_t element_mask = mask_for_bits(instruction->bits);
        AVZNativeVectorRegister result = {0, 0};
        for (unsigned lane = 0; lane < result_half; lane++) {
            uint64_t lhs = read_vector_element(
                cpu,
                instruction->rn,
                lane * 2u,
                instruction->bits
            );
            uint64_t rhs = read_vector_element(
                cpu,
                instruction->rn,
                lane * 2u + 1u,
                instruction->bits
            );
            write_vector_element(
                &result,
                lane,
                instruction->bits,
                (lhs + rhs) & element_mask
            );

            lhs = read_vector_element(
                cpu,
                instruction->rm,
                lane * 2u,
                instruction->bits
            );
            rhs = read_vector_element(
                cpu,
                instruction->rm,
                lane * 2u + 1u,
                instruction->bits
            );
            write_vector_element(
                &result,
                result_half + lane,
                instruction->bits,
                (lhs + rhs) & element_mask
            );
        }
        cpu->v[instruction->rd] = result;
        cpu->pc = pc + 4;
        return 1;
    }
    default:
        return 0;
    }
}

static int try_execute_store_pair_fill_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    if (fill_memory == 0 || executed_steps == 0 || remaining_steps == 0 ||
        cpu->pc != base_pc || instruction_count < 3) {
        return 0;
    }

    const AVZNativeInstruction *subtract = &instructions[instruction_count - 2];
    const AVZNativeInstruction *branch = &instructions[instruction_count - 1];
    uint64_t branch_pc = base_pc + ((uint64_t)instruction_count - 1) * 4;
    if (branch->kind != AVZ_NATIVE_OP_BCOND ||
        (uint64_t)((int64_t)branch_pc + branch->immediate) != base_pc ||
        subtract->kind != AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE ||
        (subtract->flags & 3) != 3 ||
        subtract->rd != subtract->rn ||
        subtract->bits != 64 ||
        subtract->immediate <= 0) {
        return 0;
    }

    size_t store_count = instruction_count - 2;
    uint8_t base_register = instructions[0].rn;
    uint8_t fill_register = instructions[0].rt;
    uint64_t store_width = instructions[0].width;
    int64_t relative_base = 0;
    int64_t range_start = 0;
    int64_t range_end = 0;
    int saw_range = 0;

    if (store_width != 8 || fill_register == base_register || subtract->rd == base_register) {
        return 0;
    }

    for (size_t index = 0; index < store_count; index++) {
        const AVZNativeInstruction *store = &instructions[index];
        if (store->kind != AVZ_NATIVE_OP_LOAD_STORE_PAIR ||
            (store->flags & 1) != 0 ||
            store->width != store_width ||
            store->bits != store_width * 8 ||
            store->rn != base_register ||
            store->rt != fill_register ||
            store->rd != fill_register) {
            return 0;
        }

        int64_t first = relative_base + store->immediate;
        int64_t end = first + (int64_t)(store_width * 2);
        if (end <= first) {
            return 0;
        }
        if (!saw_range) {
            range_start = first;
            range_end = end;
            saw_range = 1;
        } else if (first == range_end) {
            range_end = end;
        } else {
            return 0;
        }

        if ((store->flags & 8) != 0) {
            relative_base += store->immediate2;
        }
    }

    if (!saw_range || range_end <= range_start || relative_base <= 0 ||
        range_start + relative_base != range_end) {
        return 0;
    }

    uint64_t max_iterations = remaining_steps / (uint64_t)instruction_count;
    if (max_iterations == 0) {
        return 0;
    }

    uint64_t counter = read_register(cpu, subtract->rn);
    uint64_t pstate = cpu->pstate;
    uint64_t iterations = 0;
    uint64_t final_counter = counter;
    uint64_t final_pstate = pstate;
    uint64_t final_pc = base_pc;
    uint64_t decrement = (uint64_t)subtract->immediate;

    while (iterations < max_iterations) {
        uint64_t result_value = 0;
        uint64_t rhs = (~decrement) & UINT64_MAX;
        uint64_t flags = add_with_carry_nzcv(counter, rhs, 1, 64, &result_value);
        final_counter = result_value;
        final_pstate = (pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        iterations++;

        if (condition_holds(branch->condition, final_pstate)) {
            counter = result_value;
            pstate = final_pstate;
            final_pc = base_pc;
        } else {
            final_pc = branch_pc + 4;
            break;
        }
    }

    if (iterations == 0) {
        return 0;
    }

    uint64_t bytes_per_iteration = (uint64_t)(range_end - range_start);
    if (bytes_per_iteration == 0 || iterations > UINT64_MAX / bytes_per_iteration) {
        return 0;
    }
    uint64_t byte_count = iterations * bytes_per_iteration;
    uint64_t virtual_start = (uint64_t)((int64_t)read_base_register(cpu, base_register) + range_start);
    uint64_t pattern = read_register(cpu, fill_register) & mask_for_bits((unsigned)(store_width * 8));

    if (!fill_memory(memory_context, virtual_start, byte_count, pattern, (uint8_t)store_width)) {
        return 0;
    }
    clear_exclusive_reservation(cpu);

    write_base_register(
        cpu,
        base_register,
        (uint64_t)((int64_t)read_base_register(cpu, base_register) + relative_base * (int64_t)iterations)
    );
    write_register(cpu, subtract->rd, final_counter);
    cpu->pstate = final_pstate;
    cpu->pc = final_pc;
    *executed_steps = iterations * (uint64_t)instruction_count;
    return 1;
}

static int try_execute_simd_solid_fill_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    if (fill_memory == NULL || executed_steps == NULL ||
        remaining_steps < 3 || cpu->pc != base_pc ||
        instruction_count != 3) {
        return 0;
    }

    const AVZNativeInstruction *store = &instructions[0];
    const AVZNativeInstruction *subtract = &instructions[1];
    const AVZNativeInstruction *branch = &instructions[2];
    uint64_t branch_pc = base_pc + 8;
    unsigned register_count = store->condition;
    if (store->kind != AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE ||
        (store->flags & (1u | 16u | 32u)) != 0 ||
        (store->flags & 8u) == 0 ||
        store->width != 8 ||
        register_count < 1 || register_count > 4 ||
        subtract->kind != AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE ||
        (subtract->flags & 3u) != 3u ||
        subtract->rd != subtract->rn || subtract->bits != 64 ||
        subtract->immediate <= 0 || subtract->rd == store->rn ||
        branch->kind != AVZ_NATIVE_OP_BCOND ||
        (uint64_t)((int64_t)branch_pc + branch->immediate) != base_pc) {
        return 0;
    }

    uint64_t pattern = cpu->v[store->rt].low;
    for (unsigned index = 0; index < register_count; index++) {
        const AVZNativeVectorRegister *vector =
            &cpu->v[(store->rt + index) & 0x1fu];
        if (vector->low != pattern) {
            return 0;
        }
    }

    uint64_t max_iterations = remaining_steps / instruction_count;
    if (max_iterations == 0) {
        return 0;
    }
    uint64_t counter = read_register(cpu, subtract->rn);
    uint64_t pstate = cpu->pstate;
    uint64_t final_counter = counter;
    uint64_t final_pstate = pstate;
    uint64_t final_pc = base_pc;
    uint64_t decrement = (uint64_t)subtract->immediate;
    uint64_t iterations = 0;
    while (iterations < max_iterations) {
        uint64_t result_value = 0;
        uint64_t flags = add_with_carry_nzcv(
            counter,
            (~decrement) & UINT64_MAX,
            1,
            64,
            &result_value
        );
        final_counter = result_value;
        final_pstate =
            (pstate & ~UINT64_C(0xf0000000)) |
            (flags & UINT64_C(0xf0000000));
        iterations++;
        if (condition_holds(branch->condition, final_pstate)) {
            counter = result_value;
            pstate = final_pstate;
            final_pc = base_pc;
        } else {
            final_pc = branch_pc + 4;
            break;
        }
    }

    uint64_t bytes_per_iteration = (uint64_t)store->width * register_count;
    if (iterations == 0 ||
        iterations > UINT64_MAX / bytes_per_iteration) {
        return 0;
    }
    uint64_t byte_count = iterations * bytes_per_iteration;
    uint64_t virtual_start = read_base_register(cpu, store->rn);
    if (!fill_memory(
            memory_context,
            virtual_start,
            byte_count,
            pattern,
            8
        )) {
        return 0;
    }

    clear_exclusive_reservation(cpu);
    write_base_register(cpu, store->rn, virtual_start + byte_count);
    write_register(cpu, subtract->rd, final_counter);
    cpu->pstate = final_pstate;
    cpu->pc = final_pc;
    *executed_steps = iterations * instruction_count;
    return 1;
}

typedef struct {
    uint16_t offset;
    uint32_t raw;
} AVZPixmanSourceOverInstruction;

static int trace_contains_raw_instruction(
    const AVZNativeInstruction *instructions,
    const uint64_t *instruction_pcs,
    size_t instruction_count,
    uint64_t pc,
    uint32_t raw
) {
    for (size_t index = 0; index < instruction_count; index++) {
        if (instruction_pcs[index] == pc && instructions[index].raw == raw) {
            return 1;
        }
    }
    return 0;
}

static int try_execute_musl_memcmp_loop(
    const AVZNativeInstruction *trace_instructions,
    const uint64_t *instruction_pcs,
    size_t trace_instruction_count,
    size_t trace_instruction_index,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    static const uint32_t expected[] = {
        UINT32_C(0x39400003), /* ldrb w3, [x0] */
        UINT32_C(0xd1000442), /* sub  x2, x2, #1 */
        UINT32_C(0x39400024), /* ldrb w4, [x1] */
        UINT32_C(0x91000400), /* add  x0, x0, #1 */
        UINT32_C(0x91000421), /* add  x1, x1, #1 */
        UINT32_C(0x6b04007f), /* cmp  w3, w4 */
        UINT32_C(0x54ffff20)  /* b.eq memcmp */
    };
    enum { steps_per_iteration = 7, maximum_bytes = 64 };

    const size_t expected_count = sizeof(expected) / sizeof(expected[0]);
    if (trace_instructions == NULL || instruction_pcs == NULL ||
        cpu == NULL || executed_steps == NULL ||
        cpu->pc != base_pc ||
        remaining_steps < steps_per_iteration ||
        read_memory != avz_native_fast_memory_read ||
        trace_instruction_index == 0 ||
        trace_instruction_index > trace_instruction_count ||
        expected_count > trace_instruction_count - trace_instruction_index ||
        instruction_pcs[trace_instruction_index - 1] != base_pc - 4 ||
        trace_instructions[trace_instruction_index - 1].raw !=
            UINT32_C(0xb4000142)) {
        return 0;
    }
    uint64_t code_word = 0;
    if (!read_memory(memory_context, base_pc - 4, 4, &code_word) ||
        (uint32_t)code_word != UINT32_C(0xb4000142)) {
        return 0;
    }
    for (size_t index = 0; index < expected_count; index++) {
        size_t trace_index = trace_instruction_index + index;
        if (instruction_pcs[trace_index] != base_pc + index * 4 ||
            trace_instructions[trace_index].raw != expected[index]) {
            return 0;
        }
        code_word = 0;
        if (!read_memory(
                memory_context, base_pc + index * 4, 4, &code_word
            ) || (uint32_t)code_word != expected[index]) {
            return 0;
        }
    }

    uint64_t left_address = read_register(cpu, 0);
    uint64_t right_address = read_register(cpu, 1);
    uint64_t remaining = read_register(cpu, 2);
    uint64_t iterations = (remaining_steps + 1) / 8;
    if (iterations > remaining) {
        iterations = remaining;
    }
    if (iterations > maximum_bytes) {
        iterations = maximum_bytes;
    }
    uint64_t left_page_bytes = UINT64_C(4096) -
        (left_address & UINT64_C(4095));
    uint64_t right_page_bytes = UINT64_C(4096) -
        (right_address & UINT64_C(4095));
    if (iterations > left_page_bytes) {
        iterations = left_page_bytes;
    }
    if (iterations > right_page_bytes) {
        iterations = right_page_bytes;
    }
    if (iterations == 0) {
        return 0;
    }

    uint8_t *left = NULL;
    uint8_t *right = NULL;
    uint64_t ignored_physical = 0;
    if (!avz_native_fast_memory_map_span(
            memory_context, left_address, iterations, 0,
            &left, &ignored_physical
        ) ||
        !avz_native_fast_memory_map_span(
            memory_context, right_address, iterations, 0,
            &right, &ignored_physical
        )) {
        return 0;
    }
    uint64_t completed = 0;
    uint8_t left_byte = 0;
    uint8_t right_byte = 0;
    int mismatch = 0;
    while (completed < iterations) {
        left_byte = left[completed];
        right_byte = right[completed];
        completed++;
        if (left_byte != right_byte) {
            mismatch = 1;
            break;
        }
    }

    uint64_t ignored_result = 0;
    uint64_t flags = add_with_carry_nzcv(
        left_byte, (~(uint64_t)right_byte) & UINT32_MAX, 1, 32,
        &ignored_result
    );
    write_register(cpu, 0, left_address + completed);
    write_register(cpu, 1, right_address + completed);
    write_register(cpu, 2, remaining - completed);
    write_register(cpu, 3, left_byte);
    write_register(cpu, 4, right_byte);
    cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) |
        (flags & UINT64_C(0xf0000000));
    cpu->pc = mismatch ? base_pc + UINT64_C(0x1c) : base_pc - 4;
    *executed_steps = completed * steps_per_iteration + (completed - 1);
    return 1;
}

static int try_execute_pixman_neon_copy_loop(
    uint8_t *validated_hint,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    static const uint32_t expected[] = {
        UINT32_C(0x0c9f2840), /* st1 {v0.2s-v3.2s}, [x2], #32 */
        UINT32_C(0x0cdf2880), /* ld1 {v0.2s-v3.2s}, [x4], #32 */
        UINT32_C(0x9100214a), /* add x10, x10, #8 */
        UINT32_C(0xf2400d3f), /* tst x9, #15 */
        UINT32_C(0x54000060), /* b.eq +12 */
        UINT32_C(0x9100214a), /* add x10, x10, #8 */
        UINT32_C(0xd1000529), /* sub x9, x9, #1 */
        UINT32_C(0xeb0e015f), /* cmp x10, x14 */
        UINT32_C(0xd37ef54f), /* lsl x15, x10, #2 */
        UINT32_C(0xf8af6960), /* prfm pldl1keep, [x11, x15] */
        UINT32_C(0x540000cd), /* b.le +24 */
        UINT32_C(0xcb0e014a), /* sub x10, x10, x14 */
        UINT32_C(0xf1004129), /* subs x9, x9, #16 */
        UINT32_C(0x5400006d), /* b.le +12 */
        UINT32_C(0x8b05096b), /* add x11, x11, x5, lsl #2 */
        UINT32_C(0x3980016f), /* ldrsb x15, [x11] */
        UINT32_C(0xf1002000), /* subs x0, x0, #8 */
        UINT32_C(0x54fffdea)  /* b.ge loop */
    };
    enum {
        minimum_steps_per_iteration = 11,
        maximum_iterations = 1024,
        maximum_mapped_chunks = 32
    };

    if (cpu == NULL || executed_steps == NULL || cpu->pc != base_pc ||
        remaining_steps < minimum_steps_per_iteration ||
        read_memory != avz_native_fast_memory_read ||
        write_memory != avz_native_fast_memory_write) {
        return 0;
    }
    if (validated_hint == NULL || *validated_hint == 0) {
        for (size_t index = 0;
             index < sizeof(expected) / sizeof(expected[0]); index++) {
            uint64_t code_word = 0;
            if (!read_memory(
                    memory_context, base_pc + index * 4, 4, &code_word
                ) || (uint32_t)code_word != expected[index]) {
                return 0;
            }
        }
        if (validated_hint != NULL) {
            *validated_hint = 1;
        }
    }

    uint64_t source_address = read_base_register(cpu, 4);
    uint64_t destination_address = read_base_register(cpu, 2);
    if (((source_address | destination_address) & UINT64_C(31)) != 0) {
        return 0;
    }
    uint64_t max_iterations = remaining_steps /
        minimum_steps_per_iteration;
    if (max_iterations > maximum_iterations) {
        max_iterations = maximum_iterations;
    }
    if (max_iterations == 0) {
        return 0;
    }

    uint64_t x0 = read_register(cpu, 0);
    uint64_t x9 = read_register(cpu, 9);
    uint64_t x10 = read_register(cpu, 10);
    uint64_t x11 = read_register(cpu, 11);
    uint64_t x5 = read_register(cpu, 5);
    uint64_t x14 = read_register(cpu, 14);
    uint64_t final_x15 = read_register(cpu, 15);
    uint64_t final_flags = cpu->pstate;
    uint64_t total_steps = 0;
    uint64_t iterations = 0;
    int exits_loop = 0;

    while (iterations < max_iterations) {
        uint64_t iteration_steps = 5;
        uint64_t next_x10 = x10 + 8;
        uint64_t next_x9 = x9;
        uint64_t next_x11 = x11;
        uint64_t next_x15 = next_x10 << 2;
        if ((next_x9 & UINT64_C(15)) != 0) {
            next_x10 += 8;
            next_x9 -= 1;
            iteration_steps += 2;
        }

        uint64_t ignored_result = 0;
        uint64_t compare_flags = add_with_carry_nzcv(
            next_x10, ~x14, 1, 64, &ignored_result
        );
        next_x15 = next_x10 << 2;
        iteration_steps += 4;
        if (!condition_holds(13, compare_flags)) {
            next_x10 -= x14;
            uint64_t decremented_x9 = 0;
            uint64_t x9_flags = add_with_carry_nzcv(
                next_x9, ~UINT64_C(16), 1, 64, &decremented_x9
            );
            next_x9 = decremented_x9;
            iteration_steps += 3;
            if (!condition_holds(13, x9_flags)) {
                next_x11 += x5 << 2;
                uint64_t probe_value = 0;
                if (!read_memory(
                        memory_context, next_x11, 1, &probe_value
                    )) {
                    return 0;
                }
                next_x15 = (uint64_t)(int64_t)(int8_t)probe_value;
                iteration_steps += 2;
            }
        }

        uint64_t next_x0 = 0;
        uint64_t x0_flags = add_with_carry_nzcv(
            x0, ~UINT64_C(8), 1, 64, &next_x0
        );
        iteration_steps += 2;
        if (iteration_steps > remaining_steps - total_steps) {
            break;
        }

        x0 = next_x0;
        x9 = next_x9;
        x10 = next_x10;
        x11 = next_x11;
        final_x15 = next_x15;
        final_flags = x0_flags;
        total_steps += iteration_steps;
        iterations++;
        if (!condition_holds(10, x0_flags)) {
            exits_loop = 1;
            break;
        }
    }
    if (iterations == 0) {
        return 0;
    }

    uint64_t byte_count = iterations * 32;
    if (source_address > UINT64_MAX - byte_count ||
        destination_address > UINT64_MAX - byte_count) {
        return 0;
    }
    typedef struct {
        uint8_t *source;
        uint8_t *destination;
        uint64_t destination_physical;
        size_t byte_count;
    } AVZPixmanCopyChunk;
    AVZPixmanCopyChunk chunks[maximum_mapped_chunks];
    size_t chunk_count = 0;
    uint64_t mapped_bytes = 0;
    while (mapped_bytes < byte_count) {
        if (chunk_count >= maximum_mapped_chunks) {
            return 0;
        }
        uint64_t source_cursor = source_address + mapped_bytes;
        uint64_t destination_cursor = destination_address + mapped_bytes;
        uint64_t chunk_bytes = byte_count - mapped_bytes;
        uint64_t source_page_bytes = UINT64_C(4096) -
            (source_cursor & UINT64_C(4095));
        uint64_t destination_page_bytes = UINT64_C(4096) -
            (destination_cursor & UINT64_C(4095));
        if (chunk_bytes > source_page_bytes) {
            chunk_bytes = source_page_bytes;
        }
        if (chunk_bytes > destination_page_bytes) {
            chunk_bytes = destination_page_bytes;
        }
        if (chunk_bytes == 0 || (chunk_bytes & UINT64_C(31)) != 0) {
            return 0;
        }
        uint64_t ignored_physical = 0;
        AVZPixmanCopyChunk *chunk = &chunks[chunk_count];
        if (!avz_native_fast_memory_map_span(
                memory_context, source_cursor, (size_t)chunk_bytes, 0,
                &chunk->source, &ignored_physical
            ) ||
            !avz_native_fast_memory_map_span(
                memory_context, destination_cursor, (size_t)chunk_bytes, 1,
                &chunk->destination, &chunk->destination_physical
            )) {
            return 0;
        }
        chunk->byte_count = (size_t)chunk_bytes;
        chunk_count++;
        mapped_bytes += chunk_bytes;
    }

    uint64_t current_vectors[4];
    for (size_t vector = 0; vector < 4; vector++) {
        current_vectors[vector] = cpu->v[vector].low;
    }
    size_t chunk_index = 0;
    size_t chunk_offset = 0;
    for (uint64_t iteration = 0; iteration < iterations; iteration++) {
        AVZPixmanCopyChunk *chunk = &chunks[chunk_index];
        memcpy(chunk->destination + chunk_offset, current_vectors, 32);
        memcpy(current_vectors, chunk->source + chunk_offset, 32);
        chunk_offset += 32;
        if (chunk_offset == chunk->byte_count) {
            chunk_index++;
            chunk_offset = 0;
        }
    }
    for (size_t chunk_index = 0; chunk_index < chunk_count; chunk_index++) {
        avz_native_fast_memory_commit_write_span(
            memory_context,
            chunks[chunk_index].destination_physical,
            chunks[chunk_index].byte_count
        );
    }

    clear_exclusive_reservation(cpu);
    write_base_register(cpu, 2, destination_address + byte_count);
    write_base_register(cpu, 4, source_address + byte_count);
    write_register(cpu, 0, x0);
    write_register(cpu, 9, x9);
    write_register(cpu, 10, x10);
    write_register(cpu, 11, x11);
    write_register(cpu, 15, final_x15);
    for (size_t vector = 0; vector < 4; vector++) {
        cpu->v[vector].low = current_vectors[vector];
        cpu->v[vector].high = 0;
    }
    cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) |
        (final_flags & UINT64_C(0xf0000000));
    cpu->pc = exits_loop ? base_pc + UINT64_C(0x48) : base_pc;
    *executed_steps = total_steps;
    return 1;
}

static int try_execute_glib_djb2_string_hash_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps,
    int *exited_loop
) {
    static const uint32_t expected[] = {
        UINT32_C(0x11000718), /* add  w24, w24, #1 */
        UINT32_C(0x0b1a175a), /* add  w26, w26, w26, lsl #5 */
        UINT32_C(0x0b22835a), /* add  w26, w26, w2, sxtb */
        UINT32_C(0x38784822), /* ldrb w2, [x1, w24, uxtw] */
        UINT32_C(0x35ffff82)  /* cbnz w2, loop */
    };
    enum { steps_per_iteration = 5, maximum_bytes = 64 };

    if (instructions == NULL || cpu == NULL || executed_steps == NULL ||
        exited_loop == NULL ||
        instruction_count != sizeof(expected) / sizeof(expected[0]) ||
        remaining_steps < steps_per_iteration ||
        read_memory != avz_native_fast_memory_read || cpu->pc != base_pc) {
        return 0;
    }
    for (size_t index = 0; index < instruction_count; index++) {
        if (instructions[index].raw != expected[index]) {
            return 0;
        }
    }

    uint64_t string_address = read_register(cpu, 1);
    uint32_t string_index = (uint32_t)read_register(cpu, 24);
    uint32_t hash = (uint32_t)read_register(cpu, 26);
    uint8_t current = (uint8_t)read_register(cpu, 2);
    uint64_t next_address = string_address + (uint64_t)string_index + 1;
    if (next_address < string_address) {
        return 0;
    }

    uint64_t iterations = remaining_steps / steps_per_iteration;
    if (iterations > maximum_bytes) {
        iterations = maximum_bytes;
    }
    uint64_t page_bytes = UINT64_C(4096) -
        (next_address & UINT64_C(4095));
    if (iterations > page_bytes) {
        iterations = page_bytes;
    }
    if (iterations == 0) {
        return 0;
    }

    uint8_t *next_bytes = NULL;
    uint64_t ignored_physical = 0;
    if (!avz_native_fast_memory_map_span(
            memory_context, next_address, (size_t)iterations, 0,
            &next_bytes, &ignored_physical
        )) {
        return 0;
    }

    uint64_t completed = 0;
    int completed_string = 0;
    while (completed < iterations) {
        string_index++;
        hash = hash * UINT32_C(33) +
            (uint32_t)(int32_t)(int8_t)current;
        current = next_bytes[completed];
        completed++;
        if (current == 0) {
            completed_string = 1;
            break;
        }
    }

    write_register(cpu, 24, string_index);
    write_register(cpu, 26, hash);
    write_register(cpu, 2, current);
    cpu->pc = completed_string ? base_pc + UINT64_C(0x14) : base_pc;
    *executed_steps = completed * steps_per_iteration;
    *exited_loop = completed_string;
    return 1;
}

static int try_execute_byte_string_scan_loop(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    static const uint32_t expected[] = {
        UINT32_C(0x91000421), /* add  x1, x1, #1 */
        UINT32_C(0x39400022), /* ldrb w2, [x1] */
        UINT32_C(0x35ffffc2)  /* cbnz w2, loop */
    };
    enum { steps_per_iteration = 3, maximum_bytes = 256 };

    if (instructions == NULL || cpu == NULL || executed_steps == NULL ||
        instruction_count != sizeof(expected) / sizeof(expected[0]) ||
        remaining_steps < steps_per_iteration ||
        read_memory != avz_native_fast_memory_read || cpu->pc != base_pc) {
        return 0;
    }
    for (size_t index = 0; index < instruction_count; index++) {
        if (instructions[index].raw != expected[index]) {
            return 0;
        }
    }

    uint64_t cursor = read_register(cpu, 1);
    if (cursor == UINT64_MAX) {
        return 0;
    }
    uint64_t first_address = cursor + 1;
    uint64_t iterations = remaining_steps / steps_per_iteration;
    if (iterations > maximum_bytes) {
        iterations = maximum_bytes;
    }
    uint64_t page_bytes = UINT64_C(4096) -
        (first_address & UINT64_C(4095));
    if (iterations > page_bytes) {
        iterations = page_bytes;
    }
    if (iterations == 0) {
        return 0;
    }

    uint8_t *bytes = NULL;
    uint64_t ignored_physical = 0;
    if (!avz_native_fast_memory_map_span(
            memory_context, first_address, (size_t)iterations, 0,
            &bytes, &ignored_physical
        )) {
        return 0;
    }

    uint64_t completed = 0;
    uint8_t current = 0;
    int completed_string = 0;
    while (completed < iterations) {
        current = bytes[completed];
        completed++;
        if (current == 0) {
            completed_string = 1;
            break;
        }
    }

    write_register(cpu, 1, cursor + completed);
    write_register(cpu, 2, current);
    cpu->pc = completed_string ? base_pc + UINT64_C(0x0c) : base_pc;
    *executed_steps = completed * steps_per_iteration;
    return 1;
}

static int try_execute_musl_symbol_name_compare_loop(
    const AVZNativeInstruction *trace_instructions,
    const uint64_t *instruction_pcs,
    size_t trace_instruction_count,
    uint64_t base_pc,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
    static const uint32_t gnu_expected[] = {
        UINT32_C(0x38616864), /* ldrb w4, [x3, x1] */
        UINT32_C(0x38616927), /* ldrb w7, [x9, x1] */
        UINT32_C(0x6b07009f), /* cmp  w4, w7 */
        UINT32_C(0x54fffd41), /* b.ne next GNU hash chain entry */
        UINT32_C(0x91000421), /* add  x1, x1, #1 */
        UINT32_C(0x35ffff64)  /* cbnz w4, loop */
    };
    static const uint32_t sysv_expected[] = {
        UINT32_C(0x38616803), /* ldrb w3, [x0, x1] */
        UINT32_C(0x386168c4), /* ldrb w4, [x6, x1] */
        UINT32_C(0x6b04007f), /* cmp  w3, w4 */
        UINT32_C(0x54fffe21), /* b.ne next SysV hash chain entry */
        UINT32_C(0x91000421), /* add  x1, x1, #1 */
        UINT32_C(0x35ffff63)  /* cbnz w3, loop */
    };
    enum { steps_per_equal_byte = 6, maximum_bytes = 64 };

    if (trace_instructions == NULL || instruction_pcs == NULL ||
        cpu == NULL || executed_steps == NULL ||
        remaining_steps < steps_per_equal_byte ||
        read_memory != avz_native_fast_memory_read || cpu->pc != base_pc) {
        return 0;
    }

    const uint32_t *expected = NULL;
    unsigned left_base_register = 0;
    unsigned right_base_register = 0;
    unsigned left_value_register = 0;
    unsigned right_value_register = 0;
    int64_t mismatch_offset = 0;
    uint64_t first_code_word = 0;
    if (!read_memory(memory_context, base_pc, 4, &first_code_word)) {
        return 0;
    }
    if ((uint32_t)first_code_word == gnu_expected[0]) {
        expected = gnu_expected;
        left_base_register = 3;
        right_base_register = 9;
        left_value_register = 4;
        right_value_register = 7;
        mismatch_offset = -INT64_C(0x4c);
    } else if ((uint32_t)first_code_word == sysv_expected[0]) {
        expected = sysv_expected;
        left_base_register = 0;
        right_base_register = 6;
        left_value_register = 3;
        right_value_register = 4;
        mismatch_offset = -INT64_C(0x30);
    } else {
        return 0;
    }
    for (size_t index = 0; index < 6; index++) {
        uint64_t code_word = 0;
        if (!read_memory(
                memory_context, base_pc + index * 4, 4, &code_word
            ) || (uint32_t)code_word != expected[index]) {
            return 0;
        }
    }

    uint64_t string_index = read_register(cpu, 1);
    uint64_t left_base = read_register(cpu, left_base_register);
    uint64_t right_base = read_register(cpu, right_base_register);
    if (string_index > UINT64_MAX - left_base ||
        string_index > UINT64_MAX - right_base) {
        return 0;
    }
    uint64_t left_address = left_base + string_index;
    uint64_t right_address = right_base + string_index;
    uint64_t iterations = remaining_steps / steps_per_equal_byte;
    if (iterations > maximum_bytes) {
        iterations = maximum_bytes;
    }
    uint64_t left_page_bytes = UINT64_C(4096) -
        (left_address & UINT64_C(4095));
    uint64_t right_page_bytes = UINT64_C(4096) -
        (right_address & UINT64_C(4095));
    if (iterations > left_page_bytes) {
        iterations = left_page_bytes;
    }
    if (iterations > right_page_bytes) {
        iterations = right_page_bytes;
    }
    if (iterations == 0) {
        return 0;
    }

    uint8_t *left = NULL;
    uint8_t *right = NULL;
    uint64_t ignored_physical = 0;
    if (!avz_native_fast_memory_map_span(
            memory_context, left_address, (size_t)iterations, 0,
            &left, &ignored_physical
        ) ||
        !avz_native_fast_memory_map_span(
            memory_context, right_address, (size_t)iterations, 0,
            &right, &ignored_physical
        )) {
        return 0;
    }

    uint64_t completed = 0;
    uint64_t equal_bytes = 0;
    uint8_t left_byte = 0;
    uint8_t right_byte = 0;
    int mismatch = 0;
    int completed_string = 0;
    while (completed < iterations) {
        left_byte = left[completed];
        right_byte = right[completed];
        completed++;
        if (left_byte != right_byte) {
            mismatch = 1;
            break;
        }
        equal_bytes++;
        if (left_byte == 0) {
            completed_string = 1;
            break;
        }
    }

    uint64_t ignored_result = 0;
    uint64_t flags = add_with_carry_nzcv(
        left_byte, (~(uint64_t)right_byte) & UINT32_MAX, 1, 32,
        &ignored_result
    );
    write_register(cpu, 1, string_index + equal_bytes);
    write_register(cpu, left_value_register, left_byte);
    write_register(cpu, right_value_register, right_byte);
    cpu->pstate = (cpu->pstate & ~UINT64_C(0xf0000000)) |
        (flags & UINT64_C(0xf0000000));
    if (mismatch) {
        cpu->pc = (uint64_t)((int64_t)base_pc + mismatch_offset);
        *executed_steps = (completed - 1) * steps_per_equal_byte + 4;
    } else {
        cpu->pc = completed_string ? base_pc + UINT64_C(0x18) : base_pc;
        *executed_steps = completed * steps_per_equal_byte;
    }
    return 1;
}

#if defined(__aarch64__) && defined(__ARM_NEON)
static uint64_t vector_low_from_u8x8(uint8x8_t value) {
    return vget_lane_u64(vreinterpret_u64_u8(value), 0);
}

static void store_u16x8_vector(
    AVZNativeVectorRegister *destination,
    uint16x8_t value
) {
    memcpy(destination, &value, sizeof(value));
}

static uint16x8_t load_u16x8_vector(
    const AVZNativeVectorRegister *source
) {
    uint16x8_t value;
    memcpy(&value, source, sizeof(value));
    return value;
}

#endif

static int try_execute_pixman_source_over_prefix(
    const AVZNativeInstruction *instructions,
    const uint64_t *instruction_pcs,
    size_t instruction_count,
    uint8_t *validated_hint,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
#if !defined(__aarch64__) || !defined(__ARM_NEON)
    (void)instructions;
    (void)instruction_pcs;
    (void)instruction_count;
    (void)validated_hint;
    (void)remaining_steps;
    (void)cpu;
    (void)read_memory;
    (void)write_memory;
    (void)memory_context;
    (void)executed_steps;
    return 0;
#else
    enum { minimum_steps = 24, extended_steps = 26 };
    static const AVZPixmanSourceOverInstruction expected[] = {
        {0x00, 0x0cdf0104}, {0x04, 0x6f18250e},
        {0x08, 0x9100214a}, {0x0c, 0xf2400d3f},
        {0x10, 0x6f18252f}, {0x14, 0x6f182550},
        {0x18, 0x6f182571}, {0x1c, 0x54000060},
        {0x20, 0x9100214a}, {0x24, 0xd1000529},
        {0x28, 0x2e2841dc}, {0x2c, 0x2e2941fd},
        {0x30, 0xeb0e015f}, {0x34, 0x2e2a421e},
        {0x38, 0x2e2b423f}, {0x3c, 0x2e3c0c1c},
        {0x40, 0x2e3d0c3d}, {0x44, 0x2e3e0c5e},
        {0x48, 0x2e3f0c7f}, {0x4c, 0x0cdf0080},
        {0x50, 0xd37ef54f}, {0x54, 0xf8af6960},
        {0x58, 0x2e205876}, {0x5c, 0xd37ef54f},
        {0x60, 0xf8af6980}, {0x64, 0x0c9f005c}
    };
    if (instructions == NULL || instruction_pcs == NULL ||
        executed_steps == NULL || remaining_steps < minimum_steps ||
        read_memory != avz_native_fast_memory_read ||
        write_memory != avz_native_fast_memory_write ||
        ((validated_hint == NULL || *validated_hint == 0) &&
         !trace_contains_raw_instruction(
            instructions,
            instruction_pcs,
            instruction_count,
            cpu->pc,
            expected[0].raw
        ))) {
        return 0;
    }
    uint64_t base_pc = cpu->pc;
    if (validated_hint == NULL || *validated_hint == 0) {
        for (size_t index = 0;
             index < sizeof(expected) / sizeof(expected[0]); index++) {
            if (!trace_contains_raw_instruction(
                    instructions,
                    instruction_pcs,
                    instruction_count,
                    base_pc + expected[index].offset,
                    expected[index].raw
                )) {
                return 0;
            }
        }
        if (validated_hint != NULL) {
            *validated_hint = 1;
        }
    }

    uint64_t source_address = read_base_register(cpu, 4);
    uint64_t destination_address = read_base_register(cpu, 8);
    uint64_t output_address = read_base_register(cpu, 2);
    uint64_t x9 = read_register(cpu, 9);
    uint64_t x10 = read_register(cpu, 10);
    uint64_t x14 = read_register(cpu, 14);
    int executes_unaligned_adjustment = (x9 & UINT64_C(0xf)) != 0;
    uint64_t step_count = executes_unaligned_adjustment
        ? extended_steps : minimum_steps;
    if (remaining_steps < step_count) {
        return 0;
    }

    uint8_t *source = NULL;
    uint8_t *destination = NULL;
    uint8_t *output = NULL;
    uint64_t source_physical = 0;
    uint64_t destination_physical = 0;
    uint64_t output_physical = 0;
    if (!avz_native_fast_memory_map_span(
            memory_context, destination_address, 32, 0,
            &destination, &destination_physical
        ) ||
        !avz_native_fast_memory_map_span(
            memory_context, source_address, 32, 0,
            &source, &source_physical
        ) ||
        !avz_native_fast_memory_map_span(
            memory_context, output_address, 32, 1,
            &output, &output_physical
        )) {
        return 0;
    }
    (void)source_physical;
    (void)destination_physical;

    uint8x8x4_t next_destination = vld4_u8(destination);
    uint16x8_t products[4];
    uint16x8_t rounded[4];
    uint8x8x4_t result;
    uint8x8x4_t wrapping;
    int saturated = 0;
    for (unsigned component = 0; component < 4; component++) {
        cpu->v[4 + component] = (AVZNativeVectorRegister){
            vector_low_from_u8x8(next_destination.val[component]), 0
        };
        products[component] = load_u16x8_vector(&cpu->v[8 + component]);
        rounded[component] = vrshrq_n_u16(products[component], 8);
        store_u16x8_vector(&cpu->v[14 + component], rounded[component]);
    }

    x10 += 8;
    if (executes_unaligned_adjustment) {
        x10 += 8;
        x9 -= 1;
    }

    for (unsigned component = 0; component < 4; component++) {
        uint8x8_t scaled = vraddhn_u16(
            rounded[component], products[component]
        );
        uint8x8_t source_component = vcreate_u8(cpu->v[component].low);
        result.val[component] = vqadd_u8(source_component, scaled);
        wrapping.val[component] = vadd_u8(source_component, scaled);
        saturated |= vmaxv_u8(veor_u8(
            result.val[component], wrapping.val[component]
        )) != 0;
        cpu->v[28 + component] = (AVZNativeVectorRegister){
            vector_low_from_u8x8(result.val[component]), 0
        };
    }
    if (saturated) {
        cpu->fpsr |= UINT64_C(1) << 27;
    }

    uint64_t ignored = 0;
    uint64_t compare_flags = add_with_carry_nzcv(
        x10, ~x14, 1, 64, &ignored
    );
    uint8x8x4_t next_source = vld4_u8(source);
    for (unsigned component = 0; component < 4; component++) {
        cpu->v[component] = (AVZNativeVectorRegister){
            vector_low_from_u8x8(next_source.val[component]), 0
        };
    }
    uint8x8_t inverse_alpha = vmvn_u8(next_source.val[3]);
    cpu->v[22] = (AVZNativeVectorRegister){
        vector_low_from_u8x8(inverse_alpha), 0
    };
    vst4_u8(output, result);
    avz_native_fast_memory_commit_write_span(
        memory_context, output_physical, 32
    );
    clear_exclusive_reservation(cpu);
    write_base_register(cpu, 4, source_address + 32);
    write_base_register(cpu, 8, destination_address + 32);
    write_base_register(cpu, 2, output_address + 32);
    write_register(cpu, 9, x9);
    write_register(cpu, 10, x10);
    write_register(cpu, 15, x10 << 2);
    cpu->pstate =
        (cpu->pstate & ~UINT64_C(0xf0000000)) |
        (compare_flags & UINT64_C(0xf0000000));
    cpu->pc = base_pc + 0x68;
    *executed_steps = step_count;
    return 1;
#endif
}

static int try_execute_pixman_source_over_tail(
    const AVZNativeInstruction *instructions,
    const uint64_t *instruction_pcs,
    size_t instruction_count,
    uint8_t *validated_hint,
    uint64_t remaining_steps,
    AVZNativeCPU *cpu,
    AVZNativeMemoryReadCallback read_memory,
    void *memory_context,
    uint64_t *executed_steps
) {
#if !defined(__aarch64__) || !defined(__ARM_NEON)
    (void)instructions;
    (void)instruction_pcs;
    (void)instruction_count;
    (void)validated_hint;
    (void)remaining_steps;
    (void)cpu;
    (void)read_memory;
    (void)memory_context;
    (void)executed_steps;
    return 0;
#else
    static const uint32_t expected[] = {
        UINT32_C(0x5400004d), UINT32_C(0xcb0e014a),
        UINT32_C(0x2e24c2c8), UINT32_C(0x5400004d),
        UINT32_C(0xf1004129), UINT32_C(0x2e25c2c9),
        UINT32_C(0x5400006d), UINT32_C(0x8b05096b),
        UINT32_C(0x3980016f), UINT32_C(0x2e26c2ca),
        UINT32_C(0x5400006d), UINT32_C(0x8b03098c),
        UINT32_C(0x3980018f), UINT32_C(0x2e27c2cb),
        UINT32_C(0xf1002000), UINT32_C(0x54fffaea)
    };
    if (instructions == NULL || instruction_pcs == NULL ||
        cpu == NULL || executed_steps == NULL ||
        remaining_steps < 10 ||
        read_memory != avz_native_fast_memory_read ||
        ((validated_hint == NULL || *validated_hint == 0) &&
         !trace_contains_raw_instruction(
            instructions, instruction_pcs, instruction_count,
            cpu->pc, expected[0]
         ))) {
        return 0;
    }
    uint64_t base_pc = cpu->pc;
    if (validated_hint == NULL || *validated_hint == 0) {
        for (size_t index = 0;
             index < sizeof(expected) / sizeof(expected[0]); index++) {
            if (!trace_contains_raw_instruction(
                    instructions,
                    instruction_pcs,
                    instruction_count,
                    base_pc + index * 4,
                    expected[index]
                )) {
                return 0;
            }
        }
        if (validated_hint != NULL) {
            *validated_hint = 1;
        }
    }

    uint64_t initial_flags = cpu->pstate;
    int initial_le = condition_holds(13, initial_flags);
    uint64_t x9 = read_register(cpu, 9);
    uint64_t x10 = read_register(cpu, 10);
    uint64_t tail_flags = initial_flags;
    uint64_t next_x9 = x9;
    int reads_probe_addresses = 0;
    uint64_t step_count = 10;
    if (!initial_le) {
        x10 -= read_register(cpu, 14);
        tail_flags = add_with_carry_nzcv(
            x9, ~UINT64_C(16), 1, 64, &next_x9
        );
        reads_probe_addresses = !condition_holds(13, tail_flags);
        step_count = 12 + (reads_probe_addresses ? 4 : 0);
    }
    if (remaining_steps < step_count) {
        return 0;
    }

    uint64_t x11 = read_register(cpu, 11);
    uint64_t x12 = read_register(cpu, 12);
    uint64_t x15 = read_register(cpu, 15);
    if (reads_probe_addresses) {
        x11 += read_register(cpu, 5) << 2;
        uint64_t probe_value = 0;
        if (!read_memory(memory_context, x11, 1, &probe_value)) {
            return 0;
        }
        x15 = (uint64_t)(int64_t)(int8_t)probe_value;
        x12 += read_register(cpu, 3) << 2;
        if (!read_memory(memory_context, x12, 1, &probe_value)) {
            return 0;
        }
        x15 = (uint64_t)(int64_t)(int8_t)probe_value;
    }

    uint8x8_t inverse_alpha = vcreate_u8(cpu->v[22].low);
    for (unsigned component = 0; component < 4; component++) {
        uint8x8_t destination = vcreate_u8(cpu->v[4 + component].low);
        store_u16x8_vector(
            &cpu->v[8 + component],
            vmull_u8(inverse_alpha, destination)
        );
    }

    uint64_t x0 = read_register(cpu, 0);
    uint64_t next_x0 = 0;
    uint64_t final_flags = add_with_carry_nzcv(
        x0, ~UINT64_C(8), 1, 64, &next_x0
    );
    write_register(cpu, 0, next_x0);
    write_register(cpu, 9, next_x9);
    write_register(cpu, 10, x10);
    if (reads_probe_addresses) {
        write_register(cpu, 11, x11);
        write_register(cpu, 12, x12);
        write_register(cpu, 15, x15);
    }
    cpu->pstate =
        (cpu->pstate & ~UINT64_C(0xf0000000)) |
        (final_flags & UINT64_C(0xf0000000));
    cpu->pc = condition_holds(10, final_flags)
        ? base_pc - UINT64_C(0x68)
        : base_pc + UINT64_C(0x40);
    *executed_steps = step_count;
    return 1;
#endif
}

static void copy_registers_to_cpu(
    AVZNativeCPU *cpu,
    const uint64_t *x31,
    const uint64_t *v32_low,
    const uint64_t *v32_high,
    uint64_t sp,
    uint64_t pc,
    uint64_t pstate,
    uint64_t fpcr,
    uint64_t fpsr,
    uint64_t exclusive_address,
    uint8_t exclusive_size,
    uint8_t exclusive_valid,
    uint8_t halted
) {
    for (size_t index = 0; index < 31; index++) {
        cpu->x[index] = x31[index];
    }
    for (size_t index = 0; index < 32; index++) {
        cpu->v[index].low = v32_low == 0 ? 0 : v32_low[index];
        cpu->v[index].high = v32_high == 0 ? 0 : v32_high[index];
    }
    cpu->sp = sp;
    cpu->pc = pc;
    cpu->pstate = pstate;
    cpu->fpcr = fpcr;
    cpu->fpsr = fpsr;
    cpu->exclusive_address = exclusive_address;
    cpu->exclusive_generation = 0;
    cpu->exclusive_size = exclusive_size;
    cpu->exclusive_valid = exclusive_valid;
    cpu->halted = halted;
}

static void copy_cpu_to_registers(
    const AVZNativeCPU *cpu,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted
) {
    for (size_t index = 0; index < 31; index++) {
        x31[index] = cpu->x[index];
    }
    if (v32_low != 0 && v32_high != 0) {
        for (size_t index = 0; index < 32; index++) {
            v32_low[index] = cpu->v[index].low;
            v32_high[index] = cpu->v[index].high;
        }
    }
    *sp = cpu->sp;
    *pc = cpu->pc;
    *pstate = cpu->pstate;
    if (fpcr != 0) {
        *fpcr = cpu->fpcr;
    }
    if (fpsr != 0) {
        *fpsr = cpu->fpsr;
    }
    if (exclusive_address != 0) {
        *exclusive_address = cpu->exclusive_address;
    }
    if (exclusive_size != 0) {
        *exclusive_size = cpu->exclusive_size;
    }
    if (exclusive_valid != 0) {
        *exclusive_valid = cpu->exclusive_valid;
    }
    *halted = cpu->halted;
}

AVZNativeBlockResult avz_native_run_threaded_decoded_block_full_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
) {
    uint64_t exclusive_address = 0;
    uint8_t exclusive_size = 0;
    uint8_t exclusive_valid = 0;
    return avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
        instructions,
        instruction_count,
        base_pc,
        max_steps,
        x31,
        v32_low,
        v32_high,
        sp,
        pc,
        pstate,
        fpcr,
        fpsr,
        &exclusive_address,
        &exclusive_size,
        &exclusive_valid,
        halted,
        read_memory,
        write_memory,
        can_access_memory,
        fill_memory,
        0,
        0,
        0,
        0,
        0,
        0,
        memory_context
    );
}

#if defined(AVZ_DISABLE_COMPUTED_GOTO)
static AVZNativeBlockResult avz_native_run_decoded_block_full_generic(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
) {
    AVZNativeBlockResult result = {
        .steps = 0,
        .generic_dispatches = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .unsupported_instruction = 0
    };
    (void)fill_memory;
    if (instructions == 0 || x31 == 0 || sp == 0 || pc == 0 ||
        pstate == 0 || halted == 0) {
        result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
        return result;
    }

    AVZNativeCPU cpu;
    copy_registers_to_cpu(
        &cpu,
        x31,
        v32_low,
        v32_high,
        *sp,
        *pc,
        *pstate,
        fpcr == 0 ? 0 : *fpcr,
        fpsr == 0 ? 0 : *fpsr,
        exclusive_address == 0 ? 0 : *exclusive_address,
        exclusive_size == 0 ? 0 : *exclusive_size,
        exclusive_valid == 0 ? 0 : *exclusive_valid,
        *halted
    );

    while (result.steps < max_steps) {
        if (cpu.halted) {
            result.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }
        if (cpu.pc < base_pc || ((cpu.pc - base_pc) & 3u) != 0u) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            break;
        }
        uint64_t index64 = (cpu.pc - base_pc) >> 2;
        if (index64 >= instruction_count) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            break;
        }
        const AVZNativeInstruction *instruction = &instructions[index64];
        int execution_status = execute_decoded_instruction(
            instruction,
            &cpu,
            read_memory,
            write_memory,
            can_access_memory,
            read_system_register,
            write_system_register,
            execute_system_instruction,
            exception_return,
            synchronous_exception,
            wait,
            memory_context
        );
        if (execution_status == 0) {
            result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
            result.unsupported_instruction = instruction->raw;
            break;
        }
        result.steps++;
        if (execution_status == AVZ_NATIVE_WAIT_YIELD) {
            result.status = AVZ_NATIVE_STATUS_YIELDED;
            break;
        }
    }
    if (result.steps >= max_steps && result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
        result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    }

    copy_cpu_to_registers(
        &cpu,
        x31,
        v32_low,
        v32_high,
        sp,
        pc,
        pstate,
        fpcr,
        fpsr,
        exclusive_address,
        exclusive_size,
        exclusive_valid,
        halted
    );
    return result;
}

#endif

static AVZNativeBlockResult avz_native_run_threaded_decoded_block_cpu_mapped(
    const AVZNativeInstruction *restrict instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    AVZNativeCPU *restrict cpu_state,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *restrict memory_context,
    uint8_t *restrict semantic_hints,
    const uint64_t *restrict instruction_pcs,
    const uint16_t *restrict block_offsets,
    size_t fused_block_count,
    const AVZNativeBlockCache *block_cache,
    uint64_t code_mutation_epoch
) {
    AVZNativeBlockResult result = {
        .steps = 0,
        .generic_dispatches = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .unsupported_instruction = 0
    };

    if (instructions == 0 || cpu_state == 0) {
        result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
        return result;
    }

#define cpu (*cpu_state)

#if !defined(AVZ_DISABLE_COMPUTED_GOTO)
    const AVZNativeInstruction *instruction = 0;
    uint64_t index64 = 0;
    size_t boundary_cursor = 1;
    const uint64_t *code_mutation_epoch_token =
        avz_native_block_cache_code_mutation_epoch_token(block_cache);

#define AVZ_THREADED_FINISH(next_status) \
    do { \
        result.status = (uint32_t)(next_status); \
        goto done; \
    } while (0)

#define AVZ_THREADED_STEP() \
    do { \
        result.steps++; \
        if (instruction_pcs != NULL) { \
            index64++; \
        } \
        goto dispatch; \
    } while (0)

dispatch:
    if (result.steps >= max_steps) {
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_MAX_STEPS);
    }
    if (instruction_pcs != NULL) {
        if (index64 >= instruction_count) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        int at_block_boundary = block_offsets != NULL &&
            boundary_cursor < fused_block_count &&
            index64 == block_offsets[boundary_cursor];
        /*
         * Every control-flow instruction terminates a decoded block. Within a
         * block, the next PC is therefore necessarily linear. Validate the
         * mapped trace at entry and after each terminator instead of loading
         * and comparing the expected PC for every guest instruction.
         */
        if ((index64 == 0 || at_block_boundary) &&
            instruction_pcs[index64] != cpu.pc) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        if (at_block_boundary) {
            if (code_mutation_epoch_token == NULL ||
                *code_mutation_epoch_token != code_mutation_epoch) {
                AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
            }
            boundary_cursor++;
        }
    } else {
        if (cpu.pc < base_pc || ((cpu.pc - base_pc) & 3) != 0) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        index64 = (cpu.pc - base_pc) >> 2;
        if (index64 >= instruction_count) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
    }
    uint64_t fast_steps = 0;
    const AVZNativeInstruction *fast_instructions = instructions;
    size_t fast_instruction_count = instruction_count;
    uint64_t fast_base_pc = base_pc;
    if (instruction_pcs != NULL) {
        size_t block_index = boundary_cursor - 1;
        size_t block_start = block_offsets[block_index];
        size_t block_end = block_offsets[block_index + 1];
        if (index64 == block_start && block_end > block_start) {
            fast_instructions = &instructions[block_start];
            fast_instruction_count = block_end - block_start;
            fast_base_pc = instruction_pcs[block_start];
        } else {
            fast_instruction_count = 0;
        }
    }
    int used_semantic_fast_path = 0;
    int semantic_fast_path_exits_mapped_block = 0;
    if (instruction_pcs != NULL &&
        (instructions[index64].raw == UINT32_C(0x38616864) ||
         instructions[index64].raw == UINT32_C(0x38616803))) {
        used_semantic_fast_path = try_execute_musl_symbol_name_compare_loop(
            instructions,
            instruction_pcs,
            instruction_count,
            cpu.pc,
            max_steps - result.steps,
            &cpu,
            read_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (fast_instruction_count > 0 &&
        fast_instructions[0].raw == UINT32_C(0x0cdf0104)) {
        used_semantic_fast_path = try_execute_pixman_source_over_prefix(
            instructions,
            instruction_pcs,
            instruction_count,
            semantic_hints == NULL ? NULL : &semantic_hints[index64],
            max_steps - result.steps,
            &cpu,
            read_memory,
            write_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (fast_instruction_count > 0 &&
        fast_instructions[0].raw == UINT32_C(0x5400004d)) {
        used_semantic_fast_path = try_execute_pixman_source_over_tail(
            instructions,
            instruction_pcs,
            instruction_count,
            semantic_hints == NULL ? NULL : &semantic_hints[index64],
            max_steps - result.steps,
            &cpu,
            read_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (fast_instruction_count == 3 &&
        fast_instructions[0].raw == UINT32_C(0x91000421)) {
        used_semantic_fast_path = try_execute_byte_string_scan_loop(
            fast_instructions,
            fast_instruction_count,
            fast_base_pc,
            max_steps - result.steps,
            &cpu,
            read_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (fast_instruction_count == 5 &&
        fast_instructions[0].raw == UINT32_C(0x11000718)) {
        int exited_hash_loop = 0;
        used_semantic_fast_path = try_execute_glib_djb2_string_hash_loop(
            fast_instructions,
            fast_instruction_count,
            fast_base_pc,
            max_steps - result.steps,
            &cpu,
            read_memory,
            memory_context,
            &fast_steps,
            &exited_hash_loop
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (instruction_pcs != NULL &&
        instructions[index64].raw == UINT32_C(0x39400003)) {
        used_semantic_fast_path = try_execute_musl_memcmp_loop(
            instructions,
            instruction_pcs,
            instruction_count,
            index64,
            cpu.pc,
            max_steps - result.steps,
            &cpu,
            read_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (instruction_pcs != NULL &&
        index64 + 1 < instruction_count &&
        instructions[index64].raw == UINT32_C(0x0c9f2840) &&
        instruction_pcs[index64 + 1] == cpu.pc + 4 &&
        instructions[index64 + 1].raw == UINT32_C(0x0cdf2880)) {
        used_semantic_fast_path = try_execute_pixman_neon_copy_loop(
            semantic_hints == NULL ? NULL : &semantic_hints[index64],
            cpu.pc,
            max_steps - result.steps,
            &cpu,
            read_memory,
            write_memory,
            memory_context,
            &fast_steps
        );
        semantic_fast_path_exits_mapped_block = used_semantic_fast_path;
    } else if (fast_instruction_count == 3 &&
        fast_instructions[0].kind ==
            AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE) {
        used_semantic_fast_path = try_execute_simd_solid_fill_loop(
            fast_instructions,
            fast_instruction_count,
            fast_base_pc,
            max_steps - result.steps,
            &cpu,
            fill_memory,
            memory_context,
            &fast_steps
        );
    } else if (fast_instruction_count >= 3 &&
               fast_instructions[0].kind == AVZ_NATIVE_OP_LOAD_STORE_PAIR) {
        used_semantic_fast_path = try_execute_store_pair_fill_loop(
            fast_instructions,
            fast_instruction_count,
            fast_base_pc,
            max_steps - result.steps,
            &cpu,
            fill_memory,
            memory_context,
            &fast_steps
        );
    }
    if (used_semantic_fast_path) {
        result.steps += fast_steps;
        result.fast_path_steps += fast_steps;
        result.fast_path_hits++;
        if (semantic_fast_path_exits_mapped_block) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        goto dispatch;
    }

    instruction = &instructions[index64];
    /*
     * Keep dispatch in standard C. Label-address computed goto made this
     * function's generated control flow sensitive to unrelated handler edits.
     */
    switch (instruction->kind) {
    case AVZ_NATIVE_OP_NOP: goto op_nop;
    case AVZ_NATIVE_OP_HALT: goto op_halt;
    case AVZ_NATIVE_OP_ADR: goto op_adr;
    case AVZ_NATIVE_OP_CBZ: goto op_cbz;
    case AVZ_NATIVE_OP_TBZ: goto op_tbz;
    case AVZ_NATIVE_OP_BCOND: goto op_bcond;
    case AVZ_NATIVE_OP_ADD_SUB_IMMEDIATE: goto op_add_sub_immediate;
    case AVZ_NATIVE_OP_MOVE_WIDE: goto op_move_wide;
    case AVZ_NATIVE_OP_ADD_SUB_SHIFTED_REGISTER: goto op_add_sub_shifted_register;
    case AVZ_NATIVE_OP_BRANCH: goto op_branch;
    case AVZ_NATIVE_OP_LOAD_STORE_UNSIGNED_IMMEDIATE: goto op_load_store_unsigned_immediate;
    case AVZ_NATIVE_OP_LOAD_STORE_SIGNED_IMMEDIATE: goto op_load_store_signed_immediate;
    case AVZ_NATIVE_OP_LOAD_STORE_REGISTER_OFFSET: goto op_load_store_register_offset;
    case AVZ_NATIVE_OP_LOAD_STORE_PAIR: goto op_load_store_pair;
    case AVZ_NATIVE_OP_LOGICAL_SHIFTED_REGISTER: goto op_logical_shifted_register;
    case AVZ_NATIVE_OP_LOGICAL_IMMEDIATE: goto op_logical_immediate;
    case AVZ_NATIVE_OP_REGISTER_BRANCH: goto op_register_branch;
    case AVZ_NATIVE_OP_CONDITIONAL_SELECT: goto op_conditional_select;
    case AVZ_NATIVE_OP_BITFIELD_MOVE: goto op_bitfield_move;
    case AVZ_NATIVE_OP_DATA_PROCESSING_ONE_SOURCE: goto op_data_processing_one_source;
    case AVZ_NATIVE_OP_DATA_PROCESSING_TWO_SOURCE: goto op_data_processing_two_source;
    case AVZ_NATIVE_OP_LOAD_LITERAL: goto op_load_literal;
    case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER:
    case AVZ_NATIVE_OP_CONDITIONAL_COMPARE_IMMEDIATE: goto op_conditional_compare;
    case AVZ_NATIVE_OP_ADD_SUB_EXTENDED_REGISTER: goto op_add_sub_extended_register;
    case AVZ_NATIVE_OP_MULTIPLY_ADD_SUBTRACT: goto op_multiply_add_subtract;
    case AVZ_NATIVE_OP_SIGNED_MULTIPLY_LONG_ADD_SUBTRACT: goto op_signed_multiply_long_add_subtract;
    case AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_LONG_ADD_SUBTRACT: goto op_unsigned_multiply_long_add_subtract;
    case AVZ_NATIVE_OP_ADD_SUB_CARRY: goto op_add_sub_carry;
    case AVZ_NATIVE_OP_SIGNED_MULTIPLY_HIGH: goto op_signed_multiply_high;
    case AVZ_NATIVE_OP_UNSIGNED_MULTIPLY_HIGH: goto op_unsigned_multiply_high;
    case AVZ_NATIVE_OP_LOAD_ACQUIRE_STORE_RELEASE: goto op_load_acquire_store_release;
    case AVZ_NATIVE_OP_LOAD_STORE_EXCLUSIVE: goto op_load_store_exclusive;
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ: goto op_system_register_read;
    case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE: goto op_system_register_write;
    case AVZ_NATIVE_OP_BARRIER: goto op_barrier;
    case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION: goto op_system_instruction;
    case AVZ_NATIVE_OP_EXCEPTION_RETURN: goto op_exception_return;
    case AVZ_NATIVE_OP_PSTATE_IMMEDIATE: goto op_pstate_immediate;
    case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION: goto op_synchronous_exception;
    case AVZ_NATIVE_OP_WAIT: goto op_wait;
    case AVZ_NATIVE_OP_SIMD_MOVE_VECTOR_ELEMENT_TO_GENERAL: goto op_simd_move_vector_element_to_general;
    case AVZ_NATIVE_OP_SIMD_MULTIPLY_LONG: goto op_simd_multiply_long;
    case AVZ_NATIVE_OP_SIMD_NARROW_HIGH: goto op_simd_narrow_high;
    case AVZ_NATIVE_OP_SIMD_BITWISE_NOT: goto op_simd_bitwise_not;
    case AVZ_NATIVE_OP_SIMD_SATURATING_ADD_SUBTRACT: goto op_simd_saturating_add_subtract;
    case AVZ_NATIVE_OP_SIMD_SHIFT_LEFT_IMMEDIATE: goto op_simd_shift_left_immediate;
    case AVZ_NATIVE_OP_SIMD_SHIFT_RIGHT_IMMEDIATE: goto op_simd_shift_right_immediate;
    case AVZ_NATIVE_OP_SIMD_LOAD_STORE_MULTIPLE_STRUCTURE: goto op_simd_load_store_multiple_structure;
    case AVZ_NATIVE_OP_SIMD_COMPARE_EQUAL_VECTOR: goto op_simd_compare_equal_vector;
    case AVZ_NATIVE_OP_SIMD_COUNT_SET_BITS: goto op_simd_count_set_bits;
    case AVZ_NATIVE_OP_SIMD_COUNT_LEADING_ZEROS: goto op_simd_count_leading_zeros;
    default: goto op_generic;
    }

op_nop:
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_halt:
    cpu.pc += 4;
    cpu.halted = 1;
    result.steps++;
    AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_HALTED);

op_adr: {
    uint64_t current_pc = cpu.pc;
    uint64_t base = (instruction->flags & 1) ? (current_pc & ~UINT64_C(0xfff)) : current_pc;
    write_register(
        &cpu,
        instruction->rd,
        add_signed_offset(base, instruction->immediate)
    );
    cpu.pc = current_pc + 4;
    AVZ_THREADED_STEP();
}

op_cbz: {
    uint64_t current_pc = cpu.pc;
    uint64_t value = instruction->bits == 64
        ? read_register(&cpu, instruction->rt)
        : (read_register(&cpu, instruction->rt) & UINT64_C(0xffffffff));
    int branch_non_zero = (instruction->flags & 1) != 0;
    cpu.pc = ((value != 0) == branch_non_zero)
        ? add_signed_offset(current_pc, instruction->immediate)
        : current_pc + 4;
    AVZ_THREADED_STEP();
}

op_tbz: {
    uint64_t current_pc = cpu.pc;
    int bit_set = ((read_register(&cpu, instruction->rt) >> instruction->shift_amount) & 1) != 0;
    int branch_non_zero = (instruction->flags & 1) != 0;
    cpu.pc = (bit_set == branch_non_zero)
        ? add_signed_offset(current_pc, instruction->immediate)
        : current_pc + 4;
    AVZ_THREADED_STEP();
}

op_bcond: {
    uint64_t current_pc = cpu.pc;
    cpu.pc = condition_holds(instruction->condition, cpu.pstate)
        ? add_signed_offset(current_pc, instruction->immediate)
        : current_pc + 4;
    AVZ_THREADED_STEP();
}

op_add_sub_immediate: {
    unsigned bits = instruction->bits;
    int subtract = (instruction->flags & 1) != 0;
    int set_flags = (instruction->flags & 2) != 0;
    uint64_t lhs = masked_operand(read_base_register(&cpu, instruction->rn), bits);
    uint64_t rhs = masked_operand((uint64_t)instruction->immediate, bits);
    uint64_t value = 0;
    if (subtract) {
        rhs = (~rhs) & mask_for_bits(bits);
    }
    uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &value);
    if (set_flags) {
        cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
        write_register(&cpu, instruction->rd, value);
    } else {
        write_base_register(&cpu, instruction->rd, value);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_move_wide: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t imm = (uint64_t)instruction->immediate;
    uint64_t value = 0;
    switch (instruction->flags) {
    case 0:
        value = (~imm) & mask;
        break;
    case 2:
        value = imm & mask;
        break;
    case 3: {
        uint64_t field_mask = (UINT64_C(0xffff) << instruction->shift_amount) & mask;
        value = (read_register(&cpu, instruction->rd) & ~field_mask) | (imm & field_mask);
        value &= mask;
        break;
    }
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    write_register(&cpu, instruction->rd, value);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_add_sub_shifted_register: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t rhs = masked_operand(read_register(&cpu, instruction->rm), bits);
    uint64_t value = 0;
    switch (instruction->shift_type) {
    case 0:
        rhs = (rhs << instruction->shift_amount) & mask;
        break;
    case 1:
        rhs >>= instruction->shift_amount;
        break;
    case 2:
        if (instruction->shift_amount > 0) {
            rhs = bits == 64
                ? (uint64_t)(((int64_t)rhs) >> instruction->shift_amount)
                : (uint64_t)(((int32_t)(uint32_t)rhs) >> instruction->shift_amount);
        }
        rhs &= mask;
        break;
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    int subtract = (instruction->flags & 1) != 0;
    int set_flags = (instruction->flags & 2) != 0;
    if (subtract) {
        rhs = (~rhs) & mask;
    }
    uint64_t flags = add_with_carry_nzcv(lhs, rhs, subtract ? 1 : 0, bits, &value);
    if (set_flags) {
        cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) | (flags & UINT64_C(0xf0000000));
    }
    write_register(&cpu, instruction->rd, value);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_branch: {
    uint64_t current_pc = cpu.pc;
    if ((instruction->flags & 1) != 0) {
        cpu.x[30] = current_pc + 4;
    }
    cpu.pc = add_signed_offset(current_pc, instruction->immediate);
    AVZ_THREADED_STEP();
}

op_register_branch:
    if ((instruction->flags & 1) != 0) {
        cpu.x[30] = cpu.pc + 4;
    }
    cpu.pc = read_register(&cpu, instruction->rn);
    AVZ_THREADED_STEP();

op_conditional_select: {
    unsigned bits = instruction->bits;
    uint64_t value;
    uint8_t operation = instruction->flags & 3u;
    int invert_or_negate = (instruction->flags & 4u) != 0u;
    if (condition_holds(instruction->condition, cpu.pstate)) {
        value = read_register(&cpu, instruction->rn);
    } else {
        uint64_t fallback = read_register(&cpu, instruction->rm);
        if (operation == 0u) {
            value = invert_or_negate ? ~fallback : fallback;
        } else if (operation == 1u) {
            value = invert_or_negate ? (UINT64_C(0) - fallback) : (fallback + 1u);
        } else {
            result.unsupported_instruction = instruction->raw;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
        }
    }
    write_register(&cpu, instruction->rd, masked_operand(value, bits));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_bitfield_move: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint8_t opcode = instruction->flags & 3u;
    uint8_t immr = instruction->shift_amount;
    uint8_t imms = instruction->condition;
    uint64_t source = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t rotated = rotate_right_width(source, immr, bits);
    uint64_t write_mask = (uint64_t)instruction->immediate & mask;
    uint64_t top_mask = (uint64_t)instruction->immediate2 & mask;
    uint64_t value;
    if (opcode == 0u) {
        uint64_t sign_bit = (source >> (imms & (bits - 1u))) & 1u;
        value = ((sign_bit ? mask : 0u) & ~top_mask) |
            ((rotated & write_mask) & top_mask);
    } else if (opcode == 1u) {
        uint64_t insert_value = 0;
        uint64_t insert_mask = 0;
        bitfield_insert(source, immr, imms, bits, &insert_value, &insert_mask);
        value = (read_register(&cpu, instruction->rd) & ~insert_mask & mask) |
            (insert_value & insert_mask);
    } else if (opcode == 2u) {
        value = (rotated & write_mask) & top_mask;
    } else {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    write_register(&cpu, instruction->rd, value & mask);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_data_processing_one_source: {
    unsigned bits = instruction->bits;
    uint64_t source = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t value;
    switch (instruction->flags) {
    case 0x00: value = reverse_bits_width(source, bits); break;
    case 0x01: value = reverse_bytes_group(source, 2, bits); break;
    case 0x02: value = reverse_bytes_group(source, 4, bits); break;
    case 0x03:
        if (bits != 64u) {
            result.unsupported_instruction = instruction->raw;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
        }
        value = reverse_bytes_group(source, 8, bits);
        break;
    case 0x04: value = count_leading_zeros_width(source, bits); break;
    case 0x05: value = count_leading_sign_bits_width(source, bits); break;
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    write_register(&cpu, instruction->rd, value);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_data_processing_two_source: {
    unsigned bits = instruction->bits;
    uint64_t source = read_register(&cpu, instruction->rn);
    uint64_t rhs = read_register(&cpu, instruction->rm);
    uint64_t value = 0;
    switch (instruction->flags) {
    case 0x02:
        source = masked_operand(source, bits);
        rhs = masked_operand(rhs, bits);
        value = rhs == 0 ? 0 : source / rhs;
        break;
    case 0x03:
        value = signed_divide_width(source, rhs, bits);
        break;
    case 0x08:
        value = shifted_register_value(
            source,
            0,
            (uint8_t)(rhs & (bits - 1u)),
            bits
        );
        break;
    case 0x09:
        value = shifted_register_value(
            source,
            1,
            (uint8_t)(rhs & (bits - 1u)),
            bits
        );
        break;
    case 0x0a:
        value = shifted_register_value(
            source,
            2,
            (uint8_t)(rhs & (bits - 1u)),
            bits
        );
        break;
    case 0x0b:
        value = rotate_right_width(
            source,
            (unsigned)(rhs & (bits - 1u)),
            bits
        );
        break;
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    write_register(&cpu, instruction->rd, masked_operand(value, bits));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_literal: {
    if (instruction->flags == 3u) {
        cpu.pc += 4;
        AVZ_THREADED_STEP();
    }
    uint64_t address = add_signed_offset(cpu.pc, instruction->immediate);
    uint64_t value = 0;
    if (read_memory == 0 ||
        !read_memory(memory_context, address, instruction->width, &value)) {
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
    }
    if (instruction->flags == 2u) {
        value = sign_extend_loaded(value, 32);
    }
    write_register(&cpu, instruction->rt, value);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_conditional_compare: {
    unsigned bits = instruction->bits;
    uint64_t flags;
    if (condition_holds(instruction->condition, cpu.pstate)) {
        uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
        uint64_t rhs = instruction->kind == AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER
            ? masked_operand(read_register(&cpu, instruction->rm), bits)
            : masked_operand((uint64_t)instruction->immediate, bits);
        uint64_t arithmetic_result = 0;
        int subtract = (instruction->flags & 1u) != 0u;
        if (subtract) {
            rhs = (~rhs) & mask_for_bits(bits);
        }
        flags = add_with_carry_nzcv(
            lhs, rhs, subtract, bits, &arithmetic_result
        );
    } else {
        flags = instruction->kind == AVZ_NATIVE_OP_CONDITIONAL_COMPARE_REGISTER
            ? (uint64_t)instruction->immediate
            : (uint64_t)instruction->immediate2;
    }
    cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) |
        (flags & UINT64_C(0xf0000000));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_add_sub_extended_register: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_base_register(&cpu, instruction->rn), bits);
    uint64_t rhs = masked_operand(
        extended_register_value(
            read_register(&cpu, instruction->rm), instruction->condition
        ) << instruction->shift_amount,
        bits
    );
    uint64_t arithmetic_result;
    int subtract = (instruction->flags & 1u) != 0u;
    int set_flags = (instruction->flags & 2u) != 0u;
    if (subtract) {
        rhs = (~rhs) & mask;
    }
    uint64_t flags = add_with_carry_nzcv(
        lhs, rhs, subtract, bits, &arithmetic_result
    );
    if (set_flags) {
        cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) |
            (flags & UINT64_C(0xf0000000));
        write_register(&cpu, instruction->rd, arithmetic_result);
    } else {
        write_base_register(&cpu, instruction->rd, arithmetic_result);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_add_sub_carry: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t rhs = masked_operand(read_register(&cpu, instruction->rm), bits);
    uint64_t arithmetic_result;
    int subtract = (instruction->flags & 1u) != 0u;
    int set_flags = (instruction->flags & 2u) != 0u;
    int carry_in = (cpu.pstate & UINT64_C(0x20000000)) != 0u;
    if (subtract) {
        rhs = (~rhs) & mask;
    }
    uint64_t flags = add_with_carry_nzcv(
        lhs, rhs, carry_in, bits, &arithmetic_result
    );
    if (set_flags) {
        cpu.pstate = (cpu.pstate & ~UINT64_C(0xf0000000)) |
            (flags & UINT64_C(0xf0000000));
    }
    write_register(&cpu, instruction->rd, arithmetic_result);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_multiply_add_subtract: {
    unsigned bits = instruction->bits;
    uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t rhs = masked_operand(read_register(&cpu, instruction->rm), bits);
    uint64_t addend = masked_operand(read_register(&cpu, instruction->rt), bits);
    uint64_t product = (lhs * rhs) & mask_for_bits(bits);
    uint64_t value = (instruction->flags & 1u) != 0u
        ? addend - product : addend + product;
    write_register(&cpu, instruction->rd, masked_operand(value, bits));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_signed_multiply_long_add_subtract: {
    int64_t lhs = (int64_t)(int32_t)(uint32_t)read_register(&cpu, instruction->rn);
    int64_t rhs = (int64_t)(int32_t)(uint32_t)read_register(&cpu, instruction->rm);
    uint64_t addend = read_register(&cpu, instruction->rt);
    uint64_t product = (uint64_t)(lhs * rhs);
    write_register(&cpu, instruction->rd, (instruction->flags & 1u) != 0u
        ? addend - product : addend + product);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_unsigned_multiply_long_add_subtract: {
    uint64_t lhs = read_register(&cpu, instruction->rn) & UINT64_C(0xffffffff);
    uint64_t rhs = read_register(&cpu, instruction->rm) & UINT64_C(0xffffffff);
    uint64_t addend = read_register(&cpu, instruction->rt);
    uint64_t product = lhs * rhs;
    write_register(&cpu, instruction->rd, (instruction->flags & 1u) != 0u
        ? addend - product : addend + product);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_signed_multiply_high: {
    __int128 product = (__int128)(int64_t)read_register(&cpu, instruction->rn) *
        (__int128)(int64_t)read_register(&cpu, instruction->rm);
    write_register(&cpu, instruction->rd, (uint64_t)(product >> 64));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_unsigned_multiply_high: {
    unsigned __int128 product =
        (unsigned __int128)read_register(&cpu, instruction->rn) *
        (unsigned __int128)read_register(&cpu, instruction->rm);
    write_register(&cpu, instruction->rd, (uint64_t)(product >> 64));
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_system_register_read: {
    uint64_t value = 0;
    uint16_t key = decoded_system_register_key(instruction->raw);
    int use_local_system_registers =
        read_system_register == NULL ||
        read_system_register == avz_native_fast_read_system_register;
    switch (use_local_system_registers ? key : UINT16_MAX) {
    case (3u << 14) | (0u << 11) | (4u << 7) | (2u << 3) | 2u:
        value = cpu.pstate & UINT64_C(0xc);
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 0u:
        value = cpu.pstate & UINT64_C(0xf0000000);
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 1u:
        value = cpu.pstate & UINT64_C(0x3c0);
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 0u:
        value = cpu.fpcr;
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 1u:
        value = cpu.fpsr;
        break;
    default:
        if (read_system_register == NULL ||
            !read_system_register(
                memory_context,
                instruction->raw,
                cpu.pc,
                cpu.pstate,
                cpu.sp,
                &value
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        break;
    }
    write_register(&cpu, instruction->rt, value);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_system_register_write: {
    uint64_t value = read_register(&cpu, instruction->rt);
    uint16_t key = decoded_system_register_key(instruction->raw);
    int use_local_system_registers =
        write_system_register == NULL ||
        write_system_register == avz_native_fast_write_system_register;
    switch (use_local_system_registers ? key : UINT16_MAX) {
    case (3u << 14) | (0u << 11) | (4u << 7) | (2u << 3) | 2u:
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 0u:
        cpu.pstate =
            (cpu.pstate & ~UINT64_C(0xf0000000)) |
            (value & UINT64_C(0xf0000000));
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (2u << 3) | 1u:
        cpu.pstate =
            (cpu.pstate & ~UINT64_C(0x3c0)) |
            (value & UINT64_C(0x3c0));
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 0u:
        cpu.fpcr = value;
        break;
    case (3u << 14) | (3u << 11) | (4u << 7) | (4u << 3) | 1u:
        cpu.fpsr = value;
        break;
    default:
        if (write_system_register == NULL ||
            !write_system_register(
                memory_context,
                instruction->raw,
                cpu.pc,
                value,
                &cpu.pstate,
                &cpu.sp
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        break;
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_barrier:
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_system_instruction:
    if (execute_system_instruction == 0 ||
        !execute_system_instruction(
            memory_context,
            instruction->raw,
            read_register(&cpu, instruction->rt)
        )) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_exception_return:
    if (exception_return == 0 ||
        !exception_return(memory_context, &cpu.pstate, &cpu.sp, &cpu.pc)) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    AVZ_THREADED_STEP();

op_pstate_immediate:
    if (instruction->flags == 0x6u) {
        cpu.pstate |= (uint64_t)instruction->immediate;
    } else {
        cpu.pstate &= ~(uint64_t)instruction->immediate;
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_synchronous_exception:
    if (synchronous_exception == 0 ||
        !synchronous_exception(
            memory_context,
            instruction->raw,
            cpu.x,
            &cpu.pstate,
            &cpu.sp,
            &cpu.pc
        )) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    AVZ_THREADED_STEP();

op_wait:
    if (wait == 0) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    {
        int wait_status = wait(memory_context, instruction->raw, &cpu.pc);
        if (wait_status == AVZ_NATIVE_WAIT_UNSUPPORTED) {
            result.unsupported_instruction = instruction->raw;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
        }
        if (wait_status == AVZ_NATIVE_WAIT_YIELD) {
            result.steps++;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_YIELDED);
        }
    }
    AVZ_THREADED_STEP();

op_simd_move_vector_element_to_general:
    write_register(
        &cpu,
        instruction->rd,
        read_vector_element(&cpu, instruction->rn, instruction->condition, instruction->bits)
    );
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_simd_multiply_long:
#if defined(__aarch64__) && defined(__ARM_NEON)
    if (execute_simd_multiply_long_neon(&cpu, instruction)) {
        cpu.pc += 4;
        AVZ_THREADED_STEP();
    }
#endif
    goto op_generic;

op_simd_narrow_high:
#if defined(__aarch64__) && defined(__ARM_NEON)
    if (execute_simd_narrow_high_neon(&cpu, instruction)) {
        cpu.pc += 4;
        AVZ_THREADED_STEP();
    }
#endif
    goto op_generic;

op_simd_bitwise_not:
    cpu.v[instruction->rd] = (AVZNativeVectorRegister){
        ~cpu.v[instruction->rn].low,
        (instruction->flags & 1u) != 0u
            ? ~cpu.v[instruction->rn].high
            : 0
    };
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_simd_saturating_add_subtract:
#if defined(__aarch64__) && defined(__ARM_NEON)
    if (execute_simd_saturating_add_subtract_neon(&cpu, instruction)) {
        cpu.pc += 4;
        AVZ_THREADED_STEP();
    }
#endif
    if (!execute_simd_saturating_add_subtract_portable(&cpu, instruction)) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_simd_shift_left_immediate:
    if (!execute_simd_shift_left_immediate_portable(&cpu, instruction)) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_simd_shift_right_immediate:
#if defined(__aarch64__) && defined(__ARM_NEON)
    if (execute_simd_shift_right_immediate_neon(&cpu, instruction)) {
        cpu.pc += 4;
        AVZ_THREADED_STEP();
    }
#endif
    if (!execute_simd_shift_right_immediate_portable(&cpu, instruction)) {
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();

op_simd_load_store_multiple_structure:
    if (try_execute_simd_multiple_structure_bulk(
            &cpu,
            instruction,
            read_memory,
            write_memory,
            memory_context
        )) {
        AVZ_THREADED_STEP();
    }
    goto op_generic;

op_logical_shifted_register: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t rhs = shifted_register_value(
        read_register(&cpu, instruction->rm),
        instruction->shift_type,
        instruction->shift_amount,
        bits
    );
    uint8_t opcode = instruction->flags & 3;
    if ((instruction->flags & 4) != 0) {
        rhs = (~rhs) & mask;
    }

    uint64_t value = 0;
    switch (opcode) {
    case 0:
        value = lhs & rhs;
        break;
    case 1:
        value = lhs | rhs;
        break;
    case 2:
        value = lhs ^ rhs;
        break;
    case 3:
        value = lhs & rhs;
        cpu.pstate &= ~UINT64_C(0xf0000000);
        if ((value & sign_bit_for_bits(bits)) != 0) {
            cpu.pstate |= UINT64_C(0x80000000);
        }
        if (value == 0) {
            cpu.pstate |= UINT64_C(0x40000000);
        }
        break;
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }

    write_register(&cpu, instruction->rd, value & mask);
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_logical_immediate: {
    unsigned bits = instruction->bits;
    uint64_t mask = mask_for_bits(bits);
    uint64_t lhs = masked_operand(read_register(&cpu, instruction->rn), bits);
    uint64_t immediate = ((uint64_t)instruction->immediate) & mask;
    uint8_t opcode = instruction->flags & 3;
    uint64_t value = 0;
    switch (opcode) {
    case 0:
        value = lhs & immediate;
        break;
    case 1:
        value = lhs | immediate;
        break;
    case 2:
        value = lhs ^ immediate;
        break;
    case 3:
        value = lhs & immediate;
        cpu.pstate &= ~UINT64_C(0xf0000000);
        if ((value & sign_bit_for_bits(bits)) != 0) {
            cpu.pstate |= UINT64_C(0x80000000);
        }
        if (value == 0) {
            cpu.pstate |= UINT64_C(0x40000000);
        }
        break;
    default:
        result.unsupported_instruction = instruction->raw;
        AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
    }
    if (opcode == 3) {
        write_register(&cpu, instruction->rd, value & mask);
    } else {
        write_base_register(&cpu, instruction->rd, value & mask);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_store_register_offset: {
    uint64_t offset = extended_register_value(
        read_register(&cpu, instruction->rm),
        instruction->condition
    ) << instruction->shift_amount;
    uint64_t address = read_base_register(&cpu, instruction->rn) + offset;
    uint64_t value = 0;
    if ((instruction->flags & 1u) != 0u) {
        if (read_memory == NULL ||
            !read_memory(memory_context, address, instruction->width, &value)) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        if ((instruction->flags & 2u) != 0u) {
            value = sign_extend_loaded(value, instruction->bits);
            if ((instruction->flags & 4u) != 0u) {
                value &= UINT64_C(0xffffffff);
            }
        }
        write_register(&cpu, instruction->rt, value);
    } else {
        value = read_register(&cpu, instruction->rt) &
            mask_for_bits(instruction->bits);
        if (write_memory == NULL ||
            !write_memory(
                memory_context,
                address,
                instruction->width,
                value
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        clear_exclusive_reservation(&cpu);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_acquire_store_release: {
    uint64_t address = read_base_register(&cpu, instruction->rn);
    uint64_t value = 0;
    if ((instruction->flags & 1) != 0) {
        if (read_memory == NULL ||
            !read_memory(
                memory_context,
                address,
                instruction->width,
                &value
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        write_register(&cpu, instruction->rt, value);
    } else {
        if (write_memory == NULL ||
            !write_memory(
                memory_context,
                address,
                instruction->width,
                read_register(&cpu, instruction->rt) &
                    mask_for_bits(instruction->bits)
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        clear_exclusive_reservation(&cpu);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_store_exclusive: {
    uint64_t address = read_base_register(&cpu, instruction->rn);
    uint64_t value = 0;
    if ((instruction->flags & 1) != 0) {
        if (read_memory == avz_native_fast_memory_read) {
            if (!avz_native_fast_memory_exclusive_read(
                    memory_context,
                    address,
                    instruction->width,
                    &value,
                    &cpu.exclusive_generation
                )) {
                AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
            }
        } else if (read_memory == NULL ||
                   !read_memory(
                       memory_context,
                       address,
                       instruction->width,
                       &value
                   )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        write_register(
            &cpu,
            instruction->rt,
            value & mask_for_bits(instruction->bits)
        );
        cpu.exclusive_address = address;
        cpu.exclusive_size = instruction->width;
        cpu.exclusive_valid = 1;
    } else {
        int reservation_matches = cpu.exclusive_valid != 0 &&
            cpu.exclusive_address == address &&
            cpu.exclusive_size == instruction->width;
        if (reservation_matches) {
            uint64_t store_value = read_register(&cpu, instruction->rt) &
                mask_for_bits(instruction->bits);
            if (write_memory == avz_native_fast_memory_write) {
                int exclusive_result = avz_native_fast_memory_exclusive_write(
                    memory_context,
                    address,
                    instruction->width,
                    store_value,
                    cpu.exclusive_generation
                );
                if (exclusive_result < 0) {
                    AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
                }
                reservation_matches = exclusive_result;
            } else if (write_memory == NULL ||
                       !write_memory(
                           memory_context,
                           address,
                           instruction->width,
                           store_value
                       )) {
                AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
            }
        }
        write_register(&cpu, instruction->rd, reservation_matches ? 0 : 1);
        clear_exclusive_reservation(&cpu);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_store_unsigned_immediate: {
    uint64_t address = read_base_register(&cpu, instruction->rn) +
        (uint64_t)instruction->immediate;
    uint64_t value = 0;
    if ((instruction->flags & 1u) != 0u) {
        if (read_memory == NULL ||
            !read_memory(memory_context, address, instruction->width, &value)) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        if ((instruction->flags & 2u) != 0u) {
            value = sign_extend_loaded(value, instruction->bits);
            if ((instruction->flags & 4u) != 0u) {
                value &= UINT64_C(0xffffffff);
            }
        }
        write_register(&cpu, instruction->rt, value);
    } else {
        value = read_register(&cpu, instruction->rt) &
            mask_for_bits(instruction->bits);
        if (write_memory == NULL ||
            !write_memory(
                memory_context,
                address,
                instruction->width,
                value
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        clear_exclusive_reservation(&cpu);
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_simd_compare_equal_vector: {
    unsigned element_bits = instruction->bits;
    unsigned vector_bits = (instruction->flags & 1) != 0 ? 128 : 64;
    unsigned comparison = instruction->flags >> 1;
    uint64_t lane_mask = mask_for_bits(element_bits);
    AVZNativeVectorRegister vector_result = {0, 0};
    for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
        uint64_t lhs = read_vector_element(&cpu, instruction->rn, lane, element_bits);
        uint64_t rhs = read_vector_element(&cpu, instruction->rm, lane, element_bits);
        int matches;
        switch (comparison) {
        case 0:
            matches = lhs == rhs;
            break;
        case 1:
            matches = (lhs & rhs) != 0;
            break;
        case 2:
            matches = lhs > rhs;
            break;
        case 3:
            matches = lhs >= rhs;
            break;
        case 4:
            matches = lhs == 0;
            break;
        case 5:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) > 0;
            break;
        case 6:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) >= 0;
            break;
        case 7:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) < 0;
            break;
        case 8:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) <= 0;
            break;
        case 9:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) > (int64_t)sign_extend_vector_element(
                &cpu, instruction->rm, lane, element_bits
            );
            break;
        case 10:
            matches = (int64_t)sign_extend_vector_element(
                &cpu, instruction->rn, lane, element_bits
            ) >= (int64_t)sign_extend_vector_element(
                &cpu, instruction->rm, lane, element_bits
            );
            break;
        default:
            result.unsupported_instruction = instruction->raw;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_UNSUPPORTED);
        }
        write_vector_element(&vector_result, lane, element_bits, matches ? lane_mask : 0);
    }
    cpu.v[instruction->rd] = vector_result;
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_simd_count_set_bits: {
    unsigned vector_bits = (instruction->flags & 1) != 0 ? 128 : 64;
    AVZNativeVectorRegister vector_result = {0, 0};
    for (unsigned lane = 0; lane < vector_bits / 8u; lane++) {
        uint8_t byte = (uint8_t)read_vector_element(&cpu, instruction->rn, lane, 8);
        write_vector_element(&vector_result, lane, 8, popcount_u8(byte));
    }
    cpu.v[instruction->rd] = vector_result;
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_simd_count_leading_zeros: {
    unsigned element_bits = instruction->bits;
    unsigned vector_bits = (instruction->flags & 1u) != 0u ? 128u : 64u;
    AVZNativeVectorRegister vector_result = {0, 0};
    for (unsigned lane = 0; lane < vector_bits / element_bits; lane++) {
        uint64_t value = read_vector_element(
            &cpu, instruction->rn, lane, element_bits
        );
        write_vector_element(
            &vector_result, lane, element_bits,
            count_leading_zeros_width(value, element_bits)
        );
    }
    cpu.v[instruction->rd] = vector_result;
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_store_signed_immediate: {
    uint64_t base = read_base_register(&cpu, instruction->rn);
    uint64_t address = add_signed_offset(base, instruction->immediate);
    uint64_t value = 0;
    if ((instruction->flags & 1u) != 0u) {
        if (read_memory == NULL ||
            !read_memory(memory_context, address, instruction->width, &value)) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        if ((instruction->flags & 2u) != 0u) {
            value = sign_extend_loaded(value, instruction->bits);
            if ((instruction->flags & 4u) != 0u) {
                value &= UINT64_C(0xffffffff);
            }
        }
        write_register(&cpu, instruction->rt, value);
    } else {
        value = read_register(&cpu, instruction->rt) &
            mask_for_bits(instruction->bits);
        if (write_memory == NULL ||
            !write_memory(
                memory_context,
                address,
                instruction->width,
                value
            )) {
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
        }
        clear_exclusive_reservation(&cpu);
    }
    if ((instruction->flags & 8u) != 0u) {
        write_base_register(
            &cpu,
            instruction->rn,
            add_signed_offset(base, instruction->immediate2)
        );
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_load_store_pair: {
    uint64_t base = read_base_register(&cpu, instruction->rn);
    uint64_t first_address = add_signed_offset(base, instruction->immediate);
    uint64_t second_address = first_address + instruction->width;
    uint8_t is_write = (instruction->flags & 1) == 0;
    size_t pair_byte_count = (size_t)instruction->width * 2u;
    uint8_t *mapped_pair = NULL;
    uint64_t mapped_pair_physical_address = 0;
    int pair_is_directly_mapped =
        instruction->width <= sizeof(uint64_t) &&
        ((is_write && write_memory == avz_native_fast_memory_write) ||
         (!is_write && read_memory == avz_native_fast_memory_read)) &&
        avz_native_fast_memory_map_span(
            memory_context,
            first_address,
            pair_byte_count,
            is_write,
            &mapped_pair,
            &mapped_pair_physical_address
        );

    if ((instruction->flags & 1) != 0) {
        uint64_t first = 0;
        uint64_t second = 0;
        if (pair_is_directly_mapped) {
            memcpy(&first, mapped_pair, instruction->width);
            memcpy(&second, mapped_pair + instruction->width, instruction->width);
        } else {
            if (can_access_memory == 0 ||
                !can_access_memory(memory_context, first_address, instruction->width, 0) ||
                !can_access_memory(memory_context, second_address, instruction->width, 0) ||
                read_memory == 0 ||
                !read_memory(memory_context, first_address, instruction->width, &first) ||
                !read_memory(memory_context, second_address, instruction->width, &second)) {
                AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
            }
        }
        if ((instruction->flags & 2) != 0) {
            first = sign_extend_loaded(first, 32);
            second = sign_extend_loaded(second, 32);
        }
        write_register(&cpu, instruction->rt, first);
        write_register(&cpu, instruction->rd, second);
    } else {
        uint64_t first = read_register(&cpu, instruction->rt) & mask_for_bits(instruction->bits);
        uint64_t second = read_register(&cpu, instruction->rd) & mask_for_bits(instruction->bits);
        if (pair_is_directly_mapped) {
            memcpy(mapped_pair, &first, instruction->width);
            memcpy(mapped_pair + instruction->width, &second, instruction->width);
            avz_native_fast_memory_commit_write_span(
                memory_context,
                mapped_pair_physical_address,
                pair_byte_count
            );
        } else {
            if (can_access_memory == 0 ||
                !can_access_memory(memory_context, first_address, instruction->width, 1) ||
                !can_access_memory(memory_context, second_address, instruction->width, 1) ||
                write_memory == 0 ||
                !write_memory(
                    memory_context,
                    first_address,
                    instruction->width,
                    first
                ) ||
                !write_memory(
                    memory_context,
                    second_address,
                    instruction->width,
                    second
                )) {
                AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_OUTSIDE_BLOCK);
            }
        }
        clear_exclusive_reservation(&cpu);
    }
    if ((instruction->flags & 8) != 0) {
        write_base_register(
            &cpu,
            instruction->rn,
            add_signed_offset(base, instruction->immediate2)
        );
    }
    cpu.pc += 4;
    AVZ_THREADED_STEP();
}

op_generic:
    result.generic_dispatches++;
    {
        int execution_status = execute_decoded_instruction(
        instruction,
        &cpu,
        read_memory,
        write_memory,
        can_access_memory,
        read_system_register,
        write_system_register,
        execute_system_instruction,
        exception_return,
        synchronous_exception,
        wait,
        memory_context
        );
        if (execution_status == 0) {
            result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
            result.unsupported_instruction = instruction == 0 ? 0 : instruction->raw;
            goto done;
        }
        if (execution_status == AVZ_NATIVE_WAIT_YIELD) {
            result.steps++;
            AVZ_THREADED_FINISH(AVZ_NATIVE_STATUS_YIELDED);
        }
    }
    AVZ_THREADED_STEP();

done:
    return result;

#undef AVZ_THREADED_FINISH
#undef AVZ_THREADED_STEP
#else
    (void)fill_memory;
    uint64_t index64 = 0;
    size_t boundary_cursor = 1;
    while (result.steps < max_steps) {
        if (cpu.halted) {
            result.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }
        if (instruction_pcs != NULL) {
            if (index64 >= instruction_count ||
                instruction_pcs[index64] != cpu.pc) {
                result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
                break;
            }
            if (block_offsets != NULL &&
                boundary_cursor < fused_block_count &&
                index64 == block_offsets[boundary_cursor]) {
                if (block_cache == NULL ||
                    avz_native_block_cache_code_mutation_epoch(block_cache) !=
                        code_mutation_epoch) {
                    result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
                    break;
                }
                boundary_cursor++;
            }
        } else {
            if (cpu.pc < base_pc || ((cpu.pc - base_pc) & 3u) != 0u) {
                result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
                break;
            }
            index64 = (cpu.pc - base_pc) >> 2;
            if (index64 >= instruction_count) {
                result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
                break;
            }
        }
        const AVZNativeInstruction *instruction = &instructions[index64];
        int execution_status = execute_decoded_instruction(
            instruction,
            &cpu,
            read_memory,
            write_memory,
            can_access_memory,
            read_system_register,
            write_system_register,
            execute_system_instruction,
            exception_return,
            synchronous_exception,
            wait,
            memory_context
        );
        if (execution_status == 0) {
            result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
            result.unsupported_instruction = instruction->raw;
            break;
        }
        result.steps++;
        if (execution_status == AVZ_NATIVE_WAIT_YIELD) {
            result.status = AVZ_NATIVE_STATUS_YIELDED;
            break;
        }
        if (instruction_pcs != NULL) {
            index64++;
        }
    }
    if (result.steps >= max_steps &&
        result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
        result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    }
    return result;
#endif
#undef cpu
}

static AVZNativeBlockResult avz_native_run_threaded_decoded_block_cpu_impl(
    const AVZNativeInstruction *restrict instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    AVZNativeCPU *restrict cpu_state,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *restrict memory_context
) {
    return avz_native_run_threaded_decoded_block_cpu_mapped(
        instructions,
        instruction_count,
        base_pc,
        max_steps,
        cpu_state,
        read_memory,
        write_memory,
        can_access_memory,
        fill_memory,
        read_system_register,
        write_system_register,
        execute_system_instruction,
        exception_return,
        synchronous_exception,
        wait,
        memory_context,
        NULL,
        NULL,
        NULL,
        0,
        NULL,
        0
    );
}

AVZNativeBlockResult avz_native_run_threaded_decoded_block_full_registers_with_exclusive(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
) {
    AVZNativeBlockResult invalid = {
        .steps = 0,
        .generic_dispatches = 0,
        .status = AVZ_NATIVE_STATUS_UNSUPPORTED,
        .unsupported_instruction = 0
    };
    if (instructions == 0 || x31 == 0 || sp == 0 || pc == 0 ||
        pstate == 0 || halted == 0) {
        return invalid;
    }

    AVZNativeCPU cpu;
    copy_registers_to_cpu(
        &cpu,
        x31,
        v32_low,
        v32_high,
        *sp,
        *pc,
        *pstate,
        fpcr == 0 ? 0 : *fpcr,
        fpsr == 0 ? 0 : *fpsr,
        exclusive_address == 0 ? 0 : *exclusive_address,
        exclusive_size == 0 ? 0 : *exclusive_size,
        exclusive_valid == 0 ? 0 : *exclusive_valid,
        *halted
    );
    AVZNativeBlockResult result = avz_native_run_threaded_decoded_block_cpu_impl(
        instructions,
        instruction_count,
        base_pc,
        max_steps,
        &cpu,
        read_memory,
        write_memory,
        can_access_memory,
        fill_memory,
        read_system_register,
        write_system_register,
        execute_system_instruction,
        exception_return,
        synchronous_exception,
        wait,
        memory_context
    );
    copy_cpu_to_registers(
        &cpu,
        x31,
        v32_low,
        v32_high,
        sp,
        pc,
        pstate,
        fpcr,
        fpsr,
        exclusive_address,
        exclusive_size,
        exclusive_valid,
        halted
    );
    return result;
}

#define AVZ_NATIVE_DIRECT_LINK_COUNT 8192
#define AVZ_NATIVE_DIRECT_LINK_WAYS 4
#define AVZ_NATIVE_DIRECT_LINK_SET_COUNT \
    (AVZ_NATIVE_DIRECT_LINK_COUNT / AVZ_NATIVE_DIRECT_LINK_WAYS)
#define AVZ_NATIVE_SUPERBLOCK_COUNT 1024
#define AVZ_NATIVE_SUPERBLOCK_WAYS 4
#define AVZ_NATIVE_SUPERBLOCK_SET_COUNT \
    (AVZ_NATIVE_SUPERBLOCK_COUNT / AVZ_NATIVE_SUPERBLOCK_WAYS)
#define AVZ_NATIVE_SUPERBLOCK_FRONT_COUNT 256
#define AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS 32
#define AVZ_NATIVE_SUPERBLOCK_MAX_INSTRUCTIONS \
    (AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS * AVZ_NATIVE_BLOCK_MAX_INSTRUCTIONS)
#define AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES \
    (AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS * AVZ_NATIVE_BLOCK_MAX_CODE_PAGES)
#define AVZ_NATIVE_HOT_PC_SET_COUNT 64
#define AVZ_NATIVE_HOT_PC_WAYS 4
#define AVZ_NATIVE_HOT_PC_SAMPLE_INTERVAL 256
#define AVZ_NATIVE_TTBR_BASE_MASK UINT64_C(0x0000fffffffff000)

_Static_assert(
    AVZ_NATIVE_DIRECT_LINK_COUNT % AVZ_NATIVE_DIRECT_LINK_WAYS == 0,
    "direct-link ways must divide the cache size"
);
_Static_assert(
    (AVZ_NATIVE_DIRECT_LINK_SET_COUNT &
     (AVZ_NATIVE_DIRECT_LINK_SET_COUNT - 1)) == 0,
    "direct-link set count must be a power of two"
);
_Static_assert(
    AVZ_NATIVE_SUPERBLOCK_COUNT % AVZ_NATIVE_SUPERBLOCK_WAYS == 0,
    "superblock ways must divide the cache size"
);
_Static_assert(
    (AVZ_NATIVE_SUPERBLOCK_SET_COUNT &
     (AVZ_NATIVE_SUPERBLOCK_SET_COUNT - 1)) == 0,
    "superblock set count must be a power of two"
);
_Static_assert(
    (AVZ_NATIVE_SUPERBLOCK_FRONT_COUNT &
     (AVZ_NATIVE_SUPERBLOCK_FRONT_COUNT - 1)) == 0,
    "superblock front-cache size must be a power of two"
);
_Static_assert(
    sizeof(AVZNativeInstruction) % _Alignof(uint64_t) == 0,
    "packed trace PC storage requires uint64_t alignment"
);
_Static_assert(
    (AVZ_NATIVE_HOT_PC_SET_COUNT & (AVZ_NATIVE_HOT_PC_SET_COUNT - 1)) == 0,
    "hot-PC set count must be a power of two"
);
_Static_assert(
    (AVZ_NATIVE_HOT_PC_SAMPLE_INTERVAL &
     (AVZ_NATIVE_HOT_PC_SAMPLE_INTERVAL - 1)) == 0,
    "hot-PC sampling interval must be a power of two"
);

typedef struct {
    const AVZNativeDecodedBlock *source;
    const AVZNativeDecodedBlock *target;
    const uint64_t *source_serial_token;
    const uint64_t *target_serial_token;
    uint64_t source_serial;
    uint64_t target_serial;
    AVZNativeBlockKey target_key;
    uint64_t code_mutation_epoch;
    uint64_t last_used;
} AVZNativeDirectLink;

typedef struct {
    AVZNativeBlockKey key;
    const AVZNativeBlockCache *cache;
    const AVZNativeDecodedBlock
        *blocks[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS];
    const uint64_t
        *serial_tokens[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS];
    uint64_t serials[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS];
    AVZNativeInstruction *instructions;
    uint64_t *instruction_pcs;
    uint8_t *semantic_hints;
    const uint64_t
        *code_page_generation_tokens[AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES];
    uint64_t
        code_page_generations[AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES];
    uint16_t block_offsets[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS + 1];
    uint64_t reset_epoch;
    uint64_t mutation_epoch;
    uint64_t code_mutation_epoch;
    uint16_t instruction_count;
    uint8_t count;
    uint8_t code_page_count;
    uint8_t requires_cache_residency;
    uint8_t valid;
} AVZNativeSuperblock;

static int avz_native_serial_token_matches(
    const uint64_t *token,
    uint64_t serial
) {
    return token != NULL && serial != 0 && *token == serial;
}

static int avz_native_block_keys_match(
    const AVZNativeBlockKey *left,
    const AVZNativeBlockKey *right
);

static int avz_native_direct_link_is_current(
    AVZNativeDirectLink *link,
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *target_key
) {
    if (link->source != source || link->source_serial != source_serial ||
        target_key == NULL ||
        !avz_native_block_keys_match(&link->target_key, target_key) ||
        !avz_native_serial_token_matches(
            link->source_serial_token,
            source_serial
        ) ||
        !avz_native_serial_token_matches(
            link->target_serial_token,
            link->target_serial
        )) {
        return 0;
    }
    if (!avz_native_decoded_block_code_is_current(cache, link->source) ||
        !avz_native_decoded_block_code_is_current(cache, link->target)) {
        return 0;
    }
    uint64_t code_mutation_epoch =
        avz_native_block_cache_code_mutation_epoch(cache);
    link->code_mutation_epoch = code_mutation_epoch;
    return 1;
}

struct AVZNativeExecutionContext {
    AVZNativeCPU cpu;
    AVZNativeDirectLink direct_links[AVZ_NATIVE_DIRECT_LINK_COUNT];
    AVZNativeSuperblock superblocks[AVZ_NATIVE_SUPERBLOCK_COUNT];
    AVZNativeSuperblock
        *superblock_front[AVZ_NATIVE_SUPERBLOCK_FRONT_COUNT];
    uint8_t superblock_next_victim[AVZ_NATIVE_SUPERBLOCK_SET_COUNT];
    AVZNativeBlockKey superblock_context_key;
    uint64_t superblock_context_hash;
    uint64_t direct_link_clock;
    uint64_t hot_pc_sample_clock;
    AVZNativeHotPC hot_pcs[
        AVZ_NATIVE_HOT_PC_SET_COUNT * AVZ_NATIVE_HOT_PC_WAYS
    ];
    uint8_t hot_pc_profiling_enabled;
    uint8_t superblock_context_valid;
    const AVZNativeDecodedBlock *last_block;
    uint64_t last_block_serial;
};

static uint64_t avz_native_mix_u64(uint64_t value);

static inline void avz_native_sample_hot_pc(
    AVZNativeExecutionContext *context,
    uint64_t pc,
    const AVZNativeInstruction *instructions,
    size_t instruction_count
) {
    if (!context->hot_pc_profiling_enabled) {
        return;
    }
    context->hot_pc_sample_clock++;
    if ((context->hot_pc_sample_clock &
         (AVZ_NATIVE_HOT_PC_SAMPLE_INTERVAL - 1)) != 0) {
        return;
    }

    uint64_t hash = avz_native_mix_u64(pc >> 2);
    size_t base = (size_t)(hash & (AVZ_NATIVE_HOT_PC_SET_COUNT - 1)) *
        AVZ_NATIVE_HOT_PC_WAYS;
    size_t victim = base;
    for (size_t way = 0; way < AVZ_NATIVE_HOT_PC_WAYS; way++) {
        AVZNativeHotPC *entry = &context->hot_pcs[base + way];
        if (entry->pc == pc) {
            entry->samples++;
            return;
        }
        if (entry->samples == 0) {
            entry->pc = pc;
            entry->samples = 1;
            entry->instruction_count = (uint8_t)(
                instruction_count < 4 ? instruction_count : 4
            );
            entry->instruction0 = entry->instruction_count > 0
                ? instructions[0].raw : 0;
            entry->instruction1 = entry->instruction_count > 1
                ? instructions[1].raw : 0;
            entry->instruction2 = entry->instruction_count > 2
                ? instructions[2].raw : 0;
            entry->instruction3 = entry->instruction_count > 3
                ? instructions[3].raw : 0;
            return;
        }
        if (entry->samples < context->hot_pcs[victim].samples) {
            victim = base + way;
        }
    }

    // Space-Saving retains frequent PCs under bounded collision pressure.
    uint64_t inherited_samples = context->hot_pcs[victim].samples;
    context->hot_pcs[victim].pc = pc;
    context->hot_pcs[victim].samples = inherited_samples + 1;
    context->hot_pcs[victim].instruction_count = (uint8_t)(
        instruction_count < 4 ? instruction_count : 4
    );
    context->hot_pcs[victim].instruction0 =
        context->hot_pcs[victim].instruction_count > 0
            ? instructions[0].raw : 0;
    context->hot_pcs[victim].instruction1 =
        context->hot_pcs[victim].instruction_count > 1
            ? instructions[1].raw : 0;
    context->hot_pcs[victim].instruction2 =
        context->hot_pcs[victim].instruction_count > 2
            ? instructions[2].raw : 0;
    context->hot_pcs[victim].instruction3 =
        context->hot_pcs[victim].instruction_count > 3
            ? instructions[3].raw : 0;
}

static size_t avz_native_direct_link_set_base(
    const AVZNativeDecodedBlock *block,
    uint64_t serial
) {
    uint64_t value = ((uint64_t)(uintptr_t)block >> 4) ^ serial;
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    return (size_t)(value & (AVZ_NATIVE_DIRECT_LINK_SET_COUNT - 1)) *
        AVZ_NATIVE_DIRECT_LINK_WAYS;
}

static uint64_t avz_native_mix_u64(uint64_t value) {
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return value;
}

static AVZNativeBlockKey avz_native_canonical_block_key(
    const AVZNativeBlockKey *key
) {
    AVZNativeBlockKey canonical = *key;
    if ((canonical.pc >> 63) != 0) {
        canonical.ttbr0_el1 = 0;
        canonical.ttbr1_el1 &= AVZ_NATIVE_TTBR_BASE_MASK;
    } else {
        canonical.ttbr0_el1 &= AVZ_NATIVE_TTBR_BASE_MASK;
        canonical.ttbr1_el1 = 0;
    }
    return canonical;
}

static int avz_native_block_contexts_match(
    const AVZNativeBlockKey *left,
    const AVZNativeBlockKey *right
) {
    return left->sctlr_el1 == right->sctlr_el1 &&
        left->tcr_el1 == right->tcr_el1 &&
        left->ttbr0_el1 == right->ttbr0_el1 &&
        left->ttbr1_el1 == right->ttbr1_el1 &&
        left->current_el == right->current_el;
}

static uint64_t avz_native_superblock_context_hash(
    AVZNativeExecutionContext *context,
    const AVZNativeBlockKey *key
) {
    if (context->superblock_context_valid &&
        avz_native_block_contexts_match(
            &context->superblock_context_key,
            key
        )) {
        return context->superblock_context_hash;
    }
    uint64_t hash = avz_native_mix_u64(key->sctlr_el1);
    hash ^= avz_native_mix_u64(key->tcr_el1);
    hash ^= avz_native_mix_u64(key->ttbr0_el1);
    hash ^= avz_native_mix_u64(key->ttbr1_el1);
    hash ^= avz_native_mix_u64(key->current_el);
    context->superblock_context_key = *key;
    context->superblock_context_hash = hash;
    context->superblock_context_valid = 1;
    return hash;
}

static size_t avz_native_superblock_index(
    AVZNativeExecutionContext *context,
    const AVZNativeBlockKey *key
) {
    uint64_t hash = avz_native_mix_u64(key->pc) ^
        avz_native_superblock_context_hash(context, key);
    return (size_t)(hash & (AVZ_NATIVE_SUPERBLOCK_SET_COUNT - 1)) *
        AVZ_NATIVE_SUPERBLOCK_WAYS;
}

static size_t avz_native_superblock_front_index(
    AVZNativeExecutionContext *context,
    const AVZNativeBlockKey *key
) {
    uint64_t pc = key->pc >> 2;
    uint64_t hash = pc ^ (pc >> 11) ^
        avz_native_superblock_context_hash(context, key);
    return (size_t)(hash & (AVZ_NATIVE_SUPERBLOCK_FRONT_COUNT - 1));
}

static int avz_native_block_keys_match(
    const AVZNativeBlockKey *left,
    const AVZNativeBlockKey *right
) {
    return left->pc == right->pc &&
        left->sctlr_el1 == right->sctlr_el1 &&
        left->tcr_el1 == right->tcr_el1 &&
        left->ttbr0_el1 == right->ttbr0_el1 &&
        left->ttbr1_el1 == right->ttbr1_el1 &&
        left->current_el == right->current_el;
}

static uint64_t avz_native_next_direct_link_clock(
    AVZNativeExecutionContext *context
) {
    context->direct_link_clock++;
    if (context->direct_link_clock == 0) {
        for (size_t index = 0; index < AVZ_NATIVE_DIRECT_LINK_COUNT; index++) {
            context->direct_links[index].last_used = 0;
        }
        context->direct_link_clock = 1;
    }
    return context->direct_link_clock;
}

static AVZNativeDirectLink *avz_native_find_direct_link(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *target_key
) {
    size_t base = avz_native_direct_link_set_base(source, source_serial);
    for (size_t way = 0; way < AVZ_NATIVE_DIRECT_LINK_WAYS; way++) {
        AVZNativeDirectLink *link = &context->direct_links[base + way];
        if (link->source != source ||
            link->source_serial != source_serial ||
            !avz_native_block_keys_match(&link->target_key, target_key)) {
            continue;
        }
        if (avz_native_direct_link_is_current(
                link,
                cache,
                source,
                source_serial,
                target_key
            )) {
            link->last_used = avz_native_next_direct_link_clock(context);
            return link;
        }
    }
    return NULL;
}

static AVZNativeDirectLink *avz_native_find_recent_direct_link(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    uint64_t source_serial,
    const AVZNativeBlockKey *key_template
) {
    size_t base = avz_native_direct_link_set_base(source, source_serial);
    AVZNativeDirectLink *recent = NULL;
    for (size_t way = 0; way < AVZ_NATIVE_DIRECT_LINK_WAYS; way++) {
        AVZNativeDirectLink *link = &context->direct_links[base + way];
        if (link->source != source ||
            link->source_serial != source_serial ||
            !avz_native_block_contexts_match(
                &link->target_key,
                key_template
            )) {
            continue;
        }
        AVZNativeBlockKey target_key = *key_template;
        target_key.pc = link->target_key.pc;
        if (avz_native_direct_link_is_current(
                link,
                cache,
                source,
                source_serial,
                &target_key
            ) && (recent == NULL || link->last_used > recent->last_used)) {
            recent = link;
        }
    }
    if (recent != NULL) {
        recent->last_used = avz_native_next_direct_link_clock(context);
    }
    return recent;
}

static void avz_native_record_direct_link(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeDecodedBlock *source,
    const AVZNativeDecodedBlock *target,
    uint64_t source_serial,
    uint64_t target_serial,
    const AVZNativeBlockKey *target_key
) {
    size_t base = avz_native_direct_link_set_base(source, source_serial);
    AVZNativeDirectLink *slot = NULL;
    AVZNativeDirectLink *oldest = &context->direct_links[base];
    for (size_t way = 0; way < AVZ_NATIVE_DIRECT_LINK_WAYS; way++) {
        AVZNativeDirectLink *candidate = &context->direct_links[base + way];
        if (candidate->source == source &&
            candidate->source_serial == source_serial &&
            avz_native_block_keys_match(&candidate->target_key, target_key)) {
            slot = candidate;
            break;
        }
        if (candidate->source == NULL ||
            !avz_native_serial_token_matches(
                candidate->source_serial_token,
                candidate->source_serial
            ) ||
            !avz_native_serial_token_matches(
                candidate->target_serial_token,
                candidate->target_serial
            )) {
            slot = candidate;
            break;
        }
        if (candidate->last_used < oldest->last_used) {
            oldest = candidate;
        }
    }
    if (slot == NULL) {
        slot = oldest;
    }
    *slot = (AVZNativeDirectLink){
        .source = source,
        .target = target,
        .source_serial_token =
            avz_native_decoded_block_serial_token(cache, source),
        .target_serial_token =
            avz_native_decoded_block_serial_token(cache, target),
        .source_serial = source_serial,
        .target_serial = target_serial,
        .target_key = *target_key,
        .code_mutation_epoch =
            avz_native_block_cache_code_mutation_epoch(cache),
        .last_used = avz_native_next_direct_link_clock(context)
    };
}

AVZNativeExecutionContext *avz_native_execution_context_create(void) {
    return calloc(1, sizeof(AVZNativeExecutionContext));
}

void avz_native_execution_context_destroy(AVZNativeExecutionContext *context) {
    if (context == NULL) {
        return;
    }
    for (size_t index = 0; index < AVZ_NATIVE_SUPERBLOCK_COUNT; index++) {
        free(context->superblocks[index].instructions);
    }
    free(context);
}

void avz_native_execution_context_load(
    AVZNativeExecutionContext *context,
    const uint64_t *x31,
    const uint64_t *v32_low,
    const uint64_t *v32_high,
    uint64_t sp,
    uint64_t pc,
    uint64_t pstate,
    uint64_t fpcr,
    uint64_t fpsr,
    uint64_t exclusive_address,
    uint8_t exclusive_size,
    uint8_t exclusive_valid,
    uint8_t halted
) {
    if (context == 0 || x31 == 0) {
        return;
    }
    const uint64_t preserved_generation =
        context->cpu.exclusive_valid != 0 && exclusive_valid != 0 &&
        context->cpu.exclusive_address == exclusive_address &&
        context->cpu.exclusive_size == exclusive_size
            ? context->cpu.exclusive_generation
            : 0;
    copy_registers_to_cpu(
        &context->cpu,
        x31,
        v32_low,
        v32_high,
        sp,
        pc,
        pstate,
        fpcr,
        fpsr,
        exclusive_address,
        exclusive_size,
        exclusive_valid,
        halted
    );
    context->cpu.exclusive_generation = preserved_generation;
    context->last_block = NULL;
    context->last_block_serial = 0;
}

void avz_native_execution_context_store(
    const AVZNativeExecutionContext *context,
    uint64_t *x31,
    uint64_t *v32_low,
    uint64_t *v32_high,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint64_t *fpcr,
    uint64_t *fpsr,
    uint64_t *exclusive_address,
    uint8_t *exclusive_size,
    uint8_t *exclusive_valid,
    uint8_t *halted
) {
    if (context == 0 || x31 == 0 || sp == 0 || pc == 0 ||
        pstate == 0 || halted == 0) {
        return;
    }
    copy_cpu_to_registers(
        &context->cpu,
        x31,
        v32_low,
        v32_high,
        sp,
        pc,
        pstate,
        fpcr,
        fpsr,
        exclusive_address,
        exclusive_size,
        exclusive_valid,
        halted
    );
}

uint64_t avz_native_execution_context_pc(
    const AVZNativeExecutionContext *context
) {
    return context == 0 ? 0 : context->cpu.pc;
}

uint64_t avz_native_execution_context_pstate(
    const AVZNativeExecutionContext *context
) {
    return context == 0 ? 0 : context->cpu.pstate;
}

uint8_t avz_native_execution_context_halted(
    const AVZNativeExecutionContext *context
) {
    return context == 0 ? 0 : context->cpu.halted;
}

size_t avz_native_execution_context_copy_hot_pcs(
    const AVZNativeExecutionContext *context,
    AVZNativeHotPC *entries,
    size_t capacity
) {
    if (context == NULL || entries == NULL || capacity == 0) {
        return 0;
    }

    size_t copied = 0;
    size_t entry_count = AVZ_NATIVE_HOT_PC_SET_COUNT *
        AVZ_NATIVE_HOT_PC_WAYS;
    for (size_t source = 0; source < entry_count; source++) {
        AVZNativeHotPC candidate = context->hot_pcs[source];
        if (candidate.samples == 0) {
            continue;
        }

        size_t insertion = 0;
        while (insertion < copied &&
               entries[insertion].samples >= candidate.samples) {
            insertion++;
        }
        if (insertion >= capacity) {
            continue;
        }
        size_t last = copied < capacity ? copied : capacity - 1;
        while (last > insertion) {
            entries[last] = entries[last - 1];
            last--;
        }
        entries[insertion] = candidate;
        if (copied < capacity) {
            copied++;
        }
    }
    return copied;
}

void avz_native_execution_context_reset_hot_pc_profile(
    AVZNativeExecutionContext *context
) {
    if (context == NULL) {
        return;
    }
    memset(context->hot_pcs, 0, sizeof(context->hot_pcs));
    context->hot_pc_sample_clock = 0;
}

void avz_native_execution_context_set_hot_pc_profiling(
    AVZNativeExecutionContext *context,
    int enabled
) {
    if (context == NULL) {
        return;
    }
    context->hot_pc_profiling_enabled = enabled != 0;
}

static int avz_native_block_is_chain_barrier(
    const AVZNativeDecodedBlock *block
) {
    const AVZNativeInstruction *instructions =
        avz_native_decoded_block_instructions(block);
    size_t count = avz_native_decoded_block_instruction_count(block);
    if (instructions == 0 || count == 0) {
        return 1;
    }
    for (size_t index = 0; index < count; index++) {
        switch (instructions[index].kind) {
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ:
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE:
        case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
        case AVZ_NATIVE_OP_EXCEPTION_RETURN:
        case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
        case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
        case AVZ_NATIVE_OP_WAIT:
        case AVZ_NATIVE_OP_HALT:
            return 1;
        default:
            break;
        }
    }
    return 0;
}

static int avz_native_block_requires_host_checkpoint(
    const AVZNativeDecodedBlock *block
) {
    const AVZNativeInstruction *instructions =
        avz_native_decoded_block_instructions(block);
    size_t count = avz_native_decoded_block_instruction_count(block);
    if (instructions == NULL || count == 0)
        return 1;
    for (size_t index = 0; index < count; index++) {
        switch (instructions[index].kind) {
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_READ:
        case AVZ_NATIVE_OP_EXCEPTION_RETURN:
            break;
        case AVZ_NATIVE_OP_SYNCHRONOUS_EXCEPTION:
            if ((instructions[index].raw & 0xffe0001fu) != 0xd4000001u)
                return 1;
            break;
        case AVZ_NATIVE_OP_SYSTEM_REGISTER_WRITE:
        case AVZ_NATIVE_OP_SYSTEM_INSTRUCTION:
        case AVZ_NATIVE_OP_PSTATE_IMMEDIATE:
        case AVZ_NATIVE_OP_WAIT:
        case AVZ_NATIVE_OP_HALT:
            return 1;
        default:
            break;
        }
    }
    return 0;
}

#if defined(__clang__) || defined(__GNUC__)
__attribute__((always_inline))
#endif
static inline AVZNativeSuperblock *avz_native_validate_superblock(
    AVZNativeSuperblock *superblock,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key,
    uint64_t mutation_epoch,
    uint64_t code_mutation_epoch,
    uint64_t reset_epoch
) {
    if (superblock == NULL || !superblock->valid ||
        !avz_native_block_keys_match(&superblock->key, key)) {
        return NULL;
    }
    if (superblock->count < 2 || superblock->instructions == NULL ||
        superblock->instruction_pcs == NULL) {
        superblock->valid = 0;
        return NULL;
    }
    if (superblock->cache != cache ||
        superblock->reset_epoch != reset_epoch) {
        superblock->valid = 0;
        return NULL;
    }
    for (size_t slot = 0; slot < superblock->count; slot++) {
        if (!avz_native_decoded_block_code_is_current(
                cache,
                superblock->blocks[slot]
            )) {
            superblock->valid = 0;
            return NULL;
        }
    }
    if (superblock->requires_cache_residency &&
        superblock->mutation_epoch != mutation_epoch) {
        for (size_t slot = 0; slot < superblock->count; slot++) {
            if (!avz_native_serial_token_matches(
                    superblock->serial_tokens[slot],
                    superblock->serials[slot]
                )) {
                superblock->valid = 0;
                return NULL;
            }
        }
        superblock->mutation_epoch = mutation_epoch;
    }
    if (superblock->code_mutation_epoch != code_mutation_epoch) {
        for (size_t slot = 0;
             slot < superblock->code_page_count;
             slot++) {
            const uint64_t *token =
                superblock->code_page_generation_tokens[slot];
            if (token == NULL ||
                *token != superblock->code_page_generations[slot]) {
                superblock->valid = 0;
                return NULL;
            }
        }
        superblock->code_mutation_epoch = code_mutation_epoch;
    }
    return superblock;
}

static const AVZNativeSuperblock *avz_native_find_superblock(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key,
    int *front_hit
) {
    if (front_hit != NULL) {
        *front_hit = 0;
    }
    uint64_t mutation_epoch = avz_native_block_cache_mutation_epoch(cache);
    uint64_t code_mutation_epoch =
        avz_native_block_cache_code_mutation_epoch(cache);
    uint64_t reset_epoch = avz_native_block_cache_reset_epoch(cache);
    size_t front_index = avz_native_superblock_front_index(context, key);
    AVZNativeSuperblock *superblock = avz_native_validate_superblock(
        context->superblock_front[front_index],
        cache,
        key,
        mutation_epoch,
        code_mutation_epoch,
        reset_epoch
    );
    if (superblock != NULL) {
        if (front_hit != NULL) {
            *front_hit = 1;
        }
        return superblock;
    }

    size_t base = avz_native_superblock_index(context, key);
    for (size_t way = 0; way < AVZ_NATIVE_SUPERBLOCK_WAYS; way++) {
        superblock = avz_native_validate_superblock(
            &context->superblocks[base + way],
            cache,
            key,
            mutation_epoch,
            code_mutation_epoch,
            reset_epoch
        );
        if (superblock != NULL) {
            context->superblock_front[front_index] = superblock;
            return superblock;
        }
    }
    return NULL;
}

static AVZNativeSuperblock *avz_native_select_superblock_slot(
    AVZNativeExecutionContext *context,
    const AVZNativeBlockKey *key
) {
    size_t base = avz_native_superblock_index(context, key);
    for (size_t way = 0; way < AVZ_NATIVE_SUPERBLOCK_WAYS; way++) {
        AVZNativeSuperblock *candidate = &context->superblocks[base + way];
        if (!candidate->valid ||
            avz_native_block_keys_match(&candidate->key, key)) {
            return candidate;
        }
    }
    size_t set = base / AVZ_NATIVE_SUPERBLOCK_WAYS;
    size_t way = context->superblock_next_victim[set];
    context->superblock_next_victim[set] =
        (uint8_t)((way + 1u) % AVZ_NATIVE_SUPERBLOCK_WAYS);
    return &context->superblocks[base + way];
}

static const AVZNativeSuperblock *avz_native_compose_superblock(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key_template,
    const AVZNativeDecodedBlock *first_block,
    uint64_t first_serial
) {
    if (first_block == NULL || first_serial == 0 ||
        avz_native_block_is_chain_barrier(first_block)) {
        return NULL;
    }

    const AVZNativeDecodedBlock
        *blocks[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS] = {first_block};
    uint64_t serials[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS] = {first_serial};
    uint16_t block_offsets[AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS + 1] = {0};
    const AVZNativeInstruction *first_instructions =
        avz_native_decoded_block_instructions(first_block);
    size_t first_instruction_count =
        avz_native_decoded_block_instruction_count(first_block);
    if (first_instructions == NULL || first_instruction_count == 0 ||
        first_instruction_count > AVZ_NATIVE_SUPERBLOCK_MAX_INSTRUCTIONS) {
        return NULL;
    }
    size_t block_count = 1;
    size_t instruction_count = first_instruction_count;
    block_offsets[1] = (uint16_t)instruction_count;

    const AVZNativeDecodedBlock *source = first_block;
    uint64_t source_serial = first_serial;
    while (block_count < AVZ_NATIVE_SUPERBLOCK_MAX_BLOCKS) {
        AVZNativeDirectLink *link = avz_native_find_recent_direct_link(
            context,
            cache,
            source,
            source_serial,
            key_template
        );
        if (link == NULL) {
            break;
        }
        if (avz_native_block_is_chain_barrier(link->target)) {
            break;
        }
        const AVZNativeInstruction *target_instructions =
            avz_native_decoded_block_instructions(link->target);
        size_t target_instruction_count =
            avz_native_decoded_block_instruction_count(link->target);
        if (target_instructions == NULL || target_instruction_count == 0 ||
            instruction_count + target_instruction_count >
                AVZ_NATIVE_SUPERBLOCK_MAX_INSTRUCTIONS) {
            break;
        }
        blocks[block_count] = link->target;
        serials[block_count] = link->target_serial;
        block_offsets[block_count] = (uint16_t)instruction_count;
        instruction_count += target_instruction_count;
        block_count++;
        block_offsets[block_count] = (uint16_t)instruction_count;
        source = link->target;
        source_serial = link->target_serial;
    }

    uint64_t generation = avz_native_block_cache_generation(cache);
    if (block_count < 2) {
        return NULL;
    }

    size_t instruction_bytes = instruction_count * sizeof(AVZNativeInstruction);
    size_t pc_bytes = instruction_count * sizeof(uint64_t);
    size_t hint_bytes = instruction_count * sizeof(uint8_t);
    AVZNativeInstruction *instructions = malloc(
        instruction_bytes + pc_bytes + hint_bytes
    );
    if (instructions == NULL) {
        return NULL;
    }
    uint64_t *instruction_pcs = (uint64_t *)(
        (unsigned char *)instructions + instruction_bytes
    );
    uint8_t *semantic_hints = (uint8_t *)(instruction_pcs + instruction_count);
    memset(semantic_hints, 0, hint_bytes);
    size_t destination = 0;
    for (size_t slot = 0; slot < block_count; slot++) {
        const AVZNativeInstruction *block_instructions =
            avz_native_decoded_block_instructions(blocks[slot]);
        size_t count = avz_native_decoded_block_instruction_count(blocks[slot]);
        uint64_t pc = avz_native_decoded_block_pc(blocks[slot]);
        for (size_t index = 0; index < count; index++, destination++) {
            instructions[destination] = block_instructions[index];
            instruction_pcs[destination] = pc + index * 4u;
        }
    }
    if (generation != avz_native_block_cache_generation(cache)) {
        free(instructions);
        return NULL;
    }

    const uint64_t
        *code_page_generation_tokens[AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES] = {0};
    uint64_t
        code_page_generations[AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES] = {0};
    uint64_t physical_code_pages[AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES] = {0};
    size_t physical_code_page_count = 0;
    size_t code_page_count = 0;
    int requires_cache_residency = 0;
    for (size_t block_slot = 0; block_slot < block_count; block_slot++) {
        size_t block_page_count =
            avz_native_decoded_block_code_page_count(blocks[block_slot]);
        for (size_t page_slot = 0;
             page_slot < block_page_count;
             page_slot++) {
            uint64_t physical_page =
                avz_native_decoded_block_physical_code_page(
                    blocks[block_slot],
                    page_slot
                );
            int duplicate = 0;
            for (size_t existing = 0;
                 existing < physical_code_page_count;
                 existing++) {
                if (physical_code_pages[existing] == physical_page) {
                    duplicate = 1;
                    break;
                }
            }
            if (duplicate) {
                continue;
            }
            if (physical_code_page_count >=
                AVZ_NATIVE_SUPERBLOCK_MAX_CODE_PAGES) {
                free(instructions);
                return NULL;
            }
            physical_code_pages[physical_code_page_count++] = physical_page;
        }
    }
    for (size_t slot = 0; slot < physical_code_page_count; slot++) {
        const uint64_t *token = NULL;
        uint64_t page_generation = 0;
        if (!avz_native_block_cache_register_trace_code_page(
                cache,
                physical_code_pages[slot],
                &token,
                &page_generation
            )) {
            requires_cache_residency = 1;
            continue;
        }
        code_page_generation_tokens[code_page_count] = token;
        code_page_generations[code_page_count] = page_generation;
        code_page_count++;
    }

    AVZNativeSuperblock *composed =
        avz_native_select_superblock_slot(context, key_template);
    composed->valid = 0;
    free(composed->instructions);
    composed->instructions = instructions;
    composed->instruction_pcs = instruction_pcs;
    composed->semantic_hints = semantic_hints;
    composed->key = *key_template;
    composed->cache = cache;
    composed->reset_epoch = avz_native_block_cache_reset_epoch(cache);
    composed->mutation_epoch = avz_native_block_cache_mutation_epoch(cache);
    composed->code_mutation_epoch =
        avz_native_block_cache_code_mutation_epoch(cache);
    composed->count = (uint8_t)block_count;
    composed->code_page_count = (uint8_t)code_page_count;
    composed->requires_cache_residency =
        (uint8_t)requires_cache_residency;
    composed->instruction_count = (uint16_t)instruction_count;
    for (size_t slot = 0; slot < block_count; slot++) {
        composed->blocks[slot] = blocks[slot];
        composed->serial_tokens[slot] =
            avz_native_decoded_block_serial_token(cache, blocks[slot]);
        composed->serials[slot] = serials[slot];
    }
    for (size_t slot = 0; slot < code_page_count; slot++) {
        composed->code_page_generation_tokens[slot] =
            code_page_generation_tokens[slot];
        composed->code_page_generations[slot] =
            code_page_generations[slot];
    }
    for (size_t slot = 0; slot <= block_count; slot++) {
        composed->block_offsets[slot] = block_offsets[slot];
    }
    composed->valid = 1;
    context->superblock_front[
        avz_native_superblock_front_index(context, key_template)
    ] = composed;
    return composed;
}

AVZNativeChainResult avz_native_execution_context_run_cached_chain(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key_template,
    uint64_t max_steps,
    uint64_t max_blocks,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
) {
    AVZNativeChainResult chain = {
        .steps = 0,
        .blocks = 0,
        .direct_link_hits = 0,
        .direct_link_misses = 0,
        .superblock_hits = 0,
        .superblock_front_hits = 0,
        .superblock_blocks = 0,
        .superblock_dispatches = 0,
        .generic_dispatches = 0,
        .fast_path_steps = 0,
        .fast_path_hits = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .decode_status = AVZ_NATIVE_BLOCK_DECODE_OK,
        .unsupported_instruction = 0
    };
    if (context == 0 || cache == 0 || key_template == 0 ||
        fetch_instruction == 0 || max_steps == 0 || max_blocks == 0) {
        chain.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
        return chain;
    }

    while (chain.steps < max_steps && chain.blocks < max_blocks) {
        if (context->cpu.halted) {
            chain.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }
        AVZNativeBlockKey key = *key_template;
        key.pc = context->cpu.pc;
        key.current_el = (uint8_t)((context->cpu.pstate >> 2) & 0x3u);
        key = avz_native_canonical_block_key(&key);
        uint32_t decode_status = AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT;
        uint32_t unsupported = 0;
        const AVZNativeDecodedBlock *block =
            avz_native_block_cache_get_or_decode(
                cache,
                &key,
                fetch_instruction,
                fetch_context,
                &decode_status,
                &unsupported
            );
        chain.decode_status = decode_status;
        if (block == 0) {
            chain.status = decode_status == AVZ_NATIVE_BLOCK_DECODE_UNSUPPORTED
                ? AVZ_NATIVE_STATUS_UNSUPPORTED
                : AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            chain.unsupported_instruction = unsupported;
            break;
        }

        uint64_t remaining_steps = max_steps - chain.steps;
        AVZNativeBlockResult block_result =
            avz_native_run_threaded_decoded_block_cpu_impl(
                avz_native_decoded_block_instructions(block),
                avz_native_decoded_block_instruction_count(block),
                avz_native_decoded_block_pc(block),
                remaining_steps,
                &context->cpu,
                read_memory,
                write_memory,
                can_access_memory,
                fill_memory,
                read_system_register,
                write_system_register,
                execute_system_instruction,
                exception_return,
                synchronous_exception,
                wait,
                memory_context
            );
        chain.steps += block_result.steps;
        int native_irq_due = avz_native_memory_fast_path_advance_time(
            memory_context, block_result.steps, context->cpu.pstate);
        chain.generic_dispatches += block_result.generic_dispatches;
        chain.fast_path_steps += block_result.fast_path_steps;
        chain.fast_path_hits += block_result.fast_path_hits;
        chain.blocks++;
        chain.status = block_result.status;
        if (native_irq_due &&
            chain.status != AVZ_NATIVE_STATUS_HALTED &&
            chain.status != AVZ_NATIVE_STATUS_UNSUPPORTED)
            chain.status = AVZ_NATIVE_STATUS_YIELDED;
        chain.unsupported_instruction = block_result.unsupported_instruction;

        if (chain.status == AVZ_NATIVE_STATUS_HALTED ||
            chain.status == AVZ_NATIVE_STATUS_UNSUPPORTED ||
            chain.status == AVZ_NATIVE_STATUS_YIELDED ||
            block_result.status == AVZ_NATIVE_STATUS_MAX_STEPS ||
            block_result.steps == 0 ||
            avz_native_block_is_chain_barrier(block)) {
            break;
        }
    }

    if (chain.steps >= max_steps &&
        chain.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
        chain.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    }
    return chain;
}

AVZNativeChainResult avz_native_execution_context_run_cached_chain_checkpointed(
    AVZNativeExecutionContext *context,
    AVZNativeBlockCache *cache,
    const AVZNativeBlockKey *key_template,
    uint64_t initial_block_step_limit,
    uint64_t max_steps,
    uint64_t max_blocks,
    uint64_t checkpoint_block_interval,
    AVZNativeChainCheckpointCallback checkpoint,
    void *checkpoint_context,
    AVZNativeInstructionFetchCallback fetch_instruction,
    void *fetch_context,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    AVZNativeSystemRegisterReadCallback read_system_register,
    AVZNativeSystemRegisterWriteCallback write_system_register,
    AVZNativeSystemInstructionCallback execute_system_instruction,
    AVZNativeExceptionReturnCallback exception_return,
    AVZNativeSynchronousExceptionCallback synchronous_exception,
    AVZNativeWaitCallback wait,
    void *memory_context
) {
    AVZNativeChainResult chain = {
        .steps = 0,
        .blocks = 0,
        .direct_link_hits = 0,
        .direct_link_misses = 0,
        .superblock_hits = 0,
        .superblock_front_hits = 0,
        .superblock_blocks = 0,
        .superblock_dispatches = 0,
        .generic_dispatches = 0,
        .fast_path_steps = 0,
        .fast_path_hits = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .decode_status = AVZ_NATIVE_BLOCK_DECODE_OK,
        .unsupported_instruction = 0
    };
    if (context == 0 || cache == 0 || key_template == 0 ||
        checkpoint == 0 || fetch_instruction == 0 ||
        initial_block_step_limit == 0 || max_steps == 0 ||
        max_blocks == 0 || checkpoint_block_interval == 0) {
        chain.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
        return chain;
    }

    uint64_t block_step_limit = initial_block_step_limit;
    uint64_t checkpoint_steps = 0;
    uint64_t checkpoint_blocks = 0;
    const AVZNativeDecodedBlock *previous_block = context->last_block;
    uint64_t previous_serial = context->last_block_serial;
    const AVZNativeSuperblock *active_superblock = NULL;
    while (chain.steps < max_steps && chain.blocks < max_blocks) {
        if (context->cpu.halted) {
            chain.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }

        AVZNativeBlockKey key = *key_template;
        key.pc = context->cpu.pc;
        key.current_el = (uint8_t)((context->cpu.pstate >> 2) & 0x3u);
        key = avz_native_canonical_block_key(&key);
        uint32_t decode_status = AVZ_NATIVE_BLOCK_DECODE_FETCH_FAULT;
        uint32_t unsupported = 0;
        const AVZNativeDecodedBlock *block = NULL;
        int superblock_front_hit = 0;
        active_superblock = avz_native_find_superblock(
            context,
            cache,
            &key,
            &superblock_front_hit
        );
        if (active_superblock != NULL) {
            decode_status = AVZ_NATIVE_BLOCK_DECODE_OK;
            chain.superblock_hits++;
            chain.superblock_front_hits +=
                (uint64_t)superblock_front_hit;
        }
        if (active_superblock == NULL && block == NULL &&
            previous_block != NULL && previous_serial != 0) {
            AVZNativeDirectLink *link = avz_native_find_direct_link(
                context,
                cache,
                previous_block,
                previous_serial,
                &key
            );
            if (link != NULL) {
                block = link->target;
                decode_status = AVZ_NATIVE_BLOCK_DECODE_OK;
                chain.direct_link_hits++;
            } else {
                chain.direct_link_misses++;
            }
        }
        if (active_superblock == NULL && block == NULL) {
            block = avz_native_block_cache_get_or_decode(
                cache,
                &key,
                fetch_instruction,
                fetch_context,
                &decode_status,
                &unsupported
            );
            if (block != NULL && previous_block != NULL &&
                previous_serial != 0 &&
                avz_native_serial_token_matches(
                    avz_native_decoded_block_serial_token(
                        cache,
                        previous_block
                    ),
                    previous_serial
                ) &&
                avz_native_decoded_block_code_is_current(
                    cache,
                    previous_block
                )) {
                uint64_t target_serial =
                    avz_native_decoded_block_serial(cache, block);
                if (target_serial != 0) {
                    avz_native_record_direct_link(
                        context,
                        cache,
                        previous_block,
                        block,
                        previous_serial,
                        target_serial,
                        &key
                    );
                }
            }
        }
        chain.decode_status = decode_status;
        if (active_superblock == NULL && block == NULL) {
            previous_block = NULL;
            previous_serial = 0;
            chain.status = decode_status == AVZ_NATIVE_BLOCK_DECODE_UNSUPPORTED
                ? AVZ_NATIVE_STATUS_UNSUPPORTED
                : AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            chain.unsupported_instruction = unsupported;
            break;
        }
        if (active_superblock == NULL) {
            uint64_t block_serial =
                avz_native_decoded_block_serial(cache, block);
            const AVZNativeSuperblock *composed =
                avz_native_compose_superblock(
                    context,
                    cache,
                    &key,
                    block,
                    block_serial
                );
            if (composed != NULL) {
                active_superblock = composed;
            }
        }

        int chain_barrier = active_superblock == NULL
            ? avz_native_block_is_chain_barrier(block)
            : 0;
        int host_checkpoint_barrier = active_superblock == NULL
            ? avz_native_block_requires_host_checkpoint(block)
            : 0;
        if (host_checkpoint_barrier && checkpoint_steps != 0) {
            uint64_t remaining_steps = max_steps - chain.steps;
            block_step_limit = checkpoint(
                checkpoint_context,
                checkpoint_steps,
                checkpoint_blocks,
                chain.steps,
                context->cpu.pc,
                context->cpu.pstate,
                remaining_steps
            );
            checkpoint_steps = 0;
            checkpoint_blocks = 0;
            if (block_step_limit == 0) {
                break;
            }
        }

        uint64_t remaining_steps = max_steps - chain.steps;
        uint64_t checkpoint_remaining =
            block_step_limit > checkpoint_steps
                ? block_step_limit - checkpoint_steps
                : 0;
        if (checkpoint_remaining == 0) {
            block_step_limit = checkpoint(
                checkpoint_context,
                checkpoint_steps,
                checkpoint_blocks,
                chain.steps,
                context->cpu.pc,
                context->cpu.pstate,
                remaining_steps
            );
            checkpoint_steps = 0;
            checkpoint_blocks = 0;
            if (block_step_limit == 0) {
                break;
            }
            checkpoint_remaining = block_step_limit;
        }
        uint64_t requested_steps = checkpoint_remaining < remaining_steps
            ? checkpoint_remaining
            : remaining_steps;
        uint64_t executed_blocks = 1;
        uint64_t fused_block_limit = 0;
        AVZNativeBlockResult block_result;
        if (active_superblock != NULL && active_superblock->count >= 2) {
            fused_block_limit = active_superblock->count;
            uint64_t block_budget = max_blocks - chain.blocks;
            if (fused_block_limit > block_budget) {
                fused_block_limit = block_budget;
            }
            uint64_t checkpoint_block_budget =
                checkpoint_block_interval > checkpoint_blocks
                    ? checkpoint_block_interval - checkpoint_blocks
                    : 1;
            if (fused_block_limit > checkpoint_block_budget) {
                fused_block_limit = checkpoint_block_budget;
            }
            uint16_t fused_instruction_count =
                active_superblock->block_offsets[fused_block_limit];
            block_result = avz_native_run_threaded_decoded_block_cpu_mapped(
                active_superblock->instructions,
                fused_instruction_count,
                active_superblock->instruction_pcs[0],
                requested_steps,
                &context->cpu,
                read_memory,
                write_memory,
                can_access_memory,
                fill_memory,
                read_system_register,
                write_system_register,
                execute_system_instruction,
                exception_return,
                synchronous_exception,
                wait,
                memory_context,
                active_superblock->semantic_hints,
                active_superblock->instruction_pcs,
                active_superblock->block_offsets,
                fused_block_limit,
                cache,
                active_superblock->code_mutation_epoch
            );
            chain.superblock_dispatches++;
            executed_blocks = 0;
            for (uint64_t slot = 0; slot < fused_block_limit; slot++) {
                if (active_superblock->block_offsets[slot] >=
                    block_result.steps) {
                    break;
                }
                avz_native_sample_hot_pc(
                    context,
                    active_superblock->instruction_pcs[
                        active_superblock->block_offsets[slot]
                    ],
                    &active_superblock->instructions[
                        active_superblock->block_offsets[slot]
                    ],
                    (size_t)(
                        active_superblock->block_offsets[slot + 1] -
                        active_superblock->block_offsets[slot]
                    )
                );
                executed_blocks++;
            }
            chain.superblock_blocks += executed_blocks;
        } else {
            block_result = avz_native_run_threaded_decoded_block_cpu_impl(
                avz_native_decoded_block_instructions(block),
                avz_native_decoded_block_instruction_count(block),
                avz_native_decoded_block_pc(block),
                requested_steps,
                &context->cpu,
                read_memory,
                write_memory,
                can_access_memory,
                fill_memory,
                read_system_register,
                write_system_register,
                execute_system_instruction,
                exception_return,
                synchronous_exception,
                wait,
                memory_context
            );
            avz_native_sample_hot_pc(
                context,
                avz_native_decoded_block_pc(block),
                avz_native_decoded_block_instructions(block),
                avz_native_decoded_block_instruction_count(block)
            );
        }
        chain.steps += block_result.steps;
        int native_irq_due = avz_native_memory_fast_path_advance_time(
            memory_context, block_result.steps, context->cpu.pstate);
        chain.generic_dispatches += block_result.generic_dispatches;
        chain.fast_path_steps += block_result.fast_path_steps;
        chain.fast_path_hits += block_result.fast_path_hits;
        chain.blocks += executed_blocks;
        chain.status = block_result.status;
        if (native_irq_due &&
            chain.status != AVZ_NATIVE_STATUS_HALTED &&
            chain.status != AVZ_NATIVE_STATUS_UNSUPPORTED)
            chain.status = AVZ_NATIVE_STATUS_YIELDED;
        chain.unsupported_instruction = block_result.unsupported_instruction;
        checkpoint_steps += block_result.steps;
        checkpoint_blocks += executed_blocks;
        if (fused_block_limit != 0 && executed_blocks != 0) {
            size_t last_slot = (size_t)(executed_blocks - 1);
            const uint64_t *serial_token =
                active_superblock->serial_tokens[last_slot];
            uint64_t block_serial = active_superblock->serials[last_slot];
            if (avz_native_serial_token_matches(
                    serial_token,
                    block_serial
                )) {
                previous_block = active_superblock->blocks[last_slot];
                previous_serial = block_serial;
            } else {
                previous_block = NULL;
                previous_serial = 0;
            }
        } else if (fused_block_limit != 0) {
            previous_block = NULL;
            previous_serial = 0;
        } else {
            uint64_t block_serial =
                avz_native_decoded_block_serial(cache, block);
            previous_block = block_serial != 0 ? block : NULL;
            previous_serial = block_serial;
        }
        if (chain_barrier) {
            previous_block = NULL;
            previous_serial = 0;
        }
        active_superblock = NULL;

        remaining_steps = max_steps - chain.steps;
        int must_checkpoint =
            checkpoint_steps >= block_step_limit ||
            checkpoint_blocks >= checkpoint_block_interval ||
            chain.status == AVZ_NATIVE_STATUS_HALTED ||
            chain.status == AVZ_NATIVE_STATUS_UNSUPPORTED ||
            chain.status == AVZ_NATIVE_STATUS_YIELDED ||
            block_result.steps == 0 ||
            chain.steps >= max_steps ||
            host_checkpoint_barrier;
        if (must_checkpoint) {
            block_step_limit = checkpoint(
                checkpoint_context,
                checkpoint_steps,
                checkpoint_blocks,
                chain.steps,
                context->cpu.pc,
                context->cpu.pstate,
                remaining_steps
            );
            checkpoint_steps = 0;
            checkpoint_blocks = 0;
        }

        if (chain.status == AVZ_NATIVE_STATUS_HALTED ||
            chain.status == AVZ_NATIVE_STATUS_UNSUPPORTED ||
            chain.status == AVZ_NATIVE_STATUS_YIELDED ||
            block_result.steps == 0 ||
            (must_checkpoint && block_step_limit == 0) ||
            chain.steps >= max_steps ||
            (block_result.status != AVZ_NATIVE_STATUS_MAX_STEPS &&
             host_checkpoint_barrier)) {
            break;
        }
    }

    if (checkpoint_steps != 0) {
        (void)checkpoint(
            checkpoint_context,
            checkpoint_steps,
            checkpoint_blocks,
            chain.steps,
            context->cpu.pc,
            context->cpu.pstate,
            max_steps - chain.steps
        );
    }
    context->last_block = previous_block;
    context->last_block_serial = previous_serial;
    if (chain.steps >= max_steps &&
        chain.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
        chain.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    }
    return chain;
}

AVZNativeBlockResult avz_native_run_threaded_decoded_block_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
) {
    return avz_native_run_threaded_decoded_block_full_registers(
        instructions,
        instruction_count,
        base_pc,
        max_steps,
        x31,
        0,
        0,
        sp,
        pc,
        pstate,
        0,
        0,
        halted,
        read_memory,
        write_memory,
        can_access_memory,
        fill_memory,
        memory_context
    );
}

AVZNativeBlockResult avz_native_run_decoded_block_registers(
    const AVZNativeInstruction *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted,
    AVZNativeMemoryReadCallback read_memory,
    AVZNativeMemoryWriteCallback write_memory,
    AVZNativeMemoryCanAccessCallback can_access_memory,
    AVZNativeMemoryFillCallback fill_memory,
    void *memory_context
) {
    AVZNativeBlockResult result = {
        .steps = 0,
        .generic_dispatches = 0,
        .status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK,
        .unsupported_instruction = 0
    };
    AVZNativeCPU cpu;
    for (size_t index = 0; index < 31; index++) {
        cpu.x[index] = x31[index];
    }
    for (size_t index = 0; index < 32; index++) {
        cpu.v[index] = (AVZNativeVectorRegister){0, 0};
    }
    cpu.sp = *sp;
    cpu.pc = *pc;
    cpu.pstate = *pstate;
    cpu.fpcr = 0;
    cpu.fpsr = 0;
    cpu.exclusive_address = 0;
    cpu.exclusive_generation = 0;
    cpu.exclusive_size = 0;
    cpu.exclusive_valid = 0;
    cpu.halted = *halted;

    while (result.steps < max_steps) {
        if (cpu.halted) {
            result.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }
        if (cpu.pc < base_pc || ((cpu.pc - base_pc) & 3) != 0) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            break;
        }
        uint64_t index64 = (cpu.pc - base_pc) >> 2;
        if (index64 >= instruction_count) {
            result.status = AVZ_NATIVE_STATUS_OUTSIDE_BLOCK;
            break;
        }

        const AVZNativeInstruction *instruction = &instructions[index64];
        uint64_t fast_steps = 0;
        if (try_execute_store_pair_fill_loop(
            instructions,
            instruction_count,
            base_pc,
            max_steps - result.steps,
            &cpu,
            fill_memory,
            memory_context,
            &fast_steps
        )) {
            result.steps += fast_steps;
            result.fast_path_steps += fast_steps;
            result.fast_path_hits++;
            continue;
        }

        if (!execute_decoded_instruction(
            instruction,
            &cpu,
            read_memory,
            write_memory,
            can_access_memory,
            0,
            0,
            0,
            0,
            0,
            0,
            memory_context
        )) {
            result.status = AVZ_NATIVE_STATUS_UNSUPPORTED;
            result.unsupported_instruction = instruction->raw;
            break;
        }

        result.steps++;
        if (cpu.halted) {
            result.status = AVZ_NATIVE_STATUS_HALTED;
            break;
        }
    }

    if (result.steps >= max_steps && result.status == AVZ_NATIVE_STATUS_OUTSIDE_BLOCK) {
        result.status = AVZ_NATIVE_STATUS_MAX_STEPS;
    }

    for (size_t index = 0; index < 31; index++) {
        x31[index] = cpu.x[index];
    }
    *sp = cpu.sp;
    *pc = cpu.pc;
    *pstate = cpu.pstate;
    *halted = cpu.halted;
    return result;
}

AVZNativeBlockResult avz_native_run_block_registers(
    const uint32_t *instructions,
    size_t instruction_count,
    uint64_t base_pc,
    uint64_t max_steps,
    uint64_t *x31,
    uint64_t *sp,
    uint64_t *pc,
    uint64_t *pstate,
    uint8_t *halted
) {
    AVZNativeCPU cpu;
    for (size_t index = 0; index < 31; index++) {
        cpu.x[index] = x31[index];
    }
    cpu.sp = *sp;
    cpu.pc = *pc;
    cpu.pstate = *pstate;
    cpu.fpcr = 0;
    cpu.fpsr = 0;
    cpu.exclusive_address = 0;
    cpu.exclusive_generation = 0;
    cpu.exclusive_size = 0;
    cpu.exclusive_valid = 0;
    cpu.halted = *halted;

    AVZNativeBlockResult result = avz_native_run_block(
        instructions,
        instruction_count,
        base_pc,
        max_steps,
        &cpu
    );

    for (size_t index = 0; index < 31; index++) {
        x31[index] = cpu.x[index];
    }
    *sp = cpu.sp;
    *pc = cpu.pc;
    *pstate = cpu.pstate;
    *halted = cpu.halted;
    return result;
}
