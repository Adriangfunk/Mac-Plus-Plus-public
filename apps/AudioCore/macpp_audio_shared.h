#ifndef MACPP_AUDIO_SHARED_H
#define MACPP_AUDIO_SHARED_H

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MACPP_AUDIO_SHARED_NAME "/macpp.audio.v1"
#define MACPP_AUDIO_SHARED_MAGIC UINT32_C(0x52414345)
#define MACPP_AUDIO_SHARED_VERSION UINT32_C(1)
#define MACPP_AUDIO_SHARED_JSON_CAPACITY 16384

typedef struct {
    uint32_t magic;
    uint32_t version;
    _Atomic(uint64_t) sequence;
    _Atomic(uint32_t) length;
    uint32_t reserved;
    unsigned char json[MACPP_AUDIO_SHARED_JSON_CAPACITY];
} MacPlusPlusAudioSharedState;

typedef struct {
    int fd;
    int owner_fd;
    size_t mappingSize;
    MacPlusPlusAudioSharedState *state;
} MacPlusPlusAudioSharedMapping;

_Static_assert(offsetof(MacPlusPlusAudioSharedState, sequence) == 8,
               "audio shared sequence offset must match the Shell reader");
_Static_assert(offsetof(MacPlusPlusAudioSharedState, length) == 16,
               "audio shared length offset must match the Shell reader");
_Static_assert(offsetof(MacPlusPlusAudioSharedState, json) == 24,
               "audio shared JSON offset must match the Shell reader");

static inline bool macpp_audio_shared_open_writer(
    MacPlusPlusAudioSharedMapping *mapping) {
    if (mapping == NULL) return false;
    mapping->fd = -1;
    mapping->owner_fd = -1;
    mapping->mappingSize = sizeof(MacPlusPlusAudioSharedState);
    mapping->state = NULL;

    int fd = shm_open(MACPP_AUDIO_SHARED_NAME, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 && errno == EEXIST) {
        if (shm_unlink(MACPP_AUDIO_SHARED_NAME) != 0 && errno != ENOENT) {
            return false;
        }
        fd = shm_open(MACPP_AUDIO_SHARED_NAME, O_CREAT | O_EXCL | O_RDWR, 0600);
    }
    if (fd < 0) return false;
    if (ftruncate(fd, (off_t)mapping->mappingSize) != 0) {
        close(fd);
        shm_unlink(MACPP_AUDIO_SHARED_NAME);
        return false;
    }

    void *address = mmap(NULL, mapping->mappingSize, PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) {
        close(fd);
        shm_unlink(MACPP_AUDIO_SHARED_NAME);
        return false;
    }

    mapping->fd = fd;
    mapping->state = (MacPlusPlusAudioSharedState *)address;
    mapping->state->magic = MACPP_AUDIO_SHARED_MAGIC;
    mapping->state->version = MACPP_AUDIO_SHARED_VERSION;
    atomic_init(&mapping->state->sequence, 0);
    atomic_init(&mapping->state->length, 0);
    mapping->state->reserved = 0;
    return true;
}

static inline bool macpp_audio_shared_publish(
    MacPlusPlusAudioSharedMapping *mapping,
    const void *json,
    size_t length) {
    if (mapping == NULL || mapping->state == NULL || json == NULL ||
        length == 0 || length > MACPP_AUDIO_SHARED_JSON_CAPACITY) {
        return false;
    }
    MacPlusPlusAudioSharedState *state = mapping->state;
    uint64_t sequence = atomic_load_explicit(&state->sequence,
                                              memory_order_relaxed);
    if (sequence & 1u) sequence++;
    atomic_store_explicit(&state->sequence, sequence + 1,
                          memory_order_release);
    memcpy(state->json, json, length);
    atomic_store_explicit(&state->length, (uint32_t)length,
                          memory_order_relaxed);
    atomic_store_explicit(&state->sequence, sequence + 2,
                          memory_order_release);
    return true;
}

static inline void macpp_audio_shared_close_writer(
    MacPlusPlusAudioSharedMapping *mapping) {
    if (mapping == NULL) return;
    if (mapping->state != NULL) {
        atomic_store_explicit(&mapping->state->length, 0, memory_order_relaxed);
        munmap(mapping->state, mapping->mappingSize);
    }
    if (mapping->fd >= 0) close(mapping->fd);
    if (mapping->owner_fd >= 0 && mapping->owner_fd != mapping->fd) {
        close(mapping->owner_fd);
    }
    shm_unlink(MACPP_AUDIO_SHARED_NAME);
    mapping->fd = -1;
    mapping->owner_fd = -1;
    mapping->mappingSize = 0;
    mapping->state = NULL;
}

#endif
