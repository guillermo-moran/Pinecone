#include "ARM64VizNative.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define AVZ_FRAMEBUFFER_HAS_NEON 1
#else
#define AVZ_FRAMEBUFFER_HAS_NEON 0
#endif

enum {
    AVZ_GPU_FORMAT_B8G8R8A8_UNORM = 1,
    AVZ_GPU_FORMAT_B8G8R8X8_UNORM = 2,
    AVZ_GPU_FORMAT_A8R8G8B8_UNORM = 3,
    AVZ_GPU_FORMAT_X8R8G8B8_UNORM = 4,
    AVZ_GPU_FORMAT_R8G8B8A8_UNORM = 67,
    AVZ_GPU_FORMAT_X8B8G8R8_UNORM = 68,
    AVZ_GPU_FORMAT_A8B8G8R8_UNORM = 121,
    AVZ_GPU_FORMAT_R8G8B8X8_UNORM = 134
};

struct AVZFramebufferSurface {
    uint8_t *bytes;
    size_t byte_count;
    size_t allocation_size;
};

AVZFramebufferSurface *avz_framebuffer_surface_create(size_t byte_count) {
    if (byte_count == 0) {
        return NULL;
    }
    long page_size_value = sysconf(_SC_PAGESIZE);
    size_t page_size = page_size_value > 0 ? (size_t)page_size_value : 4096u;
    if (byte_count > SIZE_MAX - (page_size - 1u)) {
        return NULL;
    }
    size_t allocation_size =
        ((byte_count + page_size - 1u) / page_size) * page_size;
    AVZFramebufferSurface *surface = calloc(1, sizeof(*surface));
    if (surface == NULL) {
        return NULL;
    }
    void *allocation = NULL;
    if (posix_memalign(&allocation, page_size, allocation_size) != 0) {
        free(surface);
        return NULL;
    }
    memset(allocation, 0, allocation_size);
    surface->bytes = allocation;
    surface->byte_count = byte_count;
    surface->allocation_size = allocation_size;
    return surface;
}

void avz_framebuffer_surface_destroy(AVZFramebufferSurface *surface) {
    if (surface == NULL) {
        return;
    }
    free(surface->bytes);
    free(surface);
}

uint8_t *avz_framebuffer_surface_bytes(AVZFramebufferSurface *surface) {
    return surface != NULL ? surface->bytes : NULL;
}

size_t avz_framebuffer_surface_byte_count(const AVZFramebufferSurface *surface) {
    return surface != NULL ? surface->byte_count : 0;
}

size_t avz_framebuffer_surface_allocation_size(
    const AVZFramebufferSurface *surface
) {
    return surface != NULL ? surface->allocation_size : 0;
}

void avz_framebuffer_surface_clear(AVZFramebufferSurface *surface) {
    if (surface != NULL) {
        memset(surface->bytes, 0, surface->allocation_size);
    }
}

static int avz_framebuffer_layout_is_valid(
    size_t stride,
    size_t width,
    size_t height
) {
    if (width == 0 || height == 0 || width > SIZE_MAX / 4) {
        return 0;
    }
    return stride >= width * 4 && height <= SIZE_MAX / stride;
}

static void avz_framebuffer_copy_rectangle(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
);

int avz_framebuffer_normalize_bgra8(
    uint8_t *pixels,
    size_t stride,
    size_t width,
    size_t height,
    uint32_t format
) {
    if (pixels == NULL ||
        !avz_framebuffer_layout_is_valid(stride, width, height)) {
        return 0;
    }

    if (format == AVZ_GPU_FORMAT_B8G8R8A8_UNORM) {
        return 1;
    }

    for (size_t y = 0; y < height; y++) {
        uint8_t *row = pixels + y * stride;
        size_t x = 0;
#if AVZ_FRAMEBUFFER_HAS_NEON
        for (; x + 16u <= width; x += 16u) {
            uint8x16x4_t input = vld4q_u8(row + x * 4u);
            uint8x16x4_t output;
            switch (format) {
            case AVZ_GPU_FORMAT_B8G8R8X8_UNORM:
                output = input;
                output.val[3] = vdupq_n_u8(UINT8_MAX);
                break;
            case AVZ_GPU_FORMAT_A8R8G8B8_UNORM:
                output.val[0] = input.val[3];
                output.val[1] = input.val[2];
                output.val[2] = input.val[1];
                output.val[3] = input.val[0];
                break;
            case AVZ_GPU_FORMAT_X8R8G8B8_UNORM:
                output.val[0] = input.val[3];
                output.val[1] = input.val[2];
                output.val[2] = input.val[1];
                output.val[3] = vdupq_n_u8(UINT8_MAX);
                break;
            case AVZ_GPU_FORMAT_R8G8B8A8_UNORM:
                output.val[0] = input.val[2];
                output.val[1] = input.val[1];
                output.val[2] = input.val[0];
                output.val[3] = input.val[3];
                break;
            case AVZ_GPU_FORMAT_X8B8G8R8_UNORM:
                output.val[0] = input.val[1];
                output.val[1] = input.val[2];
                output.val[2] = input.val[3];
                output.val[3] = vdupq_n_u8(UINT8_MAX);
                break;
            case AVZ_GPU_FORMAT_A8B8G8R8_UNORM:
                output.val[0] = input.val[1];
                output.val[1] = input.val[2];
                output.val[2] = input.val[3];
                output.val[3] = input.val[0];
                break;
            case AVZ_GPU_FORMAT_R8G8B8X8_UNORM:
                output.val[0] = input.val[2];
                output.val[1] = input.val[1];
                output.val[2] = input.val[0];
                output.val[3] = vdupq_n_u8(UINT8_MAX);
                break;
            default:
                return 0;
            }
            vst4q_u8(row + x * 4u, output);
        }
#endif
        for (; x < width; x++) {
            uint8_t *pixel = row + x * 4;
            const uint8_t c0 = pixel[0];
            const uint8_t c1 = pixel[1];
            const uint8_t c2 = pixel[2];
            const uint8_t c3 = pixel[3];

            switch (format) {
            case AVZ_GPU_FORMAT_B8G8R8X8_UNORM:
                pixel[3] = UINT8_MAX;
                break;
            case AVZ_GPU_FORMAT_A8R8G8B8_UNORM:
                pixel[0] = c3;
                pixel[1] = c2;
                pixel[2] = c1;
                pixel[3] = c0;
                break;
            case AVZ_GPU_FORMAT_X8R8G8B8_UNORM:
                pixel[0] = c3;
                pixel[1] = c2;
                pixel[2] = c1;
                pixel[3] = UINT8_MAX;
                break;
            case AVZ_GPU_FORMAT_R8G8B8A8_UNORM:
                pixel[0] = c2;
                pixel[1] = c1;
                pixel[2] = c0;
                break;
            case AVZ_GPU_FORMAT_X8B8G8R8_UNORM:
                pixel[0] = c1;
                pixel[1] = c2;
                pixel[2] = c3;
                pixel[3] = UINT8_MAX;
                break;
            case AVZ_GPU_FORMAT_A8B8G8R8_UNORM:
                pixel[0] = c1;
                pixel[1] = c2;
                pixel[2] = c3;
                pixel[3] = c0;
                break;
            case AVZ_GPU_FORMAT_R8G8B8X8_UNORM:
                pixel[0] = c2;
                pixel[1] = c1;
                pixel[2] = c0;
                pixel[3] = UINT8_MAX;
                break;
            default:
                return 0;
            }
        }
    }
    return 1;
}

int avz_framebuffer_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
) {
    if (source == NULL || destination == NULL || width == 0 || height == 0 ||
        source_x > SIZE_MAX - width || destination_x > SIZE_MAX - width ||
        source_y > SIZE_MAX - height || destination_y > SIZE_MAX - height ||
        source_x + width > source_stride / 4u ||
        destination_x + width > destination_stride / 4u) {
        return 0;
    }
    avz_framebuffer_copy_rectangle(
        source,
        source_stride,
        source_x,
        source_y,
        destination,
        destination_stride,
        destination_x,
        destination_y,
        width,
        height
    );
    return 1;
}

int avz_framebuffer_fill_bgra8(
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    uint32_t premultiplied_bgra
) {
    if (destination == NULL || width == 0 || height == 0 ||
        destination_x > SIZE_MAX - width || destination_y > SIZE_MAX - height ||
        destination_x + width > destination_stride / 4u) {
        return 0;
    }

    for (size_t y = 0; y < height; y++) {
        uint32_t *row = (uint32_t *)(destination +
            (destination_y + y) * destination_stride) + destination_x;
        size_t x = 0;
#if AVZ_FRAMEBUFFER_HAS_NEON
        const uint32x4_t pixels = vdupq_n_u32(premultiplied_bgra);
        for (; x + 4u <= width; x += 4u) {
            vst1q_u32(row + x, pixels);
        }
#endif
        for (; x < width; x++) {
            row[x] = premultiplied_bgra;
        }
    }
    return 1;
}

int avz_framebuffer_fill_over_bgra8(
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    uint32_t premultiplied_bgra
) {
    if (destination == NULL || width == 0 || height == 0 ||
        destination_x > SIZE_MAX - width || destination_y > SIZE_MAX - height ||
        destination_x + width > destination_stride / 4u) {
        return 0;
    }
    const uint32_t alpha = premultiplied_bgra >> 24;
    if (alpha == UINT8_MAX) {
        return avz_framebuffer_fill_bgra8(
            destination, destination_stride, destination_x, destination_y,
            width, height, premultiplied_bgra
        );
    }
    const uint32_t inverse_alpha = UINT8_MAX - alpha;
    for (size_t y = 0; y < height; y++) {
        uint8_t *row = destination + (destination_y + y) * destination_stride +
            destination_x * 4u;
        for (size_t x = 0; x < width; x++) {
            uint8_t *pixel = row + x * 4u;
            for (size_t channel = 0; channel < 4u; channel++) {
                uint32_t product = (uint32_t)pixel[channel] * inverse_alpha;
                product += 128u;
                product += product >> 8u;
                uint32_t value = ((premultiplied_bgra >> (channel * 8u)) &
                    UINT8_MAX) + (product >> 8u);
                pixel[channel] = (uint8_t)(value > UINT8_MAX ? UINT8_MAX : value);
            }
        }
    }
    return 1;
}

#if AVZ_FRAMEBUFFER_HAS_NEON
static uint8x8_t avz_framebuffer_divide_255_round(uint16x8_t value) {
    value = vaddq_u16(value, vdupq_n_u16(128u));
    value = vaddq_u16(value, vshrq_n_u16(value, 8));
    return vmovn_u16(vshrq_n_u16(value, 8));
}
#endif

int avz_framebuffer_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
) {
    if (source == NULL || destination == NULL || width == 0 || height == 0 ||
        source_x > SIZE_MAX - width || destination_x > SIZE_MAX - width ||
        source_y > SIZE_MAX - height || destination_y > SIZE_MAX - height ||
        source_x + width > source_stride / 4u ||
        destination_x + width > destination_stride / 4u) {
        return 0;
    }

    for (size_t row = 0; row < height; row++) {
        const uint8_t *source_row = source + (source_y + row) * source_stride +
            source_x * 4u;
        uint8_t *destination_row = destination +
            (destination_y + row) * destination_stride + destination_x * 4u;
        size_t column = 0;
#if AVZ_FRAMEBUFFER_HAS_NEON
        for (; column + 8u <= width; column += 8u) {
            uint8x8x4_t foreground = vld4_u8(source_row + column * 4u);
            uint8x8x4_t background = vld4_u8(destination_row + column * 4u);
            uint8x8_t alpha = foreground.val[3];
            uint8x8_t inverse_alpha = vsub_u8(vdup_n_u8(UINT8_MAX), alpha);
            uint8x8x4_t output;
            for (unsigned component = 0; component < 4; component++) {
                uint16x8_t scaled_background = vmull_u8(
                    background.val[component],
                    inverse_alpha
                );
                output.val[component] = vqadd_u8(
                    foreground.val[component],
                    avz_framebuffer_divide_255_round(scaled_background)
                );
            }
            vst4_u8(destination_row + column * 4u, output);
        }
#endif
        for (; column < width; column++) {
            const uint8_t *foreground = source_row + column * 4u;
            uint8_t *background = destination_row + column * 4u;
            unsigned alpha = foreground[3];
            unsigned inverse_alpha = UINT8_MAX - alpha;
            for (unsigned component = 0; component < 4; component++) {
                unsigned product = background[component] * inverse_alpha;
                product += 128u;
                product += product >> 8u;
                unsigned value = foreground[component] + (product >> 8u);
                background[component] = (uint8_t)(
                    value > UINT8_MAX ? UINT8_MAX : value
                );
            }
        }
    }
    return 1;
}

static size_t avz_framebuffer_scaled_coordinate(
    size_t position,
    size_t source_extent,
    size_t destination_extent
) {
    /* Sample the nearest source pixel at destination-pixel centers. */
    const size_t quotient = source_extent / destination_extent;
    const size_t remainder = source_extent % destination_extent;
    return position * quotient +
        ((position * remainder + remainder / 2u) / destination_extent);
}

static int avz_framebuffer_scale_parameters_are_valid(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
) {
    return source != NULL && destination != NULL &&
        source_width != 0 && source_height != 0 &&
        destination_width != 0 && destination_height != 0 &&
        source_x <= SIZE_MAX - source_width &&
        source_y <= SIZE_MAX - source_height &&
        destination_x <= SIZE_MAX - destination_width &&
        destination_y <= SIZE_MAX - destination_height &&
        source_x + source_width <= source_stride / 4u &&
        destination_x + destination_width <= destination_stride / 4u;
}

int avz_framebuffer_scale_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
) {
    if (!avz_framebuffer_scale_parameters_are_valid(
            source, source_stride, source_x, source_y,
            source_width, source_height, destination, destination_stride,
            destination_x, destination_y,
            destination_width, destination_height)) {
        return 0;
    }

    for (size_t y = 0; y < destination_height; y++) {
        const size_t sampled_y = source_y + avz_framebuffer_scaled_coordinate(
            y, source_height, destination_height);
        const uint32_t *source_row = (const uint32_t *)(
            source + sampled_y * source_stride);
        uint32_t *destination_row = (uint32_t *)(
            destination + (destination_y + y) * destination_stride);
        for (size_t x = 0; x < destination_width; x++) {
            const size_t sampled_x = source_x + avz_framebuffer_scaled_coordinate(
                x, source_width, destination_width);
            destination_row[destination_x + x] = source_row[sampled_x];
        }
    }
    return 1;
}

int avz_framebuffer_scale_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
) {
    if (!avz_framebuffer_scale_parameters_are_valid(
            source, source_stride, source_x, source_y,
            source_width, source_height, destination, destination_stride,
            destination_x, destination_y,
            destination_width, destination_height)) {
        return 0;
    }

    for (size_t y = 0; y < destination_height; y++) {
        const size_t sampled_y = source_y + avz_framebuffer_scaled_coordinate(
            y, source_height, destination_height);
        const uint8_t *source_row = source + sampled_y * source_stride;
        uint8_t *destination_row = destination +
            (destination_y + y) * destination_stride;
        for (size_t x = 0; x < destination_width; x++) {
            const size_t sampled_x = source_x + avz_framebuffer_scaled_coordinate(
                x, source_width, destination_width);
            const uint8_t *source_pixel = source_row + sampled_x * 4u;
            uint8_t *destination_pixel = destination_row +
                (destination_x + x) * 4u;
            const uint16_t inverse_alpha = (uint16_t)(255u - source_pixel[3]);
            for (size_t channel = 0; channel < 4u; channel++) {
                uint16_t product = (uint16_t)destination_pixel[channel] *
                    inverse_alpha;
                product = (uint16_t)(product + 128u);
                uint16_t blended = (uint16_t)source_pixel[channel] +
                    ((product + (product >> 8u)) >> 8u);
                destination_pixel[channel] = blended > 255u
                    ? 255u
                    : (uint8_t)blended;
            }
        }
    }
    return 1;
}

static uint64_t avz_framebuffer_bilinear_position(
    size_t output_position,
    size_t source_extent,
    size_t destination_extent
) {
    uint64_t position = (((uint64_t)output_position * 2u + 1u) *
        source_extent << 15u) / destination_extent;
    if (position <= (1u << 15u)) {
        return 0;
    }
    position -= 1u << 15u;
    const uint64_t maximum = (uint64_t)(source_extent - 1u) << 16u;
    return position < maximum ? position : maximum;
}

static void avz_framebuffer_bilinear_sample_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    size_t output_x,
    size_t output_y,
    size_t output_width,
    size_t output_height,
    uint8_t sampled[4]
) {
    const uint64_t fixed_x = avz_framebuffer_bilinear_position(
        output_x, source_width, output_width);
    const uint64_t fixed_y = avz_framebuffer_bilinear_position(
        output_y, source_height, output_height);
    const size_t left = source_x + (size_t)(fixed_x >> 16u);
    const size_t top = source_y + (size_t)(fixed_y >> 16u);
    const size_t right = left + ((fixed_x >> 16u) + 1u < source_width);
    const size_t bottom = top + ((fixed_y >> 16u) + 1u < source_height);
    const uint32_t fraction_x = (uint32_t)fixed_x & 0xffffu;
    const uint32_t fraction_y = (uint32_t)fixed_y & 0xffffu;
    const uint32_t inverse_x = 0x10000u - fraction_x;
    const uint32_t inverse_y = 0x10000u - fraction_y;
    const uint8_t *top_left = source + top * source_stride + left * 4u;
    const uint8_t *top_right = source + top * source_stride + right * 4u;
    const uint8_t *bottom_left = source + bottom * source_stride + left * 4u;
    const uint8_t *bottom_right = source + bottom * source_stride + right * 4u;
    for (size_t channel = 0; channel < 4u; channel++) {
        const uint64_t upper = (uint64_t)top_left[channel] * inverse_x +
            (uint64_t)top_right[channel] * fraction_x;
        const uint64_t lower = (uint64_t)bottom_left[channel] * inverse_x +
            (uint64_t)bottom_right[channel] * fraction_x;
        sampled[channel] = (uint8_t)((upper * inverse_y +
            lower * fraction_y + (UINT64_C(1) << 31u)) >> 32u);
    }
}

int avz_framebuffer_bilinear_scale_copy_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
) {
    if (!avz_framebuffer_scale_parameters_are_valid(
            source, source_stride, source_x, source_y,
            source_width, source_height, destination, destination_stride,
            destination_x, destination_y,
            destination_width, destination_height)) {
        return 0;
    }
    for (size_t y = 0; y < destination_height; y++) {
        uint8_t *destination_row = destination +
            (destination_y + y) * destination_stride;
        for (size_t x = 0; x < destination_width; x++) {
            uint8_t sampled[4];
            avz_framebuffer_bilinear_sample_bgra8(
                source, source_stride, source_x, source_y,
                source_width, source_height, x, y,
                destination_width, destination_height, sampled);
            memcpy(destination_row + (destination_x + x) * 4u, sampled, 4u);
        }
    }
    return 1;
}

int avz_framebuffer_bilinear_scale_source_over_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height
) {
    if (!avz_framebuffer_scale_parameters_are_valid(
            source, source_stride, source_x, source_y,
            source_width, source_height, destination, destination_stride,
            destination_x, destination_y,
            destination_width, destination_height)) {
        return 0;
    }
    for (size_t y = 0; y < destination_height; y++) {
        uint8_t *destination_row = destination +
            (destination_y + y) * destination_stride;
        for (size_t x = 0; x < destination_width; x++) {
            uint8_t sampled[4];
            avz_framebuffer_bilinear_sample_bgra8(
                source, source_stride, source_x, source_y,
                source_width, source_height, x, y,
                destination_width, destination_height, sampled);
            uint8_t *destination_pixel = destination_row +
                (destination_x + x) * 4u;
            const uint16_t inverse_alpha = (uint16_t)(255u - sampled[3]);
            for (size_t channel = 0; channel < 4u; channel++) {
                uint16_t product = (uint16_t)destination_pixel[channel] *
                    inverse_alpha;
                product = (uint16_t)(product + 128u);
                uint16_t blended = (uint16_t)sampled[channel] +
                    ((product + (product >> 8u)) >> 8u);
                destination_pixel[channel] = blended > 255u
                    ? 255u
                    : (uint8_t)blended;
            }
        }
    }
    return 1;
}

static uint8_t avz_framebuffer_multiply_255(uint8_t value, uint8_t alpha) {
    uint32_t product = (uint32_t)value * alpha + 128u;
    return (uint8_t)((product + (product >> 8u)) >> 8u);
}

int avz_framebuffer_masked_composite_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    const uint8_t *mask,
    size_t mask_stride,
    uint8_t solid_mask_alpha,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height,
    uint32_t premultiplied_bgra,
    uint32_t operation,
    int bilinear_filtering
) {
    const int is_fill = operation == 3u || operation == 4u;
    const int is_over = operation == 2u || operation == 4u;
    if (destination == NULL || destination_width == 0 ||
        destination_height == 0 || (!is_fill && source == NULL) ||
        (operation < 1u || operation > 4u) ||
        destination_x > SIZE_MAX - destination_width ||
        destination_y > SIZE_MAX - destination_height ||
        destination_x + destination_width > destination_stride / 4u ||
        (mask != NULL && mask_stride / 4u < destination_width) ||
        (!is_fill && !avz_framebuffer_scale_parameters_are_valid(
            source, source_stride, source_x, source_y,
            source_width, source_height, destination, destination_stride,
            destination_x, destination_y,
            destination_width, destination_height))) {
        return 0;
    }

    const uint8_t fill[4] = {
        (uint8_t)premultiplied_bgra,
        (uint8_t)(premultiplied_bgra >> 8u),
        (uint8_t)(premultiplied_bgra >> 16u),
        (uint8_t)(premultiplied_bgra >> 24u)
    };
    for (size_t y = 0; y < destination_height; y++) {
        uint8_t *destination_row = destination +
            (destination_y + y) * destination_stride + destination_x * 4u;
        const uint8_t *mask_row = mask != NULL ? mask + y * mask_stride : NULL;
        for (size_t x = 0; x < destination_width; x++) {
            uint8_t sampled[4];
            if (is_fill) {
                memcpy(sampled, fill, sizeof(sampled));
            } else if (bilinear_filtering) {
                avz_framebuffer_bilinear_sample_bgra8(
                    source, source_stride, source_x, source_y,
                    source_width, source_height, x, y,
                    destination_width, destination_height, sampled);
            } else {
                const size_t sampled_x = source_x +
                    avz_framebuffer_scaled_coordinate(
                        x, source_width, destination_width);
                const size_t sampled_y = source_y +
                    avz_framebuffer_scaled_coordinate(
                        y, source_height, destination_height);
                memcpy(sampled,
                    source + sampled_y * source_stride + sampled_x * 4u,
                    sizeof(sampled));
            }

            const uint8_t alpha = mask_row != NULL
                ? mask_row[x * 4u + 3u]
                : solid_mask_alpha;
            for (size_t channel = 0; channel < 4u; channel++)
                sampled[channel] = avz_framebuffer_multiply_255(
                    sampled[channel], alpha);

            uint8_t *output = destination_row + x * 4u;
            if (!is_over) {
                memcpy(output, sampled, sizeof(sampled));
                continue;
            }
            const uint8_t inverse_alpha = (uint8_t)(UINT8_MAX - sampled[3]);
            for (size_t channel = 0; channel < 4u; channel++) {
                uint32_t value = sampled[channel] +
                    avz_framebuffer_multiply_255(output[channel], inverse_alpha);
                output[channel] = (uint8_t)(
                    value > UINT8_MAX ? UINT8_MAX : value);
            }
        }
    }
    return 1;
}

int avz_framebuffer_composite_bgra8(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    size_t source_width,
    size_t source_height,
    const uint8_t *mask,
    size_t mask_stride,
    uint8_t solid_mask_alpha,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t destination_width,
    size_t destination_height,
    uint32_t premultiplied_bgra,
    uint32_t blend_operator,
    int source_is_solid,
    int bilinear_filtering,
    int component_alpha_mask,
    int mask_is_packed_a8,
    int source_is_packed_a8,
    int destination_is_packed_a8
) {
    const int source_required = blend_operator != 0u && blend_operator != 2u;
    const size_t source_bytes_per_pixel = source_is_packed_a8 ? 1u : 4u;
    const size_t destination_bytes_per_pixel =
        destination_is_packed_a8 ? 1u : 4u;
    if (destination == NULL || destination_width == 0 ||
        destination_height == 0 ||
        blend_operator > 13u ||
        (source_required && !source_is_solid && source == NULL) ||
        (source_is_packed_a8 && bilinear_filtering) ||
        destination_x > SIZE_MAX - destination_width ||
        destination_y > SIZE_MAX - destination_height ||
        destination_x + destination_width >
            destination_stride / destination_bytes_per_pixel ||
        (mask != NULL && mask_stride == 0) ||
        (source_required && !source_is_solid &&
         (source_width == 0 || source_height == 0 ||
          source_x > SIZE_MAX - source_width ||
          source_y > SIZE_MAX - source_height ||
          source_x + source_width >
              source_stride / source_bytes_per_pixel))) {
        return 0;
    }

    const uint8_t solid[4] = {
        (uint8_t)premultiplied_bgra,
        (uint8_t)(premultiplied_bgra >> 8u),
        (uint8_t)(premultiplied_bgra >> 16u),
        (uint8_t)(premultiplied_bgra >> 24u)
    };
    for (size_t y = 0; y < destination_height; y++) {
        uint8_t *destination_row = destination +
            (destination_y + y) * destination_stride +
            destination_x * destination_bytes_per_pixel;
        const uint8_t *mask_row = mask != NULL ? mask + y * mask_stride : NULL;
        for (size_t x = 0; x < destination_width; x++) {
            uint8_t packed_destination[4] = { 0, 0, 0, 0 };
            uint8_t *output;
            if (destination_is_packed_a8) {
                packed_destination[3] = destination_row[x];
                output = packed_destination;
            } else {
                output = destination_row + x * 4u;
            }
            if (blend_operator == 0u) {
                if (destination_is_packed_a8)
                    destination_row[x] = 0;
                else
                    memset(output, 0, 4u);
                continue;
            }
            if (blend_operator == 2u)
                continue;

            uint8_t sampled[4];
            if (source_is_solid) {
                memcpy(sampled, solid, sizeof(sampled));
            } else if (bilinear_filtering) {
                avz_framebuffer_bilinear_sample_bgra8(
                    source, source_stride, source_x, source_y,
                    source_width, source_height, x, y,
                    destination_width, destination_height, sampled);
            } else {
                const size_t sampled_x = source_x +
                    avz_framebuffer_scaled_coordinate(
                        x, source_width, destination_width);
                const size_t sampled_y = source_y +
                    avz_framebuffer_scaled_coordinate(
                        y, source_height, destination_height);
                if (source_is_packed_a8) {
                    sampled[0] = 0;
                    sampled[1] = 0;
                    sampled[2] = 0;
                    sampled[3] = source[
                        sampled_y * source_stride + sampled_x];
                } else {
                    memcpy(sampled,
                        source + sampled_y * source_stride + sampled_x * 4u,
                        sizeof(sampled));
                }
            }

            uint8_t coverage[4];
            if (mask_row == NULL) {
                memset(coverage, solid_mask_alpha, sizeof(coverage));
            } else if (mask_is_packed_a8) {
                memset(coverage, mask_row[x], sizeof(coverage));
            } else if (component_alpha_mask) {
                memcpy(coverage, mask_row + x * 4u, sizeof(coverage));
            } else {
                memset(coverage, mask_row[x * 4u + 3u], sizeof(coverage));
            }

            uint8_t masked_source[4];
            for (size_t channel = 0; channel < 4u; channel++)
                masked_source[channel] = avz_framebuffer_multiply_255(
                    sampled[channel], coverage[channel]);
            if (blend_operator == 1u) {
                memcpy(output, masked_source, sizeof(masked_source));
                if (destination_is_packed_a8)
                    destination_row[x] = output[3];
                continue;
            }
            if (blend_operator == 12u) {
                for (size_t channel = 0; channel < 4u; channel++) {
                    uint16_t value = (uint16_t)masked_source[channel] +
                        output[channel];
                    output[channel] = value > UINT8_MAX
                        ? UINT8_MAX : (uint8_t)value;
                }
                if (destination_is_packed_a8)
                    destination_row[x] = output[3];
                continue;
            }

            if (blend_operator == 13u) {
                const float destination_alpha =
                    (float)output[3] * (1.0f / 255.0f);
                for (size_t channel = 0; channel < 4u; channel++) {
                    const float channel_coverage =
                        (float)coverage[channel] * (1.0f / 255.0f);
                    const float source_alpha =
                        (float)sampled[3] * (1.0f / 255.0f) *
                        channel_coverage;
                    const float source_value =
                        (float)sampled[channel] * (1.0f / 255.0f) *
                        channel_coverage;
                    float source_factor = 1.0f;
                    if (source_alpha > 0.0f) {
                        source_factor =
                            (1.0f - destination_alpha) / source_alpha;
                        if (source_factor > 1.0f)
                            source_factor = 1.0f;
                        else if (source_factor < 0.0f)
                            source_factor = 0.0f;
                    }
                    float result = source_value * source_factor +
                        (float)output[channel] * (1.0f / 255.0f);
                    if (result > 1.0f)
                        result = 1.0f;
                    else if (result < 0.0f)
                        result = 0.0f;
                    uint32_t quantized = (uint32_t)(result * 256.0f);
                    output[channel] = quantized > UINT8_MAX
                        ? UINT8_MAX : (uint8_t)quantized;
                }
                if (destination_is_packed_a8)
                    destination_row[x] = output[3];
                continue;
            }

            const uint8_t destination_alpha = output[3];
            for (size_t channel = 0; channel < 4u; channel++) {
                const uint8_t covered_alpha = avz_framebuffer_multiply_255(
                    sampled[3], coverage[channel]);
                uint8_t source_factor = UINT8_MAX;
                uint8_t destination_factor =
                    (uint8_t)(UINT8_MAX - covered_alpha);
                switch (blend_operator) {
                case 4u:
                    source_factor = (uint8_t)(UINT8_MAX - destination_alpha);
                    destination_factor = UINT8_MAX;
                    break;
                case 5u:
                    source_factor = destination_alpha;
                    destination_factor = 0;
                    break;
                case 6u:
                    source_factor = 0;
                    destination_factor = covered_alpha;
                    break;
                case 7u:
                    source_factor = (uint8_t)(UINT8_MAX - destination_alpha);
                    destination_factor = 0;
                    break;
                case 8u:
                    source_factor = 0;
                    destination_factor =
                        (uint8_t)(UINT8_MAX - covered_alpha);
                    break;
                case 9u:
                    source_factor = destination_alpha;
                    break;
                case 10u:
                    source_factor = (uint8_t)(UINT8_MAX - destination_alpha);
                    destination_factor = covered_alpha;
                    break;
                case 11u:
                    source_factor = (uint8_t)(UINT8_MAX - destination_alpha);
                    break;
                default:
                    break;
                }
                uint16_t value =
                    avz_framebuffer_multiply_255(
                        masked_source[channel], source_factor) +
                    avz_framebuffer_multiply_255(
                        output[channel], destination_factor);
                output[channel] = value > UINT8_MAX
                    ? UINT8_MAX : (uint8_t)value;
            }
            if (destination_is_packed_a8)
                destination_row[x] = output[3];
        }
    }
    return 1;
}

static int avz_framebuffer_merge_damage(
    const AVZFramebufferDamageRect *first,
    const AVZFramebufferDamageRect *second,
    AVZFramebufferDamageRect *merged
) {
    const uint64_t first_right = (uint64_t)first->x + first->width;
    const uint64_t second_right = (uint64_t)second->x + second->width;
    const uint64_t first_bottom = (uint64_t)first->y + first->height;
    const uint64_t second_bottom = (uint64_t)second->y + second->height;

    if (first->y == second->y && first->height == second->height &&
        first_right >= second->x && second_right >= first->x) {
        const uint32_t left = first->x < second->x ? first->x : second->x;
        const uint64_t right = first_right > second_right
            ? first_right
            : second_right;
        merged->x = left;
        merged->y = first->y;
        merged->width = (uint32_t)(right - left);
        merged->height = first->height;
        return 1;
    }

    if (first->x == second->x && first->width == second->width &&
        first_bottom >= second->y && second_bottom >= first->y) {
        const uint32_t top = first->y < second->y ? first->y : second->y;
        const uint64_t bottom = first_bottom > second_bottom
            ? first_bottom
            : second_bottom;
        merged->x = first->x;
        merged->y = top;
        merged->width = first->width;
        merged->height = (uint32_t)(bottom - top);
        return 1;
    }
    return 0;
}

static size_t avz_framebuffer_compact_damage(
    AVZFramebufferDamageRect *rects,
    size_t count
) {
    int merged_any = 1;
    while (merged_any) {
        merged_any = 0;
        for (size_t first = 0; first < count && !merged_any; first++) {
            for (size_t second = first + 1; second < count; second++) {
                AVZFramebufferDamageRect merged;
                if (!avz_framebuffer_merge_damage(
                        &rects[first],
                        &rects[second],
                        &merged)) {
                    continue;
                }
                rects[first] = merged;
                rects[second] = rects[count - 1];
                count--;
                merged_any = 1;
                break;
            }
        }
    }
    return count;
}

static void avz_framebuffer_copy_rectangle(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height
) {
    const size_t row_bytes = width * 4;
    for (size_t row = 0; row < height; row++) {
        memcpy(
            destination + (destination_y + row) * destination_stride +
                destination_x * 4,
            source + (source_y + row) * source_stride + source_x * 4,
            row_bytes
        );
    }
}

size_t avz_framebuffer_commit_dirty_tiles(
    const uint8_t *source,
    size_t source_stride,
    size_t source_x,
    size_t source_y,
    uint8_t *destination,
    size_t destination_stride,
    size_t destination_x,
    size_t destination_y,
    size_t width,
    size_t height,
    size_t tile_width,
    size_t tile_height,
    AVZFramebufferDamageRect *damage_rects,
    size_t damage_capacity,
    size_t *changed_byte_count
) {
    if (changed_byte_count != NULL) {
        *changed_byte_count = 0;
    }
    if (source == NULL || destination == NULL || damage_rects == NULL ||
        changed_byte_count == NULL || damage_capacity == 0 ||
        tile_width == 0 || tile_height == 0 || width == 0 || height == 0 ||
        ((uintptr_t)source & 3U) != 0 ||
        ((uintptr_t)destination & 3U) != 0 ||
        (source_stride & 3U) != 0 || (destination_stride & 3U) != 0 ||
        source_x > SIZE_MAX - width || source_y > SIZE_MAX - height ||
        destination_x > SIZE_MAX - width || destination_y > SIZE_MAX - height ||
        source_x + width > source_stride / 4 ||
        destination_x + width > destination_stride / 4 ||
        destination_x + width > UINT32_MAX ||
        destination_y + height > UINT32_MAX) {
        return 0;
    }

    size_t damage_count = 0;
    for (size_t tile_y = 0; tile_y < height; tile_y += tile_height) {
        const size_t current_height = tile_height < height - tile_y
            ? tile_height
            : height - tile_y;
        for (size_t tile_x = 0; tile_x < width; tile_x += tile_width) {
            const size_t current_width = tile_width < width - tile_x
                ? tile_width
                : width - tile_x;
            size_t minimum_x = current_width;
            size_t minimum_y = current_height;
            size_t maximum_x = 0;
            size_t maximum_y = 0;
            int tile_changed = 0;

            for (size_t row = 0; row < current_height; row++) {
                const uint32_t *source_pixels = (const uint32_t *)(
                    source + (source_y + tile_y + row) * source_stride +
                    (source_x + tile_x) * 4
                );
                const uint32_t *destination_pixels = (const uint32_t *)(
                    destination + (destination_y + tile_y + row) *
                        destination_stride + (destination_x + tile_x) * 4
                );
                if (memcmp(
                        source_pixels,
                        destination_pixels,
                        current_width * 4) == 0) {
                    continue;
                }
                for (size_t column = 0; column < current_width; column++) {
                    if (source_pixels[column] == destination_pixels[column]) {
                        continue;
                    }
                    if (column < minimum_x) {
                        minimum_x = column;
                    }
                    if (column > maximum_x) {
                        maximum_x = column;
                    }
                    if (row < minimum_y) {
                        minimum_y = row;
                    }
                    if (row > maximum_y) {
                        maximum_y = row;
                    }
                    tile_changed = 1;
                }
            }

            if (!tile_changed) {
                continue;
            }
            if (damage_count == damage_capacity) {
                avz_framebuffer_copy_rectangle(
                    source,
                    source_stride,
                    source_x,
                    source_y,
                    destination,
                    destination_stride,
                    destination_x,
                    destination_y,
                    width,
                    height
                );
                damage_rects[0].x = (uint32_t)destination_x;
                damage_rects[0].y = (uint32_t)destination_y;
                damage_rects[0].width = (uint32_t)width;
                damage_rects[0].height = (uint32_t)height;
                *changed_byte_count = width * height * 4;
                return 1;
            }

            const size_t changed_width = maximum_x - minimum_x + 1;
            const size_t changed_height = maximum_y - minimum_y + 1;
            avz_framebuffer_copy_rectangle(
                source,
                source_stride,
                source_x + tile_x + minimum_x,
                source_y + tile_y + minimum_y,
                destination,
                destination_stride,
                destination_x + tile_x + minimum_x,
                destination_y + tile_y + minimum_y,
                changed_width,
                changed_height
            );
            damage_rects[damage_count].x = (uint32_t)(
                destination_x + tile_x + minimum_x
            );
            damage_rects[damage_count].y = (uint32_t)(
                destination_y + tile_y + minimum_y
            );
            damage_rects[damage_count].width = (uint32_t)changed_width;
            damage_rects[damage_count].height = (uint32_t)changed_height;
            damage_count++;
        }
    }

    damage_count = avz_framebuffer_compact_damage(damage_rects, damage_count);
    size_t changed_bytes = 0;
    for (size_t index = 0; index < damage_count; index++) {
        const size_t rectangle_bytes =
            (size_t)damage_rects[index].width * damage_rects[index].height * 4;
        if (changed_bytes > SIZE_MAX - rectangle_bytes) {
            changed_bytes = SIZE_MAX;
            break;
        }
        changed_bytes += rectangle_bytes;
    }
    *changed_byte_count = changed_bytes;
    return damage_count;
}
