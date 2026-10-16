/* Exercises the production descriptor reader at actual native read boundaries. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

static const char *event_target;
static int fault, root_fd, read_fault;
static void write_leaf(const char *leaf, const char *body) {
    int fd = openat(root_fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    assert(fd >= 0); size_t length = strlen(body);
    assert(write(fd, body, length) == (ssize_t)length); assert(close(fd) == 0);
}
static void attribute(int fd, const char *name, const char *value) {
#if defined(__APPLE__)
    assert(fsetxattr(fd, name, value, strlen(value), 0, 0) == 0);
#else
    char actual[256]; assert(snprintf(actual, sizeof(actual), "user.%s", name) > 0);
    assert(fsetxattr(fd, actual, value, strlen(value), 0) == 0);
#endif
}
static void read_event(const char *name, int fd) {
    if (!event_target || strcmp(name, event_target)) return;
    event_target = NULL;
    if (fault == 1) {
        assert(renameat(root_fd, "note.txt", root_fd, "saved.txt") == 0);
        write_leaf("note.txt", "changed");
    } else if (fault == 2) attribute(fd, "com.apple.TextEncoding", "changed");
    else if (fault == 3) { assert(fchmod(fd, 0644) == 0); }
}
static ssize_t read_faults(int fd, void *bytes, size_t count, off_t offset) {
    if (read_fault == 1) { errno = EIO; return -1; }
    if (read_fault == 2) return 0;
    if (read_fault == 3) { read_fault = 4; errno = EINTR; return -1; }
    if (read_fault == 4 && count > 1) count = 1;
    return pread(fd, bytes, count, offset);
}
static int read_openat(int directory, const char *name, int flags, ...) {
    if (read_fault == 5) { errno = EMFILE; return -1; }
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args; va_start(args, flags); mode = (mode_t)va_arg(args, int); va_end(args);
    }
    return openat(directory, name, flags, mode);
}
#define pread read_faults
#define openat read_openat
#define NV_PROJECTION_EVENT(name, fd) read_event(name, fd)
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef pread
#undef openat

#ifndef NV_PROJECTION_RETAIN_READ
#define NV_PROJECTION_RETAIN_READ 0
#endif

static int open_files(void) {
    DIR *directory = opendir("/dev/fd"); assert(directory);
    int count = 0; struct dirent *entry;
    while ((entry = readdir(directory))) if (entry->d_name[0] != '.') count++;
    assert(closedir(directory) == 0); return count;
}

/* Independently checks transfer, failure cleanup and caller-owned closure. */
static int read_projection(NVRootOwner *owner, const char *name, const uint64_t words[9],
    uint64_t maximum, NVProjectionRead **output) {
    int before = open_files(), descriptor = 12345;
    int result = NV_PROJECTION_RETAIN_READ ?
        nv_projection_read_retaining(owner, name, words, maximum, output, &descriptor) :
        nv_projection_read(owner, name, words, maximum, output);
    int saved = errno;
    if (NV_PROJECTION_RETAIN_READ) {
        if (result == 0) {
            struct stat st; assert(fstat(descriptor, &st) == 0);
            assert((uint64_t)st.st_dev == (*output)->words[1] && (uint64_t)st.st_ino == (*output)->words[2]);
            assert(fcntl(descriptor, F_GETFD) & FD_CLOEXEC);
            assert(open_files() == before + 1);
            assert(close(descriptor) == 0);
            assert(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);
        } else assert(descriptor == -1);
    }
    assert(open_files() == before);
    errno = saved; return result;
}

static unsigned checks;
static NVProjectionRead *read_note(NVRootOwner *owner, int expected_result, int expected_error) {
    uint64_t words[9]; assert(nv_root_snapshot(owner, "note.txt", words) == 0);
    NVProjectionRead *read = NULL;
    int result = read_projection(owner, "note.txt", words, 1024, &read);
    assert(result == expected_result);
    if (result < 0) { assert(errno == expected_error); assert(read == NULL); }
    else assert(read != NULL);
    checks++; return read;
}
int main(int argc, char **argv) {
    assert(argc == 2); assert(mkdir(argv[1], 0700) == 0);
    NVRootOwner *owner = nv_root_open(argv[1]); assert(owner); root_fd = owner->directory;
    write_leaf("note.txt", "original");
    int fd = openat(root_fd, "note.txt", O_RDONLY | O_CLOEXEC); assert(fd >= 0);
    attribute(fd, "com.apple.TextEncoding", "UTF-8;134217984");
    attribute(fd, "com.apple.metadata:kMDItemOMUserTags", "");
    attribute(fd, "org.notationalvelocity.projection#S", "stamp");
    assert(close(fd) == 0);
    NVProjectionRead *read = read_note(owner, 0, 0);
    assert(read->count == 8 && !memcmp(read->bytes, "original", 8));
    assert(read->encoding.state == 1 && read->encoding.count == 15);
    assert(read->tags.state == 1 && read->tags.count == 0);
    assert(read->finder_tags.state == 0);
    assert(read->stamp.state == 1 && !memcmp(read->stamp.bytes, "stamp", 5));
    assert(read->permissions == 0600); nv_projection_read_close(read);
    read_fault = 3; read = read_note(owner, 0, 0);
    assert(read->count == 8 && !memcmp(read->bytes, "original", 8)); nv_projection_read_close(read);
    read_fault = 1; read_note(owner, -1, EIO);
    read_fault = 2; read_note(owner, -1, ESTALE); read_fault = 0;
    read_fault = 5; read_note(owner, -1, EMFILE); read_fault = 0;
    fault = 2; event_target = "body-read"; read_note(owner, -1, ESTALE);
    fault = 3; event_target = "metadata-read"; read_note(owner, -1, ESTALE);
    fault = 1; event_target = "before-name-check"; read_note(owner, -1, ESTALE);
    read = read_note(owner, 0, 0); assert(!memcmp(read->bytes, "changed", 7)); nv_projection_read_close(read);
    uint64_t words[9]; assert(nv_root_snapshot(owner, "note.txt", words) == 0);
    assert(renameat(root_fd, "note.txt", root_fd, "newer.txt") == 0);
    write_leaf("note.txt", "");
    assert(read_projection(owner, "note.txt", words, 1024, &read) == -1 && errno == ESTALE && !read); checks++;
    read = read_note(owner, 0, 0); assert(read->count == 0); nv_projection_read_close(read);
    assert(linkat(root_fd, "note.txt", root_fd, "hard.txt", 0) == 0);
    read_note(owner, -1, EMLINK);
    assert(renameat(root_fd, "note.txt", root_fd, "empty.txt") == 0);
    assert(symlinkat("saved.txt", root_fd, "note.txt") == 0);
    read_note(owner, -1, ENOTDIR);
    assert(read_projection(owner, "../outside", words, 1024, &read) == -1 && errno == EINVAL && !read); checks++;
    assert(read_projection(owner, "saved.txt", words, UINT64_MAX, &read) == -1 && errno == EFBIG && !read); checks++;
    nv_root_close(owner);
    printf("PASS: projection coherent read %u native assertions/cases\n", checks);
    return 0;
}
