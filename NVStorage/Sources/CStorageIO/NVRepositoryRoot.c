#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "NVRepositoryRoot.h"
#include "NVRepositoryRootInternal.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <sys/inotify.h>
#endif

/* Watches the retained directory object for loss of access or namespace membership. */
static int root_events_open(int directory) {
#if defined(__APPLE__)
    int events = kqueue();
    if (events < 0) return -1;
    struct kevent change;
    EV_SET(&change, (uintptr_t)directory, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_DELETE | NOTE_REVOKE, 0, NULL);
    if (fcntl(events, F_SETFD, FD_CLOEXEC) || kevent(events, &change, 1, NULL, 0, NULL)) {
        int saved = errno; close(events); errno = saved; return -1;
    }
    return events;
#elif defined(__linux__)
    int events = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (events < 0) return -1;
    char reference[64];
    int count = snprintf(reference, sizeof(reference), "/proc/self/fd/%d", directory);
    if (count < 0 || (size_t)count >= sizeof(reference)) {
        close(events); errno = EOVERFLOW; return -1;
    }
    if (inotify_add_watch(events, reference, IN_DELETE_SELF | IN_UNMOUNT) < 0) {
        int saved = errno; close(events); errno = saved; return -1;
    }
    return events;
#else
    (void)directory; errno = ENOTSUP; return -1;
#endif
}

/* Polls once per rooted turn and retains delivered loss evidence through later retries. */
static int root_events_check(NVRootOwner *owner) {
    if (owner->invalidated) { errno = ESTALE; return -1; }
#if defined(__APPLE__)
    struct kevent event;
    const struct timespec immediate = {0, 0};
    int count = kevent(owner->events, NULL, 0, &event, 1, &immediate);
    if (count < 0) return -1;
    if (count && ((event.flags & EV_ERROR) || (event.fflags & (NOTE_DELETE | NOTE_REVOKE)))) {
        owner->invalidated = 1; errno = ESTALE; return -1;
    }
#elif defined(__linux__)
    union { struct inotify_event alignment; char bytes[4096]; } buffer;
    ssize_t count = read(owner->events, buffer.bytes, sizeof(buffer.bytes));
    if (count < 0) { if (errno == EAGAIN) return 0; return -1; }
    size_t offset = 0;
    while (offset < (size_t)count) {
        if ((size_t)count - offset < sizeof(struct inotify_event)) { errno = EIO; return -1; }
        struct inotify_event event;
        memcpy(&event, buffer.bytes + offset, sizeof(event));
        if (event.len > (size_t)count - offset - sizeof(event)) { errno = EIO; return -1; }
        if (event.mask & (IN_DELETE_SELF | IN_UNMOUNT | IN_IGNORED | IN_Q_OVERFLOW)) {
            owner->invalidated = 1; errno = ESTALE; return -1;
        }
        offset += sizeof(event) + event.len;
    }
#else
    errno = ENOTSUP; return -1;
#endif
    return 0;
}

/* Normalizes the final component so trailing slashes retain no-follow semantics. */
static char *candidate_path(const char *path) {
    char *copy = strdup(path);
    if (!copy) return NULL;
    size_t count = strlen(copy);
    while (count > 1 && copy[count - 1] == '/') copy[--count] = 0;
    return copy;
}

/* Resolves selection components individually, preserving descriptor-relative long-path access. */
static int candidate_parent(const char *path, char **leaf) {
    char *copy = candidate_path(path);
    if (!copy) return -1;
    int fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { int saved = errno; free(copy); errno = saved; return -1; }
    char *component = copy + (path[0] == '/'), *slash;
    while ((slash = strchr(component, '/'))) {
        *slash = 0;
        if (component[0]) {
            if (!strcmp(component, ".") || !strcmp(component, "..")) {
                close(fd); free(copy); errno = EINVAL; return -1;
            }
            int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (next < 0) { int saved = errno; close(fd); free(copy); errno = saved; return -1; }
            close(fd); fd = next;
        }
        component = slash + 1;
    }
    if (!strcmp(component, ".") || !strcmp(component, "..")) {
        close(fd); free(copy); errno = EINVAL; return -1;
    }
    *leaf = strdup(component[0] ? component : ".");
    int saved = errno;
    free(copy);
    if (!*leaf) { close(fd); errno = saved; return -1; }
    return fd;
}

int nv_root_validate(NVRootOwner *owner) {
    if (root_events_check(owner)) return -1;
    struct stat st;
    if (fstat(owner->directory, &st)) return -1;
    if (!S_ISDIR(st.st_mode) || !st.st_nlink || st.st_dev != owner->device || st.st_ino != owner->inode) {
        errno = ESTALE; return -1;
    }
    return 0;
}

static NVRootOwner *root_open(const char *path, int create) {
    char *leaf = NULL;
    int parent = candidate_parent(path, &leaf);
    if (parent < 0) return NULL;
    if (create && (mkdirat(parent, leaf, 0700) || fsync(parent))) {
        int saved = errno; close(parent); free(leaf); errno = saved; return NULL;
    }
    int fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int saved = errno; close(parent); free(leaf); errno = saved;
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st)) { saved = errno; close(fd); errno = saved; return NULL; }
    if (!S_ISDIR(st.st_mode) || !st.st_nlink) { close(fd); errno = ESTALE; return NULL; }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        int saved = errno; close(fd); errno = saved; return NULL;
    }
    NVRootOwner *owner = malloc(sizeof(*owner));
    if (!owner) { int saved = errno; close(fd); errno = saved; return NULL; }
    owner->directory = fd; owner->events = -1; owner->invalidated = 0;
    owner->device = st.st_dev; owner->inode = st.st_ino;
    owner->events = root_events_open(fd);
    if (owner->events < 0) { saved = errno; nv_root_close(owner); errno = saved; return NULL; }
    int same = nv_root_compare(owner, path);
    if (same != 1) {
        saved = same < 0 ? errno : ESTALE; nv_root_close(owner); errno = saved; return NULL;
    }
    return owner;
}

NVRootOwner *nv_root_open(const char *path) { return root_open(path, 0); }
NVRootOwner *nv_root_create(const char *path) { return root_open(path, 1); }

int nv_root_compare(NVRootOwner *owner, const char *candidate) {
    if (nv_root_validate(owner)) return -1;
    char *leaf = NULL;
    int parent = candidate_parent(candidate, &leaf);
    if (parent < 0) return -1;
    struct stat st;
    int result = fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW), saved = errno;
    close(parent); free(leaf); errno = saved;
    if (result) return -1;
    return S_ISDIR(st.st_mode) && st.st_dev == owner->device && st.st_ino == owner->inode;
}

int nv_root_identity(NVRootOwner *owner, uint64_t words[2]) {
    if (nv_root_validate(owner)) return -1;
    words[0] = (uint64_t)owner->device;
    words[1] = (uint64_t)owner->inode;
    return 0;
}

static int safe_component(const char *name) {
    return name[0] && strcmp(name, ".") && strcmp(name, "..");
}

int nv_root_observe(NVRootOwner *owner, const char *relative, uint64_t words[5]) {
    if (nv_root_validate(owner)) return -2;
    if (!relative[0] || relative[0] == '/') { errno = EINVAL; return -1; }
    char *copy = strdup(relative);
    if (!copy) return -1;
    int parent = fcntl(owner->directory, F_DUPFD_CLOEXEC, 0);
    if (parent < 0) { int saved = errno; free(copy); errno = saved; return -1; }
    char *component = copy, *slash;
    int result = -1;
    while ((slash = strchr(component, '/'))) {
        *slash = 0;
        if (!safe_component(component)) { errno = EINVAL; goto done; }
        int next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) goto done;
        close(parent); parent = next; component = slash + 1;
    }
    if (!safe_component(component)) { errno = EINVAL; goto done; }
    struct stat st;
    if (fstatat(parent, component, &st, AT_SYMLINK_NOFOLLOW)) goto done;
    if (nv_root_validate(owner)) { result = -2; goto done; }
    words[0] = S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4;
    words[1] = (uint64_t)st.st_dev; words[2] = (uint64_t)st.st_ino;
    words[3] = (uint64_t)st.st_size; words[4] = (uint64_t)st.st_nlink;
    result = 0;
done:;
    int saved = errno; close(parent); free(copy); errno = saved; return result;
}

void nv_root_close(NVRootOwner *owner) {
    if (!owner) return;
    if (owner->events >= 0) close(owner->events);
    close(owner->directory); free(owner);
}
