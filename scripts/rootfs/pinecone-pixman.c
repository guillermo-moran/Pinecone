#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct pixman_image pixman_image_t;
typedef int pixman_bool_t;
typedef int pixman_op_t;
typedef uint32_t pixman_format_code_t;
typedef struct { int32_t matrix[3][3]; } pixman_transform_t;
typedef struct { int32_t x1, y1, x2, y2; } pixman_box32_t;
typedef struct { uint16_t red, green, blue, alpha; } pixman_color_t;
typedef struct pixman_region32_data pixman_region32_data_t;
typedef struct pixman_region32 {
    pixman_box32_t extents;
    pixman_region32_data_t *data;
} pixman_region32_t;
typedef struct pixman_region16 pixman_region16_t;

enum {
    PINECONE_PIXMAN_OP_CLEAR = 0,
    PINECONE_PIXMAN_OP_SRC = 1,
    PINECONE_PIXMAN_OP_DST = 2,
    PINECONE_PIXMAN_OP_OVER = 3,
    PINECONE_PIXMAN_OP_ADD = 12,
    PINECONE_FORMAT_A8R8G8B8 = 0x20028888u,
    PINECONE_FORMAT_X8R8G8B8 = 0x20020888u,
    PINECONE_FORMAT_A8 = 0x08018000u,
    PINECONE_FILTER_NEAREST = 3,
    PINECONE_FILTER_BILINEAR = 4,
    PINECONE_REPEAT_NONE = 0,
    PINECONE_REPEAT_PAD = 3,
    PINECONE_DRM_IOCTL_BASE = 'd',
    PINECONE_DRM_COMMAND_BASE = 0x40,
    PINECONE_DRM_VIRTGPU_EXECBUFFER = 0x02,
    PINECONE_DRM_IOCTL_PRIME_HANDLE_TO_FD_NR = 0x2d,
    PINECONE_DRM_IOCTL_MODE_CREATE_DUMB_NR = 0xb2,
    PINECONE_DRM_IOCTL_MODE_MAP_DUMB_NR = 0xb3,
    PINECONE_DRM_IOCTL_MODE_DESTROY_DUMB_NR = 0xb4,
    PINECONE_MAGIC = 0x504e3244u,
    PINECONE_VERSION = 3,
    PINECONE_EXACT_COMPOSITE_VERSION = 5,
    PINECONE_BATCH_VERSION = 4,
    PINECONE_SOURCE_CONTAINS_ALPHA = 1u << 0,
    PINECONE_FILTER_BILINEAR_FLAG = 1u << 1,
    PINECONE_HAS_MASK = 1u << 2,
    PINECONE_MASK_IS_SOLID = 1u << 3,
    PINECONE_SOURCE_IS_SOLID = 1u << 4,
    PINECONE_MASK_COMPONENT_ALPHA = 1u << 5,
    PINECONE_MASK_PACKED_A8 = 1u << 6,
    PINECONE_DRM_CLOEXEC = 1u << 0,
    PINECONE_DRM_RDWR = 1u << 1,
    PINECONE_EXECBUFFER_FENCE_FD_OUT = 1u << 1,
    PINECONE_PAYLOAD_SIZE = 64,
    PINECONE_BATCH_HEADER_SIZE = 16,
    PINECONE_MAX_BATCH_COMMANDS = 64,
    PINECONE_MAX_BATCH_HANDLES = PINECONE_MAX_BATCH_COMMANDS * 3,
    PINECONE_OPERATOR_COUNT = 64,
    PINECONE_MAX_IMAGES = 4096,
    PINECONE_MAX_MAPPINGS = 2048,
    PINECONE_SYSCALL_IOCTL = 29,
    PINECONE_SYSCALL_WRITE = 64,
    PINECONE_SYSCALL_MUNMAP = 215,
    PINECONE_SYSCALL_MMAP = 222
};

#define PINECONE_IOC_NRBITS 8
#define PINECONE_IOC_TYPEBITS 8
#define PINECONE_IOC_SIZEBITS 14
#define PINECONE_IOC_NRSHIFT 0
#define PINECONE_IOC_TYPESHIFT (PINECONE_IOC_NRSHIFT + PINECONE_IOC_NRBITS)
#define PINECONE_IOC_SIZESHIFT (PINECONE_IOC_TYPESHIFT + PINECONE_IOC_TYPEBITS)
#define PINECONE_IOC_DIRSHIFT (PINECONE_IOC_SIZESHIFT + PINECONE_IOC_SIZEBITS)
#define PINECONE_IOC_WRITE 1u
#define PINECONE_IOC_READ 2u
#define PINECONE_IOC(direction, type, number, size) \
    (((direction) << PINECONE_IOC_DIRSHIFT) | \
     ((type) << PINECONE_IOC_TYPESHIFT) | \
     ((number) << PINECONE_IOC_NRSHIFT) | \
     ((uint32_t)(size) << PINECONE_IOC_SIZESHIFT))
#define PINECONE_IOWR(number, type) \
    PINECONE_IOC(PINECONE_IOC_READ | PINECONE_IOC_WRITE, \
                 PINECONE_DRM_IOCTL_BASE, number, sizeof(type))

struct pinecone_drm_mode_create_dumb {
    uint32_t height, width, bpp, flags;
    uint32_t handle, pitch;
    uint64_t size;
};

struct pinecone_drm_mode_map_dumb {
    uint32_t handle, pad;
    uint64_t offset;
};

struct pinecone_drm_mode_destroy_dumb {
    uint32_t handle;
};

struct pinecone_drm_execbuffer {
    uint32_t flags, size;
    uint64_t command, bo_handles;
    uint32_t num_bo_handles;
    int32_t fence_fd;
    uint32_t ring_idx, syncobj_stride, num_in_syncobjs, num_out_syncobjs;
    uint64_t in_syncobjs, out_syncobjs;
};

struct pinecone_drm_prime_handle {
    uint32_t handle;
    uint32_t flags;
    int32_t fd;
};

struct pinecone_2d_payload {
    uint32_t magic;
    uint16_t version, operation;
    uint32_t flags, source_resource_id, destination_resource_id;
    int32_t source_x, source_y, destination_x, destination_y;
    uint32_t width, height, color;
    uint32_t source_width, source_height;
    uint32_t mask_resource_id, mask_alpha;
};

_Static_assert(sizeof(struct pinecone_2d_payload) == PINECONE_PAYLOAD_SIZE,
               "Pinecone 2D ABI must remain 64 bytes");

struct pinecone_2d_batch_header {
    uint32_t magic;
    uint16_t version, command_count;
    uint16_t record_size, flags;
    uint32_t byte_count;
};

_Static_assert(sizeof(struct pinecone_2d_batch_header) ==
                   PINECONE_BATCH_HEADER_SIZE,
               "Pinecone 2D batch header must remain 16 bytes");

struct pinecone_2d_batch {
    struct pinecone_2d_batch_header header;
    struct pinecone_2d_payload commands[PINECONE_MAX_BATCH_COMMANDS];
};

struct pinecone_thread_batch {
    unsigned int depth;
    int graphics_fd;
    uint32_t command_count;
    uint32_t handle_count;
    uint32_t handles[PINECONE_MAX_BATCH_HANDLES];
    struct pinecone_2d_batch payload;
};

struct pinecone_mapping {
    void *address;
    size_t length;
    int fd;
    uint32_t handle;
};

struct pinecone_pending_mapping {
    uint64_t offset;
    int fd;
    uint32_t handle;
};

struct pinecone_image_state {
    pixman_image_t *image;
    unsigned int unsafe_state;
    pixman_transform_t transform;
    int has_transform;
    int repeat;
    int filter;
    int filter_parameter_count;
    uint32_t solid_color;
    int is_solid;
    int cpu_data_exposed;
    pixman_region32_t *destination_clip;
    struct pinecone_upload_surface *owned_surface;
};

struct pinecone_upload_surface {
    void *address;
    size_t length;
    int fd;
    uint32_t handle;
    uint32_t width;
    uint32_t height;
    uint32_t pitch;
};

enum pinecone_fallback_reason {
    PINECONE_FALLBACK_OPERATION,
    PINECONE_FALLBACK_MASK,
    PINECONE_FALLBACK_GEOMETRY,
    PINECONE_FALLBACK_DESTINATION,
    PINECONE_FALLBACK_IMAGE_STATE,
    PINECONE_FALLBACK_CLIP,
    PINECONE_FALLBACK_SOURCE,
    PINECONE_FALLBACK_UPLOAD,
    PINECONE_FALLBACK_SUBMIT,
    PINECONE_FALLBACK_REASON_COUNT
};

static pthread_mutex_t pinecone_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t pinecone_resolve_once = PTHREAD_ONCE_INIT;
static struct pinecone_mapping pinecone_mappings[PINECONE_MAX_MAPPINGS];
static struct pinecone_pending_mapping pinecone_pending_mappings[PINECONE_MAX_MAPPINGS];
static struct pinecone_image_state pinecone_images[PINECONE_MAX_IMAGES];
enum pinecone_upload_kind {
    PINECONE_UPLOAD_SOURCE,
    PINECONE_UPLOAD_MASK,
    PINECONE_UPLOAD_DESTINATION,
    PINECONE_UPLOAD_COUNT
};

static struct pinecone_upload_surface pinecone_uploads[PINECONE_UPLOAD_COUNT];
static int pinecone_owned_graphics_fd = -1;
static uint64_t pinecone_composite_count;
static uint64_t pinecone_accelerated_count;
static uint64_t pinecone_accelerated_pixels;
static uint64_t pinecone_fallback_counts[PINECONE_FALLBACK_REASON_COUNT];
static uint64_t pinecone_shared_surface_count;
static uint64_t pinecone_live_shared_surfaces;
static uint64_t pinecone_live_shared_bytes;
static uint64_t pinecone_batch_count;
static uint64_t pinecone_batched_command_count;
static uint64_t pinecone_operator_counts[PINECONE_OPERATOR_COUNT];
static uint64_t pinecone_accelerated_operator_counts[PINECONE_OPERATOR_COUNT];
enum pinecone_geometry_diagnostic {
    PINECONE_GEOMETRY_IDENTITY,
    PINECONE_GEOMETRY_SCALED_NEAREST,
    PINECONE_GEOMETRY_SCALED_BILINEAR,
    PINECONE_GEOMETRY_SOLID,
    PINECONE_GEOMETRY_DESTINATION_ONLY,
    PINECONE_GEOMETRY_REJECTED,
    PINECONE_GEOMETRY_DIAGNOSTIC_COUNT
};
static uint64_t pinecone_geometry_counts[PINECONE_GEOMETRY_DIAGNOSTIC_COUNT];
enum pinecone_mask_diagnostic {
    PINECONE_MASK_NONE,
    PINECONE_MASK_SOLID,
    PINECONE_MASK_A8,
    PINECONE_MASK_ARGB,
    PINECONE_MASK_DIAG_COMPONENT_ALPHA,
    PINECONE_MASK_GEOMETRY_REJECTED,
    PINECONE_MASK_FORMAT_REJECTED,
    PINECONE_MASK_DATA_REJECTED,
    PINECONE_MASK_BOUNDS_REJECTED,
    PINECONE_MASK_ALLOCATION_REJECTED,
    PINECONE_MASK_DIRECT,
    PINECONE_MASK_UPLOADED,
    PINECONE_MASK_DIAGNOSTIC_COUNT
};
static uint64_t pinecone_mask_counts[PINECONE_MASK_DIAGNOSTIC_COUNT];
static int pinecone_image_state_diagnostic_written;
static _Thread_local struct pinecone_thread_batch pinecone_thread_batch;

static void (*real_composite32)(pixman_op_t, pixman_image_t *, pixman_image_t *,
    pixman_image_t *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    uint32_t, uint32_t);
static uint32_t *(*real_get_data)(pixman_image_t *);
static int (*real_get_stride)(pixman_image_t *);
static int (*real_get_width)(pixman_image_t *);
static int (*real_get_height)(pixman_image_t *);
static pixman_format_code_t (*real_get_format)(pixman_image_t *);
static pixman_bool_t (*real_unref)(pixman_image_t *);
static pixman_image_t *(*real_create_solid_fill)(const pixman_color_t *);
static pixman_image_t *(*real_create_bits)(
    pixman_format_code_t, int, int, uint32_t *, int);
static pixman_image_t *(*real_create_bits_no_clear)(
    pixman_format_code_t, int, int, uint32_t *, int);
static pixman_bool_t (*real_set_transform)(pixman_image_t *, const pixman_transform_t *);
static void (*real_set_repeat)(pixman_image_t *, int);
static pixman_bool_t (*real_set_filter)(pixman_image_t *, int, const int32_t *, int);
static pixman_bool_t (*real_set_clip_region32)(pixman_image_t *, pixman_region32_t *);
static pixman_bool_t (*real_set_clip_region)(pixman_image_t *, pixman_region16_t *);
static void (*real_set_alpha_map)(pixman_image_t *, pixman_image_t *, int16_t, int16_t);
static void (*real_set_source_clipping)(pixman_image_t *, pixman_bool_t);
static void (*real_set_component_alpha)(pixman_image_t *, pixman_bool_t);
static void (*real_region32_init)(pixman_region32_t *);
static void (*real_region32_fini)(pixman_region32_t *);
static pixman_bool_t (*real_region32_copy)(pixman_region32_t *, pixman_region32_t *);
static int (*real_region32_contains_rectangle)(pixman_region32_t *, const pixman_box32_t *);

static long pinecone_syscall6(
    long number, long argument0, long argument1, long argument2,
    long argument3, long argument4, long argument5
) {
    register long x0 __asm__("x0") = argument0;
    register long x1 __asm__("x1") = argument1;
    register long x2 __asm__("x2") = argument2;
    register long x3 __asm__("x3") = argument3;
    register long x4 __asm__("x4") = argument4;
    register long x5 __asm__("x5") = argument5;
    register long x8 __asm__("x8") = number;
    __asm__ volatile(
        "svc #0"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
        : "memory", "cc"
    );
    return x0;
}

static long pinecone_syscall_result(long result) {
    if ((unsigned long)result >= (unsigned long)-4095) {
        errno = (int)-result;
        return -1;
    }
    return result;
}

static int pinecone_raw_ioctl(int fd, uint32_t request, void *argument) {
    return (int)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_IOCTL, fd, request, (long)argument, 0, 0, 0));
}

static void pinecone_forget_mapping_locked(void *address) {
    for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
        if (pinecone_mappings[index].address == address) {
            memset(&pinecone_mappings[index], 0, sizeof(pinecone_mappings[index]));
            return;
        }
    }
}

static int pinecone_record_mapping_locked(
    void *address, size_t length, int fd, uint32_t handle
) {
    for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
        if (pinecone_mappings[index].address == NULL) {
            pinecone_mappings[index].address = address;
            pinecone_mappings[index].length = length;
            pinecone_mappings[index].fd = fd;
            pinecone_mappings[index].handle = handle;
            return 1;
        }
    }
    return 0;
}

static void pinecone_release_upload_locked(
    struct pinecone_upload_surface *upload
) {
    if (upload->address != NULL) {
        pinecone_forget_mapping_locked(upload->address);
        pinecone_syscall_result(pinecone_syscall6(
            PINECONE_SYSCALL_MUNMAP, (long)upload->address,
            (long)upload->length, 0, 0, 0, 0));
    }
    if (upload->handle != 0) {
        struct pinecone_drm_mode_destroy_dumb destroy = {
            .handle = upload->handle
        };
        pinecone_raw_ioctl(
            upload->fd,
            PINECONE_IOWR(PINECONE_DRM_IOCTL_MODE_DESTROY_DUMB_NR,
                          struct pinecone_drm_mode_destroy_dumb),
            &destroy
        );
    }
    memset(upload, 0, sizeof(*upload));
    upload->fd = -1;
}

static int pinecone_ensure_upload_locked(
    struct pinecone_upload_surface *upload,
    int fd,
    uint32_t required_width,
    uint32_t required_height
) {
    if (upload->address != NULL && upload->fd == fd &&
        upload->width >= required_width &&
        upload->height >= required_height) {
        return 1;
    }
    pinecone_release_upload_locked(upload);

    uint32_t width = required_width < 64u ? 64u : required_width;
    uint32_t height = required_height < 64u ? 64u : required_height;
    if (width > UINT32_MAX - 63u)
        return 0;
    width = (width + 63u) & ~63u;

    struct pinecone_drm_mode_create_dumb create = {
        .height = height,
        .width = width,
        .bpp = 32
    };
    if (pinecone_raw_ioctl(
            fd,
            PINECONE_IOWR(PINECONE_DRM_IOCTL_MODE_CREATE_DUMB_NR,
                          struct pinecone_drm_mode_create_dumb),
            &create) != 0 || create.handle == 0 || create.pitch < width * 4u ||
        create.size == 0 || create.size > SIZE_MAX) {
        return 0;
    }

    struct pinecone_drm_mode_map_dumb map = { .handle = create.handle };
    if (pinecone_raw_ioctl(
            fd,
            PINECONE_IOWR(PINECONE_DRM_IOCTL_MODE_MAP_DUMB_NR,
                          struct pinecone_drm_mode_map_dumb),
            &map) != 0) {
        struct pinecone_drm_mode_destroy_dumb destroy = {
            .handle = create.handle
        };
        pinecone_raw_ioctl(
            fd,
            PINECONE_IOWR(PINECONE_DRM_IOCTL_MODE_DESTROY_DUMB_NR,
                          struct pinecone_drm_mode_destroy_dumb),
            &destroy
        );
        return 0;
    }

    void *address = (void *)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_MMAP, 0, (long)create.size,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd, (long)map.offset));
    if (address == MAP_FAILED) {
        struct pinecone_drm_mode_destroy_dumb destroy = {
            .handle = create.handle
        };
        pinecone_raw_ioctl(
            fd,
            PINECONE_IOWR(PINECONE_DRM_IOCTL_MODE_DESTROY_DUMB_NR,
                          struct pinecone_drm_mode_destroy_dumb),
            &destroy
        );
        return 0;
    }

    upload->address = address;
    upload->length = (size_t)create.size;
    upload->fd = fd;
    upload->handle = create.handle;
    upload->width = width;
    upload->height = height;
    upload->pitch = create.pitch;
    return 1;
}

static int pinecone_open_graphics_locked(void) {
    if (pinecone_owned_graphics_fd >= 0)
        return pinecone_owned_graphics_fd;

    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd >= 0)
        pinecone_owned_graphics_fd = fd;
    return fd;
}

static int pinecone_existing_graphics_fd_locked(void) {
    for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
        if (pinecone_mappings[index].address != NULL)
            return pinecone_mappings[index].fd;
    }
    for (size_t index = 0; index < PINECONE_UPLOAD_COUNT; index++) {
        if (pinecone_uploads[index].address != NULL)
            return pinecone_uploads[index].fd;
    }
    return -1;
}

static struct pinecone_upload_surface *pinecone_allocate_image_surface_locked(
    uint32_t width, uint32_t height
) {
    int fd = pinecone_existing_graphics_fd_locked();
    if (fd < 0)
        fd = pinecone_open_graphics_locked();
    if (fd < 0)
        return NULL;

    struct pinecone_upload_surface *surface = calloc(1, sizeof(*surface));
    if (surface == NULL)
        return NULL;
    surface->fd = -1;
    if (!pinecone_ensure_upload_locked(surface, fd, width, height) ||
        !pinecone_record_mapping_locked(
            surface->address, surface->length, surface->fd, surface->handle)) {
        pinecone_release_upload_locked(surface);
        free(surface);
        return NULL;
    }
    __atomic_add_fetch(&pinecone_shared_surface_count, 1u, __ATOMIC_RELAXED);
    __atomic_add_fetch(&pinecone_live_shared_surfaces, 1u, __ATOMIC_RELAXED);
    __atomic_add_fetch(
        &pinecone_live_shared_bytes, surface->length, __ATOMIC_RELAXED);
    return surface;
}

static void pinecone_release_image_surface_locked(
    struct pinecone_upload_surface *surface
) {
    if (surface == NULL)
        return;
    __atomic_sub_fetch(&pinecone_live_shared_surfaces, 1u, __ATOMIC_RELAXED);
    __atomic_sub_fetch(
        &pinecone_live_shared_bytes, surface->length, __ATOMIC_RELAXED);
    pinecone_release_upload_locked(surface);
    free(surface);
}

static int pinecone_upload_pixels_locked(
    struct pinecone_upload_surface *upload,
    int fd,
    const uint8_t *source,
    size_t source_stride,
    uint32_t source_x,
    uint32_t source_y,
    uint32_t width,
    uint32_t height
) {
    if (!pinecone_ensure_upload_locked(upload, fd, width, height))
        return 0;
    const size_t row_bytes = (size_t)width * 4u;
    for (uint32_t row = 0; row < height; row++) {
        memcpy(
            (uint8_t *)upload->address + (size_t)row * upload->pitch,
            source + (size_t)(source_y + row) * source_stride +
                (size_t)source_x * 4u,
            row_bytes
        );
    }
    return 1;
}

static int pinecone_upload_mask_locked(
    struct pinecone_upload_surface *upload,
    int fd,
    const uint8_t *source,
    size_t source_stride,
    uint32_t source_x,
    uint32_t source_y,
    uint32_t width,
    uint32_t height,
    pixman_format_code_t format,
    int component_alpha
) {
    if (!pinecone_ensure_upload_locked(upload, fd, width, height))
        return 0;
    for (uint32_t row = 0; row < height; row++) {
        const uint8_t *source_row = source +
            (size_t)(source_y + row) * source_stride;
        uint8_t *destination_row = (uint8_t *)upload->address +
            (size_t)row * upload->pitch;
        for (uint32_t column = 0; column < width; column++) {
            uint8_t *destination_pixel =
                destination_row + (size_t)column * 4u;
            if (component_alpha && format != PINECONE_FORMAT_A8) {
                memcpy(destination_pixel,
                    source_row + (size_t)(source_x + column) * 4u, 4u);
            } else {
                uint8_t alpha = format == PINECONE_FORMAT_A8
                    ? source_row[source_x + column]
                    : source_row[(size_t)(source_x + column) * 4u + 3u];
                destination_pixel[0] = 0;
                destination_pixel[1] = 0;
                destination_pixel[2] = 0;
                destination_pixel[3] = alpha;
            }
        }
    }
    return 1;
}

static void pinecone_record_composite(
    pixman_op_t op,
    int accelerated,
    enum pinecone_fallback_reason fallback_reason,
    uint32_t width,
    uint32_t height
) {
    if ((unsigned int)op < PINECONE_OPERATOR_COUNT) {
        __atomic_add_fetch(
            &pinecone_operator_counts[op], 1u, __ATOMIC_RELAXED);
        if (accelerated) {
            __atomic_add_fetch(
                &pinecone_accelerated_operator_counts[op],
                1u, __ATOMIC_RELAXED);
        }
    }
    uint64_t total = __atomic_add_fetch(
        &pinecone_composite_count, 1u, __ATOMIC_RELAXED);
    if (accelerated) {
        __atomic_add_fetch(&pinecone_accelerated_count, 1u, __ATOMIC_RELAXED);
        __atomic_add_fetch(
            &pinecone_accelerated_pixels,
            (uint64_t)width * height,
            __ATOMIC_RELAXED
        );
    } else if ((unsigned int)fallback_reason < PINECONE_FALLBACK_REASON_COUNT) {
        __atomic_add_fetch(
            &pinecone_fallback_counts[fallback_reason], 1u, __ATOMIC_RELAXED);
    }
    const char *diagnostics = getenv("PINECONE_PIXMAN_DIAGNOSTICS");
    if (diagnostics == NULL || strcmp(diagnostics, "1") != 0 ||
        (total & (total - 1u)) != 0)
        return;

    char line[384];
    int length = snprintf(
        line, sizeof(line),
        "pinecone-pixman: total=%llu accelerated=%llu pixels=%llu "
        "fallback(op=%llu mask=%llu geometry=%llu destination=%llu "
        "state=%llu clip=%llu source=%llu upload=%llu submit=%llu) "
        "shared(created=%llu live=%llu bytes=%llu) batch=%llu/%llu\n",
        (unsigned long long)total,
        (unsigned long long)__atomic_load_n(
            &pinecone_accelerated_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_accelerated_pixels, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_OPERATION], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_MASK], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_GEOMETRY], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_DESTINATION], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_IMAGE_STATE], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_CLIP], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_SOURCE], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_UPLOAD], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_fallback_counts[PINECONE_FALLBACK_SUBMIT], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_shared_surface_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_live_shared_surfaces, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_live_shared_bytes, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batched_command_count, __ATOMIC_RELAXED)
    );
    if (length > 0) {
        size_t count = (size_t)length < sizeof(line)
            ? (size_t)length
            : sizeof(line) - 1u;
        pinecone_syscall6(
            PINECONE_SYSCALL_WRITE, STDERR_FILENO, (long)line,
            (long)count, 0, 0, 0);
        int console = open(
            "/dev/ttyAMA0", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (console >= 0) {
            pinecone_syscall6(
                PINECONE_SYSCALL_WRITE, console, (long)line,
                (long)count, 0, 0, 0);
            close(console);
        }
    }

    char operators[768];
    size_t used = 0;
    int written = snprintf(
        operators, sizeof(operators), "pinecone-pixman-ops:");
    if (written > 0)
        used = (size_t)written < sizeof(operators)
            ? (size_t)written : sizeof(operators) - 1u;
    for (unsigned int index = 0;
         index < PINECONE_OPERATOR_COUNT && used < sizeof(operators) - 2u;
         index++) {
        uint64_t count = __atomic_load_n(
            &pinecone_operator_counts[index], __ATOMIC_RELAXED);
        if (count == 0)
            continue;
        uint64_t accelerated_count = __atomic_load_n(
            &pinecone_accelerated_operator_counts[index], __ATOMIC_RELAXED);
        written = snprintf(
            operators + used, sizeof(operators) - used,
            " %02x=%llu/%llu", index,
            (unsigned long long)accelerated_count,
            (unsigned long long)count);
        if (written <= 0)
            break;
        size_t appended = (size_t)written;
        used += appended < sizeof(operators) - used
            ? appended : sizeof(operators) - used - 1u;
    }
    written = snprintf(
        operators + used, sizeof(operators) - used,
        " mask(none=%llu solid=%llu a8=%llu argb=%llu component=%llu "
        "geometry=%llu format=%llu data=%llu bounds=%llu allocation=%llu "
        "direct=%llu uploaded=%llu) "
        "geometry(identity=%llu nearest=%llu bilinear=%llu solid=%llu "
        "destination=%llu rejected=%llu)\n",
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_NONE], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_SOLID], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_A8], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_ARGB], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_DIAG_COMPONENT_ALPHA],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_GEOMETRY_REJECTED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_FORMAT_REJECTED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_DATA_REJECTED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_BOUNDS_REJECTED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_ALLOCATION_REJECTED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_DIRECT],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_mask_counts[PINECONE_MASK_UPLOADED],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_IDENTITY],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_SCALED_NEAREST],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_SCALED_BILINEAR],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_SOLID],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_DESTINATION_ONLY],
            __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_REJECTED],
            __ATOMIC_RELAXED));
    if (written > 0) {
        size_t count = used + (size_t)written < sizeof(operators)
            ? used + (size_t)written : sizeof(operators) - 1u;
        pinecone_syscall6(
            PINECONE_SYSCALL_WRITE, STDERR_FILENO, (long)operators,
            (long)count, 0, 0, 0);
        int console = open(
            "/dev/ttyAMA0", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (console >= 0) {
            pinecone_syscall6(
                PINECONE_SYSCALL_WRITE, console, (long)operators,
                (long)count, 0, 0, 0);
            close(console);
        }
    }
}

static void pinecone_resolve_symbols(void) {
    real_composite32 = dlsym(RTLD_NEXT, "pixman_image_composite32");
    real_get_data = dlsym(RTLD_NEXT, "pixman_image_get_data");
    real_get_stride = dlsym(RTLD_NEXT, "pixman_image_get_stride");
    real_get_width = dlsym(RTLD_NEXT, "pixman_image_get_width");
    real_get_height = dlsym(RTLD_NEXT, "pixman_image_get_height");
    real_get_format = dlsym(RTLD_NEXT, "pixman_image_get_format");
    real_unref = dlsym(RTLD_NEXT, "pixman_image_unref");
    real_create_solid_fill = dlsym(RTLD_NEXT, "pixman_image_create_solid_fill");
    real_create_bits = dlsym(RTLD_NEXT, "pixman_image_create_bits");
    real_create_bits_no_clear = dlsym(
        RTLD_NEXT, "pixman_image_create_bits_no_clear");
    real_set_transform = dlsym(RTLD_NEXT, "pixman_image_set_transform");
    real_set_repeat = dlsym(RTLD_NEXT, "pixman_image_set_repeat");
    real_set_filter = dlsym(RTLD_NEXT, "pixman_image_set_filter");
    real_set_clip_region32 = dlsym(RTLD_NEXT, "pixman_image_set_clip_region32");
    real_set_clip_region = dlsym(RTLD_NEXT, "pixman_image_set_clip_region");
    real_set_alpha_map = dlsym(RTLD_NEXT, "pixman_image_set_alpha_map");
    real_set_source_clipping = dlsym(RTLD_NEXT, "pixman_image_set_source_clipping");
    real_set_component_alpha = dlsym(
        RTLD_NEXT, "pixman_image_set_component_alpha");
    real_region32_init = dlsym(RTLD_NEXT, "pixman_region32_init");
    real_region32_fini = dlsym(RTLD_NEXT, "pixman_region32_fini");
    real_region32_copy = dlsym(RTLD_NEXT, "pixman_region32_copy");
    real_region32_contains_rectangle = dlsym(
        RTLD_NEXT, "pixman_region32_contains_rectangle");
}

static void pinecone_resolve(void) {
    pthread_once(&pinecone_resolve_once, pinecone_resolve_symbols);
}

static struct pinecone_image_state *pinecone_image_state(
    pixman_image_t *image, int create
) {
    if (image == NULL)
        return NULL;
    size_t empty = PINECONE_MAX_IMAGES;
    size_t start = ((uintptr_t)image >> 4) % PINECONE_MAX_IMAGES;
    for (size_t probe = 0; probe < PINECONE_MAX_IMAGES; probe++) {
        size_t index = (start + probe) % PINECONE_MAX_IMAGES;
        if (pinecone_images[index].image == image)
            return &pinecone_images[index];
        if (pinecone_images[index].image == (pixman_image_t *)(uintptr_t)1) {
            if (empty == PINECONE_MAX_IMAGES)
                empty = index;
            continue;
        }
        if (pinecone_images[index].image == NULL) {
            if (empty == PINECONE_MAX_IMAGES)
                empty = index;
            break;
        }
    }
    if (!create || empty == PINECONE_MAX_IMAGES)
        return NULL;
    pinecone_images[empty].image = image;
    pinecone_images[empty].unsafe_state = 0;
    memset(&pinecone_images[empty].transform, 0,
           sizeof(pinecone_images[empty].transform));
    pinecone_images[empty].transform.matrix[0][0] = 1 << 16;
    pinecone_images[empty].transform.matrix[1][1] = 1 << 16;
    pinecone_images[empty].transform.matrix[2][2] = 1 << 16;
    pinecone_images[empty].has_transform = 0;
    pinecone_images[empty].repeat = PINECONE_REPEAT_NONE;
    pinecone_images[empty].filter = PINECONE_FILTER_NEAREST;
    pinecone_images[empty].filter_parameter_count = 0;
    pinecone_images[empty].solid_color = 0;
    pinecone_images[empty].is_solid = 0;
    pinecone_images[empty].cpu_data_exposed = 0;
    pinecone_images[empty].destination_clip = NULL;
    pinecone_images[empty].owned_surface = NULL;
    return &pinecone_images[empty];
}

static struct pinecone_mapping *pinecone_mapping_for(
    const void *address, size_t length
) {
    uintptr_t start = (uintptr_t)address;
    if (start > UINTPTR_MAX - length)
        return NULL;
    uintptr_t end = start + length;
    for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
        uintptr_t mapping_start = (uintptr_t)pinecone_mappings[index].address;
        uintptr_t mapping_end = mapping_start + pinecone_mappings[index].length;
        if (pinecone_mappings[index].address != NULL &&
            start >= mapping_start && end <= mapping_end)
            return &pinecone_mappings[index];
    }
    return NULL;
}

static int pinecone_image_is_simple_locked(pixman_image_t *image) {
    struct pinecone_image_state *state = pinecone_image_state(image, 0);
    return state == NULL || state->unsafe_state == 0;
}

static void pinecone_log_image_state_rejection_locked(
    const struct pinecone_image_state *source,
    const struct pinecone_image_state *destination
) {
    const char *diagnostics = getenv("PINECONE_PIXMAN_DIAGNOSTICS");
    if (diagnostics == NULL || strcmp(diagnostics, "1") != 0)
        return;
    if (__atomic_exchange_n(
            &pinecone_image_state_diagnostic_written, 1, __ATOMIC_RELAXED)) {
        return;
    }
    const pixman_transform_t identity = {
        .matrix = {
            { 1 << 16, 0, 0 },
            { 0, 1 << 16, 0 },
            { 0, 0, 1 << 16 }
        }
    };
    const pixman_transform_t *transform = source != NULL
        ? &source->transform
        : &identity;
    char line[512];
    int length = snprintf(
        line, sizeof(line),
        "pinecone-pixman-state: src(unsafe=%u transform=%d repeat=%d "
        "filter=%d params=%d matrix=%d,%d,%d;%d,%d,%d;%d,%d,%d) "
        "dst(unsafe=%u clip=%d)\n",
        source != NULL ? source->unsafe_state : 0,
        source != NULL ? source->has_transform : 0,
        source != NULL ? source->repeat : PINECONE_REPEAT_NONE,
        source != NULL ? source->filter : PINECONE_FILTER_NEAREST,
        source != NULL ? source->filter_parameter_count : 0,
        transform->matrix[0][0], transform->matrix[0][1],
        transform->matrix[0][2], transform->matrix[1][0],
        transform->matrix[1][1], transform->matrix[1][2],
        transform->matrix[2][0], transform->matrix[2][1],
        transform->matrix[2][2],
        destination != NULL ? destination->unsafe_state : 0,
        destination != NULL && destination->destination_clip != NULL
    );
    if (length <= 0)
        return;
    size_t count = (size_t)length < sizeof(line)
        ? (size_t)length
        : sizeof(line) - 1u;
    pinecone_syscall6(
        PINECONE_SYSCALL_WRITE, STDERR_FILENO, (long)line,
        (long)count, 0, 0, 0);
    int console = open("/dev/ttyAMA0", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (console >= 0) {
        pinecone_syscall6(
            PINECONE_SYSCALL_WRITE, console, (long)line,
            (long)count, 0, 0, 0);
        close(console);
    }
}

static int pinecone_fixed_round_to_int32(int64_t value, int32_t *result) {
    if (value < 0 || value > ((int64_t)INT32_MAX << 16))
        return 0;
    int64_t rounded = (value + (1 << 15)) >> 16;
    if (rounded > INT32_MAX)
        return 0;
    *result = (int32_t)rounded;
    return 1;
}

static int pinecone_source_geometry_locked(
    const struct pinecone_image_state *state,
    int32_t input_x, int32_t input_y, uint32_t output_width,
    uint32_t output_height, int32_t *source_x, int32_t *source_y,
    uint32_t *source_width, uint32_t *source_height, uint32_t *flags,
    unsigned int permitted_unsafe_state
) {
    if (state == NULL) {
        *source_x = input_x;
        *source_y = input_y;
        *source_width = output_width;
        *source_height = output_height;
        return 1;
    }
    if ((state->unsafe_state & ~permitted_unsafe_state) != 0 ||
        (state->repeat != PINECONE_REPEAT_NONE &&
         state->repeat != PINECONE_REPEAT_PAD) ||
        (state->filter != PINECONE_FILTER_NEAREST &&
         state->filter != PINECONE_FILTER_BILINEAR) ||
        state->filter_parameter_count != 0) {
        return 0;
    }
    if (state->filter == PINECONE_FILTER_BILINEAR)
        *flags |= PINECONE_FILTER_BILINEAR_FLAG;
    if (!state->has_transform) {
        *source_x = input_x;
        *source_y = input_y;
        *source_width = output_width;
        *source_height = output_height;
        return 1;
    }

    const pixman_transform_t *transform = &state->transform;
    if (transform->matrix[0][0] <= 0 || transform->matrix[1][1] <= 0 ||
        transform->matrix[0][1] != 0 || transform->matrix[1][0] != 0 ||
        transform->matrix[2][0] != 0 || transform->matrix[2][1] != 0 ||
        transform->matrix[2][2] != (1 << 16)) {
        return 0;
    }

    int64_t left = (int64_t)transform->matrix[0][0] * input_x +
        transform->matrix[0][2];
    int64_t top = (int64_t)transform->matrix[1][1] * input_y +
        transform->matrix[1][2];
    int64_t right = left +
        (int64_t)transform->matrix[0][0] * output_width;
    int64_t bottom = top +
        (int64_t)transform->matrix[1][1] * output_height;
    int32_t rounded_left, rounded_top, rounded_right, rounded_bottom;
    if (!pinecone_fixed_round_to_int32(left, &rounded_left) ||
        !pinecone_fixed_round_to_int32(top, &rounded_top) ||
        !pinecone_fixed_round_to_int32(right, &rounded_right) ||
        !pinecone_fixed_round_to_int32(bottom, &rounded_bottom) ||
        rounded_right <= rounded_left || rounded_bottom <= rounded_top) {
        return 0;
    }
    *source_x = rounded_left;
    *source_y = rounded_top;
    *source_width = (uint32_t)(rounded_right - rounded_left);
    *source_height = (uint32_t)(rounded_bottom - rounded_top);
    return 1;
}

static int pinecone_destination_clip_contains_locked(
    pixman_image_t *image, int32_t x, int32_t y,
    uint32_t width, uint32_t height
) {
    struct pinecone_image_state *state = pinecone_image_state(image, 0);
    if (state == NULL || state->destination_clip == NULL)
        return 1;
    if (real_region32_contains_rectangle == NULL ||
        width > INT32_MAX || height > INT32_MAX ||
        x > INT32_MAX - (int32_t)width || y > INT32_MAX - (int32_t)height)
        return 0;
    pixman_box32_t rectangle = {
        .x1 = x,
        .y1 = y,
        .x2 = x + (int32_t)width,
        .y2 = y + (int32_t)height
    };
    return real_region32_contains_rectangle(
        state->destination_clip, &rectangle) == 1;
}

static int pinecone_graphics_fd_locked(void) {
    int fd = pinecone_existing_graphics_fd_locked();
    if (fd >= 0)
        return fd;
    return pinecone_owned_graphics_fd;
}

static void pinecone_append_handle(
    uint32_t handles[3], uint32_t *count, uint32_t handle
) {
    if (handle == 0)
        return;
    for (uint32_t index = 0; index < *count; index++) {
        if (handles[index] == handle)
            return;
    }
    if (*count < 3u)
        handles[(*count)++] = handle;
}

static int pinecone_submit_locked(
    int graphics_fd, void *payload, uint32_t payload_size,
    uint32_t *handles, uint32_t handle_count
) {
    struct pinecone_drm_execbuffer submit = {
        .flags = PINECONE_EXECBUFFER_FENCE_FD_OUT,
        .size = payload_size,
        .command = (uintptr_t)payload,
        .bo_handles = (uintptr_t)handles,
        .num_bo_handles = handle_count,
        .fence_fd = -1
    };
    int result = pinecone_raw_ioctl(
        graphics_fd,
        PINECONE_IOWR(PINECONE_DRM_COMMAND_BASE +
            PINECONE_DRM_VIRTGPU_EXECBUFFER, struct pinecone_drm_execbuffer),
        &submit
    );
    if (result != 0)
        return result;
    if (submit.fence_fd < 0) {
        errno = EIO;
        return -1;
    }

    struct pollfd fence = {
        .fd = submit.fence_fd,
        .events = POLLIN
    };
    int poll_result;
    do {
        poll_result = poll(&fence, 1, -1);
    } while (poll_result < 0 && errno == EINTR);
    if (poll_result <= 0 || (fence.revents & (POLLERR | POLLNVAL)) != 0)
        result = -1;
    close(submit.fence_fd);
    return result;
}

static void pinecone_reset_batch_locked(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    batch->graphics_fd = -1;
    batch->command_count = 0;
    batch->handle_count = 0;
}

static int pinecone_flush_batch_locked(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (batch->command_count == 0)
        return 0;

    uint32_t byte_count = PINECONE_BATCH_HEADER_SIZE +
        batch->command_count * PINECONE_PAYLOAD_SIZE;
    batch->payload.header.magic = PINECONE_MAGIC;
    batch->payload.header.version = PINECONE_BATCH_VERSION;
    batch->payload.header.command_count = (uint16_t)batch->command_count;
    batch->payload.header.record_size = PINECONE_PAYLOAD_SIZE;
    batch->payload.header.flags = 0;
    batch->payload.header.byte_count = byte_count;
    uint32_t command_count = batch->command_count;
    int result = pinecone_submit_locked(
        batch->graphics_fd, &batch->payload, byte_count,
        batch->handles, batch->handle_count
    );
    pinecone_reset_batch_locked();
    if (result == 0) {
        __atomic_add_fetch(&pinecone_batch_count, 1u, __ATOMIC_RELAXED);
        __atomic_add_fetch(
            &pinecone_batched_command_count, command_count, __ATOMIC_RELAXED);
    }
    return result;
}

static uint32_t pinecone_batch_slot_locked(uint32_t handle) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (handle == 0)
        return 0;
    for (uint32_t index = 0; index < batch->handle_count; index++) {
        if (batch->handles[index] == handle)
            return index + 1u;
    }
    if (batch->handle_count >= PINECONE_MAX_BATCH_HANDLES)
        return 0;
    batch->handles[batch->handle_count] = handle;
    return ++batch->handle_count;
}

static int pinecone_enqueue_locked(
    int graphics_fd, const struct pinecone_2d_payload *payload,
    uint32_t source_handle, uint32_t mask_handle, uint32_t destination_handle
) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (batch->command_count != 0 &&
        (batch->graphics_fd != graphics_fd ||
         batch->command_count >= PINECONE_MAX_BATCH_COMMANDS)) {
        if (pinecone_flush_batch_locked() != 0)
            return 0;
    }
    if (batch->command_count == 0)
        batch->graphics_fd = graphics_fd;

    uint32_t prior_handle_count = batch->handle_count;
    uint32_t source_slot = pinecone_batch_slot_locked(source_handle);
    uint32_t mask_slot = pinecone_batch_slot_locked(mask_handle);
    uint32_t destination_slot = pinecone_batch_slot_locked(destination_handle);
    if ((source_handle != 0 && source_slot == 0) ||
        (mask_handle != 0 && mask_slot == 0) || destination_slot == 0) {
        batch->handle_count = prior_handle_count;
        return 0;
    }

    struct pinecone_2d_payload *record =
        &batch->payload.commands[batch->command_count++];
    *record = *payload;
    record->source_resource_id = source_slot;
    record->mask_resource_id = mask_slot;
    record->destination_resource_id = destination_slot;
    return 1;
}

static int pinecone_try_composite(
    pixman_op_t op, pixman_image_t *source, pixman_image_t *mask,
    pixman_image_t *destination, int32_t source_x, int32_t source_y,
    int32_t mask_x, int32_t mask_y, int32_t destination_x,
    int32_t destination_y,
    uint32_t width, uint32_t height,
    enum pinecone_fallback_reason *fallback_reason
) {
    *fallback_reason = PINECONE_FALLBACK_OPERATION;
    if (op != PINECONE_PIXMAN_OP_CLEAR && op != PINECONE_PIXMAN_OP_SRC &&
        op != PINECONE_PIXMAN_OP_DST && op != PINECONE_PIXMAN_OP_OVER &&
        op != PINECONE_PIXMAN_OP_ADD)
        return 0;
    int source_required = op != PINECONE_PIXMAN_OP_CLEAR &&
        op != PINECONE_PIXMAN_OP_DST;
    if ((source_required && source == NULL) || destination == NULL) {
        *fallback_reason = PINECONE_FALLBACK_SOURCE;
        return 0;
    }
    if (width == 0 || height == 0 || source_x < 0 || source_y < 0 ||
        (mask != NULL && (mask_x < 0 || mask_y < 0)) ||
        destination_x < 0 || destination_y < 0) {
        *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
        return 0;
    }

    uint32_t *destination_data = real_get_data(destination);
    int destination_stride = real_get_stride(destination);
    int destination_width = real_get_width(destination);
    int destination_height = real_get_height(destination);
    pixman_format_code_t destination_format = real_get_format(destination);
    if (destination_data == NULL || destination_stride <= 0 ||
        (destination_format != PINECONE_FORMAT_A8R8G8B8 &&
         destination_format != PINECONE_FORMAT_X8R8G8B8) ||
        destination_x + (int64_t)width > destination_width ||
        destination_y + (int64_t)height > destination_height) {
        *fallback_reason = PINECONE_FALLBACK_DESTINATION;
        return 0;
    }

    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *source_state = pinecone_image_state(source, 0);
    struct pinecone_image_state *mask_state = pinecone_image_state(mask, 0);
    struct pinecone_image_state *destination_state =
        pinecone_image_state(destination, 0);
    if (!pinecone_image_is_simple_locked(destination)) {
        pinecone_log_image_state_rejection_locked(
            source_state, destination_state);
        pthread_mutex_unlock(&pinecone_lock);
        *fallback_reason = PINECONE_FALLBACK_IMAGE_STATE;
        return 0;
    }
    if (!pinecone_destination_clip_contains_locked(
            destination, destination_x, destination_y, width, height)) {
        pthread_mutex_unlock(&pinecone_lock);
        *fallback_reason = PINECONE_FALLBACK_CLIP;
        return 0;
    }
    struct pinecone_mapping *destination_mapping = pinecone_mapping_for(
        destination_data, (size_t)destination_stride * destination_height);
    struct pinecone_upload_surface *destination_upload = NULL;
    int graphics_fd = destination_mapping != NULL
        ? destination_mapping->fd
        : pinecone_graphics_fd_locked();
    if (graphics_fd < 0) {
        pthread_mutex_unlock(&pinecone_lock);
        *fallback_reason = PINECONE_FALLBACK_DESTINATION;
        return 0;
    }
    uint32_t destination_handle;
    if (destination_mapping != NULL) {
        uintptr_t destination_byte_offset =
            (uintptr_t)destination_data - (uintptr_t)destination_mapping->address;
        if (destination_byte_offset % 4 != 0) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
            return 0;
        }
        destination_x += (int32_t)((destination_byte_offset %
            (uintptr_t)destination_stride) / 4);
        destination_y += (int32_t)(destination_byte_offset /
            (uintptr_t)destination_stride);
        destination_handle = destination_mapping->handle;
    } else {
        destination_upload = &pinecone_uploads[PINECONE_UPLOAD_DESTINATION];
        if (!pinecone_ensure_upload_locked(
                destination_upload, graphics_fd,
                (uint32_t)destination_width, (uint32_t)destination_height)) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_UPLOAD;
            return 0;
        }
        const size_t row_bytes = (size_t)width * 4u;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(
                (uint8_t *)destination_upload->address +
                    (size_t)(destination_y + (int32_t)row) *
                        destination_upload->pitch + (size_t)destination_x * 4u,
                (const uint8_t *)destination_data +
                    (size_t)(destination_y + (int32_t)row) *
                        (size_t)destination_stride + (size_t)destination_x * 4u,
                row_bytes
            );
        }
        destination_handle = destination_upload->handle;
    }

    uint32_t source_handle = 0;
    uint32_t solid_color = 0;
    uint32_t flags = 0;
    uint32_t source_width_in_payload = 0;
    uint32_t source_height_in_payload = 0;
    uint16_t operation;
    if (!source_required) {
        operation = (uint16_t)op;
        __atomic_add_fetch(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_DESTINATION_ONLY],
            1u, __ATOMIC_RELAXED);
    } else if (source_state != NULL && source_state->is_solid) {
        solid_color = source_state->solid_color;
        flags |= PINECONE_SOURCE_IS_SOLID;
        operation = (uint16_t)op;
        __atomic_add_fetch(
            &pinecone_geometry_counts[PINECONE_GEOMETRY_SOLID],
            1u, __ATOMIC_RELAXED);
    } else {
        if (!pinecone_source_geometry_locked(
                source_state, source_x, source_y, width, height,
                &source_x, &source_y, &source_width_in_payload,
                &source_height_in_payload, &flags, 0u)) {
            __atomic_add_fetch(
                &pinecone_geometry_counts[PINECONE_GEOMETRY_REJECTED],
                1u, __ATOMIC_RELAXED);
            pinecone_log_image_state_rejection_locked(
                source_state, destination_state);
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_IMAGE_STATE;
            return 0;
        }
        uint32_t *source_data = real_get_data(source);
        int source_stride = real_get_stride(source);
        int source_width = real_get_width(source);
        int source_height = real_get_height(source);
        pixman_format_code_t source_format = real_get_format(source);
        if (source_data == NULL || source_stride <= 0 ||
            (source_format != PINECONE_FORMAT_A8R8G8B8 &&
             source_format != PINECONE_FORMAT_X8R8G8B8) ||
            source_x + (int64_t)source_width_in_payload > source_width ||
            source_y + (int64_t)source_height_in_payload > source_height) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_SOURCE;
            return 0;
        }
        struct pinecone_mapping *source_mapping = pinecone_mapping_for(
            source_data, (size_t)source_stride * source_height);
        if (source_mapping != NULL &&
            source_mapping->fd == graphics_fd &&
            source_mapping->handle != destination_handle) {
            uintptr_t source_byte_offset =
                (uintptr_t)source_data - (uintptr_t)source_mapping->address;
            if (source_byte_offset % 4 != 0) {
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
                return 0;
            }
            source_x += (int32_t)((source_byte_offset %
                (uintptr_t)source_stride) / 4);
            source_y += (int32_t)(source_byte_offset /
                (uintptr_t)source_stride);
            source_handle = source_mapping->handle;
        } else {
            if (!pinecone_upload_pixels_locked(
                    &pinecone_uploads[PINECONE_UPLOAD_SOURCE], graphics_fd,
                    (const uint8_t *)source_data,
                    (size_t)source_stride,
                    (uint32_t)source_x,
                    (uint32_t)source_y,
                    source_width_in_payload,
                    source_height_in_payload)) {
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_UPLOAD;
                return 0;
            }
            source_handle = pinecone_uploads[PINECONE_UPLOAD_SOURCE].handle;
            source_x = 0;
            source_y = 0;
        }
        if (source_format == PINECONE_FORMAT_A8R8G8B8)
            flags |= PINECONE_SOURCE_CONTAINS_ALPHA;
        enum pinecone_geometry_diagnostic geometry =
            source_width_in_payload == width &&
            source_height_in_payload == height
                ? PINECONE_GEOMETRY_IDENTITY
                : ((flags & PINECONE_FILTER_BILINEAR_FLAG) != 0
                    ? PINECONE_GEOMETRY_SCALED_BILINEAR
                    : PINECONE_GEOMETRY_SCALED_NEAREST);
        __atomic_add_fetch(
            &pinecone_geometry_counts[geometry], 1u, __ATOMIC_RELAXED);
        operation = (uint16_t)op;
    }

    uint32_t mask_handle = 0;
    uint32_t mask_alpha = 0;
    if (mask == NULL) {
        __atomic_add_fetch(
            &pinecone_mask_counts[PINECONE_MASK_NONE], 1u, __ATOMIC_RELAXED);
    } else {
        flags |= PINECONE_HAS_MASK;
        if (mask_state != NULL && mask_state->is_solid) {
            __atomic_add_fetch(
                &pinecone_mask_counts[PINECONE_MASK_SOLID],
                1u, __ATOMIC_RELAXED);
            flags |= PINECONE_MASK_IS_SOLID;
            mask_alpha = mask_state->solid_color >> 24u;
        } else {
            int component_alpha = mask_state != NULL &&
                (mask_state->unsafe_state & 128u) != 0;
            if (component_alpha) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_DIAG_COMPONENT_ALPHA],
                    1u, __ATOMIC_RELAXED);
                flags |= PINECONE_MASK_COMPONENT_ALPHA;
            }
            int32_t resolved_mask_x, resolved_mask_y;
            uint32_t resolved_mask_width, resolved_mask_height;
            uint32_t mask_geometry_flags = 0;
            if (!pinecone_source_geometry_locked(
                    mask_state, mask_x, mask_y, width, height,
                    &resolved_mask_x, &resolved_mask_y,
                    &resolved_mask_width, &resolved_mask_height,
                    &mask_geometry_flags, 128u) ||
                mask_geometry_flags != 0 || resolved_mask_width != width ||
                resolved_mask_height != height) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_GEOMETRY_REJECTED],
                    1u, __ATOMIC_RELAXED);
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_MASK;
                return 0;
            }
            uint32_t *mask_data = real_get_data(mask);
            int mask_stride = real_get_stride(mask);
            int mask_width = real_get_width(mask);
            int mask_height = real_get_height(mask);
            pixman_format_code_t mask_format = real_get_format(mask);
            if (mask_format == PINECONE_FORMAT_A8) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_A8],
                    1u, __ATOMIC_RELAXED);
            } else if (mask_format == PINECONE_FORMAT_A8R8G8B8 ||
                       mask_format == PINECONE_FORMAT_X8R8G8B8) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_ARGB],
                    1u, __ATOMIC_RELAXED);
            } else {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_FORMAT_REJECTED],
                    1u, __ATOMIC_RELAXED);
            }
            if (mask_data == NULL || mask_stride <= 0 ||
                (mask_format != PINECONE_FORMAT_A8 &&
                 mask_format != PINECONE_FORMAT_A8R8G8B8 &&
                 mask_format != PINECONE_FORMAT_X8R8G8B8)) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_DATA_REJECTED],
                    1u, __ATOMIC_RELAXED);
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_MASK;
                return 0;
            }
            if (resolved_mask_x < 0 || resolved_mask_y < 0 ||
                resolved_mask_x + (int64_t)width > mask_width ||
                resolved_mask_y + (int64_t)height > mask_height) {
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_BOUNDS_REJECTED],
                    1u, __ATOMIC_RELAXED);
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_MASK;
                return 0;
            }
            struct pinecone_mapping *mask_mapping = pinecone_mapping_for(
                mask_data, (size_t)mask_stride * mask_height);
            if (mask_mapping != NULL && mask_mapping->fd == graphics_fd &&
                mask_mapping->handle != destination_handle &&
                mask_mapping->handle != source_handle &&
                resolved_mask_x == 0 && resolved_mask_y == 0) {
                mask_handle = mask_mapping->handle;
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_DIRECT],
                    1u, __ATOMIC_RELAXED);
                if (mask_format == PINECONE_FORMAT_A8)
                    flags |= PINECONE_MASK_PACKED_A8;
            } else {
                if (!pinecone_upload_mask_locked(
                        &pinecone_uploads[PINECONE_UPLOAD_MASK], graphics_fd,
                        (const uint8_t *)mask_data, (size_t)mask_stride,
                        (uint32_t)resolved_mask_x, (uint32_t)resolved_mask_y,
                        width, height, mask_format, component_alpha)) {
                    __atomic_add_fetch(
                        &pinecone_mask_counts[PINECONE_MASK_ALLOCATION_REJECTED],
                        1u, __ATOMIC_RELAXED);
                    pthread_mutex_unlock(&pinecone_lock);
                    *fallback_reason = PINECONE_FALLBACK_MASK;
                    return 0;
                }
                mask_handle = pinecone_uploads[PINECONE_UPLOAD_MASK].handle;
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_UPLOADED],
                    1u, __ATOMIC_RELAXED);
            }
        }
    }

    struct pinecone_2d_payload payload = {
        .magic = PINECONE_MAGIC,
        .version = PINECONE_EXACT_COMPOSITE_VERSION,
        .operation = operation,
        .flags = flags,
        .source_resource_id = source_handle,
        .destination_resource_id = destination_handle,
        .source_x = source_x,
        .source_y = source_y,
        .destination_x = destination_x,
        .destination_y = destination_y,
        .width = width,
        .height = height,
        .color = solid_color,
        .source_width = source_width_in_payload,
        .source_height = source_height_in_payload,
        .mask_resource_id = mask_handle,
        .mask_alpha = mask_alpha
    };
    uint32_t handles[3] = { 0, 0, 0 };
    uint32_t handle_count = 0;
    pinecone_append_handle(handles, &handle_count, source_handle);
    pinecone_append_handle(handles, &handle_count, mask_handle);
    pinecone_append_handle(handles, &handle_count, destination_handle);
    int uses_reusable_upload =
        (source_handle != 0 &&
         source_handle == pinecone_uploads[PINECONE_UPLOAD_SOURCE].handle) ||
        (mask_handle != 0 &&
         mask_handle == pinecone_uploads[PINECONE_UPLOAD_MASK].handle);
    int batch_eligible = pinecone_thread_batch.depth != 0 &&
        destination_upload == NULL && !uses_reusable_upload &&
        (source_state == NULL || !source_state->cpu_data_exposed) &&
        (mask_state == NULL || !mask_state->cpu_data_exposed) &&
        (destination_state == NULL || !destination_state->cpu_data_exposed);
    int result;
    if (batch_eligible) {
        result = pinecone_enqueue_locked(
            graphics_fd, &payload,
            source_handle, mask_handle, destination_handle
        ) ? 0 : -1;
    } else {
        result = pinecone_flush_batch_locked();
        if (result == 0) {
            result = pinecone_submit_locked(
                graphics_fd, &payload, sizeof(payload), handles, handle_count
            );
        }
    }
    if (result == 0 && destination_upload != NULL) {
        const size_t row_bytes = (size_t)width * 4u;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(
                (uint8_t *)destination_data +
                    (size_t)(destination_y + (int32_t)row) *
                        (size_t)destination_stride + (size_t)destination_x * 4u,
                (const uint8_t *)destination_upload->address +
                    (size_t)(destination_y + (int32_t)row) *
                        destination_upload->pitch + (size_t)destination_x * 4u,
                row_bytes
            );
        }
    }
    pthread_mutex_unlock(&pinecone_lock);
    if (result != 0)
        *fallback_reason = PINECONE_FALLBACK_SUBMIT;
    return result == 0;
}

static pixman_image_t *pinecone_create_bits_image(
    pixman_format_code_t format, int width, int height, uint32_t *bits,
    int rowstride_bytes, int clear, int permit_pixman_fallback
) {
    pinecone_resolve();
    pixman_image_t *(*create_image)(
        pixman_format_code_t, int, int, uint32_t *, int
    ) = clear ? real_create_bits : real_create_bits_no_clear;
    if (create_image == NULL)
        return NULL;

    if (bits != NULL || width <= 0 || height <= 0 ||
        (format != PINECONE_FORMAT_A8R8G8B8 &&
         format != PINECONE_FORMAT_X8R8G8B8 &&
         format != PINECONE_FORMAT_A8)) {
        return permit_pixman_fallback
            ? create_image(format, width, height, bits, rowstride_bytes)
            : NULL;
    }

    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_upload_surface *surface =
        pinecone_allocate_image_surface_locked(
            (uint32_t)width, (uint32_t)height);
    pthread_mutex_unlock(&pinecone_lock);
    if (surface == NULL || surface->pitch > INT_MAX) {
        if (surface != NULL) {
            pthread_mutex_lock(&pinecone_lock);
            pinecone_release_image_surface_locked(surface);
            pthread_mutex_unlock(&pinecone_lock);
        }
        return permit_pixman_fallback
            ? create_image(format, width, height, bits, rowstride_bytes)
            : NULL;
    }

    if (clear)
        memset(surface->address, 0, surface->length);
    pixman_image_t *image = create_image(
        format, width, height, surface->address, (int)surface->pitch);
    if (image == NULL) {
        pthread_mutex_lock(&pinecone_lock);
        pinecone_release_image_surface_locked(surface);
        pthread_mutex_unlock(&pinecone_lock);
        return NULL;
    }

    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (state != NULL)
        state->owned_surface = surface;
    pthread_mutex_unlock(&pinecone_lock);
    if (state == NULL) {
        real_unref(image);
        pthread_mutex_lock(&pinecone_lock);
        pinecone_release_image_surface_locked(surface);
        pthread_mutex_unlock(&pinecone_lock);
        return permit_pixman_fallback
            ? create_image(format, width, height, bits, rowstride_bytes)
            : NULL;
    }
    return image;
}

pixman_image_t *pinecone_pixman_create_bits(
    pixman_format_code_t format, int width, int height, pixman_bool_t clear
) {
    return pinecone_create_bits_image(
        format, width, height, NULL, 0, clear != 0, 0);
}

int pinecone_pixman_export_dmabuf(
    pixman_image_t *image,
    int *dma_buf_fd,
    uint32_t *stride,
    uint64_t *modifier
) {
    pinecone_resolve();
    if (image == NULL || dma_buf_fd == NULL || stride == NULL ||
        modifier == NULL) {
        errno = EINVAL;
        return -1;
    }

    pthread_mutex_lock(&pinecone_lock);
    if (pinecone_flush_batch_locked() != 0) {
        pthread_mutex_unlock(&pinecone_lock);
        return -1;
    }
    struct pinecone_image_state *state = pinecone_image_state(image, 0);
    struct pinecone_upload_surface *surface = state != NULL
        ? state->owned_surface : NULL;
    if (surface == NULL) {
        pthread_mutex_unlock(&pinecone_lock);
        errno = ENOTSUP;
        return -1;
    }
    struct pinecone_drm_prime_handle export = {
        .handle = surface->handle,
        .flags = PINECONE_DRM_CLOEXEC | PINECONE_DRM_RDWR,
        .fd = -1
    };
    int result = pinecone_raw_ioctl(
        surface->fd,
        PINECONE_IOWR(PINECONE_DRM_IOCTL_PRIME_HANDLE_TO_FD_NR,
                      struct pinecone_drm_prime_handle),
        &export);
    if (result == 0 && export.fd >= 0) {
        *dma_buf_fd = export.fd;
        *stride = surface->pitch;
        *modifier = 0;
    } else if (result == 0) {
        result = -1;
        errno = EIO;
    }
    pthread_mutex_unlock(&pinecone_lock);
    return result;
}

pixman_image_t *pixman_image_create_bits(
    pixman_format_code_t format, int width, int height, uint32_t *bits,
    int rowstride_bytes
) {
    return pinecone_create_bits_image(
        format, width, height, bits, rowstride_bytes, 1, 1);
}

pixman_image_t *pixman_image_create_bits_no_clear(
    pixman_format_code_t format, int width, int height, uint32_t *bits,
    int rowstride_bytes
) {
    return pinecone_create_bits_image(
        format, width, height, bits, rowstride_bytes, 0, 1);
}

void pinecone_pixman_created_solid(
    pixman_image_t *image,
    const pixman_color_t *color
) {
    if (image == NULL || color == NULL)
        return;
    uint32_t alpha = (uint32_t)((color->alpha + 128u) / 257u);
    uint32_t red = ((uint32_t)color->red * color->alpha + 0x8000u) / 0xffffu;
    uint32_t green = ((uint32_t)color->green * color->alpha + 0x8000u) / 0xffffu;
    uint32_t blue = ((uint32_t)color->blue * color->alpha + 0x8000u) / 0xffffu;
    red = (red + 128u) / 257u;
    green = (green + 128u) / 257u;
    blue = (blue + 128u) / 257u;

    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (state != NULL) {
        state->is_solid = 1;
        state->solid_color = blue | (green << 8u) | (red << 16u) |
            (alpha << 24u);
    }
    pthread_mutex_unlock(&pinecone_lock);
}

pixman_image_t *pixman_image_create_solid_fill(const pixman_color_t *color) {
    pinecone_resolve();
    if (real_create_solid_fill == NULL)
        return NULL;
    pixman_image_t *image = real_create_solid_fill(color);
    if (image == NULL || color == NULL)
        return image;

    pinecone_pixman_created_solid(image, color);
    return image;
}

void pinecone_pixman_begin_composite(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    batch->depth++;
}

pixman_bool_t pinecone_pixman_end_composite(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (batch->depth == 0)
        return 1;
    --batch->depth;
    return 1;
}

pixman_bool_t pinecone_pixman_composite(
    pixman_op_t op, pixman_image_t *source, pixman_image_t *mask,
    pixman_image_t *destination, int32_t source_x, int32_t source_y,
    int32_t mask_x, int32_t mask_y, int32_t destination_x,
    int32_t destination_y, uint32_t width, uint32_t height
) {
    pinecone_resolve();
    if (real_composite32 == NULL)
        return 0;
    enum pinecone_fallback_reason fallback_reason =
        PINECONE_FALLBACK_OPERATION;
    int accelerated = pinecone_try_composite(
        op, source, mask, destination, source_x, source_y,
        mask_x, mask_y, destination_x, destination_y,
        width, height, &fallback_reason
    );
    if (!accelerated && pinecone_thread_batch.command_count != 0) {
        pthread_mutex_lock(&pinecone_lock);
        if (pinecone_flush_batch_locked() != 0)
            fallback_reason = PINECONE_FALLBACK_SUBMIT;
        pthread_mutex_unlock(&pinecone_lock);
    }
    pinecone_record_composite(
        op, accelerated, fallback_reason, width, height);
    return accelerated;
}

void pixman_image_composite32(
    pixman_op_t op, pixman_image_t *source, pixman_image_t *mask,
    pixman_image_t *destination, int32_t source_x, int32_t source_y,
    int32_t mask_x, int32_t mask_y, int32_t destination_x,
    int32_t destination_y, uint32_t width, uint32_t height
) {
    pinecone_resolve();
    if (real_composite32 == NULL)
        return;
    // The patched Pixman core owns clipping and opens a transaction around its
    // complete pbox list. Entering through it is what allows those rectangles
    // to share one v4 submission without changing Pixman's public ABI.
    real_composite32(op, source, mask, destination, source_x, source_y,
                     mask_x, mask_y, destination_x, destination_y,
                     width, height);
}

uint32_t *pixman_image_get_data(pixman_image_t *image) {
    pinecone_resolve();
    if (real_get_data == NULL)
        return NULL;
    pthread_mutex_lock(&pinecone_lock);
    int result = pinecone_flush_batch_locked();
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (state != NULL)
        state->cpu_data_exposed = 1;
    pthread_mutex_unlock(&pinecone_lock);
    return result == 0 ? real_get_data(image) : NULL;
}

__attribute__((destructor))
static void pinecone_pixman_shutdown(void) {
    pthread_mutex_lock(&pinecone_lock);
    pinecone_flush_batch_locked();
    for (size_t index = 0; index < PINECONE_UPLOAD_COUNT; index++)
        pinecone_release_upload_locked(&pinecone_uploads[index]);
    if (pinecone_owned_graphics_fd >= 0) {
        close(pinecone_owned_graphics_fd);
        pinecone_owned_graphics_fd = -1;
    }
    pthread_mutex_unlock(&pinecone_lock);
}

static void pinecone_set_image_unsafe(
    pixman_image_t *image, unsigned int bit, int enabled
) {
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (state != NULL) {
        if (enabled)
            state->unsafe_state |= bit;
        else
            state->unsafe_state &= ~bit;
    }
    pthread_mutex_unlock(&pinecone_lock);
}

pixman_bool_t pixman_image_set_transform(
    pixman_image_t *image, const pixman_transform_t *transform
) {
    pinecone_resolve();
    if (real_set_transform == NULL)
        return 0;
    pixman_bool_t result = real_set_transform(image, transform);
    if (result) {
        int is_identity = transform == NULL || (
            transform->matrix[0][0] == (1 << 16) &&
            transform->matrix[0][1] == 0 &&
            transform->matrix[0][2] == 0 &&
            transform->matrix[1][0] == 0 &&
            transform->matrix[1][1] == (1 << 16) &&
            transform->matrix[1][2] == 0 &&
            transform->matrix[2][0] == 0 &&
            transform->matrix[2][1] == 0 &&
            transform->matrix[2][2] == (1 << 16)
        );
        pthread_mutex_lock(&pinecone_lock);
        struct pinecone_image_state *state = pinecone_image_state(image, 1);
        if (state != NULL) {
            state->has_transform = !is_identity;
            if (transform != NULL)
                state->transform = *transform;
        }
        pthread_mutex_unlock(&pinecone_lock);
    }
    return result;
}

void pixman_image_set_repeat(pixman_image_t *image, int repeat) {
    pinecone_resolve();
    if (real_set_repeat == NULL)
        return;
    real_set_repeat(image, repeat);
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (state != NULL)
        state->repeat = repeat;
    pthread_mutex_unlock(&pinecone_lock);
}

pixman_bool_t pixman_image_set_filter(
    pixman_image_t *image, int filter, const int32_t *parameters, int count
) {
    pinecone_resolve();
    if (real_set_filter == NULL)
        return 0;
    pixman_bool_t result = real_set_filter(image, filter, parameters, count);
    if (result) {
        pthread_mutex_lock(&pinecone_lock);
        struct pinecone_image_state *state = pinecone_image_state(image, 1);
        if (state != NULL) {
            state->filter = filter;
            state->filter_parameter_count = count;
        }
        pthread_mutex_unlock(&pinecone_lock);
    }
    return result;
}

pixman_bool_t pixman_image_set_clip_region32(
    pixman_image_t *image, pixman_region32_t *region
) {
    pinecone_resolve();
    if (real_set_clip_region32 == NULL)
        return 0;
    pixman_bool_t result = real_set_clip_region32(image, region);
    if (!result)
        return result;

    pixman_region32_t *replacement = NULL;
    int replacement_failed = 0;
    if (region != NULL) {
        if (real_region32_init != NULL && real_region32_copy != NULL) {
            replacement = malloc(sizeof(*replacement));
            if (replacement != NULL)
                real_region32_init(replacement);
        }
        if (replacement == NULL || !real_region32_copy(replacement, region)) {
            if (replacement != NULL) {
                if (real_region32_fini != NULL)
                    real_region32_fini(replacement);
                free(replacement);
            }
            replacement = NULL;
            replacement_failed = 1;
        }
    }

    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    pixman_region32_t *previous = state != NULL
        ? state->destination_clip
        : NULL;
    if (state != NULL) {
        state->destination_clip = replacement;
        if (replacement_failed)
            state->unsafe_state |= 8u;
        else
            state->unsafe_state &= ~8u;
    } else if (replacement != NULL) {
        previous = replacement;
    }
    pthread_mutex_unlock(&pinecone_lock);
    if (previous != NULL) {
        if (real_region32_fini != NULL)
            real_region32_fini(previous);
        free(previous);
    }
    return result;
}

pixman_bool_t pixman_image_set_clip_region(
    pixman_image_t *image, pixman_region16_t *region
) {
    pinecone_resolve();
    if (real_set_clip_region == NULL)
        return 0;
    pixman_bool_t result = real_set_clip_region(image, region);
    if (result)
        pinecone_set_image_unsafe(image, 64u, region != NULL);
    return result;
}

void pixman_image_set_alpha_map(
    pixman_image_t *image, pixman_image_t *alpha_map, int16_t x, int16_t y
) {
    pinecone_resolve();
    if (real_set_alpha_map == NULL)
        return;
    real_set_alpha_map(image, alpha_map, x, y);
    pinecone_set_image_unsafe(image, 16u, alpha_map != NULL);
}

void pixman_image_set_source_clipping(
    pixman_image_t *image, pixman_bool_t source_clipping
) {
    pinecone_resolve();
    if (real_set_source_clipping == NULL)
        return;
    real_set_source_clipping(image, source_clipping);
    pinecone_set_image_unsafe(image, 32u, source_clipping != 0);
}

void pixman_image_set_component_alpha(
    pixman_image_t *image, pixman_bool_t component_alpha
) {
    pinecone_resolve();
    if (real_set_component_alpha == NULL)
        return;
    real_set_component_alpha(image, component_alpha);
    pinecone_set_image_unsafe(image, 128u, component_alpha != 0);
}

pixman_bool_t pixman_image_unref(pixman_image_t *image) {
    pinecone_resolve();
    if (real_unref == NULL)
        return 0;
    pthread_mutex_lock(&pinecone_lock);
    int flush_result = pinecone_flush_batch_locked();
    pthread_mutex_unlock(&pinecone_lock);
    if (flush_result != 0)
        return 0;
    pixman_bool_t destroyed = real_unref(image);
    if (!destroyed)
        return 0;

    pixman_region32_t *destination_clip = NULL;
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 0);
    if (state != NULL) {
        destination_clip = state->destination_clip;
        pinecone_release_image_surface_locked(state->owned_surface);
        state->image = (pixman_image_t *)(uintptr_t)1;
        state->unsafe_state = 0;
        state->has_transform = 0;
        state->repeat = PINECONE_REPEAT_NONE;
        state->filter = PINECONE_FILTER_NEAREST;
        state->filter_parameter_count = 0;
        state->solid_color = 0;
        state->is_solid = 0;
        state->cpu_data_exposed = 0;
        state->destination_clip = NULL;
        state->owned_surface = NULL;
    }
    pthread_mutex_unlock(&pinecone_lock);
    if (destination_clip != NULL) {
        if (real_region32_fini != NULL)
            real_region32_fini(destination_clip);
        free(destination_clip);
    }
    return destroyed;
}

int ioctl(int fd, int request, ...) {
    void *argument;
    __builtin_va_list arguments;
    __builtin_va_start(arguments, request);
    argument = __builtin_va_arg(arguments, void *);
    __builtin_va_end(arguments);
    if (pinecone_thread_batch.command_count != 0 &&
        pinecone_thread_batch.graphics_fd == fd) {
        pthread_mutex_lock(&pinecone_lock);
        int flush_result = pinecone_flush_batch_locked();
        pthread_mutex_unlock(&pinecone_lock);
        if (flush_result != 0)
            return -1;
    }
    int result = (int)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_IOCTL, fd, request, (long)argument, 0, 0, 0));
    if (result == 0 && (uint32_t)request == PINECONE_IOWR(
            PINECONE_DRM_IOCTL_MODE_MAP_DUMB_NR,
            struct pinecone_drm_mode_map_dumb)) {
        struct pinecone_drm_mode_map_dumb *map = argument;
        pthread_mutex_lock(&pinecone_lock);
        for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
            if (pinecone_pending_mappings[index].handle == 0) {
                pinecone_pending_mappings[index].fd = fd;
                pinecone_pending_mappings[index].handle = map->handle;
                pinecone_pending_mappings[index].offset = map->offset;
                break;
            }
        }
        pthread_mutex_unlock(&pinecone_lock);
    }
    return result;
}

void *mmap(void *address, size_t length, int protection, int flags,
           int fd, off_t offset) {
    void *mapping = (void *)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_MMAP, (long)address, (long)length, protection,
        flags, fd, offset));
    if (mapping == MAP_FAILED)
        return mapping;

    pthread_mutex_lock(&pinecone_lock);
    for (size_t pending = 0; pending < PINECONE_MAX_MAPPINGS; pending++) {
        if (pinecone_pending_mappings[pending].handle != 0 &&
            pinecone_pending_mappings[pending].fd == fd &&
            pinecone_pending_mappings[pending].offset == (uint64_t)offset) {
            for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
                if (pinecone_mappings[index].address == NULL) {
                    pinecone_mappings[index].address = mapping;
                    pinecone_mappings[index].length = length;
                    pinecone_mappings[index].fd = fd;
                    pinecone_mappings[index].handle =
                        pinecone_pending_mappings[pending].handle;
                    break;
                }
            }
            memset(&pinecone_pending_mappings[pending], 0,
                   sizeof(pinecone_pending_mappings[pending]));
            break;
        }
    }
    pthread_mutex_unlock(&pinecone_lock);
    return mapping;
}

int munmap(void *address, size_t length) {
    pthread_mutex_lock(&pinecone_lock);
    if (pinecone_flush_batch_locked() != 0) {
        pthread_mutex_unlock(&pinecone_lock);
        return -1;
    }
    for (size_t index = 0; index < PINECONE_MAX_MAPPINGS; index++) {
        if (pinecone_mappings[index].address == address) {
            memset(&pinecone_mappings[index], 0, sizeof(pinecone_mappings[index]));
            break;
        }
    }
    pthread_mutex_unlock(&pinecone_lock);
    return (int)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_MUNMAP, (long)address, (long)length, 0, 0, 0, 0));
}
