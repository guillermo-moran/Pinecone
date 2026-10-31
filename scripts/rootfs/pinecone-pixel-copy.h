#ifndef PINECONE_PIXEL_COPY_H
#define PINECONE_PIXEL_COPY_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Callers validate non-overlapping allocations and row extents. Never copy
 * padding: a full-width, tightly packed rectangle is the only bulk case. */
static inline size_t pinecone_copy_pixel_rows(void *destination, size_t pitch,
    const void *source, size_t stride, size_t row_bytes, size_t rows)
{
    if (!row_bytes || !rows) return 0;
    if (pitch == row_bytes && stride == row_bytes && rows <= SIZE_MAX / row_bytes) {
        memcpy(destination, source, row_bytes * rows);
        return 1;
    }
    for (size_t row = 0; row < rows; ++row)
        memcpy((uint8_t *)destination + row * pitch,
            (const uint8_t *)source + row * stride, row_bytes);
    return rows;
}

#endif
