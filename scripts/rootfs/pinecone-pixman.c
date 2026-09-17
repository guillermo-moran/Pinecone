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
    PINECONE_PIXMAN_OP_OVER_REVERSE = 4,
    PINECONE_PIXMAN_OP_IN = 5,
    PINECONE_PIXMAN_OP_IN_REVERSE = 6,
    PINECONE_PIXMAN_OP_OUT = 7,
    PINECONE_PIXMAN_OP_OUT_REVERSE = 8,
    PINECONE_PIXMAN_OP_ATOP = 9,
    PINECONE_PIXMAN_OP_ATOP_REVERSE = 10,
    PINECONE_PIXMAN_OP_XOR = 11,
    PINECONE_PIXMAN_OP_ADD = 12,
    PINECONE_PIXMAN_OP_SATURATE = 13,
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
    PINECONE_SOURCE_PACKED_A8 = 1u << 7,
    PINECONE_DESTINATION_PACKED_A8 = 1u << 8,
    PINECONE_DRM_CLOEXEC = 1u << 0,
    PINECONE_DRM_RDWR = 1u << 1,
    PINECONE_EXECBUFFER_FENCE_FD_OUT = 1u << 1,
    PINECONE_PAYLOAD_SIZE = 64,
    PINECONE_BATCH_HEADER_SIZE = 16,
    PINECONE_MAX_BATCH_COMMANDS = 64,
    PINECONE_MAX_BATCH_HANDLES = PINECONE_MAX_BATCH_COMMANDS * 3,
    PINECONE_MAX_IN_FLIGHT_BATCHES = 3,
    PINECONE_OPERATOR_COUNT = 64,
    PINECONE_INITIAL_IMAGE_CAPACITY = 1024,
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

struct pinecone_fence_use {
    struct pinecone_fence_use *next;
    int fd;
    int graphics_fd;
    uint32_t count;
    uint32_t handles[PINECONE_MAX_BATCH_HANDLES];
};

struct pinecone_pending_batch {
    struct pinecone_fence_use *use;
    int fence_fd;
    int graphics_fd;
    uint32_t image_count;
    pixman_image_t *images[PINECONE_MAX_BATCH_HANDLES];
};

struct pinecone_thread_batch {
    unsigned int depth;
    int graphics_fd;
    uint32_t command_count;
    uint32_t handle_count;
    uint32_t handles[PINECONE_MAX_BATCH_HANDLES];
    uint32_t image_count;
    pixman_image_t *images[PINECONE_MAX_BATCH_HANDLES];
    uint32_t pending_head;
    uint32_t pending_count;
    struct pinecone_pending_batch pending[PINECONE_MAX_IN_FLIGHT_BATCHES];
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
    uint32_t scoped_cpu_access_count;
    uint64_t cpu_generation;
    int cpu_data_unbounded;
    pixman_region32_t *destination_clip;
    struct pinecone_upload_surface *owned_surface;
    struct pinecone_upload_surface *source_cache;
    struct pinecone_upload_surface *mask_cache;
    struct pinecone_upload_surface *source_spares[2];
    struct pinecone_upload_surface *mask_spares[2];
    uint64_t source_cache_generation;
    uint64_t mask_cache_generation;
    uint32_t mask_cache_x;
    uint32_t mask_cache_y;
    uint32_t mask_cache_width;
    uint32_t mask_cache_height;
    pixman_format_code_t mask_cache_format;
    int mask_cache_component_alpha;
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
static size_t pinecone_mapping_count;
static struct pinecone_pending_mapping pinecone_pending_mappings[PINECONE_MAX_MAPPINGS];
static struct pinecone_image_state **pinecone_images;
#define PINECONE_IMAGE_TOMBSTONE ((struct pinecone_image_state *)(uintptr_t)1)
static size_t pinecone_image_capacity;
static size_t pinecone_image_count;
static size_t pinecone_image_tombstones;
enum pinecone_upload_kind {
    PINECONE_UPLOAD_SOURCE,
    PINECONE_UPLOAD_MASK,
    PINECONE_UPLOAD_DESTINATION,
    PINECONE_UPLOAD_COUNT
};

/* Synchronous scratch copyback belongs to the calling thread, not the process. */
static _Thread_local struct pinecone_upload_surface pinecone_uploads[PINECONE_UPLOAD_COUNT];
static pthread_key_t pinecone_scratch_key;
static pthread_once_t pinecone_scratch_once = PTHREAD_ONCE_INIT;
static int pinecone_scratch_key_error;
static void pinecone_scratch_destroy(void *value);
static void pinecone_scratch_key_init(void) {
    pinecone_scratch_key_error = pthread_key_create(&pinecone_scratch_key, pinecone_scratch_destroy);
}
static _Thread_local int pinecone_thread_registered;
static int pinecone_register_thread(void) {
    if (pinecone_thread_registered) return 1;
    pthread_once(&pinecone_scratch_once, pinecone_scratch_key_init);
    int error = pinecone_scratch_key_error;
    if (error == 0) error = pthread_setspecific(pinecone_scratch_key, pinecone_uploads);
    if (error != 0) { errno = error; return 0; }
    pinecone_thread_registered = 1;
    return 1;
}
static int pinecone_owned_graphics_fd = -1;
static int pinecone_packed_a8_enabled = 1;
static uint64_t pinecone_composite_count;
static uint64_t pinecone_accelerated_count;
static uint64_t pinecone_accelerated_pixels;
static uint64_t pinecone_fallback_counts[PINECONE_FALLBACK_REASON_COUNT];
static uint64_t pinecone_shared_surface_count;
static uint64_t pinecone_live_shared_surfaces;
static uint64_t pinecone_live_shared_bytes;
static size_t pinecone_spare_bytes;
static uint64_t pinecone_cache_rotations;
static const size_t pinecone_spare_budget = 16u * 1024u * 1024u;
static uint64_t pinecone_mapped_surface_count;
static uint64_t pinecone_live_mapped_surfaces;
static uint64_t pinecone_live_mapped_bytes;
static uint64_t pinecone_batch_count;
static uint64_t pinecone_batched_command_count;
static uint64_t pinecone_batch_sizes[6];
static uint64_t pinecone_batch_candidate_count;
static uint64_t pinecone_batch_rejection_upload_count;
static uint64_t pinecone_batch_rejection_hazard_count;
static uint64_t pinecone_batch_rejection_scope_count;
static uint64_t pinecone_render_pass_count;
static uint64_t pinecone_operator_counts[PINECONE_OPERATOR_COUNT];
static uint64_t pinecone_accelerated_operator_counts[PINECONE_OPERATOR_COUNT];
static uint64_t pinecone_enabled_operator_mask = UINT64_C(0x100f);
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
static _Thread_local struct pinecone_thread_batch pinecone_thread_batch = {
    .graphics_fd = -1
};
static _Thread_local unsigned int pinecone_render_pass_depth;
static _Thread_local struct {
    unsigned int depth;
    uint32_t flags[64];
    uint32_t image_count;
    int retention_failed;
    pixman_image_t *images[PINECONE_MAX_BATCH_HANDLES];
    uint32_t image_flags[PINECONE_MAX_BATCH_HANDLES];
} pinecone_cpu_access_scope;

static int pinecone_flush_batch_locked(void);
static struct pinecone_fence_use *pinecone_fence_uses;
static int pinecone_wait_handle_locked(int fd, uint32_t handle);
static int pinecone_handle_pending_locked(int fd, uint32_t handle);

static void (*real_composite32)(pixman_op_t, pixman_image_t *, pixman_image_t *,
    pixman_image_t *, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    uint32_t, uint32_t);
static uint32_t *(*real_get_data)(pixman_image_t *);
static int (*real_get_stride)(pixman_image_t *);
static int (*real_get_width)(pixman_image_t *);
static int (*real_get_height)(pixman_image_t *);
static pixman_format_code_t (*real_get_format)(pixman_image_t *);
static pixman_bool_t (*real_unref)(pixman_image_t *);
static pixman_image_t *(*real_ref)(pixman_image_t *);
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
static pixman_bool_t (*real_fill)(
    uint32_t *, int, int, int, int, int, int, uint32_t);

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

static size_t pinecone_mapping_lower_bound_locked(uintptr_t address) {
    size_t lower = 0;
    size_t upper = pinecone_mapping_count;
    while (lower < upper) {
        size_t middle = lower + (upper - lower) / 2;
        if ((uintptr_t)pinecone_mappings[middle].address < address)
            lower = middle + 1;
        else
            upper = middle;
    }
    return lower;
}

static struct pinecone_mapping *pinecone_exact_mapping_locked(void *address) {
    size_t index = pinecone_mapping_lower_bound_locked((uintptr_t)address);
    if (index < pinecone_mapping_count &&
        pinecone_mappings[index].address == address)
        return &pinecone_mappings[index];
    return NULL;
}

static void pinecone_remove_mapping_at_locked(size_t index) {
    if (index >= pinecone_mapping_count)
        return;
    if (index + 1 < pinecone_mapping_count) {
        memmove(&pinecone_mappings[index], &pinecone_mappings[index + 1],
                (pinecone_mapping_count - index - 1) *
                    sizeof(pinecone_mappings[0]));
    }
    --pinecone_mapping_count;
    memset(&pinecone_mappings[pinecone_mapping_count], 0,
           sizeof(pinecone_mappings[0]));
}

static void pinecone_forget_mapping_locked(void *address) {
    size_t index = pinecone_mapping_lower_bound_locked((uintptr_t)address);
    if (index < pinecone_mapping_count &&
        pinecone_mappings[index].address == address)
        pinecone_remove_mapping_at_locked(index);
}

static int pinecone_record_mapping_locked(
    void *address, size_t length, int fd, uint32_t handle
) {
    uintptr_t start = (uintptr_t)address;
    if (address == NULL || length == 0 || start > UINTPTR_MAX - length ||
        pinecone_mapping_count == PINECONE_MAX_MAPPINGS)
        return 0;
    uintptr_t end = start + length;
    size_t index = pinecone_mapping_lower_bound_locked(start);
    if (index < pinecone_mapping_count &&
        pinecone_mappings[index].address == address) {
        pinecone_mappings[index] = (struct pinecone_mapping) {
            .address = address, .length = length, .fd = fd, .handle = handle
        };
        return 1;
    }
    if (index != 0) {
        const struct pinecone_mapping *previous = &pinecone_mappings[index - 1];
        uintptr_t previous_end =
            (uintptr_t)previous->address + previous->length;
        if (start < previous_end)
            return 0;
    }
    if (index < pinecone_mapping_count &&
        end > (uintptr_t)pinecone_mappings[index].address)
        return 0;
    if (index < pinecone_mapping_count) {
        memmove(&pinecone_mappings[index + 1], &pinecone_mappings[index],
                (pinecone_mapping_count - index) *
                    sizeof(pinecone_mappings[0]));
    }
    pinecone_mappings[index] = (struct pinecone_mapping) {
        .address = address, .length = length, .fd = fd, .handle = handle
    };
    ++pinecone_mapping_count;
    return 1;
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
    for (size_t i = 0; i < PINECONE_UPLOAD_COUNT; ++i) {
        if (upload != &pinecone_uploads[i]) continue;
        if (!pinecone_register_thread()) return 0;
        break;
    }
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
    if (pinecone_mapping_count != 0)
        return pinecone_mappings[0].fd;
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

static int pinecone_batch_uses_handle_locked(uint32_t handle) {
    if (handle == 0)
        return 0;
    const struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    for (uint32_t index = 0; index < batch->handle_count; index++) {
        if (batch->handles[index] == handle)
            return 1;
    }
    return 0;
}

static int pinecone_upload_pixels_locked(
    struct pinecone_upload_surface *upload,
    int fd,
    const uint8_t *source,
    size_t source_stride,
    uint32_t source_x,
    uint32_t source_y,
    uint32_t width,
    uint32_t height,
    size_t bytes_per_pixel
) {
    if ((bytes_per_pixel != 1u && bytes_per_pixel != 4u) ||
        !pinecone_ensure_upload_locked(upload, fd, width, height))
        return 0;
    if (pinecone_wait_handle_locked(fd, upload->handle) != 0)
        return 0;
    const size_t row_bytes = (size_t)width * bytes_per_pixel;
    for (uint32_t row = 0; row < height; row++) {
        memcpy(
            (uint8_t *)upload->address + (size_t)row * upload->pitch,
            source + (size_t)(source_y + row) * source_stride +
                (size_t)source_x * bytes_per_pixel,
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
    if (pinecone_wait_handle_locked(fd, upload->handle) != 0)
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

static int pinecone_rotate_cache_locked(struct pinecone_upload_surface **current,
    struct pinecone_upload_surface **spares, int fd, uint32_t width, uint32_t height) {
    struct pinecone_upload_surface *old = *current;
    int pending = pinecone_handle_pending_locked(fd, old->handle);
    if (pending < 0) return 0;
    if (!pending && !pinecone_batch_uses_handle_locked(old->handle)) return 1;
    for (size_t i = 0; i < 2; ++i) {
        struct pinecone_upload_surface *spare = spares[i];
        if (spare == NULL || spare->fd != fd || spare->width < width || spare->height < height ||
            pinecone_batch_uses_handle_locked(spare->handle) ||
            pinecone_handle_pending_locked(fd, spare->handle) != 0) continue;
        if (pinecone_spare_bytes - spare->length + old->length > pinecone_spare_budget) continue;
        pinecone_spare_bytes = pinecone_spare_bytes - spare->length + old->length;
        *current = spare;
        spares[i] = old;
        ++pinecone_cache_rotations;
        return 1;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (spares[i] != NULL || old->length > pinecone_spare_budget - pinecone_spare_bytes) continue;
        struct pinecone_upload_surface *spare = pinecone_allocate_image_surface_locked(width, height);
        if (spare == NULL) break;
        if (spare->fd != fd) { pinecone_release_image_surface_locked(spare); break; }
        spares[i] = old;
        *current = spare;
        pinecone_spare_bytes += old->length;
        ++pinecone_cache_rotations;
        return 1;
    }
    // Bounded storage exhaustion applies backpressure only to this resource.
    if (pinecone_batch_uses_handle_locked(old->handle) && pinecone_flush_batch_locked() != 0) return 0;
    return pinecone_wait_handle_locked(fd, old->handle) == 0;
}

static void pinecone_release_spares_locked(struct pinecone_image_state *state) {
    for (size_t i = 0; i < 2; ++i) {
        if (state->source_spares[i] != NULL) {
            pinecone_spare_bytes -= state->source_spares[i]->length;
            pinecone_release_image_surface_locked(state->source_spares[i]);
        }
        if (state->mask_spares[i] != NULL) {
            pinecone_spare_bytes -= state->mask_spares[i]->length;
            pinecone_release_image_surface_locked(state->mask_spares[i]);
        }
    }
}

static struct pinecone_upload_surface *pinecone_prepare_source_cache_locked(
    struct pinecone_image_state *state,
    int fd,
    const uint8_t *source,
    size_t source_stride,
    uint32_t width,
    uint32_t height,
    size_t bytes_per_pixel
) {
    if (state == NULL)
        return NULL;
    if (state->source_cache == NULL) {
        state->source_cache = pinecone_allocate_image_surface_locked(
            width, height);
        if (state->source_cache == NULL)
            return NULL;
        state->source_cache_generation = UINT64_MAX;
    }
    struct pinecone_upload_surface *cache = state->source_cache;
    if (cache->fd != fd || cache->width < width || cache->height < height)
        return NULL;
    if (!state->cpu_data_unbounded && state->scoped_cpu_access_count == 0 &&
        state->owned_surface == NULL &&
        state->source_cache_generation == state->cpu_generation)
        return cache;

    if (!pinecone_rotate_cache_locked(&state->source_cache, state->source_spares, fd, width, height))
        return NULL;
    cache = state->source_cache;
    if (!pinecone_upload_pixels_locked(
            cache, fd, source, source_stride, 0, 0,
            width, height, bytes_per_pixel))
        return NULL;
    state->source_cache_generation = state->cpu_generation;
    return cache;
}

static struct pinecone_upload_surface *pinecone_prepare_mask_cache_locked(
    struct pinecone_image_state *state,
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
    if (state == NULL)
        return NULL;
    int cache_matches = !state->cpu_data_unbounded &&
        state->scoped_cpu_access_count == 0 && state->owned_surface == NULL &&
        state->mask_cache != NULL &&
        state->mask_cache_generation == state->cpu_generation &&
        state->mask_cache_x == source_x &&
        state->mask_cache_y == source_y &&
        state->mask_cache_width == width &&
        state->mask_cache_height == height &&
        state->mask_cache_format == format &&
        state->mask_cache_component_alpha == component_alpha;
    if (cache_matches)
        return state->mask_cache;
    if (state->mask_cache == NULL) {
        state->mask_cache = pinecone_allocate_image_surface_locked(
            width, height);
        if (state->mask_cache == NULL)
            return NULL;
    }
    struct pinecone_upload_surface *cache = state->mask_cache;
    if (cache->fd != fd || cache->width < width || cache->height < height)
        return NULL;
    if (!pinecone_rotate_cache_locked(&state->mask_cache, state->mask_spares, fd, width, height))
        return NULL;
    cache = state->mask_cache;
    if (!pinecone_upload_mask_locked(
            cache, fd, source, source_stride, source_x, source_y,
            width, height, format, component_alpha))
        return NULL;
    state->mask_cache_generation = state->cpu_generation;
    state->mask_cache_x = source_x;
    state->mask_cache_y = source_y;
    state->mask_cache_width = width;
    state->mask_cache_height = height;
    state->mask_cache_format = format;
    state->mask_cache_component_alpha = component_alpha;
    return cache;
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

    char line[640];
    int length = snprintf(
        line, sizeof(line),
        "pinecone-pixman: total=%llu accelerated=%llu pixels=%llu "
        "fallback(op=%llu mask=%llu geometry=%llu destination=%llu "
        "state=%llu clip=%llu source=%llu upload=%llu submit=%llu) "
        "shared(created=%llu live=%llu bytes=%llu) "
        "mapped(created=%llu live=%llu bytes=%llu) "
        "batch=%llu/%llu candidate=%llu reject(upload=%llu hazard=%llu "
        "scope=%llu) pass=%llu sizes(1/2-4/5-16/17-64/65-256/257+)="
        "%llu/%llu/%llu/%llu/%llu/%llu\n",
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
            &pinecone_mapped_surface_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_live_mapped_surfaces, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_live_mapped_bytes, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batched_command_count, __ATOMIC_RELAXED)
        ,
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_candidate_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_rejection_upload_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_rejection_hazard_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_batch_rejection_scope_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(
            &pinecone_render_pass_count, __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[0], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[1], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[2], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[3], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[4], __ATOMIC_RELAXED),
        (unsigned long long)__atomic_load_n(&pinecone_batch_sizes[5], __ATOMIC_RELAXED)
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
    const char *packed_a8 = getenv("PINECONE_PIXMAN_PACKED_A8");
    pinecone_packed_a8_enabled = packed_a8 == NULL ||
        strcmp(packed_a8, "0") != 0;
    real_get_data = dlsym(RTLD_NEXT, "pixman_image_get_data");
    real_get_stride = dlsym(RTLD_NEXT, "pixman_image_get_stride");
    real_get_width = dlsym(RTLD_NEXT, "pixman_image_get_width");
    real_get_height = dlsym(RTLD_NEXT, "pixman_image_get_height");
    real_get_format = dlsym(RTLD_NEXT, "pixman_image_get_format");
    real_unref = dlsym(RTLD_NEXT, "pixman_image_unref");
    real_ref = dlsym(RTLD_NEXT, "pixman_image_ref");
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
    real_fill = dlsym(RTLD_NEXT, "pixman_fill");
    const char *operator_mask = getenv("PINECONE_PIXMAN_OPERATOR_MASK");
    if (operator_mask != NULL && *operator_mask != '\0') {
        char *end = NULL;
        errno = 0;
        unsigned long long parsed = strtoull(operator_mask, &end, 0);
        if (errno == 0 && end != operator_mask && *end == '\0')
            pinecone_enabled_operator_mask =
                (uint64_t)parsed & UINT64_C(0x3fff);
    }
}

static void pinecone_resolve(void) {
    pthread_once(&pinecone_resolve_once, pinecone_resolve_symbols);
}

static size_t pinecone_image_hash(pixman_image_t *image) {
    uintptr_t value = (uintptr_t)image >> 4;
#if UINTPTR_MAX > UINT32_MAX
    value ^= value >> 33;
    value *= UINT64_C(0xff51afd7ed558ccd);
    value ^= value >> 33;
    value *= UINT64_C(0xc4ceb9fe1a85ec53);
    value ^= value >> 33;
#else
    value ^= value >> 16;
    value *= UINT32_C(0x7feb352d);
    value ^= value >> 15;
#endif
    return (size_t)value;
}

static int pinecone_rehash_images_locked(size_t requested_capacity) {
    size_t capacity = PINECONE_INITIAL_IMAGE_CAPACITY;
    while (capacity < requested_capacity) {
        if (capacity > SIZE_MAX / 2)
            return 0;
        capacity *= 2;
    }
    struct pinecone_image_state **replacement =
        calloc(capacity, sizeof(*replacement));
    if (replacement == NULL)
        return 0;

    for (size_t old_index = 0; old_index < pinecone_image_capacity;
         old_index++) {
        struct pinecone_image_state *state = pinecone_images[old_index];
        if (state == NULL || state == PINECONE_IMAGE_TOMBSTONE)
            continue;
        size_t index = pinecone_image_hash(state->image) & (capacity - 1);
        while (replacement[index] != NULL)
            index = (index + 1) & (capacity - 1);
        replacement[index] = state;
    }
    free(pinecone_images);
    pinecone_images = replacement;
    pinecone_image_capacity = capacity;
    pinecone_image_tombstones = 0;
    return 1;
}

static int pinecone_prepare_image_insert_locked(void) {
    if (pinecone_image_capacity == 0)
        return pinecone_rehash_images_locked(PINECONE_INITIAL_IMAGE_CAPACITY);

    size_t occupied = pinecone_image_count + pinecone_image_tombstones;
    if ((occupied + 1) * 4 < pinecone_image_capacity * 3)
        return 1;
    size_t target_capacity = pinecone_image_capacity;
    if ((pinecone_image_count + 1) * 2 >= pinecone_image_capacity)
        target_capacity *= 2;
    return pinecone_rehash_images_locked(target_capacity);
}

static struct pinecone_image_state *pinecone_image_state(
    pixman_image_t *image, int create
) {
    if (image == NULL)
        return NULL;
    if (pinecone_image_capacity == 0 &&
        (!create || !pinecone_prepare_image_insert_locked()))
        return NULL;

    if (create && !pinecone_prepare_image_insert_locked()) return NULL;
    size_t first_tombstone = pinecone_image_capacity;
    size_t index = pinecone_image_hash(image) &
        (pinecone_image_capacity - 1);
    for (size_t probe = 0; probe < pinecone_image_capacity; probe++) {
        struct pinecone_image_state *state = pinecone_images[index];
        if (state != NULL && state != PINECONE_IMAGE_TOMBSTONE && state->image == image)
            return state;
        if (state == PINECONE_IMAGE_TOMBSTONE) {
            if (first_tombstone == pinecone_image_capacity)
                first_tombstone = index;
        } else if (state == NULL) {
            if (!create)
                return NULL;
            state = calloc(1, sizeof(*state));
            if (state == NULL) return NULL;
            if (first_tombstone != pinecone_image_capacity) {
                index = first_tombstone;
                --pinecone_image_tombstones;
            }
            pinecone_images[index] = state;
            state->image = image;
            // Unknown images may wrap caller-owned storage written without hooks.
            state->cpu_data_unbounded = 1;
            state->transform.matrix[0][0] = 1 << 16;
            state->transform.matrix[1][1] = 1 << 16;
            state->transform.matrix[2][2] = 1 << 16;
            state->repeat = PINECONE_REPEAT_NONE;
            state->filter = PINECONE_FILTER_NEAREST;
            ++pinecone_image_count;
            return state;
        }
        index = (index + 1) & (pinecone_image_capacity - 1);
    }
    return NULL;
}

static void pinecone_remove_image_state_locked(struct pinecone_image_state *state) {
    size_t index = pinecone_image_hash(state->image) & (pinecone_image_capacity - 1);
    while (pinecone_images[index] != state)
        index = (index + 1) & (pinecone_image_capacity - 1);
    pinecone_images[index] = PINECONE_IMAGE_TOMBSTONE;
    --pinecone_image_count;
    ++pinecone_image_tombstones;
    free(state);
}

static struct pinecone_mapping *pinecone_mapping_for(
    const void *address, size_t length
) {
    uintptr_t start = (uintptr_t)address;
    if (start > UINTPTR_MAX - length)
        return NULL;
    uintptr_t end = start + length;
    size_t index = pinecone_mapping_lower_bound_locked(start);
    if (index < pinecone_mapping_count &&
        (uintptr_t)pinecone_mappings[index].address == start &&
        end <= start + pinecone_mappings[index].length)
        return &pinecone_mappings[index];
    if (index != 0) {
        struct pinecone_mapping *mapping = &pinecone_mappings[index - 1];
        uintptr_t mapping_start = (uintptr_t)mapping->address;
        if (start >= mapping_start &&
            end <= mapping_start + mapping->length)
            return mapping;
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

static int pinecone_flush_batch_locked(void);
static int pinecone_wait_pending_fence_locked(void);
static int pinecone_wait_all_pending_fences_locked(void);

static int pinecone_has_pending_fence_locked(void) {
    return pinecone_thread_batch.pending_count != 0;
}

static int pinecone_has_pending_fence_for_fd_locked(int graphics_fd) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    for (uint32_t offset = 0; offset < batch->pending_count; offset++) {
        uint32_t index = (batch->pending_head + offset) %
            PINECONE_MAX_IN_FLIGHT_BATCHES;
        if (batch->pending[index].graphics_fd == graphics_fd)
            return 1;
    }
    return 0;
}

static void pinecone_release_images_locked(
    pixman_image_t **images, uint32_t *image_count
) {
    if (real_unref == NULL) {
        *image_count = 0;
        return;
    }
    while (*image_count != 0) {
        pixman_image_t *image = images[--*image_count];
        images[*image_count] = NULL;
        // Pixman destroy callbacks may re-enter the bridge (for example munmap).
        pthread_mutex_unlock(&pinecone_lock);
        pixman_bool_t destroyed = real_unref(image);
        pthread_mutex_lock(&pinecone_lock);
        if (!destroyed)
            continue;
        struct pinecone_image_state *state = pinecone_image_state(image, 0);
        if (state == NULL)
            continue;
        pixman_region32_t *destination_clip = state->destination_clip;
        pinecone_release_image_surface_locked(state->owned_surface);
        pinecone_release_image_surface_locked(state->source_cache);
        pinecone_release_image_surface_locked(state->mask_cache);
        pinecone_release_spares_locked(state);
        pinecone_remove_image_state_locked(state);
        if (destination_clip != NULL) {
            if (real_region32_fini != NULL)
                real_region32_fini(destination_clip);
            free(destination_clip);
        }
    }
}

static int pinecone_retain_image_locked(pixman_image_t *image) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (image == NULL)
        return 1;
    for (uint32_t index = 0; index < batch->image_count; index++) {
        if (batch->images[index] == image)
            return 1;
    }
    if (real_ref == NULL || batch->image_count >= PINECONE_MAX_BATCH_HANDLES)
        return 0;
    batch->images[batch->image_count++] = real_ref(image);
    return batch->images[batch->image_count - 1u] != NULL;
}

static int pinecone_retain_cpu_access_image_locked(pixman_image_t *image, uint32_t flags) {
    if (image == NULL)
        return 1;
    for (uint32_t index = 0;
         index < pinecone_cpu_access_scope.image_count; index++) {
        if (pinecone_cpu_access_scope.images[index] == image) {
            pinecone_cpu_access_scope.image_flags[index] |= flags;
            return 1;
        }
    }
    if (real_ref == NULL ||
        pinecone_cpu_access_scope.image_count >= PINECONE_MAX_BATCH_HANDLES)
        return 0;
    pixman_image_t *retained = real_ref(image);
    if (retained == NULL)
        return 0;
    uint32_t index = pinecone_cpu_access_scope.image_count++;
    pinecone_cpu_access_scope.images[index] = retained;
    pinecone_cpu_access_scope.image_flags[index] = flags;
    return 1;
}

static int pinecone_image_has_cpu_hazard(
    const struct pinecone_image_state *state
) {
    if (state == NULL || state->is_solid)
        return 0;
    /* A render pass is a submission boundary, not ownership of every pointer
     * previously exported by this process (or another thread). */
    return state->cpu_data_unbounded ||
        state->scoped_cpu_access_count != 0;
}

static void pinecone_remove_fence_use_locked(struct pinecone_fence_use *use) {
    struct pinecone_fence_use **link = &pinecone_fence_uses;
    while (*link != NULL && *link != use)
        link = &(*link)->next;
    if (*link == use)
        *link = use->next;
    free(use);
}

/* Image states are stable allocations and callers own their Pixman references.
 * Duplicate the fence descriptor so another thread may reap its queue safely. */
static int pinecone_handle_pending_locked(int fd, uint32_t handle) {
    for (struct pinecone_fence_use *use = pinecone_fence_uses; use; use = use->next) {
        if (use->graphics_fd != fd) continue;
        for (uint32_t i = 0; i < use->count; ++i) {
            if (use->handles[i] != handle) continue;
            struct pollfd probe = { .fd = use->fd, .events = POLLIN };
            int result;
            do { result = poll(&probe, 1, 0); } while (result < 0 && errno == EINTR);
            if (result < 0 || (probe.revents & (POLLERR | POLLNVAL | POLLHUP))) return -1;
            if (result == 0) return 1;
        }
    }
    return 0;
}

static int pinecone_wait_handle_locked(int fd, uint32_t handle) {
    for (;;) {
        int wait_fd = -1;
        for (struct pinecone_fence_use *use = pinecone_fence_uses;
             use != NULL && wait_fd < 0; use = use->next) {
            if (use->graphics_fd != fd)
                continue;
            for (uint32_t i = 0; i < use->count; ++i) {
                if (use->handles[i] != handle)
                    continue;
                struct pollfd probe = { .fd = use->fd, .events = POLLIN };
                int result;
                do { result = poll(&probe, 1, 0); }
                while (result < 0 && errno == EINTR);
                if (result < 0 || (probe.revents & (POLLERR | POLLNVAL | POLLHUP)))
                    return -1;
                if (result == 0) {
                    wait_fd = fcntl(use->fd, F_DUPFD_CLOEXEC, 0);
                    if (wait_fd < 0)
                        return -1;
                }
                break;
            }
        }
        if (wait_fd < 0)
            return 0;
        struct pollfd fence = { .fd = wait_fd, .events = POLLIN };
        int result;
        pthread_mutex_unlock(&pinecone_lock);
        do { result = poll(&fence, 1, -1); }
        while (result < 0 && errno == EINTR);
        int saved_errno = errno;
        pthread_mutex_lock(&pinecone_lock);
        close(wait_fd);
        if (result <= 0 || !(fence.revents & POLLIN) ||
            (fence.revents & (POLLERR | POLLNVAL))) {
            errno = result < 0 ? saved_errno : EIO;
            return -1;
        }
    }
}

static int pinecone_sync_image_locked(pixman_image_t *image) {
    if (image == NULL || real_get_data == NULL) return 0;
    struct pinecone_mapping *mapping = pinecone_mapping_for(real_get_data(image), 1u);
    if (mapping == NULL) return 0;
    const int fd = mapping->fd;
    const uint32_t handle = mapping->handle;
    if (pinecone_batch_uses_handle_locked(handle) && pinecone_flush_batch_locked() != 0)
        return -1;
    return pinecone_wait_handle_locked(fd, handle);
}

static int pinecone_submit_locked(
    int graphics_fd, void *payload, uint32_t payload_size,
    uint32_t *handles, uint32_t handle_count, int defer_completion
) {
    if (handle_count > PINECONE_MAX_BATCH_HANDLES) {
        errno = EINVAL;
        return -1;
    }
    if (defer_completion &&
        pinecone_thread_batch.pending_count ==
            PINECONE_MAX_IN_FLIGHT_BATCHES &&
        pinecone_wait_pending_fence_locked() != 0) {
        return -1;
    }
    struct pinecone_fence_use *use = calloc(1, sizeof(*use));
    if (use == NULL)
        return -1;
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
    if (result != 0) {
        free(use);
        return result;
    }
    if (submit.fence_fd < 0) {
        free(use);
        errno = EIO;
        return -1;
    }

    use->fd = submit.fence_fd;
    use->graphics_fd = graphics_fd;
    use->count = handle_count;
    memcpy(use->handles, handles, handle_count * sizeof(*handles));
    use->next = pinecone_fence_uses;
    pinecone_fence_uses = use;

    if (defer_completion) {
        struct pinecone_thread_batch *batch = &pinecone_thread_batch;
        uint32_t index = (batch->pending_head + batch->pending_count) %
            PINECONE_MAX_IN_FLIGHT_BATCHES;
        batch->pending[index].fence_fd = submit.fence_fd;
        batch->pending[index].graphics_fd = graphics_fd;
        batch->pending[index].image_count = 0;
        batch->pending[index].use = use;
        ++batch->pending_count;
        return 0;
    }

    struct pollfd fence = {
        .fd = submit.fence_fd,
        .events = POLLIN
    };
    /* Scratch is thread-local; retained images and the caller's mapped buffers
     * remain alive through submission and copyback. */
    pthread_mutex_unlock(&pinecone_lock);
    int poll_result;
    do {
        poll_result = poll(&fence, 1, -1);
    } while (poll_result < 0 && errno == EINTR);
    pthread_mutex_lock(&pinecone_lock);
    if (poll_result <= 0 || (fence.revents & (POLLERR | POLLNVAL)) != 0)
        result = -1;
    close(submit.fence_fd);
    pinecone_remove_fence_use_locked(use);
    return result;
}

static int pinecone_wait_pending_fence_locked(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    if (batch->pending_count == 0)
        return 0;
    struct pinecone_pending_batch *pending =
        &batch->pending[batch->pending_head];
    int fence_fd = pending->fence_fd;
    struct pollfd fence = {
        .fd = fence_fd,
        .events = POLLIN
    };
    int poll_result;
    /* The pending queue is thread-local and all referenced Pixman images are
     * retained by the queue entry. Do not serialize unrelated compositor
     * threads behind a GPU fence wait. */
    pthread_mutex_unlock(&pinecone_lock);
    do {
        poll_result = poll(&fence, 1, -1);
    } while (poll_result < 0 && errno == EINTR);
    pthread_mutex_lock(&pinecone_lock);
    int result = 0;
    if (poll_result <= 0 || (fence.revents & (POLLERR | POLLNVAL)) != 0)
        result = -1;
    close(fence_fd);
    pinecone_remove_fence_use_locked(pending->use);
    pending->use = NULL;
    pixman_image_t *images[PINECONE_MAX_BATCH_HANDLES];
    uint32_t image_count = pending->image_count;
    memcpy(images, pending->images, image_count * sizeof(*images));
    pending->image_count = 0;
    pending->fence_fd = -1;
    pending->graphics_fd = -1;
    batch->pending_head = (batch->pending_head + 1u) %
        PINECONE_MAX_IN_FLIGHT_BATCHES;
    --batch->pending_count;
    pinecone_release_images_locked(images, &image_count);
    return result;
}

static int pinecone_wait_all_pending_fences_locked(void) {
    int result = 0;
    while (pinecone_has_pending_fence_locked()) {
        if (pinecone_wait_pending_fence_locked() != 0)
            result = -1;
    }
    return result;
}

static int pinecone_flush_and_wait_locked(void) {
    if (pinecone_flush_batch_locked() != 0)
        return -1;
    return pinecone_wait_all_pending_fences_locked();
}

static void pinecone_reset_batch_locked(void) {
    struct pinecone_thread_batch *batch = &pinecone_thread_batch;
    batch->graphics_fd = -1;
    batch->command_count = 0;
    batch->handle_count = 0;
    batch->image_count = 0;
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
        batch->handles, batch->handle_count, 1
    );
    if (result == 0) {
        uint32_t pending_index =
            (batch->pending_head + batch->pending_count - 1u) %
            PINECONE_MAX_IN_FLIGHT_BATCHES;
        struct pinecone_pending_batch *pending = &batch->pending[pending_index];
        pending->image_count = batch->image_count;
        memcpy(pending->images, batch->images,
               batch->image_count * sizeof(batch->images[0]));
        memset(batch->images, 0,
               batch->image_count * sizeof(batch->images[0]));
        batch->image_count = 0;
    } else {
        pinecone_release_images_locked(batch->images, &batch->image_count);
    }
    /* BO and Pixman ownership now follows the completion fence. CPU access,
     * object destruction, and queue saturation reap retained batches. */
    pinecone_reset_batch_locked();
    if (result == 0) {
        __atomic_add_fetch(&pinecone_batch_count, 1u, __ATOMIC_RELAXED);
        __atomic_add_fetch(
            &pinecone_batched_command_count, command_count, __ATOMIC_RELAXED);
        unsigned bin = command_count <= 1 ? 0 : command_count <= 4 ? 1 :
            command_count <= 16 ? 2 : command_count <= 64 ? 3 :
            command_count <= 256 ? 4 : 5;
        __atomic_add_fetch(&pinecone_batch_sizes[bin], 1u, __ATOMIC_RELAXED);
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
    uint32_t source_handle, uint32_t mask_handle, uint32_t destination_handle,
    pixman_image_t *source, pixman_image_t *mask, pixman_image_t *destination
) {
    if (!pinecone_register_thread()) return 0;
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
    uint32_t prior_image_count = batch->image_count;
    if (!pinecone_retain_image_locked(source) ||
        !pinecone_retain_image_locked(mask) ||
        !pinecone_retain_image_locked(destination)) {
        while (batch->image_count > prior_image_count) {
            pixman_image_t *retained = batch->images[--batch->image_count];
            batch->images[batch->image_count] = NULL;
            if (real_unref != NULL)
                (void)real_unref(retained);
        }
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
    if ((unsigned int)op > PINECONE_PIXMAN_OP_SATURATE)
        return 0;
    if ((pinecone_enabled_operator_mask &
         (UINT64_C(1) << (unsigned int)op)) == 0)
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
         destination_format != PINECONE_FORMAT_X8R8G8B8 &&
         destination_format != PINECONE_FORMAT_A8) ||
        destination_x + (int64_t)width > destination_width ||
        destination_y + (int64_t)height > destination_height) {
        *fallback_reason = PINECONE_FALLBACK_DESTINATION;
        return 0;
    }
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *source_state = pinecone_image_state(source, 1);
    struct pinecone_image_state *mask_state = pinecone_image_state(mask, 1);
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
    struct pinecone_mapping destination_mapping_value;
    if (destination_mapping != NULL) {
        destination_mapping_value = *destination_mapping;
        destination_mapping = &destination_mapping_value;
    }
    struct pinecone_upload_surface *destination_owned =
        destination_state != NULL ? destination_state->owned_surface : NULL;
    struct pinecone_upload_surface *destination_upload = NULL;
    const size_t destination_bytes_per_pixel =
        destination_format == PINECONE_FORMAT_A8 ? 1u : 4u;
    int graphics_fd = destination_mapping != NULL
        ? destination_mapping->fd
        : (destination_owned != NULL
            ? destination_owned->fd
            : pinecone_graphics_fd_locked());
    if (graphics_fd < 0) {
        pthread_mutex_unlock(&pinecone_lock);
        *fallback_reason = PINECONE_FALLBACK_DESTINATION;
        return 0;
    }
    uint32_t destination_handle;
    if (destination_mapping != NULL || destination_owned != NULL) {
        const void *surface_address = destination_mapping != NULL
            ? destination_mapping->address : destination_owned->address;
        size_t surface_length = destination_mapping != NULL
            ? destination_mapping->length : destination_owned->length;
        uintptr_t destination_address = (uintptr_t)destination_data;
        uintptr_t surface_start = (uintptr_t)surface_address;
        size_t destination_length =
            (size_t)destination_stride * (size_t)destination_height;
        if (destination_address < surface_start ||
            destination_address - surface_start > surface_length ||
            destination_length >
                surface_length - (destination_address - surface_start)) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_DESTINATION;
            return 0;
        }
        uintptr_t destination_byte_offset = destination_address - surface_start;
        if (destination_byte_offset % destination_bytes_per_pixel != 0) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
            return 0;
        }
        destination_x += (int32_t)((destination_byte_offset %
            (uintptr_t)destination_stride) / destination_bytes_per_pixel);
        destination_y += (int32_t)(destination_byte_offset /
            (uintptr_t)destination_stride);
        destination_handle = destination_mapping != NULL
            ? destination_mapping->handle : destination_owned->handle;
    } else {
        destination_upload = &pinecone_uploads[PINECONE_UPLOAD_DESTINATION];
        if (!pinecone_ensure_upload_locked(
                destination_upload, graphics_fd,
                (uint32_t)destination_width, (uint32_t)destination_height)) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_UPLOAD;
            return 0;
        }
        const size_t row_bytes =
            (size_t)width * destination_bytes_per_pixel;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(
                (uint8_t *)destination_upload->address +
                    (size_t)(destination_y + (int32_t)row) *
                        destination_upload->pitch +
                        (size_t)destination_x * destination_bytes_per_pixel,
                (const uint8_t *)destination_data +
                    (size_t)(destination_y + (int32_t)row) *
                        (size_t)destination_stride +
                        (size_t)destination_x * destination_bytes_per_pixel,
                row_bytes
            );
        }
        destination_handle = destination_upload->handle;
    }

    uint32_t source_handle = 0;
    uint32_t solid_color = 0;
    uint32_t flags = 0;
    if (destination_format == PINECONE_FORMAT_A8)
        flags |= PINECONE_DESTINATION_PACKED_A8;
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
            source_width <= 0 || source_height <= 0 ||
            (source_format != PINECONE_FORMAT_A8R8G8B8 &&
             source_format != PINECONE_FORMAT_X8R8G8B8 &&
             source_format != PINECONE_FORMAT_A8) ||
            source_x + (int64_t)source_width_in_payload > source_width ||
            source_y + (int64_t)source_height_in_payload > source_height) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_SOURCE;
            return 0;
        }
        if (!pinecone_packed_a8_enabled &&
            source_format == PINECONE_FORMAT_A8) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_SOURCE;
            return 0;
        }
        const size_t source_bytes_per_pixel =
            source_format == PINECONE_FORMAT_A8 ? 1u : 4u;
        if (source_format == PINECONE_FORMAT_A8 &&
            (source_width_in_payload != width ||
             source_height_in_payload != height ||
             (flags & PINECONE_FILTER_BILINEAR_FLAG) != 0)) {
            pthread_mutex_unlock(&pinecone_lock);
            *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
            return 0;
        }
        struct pinecone_mapping *source_mapping = pinecone_mapping_for(
            source_data, (size_t)source_stride * source_height);
        struct pinecone_mapping source_mapping_value;
        if (source_mapping != NULL) {
            source_mapping_value = *source_mapping;
            source_mapping = &source_mapping_value;
        }
        struct pinecone_upload_surface *source_owned =
            source_state != NULL ? source_state->owned_surface : NULL;
        int source_is_direct =
            (source_mapping != NULL && source_mapping->fd == graphics_fd &&
             source_mapping->handle != destination_handle) ||
            (source_mapping == NULL && source_owned != NULL &&
             source_owned->fd == graphics_fd &&
             source_owned->handle != destination_handle);
        if (source_is_direct) {
            const void *surface_address = source_mapping != NULL
                ? source_mapping->address : source_owned->address;
            size_t surface_length = source_mapping != NULL
                ? source_mapping->length : source_owned->length;
            uintptr_t source_address = (uintptr_t)source_data;
            uintptr_t surface_start = (uintptr_t)surface_address;
            size_t source_length = (size_t)source_stride * (size_t)source_height;
            if (source_address < surface_start ||
                source_address - surface_start > surface_length ||
                source_length > surface_length - (source_address - surface_start)) {
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_SOURCE;
                return 0;
            }
            uintptr_t source_byte_offset =
                source_address - surface_start;
            if (source_byte_offset % source_bytes_per_pixel != 0) {
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_GEOMETRY;
                return 0;
            }
            source_x += (int32_t)((source_byte_offset %
                (uintptr_t)source_stride) / source_bytes_per_pixel);
            source_y += (int32_t)(source_byte_offset /
                (uintptr_t)source_stride);
            source_handle = source_mapping != NULL
                ? source_mapping->handle : source_owned->handle;
        } else {
            struct pinecone_upload_surface *source_cache =
                pinecone_prepare_source_cache_locked(
                    source_state, graphics_fd,
                    (const uint8_t *)source_data, (size_t)source_stride,
                    (uint32_t)source_width, (uint32_t)source_height,
                    source_bytes_per_pixel);
            if (source_cache != NULL) {
                source_handle = source_cache->handle;
            } else {
                if (!pinecone_upload_pixels_locked(
                        &pinecone_uploads[PINECONE_UPLOAD_SOURCE], graphics_fd,
                        (const uint8_t *)source_data,
                        (size_t)source_stride,
                        (uint32_t)source_x,
                        (uint32_t)source_y,
                        source_width_in_payload,
                        source_height_in_payload,
                        source_bytes_per_pixel)) {
                    pthread_mutex_unlock(&pinecone_lock);
                    *fallback_reason = PINECONE_FALLBACK_UPLOAD;
                    return 0;
                }
                source_handle =
                    pinecone_uploads[PINECONE_UPLOAD_SOURCE].handle;
                source_x = 0;
                source_y = 0;
            }
        }
        if (source_format == PINECONE_FORMAT_A8R8G8B8)
            flags |= PINECONE_SOURCE_CONTAINS_ALPHA;
        else if (source_format == PINECONE_FORMAT_A8)
            flags |= PINECONE_SOURCE_CONTAINS_ALPHA |
                PINECONE_SOURCE_PACKED_A8;
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
            if (!pinecone_packed_a8_enabled &&
                mask_format == PINECONE_FORMAT_A8) {
                pthread_mutex_unlock(&pinecone_lock);
                *fallback_reason = PINECONE_FALLBACK_MASK;
                return 0;
            }
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
            /* Pixman preserves a caller-supplied zero rowstride. Its bits
             * fetchers consequently reuse the same row for every y. Mirror
             * that addressing in the upload path instead of inventing a
             * tightly packed layout that may exceed caller-owned storage. */
            if (mask_data == NULL || mask_stride < 0 ||
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
            struct pinecone_mapping *mask_mapping = mask_stride == 0
                ? NULL
                : pinecone_mapping_for(
                    mask_data, (size_t)mask_stride * mask_height);
            struct pinecone_mapping mask_mapping_value;
            if (mask_mapping != NULL) {
                mask_mapping_value = *mask_mapping;
                mask_mapping = &mask_mapping_value;
            }
            struct pinecone_upload_surface *mask_owned =
                mask_state != NULL ? mask_state->owned_surface : NULL;
            uint32_t direct_mask_handle = mask_mapping != NULL
                ? mask_mapping->handle
                : (mask_owned != NULL ? mask_owned->handle : 0);
            int direct_mask_fd = mask_mapping != NULL
                ? mask_mapping->fd
                : (mask_owned != NULL ? mask_owned->fd : -1);
            if (direct_mask_handle != 0 && direct_mask_fd == graphics_fd &&
                direct_mask_handle != destination_handle &&
                direct_mask_handle != source_handle &&
                resolved_mask_x == 0 && resolved_mask_y == 0) {
                mask_handle = direct_mask_handle;
                __atomic_add_fetch(
                    &pinecone_mask_counts[PINECONE_MASK_DIRECT],
                    1u, __ATOMIC_RELAXED);
                if (mask_format == PINECONE_FORMAT_A8)
                    flags |= PINECONE_MASK_PACKED_A8;
            } else {
                struct pinecone_upload_surface *mask_cache =
                    pinecone_prepare_mask_cache_locked(
                        mask_state, graphics_fd,
                        (const uint8_t *)mask_data, (size_t)mask_stride,
                        (uint32_t)resolved_mask_x,
                        (uint32_t)resolved_mask_y,
                        width, height, mask_format, component_alpha);
                if (mask_cache != NULL) {
                    mask_handle = mask_cache->handle;
                } else {
                    if (!pinecone_upload_mask_locked(
                            &pinecone_uploads[PINECONE_UPLOAD_MASK],
                            graphics_fd, (const uint8_t *)mask_data,
                            (size_t)mask_stride,
                            (uint32_t)resolved_mask_x,
                            (uint32_t)resolved_mask_y,
                            width, height, mask_format, component_alpha)) {
                        __atomic_add_fetch(
                            &pinecone_mask_counts[
                                PINECONE_MASK_ALLOCATION_REJECTED],
                            1u, __ATOMIC_RELAXED);
                        pthread_mutex_unlock(&pinecone_lock);
                        *fallback_reason = PINECONE_FALLBACK_MASK;
                        return 0;
                    }
                    mask_handle =
                        pinecone_uploads[PINECONE_UPLOAD_MASK].handle;
                }
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
    int source_uses_stable_cache = source_state != NULL &&
        source_state->source_cache != NULL &&
        source_handle == source_state->source_cache->handle;
    int mask_uses_stable_cache = mask_state != NULL &&
        mask_state->mask_cache != NULL &&
        mask_handle == mask_state->mask_cache->handle;
    int has_upload_hazard = destination_upload != NULL || uses_reusable_upload;
    int has_cpu_hazard =
        (!source_uses_stable_cache &&
         pinecone_image_has_cpu_hazard(source_state)) ||
        (!mask_uses_stable_cache &&
         pinecone_image_has_cpu_hazard(mask_state)) ||
        pinecone_image_has_cpu_hazard(destination_state) ||
        (pinecone_cpu_access_scope.depth != 0 &&
         pinecone_cpu_access_scope.retention_failed);
    /* Pixman's composite transaction covers one clipped operation, while the
     * wlroots render pass covers the complete destination frame. Either scope
     * provides a valid ownership lifetime because queued images are retained
     * until submission completes. Prefer the outer pass when present so
     * adjacent composites and fills share one device submission. */
    int has_batch_scope = pinecone_thread_batch.depth != 0 ||
        pinecone_render_pass_depth != 0;
    int batch_eligible = has_batch_scope && !has_upload_hazard &&
        !has_cpu_hazard;
    if (has_batch_scope) {
        __atomic_add_fetch(
            &pinecone_batch_candidate_count, 1u, __ATOMIC_RELAXED);
    } else {
        __atomic_add_fetch(
            &pinecone_batch_rejection_scope_count, 1u, __ATOMIC_RELAXED);
    }
    if (has_upload_hazard) {
        __atomic_add_fetch(
            &pinecone_batch_rejection_upload_count, 1u, __ATOMIC_RELAXED);
    }
    if (has_cpu_hazard) {
        __atomic_add_fetch(
            &pinecone_batch_rejection_hazard_count, 1u, __ATOMIC_RELAXED);
    }
    int result;
    if (batch_eligible) {
        result = pinecone_enqueue_locked(
            graphics_fd, &payload,
            source_handle, mask_handle, destination_handle,
            source, mask, destination
        ) ? 0 : -1;
    } else {
        result = pinecone_flush_batch_locked();
        if (result == 0) {
            result = pinecone_submit_locked(
                graphics_fd, &payload, sizeof(payload), handles, handle_count, 0
            );
        }
    }
    if (result == 0 && destination_upload != NULL) {
        const size_t row_bytes =
            (size_t)width * destination_bytes_per_pixel;
        for (uint32_t row = 0; row < height; row++) {
            memcpy(
                (uint8_t *)destination_data +
                    (size_t)(destination_y + (int32_t)row) *
                        (size_t)destination_stride +
                        (size_t)destination_x * destination_bytes_per_pixel,
                (const uint8_t *)destination_upload->address +
                    (size_t)(destination_y + (int32_t)row) *
                        destination_upload->pitch +
                        (size_t)destination_x * destination_bytes_per_pixel,
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
    if (state != NULL) {
        state->owned_surface = surface;
        state->cpu_data_unbounded = 0;
    }
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
    if (pinecone_flush_and_wait_locked() != 0) {
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
    /* A patched wlroots render pass owns the outer batching boundary. Images
     * referenced by queued commands are retained until the completion fence,
     * so pass-local Pixman references may be released without forcing a flush. */
    if (batch->depth == 0 && pinecone_render_pass_depth == 0 &&
        batch->command_count != 0) {
        pthread_mutex_lock(&pinecone_lock);
        int result = pinecone_flush_batch_locked();
        pthread_mutex_unlock(&pinecone_lock);
        return result == 0;
    }
    return 1;
}

void pinecone_pixman_begin_render_pass(void) {
    if (pinecone_render_pass_depth != UINT_MAX) {
        if (pinecone_render_pass_depth == 0) {
            __atomic_add_fetch(
                &pinecone_render_pass_count, 1u, __ATOMIC_RELAXED);
        }
        ++pinecone_render_pass_depth;
    }
}

void pinecone_pixman_end_render_pass(void) {
    if (pinecone_render_pass_depth == 0)
        return;
    --pinecone_render_pass_depth;
    /* Phoc may use several render passes for one output frame. The output
     * commit hook is the ownership and visibility boundary; CPU-access hooks
     * still force an earlier flush for a genuine hazard. */
}

/* These hooks are consumed by the optional Pinecone wlroots patch. They keep
 * synchronization at wlroots' real buffer and output boundaries instead of
 * making the Pixman interposer guess when a frame is complete. */
void pinecone_pixman_begin_cpu_access_flags(uint32_t flags) {
    pthread_mutex_lock(&pinecone_lock);
    unsigned int depth = pinecone_cpu_access_scope.depth;
    if (depth < 64)
        pinecone_cpu_access_scope.flags[depth] = flags;
    if (pinecone_cpu_access_scope.depth++ == 0) {
        pinecone_cpu_access_scope.retention_failed = 0;
    }
    pthread_mutex_unlock(&pinecone_lock);
}

void pinecone_pixman_begin_cpu_access(void) {
    pinecone_pixman_begin_cpu_access_flags(3u);
}

int pinecone_pixman_access_buffer(void *data, size_t length) {
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_mapping *mapping = pinecone_mapping_for(data, length);
    int result = 0;
    if (mapping != NULL) {
        const int fd = mapping->fd;
        const uint32_t handle = mapping->handle;
        if (pinecone_batch_uses_handle_locked(handle))
            result = pinecone_flush_batch_locked();
        if (result == 0)
            result = pinecone_wait_handle_locked(fd, handle);
    }
    pthread_mutex_unlock(&pinecone_lock);
    return result == 0;
}

void pinecone_pixman_end_cpu_access(void) {
    pthread_mutex_lock(&pinecone_lock);
    if (pinecone_cpu_access_scope.depth == 0) {
        pthread_mutex_unlock(&pinecone_lock);
        return;
    }
    if (--pinecone_cpu_access_scope.depth != 0) {
        pthread_mutex_unlock(&pinecone_lock);
        return;
    }
    for (uint32_t index = 0;
         index < pinecone_cpu_access_scope.image_count; index++) {
        struct pinecone_image_state *state = pinecone_image_state(
            pinecone_cpu_access_scope.images[index], 0);
        if (state != NULL && state->scoped_cpu_access_count != 0) {
            --state->scoped_cpu_access_count;
            /* A cache may have been populated before the scope's final write. */
            if (pinecone_cpu_access_scope.image_flags[index] & 2u) {
                if (++state->cpu_generation == 0) {
                    state->cpu_generation = 1;
                    state->source_cache_generation = UINT64_MAX;
                    state->mask_cache_generation = UINT64_MAX;
                }
            }
        }
    }
    pinecone_release_images_locked(
        pinecone_cpu_access_scope.images,
        &pinecone_cpu_access_scope.image_count);
    pinecone_cpu_access_scope.retention_failed = 0;
    pthread_mutex_unlock(&pinecone_lock);
}

void pinecone_pixman_output_commit(void) {
    pthread_mutex_lock(&pinecone_lock);
    /* The virtio GPU control queue preserves submission order and does not
     * process a later transfer/flush command until the deferred Metal command
     * completes. Publish the frame boundary without stalling Phoc's CPU here;
     * CPU mappings and resource reuse remain explicit fence wait points. */
    (void)pinecone_flush_batch_locked();
    pthread_mutex_unlock(&pinecone_lock);
}

pixman_bool_t pixman_fill(
    uint32_t *bits, int stride, int bpp, int x, int y,
    int width, int height, uint32_t filler
) {
    pinecone_resolve();
    if (real_fill == NULL)
        return 0;
    const int supported_bpp = bpp == 8 || bpp == 32;
    const size_t bytes_per_pixel = bpp == 8 ? 1u : 4u;
    const size_t row_stride = stride > 0 && stride <= INT_MAX / 4
        ? (size_t)stride * 4u : 0u;
    const size_t row_width = bytes_per_pixel != 0
        ? row_stride / bytes_per_pixel : 0u;
    if (bits == NULL || stride <= 0 || !supported_bpp || x < 0 || y < 0 ||
        width <= 0 || height <= 0 || stride > INT_MAX / 4 ||
        (size_t)width > row_width ||
        (size_t)x > row_width - (size_t)width) {
        /* pixman_fill() is also Pixman's direct CPU write primitive. It must
         * never race previously queued host writes, including unsupported
         * 1/16-bpp fills and invalid geometry delegated to Pixman. */
        pthread_mutex_lock(&pinecone_lock);
        (void)pinecone_flush_and_wait_locked();
        pthread_mutex_unlock(&pinecone_lock);
        return real_fill(bits, stride, bpp, x, y, width, height, filler);
    }

    int accelerated = 0;
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_mapping *mapping = pinecone_mapping_for(bits, 1u);
    struct pinecone_mapping mapping_value;
    if (mapping != NULL) {
        mapping_value = *mapping;
        mapping = &mapping_value;
    }
    if (mapping != NULL) {
        uintptr_t byte_offset = (uintptr_t)bits - (uintptr_t)mapping->address;
        size_t start_x = byte_offset % row_stride;
        size_t start_y = byte_offset / row_stride;
        size_t destination_x = start_x / bytes_per_pixel + (size_t)x;
        size_t destination_y = start_y + (size_t)y;
        size_t height_minus_one = (size_t)height - 1u;
        int geometry_valid = start_x % bytes_per_pixel == 0 &&
            destination_x <= UINT32_MAX && destination_y <= UINT32_MAX &&
            (size_t)width <= UINT32_MAX && (size_t)height <= UINT32_MAX &&
            destination_y <= SIZE_MAX - height_minus_one &&
            destination_x <=
                (SIZE_MAX / bytes_per_pixel) - (size_t)width;
        size_t end = 0;
        if (geometry_valid) {
            size_t last_row = destination_y + height_minus_one;
            geometry_valid = last_row <= SIZE_MAX / row_stride;
        }
        if (geometry_valid) {
            size_t last_row = destination_y + height_minus_one;
            end = last_row * row_stride +
                (destination_x + (size_t)width) * bytes_per_pixel;
            geometry_valid = end <= mapping->length;
        }
        if (geometry_valid) {
            const uint32_t flags = PINECONE_SOURCE_IS_SOLID |
                (bpp == 8 ? PINECONE_DESTINATION_PACKED_A8 : 0u);
            const uint32_t color = bpp == 8
                ? (filler & UINT32_C(0xff)) << 24u : filler;
            struct pinecone_2d_payload payload = {
                .magic = PINECONE_MAGIC,
                .version = PINECONE_EXACT_COMPOSITE_VERSION,
                .operation = PINECONE_PIXMAN_OP_SRC,
                .flags = flags,
                .source_resource_id = 0,
                .destination_resource_id = mapping->handle,
                .source_x = 0,
                .source_y = 0,
                .destination_x = (int32_t)destination_x,
                .destination_y = (int32_t)destination_y,
                .width = (uint32_t)width,
                .height = (uint32_t)height,
                .color = color,
                .source_width = 0,
                .source_height = 0,
                .mask_resource_id = 0,
                .mask_alpha = 0
            };
            /* Raw pointers have no retained image or provable ownership end,
             * even inside a render pass. Complete before their next CPU use. */
            uint32_t handle = mapping->handle;
            int result = pinecone_flush_batch_locked();
            if (result == 0) {
                result = pinecone_submit_locked(
                    mapping->fd, &payload, sizeof(payload), &handle, 1u, 0);
            }
            accelerated = result == 0;
        }
        if (!accelerated && pinecone_flush_and_wait_locked() != 0)
            abort(); /* No safe CPU fallback after an unsuccessful fence. */
    } else if (bpp == 32) {
        int graphics_fd = pinecone_graphics_fd_locked();
        struct pinecone_upload_surface *upload =
            &pinecone_uploads[PINECONE_UPLOAD_DESTINATION];
        if (graphics_fd >= 0 &&
            pinecone_flush_batch_locked() == 0 &&
            pinecone_ensure_upload_locked(
                upload, graphics_fd, (uint32_t)width, (uint32_t)height)) {
            struct pinecone_2d_payload payload = {
                .magic = PINECONE_MAGIC,
                .version = PINECONE_EXACT_COMPOSITE_VERSION,
                .operation = PINECONE_PIXMAN_OP_SRC,
                .flags = PINECONE_SOURCE_IS_SOLID,
                .source_resource_id = 0,
                .destination_resource_id = upload->handle,
                .source_x = 0,
                .source_y = 0,
                .destination_x = 0,
                .destination_y = 0,
                .width = (uint32_t)width,
                .height = (uint32_t)height,
                .color = filler,
                .source_width = 0,
                .source_height = 0,
                .mask_resource_id = 0,
                .mask_alpha = 0
            };
            uint32_t handle = upload->handle;
            if (pinecone_submit_locked(
                    graphics_fd, &payload, sizeof(payload),
                    &handle, 1u, 0) == 0) {
                const size_t row_bytes = (size_t)width * 4u;
                for (int row = 0; row < height; row++) {
                    memcpy(
                        (uint8_t *)bits +
                            ((size_t)y + (size_t)row) * row_stride +
                            (size_t)x * 4u,
                        (const uint8_t *)upload->address +
                            (size_t)row * upload->pitch,
                        row_bytes
                    );
                }
                accelerated = 1;
            }
        }
        if (!accelerated && pinecone_flush_and_wait_locked() != 0)
            abort();
    } else {
        /* CPU-owned A8 scratch buffers have no host resource to target. Wait
         * for any commands that may feed this Pixman operation before the CPU
         * fallback writes them. */
        if (pinecone_flush_and_wait_locked() != 0)
            abort();
    }
    pthread_mutex_unlock(&pinecone_lock);

    pinecone_record_composite(
        PINECONE_PIXMAN_OP_SRC, accelerated,
        accelerated ? PINECONE_FALLBACK_REASON_COUNT
                    : PINECONE_FALLBACK_DESTINATION,
        (uint32_t)width, (uint32_t)height
    );
    return accelerated
        ? 1
        : real_fill(bits, stride, bpp, x, y, width, height, filler);
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
    /*
     * Pixman's internal CPU fallback reads and writes image storage directly;
     * it does not pass through the exported get-data hook. Any previously
     * submitted Metal operation must therefore complete before we return
     * false and allow Pixman to touch that storage.
     */
    if (!accelerated) {
        pthread_mutex_lock(&pinecone_lock);
        // CPU fallback touches these images, not every BO submitted by the thread.
        // Shared mappings include bridge-owned surfaces and cross-thread fences.
        if (pinecone_sync_image_locked(source) != 0 ||
            pinecone_sync_image_locked(mask) != 0 ||
            pinecone_sync_image_locked(destination) != 0)
            abort(); /* Returning false would let Pixman touch unsynced bytes. */
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

static uint32_t *pinecone_get_data(pixman_image_t *image, int escaping) {
    pinecone_resolve();
    if (real_get_data == NULL)
        return NULL;
    pthread_mutex_lock(&pinecone_lock);
    uint32_t *data = real_get_data(image);
    struct pinecone_mapping *mapping = pinecone_mapping_for(data, 1u);
    int result = 0;
    if (mapping != NULL) {
        const int fd = mapping->fd;
        const uint32_t handle = mapping->handle;
        if (pinecone_batch_uses_handle_locked(handle))
            result = pinecone_flush_batch_locked();
        if (result == 0)
            result = pinecone_wait_handle_locked(fd, handle);
    }
    struct pinecone_image_state *state = pinecone_image_state(image, 1);
    if (result == 0 && state != NULL) {
        unsigned int depth = escaping ? 0 : pinecone_cpu_access_scope.depth;
        uint32_t flags = depth != 0 && depth <= 64
            ? pinecone_cpu_access_scope.flags[depth - 1u] : 3u;
        // Unscoped pointers remain conservatively writable. Explicit read
        // mappings do not invalidate an otherwise current upload cache.
        if (flags & 2u) {
            if (++state->cpu_generation == 0) {
                state->cpu_generation = 1;
                state->source_cache_generation = UINT64_MAX;
                state->mask_cache_generation = UINT64_MAX;
            }
        }
        if (depth != 0) {
            uint32_t prior_count = pinecone_cpu_access_scope.image_count;
            if (pinecone_retain_cpu_access_image_locked(image, flags)) {
                if (pinecone_cpu_access_scope.image_count != prior_count)
                    ++state->scoped_cpu_access_count;
            } else {
                pinecone_cpu_access_scope.retention_failed = 1;
                /* No retained lifetime means the pointer cannot be bounded. */
                state->cpu_data_unbounded = 1;
            }
        } else {
            state->cpu_data_unbounded = 1;
        }
    }
    pthread_mutex_unlock(&pinecone_lock);
    return result == 0 ? real_get_data(image) : NULL;
}

uint32_t *pixman_image_get_data(pixman_image_t *image) {
    return pinecone_get_data(image, 0);
}

uint32_t *pinecone_pixman_get_data_escaping(pixman_image_t *image) {
    return pinecone_get_data(image, 1);
}

__attribute__((destructor))
static void pinecone_pixman_shutdown(void) {
    pthread_mutex_lock(&pinecone_lock);
    pinecone_flush_and_wait_locked();
    for (size_t index = 0; index < PINECONE_UPLOAD_COUNT; index++)
        pinecone_release_upload_locked(&pinecone_uploads[index]);
    if (pinecone_owned_graphics_fd >= 0) {
        close(pinecone_owned_graphics_fd);
        pinecone_owned_graphics_fd = -1;
    }
    pthread_mutex_unlock(&pinecone_lock);
}

static void pinecone_scratch_destroy(void *value) {
    (void)value;
    pthread_mutex_lock(&pinecone_lock);
    (void)pinecone_flush_and_wait_locked();
    for (size_t i = 0; i < PINECONE_UPLOAD_COUNT; ++i)
        pinecone_release_upload_locked(&pinecone_uploads[i]);
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
    pixman_bool_t destroyed = real_unref(image);
    if (!destroyed)
        return 0;

    pixman_region32_t *destination_clip = NULL;
    pthread_mutex_lock(&pinecone_lock);
    struct pinecone_image_state *state = pinecone_image_state(image, 0);
    if (state != NULL) {
        destination_clip = state->destination_clip;
        pinecone_release_image_surface_locked(state->owned_surface);
        pinecone_release_image_surface_locked(state->source_cache);
        pinecone_release_image_surface_locked(state->mask_cache);
        pinecone_release_spares_locked(state);
        pinecone_remove_image_state_locked(state);
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
    if ((pinecone_thread_batch.command_count != 0 &&
         pinecone_thread_batch.graphics_fd == fd) ||
        pinecone_has_pending_fence_for_fd_locked(fd)) {
        pthread_mutex_lock(&pinecone_lock);
        int flush_result = pinecone_flush_and_wait_locked();
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
            if (pinecone_record_mapping_locked(
                    mapping, length, fd,
                    pinecone_pending_mappings[pending].handle)) {
                __atomic_add_fetch(
                    &pinecone_mapped_surface_count, 1u,
                    __ATOMIC_RELAXED);
                __atomic_add_fetch(
                    &pinecone_live_mapped_surfaces, 1u,
                    __ATOMIC_RELAXED);
                __atomic_add_fetch(
                    &pinecone_live_mapped_bytes, length,
                    __ATOMIC_RELAXED);
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
    if (pinecone_flush_and_wait_locked() != 0) {
        pthread_mutex_unlock(&pinecone_lock);
        return -1;
    }
    struct pinecone_mapping *mapping =
        pinecone_exact_mapping_locked(address);
    if (mapping != NULL) {
        size_t index = (size_t)(mapping - pinecone_mappings);
        __atomic_sub_fetch(
            &pinecone_live_mapped_surfaces, 1u, __ATOMIC_RELAXED);
        __atomic_sub_fetch(
            &pinecone_live_mapped_bytes,
            mapping->length, __ATOMIC_RELAXED);
        pinecone_remove_mapping_at_locked(index);
    }
    pthread_mutex_unlock(&pinecone_lock);
    return (int)pinecone_syscall_result(pinecone_syscall6(
        PINECONE_SYSCALL_MUNMAP, (long)address, (long)length, 0, 0, 0, 0));
}
