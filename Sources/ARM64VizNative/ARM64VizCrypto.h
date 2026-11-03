#ifndef ARM64VIZ_CRYPTO_H
#define ARM64VIZ_CRYPTO_H
#include <stdint.h>
#include <string.h>
#if defined(__aarch64__) && defined(__ARM_FEATURE_SHA2)
#include <arm_neon.h>
#endif

static inline uint32_t avz_sha_rotr(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}
static inline uint32_t avz_sha_sigma0(uint32_t x) {
    return avz_sha_rotr(x, 7) ^ avz_sha_rotr(x, 18) ^ (x >> 3);
}
static inline uint32_t avz_sha_sigma1(uint32_t x) {
    return avz_sha_rotr(x, 17) ^ avz_sha_rotr(x, 19) ^ (x >> 10);
}

// mode: SHA256H, SHA256H2, SHA256SU0, SHA256SU1. Copy sources before
// writing the destination; architectural vector registers may alias.
static inline void avz_sha256_portable(uint32_t dst[4], const uint32_t n[4],
                                        const uint32_t m[4], unsigned mode) {
    uint32_t d[4], a[4], b[4], out[4];
    memcpy(d, dst, 16); memcpy(a, n, 16); memcpy(b, m, 16);
    if (mode == 2) {
        out[0] = d[0] + avz_sha_sigma0(d[1]);
        out[1] = d[1] + avz_sha_sigma0(d[2]);
        out[2] = d[2] + avz_sha_sigma0(d[3]);
        out[3] = d[3] + avz_sha_sigma0(a[0]);
    } else if (mode == 3) {
        out[0] = d[0] + a[1] + avz_sha_sigma1(b[2]);
        out[1] = d[1] + a[2] + avz_sha_sigma1(b[3]);
        out[2] = d[2] + a[3] + avz_sha_sigma1(out[0]);
        out[3] = d[3] + b[0] + avz_sha_sigma1(out[1]);
    } else {
        uint32_t abcd[4], efgh[4];
        memcpy(abcd, mode == 0 ? d : a, 16);
        memcpy(efgh, mode == 0 ? a : d, 16);
        for (unsigned i = 0; i < 4; ++i) {
            uint32_t x = abcd[0], e = efgh[0];
            uint32_t big0 = avz_sha_rotr(x, 2) ^ avz_sha_rotr(x, 13) ^ avz_sha_rotr(x, 22);
            uint32_t big1 = avz_sha_rotr(e, 6) ^ avz_sha_rotr(e, 11) ^ avz_sha_rotr(e, 25);
            uint32_t ch = (e & efgh[1]) ^ (~e & efgh[2]);
            uint32_t maj = (x & abcd[1]) ^ (x & abcd[2]) ^ (abcd[1] & abcd[2]);
            uint32_t t = efgh[3] + big1 + ch + b[i];
            uint32_t nextE = abcd[3] + t, nextA = t + big0 + maj;
            for (unsigned j = 3; j > 0; --j) {
                abcd[j] = abcd[j - 1]; efgh[j] = efgh[j - 1];
            }
            abcd[0] = nextA; efgh[0] = nextE;
        }
        memcpy(out, mode == 0 ? abcd : efgh, 16);
    }
    memcpy(dst, out, 16);
}

static inline void avz_sha256(uint32_t dst[4], const uint32_t n[4],
                               const uint32_t m[4], unsigned mode) {
#if defined(__aarch64__) && defined(__ARM_FEATURE_SHA2) && !defined(AVZ_FORCE_PORTABLE_CRYPTO)
    uint32x4_t d, a, b, result;
    memcpy(&d, dst, 16); memcpy(&a, n, 16); memcpy(&b, m, 16);
    switch (mode) {
    case 0: result = vsha256hq_u32(d, a, b); break;
    case 1: result = vsha256h2q_u32(d, a, b); break;
    case 2: result = vsha256su0q_u32(d, a); break;
    default: result = vsha256su1q_u32(d, a, b); break;
    }
    memcpy(dst, &result, 16);
#else
    avz_sha256_portable(dst, n, m, mode);
#endif
}
#endif
