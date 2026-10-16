/* Injects process exits or EIO at protected-directory synchronization in one owned test root. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#if defined(__linux__)
#include <dlfcn.h>
#endif

static atomic_uint protected_syncs;

static int OriginalSync(int descriptor) {
#if defined(__APPLE__)
    return fsync(descriptor);
#else
    void *address = dlsym(RTLD_NEXT, "fsync");
    int (*operation)(int) = NULL;
    _Static_assert(sizeof(operation) == sizeof(address), "POSIX dynamic symbol representation");
    memcpy(&operation, &address, sizeof(operation));
    if (!operation) _exit(93);
    return operation(descriptor);
#endif
}

static int ProtectedDescriptor(int descriptor) {
    const char *root = getenv("NV_P62_SOURCE_REPOSITORY");
    if (!root) return 0;
    struct stat state;
    if (fstat(descriptor, &state) || !S_ISDIR(state.st_mode)) return 0;
    char actual[PATH_MAX], canonical[PATH_MAX];
#if defined(__APPLE__)
    if (fcntl(descriptor, F_GETPATH, actual)) return 0;
#else
    char link[64];
    int written = snprintf(link, sizeof(link), "/proc/self/fd/%d", descriptor);
    if (written < 0 || (size_t)written >= sizeof(link)) _exit(93);
    ssize_t count = readlink(link, actual, sizeof(actual) - 1);
    if (count < 0 || (size_t)count >= sizeof(actual) - 1) return 0;
    actual[count] = '\0';
#endif
    if (!realpath(root, canonical)) return 0;
    size_t prefix = strlen(canonical);
    if (strncmp(actual, canonical, prefix) || actual[prefix] != '/') return 0;
    const char *leaf = actual + prefix + 1;
    size_t size = strlen(leaf), ending = strlen(".backup.cleanup");
    return !strchr(leaf, '/') && !strncmp(leaf, ".nv-source-", strlen(".nv-source-")) &&
        size > ending && !strcmp(leaf + size - ending, ".backup.cleanup");
}

static int ControlledSync(int descriptor) {
    const char *mode = getenv("NV_P62_SOURCE_MODE");
    if (!mode || strncmp(mode, "native-", strlen("native-")) || !ProtectedDescriptor(descriptor)) {
        return OriginalSync(descriptor);
    }
    unsigned turn = atomic_fetch_add_explicit(&protected_syncs, 1, memory_order_relaxed) + 1;
    if (!strcmp(mode, "native-sync-failure")) { errno = EIO; return -1; }
    int result = OriginalSync(descriptor);
    if (result) return result;
    if ((!strcmp(mode, "native-before-capture") && turn == 1) ||
        (!strcmp(mode, "native-captured") && turn == 2) ||
        (!strcmp(mode, "native-unlinked") && turn == 3)) _exit(86);
    return result;
}

#if defined(__APPLE__)
__attribute__((used, section("__DATA,__interpose")))
static const struct {
    int (*replacement)(int);
    int (*original)(int);
} sync_interposition = {ControlledSync, fsync};
#else
int fsync(int descriptor) { return ControlledSync(descriptor); }
#endif
