/* Exercise the actual patched GLib matcher, not a second optimized copy. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static size_t comparisons;
static int counted_memcmp(const void *a, const void *b, size_t n)
{
    comparisons++;
    return memcmp(a, b, n);
}
#define memcmp counted_memcmp
#include "xdgmimecache.c"
#undef memcmp

static uint32_t seed = 0x61a2459b;
static uint32_t random_word(void)
{
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

static void put32(unsigned char *cache, size_t offset, uint32_t value)
{
    value = htonl(value);
    memcpy(cache + offset, &value, sizeof(value));
}

static int reference(const unsigned char *bytes, size_t len,
                     const unsigned char *value, const unsigned char *mask,
                     size_t length, uint32_t start, uint32_t count)
{
    if (start > len || length > len - start) return 0;
    for (size_t i = start; count && i <= len - length; count--, i++) {
        size_t j = 0;
        while (j < length && ((bytes[i + j] ^ value[j]) &
                             (mask ? mask[j] : 255)) == 0) j++;
        if (j == length) return 1;
    }
    return 0;
}

static void require(int condition, const char *description)
{
    if (!condition) {
        fprintf(stderr, "MIME regression: %s (seed=%08x)\n", description, seed);
        exit(1);
    }
}

int main(void)
{
    _Alignas(8) unsigned char storage[256] = {0};
    XdgMimeCache cache = {.size = sizeof(storage), .buffer = (char *)storage};
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    unsigned char *mapping = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    require(mapping != MAP_FAILED, "mmap");
    require(mprotect(mapping + page, page, PROT_NONE) == 0, "guard page");
    for (unsigned trial = 0; trial < 100000; trial++) {
        size_t len = random_word() % 513;
        size_t length = random_word() % 65;
        uint32_t start = random_word() % 550;
        uint32_t count = random_word() % 600;
        int masked = random_word() & 1;
        unsigned char *bytes = mapping + page - len;
        for (size_t i = 0; i < len; i++) bytes[i] = random_word() % 8;
        for (size_t i = 0; i < length; i++) {
            storage[64 + i] = random_word() % 8;
            storage[128 + i] = random_word() & 255;
        }
        if (trial % 3 == 0 && length <= len) {
            size_t at = random_word() % (len - length + 1);
            memcpy(bytes + at, storage + 64, length);
        }
        if (trial % 17 == 0) count = UINT32_MAX;
        if (trial % 19 == 0) start = UINT32_MAX;
        put32(storage, 0, start);
        put32(storage, 4, count);
        put32(storage, 12, (uint32_t)length);
        put32(storage, 16, 64);
        put32(storage, 20, masked ? 128 : 0);
        int expected = reference(bytes, len, storage + 64,
                                 masked ? storage + 128 : NULL, length, start, count);
        require(cache_magic_matchlet_compare_to_data(&cache, 0, bytes, len) == expected,
                "randomized matcher equivalence");
    }
    memset(mapping, 'x', page);
    memcpy(storage + 64, "ABCD", 4);
    put32(storage, 0, 0);
    put32(storage, 4, (uint32_t)page);
    put32(storage, 12, 4);
    put32(storage, 16, 64);
    put32(storage, 20, 0);
    comparisons = 0;
    require(!cache_magic_matchlet_compare_to_data(&cache, 0, mapping, page), "absent value");
    require(comparisons == 0, "absent first byte must not call memcmp per offset");
    memcpy(mapping + page - 4, "ABCD", 4);
    require(cache_magic_matchlet_compare_to_data(&cache, 0, mapping, page), "last legal offset");
    require(comparisons == 1, "only the viable candidate needs memcmp");
    put32(storage, 16, UINT32_MAX);
    require(!cache_magic_matchlet_compare_to_data(&cache, 0, mapping, page), "invalid value offset");
    put32(storage, 16, 64);
    put32(storage, 20, 255);
    require(!cache_magic_matchlet_compare_to_data(&cache, 0, mapping, page), "truncated mask");
    require(!cache_magic_matchlet_compare_to_data(&cache, 1, mapping, page), "unaligned descriptor");
    require(!cache_magic_matchlet_compare_to_data(&cache, 240, mapping, page), "truncated descriptor");
    munmap(mapping, page * 2);
    puts("100000 MIME differential cases, guard-page/bounds and candidate-count checks passed");
    return 0;
}
