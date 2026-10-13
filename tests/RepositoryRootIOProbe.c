#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <sys/file.h>
#include <assert.h>
#include <dirent.h>
#include <stdio.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
static int probe_kqueue(void);
#define kqueue probe_kqueue
#elif defined(__linux__)
#include <sys/inotify.h>
static int probe_inotify_init1(int flags);
#define inotify_init1 probe_inotify_init1
#endif

static int probe_flock(int fd, int operation);
static int probe_close(int fd);
#define flock probe_flock
#define close probe_close
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#undef flock
#undef close
#if defined(__APPLE__)
#undef kqueue
#elif defined(__linux__)
#undef inotify_init1
#endif

static int unsupported_events;
static int retained_directory = -1, retained_events = -1;
static int directory_closes, event_closes;
static int probe_close(int fd) {
    if (fd == retained_directory) directory_closes++;
    if (fd == retained_events) event_closes++;
    return close(fd);
}
#if defined(__APPLE__)
static int probe_kqueue(void) {
    if (unsupported_events) { errno = EMFILE; return -1; }
    return kqueue();
}
#elif defined(__linux__)
static int probe_inotify_init1(int flags) {
    if (unsupported_events) { errno = EMFILE; return -1; }
    return inotify_init1(flags);
}
#endif

/* Failure injection changes the native lock result beneath the production acquisition path. */
static int unsupported_lock;
static int probe_flock(int fd, int operation) {
    if (unsupported_lock) { errno = ENOTSUP; return -1; }
    return flock(fd, operation);
}

static size_t descriptor_count(void) {
#if defined(__linux__)
    DIR *entries = opendir("/proc/self/fd");
#else
    DIR *entries = opendir("/dev/fd");
#endif
    assert(entries);
    size_t count = 0;
    while (readdir(entries)) count++;
    assert(closedir(entries) == 0);
    return count;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *path = argv[1];
    assert(mkdir(path, 0700) == 0);
    int directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    assert(directory >= 0);
    int file = openat(directory, "note.txt", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    assert(file >= 0 && write(file, "note", 4) == 4 && close(file) == 0);
    assert(close(directory) == 0);
    size_t baseline = descriptor_count();
    for (int i = 0; i < 64; i++) {
        unsupported_lock = 1;
        assert(!nv_root_open(path) && errno == ENOTSUP);
        unsupported_lock = 0;
        unsupported_events = 1;
        assert(!nv_root_open(path) && errno == EMFILE);
        unsupported_events = 0;
        assert(descriptor_count() == baseline);
        NVRootOwner *root = nv_root_open(path);
        assert(root && nv_root_validate(root) == 0);
        uint64_t identity[2];
        struct stat own;
        assert(nv_root_identity(root, identity) == 0 && fstat(root->directory, &own) == 0);
        assert(identity[0] == (uint64_t)own.st_dev && identity[1] == (uint64_t)own.st_ino);
        assert(!nv_root_create(path) && errno == EEXIST);
        assert(!nv_root_open(path) && errno == EWOULDBLOCK);
        retained_directory = root->directory; retained_events = root->events;
        directory_closes = 0; event_closes = 0;
        for (int n = 0; n < 64; n++) {
            uint64_t words[5];
            assert(nv_root_observe(root, "note.txt", words) == 0 && words[0] == 1 && words[3] == 4);
            assert(nv_root_observe(root, "../note.txt", words) == -1 && errno == EINVAL);
            assert(nv_root_observe(root, "missing/note.txt", words) == -1 && errno == ENOENT);
        }
        assert(nv_root_compare(root, path) == 1);
        nv_root_close(root);
        assert(directory_closes == 1 && event_closes == 1);
        retained_directory = -1; retained_events = -1;
        assert(descriptor_count() == baseline);
    }
    char fresh[1024];
    assert(snprintf(fresh, sizeof(fresh), "%s-fresh", path) > 0);
    NVRootOwner *created = nv_root_create(fresh);
    assert(created && nv_root_validate(created) == 0);
    assert(!nv_root_create(fresh) && errno == EEXIST);
    assert(!nv_root_open(fresh) && errno == EWOULDBLOCK);
    nv_root_close(created);
    assert(descriptor_count() == baseline);
    puts("PASS: production root allocation/failure/borrow/release loops and descriptor baseline");
    return 0;
}
