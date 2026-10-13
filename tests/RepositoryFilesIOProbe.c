#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

static ssize_t test_write(int fd, const void *bytes, size_t count);
static ssize_t test_pread(int fd, void *bytes, size_t count, off_t offset);
static int test_fsync(int fd);
static int test_mkdirat(int fd, const char *name, mode_t mode);
static int test_unlinkat(int fd, const char *name, int flags);
static int test_fcntl(int fd, int command, ...);
#if defined(__APPLE__)
static int test_renameatx_np(int source, const char *old, int destination, const char *new, unsigned flags);
#else
static int test_renameat2(int source, const char *old, int destination, const char *new, unsigned flags);
#endif
static void test_event(const char *name, int fd);

#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#define write test_write
#define pread test_pread
#define fsync test_fsync
#define mkdirat test_mkdirat
#define unlinkat test_unlinkat
#define fcntl test_fcntl
#if defined(__APPLE__)
#define renameatx_np test_renameatx_np
#else
#define renameat2 test_renameat2
#endif
#define NV_REPOSITORY_EVENT(name, fd) test_event(name, fd)
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"
#undef write
#undef pread
#undef fsync
#undef mkdirat
#undef unlinkat
#undef fcntl
#if defined(__APPLE__)
#undef renameatx_np
#else
#undef renameat2
#endif

static int trace_events, fault_at, fault_count, fault_code;
static const char *fault_name = "";

static int descriptor_count(void) {
#if defined(__linux__)
    DIR *stream = opendir("/proc/self/fd");
#else
    DIR *stream = opendir("/dev/fd");
#endif
    if (!stream) abort();
    int count = 0;
    while (readdir(stream)) count++;
    if (closedir(stream)) abort();
    return count;
}

/* Every gate follows the native effect and reports independently observable descriptor identity. */
static void test_event(const char *name, int fd) {
    if (!trace_events) return;
    struct stat st;
    if (fstat(fd, &st)) abort();
    printf("{\"event\":\"%s\",\"device\":%llu,\"inode\":%llu,\"directory\":%d,\"size\":%llu}\n",
           name, (unsigned long long)st.st_dev, (unsigned long long)st.st_ino, S_ISDIR(st.st_mode) ? 1 : 0,
           (unsigned long long)st.st_size);
    fflush(stdout);
    if (getchar() != '\n') _exit(93);
}

static int fault(const char *name) {
    if (strcmp(fault_name, name)) return 0;
    fault_count++;
    if (fault_at >= 0 && fault_count != fault_at) return 0;
    errno = fault_code; return 1;
}
static ssize_t test_write(int fd, const void *bytes, size_t count) {
    if (fault("write")) return -1;
    if (fault("write-zero")) return 0;
    if (fault("write-short") && count > 1) count /= 2;
    ssize_t result = write(fd, bytes, count);
    if (result >= 0) test_event("native-write", fd);
    return result;
}
static ssize_t test_pread(int fd, void *bytes, size_t count, off_t offset) {
    if (fault("pread")) return -1;
    if (fault("pread-zero")) return 0;
    if (fault("pread-short") && count > 1) count /= 2;
    return pread(fd, bytes, count, offset);
}
static int test_fsync(int fd) {
    if (fault("fsync")) return -1;
    int result = fsync(fd);
    if (!result) test_event("native-fsync", fd);
    return result;
}
static int test_fcntl(int fd, int command, ...) {
#if defined(__APPLE__)
    if (command == F_FULLFSYNC) {
        if (fault("fullfsync")) return -1;
        int result = fcntl(fd, command);
        if (!result) test_event("native-fullfsync", fd);
        return result;
    }
#endif
    va_list args; va_start(args, command);
    int argument = va_arg(args, int); va_end(args);
    return fcntl(fd, command, argument);
}
static int test_mkdirat(int fd, const char *name, mode_t mode) {
    if (fault("mkdir")) return -1;
    return mkdirat(fd, name, mode);
}
static int test_unlinkat(int fd, const char *name, int flags) {
    if (fault("cleanup")) return -1;
    return unlinkat(fd, name, flags);
}
static int do_rename(int source, const char *old, int destination, const char *new, unsigned flags) {
    if (fault("rename")) return -1;
    int result;
#if defined(__APPLE__)
    result = renameatx_np(source, old, destination, new, flags);
#else
    result = renameat2(source, old, destination, new, flags);
#endif
    int saved = errno;
    test_event(result ? "native-rename-failed" : "native-rename-succeeded", destination);
    errno = saved;
    if (!result && fault("rename-lost-return")) return -1;
    return result;
}
#if defined(__APPLE__)
static int test_renameatx_np(int source, const char *old, int destination, const char *new, unsigned flags) {
    return do_rename(source, old, destination, new, flags);
}
#else
static int test_renameat2(int source, const char *old, int destination, const char *new, unsigned flags) {
    return do_rename(source, old, destination, new, flags);
}
#endif

int main(int argc, char **argv) {
    if (argc != 9) return 94;
    NVRootOwner *owner = nv_root_open(argv[1]);
    if (!owner) { printf("{\"open_error\":%d}\n", errno); return 95; }
    FILE *input = fopen(argv[2], "rb");
    if (!input || fseek(input, 0, SEEK_END)) return 96;
    long size = ftell(input);
    if (size < 0 || (uint64_t)size > NV_PROTOCOL_BYTES || fseek(input, 0, SEEK_SET)) return 97;
    uint8_t *bytes = malloc((size_t)size + 1);
    if (!bytes || fread(bytes, 1, (size_t)size, input) != (size_t)size) return 98;
    if (fclose(input)) return 99;
    int descriptors = descriptor_count();
    trace_events = !strcmp(argv[4], "trace") || !strcmp(argv[4], "read-trace") || !strcmp(argv[4], "split-trace"); fault_name = argv[5]; fault_at = atoi(argv[6]); fault_code = atoi(argv[7]);
    if (!strncmp(argv[4], "read", 4)) {
        uint64_t words[9];
        int status = nv_root_snapshot(owner, argv[3], words), error = errno;
        if (!status) {
            test_event("snapshot-captured", owner->directory);
            if (words[3] > (uint64_t)size) { status = -1; error = EFBIG; }
            else { status = nv_root_read(owner, argv[3], words, bytes, words[3]); error = errno; }
        }
        printf("{\"read_status\":%d,\"error\":%d,\"hex\":\"", status, status ? error : 0);
        if (!status) for (uint64_t i = 0; i < words[3]; i++) printf("%02x", bytes[i]);
        printf("\",\"fault_count\":%d,\"descriptor_delta\":%d}\n", fault_count, descriptor_count()-descriptors); fflush(stdout);
        free(bytes); nv_root_close(owner); return 0;
    }
    NVRootInstallResult result;
    if (!strncmp(argv[4], "split", 5)) {
        char *relative = strdup(argv[3]);
        if (!relative) return 99;
        int changed = 0;
        for (char *p = relative; *p; p++) if (*p == '/') {
            *p = 0; nv_root_make_directory(owner, relative, &result); *p = '/';
            changed = changed || result.namespace_changed;
            if (result.outcome != NV_ROOT_INSTALL_VERIFIED) goto split_done;
        }
        NVRootPreparedStage *stage = nv_root_prepare_owned_stage(owner, argv[8], bytes, (uint64_t)size, &result);
        if (result.outcome == NV_ROOT_INSTALL_VERIFIED) {
            test_event("stage-prepared", owner->directory);
            nv_root_install_owned_stage(owner, argv[3], stage, bytes, (uint64_t)size, &result);
        }
        nv_root_prepared_stage_close(stage);
split_done:
        if (changed) {
            result.namespace_changed = 1;
            if (result.outcome == NV_ROOT_INSTALL_NO_EFFECT) result.outcome = NV_ROOT_INSTALL_UNCERTAIN;
        }
        free(relative);
    } else { nv_root_install(owner, argv[3], argv[8], bytes, (uint64_t)size, &result); }
    printf("{\"outcome\":%d,\"error\":%d,\"existing\":%d,\"namespace_changed\":%d,\"stage_retained\":%d,\"cleanup_error\":%d,\"fault_count\":%d,\"descriptor_delta\":%d}\n",
           result.outcome, result.error, result.existing, result.namespace_changed, result.stage_retained, result.cleanup_error, fault_count, descriptor_count()-descriptors);
    fflush(stdout);
    free(bytes); nv_root_close(owner);
    return 0;
}
