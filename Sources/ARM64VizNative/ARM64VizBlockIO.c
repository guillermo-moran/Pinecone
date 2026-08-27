#include "ARM64VizNative.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

struct AVZFileBlockStorage {
    int file_descriptor;
    size_t size;
    int is_dirty;
    pthread_mutex_t lock;
};

enum {
    AVZ_BLOCK_IO_STACK_VECTOR_COUNT = 64,
};

static int64_t avz_block_io_vector(
    int file_descriptor,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset,
    int is_write
);

static int32_t avz_negative_errno(void) {
    return errno == 0 ? -EIO : -errno;
}

static int avz_file_block_storage_validate_vector(
    const AVZFileBlockStorage *storage,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset,
    size_t *byte_count
) {
    if (storage == NULL || byte_count == NULL ||
        (segment_count != 0 && segments == NULL) ||
        offset > storage->size) {
        return 0;
    }

    size_t total = 0;
    for (size_t index = 0; index < segment_count; index++) {
        if ((segments[index].length != 0 && segments[index].base == NULL) ||
            segments[index].length > SIZE_MAX - total) {
            return 0;
        }
        total += segments[index].length;
    }
    if (total > storage->size - (size_t)offset)
        return 0;
    *byte_count = total;
    return 1;
}

AVZFileBlockStorage *avz_file_block_storage_open(
    const char *path,
    int32_t *error_code
) {
    if (error_code != NULL)
        *error_code = 0;
    if (path == NULL || path[0] == '\0') {
        if (error_code != NULL)
            *error_code = EINVAL;
        return NULL;
    }

    int descriptor = open(path, O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        if (error_code != NULL)
            *error_code = errno;
        return NULL;
    }

    struct stat status;
    if (fstat(descriptor, &status) != 0 || status.st_size <= 0 ||
        (uint64_t)status.st_size > SIZE_MAX) {
        const int saved_errno = errno == 0 ? EINVAL : errno;
        close(descriptor);
        if (error_code != NULL)
            *error_code = saved_errno;
        return NULL;
    }

    AVZFileBlockStorage *storage = calloc(1, sizeof(*storage));
    if (storage == NULL) {
        const int saved_errno = errno == 0 ? ENOMEM : errno;
        close(descriptor);
        if (error_code != NULL)
            *error_code = saved_errno;
        return NULL;
    }
    const int lock_result = pthread_mutex_init(&storage->lock, NULL);
    if (lock_result != 0) {
        free(storage);
        close(descriptor);
        if (error_code != NULL)
            *error_code = lock_result;
        return NULL;
    }

    storage->file_descriptor = descriptor;
    storage->size = (size_t)status.st_size;
    return storage;
}

void avz_file_block_storage_close(AVZFileBlockStorage *storage) {
    if (storage == NULL)
        return;
    pthread_mutex_lock(&storage->lock);
    if (storage->is_dirty)
        (void)fsync(storage->file_descriptor);
    const int descriptor = storage->file_descriptor;
    storage->file_descriptor = -1;
    storage->size = 0;
    pthread_mutex_unlock(&storage->lock);
    pthread_mutex_destroy(&storage->lock);
    close(descriptor);
    free(storage);
}

uint64_t avz_file_block_storage_size(
    const AVZFileBlockStorage *storage
) {
    return storage == NULL ? 0 : storage->size;
}

int64_t avz_file_block_storage_readv(
    AVZFileBlockStorage *storage,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
) {
    size_t byte_count = 0;
    if (!avz_file_block_storage_validate_vector(
            storage, segments, segment_count, offset, &byte_count)) {
        return -EINVAL;
    }
    if (byte_count == 0)
        return 0;

    const int lock_result = pthread_mutex_lock(&storage->lock);
    if (lock_result != 0)
        return -lock_result;
    const int64_t result = avz_block_io_vector(
        storage->file_descriptor,
        segments,
        segment_count,
        offset,
        0
    );
    pthread_mutex_unlock(&storage->lock);
    return result;
}

int64_t avz_file_block_storage_writev(
    AVZFileBlockStorage *storage,
    const AVZBlockIOSegment *segments,
    size_t segment_count,
    uint64_t offset
) {
    size_t byte_count = 0;
    if (!avz_file_block_storage_validate_vector(
            storage, segments, segment_count, offset, &byte_count)) {
        return -EINVAL;
    }
    if (byte_count == 0)
        return 0;

    const int lock_result = pthread_mutex_lock(&storage->lock);
    if (lock_result != 0)
        return -lock_result;
    const int64_t result = avz_block_io_vector(
        storage->file_descriptor,
        segments,
        segment_count,
        offset,
        1
    );
    if (result == (int64_t)byte_count)
        storage->is_dirty = 1;
    pthread_mutex_unlock(&storage->lock);
    return result;
}

int32_t avz_file_block_storage_zero(
    AVZFileBlockStorage *storage,
    uint64_t offset,
    uint64_t byte_count
) {
    if (storage == NULL || offset > storage->size ||
        byte_count > SIZE_MAX ||
        (size_t)byte_count > storage->size - (size_t)offset) {
        return -EINVAL;
    }
    if (byte_count == 0)
        return 0;

    const int lock_result = pthread_mutex_lock(&storage->lock);
    if (lock_result != 0)
        return -lock_result;

    static const unsigned char zeroes[64u * 1024u] = {0};
    size_t completed = 0;
    const size_t total = (size_t)byte_count;
    while (completed < total) {
        const size_t chunk = total - completed < sizeof(zeroes)
            ? total - completed : sizeof(zeroes);
        const ssize_t result = pwrite(
            storage->file_descriptor,
            zeroes,
            chunk,
            (off_t)(offset + completed)
        );
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0) {
            const int32_t error = result == 0 ? -EIO : avz_negative_errno();
            pthread_mutex_unlock(&storage->lock);
            return error;
        }
        completed += (size_t)result;
    }
    storage->is_dirty = 1;
    pthread_mutex_unlock(&storage->lock);
    return 0;
}

int32_t avz_file_block_storage_flush(AVZFileBlockStorage *storage) {
    if (storage == NULL)
        return -EINVAL;
    const int lock_result = pthread_mutex_lock(&storage->lock);
    if (lock_result != 0)
        return -lock_result;

    if (!storage->is_dirty) {
        pthread_mutex_unlock(&storage->lock);
        return 0;
    }

    const int32_t result = fsync(storage->file_descriptor) == 0
        ? 0 : avz_negative_errno();
    if (result == 0)
        storage->is_dirty = 0;
    pthread_mutex_unlock(&storage->lock);
    return result;
}

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

    struct iovec stack_vectors[AVZ_BLOCK_IO_STACK_VECTOR_COUNT];
    struct iovec *vectors = stack_vectors;
    if (segment_count > AVZ_BLOCK_IO_STACK_VECTOR_COUNT) {
        vectors = calloc(segment_count, sizeof(*vectors));
        if (vectors == NULL)
            return -ENOMEM;
    }
    const int vectors_are_heap_allocated = vectors != stack_vectors;
    size_t total = 0;
    for (size_t index = 0; index < segment_count; index++) {
        if (segments[index].base == NULL || total > (size_t)SSIZE_MAX ||
            segments[index].length > (size_t)SSIZE_MAX - total) {
            if (vectors_are_heap_allocated)
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
            if (vectors_are_heap_allocated)
                free(vectors);
            return -saved_errno;
        }
        if (result == 0) {
            if (vectors_are_heap_allocated)
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
    if (vectors_are_heap_allocated)
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
