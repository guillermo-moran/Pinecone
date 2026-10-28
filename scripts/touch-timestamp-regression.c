#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define S64_MAX INT64_MAX
#define U64_MAX UINT64_MAX
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define EV_SYN 0
#define EV_KEY 1
#define EV_ABS 3
#define EV_MSC 4
#define BTN_TOUCH 330

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef u64 __le64;
typedef unsigned spinlock_t;

struct virtio_input_event { u16 type, code; u32 value; };
struct input_dev { struct { u16 vendor, product, version; } id; };
struct virtio_input_config { u8 header[8]; u8 u[128]; };
struct virtio_input;
struct virtio_device;

static u8 virtinput_cfg_select(struct virtio_input *vi, u8 select, u8 subselect);
static void virtio_cread_bytes(struct virtio_device *vdev, size_t offset, void *dest, size_t size);
static u64 ktime_get_ns(void);
static u64 le64_to_cpu(__le64 value);
static u64 ns_to_ktime(u64 value);
static void input_set_timestamp(struct input_dev *idev, u64 value);

/* Generated from pristine Linux + the checked-in patch by the runner. */
#include "touch-timestamp-linux.inc"

static u64 host_now, guest_now, published;
static unsigned timestamp_sets, clock_reads;
static u8 config_size;

static u8 virtinput_cfg_select(struct virtio_input *vi, u8 select, u8 subselect)
{
    (void)vi;
    assert(select == PINECONE_INPUT_CLOCK && subselect == 0);
    clock_reads++;
    return config_size;
}

static void virtio_cread_bytes(struct virtio_device *vdev, size_t offset, void *dest, size_t size)
{
    (void)vdev;
    assert(offset == offsetof(struct virtio_input_config, u) && size == 8);
    for (unsigned i = 0; i < 8; i++)
        ((u8 *)dest)[i] = (u8)(host_now >> (i * 8));
}

static u64 ktime_get_ns(void) { return guest_now; }

static u64 le64_to_cpu(__le64 value)
{
    u8 bytes[8];
    u64 result = 0;
    memcpy(bytes, &value, sizeof(bytes));
    for (unsigned i = 0; i < 8; i++)
        result |= (u64)bytes[i] << (i * 8);
    return result;
}

static u64 ns_to_ktime(u64 value) { return value; }

static void input_set_timestamp(struct input_dev *idev, u64 value)
{
    (void)idev;
    published = value;
    timestamp_sets++;
}

static struct virtio_input fixture(void)
{
    host_now = 500000000000ULL;
    guest_now = 10000000000ULL;
    published = 0;
    timestamp_sets = 0;
    clock_reads = 0;
    config_size = 8;
    return (struct virtio_input){ .pinecone_timestamps = true };
}

static void prefix(struct virtio_input *vi, u64 capture)
{
    unsigned before = timestamp_sets;
    assert(virtinput_pinecone_time(vi, EV_MSC, PINECONE_TIME_LO, (u32)capture));
    assert(virtinput_pinecone_time(vi, EV_MSC, PINECONE_TIME_HI, (u32)(capture >> 32)));
    assert(timestamp_sets == before); /* Deferred until the first frame data. */
}

static void frame(struct virtio_input *vi, u64 capture, u16 type, u16 code, u32 value)
{
    prefix(vi, capture);
    assert(!virtinput_pinecone_time(vi, type, code, value));
    assert(!virtinput_pinecone_time(vi, EV_SYN, 0, 0));
}

static void test_delayed_burst_and_gesture_reanchor(void)
{
    struct virtio_input vi = fixture();
    frame(&vi, host_now - 100000000, EV_KEY, BTN_TOUCH, 1);
    assert(published == guest_now - 100000000);
    frame(&vi, host_now - 50000000, EV_ABS, 0, 10);
    assert(published == guest_now - 50000000);
    frame(&vi, host_now - 20000000, EV_KEY, BTN_TOUCH, 0);
    assert(published == guest_now - 20000000);
    assert(clock_reads == 1 && timestamp_sets == 3);

    /* Different clock progress while idle must not pollute the next gesture. */
    host_now += 100000000000ULL;
    guest_now += 40000000000ULL;
    frame(&vi, host_now - 100000000, EV_KEY, BTN_TOUCH, 1);
    assert(published == guest_now - 100000000 && clock_reads == 2);
    frame(&vi, host_now - 50000000, EV_ABS, 0, 20);
    assert(published == guest_now - 50000000 && clock_reads == 2);
}

static void test_bounds_and_full_width_time(void)
{
    struct virtio_input vi = fixture();
    frame(&vi, host_now + 1000000000, EV_KEY, BTN_TOUCH, 1);
    assert(published == guest_now);
    frame(&vi, 1, EV_ABS, 0, 1);
    assert(published == guest_now); /* No backwards output. */
    frame(&vi, UINT64_MAX, EV_ABS, 0, 2);
    assert(published == guest_now);

    vi = fixture();
    guest_now = 5;
    frame(&vi, 1, EV_KEY, BTN_TOUCH, 1);
    assert(published == 1); /* Zero is an unset input-core timestamp. */

    vi = fixture();
    host_now = 0x200000010ULL;
    guest_now = 1000000;
    frame(&vi, 0x1fffffff0ULL, EV_KEY, BTN_TOUCH, 1);
    assert(published == guest_now - 32); /* Cross the low-word rollover. */

    vi = fixture();
    vi.host_anchor_ns = 1;
    vi.guest_anchor_ns = UINT64_MAX - 5;
    assert(virtinput_map_time(&vi, 10, guest_now) == guest_now);
}

static void test_malformed_prefixes_and_unavailable_clock(void)
{
    struct virtio_input vi = fixture();
    assert(virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_HI, 1));
    assert(!virtinput_pinecone_time(&vi, EV_ABS, 0, 100));
    assert(timestamp_sets == 0);
    assert(virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_LO, 1));
    assert(!virtinput_pinecone_time(&vi, EV_SYN, 0, 0));
    assert(virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_HI, 1));
    assert(!virtinput_pinecone_time(&vi, EV_ABS, 0, 100));
    assert(timestamp_sets == 0);

    for (unsigned size = 0; size <= 9; size++) {
        if (size == 8)
            continue;
        vi = fixture();
        config_size = (u8)size;
        frame(&vi, host_now, EV_KEY, BTN_TOUCH, 1);
        assert(!vi.clock_valid && timestamp_sets == 0);
    }
    vi = fixture();
    host_now = UINT64_MAX;
    frame(&vi, 1, EV_KEY, BTN_TOUCH, 1);
    assert(!vi.clock_valid && timestamp_sets == 0);
}

static void test_exact_device_gate(void)
{
    struct virtio_input vi = fixture();
    struct input_dev idev = { .id = { .vendor = 0x4156, .product = 1, .version = 2 } };
    vi.idev = &idev;
    strcpy(vi.serial, "arm64viz-touch0");
    configure_timestamp_gate(&vi);
    assert(vi.pinecone_timestamps);
    idev.id.version = 1;
    configure_timestamp_gate(&vi);
    assert(!vi.pinecone_timestamps);
    assert(!virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_LO, 1));
    assert(!virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_HI, 1));
    assert(timestamp_sets == 0 && clock_reads == 0);
    idev.id.version = 2;
    idev.id.vendor++;
    configure_timestamp_gate(&vi);
    assert(!vi.pinecone_timestamps);
    idev.id.vendor--;
    idev.id.product++;
    configure_timestamp_gate(&vi);
    assert(!vi.pinecone_timestamps);
    idev.id.product--;
    strcpy(vi.serial, "arm64viz-keyboard0");
    configure_timestamp_gate(&vi);
    assert(!vi.pinecone_timestamps);
}

static void test_pm_reset_discards_pending_time_and_recalibrates(void)
{
    struct virtio_input vi = fixture();
    frame(&vi, host_now, EV_KEY, BTN_TOUCH, 1);
    prefix(&vi, host_now);
    assert(vi.capture_valid && vi.clock_valid && vi.last_time_ns);
    reset_timestamp_state(&vi);
    assert(!vi.capture_valid && !vi.time_low_valid && !vi.clock_valid && !vi.last_time_ns);
    assert(!virtinput_pinecone_time(&vi, EV_ABS, 0, 10));
    assert(timestamp_sets == 1);
    assert(virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_LO, 1));
    reset_timestamp_state(&vi);
    assert(!vi.time_low_valid);
    assert(virtinput_pinecone_time(&vi, EV_MSC, PINECONE_TIME_HI, 1));
    assert(!virtinput_pinecone_time(&vi, EV_ABS, 0, 10));
    assert(timestamp_sets == 1);
    host_now += 100000000000ULL;
    guest_now += 1000000000;
    frame(&vi, host_now - 100000000, EV_ABS, 0, 20);
    assert(clock_reads == 2 && published == guest_now - 100000000);
}

int main(void)
{
    test_delayed_burst_and_gesture_reanchor();
    test_bounds_and_full_width_time();
    test_malformed_prefixes_and_unavailable_clock();
    test_exact_device_gate();
    test_pm_reset_discards_pending_time_and_recalibrates();
    puts("PASS: delayed capture intervals, gesture reanchor, bounds, rollover, malformed metadata, device gate and PM reset");
    return 0;
}
