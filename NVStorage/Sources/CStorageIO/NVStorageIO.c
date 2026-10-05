#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__linux__) && !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#include "NVStorageIO.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <dirent.h>
#if defined(__APPLE__)
#include <copyfile.h>
#else
#include <sys/xattr.h>
#endif
#if defined(__linux__)
#include <linux/fs.h>
#endif

struct NVStorageOwner { int directory, file; char *path, *database; };
int nv_storage_owner_validate(NVStorageOwner *o) {
    struct stat directory, named, file, namedFile;
    if (fstat(o->directory, &directory) || lstat(o->path, &named) ||
        fstat(o->file, &file) || fstatat(o->directory, "Collection.sqlite", &namedFile, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISDIR(named.st_mode) || !S_ISREG(namedFile.st_mode) ||
        directory.st_dev != named.st_dev || directory.st_ino != named.st_ino ||
        file.st_dev != namedFile.st_dev || file.st_ino != namedFile.st_ino || namedFile.st_nlink != 1) {
        errno = ESTALE; return -1;
    }
    return 0;
}
NVStorageOwner *nv_storage_owner_open(const char *path, int create) {
    if (create && mkdir(path, 0700)) return NULL;
    NVStorageOwner *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->directory = -1; o->file = -1;
    o->path = realpath(path, NULL);
    struct stat named;
    if (!o->path || lstat(path, &named) || !S_ISDIR(named.st_mode)) { errno = EINVAL; goto fail; }
    o->directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (o->directory < 0 || flock(o->directory, LOCK_EX | LOCK_NB)) goto fail;
    o->file = openat(o->directory, "Collection.sqlite", O_RDWR | O_NOFOLLOW | O_CLOEXEC |
        (create ? O_CREAT | O_EXCL : 0), 0600);
    if (o->file < 0) goto fail;
    size_t n = strlen(o->path) + sizeof("/Collection.sqlite");
    o->database = malloc(n);
    if (!o->database) goto fail;
    strcpy(o->database, o->path); strcat(o->database, "/Collection.sqlite");
    if (nv_storage_owner_validate(o)) goto fail;
    if (create) {
        int parent = openat(o->directory, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (parent < 0) goto fail;
        int result = fsync(o->file) || fsync(o->directory) || fsync(parent);
        int saved = errno; close(parent); errno = saved;
        if (result) goto fail;
    }
    return o;
fail:;
    int saved = errno; nv_storage_owner_close(o); errno = saved; return NULL;
}
const char *nv_storage_owner_database(NVStorageOwner *o) { return o->database; }
void nv_storage_owner_close(NVStorageOwner *o) {
    if (!o) return;
    if (o->file >= 0) close(o->file);
    if (o->directory >= 0) close(o->directory);
    free(o->path); free(o->database); free(o);
}

NVStorageOwner *nv_storage_owner_borrow(NVStorageOwner *source) {
    if (nv_storage_owner_validate(source)) return NULL;
    NVStorageOwner *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->directory = -1; o->file = -1;
    o->directory = fcntl(source->directory, F_DUPFD_CLOEXEC, 0);
    o->file = fcntl(source->file, F_DUPFD_CLOEXEC, 0);
    o->path = strdup(source->path); o->database = strdup(source->database);
    if (o->directory < 0 || o->file < 0 || !o->path || !o->database || nv_storage_owner_validate(o)) {
        int saved = errno; nv_storage_owner_close(o); errno = saved; return NULL;
    }
    return o;
}

int nv_storage_entry_kind(const char *path, int *kind) {
    struct stat st;
    if (lstat(path, &st)) { if (errno == ENOENT) { *kind = 0; return 0; } return -1; }
    *kind = S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4;
    return 0;
}

static int durable_file(int fd) {
#if defined(__APPLE__)
    return fcntl(fd, F_FULLFSYNC);
#else
    return fsync(fd);
#endif
}

int nv_storage_owner_descriptor(NVStorageOwner *o, const char *leaf, const char *stage, const uint8_t *bytes, uint64_t count) {
    if (nv_storage_owner_validate(o)) return -1;
    if (!leaf[0] || !strcmp(leaf, ".") || !strcmp(leaf, "..") || strchr(leaf, '/') || count > 67108864) { errno = EINVAL; return -1; }
    if (mkdirat(o->directory, "unlock", 0700) && errno != EEXIST) return -1;
    int dir = openat(o->directory, "unlock", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir < 0) return -1;
    if (!stage[0] || strchr(stage, '/') || !strcmp(stage, ".") || !strcmp(stage, "..") || !strcmp(stage, leaf)) { close(dir); errno = EINVAL; return -1; }
    int fd = openat(dir, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    int existing = fd >= 0;
    if (fd < 0 && errno == ENOENT) fd = openat(dir, stage, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    int result = -1;
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1) { errno = ESTALE; goto done; }
        uint64_t offset = 0;
        if (existing) {
            if (st.st_size < 0 || (uint64_t)st.st_size != count) { errno = EEXIST; goto done; }
            uint8_t buffer[4096];
            while (offset < count) {
                size_t n = count - offset > sizeof(buffer) ? sizeof(buffer) : (size_t)(count - offset);
                ssize_t got = read(fd, buffer, n);
                if (got < 0 && errno == EINTR) continue;
                if (got <= 0 || memcmp(buffer, bytes + offset, (size_t)got)) { errno = EEXIST; goto done; }
                offset += (uint64_t)got;
            }
        } else {
            while (offset < count) {
                ssize_t n = write(fd, bytes + offset, (size_t)(count - offset));
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { if (n == 0) errno = EIO; goto done; }
                offset += (uint64_t)n;
            }
        }
        if (durable_file(fd)) goto done;
        if (!existing && linkat(dir, stage, dir, leaf, 0)) goto done;
        if (!existing && unlinkat(dir, stage, 0)) goto done;
        if (fsync(dir) || fsync(o->directory) || nv_storage_owner_validate(o)) goto done;
        result = 0;
    }
done:;
    int saved = errno;
    if (fd >= 0) close(fd);
    close(dir); errno = saved;
    return result;
}

static int copy_regular(int from, int to) {
    struct stat before, after;
    if (fstat(from, &before) || !S_ISREG(before.st_mode) || before.st_size < 0) { errno = ESTALE; return -1; }
    uint8_t buffer[65536];
    off_t offset = 0;
    while (offset < before.st_size) {
        size_t length = before.st_size - offset > (off_t)sizeof(buffer) ? sizeof(buffer) : (size_t)(before.st_size - offset);
        ssize_t got = pread(from, buffer, length, offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { if (!got) errno = EIO; return -1; }
        size_t written = 0;
        while (written < (size_t)got) {
            ssize_t n = write(to, buffer + written, (size_t)got - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { if (!n) errno = EIO; return -1; }
            written += (size_t)n;
        }
        offset += got;
    }
    if (fstat(from, &after) || before.st_size != after.st_size || before.st_mtime != after.st_mtime || before.st_ctime != after.st_ctime
#if defined(__APPLE__)
        || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
#else
        || before.st_mtim.tv_nsec != after.st_mtim.tv_nsec || before.st_ctim.tv_nsec != after.st_ctim.tv_nsec
#endif
        ) { errno = ESTALE; return -1; }
    return durable_file(to);
}

static int owner_observation(NVStorageOwner *o, uint64_t words[25]) {
    struct stat d, f;
    if (nv_storage_owner_validate(o) || fstat(o->directory, &d) || fstat(o->file, &f)) return -1;
    words[0] = (uint64_t)d.st_dev; words[1] = (uint64_t)d.st_ino;
    words[2] = (uint64_t)f.st_dev; words[3] = (uint64_t)f.st_ino; words[4] = (uint64_t)f.st_size;
    words[5] = (uint64_t)f.st_mtime; words[7] = (uint64_t)f.st_ctime;
#if defined(__APPLE__)
    words[6] = (uint64_t)f.st_mtimespec.tv_nsec; words[8] = (uint64_t)f.st_ctimespec.tv_nsec;
#else
    words[6] = (uint64_t)f.st_mtim.tv_nsec; words[8] = (uint64_t)f.st_ctim.tv_nsec;
#endif
    const char *journals[] = {"Collection.sqlite-wal", "Collection.sqlite-journal"};
    for (size_t i = 0; i < 2; ++i) {
        uint64_t *record = words + 9 + i * 8;
        memset(record, 0, 8 * sizeof(*record));
        struct stat journal;
        if (fstatat(o->directory, journals[i], &journal, AT_SYMLINK_NOFOLLOW)) {
            if (errno == ENOENT) continue;
            return -1;
        }
        if (!S_ISREG(journal.st_mode) || journal.st_size < 0) { errno = ESTALE; return -1; }
        record[0] = 1; record[1] = (uint64_t)journal.st_dev; record[2] = (uint64_t)journal.st_ino;
        record[3] = (uint64_t)journal.st_size; record[4] = (uint64_t)journal.st_mtime; record[6] = (uint64_t)journal.st_ctime;
#if defined(__APPLE__)
        record[5] = (uint64_t)journal.st_mtimespec.tv_nsec; record[7] = (uint64_t)journal.st_ctimespec.tv_nsec;
#else
        record[5] = (uint64_t)journal.st_mtim.tv_nsec; record[7] = (uint64_t)journal.st_ctim.tv_nsec;
#endif
    }
    return 0;
}
int nv_storage_owner_matches(NVStorageOwner *o, const uint64_t expected[25]) {
    uint64_t actual[25];
    if (owner_observation(o, actual)) return -1;
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; return -1; }
    return 0;
}
int nv_storage_preserve_copy(const char *source, const char *destination, uint64_t observation[25]) {
    NVStorageOwner *from = nv_storage_owner_open(source, 0);
    if (!from) return -1;
    NVStorageOwner *to = nv_storage_owner_open(destination, 1);
    if (!to) { int saved = errno; nv_storage_owner_close(from); errno = saved; return -1; }
    int result = copy_regular(from->file, to->file);
    const char *journals[] = {"Collection.sqlite-wal", "Collection.sqlite-journal"};
    for (size_t i = 0; !result && i < sizeof(journals)/sizeof(journals[0]); ++i) {
        int input = openat(from->directory, journals[i], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (input < 0) { if (errno == ENOENT) continue; result = -1; break; }
        int output = openat(to->directory, journals[i], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (output < 0) { close(input); result = -1; break; }
        result = copy_regular(input, output);
        int saved = errno; close(input); close(output); errno = saved;
    }
    if (!result) result = fsync(to->directory) || nv_storage_owner_validate(from) || nv_storage_owner_validate(to) || owner_observation(from, observation);
    int saved = errno; nv_storage_owner_close(to); nv_storage_owner_close(from); errno = saved;
    return result ? -1 : 0;
}

struct NVSelectionOwner {
    int directory, old, stage, stage_directory;
    char *path, *leaf, *destination, *stage_leaf, *stage_path;
    uint8_t expected[90], replacement[90];
    int present;
};
static int leaf_valid(const char *s) { return s[0] && strcmp(s, ".") && strcmp(s, "..") && !strchr(s, '/'); }
int nv_selection_validate(NVSelectionOwner *o) {
    struct stat actual, named;
    if (fstat(o->directory, &actual) || lstat(o->path, &named)) return -1;
    if (!S_ISDIR(named.st_mode) || actual.st_dev != named.st_dev || actual.st_ino != named.st_ino) { errno = ESTALE; return -1; }
    return 0;
}
int nv_selection_identity(NVSelectionOwner *o, uint64_t words[2]) {
    struct stat directory;
    if (nv_selection_validate(o) || fstat(o->directory, &directory)) return -1;
    words[0] = (uint64_t)directory.st_dev; words[1] = (uint64_t)directory.st_ino;
    return 0;
}
NVSelectionOwner *nv_selection_open(const char *path) {
    struct stat named;
    if (lstat(path, &named) || !S_ISDIR(named.st_mode)) { errno = EINVAL; return NULL; }
    NVSelectionOwner *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->directory = -1; o->old = -1; o->stage = -1; o->stage_directory = -1;
    o->path = realpath(path, NULL);
    o->directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!o->path || o->directory < 0 || flock(o->directory, LOCK_EX | LOCK_NB) || nv_selection_validate(o)) {
        int saved = errno; nv_selection_close(o); errno = saved; return NULL;
    }
    return o;
}
static int read_record(int fd, uint8_t bytes[90]) {
    struct stat before, after;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size != 90) { errno = ESTALE; return -1; }
    size_t offset = 0;
    while (offset < 90) {
        ssize_t n = pread(fd, bytes + offset, 90 - offset, (off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (!n) errno = EIO; return -1; } offset += (size_t)n;
    }
    if (fstat(fd, &after) || before.st_size != after.st_size || before.st_mtime != after.st_mtime || before.st_ctime != after.st_ctime
#if defined(__APPLE__)
        || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
#else
        || before.st_mtim.tv_nsec != after.st_mtim.tv_nsec || before.st_ctim.tv_nsec != after.st_ctim.tv_nsec
#endif
        ) { errno = ESTALE; return -1; }
    return 0;
}
int nv_selection_read(NVSelectionOwner *o, const char *leaf, uint8_t bytes[90], int *present) {
    if (!leaf_valid(leaf) || nv_selection_validate(o)) { errno = EINVAL; return -1; }
    int fd = openat(o->directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { if (errno == ENOENT) { *present = 0; return 0; } return -1; }
    *present = 1;
    int result = read_record(fd, bytes), saved = errno; close(fd); errno = saved; return result;
}
int nv_selection_expected(NVSelectionOwner *o) {
    if (nv_selection_validate(o)) return -1;
    uint8_t bytes[90]; int present;
    if (nv_selection_read(o, o->leaf, bytes, &present)) return -1;
    if (present != o->present || (present && memcmp(bytes, o->expected, 90))) { errno = ESTALE; return -1; }
    if (present) {
        struct stat held, named;
        if (fstat(o->old, &held) || fstatat(o->directory, o->leaf, &named, AT_SYMLINK_NOFOLLOW)) return -1;
        if (held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; return -1; }
    }
    return 0;
}
int nv_selection_prepare(NVSelectionOwner *o, const char *leaf, const uint8_t *expected, int present,
                         const uint8_t bytes[90], const char *stage_directory, const char *stage_leaf) {
    if (o->stage >= 0 || !leaf_valid(leaf) || !leaf_valid(stage_leaf) || nv_selection_validate(o)) { errno = EINVAL; return -1; }
    o->leaf = strdup(leaf); o->stage_leaf = strdup(stage_leaf);
    if (!o->leaf || !o->stage_leaf) return -1;
    o->present = present; if (present) memcpy(o->expected, expected, 90);
    memcpy(o->replacement, bytes, 90);
    if (present) o->old = openat(o->directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if ((present && o->old < 0) || nv_selection_expected(o)) return -1;
    o->stage_directory = open(stage_directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (o->stage_directory < 0) return -1;
    o->stage = openat(o->stage_directory, stage_leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (o->stage < 0) return -1;
    size_t n = strlen(o->path) + strlen(leaf) + 2;
    o->destination = malloc(n);
    n = strlen(stage_directory) + strlen(stage_leaf) + 2; o->stage_path = malloc(n);
    if (!o->destination || !o->stage_path) return -1;
    strcpy(o->destination, o->path); strcat(o->destination, "/"); strcat(o->destination, leaf);
    strcpy(o->stage_path, stage_directory); strcat(o->stage_path, "/"); strcat(o->stage_path, stage_leaf);
    size_t offset = 0;
    while (offset < 90) {
        ssize_t written = write(o->stage, bytes + offset, 90 - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { if (!written) errno = EIO; return -1; } offset += (size_t)written;
    }
    return durable_file(o->stage) || fsync(o->stage_directory) || nv_selection_expected(o) ? -1 : 0;
}
const char *nv_selection_destination(NVSelectionOwner *o) { return o->destination; }
const char *nv_selection_stage_path(NVSelectionOwner *o) { return o->stage_path; }
int nv_selection_install_portable(NVSelectionOwner *o) {
    if (nv_selection_expected(o)) return -1;
    if (!o->present) return linkat(o->stage_directory, o->stage_leaf, o->directory, o->leaf, 0);
#if defined(__linux__)
    return renameat2(o->stage_directory, o->stage_leaf, o->directory, o->leaf, RENAME_EXCHANGE);
#else
    errno = ENOTSUP; return -1;
#endif
}
int nv_selection_complete(NVSelectionOwner *o, const char *backup_leaf) {
    if (nv_selection_validate(o)) return -1;
    int fd = openat(o->directory, o->leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat installed, stage;
    uint8_t bytes[90];
    int result = fstat(fd, &installed) || fstat(o->stage, &stage) || read_record(fd, bytes);
    if (!result && (installed.st_dev != stage.st_dev || installed.st_ino != stage.st_ino || memcmp(bytes, o->replacement, 90))) { errno = ESTALE; result = -1; }
    if (!result && o->present) {
        int backup = backup_leaf ? openat(o->directory, backup_leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                                 : openat(o->stage_directory, o->stage_leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat old, displaced;
        if (backup < 0 || fstat(o->old, &old) || fstat(backup, &displaced) || read_record(backup, bytes) ||
            old.st_dev != displaced.st_dev || old.st_ino != displaced.st_ino || memcmp(bytes, o->expected, 90)) { errno = ESTALE; result = -1; }
        if (backup >= 0) close(backup);
    }
    if (!result) result = durable_file(fd) || fsync(o->directory) || fsync(o->stage_directory) || nv_selection_validate(o);
    int saved = errno; close(fd); errno = saved; return result ? -1 : 0;
}
void nv_selection_close(NVSelectionOwner *o) {
    if (!o) return;
    if (o->stage >= 0) close(o->stage);
    if (o->stage_directory >= 0) close(o->stage_directory);
    if (o->old >= 0) close(o->old);
    if (o->directory >= 0) close(o->directory);
    free(o->path); free(o->leaf); free(o->destination); free(o->stage_leaf); free(o->stage_path); free(o);
}

struct NVRepositoryOwner { int directory; char *path; };
struct NVRepositoryCatalog { DIR *directory; };
int nv_repository_validate(NVRepositoryOwner *o) {
    struct stat held, named;
    if (fstat(o->directory, &held) || lstat(o->path, &named)) return -1;
    if (!S_ISDIR(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; return -1; }
    return 0;
}
NVRepositoryOwner *nv_repository_open(const char *path) {
    struct stat st;
    if (lstat(path, &st) || !S_ISDIR(st.st_mode)) { errno = EINVAL; return NULL; }
    NVRepositoryOwner *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->directory = -1; o->path = realpath(path, NULL);
    o->directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!o->path || o->directory < 0 || nv_repository_validate(o)) {
        int saved = errno; nv_repository_close(o); errno = saved; return NULL;
    }
    return o;
}
NVRepositoryOwner *nv_repository_create(NVRepositoryOwner *source, const char *path) {
    if (source && nv_repository_validate(source)) return NULL;
    char *copy = strdup(path);
    if (!copy) return NULL;
    char *slash = strrchr(copy, '/');
    if (!slash || !leaf_valid(slash + 1)) { free(copy); errno = EINVAL; return NULL; }
    *slash = 0;
    int parent = open(copy[0] ? copy : "/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int ancestor = parent < 0 ? -1 : fcntl(parent, F_DUPFD_CLOEXEC, 0);
    struct stat source_stat;
    int failed = parent < 0 || ancestor < 0 || (source && fstat(source->directory, &source_stat));
    while (source && !failed) {
        struct stat here, above;
        int next;
        if (fstat(ancestor, &here)) { failed = 1; break; }
        if (here.st_dev == source_stat.st_dev && here.st_ino == source_stat.st_ino) { errno = EINVAL; failed = 1; break; }
        next = openat(ancestor, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) { failed = 1; break; }
        if (fstat(next, &above)) { close(next); failed = 1; break; }
        close(ancestor); ancestor = next;
        if (here.st_dev == above.st_dev && here.st_ino == above.st_ino) break;
    }
    if (!failed) failed = mkdirat(parent, slash + 1, 0700) || fsync(parent);
    int saved = errno;
    if (ancestor >= 0) close(ancestor);
    if (parent >= 0) close(parent);
    free(copy); errno = saved;
    if (failed) return NULL;
    NVRepositoryOwner *result = nv_repository_open(path);
    if (result && flock(result->directory, LOCK_EX | LOCK_NB)) {
        saved = errno; nv_repository_close(result); errno = saved; return NULL;
    }
    return result;
}
/* Every component is opened from the retained root; caller owns the returned parent and leaf. */
static int repository_parent(NVRepositoryOwner *o, const char *relative, char **leaf) {
    if (nv_repository_validate(o) || !relative[0] || relative[0] == '/') { errno = EINVAL; return -1; }
    char *copy = strdup(relative);
    if (!copy) return -1;
    int fd = fcntl(o->directory, F_DUPFD_CLOEXEC, 0);
    char *component = copy, *slash;
    while ((slash = strchr(component, '/'))) {
        *slash = 0;
        if (!leaf_valid(component)) { errno = EINVAL; goto fail; }
        int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) goto fail;
        close(fd); fd = next; component = slash + 1;
    }
    if (!leaf_valid(component) || fd < 0) { errno = EINVAL; goto fail; }
    *leaf = strdup(component);
    if (!*leaf) goto fail;
    free(copy); return fd;
fail:;
    int saved = errno; if (fd >= 0) close(fd); free(copy); errno = saved; return -1;
}
NVRepositoryCatalog *nv_repository_catalog(NVRepositoryOwner *o, const char *relative) {
    if (nv_repository_validate(o)) return NULL;
    int fd;
    if (!relative[0]) fd = openat(o->directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    else {
        char *leaf = NULL; int parent = repository_parent(o, relative, &leaf);
        if (parent < 0) return NULL;
        fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno; close(parent); free(leaf); errno = saved;
    }
    if (fd < 0) return NULL;
    NVRepositoryCatalog *catalog = calloc(1, sizeof(*catalog));
    if (!catalog) { close(fd); return NULL; }
    catalog->directory = fdopendir(fd);
    if (!catalog->directory) { int saved = errno; close(fd); free(catalog); errno = saved; return NULL; }
    return catalog;
}
const char *nv_repository_next(NVRepositoryCatalog *catalog) {
    struct dirent *entry;
    do { errno = 0; entry = readdir(catalog->directory); } while (entry && (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")));
    return entry ? entry->d_name : NULL;
}
void nv_repository_catalog_close(NVRepositoryCatalog *catalog) {
    if (!catalog) return;
    closedir(catalog->directory); free(catalog);
}
static void entry_observation(struct stat st, uint64_t words[9]) {
    words[0] = S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4;
    words[1] = (uint64_t)st.st_dev; words[2] = (uint64_t)st.st_ino; words[3] = (uint64_t)st.st_size;
    words[4] = (uint64_t)st.st_mtime; words[6] = (uint64_t)st.st_ctime; words[8] = (uint64_t)st.st_nlink;
#if defined(__APPLE__)
    words[5] = (uint64_t)st.st_mtimespec.tv_nsec; words[7] = (uint64_t)st.st_ctimespec.tv_nsec;
#else
    words[5] = (uint64_t)st.st_mtim.tv_nsec; words[7] = (uint64_t)st.st_ctim.tv_nsec;
#endif
}
int nv_repository_observe(NVRepositoryOwner *o, const char *relative, uint64_t words[9]) {
    char *leaf = NULL; int parent = repository_parent(o, relative, &leaf);
    if (parent < 0) return -1;
    struct stat st;
    int result = fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW), saved = errno;
    close(parent); free(leaf); errno = saved;
    if (!result) entry_observation(st, words);
    return result;
}
int nv_repository_read_open(NVRepositoryOwner *o, const char *relative, const uint64_t expected[9]) {
    char *leaf = NULL; int parent = repository_parent(o, relative, &leaf);
    if (parent < 0) return -1;
    int fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), saved = errno;
    close(parent); free(leaf); errno = saved;
    if (fd < 0) return -1;
    struct stat st; uint64_t actual[9];
    if (fstat(fd, &st)) { saved = errno; close(fd); errno = saved; return -1; }
    entry_observation(st, actual);
    if (expected[0] != 1 || memcmp(actual, expected, sizeof(actual))) { close(fd); errno = ESTALE; return -1; }
    return fd;
}
int nv_repository_mkdir(NVRepositoryOwner *o, const char *relative) {
    char *leaf = NULL; int parent = repository_parent(o, relative, &leaf);
    if (parent < 0) return -1;
    int result = mkdirat(parent, leaf, 0700) || fsync(parent), saved = errno;
    close(parent); free(leaf); errno = saved; return result ? -1 : 0;
}
static int copy_metadata(int from, int to) {
#if defined(__APPLE__)
    return fcopyfile(from, to, NULL, COPYFILE_METADATA);
#else
    ssize_t count = flistxattr(from, NULL, 0);
    if (count < 0) return -1;
    if (count > 65536) { errno = E2BIG; return -1; }
    char *names = malloc(count ? (size_t)count : 1);
    if (!names) return -1;
    if (flistxattr(from, names, (size_t)count) != count) { int saved = errno; free(names); errno = saved; return -1; }
    size_t offset = 0;
    while (offset < (size_t)count) {
        size_t length = strnlen(names + offset, (size_t)count - offset);
        if (!length || length == (size_t)count - offset) { free(names); errno = EIO; return -1; }
        const char *name = names + offset;
        ssize_t size = fgetxattr(from, name, NULL, 0);
        if (size < 0 || size > 67108864) { int saved = size < 0 ? errno : E2BIG; free(names); errno = saved; return -1; }
        void *value = malloc(size ? (size_t)size : 1);
        if (!value) { free(names); return -1; }
        int failed = fgetxattr(from, name, value, (size_t)size) != size || fsetxattr(to, name, value, (size_t)size, 0);
        int saved = errno; free(value);
        if (failed) { free(names); errno = saved; return -1; }
        offset += length + 1;
    }
    free(names);
    struct stat st;
    if (fstat(from, &st)) return -1;
    const struct timespec times[] = {st.st_atim, st.st_mtim};
    return fchmod(to, st.st_mode & 0777) || futimens(to, times) ? -1 : 0;
#endif
}
/* Bind the installed name to the descriptor whose bytes received the durability barrier. */
static int installed_file_matches(int parent, const char *leaf, int fd) {
    struct stat held, named;
    if (fstat(fd, &held) || fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISREG(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino ||
        held.st_size != named.st_size) { errno = ESTALE; return -1; }
    return 0;
}
int nv_repository_copy(NVRepositoryOwner *source, NVRepositoryOwner *destination, const char *relative, const uint64_t expected[9]) {
    char *from_leaf = NULL, *to_leaf = NULL;
    int from_parent = repository_parent(source, relative, &from_leaf), to_parent = -1, input = -1, output = -1, result = -1;
    if (from_parent < 0) goto done;
    to_parent = repository_parent(destination, relative, &to_leaf);
    if (to_parent < 0) goto done;
    input = openat(from_parent, from_leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (input < 0) goto done;
    struct stat st; uint64_t observation[9];
    if (fstat(input, &st)) goto done;
    entry_observation(st, observation);
    if (expected[0] != 1 || memcmp(expected, observation, sizeof(observation))) { errno = ESTALE; goto done; }
    output = openat(to_parent, to_leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0 || copy_regular(input, output) || copy_metadata(input, output) || durable_file(output)) goto done;
    if (fstatat(from_parent, from_leaf, &st, AT_SYMLINK_NOFOLLOW)) goto done;
    entry_observation(st, observation);
    if (memcmp(expected, observation, sizeof(observation))) { errno = ESTALE; goto done; }
    if (fsync(to_parent) || installed_file_matches(to_parent, to_leaf, output) || nv_repository_validate(source) || nv_repository_validate(destination)) goto done;
    result = 0;
done:;
    int saved = errno;
    if (input >= 0) close(input); if (output >= 0) close(output);
    if (from_parent >= 0) close(from_parent); if (to_parent >= 0) close(to_parent);
    free(from_leaf); free(to_leaf); errno = saved; return result;
}
int nv_repository_install(NVRepositoryOwner *o, const char *relative, const uint8_t *bytes, uint64_t count) {
    char *leaf = NULL; int parent = repository_parent(o, relative, &leaf);
    if (parent < 0) return -1;
    int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600), result = -1;
    uint64_t offset = 0;
    if (fd >= 0) {
        while (offset < count) {
            ssize_t n = write(fd, bytes + offset, (size_t)(count - offset));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { if (!n) errno = EIO; goto done; }
            offset += (uint64_t)n;
        }
        if (durable_file(fd) || fsync(parent) || installed_file_matches(parent, leaf, fd) || nv_repository_validate(o)) goto done;
        result = 0;
    }
done:;
    int saved = errno; if (fd >= 0) close(fd); close(parent); free(leaf); errno = saved; return result;
}
int nv_repository_sync(NVRepositoryOwner *o) { return nv_repository_validate(o) || fsync(o->directory) ? -1 : 0; }
void nv_repository_close(NVRepositoryOwner *o) { if (o) { if (o->directory >= 0) close(o->directory); free(o->path); free(o); } }
