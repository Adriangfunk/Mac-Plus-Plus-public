#include <fcntl.h>
#include <sys/mman.h>

// Swift cannot import macOS's variadic shm_open declaration.  Keep this
// three-argument shim in C; the shared-memory reader itself remains in Swift.
int macpp_audio_shared_open_reader(const char *name) {
    return shm_open(name, O_RDONLY, 0);
}
