#include "ARM64VizGuestMemoryInternal.h"

#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#if defined(__APPLE__)
#include <mach/mach_time.h>
#else
#include <time.h>
#endif

static uint64_t avz_counter_host_ticks(void) {
#if defined(__APPLE__)
    return mach_absolute_time();
#else
    struct timespec now = {0};
    (void)clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
#endif
}

int avz_native_counter_clock_initialize(AVZNativeCounterClock *clock,
    uint64_t counter_anchor, uint32_t frequency) {
    if (clock == NULL || frequency == 0)
        return 0;
    uint32_t numerator = 1, denominator = 1;
#if defined(__APPLE__)
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != 0 || timebase.denom == 0)
        return 0;
    numerator = timebase.numer;
    denominator = timebase.denom;
#else
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
#endif
    *clock = (AVZNativeCounterClock) {
        .host_anchor = avz_counter_host_ticks(), .counter_anchor = counter_anchor,
        .frequency = frequency, .numerator = numerator, .denominator = denominator
    };
    return 1;
}

uint64_t avz_native_counter_clock_read(const AVZNativeCounterClock *clock) {
    if (clock == NULL || clock->frequency == 0 || clock->denominator == 0)
        return 0;
    uint64_t now = avz_counter_host_ticks();
    uint64_t elapsed = now >= clock->host_anchor ? now - clock->host_anchor : 0;
    __uint128_t ticks = (__uint128_t)elapsed * clock->numerator * clock->frequency;
    ticks /= (uint64_t)clock->denominator * UINT64_C(1000000000);
    return clock->counter_anchor + (uint64_t)ticks;
}

void avz_native_memory_fast_path_set_counter_clock(AVZNativeMemoryFastPath *fast_path,
    const AVZNativeCounterClock *clock) {
    if (fast_path == NULL)
        return;
    fast_path->counter_clock = clock != NULL ? *clock : (AVZNativeCounterClock){0};
    fast_path->counter_refresh_instructions = 0;
}

static void avz_native_refresh_shared_counter(AVZNativeMemoryFastPath *fast_path) {
    if (fast_path->counter_clock.frequency != 0) {
        fast_path->architectural_state.counter_ticks =
            avz_native_counter_clock_read(&fast_path->counter_clock);
        fast_path->counter_refresh_instructions = 0;
    }
}

enum {
    AVZ_FAST_TRANSLATION_FAILED = 0,
    AVZ_FAST_TRANSLATION_RAM = 1,
    AVZ_FAST_TRANSLATION_PHYSICAL = 2
};

#define AVZ_STAGE1_OUTPUT_ADDRESS_MASK 0x0000fffffffff000ULL
#define AVZ_STAGE1_ACCESS_FLAG_BIT (1ULL << 10)
#define AVZ_STAGE1_READ_ONLY_AP_BIT (1ULL << 7)
#define AVZ_STAGE1_PRIVILEGED_EXECUTE_NEVER_BIT (1ULL << 53)
#define AVZ_STAGE1_UNPRIVILEGED_EXECUTE_NEVER_BIT (1ULL << 54)

enum {
    AVZ_FAULT_ADDRESS_SIZE_LEVEL_0 = 0x00,
    AVZ_FAULT_TRANSLATION_LEVEL_0 = 0x04,
    AVZ_FAULT_ACCESS_FLAG_LEVEL_0 = 0x08,
    AVZ_FAULT_PERMISSION_LEVEL_0 = 0x0c
};

static size_t avz_next_power_of_two(size_t value) {
    if (value <= 1) {
        return 1;
    }
    value--;
    for (size_t shift = 1; shift < sizeof(value) * 8u; shift <<= 1u) {
        value |= value >> shift;
    }
    return value == SIZE_MAX ? 0 : value + 1u;
}

#define AVZ_MEMORY_STAT_INCREMENT(fast_path, field) \
    do { \
        if ((fast_path)->detailed_statistics_enabled) { \
            (fast_path)->statistics.field++; \
        } \
    } while (0)

static int avz_is_coherent_cache_maintenance(uint32_t instruction) {
    unsigned crn = (instruction >> 12u) & 0xfu;
    unsigned crm = (instruction >> 8u) & 0xfu;

    if (crn != 7u) {
        return 0;
    }

    /*
     * IC and DC clean/invalidate operations are coherent no-ops for the
     * interpreter. Guest stores update RAM immediately and advance code-page
     * generations. CRM=4 includes DC ZVA, which still requires a real fill.
     * CRM=8 contains address-translation operations and must remain slow.
     */
    return crm == 5u || crm == 6u ||
        (crm >= 10u && crm <= 14u);
}

static void avz_lock_flag(atomic_flag *lock) {
    while (atomic_flag_test_and_set_explicit(lock, memory_order_acquire)) {
    }
}

static void avz_guest_memory_lock_page_range(
    AVZGuestMemory *memory,
    size_t first_page,
    size_t last_page
) {
    if (memory == NULL || memory->page_locks == NULL ||
        first_page > last_page) {
        return;
    }
    size_t span = last_page - first_page + 1u;
    if (span >= AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT) {
        for (size_t index = 0; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
            avz_lock_flag(&memory->page_locks[index]);
        }
        return;
    }
    size_t first = first_page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u);
    size_t last = last_page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u);
    if (first <= last) {
        for (size_t index = first; index <= last; index++) {
            avz_lock_flag(&memory->page_locks[index]);
        }
    } else {
        for (size_t index = 0; index <= last; index++) {
            avz_lock_flag(&memory->page_locks[index]);
        }
        for (size_t index = first; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
            avz_lock_flag(&memory->page_locks[index]);
        }
    }
}

static void avz_guest_memory_unlock_page_range(
    AVZGuestMemory *memory,
    size_t first_page,
    size_t last_page
) {
    if (memory == NULL || memory->page_locks == NULL ||
        first_page > last_page) {
        return;
    }
    size_t span = last_page - first_page + 1u;
    if (span >= AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT) {
        for (size_t index = 0; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
            atomic_flag_clear_explicit(&memory->page_locks[index], memory_order_release);
        }
        return;
    }
    size_t first = first_page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u);
    size_t last = last_page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u);
    if (first <= last) {
        for (size_t index = first; index <= last; index++) {
            atomic_flag_clear_explicit(&memory->page_locks[index], memory_order_release);
        }
    } else {
        for (size_t index = 0; index <= last; index++) {
            atomic_flag_clear_explicit(&memory->page_locks[index], memory_order_release);
        }
        for (size_t index = first; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
            atomic_flag_clear_explicit(&memory->page_locks[index], memory_order_release);
        }
    }
}

static int avz_guest_memory_page_range(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    size_t *first_page,
    size_t *last_page
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return 0;
    }
    *first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    *last_page = (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    return 1;
}

static int avz_guest_memory_range_may_have_observation(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint8_t mask
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->page_observation_flags == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 1;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        if ((atomic_load_explicit(
                &memory->page_observation_flags[page],
                memory_order_acquire) & mask) != 0) {
            return 1;
        }
    }
    return 0;
}

enum {
    AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS =
        AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT / 64
};

static void avz_guest_memory_note_host_observation(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->host_page_observations == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->host_page_observations[page],
            1,
            memory_order_release
        );
        atomic_fetch_or_explicit(
            &memory->page_observation_flags[page],
            AVZ_GUEST_PAGE_OBSERVATION_HOST,
            memory_order_release
        );
    }
}

static int avz_guest_memory_range_has_host_observer(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->host_page_observations == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        if (atomic_load_explicit(
                &memory->host_page_observations[page],
                memory_order_acquire) != 0) {
            return 1;
        }
    }
    return 0;
}

static void avz_guest_memory_note_bulk_read(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->bulk_read_page_observations == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->bulk_read_page_observations[page],
            1,
            memory_order_release
        );
        atomic_fetch_or_explicit(
            &memory->page_observation_flags[page],
            AVZ_GUEST_PAGE_OBSERVATION_BULK_READER,
            memory_order_release
        );
    }
}

static int avz_guest_memory_range_has_bulk_reader(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->bulk_read_page_observations == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        if (atomic_load_explicit(
                &memory->bulk_read_page_observations[page],
                memory_order_acquire) != 0) {
            return 1;
        }
    }
    return 0;
}

static void avz_guest_memory_lock_range_internal(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        avz_guest_memory_lock_page_range(memory, first_page, last_page);
    }
}

static void avz_guest_memory_unlock_range_internal(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        avz_guest_memory_unlock_page_range(memory, first_page, last_page);
    }
}

void avz_guest_memory_lock_range(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    avz_guest_memory_note_host_observation(memory, offset, byte_count);
    avz_guest_memory_lock_range_internal(memory, offset, byte_count);
}

void avz_guest_memory_unlock_range(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    avz_guest_memory_unlock_range_internal(memory, offset, byte_count);
}

int avz_guest_memory_register_host_range(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (!avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }

    /*
     * Registration is an ownership boundary: callers must publish a shared
     * range before a device can consume it. Holding the page stripes while
     * publishing the observation synchronizes with all already-observed CPU
     * accesses and guarantees that subsequent CPU accesses take the same
     * stripes. Virtio queue setup satisfies the required ownership ordering.
     */
    avz_guest_memory_lock_page_range(memory, first_page, last_page);
    avz_guest_memory_note_host_observation(memory, offset, byte_count);
    atomic_thread_fence(memory_order_seq_cst);
    avz_guest_memory_unlock_page_range(memory, first_page, last_page);
    return 1;
}

int avz_guest_memory_host_range_is_registered(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (memory == NULL || memory->host_page_observations == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        if (atomic_load_explicit(
                &memory->host_page_observations[page],
                memory_order_acquire) == 0) {
            return 0;
        }
    }
    return 1;
}

static int avz_guest_memory_collect_range_locks(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint64_t *lock_bitmap
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (!avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }
    size_t span = last_page - first_page + 1u;
    if (span >= AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT) {
        for (size_t word = 0;
             word < AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS; word++) {
            lock_bitmap[word] = UINT64_MAX;
        }
        return 1;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        size_t stripe = page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u);
        lock_bitmap[stripe >> 6] |= UINT64_C(1) << (stripe & 63u);
    }
    return 1;
}

static void avz_guest_memory_lock_bitmap(
    AVZGuestMemory *memory,
    const uint64_t *lock_bitmap
) {
    for (size_t word = 0;
         word < AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS; word++) {
        uint64_t pending = lock_bitmap[word];
        while (pending != 0) {
            unsigned bit = (unsigned)__builtin_ctzll(pending);
            size_t stripe = word * 64u + bit;
            avz_lock_flag(&memory->page_locks[stripe]);
            pending &= pending - 1u;
        }
    }
}

static void avz_guest_memory_unlock_bitmap(
    AVZGuestMemory *memory,
    const uint64_t *lock_bitmap
) {
    for (size_t word = AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS;
         word-- > 0;) {
        uint64_t pending = lock_bitmap[word];
        while (pending != 0) {
            unsigned bit = 63u - (unsigned)__builtin_clzll(pending);
            size_t stripe = word * 64u + bit;
            atomic_flag_clear_explicit(
                &memory->page_locks[stripe], memory_order_release);
            pending &= ~(UINT64_C(1) << bit);
        }
    }
}

static int avz_guest_memory_collect_small_range_locks(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint16_t *stripes,
    size_t stripe_capacity,
    size_t *stripe_count
) {
    size_t first_page = 0;
    size_t last_page = 0;
    if (stripes == NULL || stripe_count == NULL ||
        !avz_guest_memory_page_range(
            memory, offset, byte_count, &first_page, &last_page)) {
        return 0;
    }
    for (size_t page = first_page; page <= last_page; page++) {
        uint16_t stripe = (uint16_t)(
            page & (AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT - 1u));
        size_t position = 0;
        while (position < *stripe_count && stripes[position] < stripe) {
            position++;
        }
        if (position < *stripe_count && stripes[position] == stripe) {
            continue;
        }
        if (*stripe_count >= stripe_capacity) {
            return 0;
        }
        memmove(
            stripes + position + 1,
            stripes + position,
            (*stripe_count - position) * sizeof(*stripes)
        );
        stripes[position] = stripe;
        (*stripe_count)++;
    }
    return 1;
}

static void avz_guest_memory_lock_small_set(
    AVZGuestMemory *memory,
    const uint16_t *stripes,
    size_t stripe_count
) {
    for (size_t index = 0; index < stripe_count; index++) {
        avz_lock_flag(&memory->page_locks[stripes[index]]);
    }
}

static void avz_guest_memory_unlock_small_set(
    AVZGuestMemory *memory,
    const uint16_t *stripes,
    size_t stripe_count
) {
    while (stripe_count != 0) {
        atomic_flag_clear_explicit(
            &memory->page_locks[stripes[--stripe_count]],
            memory_order_release
        );
    }
}

static int avz_guest_memory_lock_small_pair(
    AVZGuestMemory *memory,
    size_t first_offset,
    size_t first_byte_count,
    size_t second_offset,
    size_t second_byte_count,
    uint16_t *stripes,
    size_t stripe_capacity,
    size_t *stripe_count
) {
    *stripe_count = 0;
    if (!avz_guest_memory_collect_small_range_locks(
            memory,
            first_offset,
            first_byte_count,
            stripes,
            stripe_capacity,
            stripe_count) ||
        !avz_guest_memory_collect_small_range_locks(
            memory,
            second_offset,
            second_byte_count,
            stripes,
            stripe_capacity,
            stripe_count)) {
        return 0;
    }
    avz_guest_memory_lock_small_set(memory, stripes, *stripe_count);
    return 1;
}

int avz_guest_memory_lock_spans(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count
) {
    if (memory == NULL || spans == NULL || span_count == 0) {
        return 0;
    }
    uint64_t lock_bitmap[AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS] = {0};
    for (size_t index = 0; index < span_count; index++) {
        avz_guest_memory_note_host_observation(
            memory,
            spans[index].offset,
            spans[index].byte_count
        );
        if (!avz_guest_memory_collect_range_locks(
                memory,
                spans[index].offset,
                spans[index].byte_count,
                lock_bitmap)) {
            return 0;
        }
    }
    avz_guest_memory_lock_bitmap(memory, lock_bitmap);
    return 1;
}

void avz_guest_memory_unlock_spans(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count
) {
    if (memory == NULL || spans == NULL || span_count == 0) {
        return;
    }
    uint64_t lock_bitmap[AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS] = {0};
    for (size_t index = 0; index < span_count; index++) {
        if (!avz_guest_memory_collect_range_locks(
                memory,
                spans[index].offset,
                spans[index].byte_count,
                lock_bitmap)) {
            return;
        }
    }
    avz_guest_memory_unlock_bitmap(memory, lock_bitmap);
}

static void avz_guest_memory_lock_internal(AVZGuestMemory *memory) {
    if (memory == NULL || memory->page_locks == NULL) {
        return;
    }
    for (size_t index = 0; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
        avz_lock_flag(&memory->page_locks[index]);
    }
}

static void avz_guest_memory_unlock_internal(AVZGuestMemory *memory) {
    if (memory != NULL && memory->page_locks != NULL) {
        for (size_t index = 0; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
            atomic_flag_clear_explicit(&memory->page_locks[index], memory_order_release);
        }
    }
}

void avz_guest_memory_lock(AVZGuestMemory *memory) {
    if (memory == NULL) {
        return;
    }
    avz_guest_memory_note_host_observation(memory, 0, memory->size);
    avz_guest_memory_lock_internal(memory);
}

void avz_guest_memory_unlock(AVZGuestMemory *memory) {
    avz_guest_memory_unlock_internal(memory);
}

void avz_guest_memory_clear_host_observations(AVZGuestMemory *memory) {
    if (memory == NULL) {
        return;
    }
    for (size_t page = 0; page < memory->page_count; page++) {
        if (memory->host_page_observations != NULL) {
            atomic_store_explicit(
                &memory->host_page_observations[page],
                0,
                memory_order_release
            );
        }
        if (memory->bulk_read_page_observations != NULL) {
            atomic_store_explicit(
                &memory->bulk_read_page_observations[page],
                0,
                memory_order_release
            );
        }
        if (memory->page_observation_flags != NULL) {
            atomic_fetch_and_explicit(
                &memory->page_observation_flags[page],
                (uint8_t)~(
                    AVZ_GUEST_PAGE_OBSERVATION_HOST |
                    AVZ_GUEST_PAGE_OBSERVATION_BULK_READER),
                memory_order_release
            );
        }
    }
}

static uint16_t avz_system_register_key(uint32_t instruction) {
    uint16_t op0 = (uint16_t)((instruction >> 19) & 0x3u);
    uint16_t op1 = (uint16_t)((instruction >> 16) & 0x7u);
    uint16_t crn = (uint16_t)((instruction >> 12) & 0xfu);
    uint16_t crm = (uint16_t)((instruction >> 8) & 0xfu);
    uint16_t op2 = (uint16_t)((instruction >> 5) & 0x7u);
    return (uint16_t)(
        (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2
    );
}

#define AVZ_SYSTEM_REGISTER_KEY(op0, op1, crn, crm, op2) \
    ((uint16_t)( \
        ((uint16_t)(op0) << 14) | ((uint16_t)(op1) << 11) | \
        ((uint16_t)(crn) << 7) | ((uint16_t)(crm) << 3) | (uint16_t)(op2) \
    ))

enum {
    AVZ_SYSREG_SPSR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 0, 0),
    AVZ_SYSREG_ELR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 0, 1),
    AVZ_SYSREG_SP_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 4, 1, 0),
    AVZ_SYSREG_ESR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 5, 2, 0),
    AVZ_SYSREG_FAR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 6, 0, 0),
    AVZ_SYSREG_VBAR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 12, 0, 0),
    AVZ_SYSREG_CONTEXTIDR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 13, 0, 1),
    AVZ_SYSREG_TPIDR_EL1 = AVZ_SYSTEM_REGISTER_KEY(3, 0, 13, 0, 4),
    AVZ_SYSREG_TPIDR_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 13, 0, 2),
    AVZ_SYSREG_TPIDRRO_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 13, 0, 3),
    AVZ_SYSREG_CNTPCT_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 0, 1),
    AVZ_SYSREG_CNTVCT_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 0, 2),
    AVZ_SYSREG_CNTP_TVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 0),
    AVZ_SYSREG_CNTP_CTL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 1),
    AVZ_SYSREG_CNTP_CVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 2, 2),
    AVZ_SYSREG_CNTV_TVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 0),
    AVZ_SYSREG_CNTV_CTL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 1),
    AVZ_SYSREG_CNTV_CVAL_EL0 = AVZ_SYSTEM_REGISTER_KEY(3, 3, 14, 3, 2)
};

AVZGuestMemory *avz_guest_memory_create(size_t size) {
    if (size == 0 || size > SIZE_MAX - (AVZ_FAST_PAGE_SIZE - 1u)) {
        return 0;
    }
    AVZGuestMemory *memory = calloc(1, sizeof(*memory));
    if (memory == 0) {
        return 0;
    }
    void *mapping = mmap(
        0,
        size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (mapping == MAP_FAILED) {
        free(memory);
        return 0;
    }
    memory->bytes = mapping;
    memory->size = size;
    memory->page_count = (size + AVZ_FAST_PAGE_SIZE - 1u) >>
        AVZ_FAST_PAGE_SHIFT;
    memory->page_epochs = calloc(
        memory->page_count,
        sizeof(*memory->page_epochs)
    );
    if (memory->page_epochs == NULL) {
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->page_write_generations = calloc(
        memory->page_count,
        sizeof(*memory->page_write_generations)
    );
    if (memory->page_write_generations == NULL) {
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->page_exclusive_observation_epochs = calloc(
        memory->page_count,
        sizeof(*memory->page_exclusive_observation_epochs)
    );
    if (memory->page_exclusive_observation_epochs == NULL) {
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->host_page_observations = calloc(
        memory->page_count,
        sizeof(*memory->host_page_observations)
    );
    if (memory->host_page_observations == NULL) {
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->bulk_read_page_observations = calloc(
        memory->page_count,
        sizeof(*memory->bulk_read_page_observations)
    );
    if (memory->bulk_read_page_observations == NULL) {
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->page_observation_flags = calloc(
        memory->page_count,
        sizeof(*memory->page_observation_flags)
    );
    if (memory->page_observation_flags == NULL) {
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    if (memory->page_count > SIZE_MAX / AVZ_EXCLUSIVE_SLOT_SCALE) {
        free(memory->page_observation_flags);
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    size_t requested_exclusive_slots =
        memory->page_count * AVZ_EXCLUSIVE_SLOT_SCALE;
    if (requested_exclusive_slots < AVZ_EXCLUSIVE_MINIMUM_SLOT_COUNT) {
        requested_exclusive_slots = AVZ_EXCLUSIVE_MINIMUM_SLOT_COUNT;
    }
    memory->exclusive_slot_count = avz_next_power_of_two(
        requested_exclusive_slots
    );
    if (memory->exclusive_slot_count == 0) {
        free(memory->page_observation_flags);
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->exclusive_slot_mask = memory->exclusive_slot_count - 1u;
    memory->exclusive_write_generations = calloc(
        memory->exclusive_slot_count,
        sizeof(*memory->exclusive_write_generations)
    );
    memory->exclusive_observations = calloc(
        memory->exclusive_slot_count,
        sizeof(*memory->exclusive_observations)
    );
    if (memory->exclusive_write_generations == NULL ||
        memory->exclusive_observations == NULL) {
        free(memory->exclusive_observations);
        free(memory->exclusive_write_generations);
        free(memory->page_observation_flags);
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->page_locks = calloc(
        AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT,
        sizeof(*memory->page_locks)
    );
    if (memory->page_locks == NULL) {
        free(memory->exclusive_observations);
        free(memory->exclusive_write_generations);
        free(memory->page_observation_flags);
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    memory->code_page_bits = calloc(
        (memory->page_count + 7u) / 8u,
        sizeof(*memory->code_page_bits)
    );
    if (memory->code_page_bits == NULL) {
        free(memory->page_locks);
        free(memory->exclusive_observations);
        free(memory->exclusive_write_generations);
        free(memory->page_observation_flags);
        free(memory->bulk_read_page_observations);
        free(memory->host_page_observations);
        free(memory->page_exclusive_observation_epochs);
        free(memory->page_write_generations);
        free(memory->page_epochs);
        munmap(memory->bytes, memory->size);
        free(memory);
        return 0;
    }
    atomic_init(&memory->current_epoch, 1);
    atomic_init(&memory->current_write_generation, 1);
    atomic_init(&memory->code_mutation_epoch, 1);
    atomic_init(&memory->translation_epoch, 1);
    atomic_flag_clear(&memory->translation_lock);
    atomic_init(&memory->exclusive_reads, 0);
    atomic_init(&memory->exclusive_nonzero_reads, 0);
    atomic_init(&memory->exclusive_write_successes, 0);
    atomic_init(&memory->exclusive_write_conflicts, 0);
    for (size_t index = 0; index < AVZ_GUEST_MEMORY_LOCK_STRIPE_COUNT; index++) {
        atomic_flag_clear(&memory->page_locks[index]);
    }
    return memory;
}

void avz_guest_memory_destroy(AVZGuestMemory *memory) {
    if (memory == 0) {
        return;
    }
    if (memory->bytes != 0 && memory->size > 0) {
        munmap(memory->bytes, memory->size);
    }
    free(memory->page_epochs);
    free(memory->page_write_generations);
    free(memory->page_exclusive_observation_epochs);
    free(memory->host_page_observations);
    free(memory->bulk_read_page_observations);
    free(memory->page_observation_flags);
    free(memory->exclusive_write_generations);
    free(memory->exclusive_observations);
    free(memory->page_locks);
    free(memory->code_page_bits);
    free(memory);
}

void avz_guest_memory_mark_code_page(
    AVZGuestMemory *memory,
    uint64_t physical_page,
    uint64_t ram_base
) {
    if (memory == NULL || physical_page < ram_base) {
        return;
    }
    uint64_t offset = physical_page - ram_base;
    if (offset >= memory->size) {
        return;
    }
    size_t page = (size_t)offset >> AVZ_FAST_PAGE_SHIFT;
    atomic_fetch_or_explicit(
        &memory->code_page_bits[page >> 3],
        (uint8_t)(1u << (page & 7u)),
        memory_order_relaxed
    );
}

int avz_guest_memory_range_may_contain_code(
    const AVZGuestMemory *memory,
    uint64_t physical_address,
    size_t byte_count,
    uint64_t ram_base
) {
    if (memory == NULL || byte_count == 0 || physical_address < ram_base) {
        return 0;
    }
    uint64_t offset_u64 = physical_address - ram_base;
    if (offset_u64 > SIZE_MAX || (size_t)offset_u64 >= memory->size ||
        byte_count > memory->size - (size_t)offset_u64) {
        return 0;
    }
    size_t first_page = (size_t)offset_u64 >> AVZ_FAST_PAGE_SHIFT;
    size_t last_page = ((size_t)offset_u64 + byte_count - 1u) >>
        AVZ_FAST_PAGE_SHIFT;
    for (size_t page = first_page; page <= last_page; page++) {
        uint8_t bits = atomic_load_explicit(
            &memory->code_page_bits[page >> 3], memory_order_relaxed);
        if ((bits & (uint8_t)(1u << (page & 7u))) != 0) {
            return 1;
        }
    }
    return 0;
}

static void avz_guest_memory_advance_code_mutation_epoch(
    AVZGuestMemory *memory
) {
    uint64_t epoch = atomic_fetch_add_explicit(
        &memory->code_mutation_epoch,
        1,
        memory_order_acq_rel
    ) + 1;
    if (epoch == 0) {
        atomic_store_explicit(
            &memory->code_mutation_epoch,
            1,
            memory_order_release
        );
    }
}

uint64_t avz_guest_memory_code_mutation_epoch(
    const AVZGuestMemory *memory
) {
    return memory == NULL ? 0 : atomic_load_explicit(
        &memory->code_mutation_epoch,
        memory_order_acquire
    );
}

const uint64_t *avz_guest_memory_code_mutation_epoch_token(
    const AVZGuestMemory *memory
) {
    return memory == NULL
        ? NULL
        : (const uint64_t *)&memory->code_mutation_epoch;
}

static uint64_t avz_guest_memory_next_write_generation(
    AVZGuestMemory *memory
) {
    uint64_t generation = atomic_fetch_add_explicit(
        &memory->current_write_generation,
        1,
        memory_order_acq_rel
    ) + 1;
    if (generation == 0) {
        generation = 1;
        atomic_store_explicit(
            &memory->current_write_generation,
            generation,
            memory_order_release
        );
    }
    return generation;
}

static void avz_guest_memory_note_page_write_generation(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    const uint64_t generation = avz_guest_memory_next_write_generation(memory);
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->page_write_generations[page],
            generation,
            memory_order_release
        );
    }
}

static size_t avz_guest_memory_exclusive_slot(
    const AVZGuestMemory *memory,
    size_t granule
) {
    uint64_t value = (uint64_t)granule;
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return (size_t)value & memory->exclusive_slot_mask;
}

static void avz_guest_memory_note_exclusive_observation(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->page_exclusive_observation_epochs[page],
            1,
            memory_order_release
        );
        atomic_fetch_or_explicit(
            &memory->page_observation_flags[page],
            AVZ_GUEST_PAGE_OBSERVATION_EXCLUSIVE,
            memory_order_release
        );
    }
    const size_t first_granule = offset >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t last_granule =
        (offset + byte_count - 1u) >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    for (size_t granule = first_granule;
         granule <= last_granule; granule++) {
        const size_t slot = avz_guest_memory_exclusive_slot(memory, granule);
        atomic_store_explicit(
            &memory->exclusive_observations[slot],
            1,
            memory_order_release
        );
    }
}

static void avz_guest_memory_note_exclusive_write_generation(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    const size_t first_granule = offset >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t last_granule =
        (offset + byte_count - 1u) >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t granules_per_page =
        (size_t)1u << (AVZ_FAST_PAGE_SHIFT - AVZ_EXCLUSIVE_GRANULE_SHIFT);
    const size_t first_page = first_granule /
        granules_per_page;
    const size_t last_page = last_granule /
        granules_per_page;
    uint64_t generation = 0;
    for (size_t page = first_page; page <= last_page; page++) {
        if (atomic_load_explicit(
                &memory->page_exclusive_observation_epochs[page],
                memory_order_acquire) == 0) {
            continue;
        }
        const size_t page_first_granule = page * granules_per_page;
        const size_t observed_first = first_granule > page_first_granule
            ? first_granule
            : page_first_granule;
        const size_t page_last_granule =
            page_first_granule + granules_per_page - 1u;
        const size_t observed_last = last_granule < page_last_granule
            ? last_granule
            : page_last_granule;
        for (size_t granule = observed_first;
             granule <= observed_last; granule++) {
            const size_t slot =
                avz_guest_memory_exclusive_slot(memory, granule);
            if (atomic_load_explicit(
                    &memory->exclusive_observations[slot],
                    memory_order_acquire) == 0) {
                continue;
            }
            if (generation == 0) {
                generation = avz_guest_memory_next_write_generation(memory);
            }
            atomic_store_explicit(
                &memory->exclusive_write_generations[slot],
                generation,
                memory_order_release
            );
        }
    }
}

static int avz_guest_memory_range_has_exclusive_observer(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return 1;
    }
    const size_t first_granule = offset >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t last_granule =
        (offset + byte_count - 1u) >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t granules_per_page =
        (size_t)1u << (AVZ_FAST_PAGE_SHIFT - AVZ_EXCLUSIVE_GRANULE_SHIFT);
    const size_t first_page = first_granule /
        granules_per_page;
    const size_t last_page = last_granule /
        granules_per_page;
    for (size_t page = first_page; page <= last_page; page++) {
        if (atomic_load_explicit(
                &memory->page_exclusive_observation_epochs[page],
                memory_order_acquire) == 0) {
            continue;
        }
        const size_t page_first_granule = page * granules_per_page;
        const size_t observed_first = first_granule > page_first_granule
            ? first_granule
            : page_first_granule;
        const size_t page_last_granule =
            page_first_granule + granules_per_page - 1u;
        const size_t observed_last = last_granule < page_last_granule
            ? last_granule
            : page_last_granule;
        for (size_t granule = observed_first;
             granule <= observed_last; granule++) {
            const size_t slot =
                avz_guest_memory_exclusive_slot(memory, granule);
            if (atomic_load_explicit(
                    &memory->exclusive_observations[slot],
                    memory_order_acquire) != 0) {
                return 1;
            }
        }
    }
    return 0;
}

int avz_guest_memory_range_requires_serialization(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    return avz_guest_memory_range_has_host_observer(
            memory, offset, byte_count) ||
        avz_guest_memory_range_has_bulk_reader(
            memory, offset, byte_count) ||
        avz_guest_memory_range_has_exclusive_observer(
            memory, offset, byte_count);
}

void avz_guest_memory_note_write(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    int touches_code = avz_guest_memory_range_may_contain_code(
        memory,
        (uint64_t)offset,
        byte_count,
        0
    );
    avz_guest_memory_mark_dirty(memory, offset, byte_count);
    avz_guest_memory_note_exclusive_write_generation(
        memory, offset, byte_count);
    if (touches_code) {
        avz_guest_memory_note_page_write_generation(
            memory, offset, byte_count);
        avz_guest_memory_advance_code_mutation_epoch(memory);
    }
}

void avz_guest_memory_note_device_write(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    avz_guest_memory_note_host_observation(memory, offset, byte_count);
    int touches_code = avz_guest_memory_range_may_contain_code(
        memory,
        (uint64_t)offset,
        byte_count,
        0
    );
    avz_guest_memory_note_exclusive_write_generation(
        memory, offset, byte_count);
    if (touches_code) {
        avz_guest_memory_note_page_write_generation(
            memory, offset, byte_count);
        avz_guest_memory_advance_code_mutation_epoch(memory);
    }
}

int avz_guest_memory_load_u16_acquire(
    AVZGuestMemory *memory,
    size_t offset,
    uint16_t *value
) {
    if (memory == NULL || value == NULL || offset > memory->size ||
        sizeof(uint16_t) > memory->size - offset ||
        (offset & (sizeof(uint16_t) - 1u)) != 0) {
        return 0;
    }

    avz_guest_memory_lock_range(memory, offset, sizeof(uint16_t));
    uint16_t loaded = __atomic_load_n(
        (const uint16_t *)(memory->bytes + offset),
        __ATOMIC_ACQUIRE
    );
    avz_guest_memory_unlock_range(memory, offset, sizeof(uint16_t));
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    loaded = __builtin_bswap16(loaded);
#endif
    *value = loaded;
    return 1;
}

int avz_guest_memory_store_u16_release(
    AVZGuestMemory *memory,
    size_t offset,
    uint16_t value
) {
    if (memory == NULL || offset > memory->size ||
        sizeof(uint16_t) > memory->size - offset ||
        (offset & (sizeof(uint16_t) - 1u)) != 0) {
        return 0;
    }

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap16(value);
#endif
    avz_guest_memory_lock_range(memory, offset, sizeof(uint16_t));
    avz_guest_memory_note_write(memory, offset, sizeof(uint16_t));
    __atomic_store_n(
        (uint16_t *)(memory->bytes + offset),
        value,
        __ATOMIC_RELEASE
    );
    avz_guest_memory_unlock_range(memory, offset, sizeof(uint16_t));
    return 1;
}

AVZNativeTLBI avz_native_decode_tlbi(
    uint32_t instruction, uint64_t operand, uint64_t tcr_el1
) {
    /* Arm DDI 0601: EL1 VMALLE1, VAE1/VALE1, ASIDE1, VAAE1/VAALE1.
     * TTL is a hint: ignoring it and invalidating all matching levels is safe.
     * Range, nXS, other regimes and unknown encodings conservatively broadcast. */
    AVZNativeTLBI result = { .kind = AVZ_TLBI_ALL, .broadcast = 1 };
    unsigned crm = (instruction >> 8) & 15u;
    unsigned op2 = (instruction >> 5) & 7u;
    if ((instruction & UINT32_C(0xfff8f000)) != UINT32_C(0xd5088000) ||
        ((instruction >> 16) & 7u) != 0 ||
        (crm != 7 && crm != 3 && crm != 1) || op2 == 4 || op2 == 6) {
        return result;
    }
    result.broadcast = crm != 7;
    result.asid = (uint16_t)(operand >> 48);
    if ((tcr_el1 & (UINT64_C(1) << 36)) == 0) {
        result.asid &= 0xffu;
    }
    /* VA[55:12], excluding TTL[47:44] and ASID[63:48]. */
    result.virtual_address = (operand & UINT64_C(0x00000fffffffffff)) << 12;
    switch (op2) {
        case 1: case 5: result.kind = AVZ_TLBI_VA_ASID; break;
        case 2: result.kind = AVZ_TLBI_ASID; break;
        case 3: case 7: result.kind = AVZ_TLBI_VA_ALL_ASIDS; break;
        default: break;
    }
    return result;
}

static void avz_translation_lock(AVZGuestMemory *memory) {
    while (atomic_flag_test_and_set_explicit(
        &memory->translation_lock, memory_order_acquire)) {}
}

void avz_guest_memory_publish_tlbi(
    AVZGuestMemory *memory, AVZNativeTLBI invalidation
) {
    if (memory == NULL) {
        return;
    }
    avz_translation_lock(memory);
    uint64_t epoch = atomic_load_explicit(
        &memory->translation_epoch, memory_order_relaxed) + 1;
    if (epoch == 0) {
        epoch = 1;
        invalidation.kind = AVZ_TLBI_ALL;
    }
    memory->translation_journal[epoch % AVZ_TLBI_JOURNAL_COUNT] = invalidation;
    atomic_store_explicit(&memory->translation_epoch, epoch, memory_order_release);
    atomic_flag_clear_explicit(&memory->translation_lock, memory_order_release);
}

void avz_guest_memory_invalidate_translations(AVZGuestMemory *memory) {
    avz_guest_memory_publish_tlbi(memory, (AVZNativeTLBI){
        .kind = AVZ_TLBI_ALL, .broadcast = 1
    });
}

uint64_t avz_guest_memory_translation_epoch(const AVZGuestMemory *memory) {
    return memory == NULL ? 0 : atomic_load_explicit(
        &memory->translation_epoch,
        memory_order_acquire
    );
}

uint8_t *avz_guest_memory_bytes(AVZGuestMemory *memory) {
    return memory == 0 ? 0 : memory->bytes;
}

size_t avz_guest_memory_size(const AVZGuestMemory *memory) {
    return memory == 0 ? 0 : memory->size;
}

void avz_guest_memory_mark_dirty(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    const uint64_t current_epoch = atomic_load_explicit(
        &memory->current_epoch,
        memory_order_relaxed
    );
    for (size_t page = first_page; page <= last_page; page++) {
        atomic_store_explicit(
            &memory->page_epochs[page],
            current_epoch,
            memory_order_release
        );
    }
}

uint64_t avz_guest_memory_advance_dirty_epoch(AVZGuestMemory *memory) {
    if (memory == NULL) {
        return 0;
    }
    uint64_t completed_epoch = atomic_load_explicit(
        &memory->current_epoch,
        memory_order_acquire
    );
    while (completed_epoch != UINT64_MAX &&
           !atomic_compare_exchange_weak_explicit(
               &memory->current_epoch,
               &completed_epoch,
               completed_epoch + 1,
               memory_order_acq_rel,
               memory_order_acquire
           )) {
    }
    return completed_epoch;
}

size_t avz_guest_memory_dirty_ranges(
    const AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count,
    uint64_t after_epoch,
    uint64_t through_epoch,
    AVZGuestDirtyRange *ranges,
    size_t range_capacity
) {
    if (memory == NULL || ranges == NULL || range_capacity == 0 ||
        byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset || through_epoch < after_epoch) {
        return 0;
    }

    const size_t requested_end = offset + byte_count;
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (requested_end - 1u) >> AVZ_FAST_PAGE_SHIFT;
    size_t range_count = 0;
    size_t page = first_page;
    while (page <= last_page) {
        const uint64_t epoch = atomic_load_explicit(
            &memory->page_epochs[page],
            memory_order_acquire
        );
        if (epoch <= after_epoch || epoch > through_epoch) {
            page++;
            continue;
        }

        const size_t run_start_page = page;
        do {
            page++;
            if (page > last_page) {
                break;
            }
            const uint64_t next_epoch = atomic_load_explicit(
                &memory->page_epochs[page],
                memory_order_acquire
            );
            if (next_epoch <= after_epoch || next_epoch > through_epoch) {
                break;
            }
        } while (1);

        if (range_count == range_capacity) {
            ranges[0] = (AVZGuestDirtyRange){
                .offset = offset,
                .length = byte_count
            };
            return 1;
        }
        const size_t run_start = run_start_page << AVZ_FAST_PAGE_SHIFT;
        const size_t run_end = page << AVZ_FAST_PAGE_SHIFT;
        const size_t clipped_start = run_start > offset ? run_start : offset;
        const size_t clipped_end = run_end < requested_end
            ? run_end
            : requested_end;
        ranges[range_count++] = (AVZGuestDirtyRange){
            .offset = clipped_start,
            .length = clipped_end - clipped_start
        };
    }
    return range_count;
}

static int avz_fast_mark_dirty(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t physical_address,
    size_t byte_count
) {
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        physical_address < fast_path->ram_base || byte_count == 0) {
        return 0;
    }
    const uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > SIZE_MAX) {
        return 0;
    }
    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t raw_offset = (size_t)offset;
    if (raw_offset >= memory->size ||
        byte_count > memory->size - raw_offset) {
        return 0;
    }
    size_t first_page = raw_offset >> AVZ_FAST_PAGE_SHIFT;
    size_t last_page = (raw_offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    uint64_t epoch = atomic_load_explicit(
        &memory->current_epoch, memory_order_relaxed);
    int mutated_code = 0;
    for (size_t page = first_page; page <= last_page; page++) {
        size_t slot = page & (AVZ_FAST_DIRTY_HOT_COUNT - 1u);
        uint64_t page_physical = fast_path->ram_base +
            ((uint64_t)page << AVZ_FAST_PAGE_SHIFT);
        int page_contains_code = avz_guest_memory_range_may_contain_code(
            memory, page_physical, 1, fast_path->ram_base);
        mutated_code |= page_contains_code;
        AVZNativeDirtyHotEntry *dirty_entry = &fast_path->dirty_hot[slot];
        if (dirty_entry->valid && dirty_entry->page == page &&
            dirty_entry->epoch == epoch) {
            continue;
        }
        atomic_store_explicit(
            &memory->page_epochs[page], epoch, memory_order_release);
        *dirty_entry = (AVZNativeDirtyHotEntry){
            .page = page,
            .epoch = epoch,
            .valid = 1
        };
    }
    avz_guest_memory_note_exclusive_write_generation(
        memory, raw_offset, byte_count);
    if (mutated_code) {
        avz_guest_memory_note_page_write_generation(
            memory, raw_offset, byte_count);
        avz_guest_memory_advance_code_mutation_epoch(memory);
    }
    return mutated_code;
}

static void avz_fast_invalidate_code_after_write(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t physical_address,
    size_t byte_count,
    int range_contains_code
) {
    if (fast_path == NULL || fast_path->block_cache == NULL ||
        byte_count == 0) {
        return;
    }
    if (fast_path->guest_memory != NULL && !range_contains_code) {
        return;
    }
    avz_native_block_cache_invalidate_physical_range(
        fast_path->block_cache,
        physical_address,
        byte_count
    );
}

static int avz_fast_width_supported(uint8_t width) {
    return width == 1 || width == 2 || width == 4 || width == 8;
}

enum {
    AVZ_NATIVE_TRANSLATION_FAULT = 0,
    AVZ_NATIVE_TRANSLATION_SUCCESS = 1,
    AVZ_NATIVE_TRANSLATION_UNAVAILABLE = 2
};

static void avz_fast_clear_hot_tlbs(AVZNativeMemoryFastPath *fast_path) {
    /* Hot copies are certified for one ASID/TLBI epoch. Reuse the existing
     * generation comparison, keeping indexed validation off ordinary loads. */
    if (++fast_path->hot_translation_generation == 0) {
        memset(fast_path->read_hot, 0, sizeof(fast_path->read_hot));
        memset(fast_path->write_hot, 0, sizeof(fast_path->write_hot));
        memset(fast_path->instruction_hot, 0, sizeof(fast_path->instruction_hot));
        fast_path->hot_translation_generation = 1;
    }
}

static void avz_fast_clear_tlbs(AVZNativeMemoryFastPath *fast_path) {
    avz_fast_clear_hot_tlbs(fast_path);
    fast_path->translation_generation++;
    if (fast_path->translation_generation == 0) {
        memset(fast_path->read_tlb, 0, sizeof(fast_path->read_tlb));
        memset(fast_path->write_tlb, 0, sizeof(fast_path->write_tlb));
        memset(
            fast_path->instruction_tlb,
            0,
            sizeof(fast_path->instruction_tlb)
        );
        fast_path->translation_generation = 1;
        memset(fast_path->read_hot, 0, sizeof(fast_path->read_hot));
        memset(fast_path->write_hot, 0, sizeof(fast_path->write_hot));
        memset(fast_path->instruction_hot, 0, sizeof(fast_path->instruction_hot));
    }
}

static size_t avz_tlbi_va_slot(uint64_t address, uint8_t shift, uint16_t asid) {
    uint64_t key = (address & UINT64_C(0x00ffffffffffffff)) >> shift;
    key ^= (uint64_t)asid * UINT64_C(0x9e3779b97f4a7c15);
    key ^= (uint64_t)shift * UINT64_C(0xbf58476d1ce4e5b9);
    key ^= key >> 23;
    key ^= key >> 12;
    return (size_t)(key & (AVZ_TLBI_VA_SLOT_COUNT - 1));
}

int avz_native_fast_revalidate_tlb_entry(
    AVZNativeMemoryFastPath *fast_path, AVZNativeFastTLBEntry *entry
) {
    uint64_t epoch = entry->tlbi_epoch;
    uint64_t address = entry->virtual_page << 12;
    size_t va_slot = avz_tlbi_va_slot(address, entry->leaf_shift, 0);
    int stale = entry->leaf_shift == 0 ||
        fast_path->va_all_tlbi_epochs[va_slot] > epoch;
    if (entry->global) {
        stale |= fast_path->va_global_tlbi_epochs[va_slot] > epoch;
    } else {
        size_t asid_slot = avz_tlbi_va_slot(address, entry->leaf_shift, entry->asid);
        stale |= fast_path->asid_tlbi_epochs[entry->asid] > epoch ||
            fast_path->va_asid_tlbi_epochs[asid_slot] > epoch;
    }
    if (stale) entry->valid = 0;
    else entry->tlbi_epoch = fast_path->tlbi_epoch;
    return !stale;
}

static void avz_fast_apply_tlbi_entries(
    AVZNativeMemoryFastPath *fast_path, AVZNativeTLBI invalidation
) {
    if (invalidation.kind == AVZ_TLBI_ALL ||
        invalidation.kind > AVZ_TLBI_VA_ALL_ASIDS) {
        avz_fast_clear_tlbs(fast_path);
        return;
    }
    avz_fast_clear_hot_tlbs(fast_path);
    if (++fast_path->tlbi_epoch == 0) {
        avz_fast_clear_tlbs(fast_path);
        memset(fast_path->asid_tlbi_epochs, 0, sizeof(fast_path->asid_tlbi_epochs));
        memset(fast_path->va_asid_tlbi_epochs, 0, sizeof(fast_path->va_asid_tlbi_epochs));
        memset(fast_path->va_all_tlbi_epochs, 0, sizeof(fast_path->va_all_tlbi_epochs));
        memset(fast_path->va_global_tlbi_epochs, 0, sizeof(fast_path->va_global_tlbi_epochs));
        fast_path->tlbi_epoch = 1;
    }
    uint64_t epoch = fast_path->tlbi_epoch;
    if (invalidation.kind == AVZ_TLBI_ASID) {
        fast_path->asid_tlbi_epochs[invalidation.asid] = epoch;
        return;
    }
    /* Fixed work independent of TLB occupancy. Record each supported 4KB
     * page/block extent, including contiguous groups. Hash collisions only
     * over-invalidate; timestamps cannot lose an earlier invalidation. */
    static const uint8_t shifts[] = { 12, 16, 21, 25, 30, 34, 39, 43 };
    for (size_t index = 0; index < sizeof(shifts); index++) {
        size_t slot = avz_tlbi_va_slot(invalidation.virtual_address, shifts[index], 0);
        if (invalidation.kind == AVZ_TLBI_VA_ALL_ASIDS) {
            fast_path->va_all_tlbi_epochs[slot] = epoch;
        } else {
            fast_path->va_global_tlbi_epochs[slot] = epoch;
            slot = avz_tlbi_va_slot(invalidation.virtual_address, shifts[index], invalidation.asid);
            fast_path->va_asid_tlbi_epochs[slot] = epoch;
        }
    }
}

static void avz_fast_invalidate_decoded_mappings(AVZNativeMemoryFastPath *fast_path) {
    avz_native_block_cache_invalidate_translation_mappings(fast_path->block_cache);
}

void avz_native_memory_fast_path_apply_tlbi(
    AVZNativeMemoryFastPath *fast_path, AVZNativeTLBI invalidation
) {
    if (fast_path == NULL) return;
    avz_fast_apply_tlbi_entries(fast_path, invalidation);
    avz_fast_invalidate_decoded_mappings(fast_path);
    fast_path->translation_fault_pending = 0;
}

static void avz_fast_synchronize_shared_translation_epoch(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path == NULL || fast_path->guest_memory == NULL) {
        return;
    }
    uint64_t epoch = atomic_load_explicit(
        &fast_path->guest_memory->translation_epoch,
        memory_order_relaxed
    );
    if (epoch == fast_path->observed_shared_translation_epoch) {
        return;
    }
    /* Copy under the publication lock; never access a peer's private TLB.
     * Acquiring this lock also publishes the preceding page-table writes. */
    AVZGuestMemory *memory = fast_path->guest_memory;
    AVZNativeTLBI pending[AVZ_TLBI_JOURNAL_COUNT];
    size_t count = 0;
    avz_translation_lock(memory);
    epoch = atomic_load_explicit(
        &memory->translation_epoch, memory_order_relaxed
    );
    uint64_t observed = fast_path->observed_shared_translation_epoch;
    if (epoch < observed || epoch - observed > AVZ_TLBI_JOURNAL_COUNT) {
        pending[count++] = (AVZNativeTLBI){ .kind = AVZ_TLBI_ALL };
    } else {
        for (uint64_t index = 1; index <= epoch - observed; index++) {
            pending[count++] = memory->translation_journal[
                (observed + index) % AVZ_TLBI_JOURNAL_COUNT];
        }
    }
    atomic_flag_clear_explicit(&memory->translation_lock, memory_order_release);
    for (size_t index = 0; index < count; index++) {
        avz_fast_apply_tlbi_entries(fast_path, pending[index]);
        if (pending[index].kind == AVZ_TLBI_ALL) break;
    }
    if (count != 0) avz_fast_invalidate_decoded_mappings(fast_path);
    fast_path->observed_shared_translation_epoch = epoch;
}

void avz_native_memory_fast_path_synchronize_translations(
    AVZNativeMemoryFastPath *fast_path
) {
    avz_fast_synchronize_shared_translation_epoch(fast_path);
}

static int avz_stage1_translation_state_equal(
    const AVZNativeStage1TranslationState *lhs,
    const AVZNativeStage1TranslationState *rhs
) {
    return lhs->sctlr_el1 == rhs->sctlr_el1 &&
        lhs->tcr_el1 == rhs->tcr_el1 &&
        lhs->ttbr0_el1 == rhs->ttbr0_el1 &&
        lhs->ttbr1_el1 == rhs->ttbr1_el1 &&
        lhs->current_el == rhs->current_el;
}

static int avz_stage1_translation_geometry_equal(
    const AVZNativeStage1TranslationState *lhs,
    const AVZNativeStage1TranslationState *rhs
) {
    return lhs->sctlr_el1 == rhs->sctlr_el1 &&
        lhs->tcr_el1 == rhs->tcr_el1;
}

static uint64_t avz_fast_mix_u64(uint64_t value) {
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return value;
}

static uint16_t avz_stage1_asid(const AVZNativeStage1TranslationState *state) {
    uint64_t ttbr = (state->tcr_el1 & (UINT64_C(1) << 22)) != 0
        ? state->ttbr1_el1 : state->ttbr0_el1;
    uint16_t asid = (uint16_t)(ttbr >> 48);
    return (state->tcr_el1 & (UINT64_C(1) << 36)) != 0 ? asid : asid & 0xffu;
}

static uint64_t avz_fast_translation_context_tag_for_ttbr(
    const AVZNativeStage1TranslationState *state,
    uint64_t ttbr
) {
    uint64_t hash = avz_fast_mix_u64(state->sctlr_el1);
    hash ^= avz_fast_mix_u64(state->tcr_el1);
    hash ^= avz_fast_mix_u64(ttbr & AVZ_STAGE1_OUTPUT_ADDRESS_MASK);
    hash ^= avz_fast_mix_u64(state->current_el);
    return avz_fast_mix_u64(hash);
}

static void avz_fast_refresh_translation_context_tags(
    AVZNativeMemoryFastPath *fast_path
) {
    const AVZNativeStage1TranslationState *state =
        &fast_path->translation_state;
    uint16_t asid = avz_stage1_asid(state);
    if (asid != fast_path->translation_asid) avz_fast_clear_hot_tlbs(fast_path);
    fast_path->translation_asid = asid;
    fast_path->low_translation_context_tag =
        avz_fast_translation_context_tag_for_ttbr(state, state->ttbr0_el1);
    fast_path->high_translation_context_tag =
        avz_fast_translation_context_tag_for_ttbr(state, state->ttbr1_el1);
    fast_path->low_translation_context_hash =
        avz_fast_mix_u64(fast_path->low_translation_context_tag);
    fast_path->high_translation_context_hash =
        avz_fast_mix_u64(fast_path->high_translation_context_tag);
}

static uint64_t avz_fast_translation_context_tag(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address
) {
    if (!fast_path->native_translation_enabled) {
        return 0;
    }
    return virtual_address >> 63
        ? fast_path->high_translation_context_tag
        : fast_path->low_translation_context_tag;
}

static uint64_t avz_fast_translation_context_hash(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address
) {
    if (!fast_path->native_translation_enabled) {
        return 0;
    }
    return virtual_address >> 63
        ? fast_path->high_translation_context_hash
        : fast_path->low_translation_context_hash;
}

static int avz_stage1_fault(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t access,
    uint8_t level,
    uint8_t status_code
) {
    fast_path->translation_fault_pending = 1;
    AVZ_MEMORY_STAT_INCREMENT(fast_path, native_page_table_faults);
    if (fast_path->report_translation_fault != NULL) {
        fast_path->report_translation_fault(
            fast_path->slow_context,
            virtual_address,
            access,
            level,
            status_code
        );
    }
    return AVZ_NATIVE_TRANSLATION_FAULT;
}

static int avz_stage1_read_descriptor(
    const AVZNativeMemoryFastPath *fast_path,
    uint64_t physical_address,
    uint64_t *descriptor
) {
    if (physical_address < fast_path->ram_base) {
        return 0;
    }
    uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > fast_path->ram_size ||
        sizeof(*descriptor) > fast_path->ram_size - offset) {
        return 0;
    }
    const uint8_t *host_address = fast_path->ram + offset;
    if (((uintptr_t)host_address & (sizeof(*descriptor) - 1u)) == 0) {
        *descriptor = __atomic_load_n(
            (const uint64_t *)host_address,
            __ATOMIC_ACQUIRE
        );
    } else {
        uint64_t value = 0;
        for (uint8_t index = 0; index < sizeof(*descriptor); index++) {
            value |= (uint64_t)__atomic_load_n(
                host_address + index, __ATOMIC_ACQUIRE) << (index * 8u);
        }
        *descriptor = value;
    }
    return 1;
}

static int avz_stage1_validate_leaf(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t descriptor,
    uint64_t virtual_address,
    uint8_t access,
    uint8_t level
) {
    if ((descriptor & AVZ_STAGE1_ACCESS_FLAG_BIT) == 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            level,
            (uint8_t)(AVZ_FAULT_ACCESS_FLAG_LEVEL_0 + level)
        );
    }
    if (access == AVZ_NATIVE_MEMORY_ACCESS_WRITE &&
        (descriptor & AVZ_STAGE1_READ_ONLY_AP_BIT) != 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            level,
            (uint8_t)(AVZ_FAULT_PERMISSION_LEVEL_0 + level)
        );
    }
    if (access == AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION) {
        uint64_t execute_never_bit = fast_path->translation_state.current_el == 0
            ? AVZ_STAGE1_UNPRIVILEGED_EXECUTE_NEVER_BIT
            : AVZ_STAGE1_PRIVILEGED_EXECUTE_NEVER_BIT;
        if ((descriptor & execute_never_bit) != 0) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_PERMISSION_LEVEL_0 + level)
            );
        }
    }
    return AVZ_NATIVE_TRANSLATION_SUCCESS;
}

static int avz_stage1_translate(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t access,
    uint64_t *physical_address,
    AVZNativeFastTLBEntry *metadata
) {
    if (!fast_path->native_translation_enabled) {
        return AVZ_NATIVE_TRANSLATION_UNAVAILABLE;
    }
    if ((fast_path->translation_state.sctlr_el1 & 1u) == 0) {
        *physical_address = virtual_address;
        return AVZ_NATIVE_TRANSLATION_SUCCESS;
    }

    AVZ_MEMORY_STAT_INCREMENT(fast_path, native_page_table_walks);
    uint8_t uses_ttbr1 = (uint8_t)(virtual_address >> 63);
    unsigned size_offset = uses_ttbr1 ? 16u : 0u;
    unsigned tsz = (unsigned)(
        (fast_path->translation_state.tcr_el1 >> size_offset) & 0x3fu
    );
    unsigned input_address_size = 64u - tsz;
    if (input_address_size == 0 || input_address_size > 48u) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            0,
            AVZ_FAULT_ADDRESS_SIZE_LEVEL_0
        );
    }

    uint64_t ttbr = uses_ttbr1
        ? fast_path->translation_state.ttbr1_el1
        : fast_path->translation_state.ttbr0_el1;
    uint64_t current_table = ttbr & AVZ_STAGE1_OUTPUT_ADDRESS_MASK;
    if (current_table == 0) {
        return avz_stage1_fault(
            fast_path,
            virtual_address,
            access,
            0,
            AVZ_FAULT_TRANSLATION_LEVEL_0
        );
    }

    uint64_t effective_address = virtual_address &
        ((1ULL << input_address_size) - 1u);
    for (uint8_t level = 0; level <= 3; level++) {
        unsigned shift = 39u - ((unsigned)level * 9u);
        uint64_t index = (effective_address >> shift) & 0x1ffu;
        if (current_table > UINT64_MAX - index * sizeof(uint64_t)) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }
        uint64_t descriptor_address =
            current_table + index * sizeof(uint64_t);
        uint64_t descriptor = 0;
        if (!avz_stage1_read_descriptor(
                fast_path,
                descriptor_address,
                &descriptor
            ) || (descriptor & 1u) == 0) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }

        uint64_t descriptor_type = descriptor & 3u;
        if (level == 3) {
            if (descriptor_type != 3u) {
                return avz_stage1_fault(
                    fast_path,
                    virtual_address,
                    access,
                    level,
                    (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
                );
            }
            if (avz_stage1_validate_leaf(
                    fast_path,
                    descriptor,
                    virtual_address,
                    access,
                    level
                ) != AVZ_NATIVE_TRANSLATION_SUCCESS) {
                return AVZ_NATIVE_TRANSLATION_FAULT;
            }
            *physical_address =
                (descriptor & AVZ_STAGE1_OUTPUT_ADDRESS_MASK) |
                (effective_address & (AVZ_FAST_PAGE_SIZE - 1u));
            metadata->global = (descriptor & (UINT64_C(1) << 11)) == 0;
            metadata->leaf_shift = (descriptor & (UINT64_C(1) << 52)) ? 16 : 12;
            return AVZ_NATIVE_TRANSLATION_SUCCESS;
        }

        if (descriptor_type == 1u) {
            unsigned offset_bits = 39u - ((unsigned)level * 9u);
            uint64_t offset_mask = (1ULL << offset_bits) - 1u;
            if (avz_stage1_validate_leaf(
                    fast_path,
                    descriptor,
                    virtual_address,
                    access,
                    level
                ) != AVZ_NATIVE_TRANSLATION_SUCCESS) {
                return AVZ_NATIVE_TRANSLATION_FAULT;
            }
            uint64_t output_base = descriptor &
                AVZ_STAGE1_OUTPUT_ADDRESS_MASK & ~offset_mask;
            *physical_address = output_base |
                (effective_address & offset_mask);
            metadata->global = (descriptor & (UINT64_C(1) << 11)) == 0;
            metadata->leaf_shift = (uint8_t)(offset_bits +
                ((descriptor & (UINT64_C(1) << 52)) ? 4 : 0));
            return AVZ_NATIVE_TRANSLATION_SUCCESS;
        }

        if (descriptor_type != 3u) {
            return avz_stage1_fault(
                fast_path,
                virtual_address,
                access,
                level,
                (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + level)
            );
        }
        current_table = descriptor & AVZ_STAGE1_OUTPUT_ADDRESS_MASK;
    }

    return avz_stage1_fault(
        fast_path,
        virtual_address,
        access,
        3,
        (uint8_t)(AVZ_FAULT_TRANSLATION_LEVEL_0 + 3u)
    );
}

static int avz_resolve_translation(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t access,
    AVZNativeMemoryTranslateRAMCallback fallback,
    uint64_t *physical_address,
    AVZNativeFastTLBEntry *metadata
) {
    *metadata = (AVZNativeFastTLBEntry){
        .asid = avz_stage1_asid(&fast_path->translation_state)
    };
    int result = avz_stage1_translate(
        fast_path,
        virtual_address,
        access,
        physical_address,
        metadata
    );
    if (result != AVZ_NATIVE_TRANSLATION_UNAVAILABLE) {
        return result == AVZ_NATIVE_TRANSLATION_SUCCESS;
    }
    AVZ_MEMORY_STAT_INCREMENT(fast_path, translation_callback_walks);
    return fallback != NULL && fallback(
        fast_path->slow_context,
        virtual_address,
        width,
        access == AVZ_NATIVE_MEMORY_ACCESS_WRITE,
        physical_address
    );
}

static int avz_fast_translate_cold(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *physical_address,
    uint8_t **host_address
) {
    if (fast_path == 0 || fast_path->ram == 0 || physical_address == 0 ||
        !avz_fast_width_supported(width)) {
        return 0;
    }
    uint64_t page_offset = virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset + width > AVZ_FAST_PAGE_SIZE) {
        return 0;
    }

    uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    uint64_t context_tag = avz_fast_translation_context_tag(
        fast_path,
        virtual_address
    );
    size_t hot_index = (size_t)(
        (virtual_page ^ (context_tag >> AVZ_FAST_PAGE_SHIFT)) &
        (AVZ_FAST_DATA_HOT_COUNT - 1u)
    );
    AVZNativeFastTLBEntry *hot = is_write
        ? &fast_path->write_hot[hot_index]
        : &fast_path->read_hot[hot_index];
    uint64_t physical_page;
    uint8_t *host_page;
    if (hot->valid && hot->generation == fast_path->hot_translation_generation &&
        hot->contiguous_span >= page_offset + width &&
        hot->virtual_page == virtual_page &&
        hot->context_tag == context_tag) {
        physical_page = hot->physical_page;
        host_page = hot->host_page;
        if (is_write) {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, write_tlb_hits);
        } else {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, read_tlb_hits);
        }
        goto translated;
    }

    uint64_t page_hash = virtual_page ^ (virtual_page >> 11) ^
        (virtual_page >> 23) ^
        avz_fast_translation_context_hash(fast_path, virtual_address);
    size_t set = (size_t)(page_hash & (AVZ_FAST_TLB_SET_COUNT - 1u));
    size_t base = set * AVZ_FAST_TLB_WAY_COUNT;
    AVZNativeFastTLBEntry *entries =
        is_write ? fast_path->write_tlb : fast_path->read_tlb;
    AVZNativeFastTLBEntry *entry = NULL;
    AVZNativeFastTLBEntry *first_invalid = NULL;
    for (size_t way = 0; way < AVZ_FAST_TLB_WAY_COUNT; way++) {
        AVZNativeFastTLBEntry *candidate = &entries[base + way];
        if (candidate->valid &&
            candidate->generation == fast_path->translation_generation &&
            candidate->contiguous_span >= page_offset + width &&
            candidate->virtual_page == virtual_page &&
            candidate->context_tag == context_tag &&
            avz_native_fast_tlb_entry_is_current(fast_path, candidate)) {
            entry = candidate;
            break;
        }
        if (!candidate->valid && first_invalid == NULL) {
            first_invalid = candidate;
        }
    }
    if (entry != NULL) {
        physical_page = entry->physical_page;
        host_page = entry->host_page;
        if (is_write) {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, write_tlb_hits);
        } else {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, read_tlb_hits);
        }
    } else {
        if (is_write) {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, write_tlb_misses);
        } else {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, read_tlb_misses);
        }
        uint64_t translated = 0;
        AVZNativeFastTLBEntry metadata;
        if (!avz_resolve_translation(
                fast_path,
                virtual_address,
                width,
                is_write
                    ? AVZ_NATIVE_MEMORY_ACCESS_WRITE
                    : AVZ_NATIVE_MEMORY_ACCESS_READ,
                fast_path->translate_ram,
                &translated,
                &metadata
            )) {
            return 0;
        }
        if (translated < page_offset) {
            return 0;
        }
        physical_page = translated - page_offset;
        if (physical_page >= fast_path->ram_base &&
            physical_page - fast_path->ram_base < fast_path->ram_size) {
            host_page =
                fast_path->ram + (physical_page - fast_path->ram_base);
        } else {
            host_page = NULL;
        }
        if (first_invalid != NULL) {
            entry = first_invalid;
        } else {
            uint8_t *replacement = is_write
                ? &fast_path->write_replacement[set]
                : &fast_path->read_replacement[set];
            size_t way = *replacement & (AVZ_FAST_TLB_WAY_COUNT - 1u);
            *replacement =
                (uint8_t)((way + 1u) & (AVZ_FAST_TLB_WAY_COUNT - 1u));
            entry = &entries[base + way];
        }
        entry->virtual_page = virtual_page;
        entry->physical_page = physical_page;
        entry->host_page = host_page;
        uint64_t contiguous_span = AVZ_FAST_PAGE_SIZE;
        if (host_page != NULL) {
            const uint64_t ram_offset = physical_page - fast_path->ram_base;
            const uint64_t ram_remaining = fast_path->ram_size - ram_offset;
            if (contiguous_span > ram_remaining) {
                contiguous_span = ram_remaining;
            }
        }
        entry->contiguous_span = (uint16_t)contiguous_span;
        entry->context_tag = context_tag;
        entry->generation = fast_path->translation_generation;
        entry->tlbi_epoch = fast_path->tlbi_epoch;
        entry->asid = metadata.asid;
        entry->global = metadata.global;
        entry->leaf_shift = metadata.leaf_shift;
        entry->valid = 1;
    }
    *hot = *entry;
    hot->generation = fast_path->hot_translation_generation;

translated:
    if (physical_page > UINT64_MAX - page_offset) {
        return AVZ_FAST_TRANSLATION_FAILED;
    }
    *physical_address = physical_page + page_offset;
    if (host_page == NULL || physical_page < fast_path->ram_base) {
        if (host_address != NULL) {
            *host_address = NULL;
        }
        return AVZ_FAST_TRANSLATION_PHYSICAL;
    }
    uint64_t offset = physical_page - fast_path->ram_base + page_offset;
    if (offset > fast_path->ram_size || width > fast_path->ram_size - offset) {
        if (host_address != NULL) {
            *host_address = NULL;
        }
        return AVZ_FAST_TRANSLATION_PHYSICAL;
    }
    if (host_address != NULL) {
        *host_address = host_page + page_offset;
    }
    return AVZ_FAST_TRANSLATION_RAM;
}

#if defined(__clang__) || defined(__GNUC__)
__attribute__((always_inline))
#endif
static inline int avz_fast_translate(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *physical_address,
    uint8_t **host_address
) {
    if (fast_path == NULL || fast_path->ram == NULL ||
        physical_address == NULL || !avz_fast_width_supported(width)) {
        return AVZ_FAST_TRANSLATION_FAILED;
    }

    avz_fast_synchronize_shared_translation_epoch(fast_path);
    const uint64_t page_offset =
        virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset + width > AVZ_FAST_PAGE_SIZE) {
        return AVZ_FAST_TRANSLATION_FAILED;
    }

    const uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    const uint64_t context_tag = avz_fast_translation_context_tag(
        fast_path,
        virtual_address
    );
    const size_t hot_index = (size_t)(
        (virtual_page ^ (context_tag >> AVZ_FAST_PAGE_SHIFT)) &
        (AVZ_FAST_DATA_HOT_COUNT - 1u)
    );
    AVZNativeFastTLBEntry *hot = is_write
        ? &fast_path->write_hot[hot_index]
        : &fast_path->read_hot[hot_index];
    if (hot->valid && hot->generation == fast_path->hot_translation_generation &&
        hot->contiguous_span >= page_offset + width &&
        hot->virtual_page == virtual_page &&
        hot->context_tag == context_tag) {
        if (is_write) {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, write_tlb_hits);
        } else {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, read_tlb_hits);
        }
        if (hot->host_page != NULL) {
            *physical_address = hot->physical_page + page_offset;
            if (host_address != NULL) {
                *host_address = hot->host_page + page_offset;
            }
            return AVZ_FAST_TRANSLATION_RAM;
        }
        if (hot->physical_page > UINT64_MAX - page_offset) {
            return AVZ_FAST_TRANSLATION_FAILED;
        }
        *physical_address = hot->physical_page + page_offset;
        if (host_address != NULL) {
            *host_address = NULL;
        }
        return AVZ_FAST_TRANSLATION_PHYSICAL;
    }

    return avz_fast_translate_cold(
        fast_path,
        virtual_address,
        width,
        is_write,
        physical_address,
        host_address
    );
}

static uint64_t avz_fast_load(
    const uint8_t *host_address,
    uint8_t width
) {
    /*
     * Plain AArch64 loads are atomic at their supported natural alignment but
     * are not acquire operations. LDAR/LDAXR handlers apply the architectural
     * acquire fence after this access, and page locks protect host-observed or
     * unaligned ranges.
     */
    const uintptr_t address = (uintptr_t)host_address;
    switch (width) {
    case 1:
        return __atomic_load_n(host_address, __ATOMIC_RELAXED);
    case 2:
        if ((address & 1u) == 0) {
            return __atomic_load_n(
                (const uint16_t *)host_address,
                __ATOMIC_RELAXED
            );
        }
        break;
    case 4:
        if ((address & 3u) == 0) {
            return __atomic_load_n(
                (const uint32_t *)host_address,
                __ATOMIC_RELAXED
            );
        }
        break;
    case 8:
        if ((address & 7u) == 0) {
            return __atomic_load_n(
                (const uint64_t *)host_address,
                __ATOMIC_RELAXED
            );
        }
        break;
    default:
        break;
    }
    uint64_t value = 0;
    for (uint8_t offset = 0; offset < width; offset++) {
        value |= (uint64_t)__atomic_load_n(
            host_address + offset, __ATOMIC_RELAXED) << (offset * 8u);
    }
    return value;
}

static int avz_fast_translate_instruction(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint8_t **host_address
) {
    if (fast_path == NULL || fast_path->ram == NULL ||
        (!fast_path->native_translation_enabled &&
         fast_path->translate_instruction_ram == NULL) ||
        physical_address == NULL || host_address == NULL ||
        (virtual_address & 3u) != 0) {
        return 0;
    }
    avz_fast_synchronize_shared_translation_epoch(fast_path);

    uint64_t page_offset = virtual_address & (AVZ_FAST_PAGE_SIZE - 1u);
    if (page_offset > AVZ_FAST_PAGE_SIZE - sizeof(uint32_t)) {
        return 0;
    }
    uint64_t virtual_page = virtual_address >> AVZ_FAST_PAGE_SHIFT;
    uint64_t context_tag = avz_fast_translation_context_tag(
        fast_path,
        virtual_address
    );
    uint64_t physical_page = 0;
    uint8_t *host_page = NULL;
    AVZNativeFastTLBEntry *entry = NULL;

    for (size_t index = 0; index < AVZ_FAST_INSTRUCTION_HOT_COUNT; index++) {
        AVZNativeFastTLBEntry *candidate =
            &fast_path->instruction_hot[index];
        if (candidate->valid &&
            candidate->generation == fast_path->hot_translation_generation &&
            candidate->contiguous_span >= page_offset + sizeof(uint32_t) &&
            candidate->virtual_page == virtual_page &&
            candidate->context_tag == context_tag) {
            entry = candidate;
            AVZ_MEMORY_STAT_INCREMENT(fast_path, instruction_tlb_hits);
            AVZ_MEMORY_STAT_INCREMENT(fast_path, instruction_tlb_hot_hits);
            break;
        }
    }
    if (entry == NULL) {
        uint64_t page_hash = virtual_page ^ (virtual_page >> 11) ^
            (virtual_page >> 23) ^
            avz_fast_translation_context_hash(fast_path, virtual_address);
        size_t set = (size_t)(
            page_hash & (AVZ_FAST_INSTRUCTION_TLB_SET_COUNT - 1u)
        );
        size_t base = set * AVZ_FAST_TLB_WAY_COUNT;
        AVZNativeFastTLBEntry *first_invalid = NULL;
        int invalidated_mapping = 0;
        for (size_t way = 0; way < AVZ_FAST_TLB_WAY_COUNT; way++) {
            AVZNativeFastTLBEntry *candidate =
                &fast_path->instruction_tlb[base + way];
            if (candidate->valid &&
                candidate->generation == fast_path->translation_generation &&
                candidate->virtual_page == virtual_page &&
                candidate->context_tag == context_tag &&
                avz_native_fast_tlb_entry_is_current(fast_path, candidate)) {
                entry = candidate;
                break;
            }
            if ((!candidate->valid ||
                 candidate->generation != fast_path->translation_generation) &&
                first_invalid == NULL) {
                first_invalid = candidate;
            }
            if (candidate->valid &&
                candidate->generation != fast_path->translation_generation &&
                candidate->virtual_page == virtual_page &&
                candidate->context_tag == context_tag) {
                invalidated_mapping = 1;
            }
        }

        if (entry != NULL) {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, instruction_tlb_hits);
        } else {
            AVZ_MEMORY_STAT_INCREMENT(fast_path, instruction_tlb_misses);
            if (invalidated_mapping) {
                AVZ_MEMORY_STAT_INCREMENT(
                    fast_path, instruction_tlb_invalidation_misses);
            } else if (first_invalid != NULL) {
                AVZ_MEMORY_STAT_INCREMENT(
                    fast_path, instruction_tlb_cold_misses);
            } else {
                AVZ_MEMORY_STAT_INCREMENT(
                    fast_path, instruction_tlb_conflict_misses);
            }
            uint64_t translated = 0;
            AVZNativeFastTLBEntry metadata;
            if (!avz_resolve_translation(
                    fast_path,
                    virtual_address,
                    sizeof(uint32_t),
                    AVZ_NATIVE_MEMORY_ACCESS_INSTRUCTION,
                    fast_path->translate_instruction_ram,
                    &translated,
                    &metadata
                ) || translated < page_offset) {
                return 0;
            }
            physical_page = translated - page_offset;
            if (physical_page < fast_path->ram_base ||
                physical_page - fast_path->ram_base >= fast_path->ram_size) {
                return 0;
            }
            host_page = fast_path->ram +
                (physical_page - fast_path->ram_base);
            if (first_invalid != NULL) {
                entry = first_invalid;
            } else {
                size_t way = fast_path->instruction_replacement[set] &
                    (AVZ_FAST_TLB_WAY_COUNT - 1u);
                fast_path->instruction_replacement[set] =
                    (uint8_t)((way + 1u) & (AVZ_FAST_TLB_WAY_COUNT - 1u));
                entry = &fast_path->instruction_tlb[base + way];
            }
            *entry = (AVZNativeFastTLBEntry){
                .virtual_page = virtual_page,
                .physical_page = physical_page,
                .host_page = host_page,
                .contiguous_span = AVZ_FAST_PAGE_SIZE,
                .context_tag = context_tag,
                .generation = fast_path->translation_generation,
                .tlbi_epoch = fast_path->tlbi_epoch,
                .asid = metadata.asid,
                .global = metadata.global,
                .leaf_shift = metadata.leaf_shift,
                .valid = 1
            };
        }
        size_t hot_slot =
            fast_path->instruction_hot_replacement &
            (AVZ_FAST_INSTRUCTION_HOT_COUNT - 1u);
        fast_path->instruction_hot_replacement = (uint8_t)(
            (hot_slot + 1u) & (AVZ_FAST_INSTRUCTION_HOT_COUNT - 1u)
        );
        fast_path->instruction_hot[hot_slot] = *entry;
        fast_path->instruction_hot[hot_slot].generation = fast_path->hot_translation_generation;
    }

    physical_page = entry->physical_page;
    host_page = entry->host_page;
    if (physical_page < fast_path->ram_base) {
        return 0;
    }
    uint64_t offset = physical_page - fast_path->ram_base + page_offset;
    if (offset > fast_path->ram_size ||
        sizeof(uint32_t) > fast_path->ram_size - offset) {
        return 0;
    }
    *physical_address = fast_path->ram_base + offset;
    *host_address = host_page + page_offset;
    return 1;
}

static int avz_fast_instruction_mapping_is_current(
    void *context, uint64_t virtual_address, uint64_t expected_physical_address
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (!fast_path->native_translation_enabled) return 0;
    /* Speculative link validation must not deliver a guest fault. The actual
     * fetch will report one if execution reaches the now-unmapped block. */
    AVZNativeMemoryTranslationFaultCallback report = fast_path->report_translation_fault;
    uint8_t pending = fast_path->translation_fault_pending;
    fast_path->report_translation_fault = NULL;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    int valid = avz_fast_translate_instruction(
        fast_path, virtual_address, &physical_address, &host_address);
    fast_path->report_translation_fault = report;
    fast_path->translation_fault_pending = pending;
    return valid && physical_address == expected_physical_address;
}

int avz_native_fast_fetch_instruction(
    void *context,
    uint64_t virtual_address,
    uint64_t *physical_address,
    uint32_t *instruction
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint8_t *host_address = NULL;
    if (instruction == NULL ||
        !avz_fast_translate_instruction(
            fast_path,
            virtual_address,
            physical_address,
            &host_address
        )) {
        return 0;
    }
    *instruction = __atomic_load_n(
        (const uint32_t *)host_address,
        __ATOMIC_ACQUIRE
    );
    AVZ_MEMORY_STAT_INCREMENT(fast_path, instruction_fetch_hits);
    return 1;
}

static void avz_fast_store_value(
    uint8_t *host_address,
    uint8_t width,
    uint64_t value
) {
    /* STLR/STLXR handlers issue their release fence before reaching here. */
    const uintptr_t address = (uintptr_t)host_address;
    if (width == 1) {
        __atomic_store_n(host_address, (uint8_t)value, __ATOMIC_RELAXED);
    } else if (width == 2 && (address & 1u) == 0) {
        __atomic_store_n((uint16_t *)host_address, (uint16_t)value, __ATOMIC_RELAXED);
    } else if (width == 4 && (address & 3u) == 0) {
        __atomic_store_n((uint32_t *)host_address, (uint32_t)value, __ATOMIC_RELAXED);
    } else if (width == 8 && (address & 7u) == 0) {
        __atomic_store_n((uint64_t *)host_address, value, __ATOMIC_RELAXED);
    } else {
        for (uint8_t offset = 0; offset < width; offset++) {
            __atomic_store_n(
                host_address + offset,
                (uint8_t)(value >> (offset * 8u)),
                __ATOMIC_RELAXED
            );
        }
    }
}

static uint8_t avz_fast_atomic_chunk_width(
    const uint8_t *host_address,
    size_t remaining
) {
    const uintptr_t address = (uintptr_t)host_address;
    if (remaining >= 8u && (address & 7u) == 0) {
        return 8;
    }
    if (remaining >= 4u && (address & 3u) == 0) {
        return 4;
    }
    if (remaining >= 2u && (address & 1u) == 0) {
        return 2;
    }
    return 1;
}

static void avz_fast_atomic_read_bytes(
    const uint8_t *host_address,
    uint8_t *destination,
    size_t byte_count
) {
    size_t offset = 0;
    while (offset < byte_count) {
        uint8_t width = avz_fast_atomic_chunk_width(
            host_address + offset, byte_count - offset);
        uint64_t value = avz_fast_load(host_address + offset, width);
        memcpy(destination + offset, &value, width);
        offset += width;
    }
}

static void avz_fast_atomic_write_bytes(
    uint8_t *host_address,
    const uint8_t *source,
    size_t byte_count
) {
    size_t offset = 0;
    while (offset < byte_count) {
        uint8_t width = avz_fast_atomic_chunk_width(
            host_address + offset, byte_count - offset);
        uint64_t value = 0;
        memcpy(&value, source + offset, width);
        avz_fast_store_value(host_address + offset, width, value);
        offset += width;
    }
}

static void avz_fast_atomic_fill_bytes(
    uint8_t *host_address,
    size_t byte_count,
    const uint8_t *pattern,
    uint8_t pattern_width,
    uint64_t pattern_phase
) {
    size_t offset = 0;
    while (offset < byte_count) {
        uint8_t width = avz_fast_atomic_chunk_width(
            host_address + offset, byte_count - offset);
        uint8_t bytes[8] = {0};
        for (uint8_t index = 0; index < width; index++) {
            bytes[index] = pattern[
                (pattern_phase + offset + index) % pattern_width];
        }
        uint64_t value = 0;
        memcpy(&value, bytes, width);
        avz_fast_store_value(host_address + offset, width, value);
        offset += width;
    }
}

int avz_guest_memory_dma_read_owned(
    AVZGuestMemory *memory,
    size_t offset,
    void *destination,
    size_t byte_count
) {
    if (memory == NULL || destination == NULL || byte_count == 0 ||
        offset >= memory->size || byte_count > memory->size - offset) {
        return 0;
    }

    /* The virtqueue acquire publishes all guest writes before device DMA. */
    atomic_thread_fence(memory_order_acquire);
    memcpy(destination, memory->bytes + offset, byte_count);
    return 1;
}

int avz_guest_memory_dma_readv_owned(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count,
    void *destination,
    size_t destination_byte_count
) {
    if (memory == NULL || spans == NULL || span_count == 0 ||
        destination == NULL || destination_byte_count == 0) {
        return 0;
    }
    size_t total = 0;
    for (size_t index = 0; index < span_count; index++) {
        size_t offset = spans[index].offset;
        size_t length = spans[index].byte_count;
        if (length == 0 || length > destination_byte_count ||
            offset >= memory->size ||
            length > memory->size - offset ||
            total > destination_byte_count - length) {
            return 0;
        }
        total += length;
    }
    if (total != destination_byte_count) {
        return 0;
    }

    atomic_thread_fence(memory_order_acquire);
    uint8_t *output = destination;
    size_t output_offset = 0;
    for (size_t index = 0; index < span_count; index++) {
        memcpy(
            output + output_offset,
            memory->bytes + spans[index].offset,
            spans[index].byte_count
        );
        output_offset += spans[index].byte_count;
    }
    return 1;
}

static int avz_guest_memory_dma_rect_owned(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count,
    size_t logical_offset,
    size_t row_byte_count,
    size_t row_stride,
    size_t row_count,
    void *host_bytes,
    size_t host_byte_count,
    int write_to_guest
) {
    if (memory == NULL || spans == NULL || span_count == 0 ||
        host_bytes == NULL || row_byte_count == 0 || row_count == 0 ||
        row_stride < row_byte_count) {
        return 0;
    }
    if (row_count - 1u > (SIZE_MAX - logical_offset) / row_stride) {
        return 0;
    }
    const size_t final_row_offset =
        logical_offset + (row_count - 1u) * row_stride;
    if (row_byte_count > SIZE_MAX - final_row_offset) {
        return 0;
    }
    const size_t required_byte_count = final_row_offset + row_byte_count;
    if (required_byte_count > host_byte_count) {
        return 0;
    }

    size_t logical_byte_count = 0;
    for (size_t index = 0; index < span_count; index++) {
        const size_t offset = spans[index].offset;
        const size_t byte_count = spans[index].byte_count;
        if (byte_count == 0 || offset >= memory->size ||
            byte_count > memory->size - offset ||
            logical_byte_count > SIZE_MAX - byte_count) {
            return 0;
        }
        logical_byte_count += byte_count;
    }
    if (required_byte_count > logical_byte_count) {
        return 0;
    }

    if (!write_to_guest) {
        atomic_thread_fence(memory_order_acquire);
    }
    uint8_t *host = host_bytes;
    size_t span_index = 0;
    size_t span_logical_start = 0;
    for (size_t row = 0; row < row_count; row++) {
        const size_t row_offset = logical_offset + row * row_stride;
        while (span_index < span_count &&
               row_offset >= span_logical_start + spans[span_index].byte_count) {
            span_logical_start += spans[span_index].byte_count;
            span_index++;
        }
        size_t current_index = span_index;
        size_t current_start = span_logical_start;
        size_t copied = 0;
        while (copied < row_byte_count && current_index < span_count) {
            const size_t within_span = row_offset + copied - current_start;
            const size_t available =
                spans[current_index].byte_count - within_span;
            const size_t byte_count = available < row_byte_count - copied
                ? available : row_byte_count - copied;
            uint8_t *guest = memory->bytes + spans[current_index].offset +
                within_span;
            if (write_to_guest) {
                memcpy(guest, host + row_offset + copied, byte_count);
            } else {
                memcpy(host + row_offset + copied, guest, byte_count);
            }
            copied += byte_count;
            if (within_span + byte_count == spans[current_index].byte_count) {
                current_start += spans[current_index].byte_count;
                current_index++;
            }
        }
        if (copied != row_byte_count) {
            return 0;
        }
    }

    if (!write_to_guest) {
        return 1;
    }

    atomic_thread_fence(memory_order_release);
    int code_changed = 0;
    span_index = 0;
    span_logical_start = 0;
    for (size_t row = 0; row < row_count; row++) {
        const size_t row_offset = logical_offset + row * row_stride;
        while (span_index < span_count &&
               row_offset >= span_logical_start + spans[span_index].byte_count) {
            span_logical_start += spans[span_index].byte_count;
            span_index++;
        }
        size_t current_index = span_index;
        size_t current_start = span_logical_start;
        size_t noted = 0;
        while (noted < row_byte_count && current_index < span_count) {
            const size_t within_span = row_offset + noted - current_start;
            const size_t available =
                spans[current_index].byte_count - within_span;
            const size_t byte_count = available < row_byte_count - noted
                ? available : row_byte_count - noted;
            const size_t guest_offset = spans[current_index].offset + within_span;
            avz_guest_memory_note_exclusive_write_generation(
                memory, guest_offset, byte_count);
            if (avz_guest_memory_range_may_contain_code(
                    memory, (uint64_t)guest_offset, byte_count, 0)) {
                avz_guest_memory_note_page_write_generation(
                    memory, guest_offset, byte_count);
                code_changed = 1;
            }
            noted += byte_count;
            if (within_span + byte_count == spans[current_index].byte_count) {
                current_start += spans[current_index].byte_count;
                current_index++;
            }
        }
    }
    if (code_changed) {
        avz_guest_memory_advance_code_mutation_epoch(memory);
    }
    return 1;
}

int avz_guest_memory_dma_read_rect_owned(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count,
    size_t logical_offset,
    size_t row_byte_count,
    size_t row_stride,
    size_t row_count,
    void *destination,
    size_t destination_byte_count
) {
    return avz_guest_memory_dma_rect_owned(
        memory, spans, span_count, logical_offset, row_byte_count,
        row_stride, row_count, destination, destination_byte_count, 0);
}

int avz_guest_memory_dma_write_rect_owned(
    AVZGuestMemory *memory,
    const AVZGuestMemorySpan *spans,
    size_t span_count,
    size_t logical_offset,
    size_t row_byte_count,
    size_t row_stride,
    size_t row_count,
    const void *source,
    size_t source_byte_count
) {
    return avz_guest_memory_dma_rect_owned(
        memory, spans, span_count, logical_offset, row_byte_count,
        row_stride, row_count, (void *)source, source_byte_count, 1);
}

uint8_t *avz_guest_memory_dma_owned_pointer(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return NULL;
    }

    atomic_thread_fence(memory_order_acquire);
    return memory->bytes + offset;
}

void avz_guest_memory_dma_write_owned_complete(
    AVZGuestMemory *memory,
    size_t offset,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || offset >= memory->size ||
        byte_count > memory->size - offset) {
        return;
    }

    atomic_thread_fence(memory_order_release);
    avz_guest_memory_note_exclusive_write_generation(
        memory, offset, byte_count);
    if (avz_guest_memory_range_may_contain_code(
            memory, (uint64_t)offset, byte_count, 0)) {
        avz_guest_memory_note_page_write_generation(
            memory, offset, byte_count);
        avz_guest_memory_advance_code_mutation_epoch(memory);
    }
}

int avz_guest_memory_dma_write_owned(
    AVZGuestMemory *memory,
    size_t offset,
    const void *source,
    size_t byte_count
) {
    if (memory == NULL || source == NULL || byte_count == 0 ||
        offset >= memory->size || byte_count > memory->size - offset) {
        return 0;
    }

    memcpy(memory->bytes + offset, source, byte_count);
    avz_guest_memory_dma_write_owned_complete(memory, offset, byte_count);
    return 1;
}

static int avz_fast_access_is_naturally_atomic(
    const uint8_t *host_address,
    uint8_t width
) {
    const uintptr_t address = (uintptr_t)host_address;
    return width == 1 ||
        (width == 2 && (address & 1u) == 0) ||
        (width == 4 && (address & 3u) == 0) ||
        (width == 8 && (address & 7u) == 0);
}

static void avz_fast_store(
    AVZNativeMemoryFastPath *fast_path,
    uint8_t *host_address,
    uint64_t physical_address,
    uint8_t width,
    uint64_t value
) {
    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t memory_offset = physical_address >= fast_path->ram_base
        ? (size_t)(physical_address - fast_path->ram_base)
        : 0;
    const int requires_lock = memory != NULL &&
        (!avz_fast_access_is_naturally_atomic(host_address, width) ||
         (avz_guest_memory_range_may_have_observation(
              memory, memory_offset, width, UINT8_MAX) &&
          (avz_guest_memory_range_has_host_observer(
               memory, memory_offset, width) ||
           avz_guest_memory_range_has_bulk_reader(
               memory, memory_offset, width) ||
           avz_guest_memory_range_has_exclusive_observer(
               memory, memory_offset, width))));
    if (requires_lock) {
        avz_guest_memory_lock_range_internal(memory, memory_offset, width);
    }
    avz_fast_store_value(host_address, width, value);
    int contains_code = avz_fast_mark_dirty(
        fast_path, physical_address, width);
    avz_fast_invalidate_code_after_write(
        fast_path, physical_address, width, contains_code);
    if (requires_lock) {
        avz_guest_memory_unlock_range_internal(memory, memory_offset, width);
    }
}

static uint64_t avz_guest_memory_page_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_address,
    uint64_t ram_base,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || physical_address < ram_base) {
        return 0;
    }
    const uint64_t raw_offset = physical_address - ram_base;
    if (raw_offset > SIZE_MAX || (size_t)raw_offset >= memory->size ||
        byte_count > memory->size - (size_t)raw_offset) {
        return 0;
    }
    const size_t offset = (size_t)raw_offset;
    const size_t first_page = offset >> AVZ_FAST_PAGE_SHIFT;
    const size_t last_page =
        (offset + byte_count - 1u) >> AVZ_FAST_PAGE_SHIFT;
    uint64_t generation = 0;
    for (size_t page = first_page; page <= last_page; page++) {
        const uint64_t candidate = atomic_load_explicit(
            &memory->page_write_generations[page],
            memory_order_acquire
        );
        if (candidate > generation) {
            generation = candidate;
        }
    }
    return generation;
}

static uint64_t avz_guest_memory_exclusive_write_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_address,
    uint64_t ram_base,
    size_t byte_count
) {
    if (memory == NULL || byte_count == 0 || physical_address < ram_base) {
        return 0;
    }
    const uint64_t raw_offset = physical_address - ram_base;
    if (raw_offset > SIZE_MAX || (size_t)raw_offset >= memory->size ||
        byte_count > memory->size - (size_t)raw_offset) {
        return 0;
    }
    const size_t offset = (size_t)raw_offset;
    const size_t first_granule = offset >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    const size_t last_granule =
        (offset + byte_count - 1u) >> AVZ_EXCLUSIVE_GRANULE_SHIFT;
    uint64_t generation = 0;
    for (size_t granule = first_granule;
         granule <= last_granule; granule++) {
        const size_t slot = avz_guest_memory_exclusive_slot(memory, granule);
        const uint64_t candidate = atomic_load_explicit(
            &memory->exclusive_write_generations[slot],
            memory_order_acquire
        );
        if (candidate > generation) {
            generation = candidate;
        }
    }
    return generation;
}

uint64_t avz_guest_memory_page_write_generation(
    const AVZGuestMemory *memory,
    uint64_t physical_page,
    uint64_t ram_base
) {
    return avz_guest_memory_page_generation(
        memory,
        physical_page,
        ram_base,
        AVZ_FAST_PAGE_SIZE
    );
}

const uint64_t *avz_guest_memory_page_write_generation_token(
    const AVZGuestMemory *memory,
    uint64_t physical_page,
    uint64_t ram_base
) {
    if (memory == NULL || physical_page < ram_base) {
        return NULL;
    }
    const uint64_t raw_offset = physical_page - ram_base;
    if (raw_offset > SIZE_MAX || (size_t)raw_offset >= memory->size) {
        return NULL;
    }
    const size_t page = (size_t)raw_offset >> AVZ_FAST_PAGE_SHIFT;
    if (page >= memory->page_count) {
        return NULL;
    }
    return (const uint64_t *)&memory->page_write_generations[page];
}

AVZGuestExclusiveStatistics avz_guest_memory_exclusive_statistics(
    const AVZGuestMemory *memory
) {
    if (memory == NULL) {
        return (AVZGuestExclusiveStatistics){0};
    }
    return (AVZGuestExclusiveStatistics){
        .reads = atomic_load_explicit(
            &memory->exclusive_reads, memory_order_relaxed),
        .nonzero_reads = atomic_load_explicit(
            &memory->exclusive_nonzero_reads, memory_order_relaxed),
        .write_successes = atomic_load_explicit(
            &memory->exclusive_write_successes, memory_order_relaxed),
        .write_conflicts = atomic_load_explicit(
            &memory->exclusive_write_conflicts, memory_order_relaxed)
    };
}

static int avz_guest_memory_valid_exclusive_range(
    const AVZGuestMemory *memory,
    size_t offset,
    uint8_t width,
    size_t element_count
) {
    if (memory == NULL ||
        (width != 1 && width != 2 && width != 4 && width != 8) ||
        element_count == 0 || width > SIZE_MAX / element_count) {
        return 0;
    }
    const size_t byte_count = (size_t)width * element_count;
    return offset <= memory->size && byte_count <= memory->size - offset;
}

int avz_guest_memory_exclusive_read(
    AVZGuestMemory *memory,
    size_t offset,
    uint8_t width,
    uint64_t *value,
    uint64_t *generation
) {
    if (value == NULL || generation == NULL ||
        !avz_guest_memory_valid_exclusive_range(memory, offset, width, 1)) {
        return 0;
    }
    avz_guest_memory_lock_range_internal(memory, offset, width);
    avz_guest_memory_note_exclusive_observation(memory, offset, width);
    *value = avz_fast_load(memory->bytes + offset, width);
    *generation = avz_guest_memory_exclusive_write_generation(
        memory, (uint64_t)offset, 0, width);
    atomic_fetch_add_explicit(
        &memory->exclusive_reads, 1, memory_order_relaxed);
    if (*value != 0) {
        atomic_fetch_add_explicit(
            &memory->exclusive_nonzero_reads, 1, memory_order_relaxed);
    }
    avz_guest_memory_unlock_range_internal(memory, offset, width);
    return 1;
}

int avz_guest_memory_exclusive_read_pair(
    AVZGuestMemory *memory,
    size_t offset,
    uint8_t width,
    uint64_t *first_value,
    uint64_t *second_value,
    uint64_t *generation
) {
    if (first_value == NULL || second_value == NULL || generation == NULL ||
        !avz_guest_memory_valid_exclusive_range(memory, offset, width, 2)) {
        return 0;
    }
    const size_t byte_count = (size_t)width * 2;
    avz_guest_memory_lock_range_internal(memory, offset, byte_count);
    avz_guest_memory_note_exclusive_observation(memory, offset, byte_count);
    *first_value = avz_fast_load(memory->bytes + offset, width);
    *second_value = avz_fast_load(memory->bytes + offset + width, width);
    *generation = avz_guest_memory_exclusive_write_generation(
        memory, (uint64_t)offset, 0, byte_count);
    atomic_fetch_add_explicit(
        &memory->exclusive_reads, 1, memory_order_relaxed);
    avz_guest_memory_unlock_range_internal(memory, offset, byte_count);
    return 1;
}

int avz_guest_memory_exclusive_write(
    AVZGuestMemory *memory,
    size_t offset,
    uint8_t width,
    uint64_t value,
    uint64_t expected_generation
) {
    if (!avz_guest_memory_valid_exclusive_range(memory, offset, width, 1)) {
        return -1;
    }
    avz_guest_memory_lock_range_internal(memory, offset, width);
    const uint64_t generation = avz_guest_memory_exclusive_write_generation(
        memory, (uint64_t)offset, 0, width);
    if (generation != expected_generation) {
        atomic_fetch_add_explicit(
            &memory->exclusive_write_conflicts, 1, memory_order_relaxed);
        avz_guest_memory_unlock_range_internal(memory, offset, width);
        return 0;
    }
    avz_fast_store_value(memory->bytes + offset, width, value);
    avz_guest_memory_note_write(memory, offset, width);
    atomic_fetch_add_explicit(
        &memory->exclusive_write_successes, 1, memory_order_relaxed);
    avz_guest_memory_unlock_range_internal(memory, offset, width);
    return 1;
}

int avz_guest_memory_exclusive_write_pair(
    AVZGuestMemory *memory,
    size_t offset,
    uint8_t width,
    uint64_t first_value,
    uint64_t second_value,
    uint64_t expected_generation
) {
    if (!avz_guest_memory_valid_exclusive_range(memory, offset, width, 2)) {
        return -1;
    }
    const size_t byte_count = (size_t)width * 2;
    avz_guest_memory_lock_range_internal(memory, offset, byte_count);
    const uint64_t generation = avz_guest_memory_exclusive_write_generation(
        memory, (uint64_t)offset, 0, byte_count);
    if (generation != expected_generation) {
        atomic_fetch_add_explicit(
            &memory->exclusive_write_conflicts, 1, memory_order_relaxed);
        avz_guest_memory_unlock_range_internal(memory, offset, byte_count);
        return 0;
    }
    avz_fast_store_value(memory->bytes + offset, width, first_value);
    avz_fast_store_value(
        memory->bytes + offset + width, width, second_value);
    avz_guest_memory_note_write(memory, offset, byte_count);
    atomic_fetch_add_explicit(
        &memory->exclusive_write_successes, 1, memory_order_relaxed);
    avz_guest_memory_unlock_range_internal(memory, offset, byte_count);
    return 1;
}

int avz_native_fast_memory_reservation_generation(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (generation == NULL || fast_path == NULL ||
        fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }
    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t memory_offset = (size_t)(physical_address - fast_path->ram_base);
    avz_guest_memory_lock_range_internal(memory, memory_offset, width);
    avz_guest_memory_note_exclusive_observation(
        memory, memory_offset, width);
    *generation = avz_guest_memory_exclusive_write_generation(
        memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    avz_guest_memory_unlock_range_internal(memory, memory_offset, width);
    return 1;
}

int avz_native_fast_memory_exclusive_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        value == NULL || generation == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t memory_offset = (size_t)(physical_address - fast_path->ram_base);
    avz_guest_memory_lock_range_internal(memory, memory_offset, width);
    avz_guest_memory_note_exclusive_observation(
        memory, memory_offset, width);
    *value = avz_fast_load(host_address, width);
    fast_path->exclusive_expected_address = physical_address;
    fast_path->exclusive_expected_first = *value;
    fast_path->exclusive_expected_second = 0;
    fast_path->exclusive_expected_width = width;
    fast_path->exclusive_expected_count = 1;
    fast_path->exclusive_expected_valid = 1;
    atomic_fetch_add_explicit(
        &memory->exclusive_reads, 1, memory_order_relaxed);
    if (*value != 0) {
        atomic_fetch_add_explicit(
            &memory->exclusive_nonzero_reads, 1, memory_order_relaxed);
    }
    *generation = avz_guest_memory_exclusive_write_generation(
        memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    avz_guest_memory_unlock_range_internal(memory, memory_offset, width);
    return 1;
}

int avz_native_fast_memory_exclusive_read_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *first_value,
    uint64_t *second_value,
    uint64_t *generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        first_value == NULL || second_value == NULL || generation == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            0,
            &first_physical,
            &first_host
        ) != AVZ_FAST_TRANSLATION_RAM ||
        avz_fast_translate(
            fast_path,
            virtual_address + width,
            width,
            0,
            &second_physical,
            &second_host
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t first_offset = (size_t)(first_physical - fast_path->ram_base);
    size_t second_offset = (size_t)(second_physical - fast_path->ram_base);
    uint16_t lock_stripes[4];
    size_t lock_stripe_count = 0;
    if (!avz_guest_memory_lock_small_pair(
            memory,
            first_offset,
            width,
            second_offset,
            width,
            lock_stripes,
            sizeof(lock_stripes) / sizeof(lock_stripes[0]),
            &lock_stripe_count)) {
        return 0;
    }
    avz_guest_memory_note_exclusive_observation(
        memory, first_offset, width);
    avz_guest_memory_note_exclusive_observation(
        memory, second_offset, width);
    *first_value = avz_fast_load(first_host, width);
    *second_value = avz_fast_load(second_host, width);
    fast_path->exclusive_expected_address = first_physical;
    fast_path->exclusive_expected_first = *first_value;
    fast_path->exclusive_expected_second = *second_value;
    fast_path->exclusive_expected_width = width;
    fast_path->exclusive_expected_count = 2;
    fast_path->exclusive_expected_valid = 1;
    const uint64_t first_generation = avz_guest_memory_exclusive_write_generation(
        memory,
        first_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t second_generation = avz_guest_memory_exclusive_write_generation(
        memory,
        second_physical,
        fast_path->ram_base,
        width
    );
    *generation = first_generation > second_generation
        ? first_generation
        : second_generation;
    avz_guest_memory_unlock_small_set(
        memory, lock_stripes, lock_stripe_count);
    return 1;
}

int avz_native_fast_memory_exclusive_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value,
    uint64_t expected_generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            1,
            &physical_address,
            &host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return -1;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t memory_offset = (size_t)(physical_address - fast_path->ram_base);
    avz_guest_memory_lock_range_internal(memory, memory_offset, width);
    fast_path->exclusive_expected_valid = 0;
    const uint64_t current_generation = avz_guest_memory_exclusive_write_generation(
        memory,
        physical_address,
        fast_path->ram_base,
        width
    );
    if (current_generation != expected_generation) {
        atomic_fetch_add_explicit(
            &memory->exclusive_write_conflicts, 1, memory_order_relaxed);
        avz_guest_memory_unlock_range_internal(memory, memory_offset, width);
        return 0;
    }

    /*
     * The page-stripe lock and per-granule write generation form the guest
     * global exclusive monitor.  Expected-value scratch belongs to a single
     * PE and must never decide another PE's STXR result when a fast-memory
     * context is reused.  Once the generation matches under the stripe lock,
     * this store is the only architecturally valid winner.
     */
    avz_fast_store_value(host_address, width, value);
    int contains_code = avz_fast_mark_dirty(
        fast_path, physical_address, width);
    avz_fast_invalidate_code_after_write(
        fast_path, physical_address, width, contains_code);
    atomic_fetch_add_explicit(
        &memory->exclusive_write_successes, 1, memory_order_relaxed);
    avz_guest_memory_unlock_range_internal(memory, memory_offset, width);
    return 1;
}

int avz_native_fast_memory_exclusive_write_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t first_value,
    uint64_t second_value,
    uint64_t expected_generation
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            1,
            &first_physical,
            &first_host
        ) != AVZ_FAST_TRANSLATION_RAM ||
        avz_fast_translate(
            fast_path,
            virtual_address + width,
            width,
            1,
            &second_physical,
            &second_host
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return -1;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    size_t first_offset = (size_t)(first_physical - fast_path->ram_base);
    size_t second_offset = (size_t)(second_physical - fast_path->ram_base);
    uint16_t lock_stripes[4];
    size_t lock_stripe_count = 0;
    if (!avz_guest_memory_lock_small_pair(
            memory,
            first_offset,
            width,
            second_offset,
            width,
            lock_stripes,
            sizeof(lock_stripes) / sizeof(lock_stripes[0]),
            &lock_stripe_count)) {
        return -1;
    }
    fast_path->exclusive_expected_valid = 0;
    const uint64_t first_generation = avz_guest_memory_exclusive_write_generation(
        memory,
        first_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t second_generation = avz_guest_memory_exclusive_write_generation(
        memory,
        second_physical,
        fast_path->ram_base,
        width
    );
    const uint64_t current_generation = first_generation > second_generation
        ? first_generation
        : second_generation;
    if (current_generation != expected_generation) {
        atomic_fetch_add_explicit(
            &memory->exclusive_write_conflicts, 1, memory_order_relaxed);
        avz_guest_memory_unlock_small_set(
            memory, lock_stripes, lock_stripe_count);
        return 0;
    }

    avz_fast_store_value(first_host, width, first_value);
    avz_fast_store_value(second_host, width, second_value);
    int first_contains_code = avz_fast_mark_dirty(
        fast_path, first_physical, width);
    int second_contains_code = avz_fast_mark_dirty(
        fast_path, second_physical, width);
    avz_fast_invalidate_code_after_write(
        fast_path, first_physical, width, first_contains_code);
    avz_fast_invalidate_code_after_write(
        fast_path, second_physical, width, second_contains_code);
    atomic_fetch_add_explicit(
        &memory->exclusive_write_successes, 1, memory_order_relaxed);
    avz_guest_memory_unlock_small_set(
        memory, lock_stripes, lock_stripe_count);
    return 1;
}

AVZNativeMemoryFastPath *avz_native_memory_fast_path_create(
    uint8_t *ram,
    uint64_t ram_base,
    uint64_t ram_size,
    AVZNativeBlockCache *block_cache,
    void *slow_context,
    AVZNativeMemoryTranslateRAMCallback translate_ram,
    AVZNativeMemoryReadCallback slow_read,
    AVZNativeMemoryWriteCallback slow_write,
    AVZNativeMemoryCanAccessCallback slow_can_access,
    AVZNativeMemoryFillCallback slow_fill,
    AVZNativeSystemRegisterReadCallback slow_read_system_register,
    AVZNativeSystemRegisterWriteCallback slow_write_system_register,
    AVZNativeSystemInstructionCallback slow_execute_system_instruction,
    AVZNativeExceptionReturnCallback slow_exception_return,
    AVZNativeSynchronousExceptionCallback slow_synchronous_exception,
    AVZNativeWaitCallback slow_wait
) {
    if (ram_size == 0 || slow_context == 0 || translate_ram == 0) {
        return 0;
    }
    AVZNativeMemoryFastPath *fast_path = calloc(1, sizeof(*fast_path));
    if (fast_path == 0) {
        return 0;
    }
    fast_path->ram = ram;
    fast_path->ram_base = ram_base;
    fast_path->ram_size = ram_size;
    fast_path->block_cache = block_cache;
    fast_path->slow_context = slow_context;
    fast_path->translate_ram = translate_ram;
    fast_path->slow_read = slow_read;
    fast_path->slow_write = slow_write;
    fast_path->slow_can_access = slow_can_access;
    fast_path->slow_fill = slow_fill;
    fast_path->slow_read_system_register = slow_read_system_register;
    fast_path->slow_write_system_register = slow_write_system_register;
    fast_path->slow_execute_system_instruction = slow_execute_system_instruction;
    fast_path->slow_exception_return = slow_exception_return;
    fast_path->slow_synchronous_exception = slow_synchronous_exception;
    fast_path->slow_wait = slow_wait;
    fast_path->translation_generation = 1;
    fast_path->hot_translation_generation = 1;
    fast_path->detailed_statistics_enabled = 1;
    fast_path->direct_bulk_mapping_enabled = 1;
    if (block_cache != 0 &&
        !avz_native_block_cache_bind_physical_memory(
            block_cache,
            ram,
            ram_base,
            ram_size
        )) {
        free(fast_path);
        return 0;
    }
    avz_native_block_cache_set_mapping_validator(
        block_cache, avz_fast_instruction_mapping_is_current, fast_path);
    return fast_path;
}

void avz_native_memory_fast_path_destroy(AVZNativeMemoryFastPath *fast_path) {
    if (fast_path != NULL) {
        avz_native_block_cache_set_mapping_validator(fast_path->block_cache, NULL, NULL);
    }
    free(fast_path);
}

void avz_native_memory_fast_path_set_ram(
    AVZNativeMemoryFastPath *fast_path,
    uint8_t *ram
) {
    if (fast_path != 0) {
        if (fast_path->ram != ram) {
            avz_fast_clear_tlbs(fast_path);
            if (fast_path->block_cache != NULL && ram != NULL) {
                avz_native_block_cache_bind_physical_memory(
                    fast_path->block_cache,
                    ram,
                    fast_path->ram_base,
                    fast_path->ram_size
                );
            }
        }
        fast_path->ram = ram;
        if (fast_path->guest_memory != NULL &&
            avz_guest_memory_bytes(fast_path->guest_memory) != ram) {
            fast_path->guest_memory = NULL;
        }
    }
}

void avz_native_memory_fast_path_set_detailed_statistics_enabled(
    AVZNativeMemoryFastPath *fast_path,
    int enabled
) {
    if (fast_path != NULL) {
        fast_path->detailed_statistics_enabled = enabled != 0;
    }
}

void avz_native_memory_fast_path_set_direct_bulk_mapping_enabled(
    AVZNativeMemoryFastPath *fast_path,
    int enabled
) {
    if (fast_path != NULL) {
        fast_path->direct_bulk_mapping_enabled = enabled != 0;
    }
}

int avz_native_memory_fast_path_set_guest_memory(
    AVZNativeMemoryFastPath *fast_path,
    AVZGuestMemory *memory
) {
    if (fast_path == NULL || memory == NULL ||
        avz_guest_memory_bytes(memory) != fast_path->ram ||
        avz_guest_memory_size(memory) != fast_path->ram_size) {
        return 0;
    }
    fast_path->guest_memory = memory;
    fast_path->observed_shared_translation_epoch = atomic_load_explicit(
        &memory->translation_epoch,
        memory_order_acquire
    );
    avz_native_block_cache_set_guest_memory(fast_path->block_cache, memory);
    return 1;
}

void avz_native_memory_fast_path_set_instruction_translator(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativeMemoryTranslateRAMCallback translate_instruction_ram
) {
    if (fast_path == NULL) {
        return;
    }
    avz_native_block_cache_invalidate_decode_window(fast_path->block_cache);
    fast_path->translate_instruction_ram = translate_instruction_ram;
    memset(
        fast_path->instruction_tlb,
        0,
        sizeof(fast_path->instruction_tlb)
    );
    memset(
        fast_path->instruction_hot,
        0,
        sizeof(fast_path->instruction_hot)
    );
    memset(
        fast_path->instruction_replacement,
        0,
        sizeof(fast_path->instruction_replacement)
    );
}

void avz_native_memory_fast_path_set_physical_memory_callbacks(
    AVZNativeMemoryFastPath *fast_path,
    AVZNativePhysicalMemoryReadCallback read_physical,
    AVZNativePhysicalMemoryWriteCallback write_physical
) {
    if (fast_path == NULL) {
        return;
    }
    fast_path->read_physical = read_physical;
    fast_path->write_physical = write_physical;
}

void avz_native_memory_fast_path_set_stage1_translation(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeStage1TranslationState *state,
    AVZNativeMemoryTranslationFaultCallback report_fault
) {
    if (fast_path == NULL) {
        return;
    }
    fast_path->report_translation_fault = report_fault;
    fast_path->translation_fault_pending = 0;
    if (state == NULL) {
        if (fast_path->native_translation_enabled) {
            fast_path->native_translation_enabled = 0;
            avz_fast_invalidate_decoded_mappings(fast_path);
            avz_fast_clear_tlbs(fast_path);
        }
        return;
    }
    int was_enabled = fast_path->native_translation_enabled;
    int state_changed = !was_enabled ||
        !avz_stage1_translation_state_equal(
            &fast_path->translation_state,
            state
        );
    if (state_changed) {
        int geometry_changed = !was_enabled ||
            !avz_stage1_translation_geometry_equal(
                &fast_path->translation_state,
                state
            );
        fast_path->translation_state = *state;
        fast_path->native_translation_enabled = 1;
        avz_fast_refresh_translation_context_tags(fast_path);
        avz_fast_invalidate_decoded_mappings(fast_path);
        if (geometry_changed) {
            avz_fast_clear_tlbs(fast_path);
        }
    }
}

void avz_native_memory_fast_path_clear_translation_fault(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path != NULL) {
        fast_path->translation_fault_pending = 0;
    }
}

void avz_native_memory_fast_path_invalidate_translation(
    AVZNativeMemoryFastPath *fast_path
) {
    if (fast_path == 0) {
        return;
    }
    avz_fast_invalidate_decoded_mappings(fast_path);
    fast_path->translation_fault_pending = 0;
    avz_fast_clear_tlbs(fast_path);
}

AVZNativeMemoryFastPathStatistics avz_native_memory_fast_path_statistics(
    const AVZNativeMemoryFastPath *fast_path
) {
    AVZNativeMemoryFastPathStatistics empty = {0};
    return fast_path == 0 ? empty : fast_path->statistics;
}

void avz_native_memory_fast_path_set_thread_registers(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeThreadRegisterState *state
) {
    if (fast_path == 0 || state == 0) {
        return;
    }
    fast_path->thread_registers = *state;
    fast_path->thread_registers.dirty_mask = 0;
}

void avz_native_memory_fast_path_get_thread_registers(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeThreadRegisterState *state
) {
    if (state == 0) {
        return;
    }
    *state = fast_path == 0
        ? (AVZNativeThreadRegisterState){0}
        : fast_path->thread_registers;
}

void avz_native_memory_fast_path_set_architectural_state(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativeArchitecturalState *state
) {
    if (fast_path == NULL || state == NULL)
        return;
    fast_path->architectural_state = *state;
    fast_path->architectural_state.dirty_mask = 0;
}

void avz_native_memory_fast_path_get_architectural_state(
    const AVZNativeMemoryFastPath *fast_path,
    AVZNativeArchitecturalState *state
) {
    if (state == NULL)
        return;
    *state = fast_path == NULL
        ? (AVZNativeArchitecturalState){0}
        : fast_path->architectural_state;
}

static int avz_native_timer_asserted(
    uint64_t control,
    uint64_t compare,
    uint64_t counter
) {
    return (control & 1u) != 0 && (control & 2u) == 0 && counter >= compare;
}

static uint64_t avz_native_timer_control(
    uint64_t control,
    uint64_t compare,
    uint64_t counter
) {
    return (control & 3u) | (counter >= compare ? 4u : 0u);
}

static uint64_t avz_native_timer_value(uint64_t compare, uint64_t counter) {
    return (uint64_t)(uint32_t)(compare - counter);
}

static uint64_t avz_native_timer_compare_from_value(
    uint64_t value,
    uint64_t counter
) {
    int64_t offset = (int64_t)(int32_t)(uint32_t)value;
    return counter + (uint64_t)offset;
}

int avz_native_memory_fast_path_advance_time(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t instruction_count,
    uint64_t pstate
) {
    if (fast_path == NULL)
        return 0;
    /* Cached chains may execute without a memory callback. Observe shootdowns
     * at their native block boundary before reusing decoded successors. */
    avz_fast_synchronize_shared_translation_epoch(fast_path);
    AVZNativeArchitecturalState *state = &fast_path->architectural_state;
    if (fast_path->counter_clock.frequency != 0) {
        fast_path->counter_refresh_instructions += instruction_count;
        // MRS always reads the live counter. Timer polling is amortized over
        // a short instruction window instead of doing a host-clock read per block.
        if (fast_path->counter_refresh_instructions >= 1024)
            avz_native_refresh_shared_counter(fast_path);
    } else {
        state->counter_ticks += instruction_count * state->timer_cycles_per_instruction;
    }
    if ((pstate & 0x80u) != 0)
        return 0;
    return state->pending_irq ||
        avz_native_timer_asserted(
            state->cntp_ctl_el0, state->cntp_cval_el0, state->counter_ticks) ||
        avz_native_timer_asserted(
            state->cntv_ctl_el0, state->cntv_cval_el0, state->counter_ticks);
}

static void avz_native_fast_set_current_el(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t pstate
) {
    uint8_t current_el = (uint8_t)((pstate >> 2) & 3u);
    if (fast_path == NULL ||
        fast_path->translation_state.current_el == current_el)
        return;
    fast_path->translation_state.current_el = current_el;
    avz_fast_refresh_translation_context_tags(fast_path);
    memset(
        fast_path->instruction_hot,
        0,
        sizeof(fast_path->instruction_hot)
    );
}

int avz_native_fast_memory_read(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    if (value == NULL) {
        return 0;
    }
    int translation = avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        0,
        &physical_address,
        &host_address
    );
    if (translation == AVZ_FAST_TRANSLATION_RAM) {
        AVZGuestMemory *memory = fast_path->guest_memory;
        const size_t memory_offset = physical_address >= fast_path->ram_base
            ? (size_t)(physical_address - fast_path->ram_base)
            : 0;
        const uintptr_t address = (uintptr_t)host_address;
        const int naturally_atomic = width == 1 ||
            (width == 2 && (address & 1u) == 0) ||
            (width == 4 && (address & 3u) == 0) ||
            (width == 8 && (address & 7u) == 0);
        const int requires_lock = memory != NULL &&
            (!naturally_atomic ||
             avz_guest_memory_range_may_have_observation(
                 memory,
                 memory_offset,
                 width,
                 AVZ_GUEST_PAGE_OBSERVATION_HOST));
        if (requires_lock) {
            avz_guest_memory_lock_range_internal(
                memory, memory_offset, width);
        }
        *value = avz_fast_load(host_address, width);
        if (requires_lock) {
            avz_guest_memory_unlock_range_internal(
                memory, memory_offset, width);
        }
        AVZ_MEMORY_STAT_INCREMENT(fast_path, read_hits);
        return 1;
    }
    if (translation == AVZ_FAST_TRANSLATION_PHYSICAL &&
        fast_path->read_physical != NULL &&
        fast_path->read_physical(
            fast_path->slow_context,
            physical_address,
            width,
            value
        )) {
        AVZ_MEMORY_STAT_INCREMENT(fast_path, physical_device_reads);
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_read != 0
        ? fast_path->slow_read(
            fast_path->slow_context,
            virtual_address,
            width,
            value
        )
        : 0;
}

int avz_native_fast_memory_write(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    uint8_t *host_address = NULL;
    int translation = avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        1,
        &physical_address,
        &host_address
    );
    if (translation == AVZ_FAST_TRANSLATION_RAM) {
        avz_fast_store(
            fast_path,
            host_address,
            physical_address,
            width,
            value
        );
        AVZ_MEMORY_STAT_INCREMENT(fast_path, write_hits);
        return 1;
    }
    if (translation == AVZ_FAST_TRANSLATION_PHYSICAL &&
        fast_path->write_physical != NULL &&
        fast_path->write_physical(
            fast_path->slow_context,
            physical_address,
            width,
            value
        )) {
        AVZ_MEMORY_STAT_INCREMENT(fast_path, physical_device_writes);
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_write != 0
        ? fast_path->slow_write(
            fast_path->slow_context,
            virtual_address,
            width,
            value
        )
        : 0;
}

static int avz_native_fast_memory_translate_pair(
    AVZNativeMemoryFastPath *fast_path,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write,
    uint64_t *first_physical,
    uint64_t *second_physical,
    uint8_t **first_host,
    uint8_t **second_host
) {
    if (fast_path == NULL || first_physical == NULL ||
        second_physical == NULL || first_host == NULL ||
        second_host == NULL ||
        (width != 1 && width != 2 && width != 4 && width != 8) ||
        virtual_address > UINT64_MAX - width) {
        return 0;
    }

    const size_t pair_byte_count = (size_t)width * 2u;
    const size_t page_offset =
        (size_t)(virtual_address & (AVZ_FAST_PAGE_SIZE - 1u));
    if (pair_byte_count <= AVZ_FAST_PAGE_SIZE - page_offset &&
        avz_fast_translate(
            fast_path,
            virtual_address,
            (uint8_t)pair_byte_count,
            is_write != 0,
            first_physical,
            first_host
        ) == AVZ_FAST_TRANSLATION_RAM) {
        *second_physical = *first_physical + width;
        *second_host = *first_host + width;
        return 1;
    }

    return avz_fast_translate(
            fast_path,
            virtual_address,
            width,
            is_write != 0,
            first_physical,
            first_host
        ) == AVZ_FAST_TRANSLATION_RAM &&
        avz_fast_translate(
            fast_path,
            virtual_address + width,
            width,
            is_write != 0,
            second_physical,
            second_host
        ) == AVZ_FAST_TRANSLATION_RAM;
}

int avz_native_fast_memory_read_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t *first_value,
    uint64_t *second_value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (first_value == NULL || second_value == NULL ||
        !avz_native_fast_memory_translate_pair(
            fast_path,
            virtual_address,
            width,
            0,
            &first_physical,
            &second_physical,
            &first_host,
            &second_host
        )) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    const size_t first_offset =
        (size_t)(first_physical - fast_path->ram_base);
    const size_t second_offset =
        (size_t)(second_physical - fast_path->ram_base);
    const int requires_lock = memory != NULL &&
        (!avz_fast_access_is_naturally_atomic(first_host, width) ||
         !avz_fast_access_is_naturally_atomic(second_host, width) ||
         avz_guest_memory_range_may_have_observation(
             memory,
             first_offset,
             width,
             AVZ_GUEST_PAGE_OBSERVATION_HOST) ||
         avz_guest_memory_range_may_have_observation(
             memory,
             second_offset,
             width,
             AVZ_GUEST_PAGE_OBSERVATION_HOST));
    uint16_t lock_stripes[4];
    size_t lock_stripe_count = 0;
    if (requires_lock) {
        if (!avz_guest_memory_lock_small_pair(
                memory,
                first_offset,
                width,
                second_offset,
                width,
                lock_stripes,
                sizeof(lock_stripes) / sizeof(lock_stripes[0]),
                &lock_stripe_count)) {
            return 0;
        }
    }
    *first_value = avz_fast_load(first_host, width);
    *second_value = avz_fast_load(second_host, width);
    if (requires_lock) {
        avz_guest_memory_unlock_small_set(
            memory, lock_stripes, lock_stripe_count);
    }
    AVZ_MEMORY_STAT_INCREMENT(fast_path, read_hits);
    AVZ_MEMORY_STAT_INCREMENT(fast_path, read_hits);
    return 1;
}

int avz_native_fast_memory_write_pair(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint64_t first_value,
    uint64_t second_value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t first_physical = 0;
    uint64_t second_physical = 0;
    uint8_t *first_host = NULL;
    uint8_t *second_host = NULL;
    if (!avz_native_fast_memory_translate_pair(
            fast_path,
            virtual_address,
            width,
            1,
            &first_physical,
            &second_physical,
            &first_host,
            &second_host
        )) {
        return 0;
    }

    AVZGuestMemory *memory = fast_path->guest_memory;
    const size_t first_offset =
        (size_t)(first_physical - fast_path->ram_base);
    const size_t second_offset =
        (size_t)(second_physical - fast_path->ram_base);
    const int requires_lock = memory != NULL &&
        (!avz_fast_access_is_naturally_atomic(first_host, width) ||
         !avz_fast_access_is_naturally_atomic(second_host, width) ||
         ((avz_guest_memory_range_may_have_observation(
                memory, first_offset, width, UINT8_MAX) ||
           avz_guest_memory_range_may_have_observation(
                memory, second_offset, width, UINT8_MAX)) &&
          (avz_guest_memory_range_has_host_observer(
               memory, first_offset, width) ||
           avz_guest_memory_range_has_host_observer(
               memory, second_offset, width) ||
           avz_guest_memory_range_has_bulk_reader(
               memory, first_offset, width) ||
           avz_guest_memory_range_has_bulk_reader(
               memory, second_offset, width) ||
           avz_guest_memory_range_has_exclusive_observer(
               memory, first_offset, width) ||
           avz_guest_memory_range_has_exclusive_observer(
               memory, second_offset, width))));
    uint16_t lock_stripes[4];
    size_t lock_stripe_count = 0;
    if (requires_lock) {
        if (!avz_guest_memory_lock_small_pair(
                memory,
                first_offset,
                width,
                second_offset,
                width,
                lock_stripes,
                sizeof(lock_stripes) / sizeof(lock_stripes[0]),
                &lock_stripe_count)) {
            return 0;
        }
    }

    avz_fast_store_value(first_host, width, first_value);
    avz_fast_store_value(second_host, width, second_value);
    if (second_physical == first_physical + width) {
        const size_t byte_count = (size_t)width * 2u;
        int contains_code = avz_fast_mark_dirty(
            fast_path, first_physical, byte_count);
        avz_fast_invalidate_code_after_write(
            fast_path, first_physical, byte_count, contains_code);
    } else {
        int contains_code = avz_fast_mark_dirty(
            fast_path, first_physical, width);
        avz_fast_invalidate_code_after_write(
            fast_path, first_physical, width, contains_code);
        contains_code = avz_fast_mark_dirty(
            fast_path, second_physical, width);
        avz_fast_invalidate_code_after_write(
            fast_path, second_physical, width, contains_code);
    }
    if (requires_lock) {
        avz_guest_memory_unlock_small_set(
            memory, lock_stripes, lock_stripe_count);
    }
    AVZ_MEMORY_STAT_INCREMENT(fast_path, write_hits);
    AVZ_MEMORY_STAT_INCREMENT(fast_path, write_hits);
    return 1;
}

int avz_native_fast_memory_read_bytes(
    void *context,
    uint64_t virtual_address,
    void *destination,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint8_t *output = destination;
    if (fast_path == NULL || output == NULL || byte_count == 0 ||
        byte_count > AVZ_FAST_PAGE_SIZE ||
        virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    typedef struct {
        uint8_t *host_address;
        uint64_t physical_address;
        size_t destination_offset;
        size_t byte_count;
    } AVZNativeReadSpan;
    AVZNativeReadSpan spans[2];
    size_t span_count = 0;
    size_t checked = 0;
    while (checked < byte_count) {
        uint64_t address = virtual_address + checked;
        size_t page_remaining = AVZ_FAST_PAGE_SIZE -
            (size_t)(address & (AVZ_FAST_PAGE_SIZE - 1u));
        size_t chunk = byte_count - checked < page_remaining
            ? byte_count - checked
            : page_remaining;
        if (span_count >= sizeof(spans) / sizeof(spans[0])) {
            return 0;
        }
        AVZNativeReadSpan *span = &spans[span_count];
        if (avz_fast_translate(
                fast_path,
                address,
                1,
                0,
                &span->physical_address,
                &span->host_address
            ) != AVZ_FAST_TRANSLATION_RAM) {
            return 0;
        }
        span->destination_offset = checked;
        span->byte_count = chunk;
        span_count++;
        checked += chunk;
    }

    uint16_t lock_stripes[2];
    size_t lock_stripe_count = 0;
    if (fast_path->guest_memory != NULL) {
        /* This is synchronous vCPU work, not a retained host mapping. Only
         * pages already shared with a device require stripe serialization. */
        for (size_t index = 0; index < span_count; index++) {
            AVZNativeReadSpan *span = &spans[index];
            const size_t memory_offset = (size_t)(
                span->physical_address - fast_path->ram_base);
            if (avz_guest_memory_range_may_have_observation(
                    fast_path->guest_memory,
                    memory_offset,
                    span->byte_count,
                    AVZ_GUEST_PAGE_OBSERVATION_HOST) &&
                !avz_guest_memory_collect_small_range_locks(
                    fast_path->guest_memory,
                    memory_offset,
                    span->byte_count,
                    lock_stripes,
                    sizeof(lock_stripes) / sizeof(lock_stripes[0]),
                    &lock_stripe_count)) {
                return 0;
            }
        }
        avz_guest_memory_lock_small_set(
            fast_path->guest_memory, lock_stripes, lock_stripe_count);
    }
    for (size_t index = 0; index < span_count; index++) {
        AVZNativeReadSpan *span = &spans[index];
        avz_fast_atomic_read_bytes(
            span->host_address,
            output + span->destination_offset,
            span->byte_count);
    }
    if (fast_path->guest_memory != NULL) {
        avz_guest_memory_unlock_small_set(
            fast_path->guest_memory, lock_stripes, lock_stripe_count);
    }
    AVZ_MEMORY_STAT_INCREMENT(fast_path, read_hits);
    return 1;
}

int avz_native_fast_memory_write_bytes(
    void *context,
    uint64_t virtual_address,
    const void *source,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    const uint8_t *input = source;
    if (fast_path == NULL || input == NULL || byte_count == 0 ||
        byte_count > 64 || virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    typedef struct {
        uint8_t *host_address;
        uint64_t physical_address;
        size_t source_offset;
        size_t byte_count;
    } AVZNativeWriteSpan;
    AVZNativeWriteSpan spans[2];
    size_t span_count = 0;
    size_t checked = 0;
    while (checked < byte_count) {
        uint64_t address = virtual_address + checked;
        size_t page_remaining = AVZ_FAST_PAGE_SIZE -
            (size_t)(address & (AVZ_FAST_PAGE_SIZE - 1u));
        size_t chunk = byte_count - checked < page_remaining
            ? byte_count - checked
            : page_remaining;
        if (span_count >= sizeof(spans) / sizeof(spans[0])) {
            return 0;
        }
        AVZNativeWriteSpan *span = &spans[span_count];
        if (avz_fast_translate(
                fast_path,
                address,
                1,
                1,
                &span->physical_address,
                &span->host_address
            ) != AVZ_FAST_TRANSLATION_RAM) {
            return 0;
        }
        span->source_offset = checked;
        span->byte_count = chunk;
        span_count++;
        checked += chunk;
    }

    for (size_t index = 0; index < span_count; index++) {
        AVZNativeWriteSpan *span = &spans[index];
        size_t memory_offset = (size_t)(
            span->physical_address - fast_path->ram_base);
        /* Do not permanently turn libc/SIMD destinations into shared pages.
         * Existing host and exclusive observers still use the same locks. */
        int requires_lock = fast_path->guest_memory != NULL &&
            avz_guest_memory_range_may_have_observation(
                fast_path->guest_memory,
                memory_offset,
                span->byte_count,
                UINT8_MAX) &&
            (avz_guest_memory_range_has_host_observer(
                 fast_path->guest_memory,
                 memory_offset,
                 span->byte_count) ||
             avz_guest_memory_range_has_bulk_reader(
                 fast_path->guest_memory,
                 memory_offset,
                 span->byte_count) ||
             avz_guest_memory_range_has_exclusive_observer(
                 fast_path->guest_memory,
                 memory_offset,
                 span->byte_count));
        if (requires_lock) {
            avz_guest_memory_lock_range_internal(
                fast_path->guest_memory, memory_offset, span->byte_count);
        }
        avz_fast_atomic_write_bytes(
            span->host_address,
            input + span->source_offset,
            span->byte_count);
        int contains_code = avz_fast_mark_dirty(
            fast_path,
            span->physical_address,
            span->byte_count
        );
        avz_fast_invalidate_code_after_write(
            fast_path,
            span->physical_address,
            span->byte_count,
            contains_code
        );
        if (requires_lock) {
            avz_guest_memory_unlock_range_internal(
                fast_path->guest_memory, memory_offset, span->byte_count);
        }
    }
    AVZ_MEMORY_STAT_INCREMENT(fast_path, write_hits);
    return 1;
}

int avz_native_fast_memory_map_span(
    void *context,
    uint64_t virtual_address,
    size_t byte_count,
    uint8_t is_write,
    uint8_t **host_address,
    uint64_t *physical_address
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || !fast_path->direct_bulk_mapping_enabled ||
        host_address == NULL ||
        physical_address == NULL || byte_count == 0 || byte_count > 64 ||
        virtual_address > UINT64_MAX - (byte_count - 1u)) {
        return 0;
    }

    size_t page_offset =
        (size_t)(virtual_address & (AVZ_FAST_PAGE_SIZE - 1u));
    if (byte_count > AVZ_FAST_PAGE_SIZE - page_offset) {
        return 0;
    }

    if (avz_fast_translate(
            fast_path,
            virtual_address,
            1,
            is_write != 0,
            physical_address,
            host_address
        ) != AVZ_FAST_TRANSLATION_RAM) {
        return 0;
    }

    uint64_t ram_offset = *physical_address - fast_path->ram_base;
    if (ram_offset > fast_path->ram_size ||
        byte_count > fast_path->ram_size - ram_offset) {
        return 0;
    }
    if (is_write != 0) {
        avz_guest_memory_note_host_observation(
            fast_path->guest_memory,
            (size_t)ram_offset,
            byte_count
        );
    } else {
        avz_guest_memory_note_bulk_read(
            fast_path->guest_memory,
            (size_t)ram_offset,
            byte_count
        );
    }
    if (is_write != 0) {
        AVZ_MEMORY_STAT_INCREMENT(fast_path, write_hits);
    } else {
        AVZ_MEMORY_STAT_INCREMENT(fast_path, read_hits);
    }
    return 1;
}

void avz_native_fast_memory_lock(void *context) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL) {
        avz_guest_memory_lock_internal(fast_path->guest_memory);
    }
}

void avz_native_fast_memory_unlock(void *context) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL) {
        avz_guest_memory_unlock_internal(fast_path->guest_memory);
    }
}

void avz_native_fast_memory_lock_physical_span(
    void *context,
    uint64_t physical_address,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        physical_address < fast_path->ram_base) {
        return;
    }
    uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > SIZE_MAX) {
        return;
    }
    avz_guest_memory_lock_range_internal(
        fast_path->guest_memory, (size_t)offset, byte_count);
}

void avz_native_fast_memory_unlock_physical_span(
    void *context,
    uint64_t physical_address,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        physical_address < fast_path->ram_base) {
        return;
    }
    uint64_t offset = physical_address - fast_path->ram_base;
    if (offset > SIZE_MAX) {
        return;
    }
    avz_guest_memory_unlock_range_internal(
        fast_path->guest_memory, (size_t)offset, byte_count);
}

static int avz_native_fast_memory_collect_physical_spans(
    AVZNativeMemoryFastPath *fast_path,
    const AVZNativePhysicalSpan *spans,
    size_t span_count,
    uint64_t *lock_bitmap
) {
    if (fast_path == NULL || fast_path->guest_memory == NULL ||
        spans == NULL || span_count == 0) {
        return 0;
    }
    memset(lock_bitmap, 0,
        AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS * sizeof(*lock_bitmap));
    for (size_t index = 0; index < span_count; index++) {
        if (spans[index].physical_address < fast_path->ram_base) {
            return 0;
        }
        uint64_t offset = spans[index].physical_address - fast_path->ram_base;
        if (offset > SIZE_MAX || !avz_guest_memory_collect_range_locks(
                fast_path->guest_memory,
                (size_t)offset,
                spans[index].byte_count,
                lock_bitmap)) {
            return 0;
        }
    }
    return 1;
}

int avz_native_fast_memory_lock_physical_spans(
    void *context,
    const AVZNativePhysicalSpan *spans,
    size_t span_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && fast_path->guest_memory == NULL) {
        return 1;
    }
    uint64_t lock_bitmap[AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS];
    if (!avz_native_fast_memory_collect_physical_spans(
            fast_path, spans, span_count, lock_bitmap)) {
        return 0;
    }
    avz_guest_memory_lock_bitmap(fast_path->guest_memory, lock_bitmap);
    return 1;
}

void avz_native_fast_memory_unlock_physical_spans(
    void *context,
    const AVZNativePhysicalSpan *spans,
    size_t span_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && fast_path->guest_memory == NULL) {
        return;
    }
    uint64_t lock_bitmap[AVZ_GUEST_MEMORY_LOCK_BITMAP_WORDS];
    if (!avz_native_fast_memory_collect_physical_spans(
            fast_path, spans, span_count, lock_bitmap)) {
        return;
    }
    avz_guest_memory_unlock_bitmap(fast_path->guest_memory, lock_bitmap);
}

void avz_native_fast_memory_commit_write_span(
    void *context,
    uint64_t physical_address,
    size_t byte_count
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path == NULL || byte_count == 0) {
        return;
    }
    int contains_code = avz_fast_mark_dirty(
        fast_path, physical_address, byte_count);
    avz_fast_invalidate_code_after_write(
        fast_path, physical_address, byte_count, contains_code);
}

int avz_native_fast_memory_can_access(
    void *context,
    uint64_t virtual_address,
    uint8_t width,
    uint8_t is_write
) {
    AVZNativeMemoryFastPath *fast_path = context;
    uint64_t physical_address = 0;
    if (avz_fast_translate(
        fast_path,
        virtual_address,
        width,
        is_write != 0,
        &physical_address,
        NULL
    ) == AVZ_FAST_TRANSLATION_RAM) {
        return 1;
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_can_access != 0
        ? fast_path->slow_can_access(
            fast_path->slow_context,
            virtual_address,
            width,
            is_write
        )
        : 0;
}

int avz_native_fast_memory_fill(
    void *context,
    uint64_t virtual_address,
    uint64_t byte_count,
    uint64_t pattern,
    uint8_t pattern_width
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && byte_count != 0 &&
        (pattern_width == 1 || pattern_width == 2 ||
         pattern_width == 4 || pattern_width == 8) &&
        virtual_address <= UINT64_MAX - (byte_count - 1)) {
        uint64_t checked = 0;
        int all_ram = 1;
        while (checked < byte_count) {
            uint64_t address = virtual_address + checked;
            uint64_t page_remaining =
                AVZ_FAST_PAGE_SIZE -
                (address & (AVZ_FAST_PAGE_SIZE - 1u));
            uint64_t chunk = byte_count - checked < page_remaining
                ? byte_count - checked
                : page_remaining;
            uint64_t physical_address = 0;
            if (avz_fast_translate(
                    fast_path,
                    address,
                    1,
                    1,
                    &physical_address,
                    NULL
                ) != AVZ_FAST_TRANSLATION_RAM) {
                all_ram = 0;
                break;
            }
            checked += chunk;
        }

        if (all_ram) {
            uint8_t pattern_bytes[8] = {0};
            memcpy(pattern_bytes, &pattern, pattern_width);
            uint64_t written = 0;
            while (written < byte_count) {
                uint64_t address = virtual_address + written;
                uint64_t page_remaining =
                    AVZ_FAST_PAGE_SIZE -
                    (address & (AVZ_FAST_PAGE_SIZE - 1u));
                uint64_t chunk = byte_count - written < page_remaining
                    ? byte_count - written
                    : page_remaining;
                uint64_t physical_address = 0;
                uint8_t *host_address = NULL;
                if (avz_fast_translate(
                        fast_path,
                        address,
                        1,
                        1,
                        &physical_address,
                        &host_address
                    ) != AVZ_FAST_TRANSLATION_RAM) {
                    AVZ_MEMORY_STAT_INCREMENT(fast_path, fill_misses);
                    return 0;
                }
                size_t memory_offset = (size_t)(
                    physical_address - fast_path->ram_base);
                int requires_lock = fast_path->guest_memory != NULL &&
                    avz_guest_memory_range_may_have_observation(
                        fast_path->guest_memory,
                        memory_offset,
                        (size_t)chunk,
                        UINT8_MAX) &&
                    (avz_guest_memory_range_has_host_observer(
                         fast_path->guest_memory,
                         memory_offset,
                         (size_t)chunk) ||
                     avz_guest_memory_range_has_bulk_reader(
                         fast_path->guest_memory,
                         memory_offset,
                         (size_t)chunk) ||
                     avz_guest_memory_range_has_exclusive_observer(
                         fast_path->guest_memory,
                         memory_offset,
                         (size_t)chunk));
                if (requires_lock) {
                    avz_guest_memory_lock_range_internal(
                        fast_path->guest_memory,
                        memory_offset,
                        (size_t)chunk);
                }
                avz_fast_atomic_fill_bytes(
                    host_address,
                    (size_t)chunk,
                    pattern_bytes,
                    pattern_width,
                    written % pattern_width);
                int contains_code = avz_fast_mark_dirty(
                    fast_path,
                    physical_address,
                    (size_t)chunk
                );
                avz_fast_invalidate_code_after_write(
                    fast_path,
                    physical_address,
                    (size_t)chunk,
                    contains_code
                );
                if (requires_lock) {
                    avz_guest_memory_unlock_range_internal(
                        fast_path->guest_memory,
                        memory_offset,
                        (size_t)chunk);
                }
                written += chunk;
            }
            AVZ_MEMORY_STAT_INCREMENT(fast_path, fill_hits);
            return 1;
        }
        AVZ_MEMORY_STAT_INCREMENT(fast_path, fill_misses);
    }
    if (fast_path != NULL && fast_path->translation_fault_pending) {
        return 0;
    }
    return fast_path != 0 && fast_path->slow_fill != 0
        ? fast_path->slow_fill(
            fast_path->slow_context,
            virtual_address,
            byte_count,
            pattern,
            pattern_width
        )
        : 0;
}

int avz_native_fast_read_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t pstate,
    uint64_t sp,
    uint64_t *value
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != 0 && value != 0) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        switch (avz_system_register_key(instruction)) {
        case AVZ_SYSREG_SPSR_EL1:
            *value = state->spsr_el1;
            break;
        case AVZ_SYSREG_ELR_EL1:
            *value = state->elr_el1;
            break;
        case AVZ_SYSREG_SP_EL0:
            *value = (pstate & 1u) == 0 ? sp : state->sp_el0;
            break;
        case AVZ_SYSREG_ESR_EL1:
            *value = state->esr_el1;
            break;
        case AVZ_SYSREG_FAR_EL1:
            *value = state->far_el1;
            break;
        case AVZ_SYSREG_VBAR_EL1:
            *value = state->vbar_el1;
            break;
        case AVZ_SYSREG_TPIDR_EL0:
            *value = fast_path->thread_registers.tpidr_el0;
            break;
        case AVZ_SYSREG_TPIDRRO_EL0:
            *value = fast_path->thread_registers.tpidrro_el0;
            break;
        case AVZ_SYSREG_TPIDR_EL1:
            *value = fast_path->thread_registers.tpidr_el1;
            break;
        case AVZ_SYSREG_CONTEXTIDR_EL1:
            *value = fast_path->thread_registers.contextidr_el1;
            break;
        case AVZ_SYSREG_CNTPCT_EL0:
        case AVZ_SYSREG_CNTVCT_EL0:
            avz_native_refresh_shared_counter(fast_path);
            *value = state->counter_ticks;
            break;
        case AVZ_SYSREG_CNTP_TVAL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            *value = avz_native_timer_value(
                state->cntp_cval_el0, state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTP_CTL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            *value = avz_native_timer_control(
                state->cntp_ctl_el0,
                state->cntp_cval_el0,
                state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTP_CVAL_EL0:
            *value = state->cntp_cval_el0;
            break;
        case AVZ_SYSREG_CNTV_TVAL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            *value = avz_native_timer_value(
                state->cntv_cval_el0, state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTV_CTL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            *value = avz_native_timer_control(
                state->cntv_ctl_el0,
                state->cntv_cval_el0,
                state->counter_ticks);
            break;
        case AVZ_SYSREG_CNTV_CVAL_EL0:
            *value = state->cntv_cval_el0;
            break;
        default:
            goto slow_path;
        }
        AVZ_MEMORY_STAT_INCREMENT(fast_path, local_system_register_reads);
        return 1;
    }

slow_path:
    return fast_path != 0 && fast_path->slow_read_system_register != 0
        ? fast_path->slow_read_system_register(
            fast_path->slow_context,
            instruction,
            pc,
            pstate,
            sp,
            value
        )
        : 0;
}

int avz_native_fast_write_system_register(
    void *context,
    uint32_t instruction,
    uint64_t pc,
    uint64_t value,
    uint64_t *pstate,
    uint64_t *sp
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != 0) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        switch (avz_system_register_key(instruction)) {
        case AVZ_SYSREG_SPSR_EL1:
            state->spsr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SPSR_EL1;
            break;
        case AVZ_SYSREG_ELR_EL1:
            state->elr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_ELR_EL1;
            break;
        case AVZ_SYSREG_SP_EL0:
            if ((*pstate & 1u) == 0) {
                *sp = value;
            } else {
                state->sp_el0 = value;
            }
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
            break;
        case AVZ_SYSREG_ESR_EL1:
            state->esr_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_ESR_EL1;
            break;
        case AVZ_SYSREG_FAR_EL1:
            state->far_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_FAR_EL1;
            break;
        case AVZ_SYSREG_VBAR_EL1:
            state->vbar_el1 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_VBAR_EL1;
            break;
        case AVZ_SYSREG_TPIDR_EL0:
            fast_path->thread_registers.tpidr_el0 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL0;
            break;
        case AVZ_SYSREG_TPIDRRO_EL0:
            fast_path->thread_registers.tpidrro_el0 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDRRO_EL0;
            break;
        case AVZ_SYSREG_TPIDR_EL1:
            fast_path->thread_registers.tpidr_el1 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_TPIDR_EL1;
            break;
        case AVZ_SYSREG_CONTEXTIDR_EL1:
            fast_path->thread_registers.contextidr_el1 = value;
            fast_path->thread_registers.dirty_mask |=
                AVZ_NATIVE_THREAD_REGISTER_CONTEXTIDR_EL1;
            break;
        case AVZ_SYSREG_CNTP_TVAL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            state->cntp_cval_el0 = avz_native_timer_compare_from_value(
                value, state->counter_ticks);
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTP_CTL_EL0:
            state->cntp_ctl_el0 = value & 3u;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CTL_EL0;
            break;
        case AVZ_SYSREG_CNTP_CVAL_EL0:
            state->cntp_cval_el0 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTP_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTV_TVAL_EL0:
            avz_native_refresh_shared_counter(fast_path);
            state->cntv_cval_el0 = avz_native_timer_compare_from_value(
                value, state->counter_ticks);
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CVAL_EL0;
            break;
        case AVZ_SYSREG_CNTV_CTL_EL0:
            state->cntv_ctl_el0 = value & 3u;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CTL_EL0;
            break;
        case AVZ_SYSREG_CNTV_CVAL_EL0:
            state->cntv_cval_el0 = value;
            state->dirty_mask |= AVZ_NATIVE_ARCH_CNTV_CVAL_EL0;
            break;
        default:
            goto slow_path;
        }
        AVZ_MEMORY_STAT_INCREMENT(fast_path, local_system_register_writes);
        return 1;
    }

slow_path:
    return fast_path != 0 && fast_path->slow_write_system_register != 0
        ? fast_path->slow_write_system_register(
            fast_path->slow_context,
            instruction,
            pc,
            value,
            pstate,
            sp
        )
        : 0;
}

int avz_native_fast_execute_system_instruction(
    void *context,
    uint32_t instruction,
    uint64_t operand
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL &&
        avz_is_coherent_cache_maintenance(instruction)) {
        return 1;
    }
    return fast_path != 0 && fast_path->slow_execute_system_instruction != 0
        ? fast_path->slow_execute_system_instruction(
            fast_path->slow_context,
            instruction,
            operand
        )
        : 0;
}

int avz_native_fast_exception_return(
    void *context,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && pstate != NULL && sp != NULL && pc != NULL) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        uint64_t old_pstate = *pstate;
        uint64_t new_pstate = state->spsr_el1;
        if ((old_pstate & 1u) == 0) {
            state->sp_el0 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
        } else {
            state->sp_el1 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL1;
        }
        *sp = (new_pstate & 1u) == 0 ? state->sp_el0 : state->sp_el1;
        *pstate = new_pstate;
        *pc = state->elr_el1;
        avz_native_fast_set_current_el(fast_path, new_pstate);
        return 1;
    }
    return fast_path != 0 && fast_path->slow_exception_return != 0
        ? fast_path->slow_exception_return(
            fast_path->slow_context,
            pstate,
            sp,
            pc
        )
        : 0;
}

int avz_native_fast_synchronous_exception(
    void *context,
    uint32_t instruction,
    uint64_t *x31,
    uint64_t *pstate,
    uint64_t *sp,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    if (fast_path != NULL && x31 != NULL && pstate != NULL &&
        sp != NULL && pc != NULL &&
        (instruction & 0xffe0001fu) == 0xd4000001u) {
        AVZNativeArchitecturalState *state = &fast_path->architectural_state;
        uint64_t previous_pstate = *pstate;
        uint64_t current_el = (previous_pstate >> 2) & 3u;
        uint64_t vector_offset = current_el == 0
            ? 0x400u
            : ((previous_pstate & 1u) == 0 ? 0u : 0x200u);
        if ((previous_pstate & 1u) == 0) {
            state->sp_el0 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL0;
        } else {
            state->sp_el1 = *sp;
            state->dirty_mask |= AVZ_NATIVE_ARCH_SP_EL1;
        }
        state->spsr_el1 = previous_pstate;
        state->elr_el1 = *pc + 4u;
        state->esr_el1 = (UINT64_C(0x15) << 26) |
            ((instruction >> 5) & 0xffffu);
        state->dirty_mask |= AVZ_NATIVE_ARCH_SPSR_EL1 |
            AVZ_NATIVE_ARCH_ELR_EL1 | AVZ_NATIVE_ARCH_ESR_EL1;
        *sp = state->sp_el1;
        *pstate = UINT64_C(0x3c5);
        *pc = state->vbar_el1 + vector_offset;
        avz_native_fast_set_current_el(fast_path, *pstate);
        return 1;
    }
    return fast_path != 0 && fast_path->slow_synchronous_exception != 0
        ? fast_path->slow_synchronous_exception(
            fast_path->slow_context,
            instruction,
            x31,
            pstate,
            sp,
            pc
        )
        : 0;
}

int avz_native_fast_wait(
    void *context,
    uint32_t instruction,
    uint64_t *pc
) {
    AVZNativeMemoryFastPath *fast_path = context;
    return fast_path != 0 && fast_path->slow_wait != 0
        ? fast_path->slow_wait(fast_path->slow_context, instruction, pc)
        : 0;
}
