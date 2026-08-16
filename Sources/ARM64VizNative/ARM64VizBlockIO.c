#include "ARM64VizNative.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

static int64_t avz_block_io_vector(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset,
    int is_write
) {
    if (file_descriptor < 0 || segments == NULL || segment_count == 0 ||
        segment_count > INT_MAX || offset > (uint64_t)INT64_MAX) {
        return -EINVAL;
    }

    struct iovec *vectors = calloc(segment_count, sizeof(*vectors));
    if (vectors == NULL)
        return -ENOMEM;
    size_t total = 0;
    for (size_t index = 0; index < segment_count; index++) {
        if (segments[index].base == NULL || total > (size_t)SSIZE_MAX ||
            segments[index].length > (size_t)SSIZE_MAX - total) {
            free(vectors);
            return -EINVAL;
        }
        vectors[index].iov_base = segments[index].base;
        vectors[index].iov_len = segments[index].length;
        total += segments[index].length;
    }

    size_t completed = 0;
    size_t first = 0;
    off_t position = (off_t)offset;
    while (completed < total) {
        ssize_t result = is_write
            ? pwritev(file_descriptor, vectors + first,
                      (int)(segment_count - first), position)
            : preadv(file_descriptor, vectors + first,
                     (int)(segment_count - first), position);
        if (result < 0) {
            if (errno == EINTR)
                continue;
            int saved_errno = errno;
            free(vectors);
            return -saved_errno;
        }
        if (result == 0) {
            free(vectors);
            return -EIO;
        }

        size_t advanced = (size_t)result;
        completed += advanced;
        position += result;
        while (first < segment_count && advanced >= vectors[first].iov_len) {
            advanced -= vectors[first].iov_len;
            first++;
        }
        if (first < segment_count && advanced != 0) {
            vectors[first].iov_base =
                (unsigned char *)vectors[first].iov_base + advanced;
            vectors[first].iov_len -= advanced;
        }
    }
    free(vectors);
    return (int64_t)completed;
}

int64_t avz_block_io_preadv(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
) {
    return avz_block_io_vector(
        file_descriptor, segments, segment_count, offset, 0);
}

int64_t avz_block_io_pwritev(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
) {
    return avz_block_io_vector(
        file_descriptor, segments, segment_count, offset, 1);
}
