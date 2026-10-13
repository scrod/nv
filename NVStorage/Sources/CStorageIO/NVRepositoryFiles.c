#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "NVRepositoryRoot.h"
#include "NVRepositoryRootInternal.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#include <sys/vnode.h>
#include <stddef.h>
#endif

/* Tests observe completed native effects and inject failures beneath these calls. */
#ifndef NV_REPOSITORY_EVENT
#define NV_REPOSITORY_EVENT(name, fd) ((void)(fd))
#endif
#define NV_PROTOCOL_COMPONENTS 6
#define NV_PROTOCOL_BYTES (64ULL * 1024 * 1024 + 64 * 1024 + 156)

typedef struct { int fd[NV_PROTOCOL_COMPONENTS]; unsigned count; char *names[NV_PROTOCOL_COMPONENTS]; char *storage; char *leaf; } FilePath;

static void path_close(FilePath *path) {
    for (unsigned i = 0; i < path->count; i++) close(path->fd[i]);
    free(path->storage);
}

static int file_component(const char *name) {
    return name[0] && strcmp(name, ".") && strcmp(name, "..") && strlen(name) <= 255;
}

static int file_relative(const char *relative) {
    size_t length = strnlen(relative, NV_PROTOCOL_COMPONENTS * 256 + 1);
    if (!length || length > NV_PROTOCOL_COMPONENTS * 256 || relative[0] == '/') return 0;
    unsigned count = 0;
    const char *start = relative;
    for (const char *p = relative;; p++) {
        if (*p != '/' && *p) continue;
        size_t size = (size_t)(p - start);
        if (!size || size > 255 || (size == 1 && start[0] == '.') ||
            (size == 2 && start[0] == '.' && start[1] == '.') || ++count > NV_PROTOCOL_COMPONENTS) return 0;
        if (!*p) return 1;
        start = p + 1;
    }
}

/* Retains every namespace parent so verification and barriers address the same objects. */
static int path_open(NVRootOwner *owner, const char *relative, int create, FilePath *path, int *changed) {
    memset(path, 0, sizeof(*path));
    if (!file_relative(relative)) { errno = EINVAL; return -1; }
    path->storage = strdup(relative);
    if (!path->storage) return -1;
    int root = fcntl(owner->directory, F_DUPFD_CLOEXEC, 0);
    if (root < 0) return -1;
    path->fd[path->count++] = root;
    char *component = path->storage, *slash;
    while ((slash = strchr(component, '/'))) {
        *slash = 0;
        if (!file_component(component) || path->count >= NV_PROTOCOL_COMPONENTS) { errno = EINVAL; return -1; }
        int parent = path->fd[path->count - 1];
        struct stat st;
        if (fstatat(parent, component, &st, AT_SYMLINK_NOFOLLOW)) {
            if (!create || errno != ENOENT) return -1;
            if (mkdirat(parent, component, 0700)) { if (errno != EEXIST) return -1; }
            else { *changed = 1; NV_REPOSITORY_EVENT("directory-created", parent); }
            if (fstatat(parent, component, &st, AT_SYMLINK_NOFOLLOW)) return -1;
        }
        if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
        int child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child < 0) return -1;
        path->names[path->count] = component;
        path->fd[path->count++] = child;
        struct stat opened;
        if (fstat(child, &opened)) return -1;
        if (opened.st_dev != st.st_dev || opened.st_ino != st.st_ino) { errno = ESTALE; return -1; }
        component = slash + 1;
    }
    if (!file_component(component)) { errno = EINVAL; return -1; }
    path->leaf = component;
    return 0;
}

static int path_check(NVRootOwner *owner, FilePath *path) {
    if (nv_root_validate(owner)) return -2;
    for (unsigned i = 1; i < path->count; i++) {
        struct stat held, named;
        if (fstat(path->fd[i], &held) || fstatat(path->fd[i-1], path->names[i], &named, AT_SYMLINK_NOFOLLOW)) return -1;
        if (!S_ISDIR(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; return -1; }
    }
    return 0;
}

static void file_words(const struct stat *st, uint64_t words[9]) {
    words[0] = S_ISREG(st->st_mode) ? 1 : S_ISDIR(st->st_mode) ? 2 : S_ISLNK(st->st_mode) ? 3 : 4;
    words[1] = (uint64_t)st->st_dev; words[2] = (uint64_t)st->st_ino;
    words[3] = (uint64_t)st->st_size; words[4] = (uint64_t)st->st_nlink;
#if defined(__APPLE__)
    words[5] = (uint64_t)st->st_mtimespec.tv_sec; words[6] = (uint64_t)st->st_mtimespec.tv_nsec;
    words[7] = (uint64_t)st->st_ctimespec.tv_sec; words[8] = (uint64_t)st->st_ctimespec.tv_nsec;
#else
    words[5] = (uint64_t)st->st_mtim.tv_sec; words[6] = (uint64_t)st->st_mtim.tv_nsec;
    words[7] = (uint64_t)st->st_ctim.tv_sec; words[8] = (uint64_t)st->st_ctim.tv_nsec;
#endif
}

int nv_root_snapshot(NVRootOwner *owner, const char *relative, uint64_t words[9]) {
    if (nv_root_validate(owner)) return -2;
    FilePath path; int changed = 0, result = -1;
    if (path_open(owner, relative, 0, &path, &changed)) goto done;
    struct stat st;
    if (fstatat(path.fd[path.count-1], path.leaf, &st, AT_SYMLINK_NOFOLLOW)) goto done;
    result = path_check(owner, &path);
    if (!result) file_words(&st, words);
done:;
    int saved = errno; path_close(&path); errno = saved; return result;
}

int nv_root_residency(NVRootOwner *owner, const char *relative, const uint64_t expected[9], int *dataless) {
    if (nv_root_validate(owner)) return -2;
    FilePath path; int changed = 0, result = -1;
    *dataless = -1;
    if (path_open(owner, relative, 0, &path, &changed)) goto done;
    struct stat st; uint64_t actual[9];
    if (fstatat(path.fd[path.count-1], path.leaf, &st, AT_SYMLINK_NOFOLLOW)) goto done;
    file_words(&st, actual);
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; goto done; }
#if defined(__APPLE__) && defined(SF_DATALESS)
    *dataless = (st.st_flags & SF_DATALESS) != 0;
#endif
    result = path_check(owner, &path);
done:;
    int saved = errno; path_close(&path); errno = saved; return result;
}

static int read_exact_fd(int fd, uint8_t *bytes, uint64_t count) {
    uint64_t offset = 0;
    while (offset < count) {
        ssize_t amount = pread(fd, bytes + offset, (size_t)(count - offset), (off_t)offset);
        if (amount < 0) { if (errno == EINTR) continue; return -1; }
        if (!amount) { errno = ESTALE; return -1; }
        offset += (uint64_t)amount;
    }
    return 0;
}

int nv_root_read(NVRootOwner *owner, const char *relative, const uint64_t expected[9], uint8_t *bytes, uint64_t count) {
    if (nv_root_validate(owner)) return -2;
    if (count > NV_PROTOCOL_BYTES || expected[3] != count) { errno = EFBIG; return -1; }
    FilePath path; int changed = 0, fd = -1, result = -1;
    if (path_open(owner, relative, 0, &path, &changed)) goto done;
    fd = openat(path.fd[path.count-1], path.leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) goto done;
    struct stat st; uint64_t actual[9];
    if (fstat(fd, &st)) goto done;
    file_words(&st, actual);
    if (!S_ISREG(st.st_mode)) { errno = ENOTDIR; goto done; }
    if (st.st_nlink != 1) { errno = EMLINK; goto done; }
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; goto done; }
    if (read_exact_fd(fd, bytes, count)) goto done;
    NV_REPOSITORY_EVENT("read-complete", fd);
    if (fstat(fd, &st)) goto done;
    file_words(&st, actual);
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; goto done; }
    if (fstatat(path.fd[path.count-1], path.leaf, &st, AT_SYMLINK_NOFOLLOW)) goto done;
    file_words(&st, actual);
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; goto done; }
    result = path_check(owner, &path);
done:;
    int saved = errno; if (fd >= 0) close(fd); path_close(&path); errno = saved; return result;
}

struct NVRootListing { DIR *stream; FilePath path; uint64_t device, inode; int metadata_mode, finished; };

NVRootListing *nv_root_list_open(NVRootOwner *owner, const char *relative) {
    if (nv_root_validate(owner)) return NULL;
    NVRootListing *listing = calloc(1, sizeof(*listing));
    if (!listing) return NULL;
    int changed = 0;
    if (path_open(owner, relative, 0, &listing->path, &changed)) goto failed;
    int fd = openat(listing->path.fd[listing->path.count-1], listing->path.leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) goto failed;
    struct stat st;
    if (fstat(fd, &st)) { int saved = errno; close(fd); errno = saved; goto failed; }
    listing->device = (uint64_t)st.st_dev; listing->inode = (uint64_t)st.st_ino;
    listing->stream = fdopendir(fd);
    if (!listing->stream) { int saved = errno; close(fd); errno = saved; goto failed; }
    return listing;
failed:;
    int saved = errno; nv_root_list_close(listing); errno = saved; return NULL;
}

static int listing_check(NVRootOwner *owner, NVRootListing *listing) {
    int result = path_check(owner, &listing->path);
    if (result) return result;
    struct stat st;
    if (fstatat(listing->path.fd[listing->path.count-1], listing->path.leaf, &st, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISDIR(st.st_mode) || (uint64_t)st.st_dev != listing->device || (uint64_t)st.st_ino != listing->inode) { errno = ESTALE; return -1; }
    return 0;
}

int nv_root_list_next(NVRootOwner *owner, NVRootListing *listing, unsigned budget, uint8_t *bytes,
                      unsigned capacity, unsigned *used, int *finished) {
    *used = 0; *finished = 0;
    if (!budget || budget > 256 || capacity < budget * 257) { errno = EINVAL; return -1; }
    int result = listing_check(owner, listing);
    if (result) return result;
    for (unsigned i = 0; i < budget; i++) {
        errno = 0;
        struct dirent *entry = readdir(listing->stream);
        if (!entry) { if (errno) return -1; *finished = 1; break; }
        size_t length = strnlen(entry->d_name, sizeof(entry->d_name));
        if (!length || length > 255 || length == sizeof(entry->d_name)) { errno = EOVERFLOW; return -1; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        bytes[(*used)++] = (uint8_t)length;
        memcpy(bytes + *used, entry->d_name, length); *used += (unsigned)length;
    }
    return listing_check(owner, listing);
}

void nv_root_list_close(NVRootListing *listing) {
    if (!listing) return;
    if (listing->stream) closedir(listing->stream);
    path_close(&listing->path); free(listing);
}

NVRootListing *nv_root_metadata_open(NVRootOwner *owner, const char *relative, int portable) {
    NVRootListing *listing = nv_root_list_open(owner, relative);
    if (!listing) return NULL;
#if defined(__APPLE__)
    listing->metadata_mode = portable ? 1 : 2;
#else
    (void)portable;
    listing->metadata_mode = 1;
#endif
    return listing;
}

static int metadata_name(NVRootMetadataEntry *entry, const uint8_t *name, size_t length) {
    if (!length || length > 255 || memchr(name, 0, length) || memchr(name, '/', length) ||
        (length == 1 && name[0] == '.') || (length == 2 && name[0] == '.' && name[1] == '.')) {
        errno = EINVAL; return -1;
    }
    memset(entry, 0, sizeof(*entry));
    entry->length = (uint32_t)length;
    memcpy(entry->name, name, length);
    return 0;
}

static void metadata_stat(NVRootListing *listing, NVRootMetadataEntry *entry, NVRootMetadataTurn *turn) {
    struct stat st;
    turn->stat_calls++;
    if (fstatat(dirfd(listing->stream), (const char *)entry->name, &st, AT_SYMLINK_NOFOLLOW)) entry->error = errno;
    else { entry->error = 0; file_words(&st, entry->words); }
}

#if defined(__APPLE__)
typedef struct __attribute__((packed, aligned(4))) {
    uint32_t length; attribute_set_t returned; uint32_t error; attrreference_t name;
    dev_t device; fsobj_type_t type; struct timespec modified, changed; uint64_t inode;
    uint32_t links; off_t size;
} NVMetadataBulkRecord;

static struct attrlist metadata_attributes(void) {
    struct attrlist requested = {0}; requested.bitmapcount = ATTR_BIT_MAP_COUNT;
    requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
    requested.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH;
    return requested;
}

/* Common headers identify raw names; fully returned regular-file fields enable the bulk fast path. */
static int metadata_parse(const uint8_t *bytes, size_t capacity, unsigned count,
                          NVRootMetadataEntry entries[64]) {
    if (count > 64) { errno = EOVERFLOW; return -1; }
    struct attrlist requested = metadata_attributes();
    size_t offset = 0;
    for (unsigned i = 0; i < count; i++) {
        size_t header = offsetof(NVMetadataBulkRecord, device);
        if (offset > capacity || header > capacity - offset) { errno = EIO; return -1; }
        NVMetadataBulkRecord record = {0}; memcpy(&record, bytes + offset, header);
        if (record.length < header || record.length % 8 || record.length > capacity - offset ||
            !(record.returned.commonattr & ATTR_CMN_NAME) || record.name.attr_dataoffset < 0 ||
            record.name.attr_length < 2 || record.name.attr_length > 256) { errno = EIO; return -1; }
        size_t start = offsetof(NVMetadataBulkRecord, name) + (size_t)record.name.attr_dataoffset;
        if (start < header || start > record.length || record.name.attr_length > record.length - start) {
            errno = EIO; return -1;
        }
        const uint8_t *name = bytes + offset + start;
        if (name[record.name.attr_length - 1] || metadata_name(&entries[i], name, record.name.attr_length - 1)) {
            errno = EIO; return -1;
        }
        if (!(record.returned.commonattr & ATTR_CMN_ERROR) || record.error > INT_MAX) { errno = EIO; return -1; }
        entries[i].error = (int)record.error;
        if (!record.error) {
            if (start >= sizeof(record)) memcpy(&record, bytes + offset, sizeof(record));
            if (start < sizeof(record) || (record.returned.commonattr & requested.commonattr) != requested.commonattr ||
                (record.returned.fileattr & requested.fileattr) != requested.fileattr || record.type != VREG ||
                record.modified.tv_nsec < 0 || record.modified.tv_nsec >= 1000000000 ||
                record.changed.tv_nsec < 0 || record.changed.tv_nsec >= 1000000000 || record.size < 0) {
                entries[i].refresh = 1;
            } else {
                uint64_t words[9] = {1, (uint64_t)record.device, record.inode, (uint64_t)record.size, record.links,
                    (uint64_t)record.modified.tv_sec, (uint64_t)record.modified.tv_nsec,
                    (uint64_t)record.changed.tv_sec, (uint64_t)record.changed.tv_nsec};
                memcpy(entries[i].words, words, sizeof(words));
            }
        }
        offset += record.length;
    }
    return 0;
}

/* A new enumeration descriptor starts the portable fallback without sharing the bulk offset. */
static int metadata_portable(NVRootListing *listing) {
    int fd = openat(dirfd(listing->stream), ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    DIR *replacement = fdopendir(fd);
    if (!replacement) { int saved = errno; close(fd); errno = saved; return -1; }
    closedir(listing->stream); listing->stream = replacement; listing->metadata_mode = 1;
    return 0;
}
#endif

int nv_root_metadata_next(NVRootOwner *owner, NVRootListing *listing, unsigned budget,
                         NVRootMetadataEntry entries[64], NVRootMetadataTurn *turn) {
    memset(turn, 0, sizeof(*turn));
    if (!budget || budget > 64 || !listing->metadata_mode) { errno = EINVAL; return -1; }
    turn->ancestor_checks++;
    int result = listing_check(owner, listing);
    if (result) return result;
    NV_REPOSITORY_EVENT("metadata-before", dirfd(listing->stream));
#if defined(__APPLE__)
    if (!listing->finished && listing->metadata_mode == 2) {
        struct attrlist requested = metadata_attributes();
        enum { minimum_record = (offsetof(NVMetadataBulkRecord, device) + 2 + 7) & ~7U };
        uint8_t buffer[64 * minimum_record];
        size_t capacity = sizeof(buffer);
        turn->bulk_calls++;
        int count = getattrlistbulk(dirfd(listing->stream), &requested, buffer, capacity, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) {
            if (errno != ENOTSUP && errno != ENOSYS && errno != EINVAL) return -1;
            if (metadata_portable(listing)) return -1;
        } else {
            if ((unsigned)count > 64 || metadata_parse(buffer, capacity, (unsigned)count, entries)) return -1;
            turn->count = (unsigned)count;
            listing->finished = count == 0;
            for (unsigned i = 0; i < turn->count; i++) {
                if (entries[i].refresh) metadata_stat(listing, &entries[i], turn);
            }
        }
    }
#endif
    if (!listing->finished && listing->metadata_mode == 1) {
        for (unsigned i = 0; i < budget; i++) {
            errno = 0;
            struct dirent *entry = readdir(listing->stream);
            if (!entry) { if (errno) return -1; listing->finished = 1; break; }
            size_t length = strnlen(entry->d_name, sizeof(entry->d_name));
            if (!length || length > 255 || length == sizeof(entry->d_name)) { errno = EOVERFLOW; return -1; }
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            NVRootMetadataEntry *value = &entries[turn->count++];
            if (metadata_name(value, (const uint8_t *)entry->d_name, length)) return -1;
            metadata_stat(listing, value, turn);
        }
    }
    NV_REPOSITORY_EVENT("metadata-after", dirfd(listing->stream));
    turn->finished = listing->finished;
    turn->ancestor_checks++;
    return listing_check(owner, listing);
}

int nv_root_metadata_refresh(NVRootOwner *owner, NVRootListing *listing,
                            NVRootMetadataEntry *entries, unsigned count, NVRootMetadataTurn *turn) {
    memset(turn, 0, sizeof(*turn));
    if (!count || count > 64 || !listing->metadata_mode) { errno = EINVAL; return -1; }
    turn->ancestor_checks++;
    int result = listing_check(owner, listing);
    if (result) return result;
    NV_REPOSITORY_EVENT("metadata-before", dirfd(listing->stream));
    for (unsigned i = 0; i < count; i++) {
        uint32_t length = entries[i].length;
        if (!length || length > 255 || entries[i].name[length] || memchr(entries[i].name, 0, length) ||
            memchr(entries[i].name, '/', length) || !file_component((const char *)entries[i].name)) { errno = EINVAL; return -1; }
        metadata_stat(listing, &entries[i], turn);
    }
    NV_REPOSITORY_EVENT("metadata-after", dirfd(listing->stream));
    turn->count = count; turn->finished = listing->finished;
    turn->ancestor_checks++;
    return listing_check(owner, listing);
}

static int file_barrier(int fd) {
    int result;
    do { result = fsync(fd); } while (result && errno == EINTR);
    if (result) return -1;
#if defined(__APPLE__)
    do { result = fcntl(fd, F_FULLFSYNC); } while (result && errno == EINTR);
    if (result) return -1;
#endif
    NV_REPOSITORY_EVENT("file-synced", fd);
    return 0;
}

static int verify_fd(int fd, const uint8_t *bytes, uint64_t count, struct stat *verified) {
    struct stat before, after;
    if (fstat(fd, &before)) return -1;
    if (!S_ISREG(before.st_mode)) { errno = ENOTDIR; return -1; }
    if (before.st_nlink != 1) { errno = EMLINK; return -1; }
    if (before.st_size < 0 || (uint64_t)before.st_size != count) { errno = EEXIST; return -1; }
    uint8_t buffer[16384];
    for (uint64_t offset = 0; offset < count;) {
        uint64_t amount = count - offset;
        if (amount > sizeof(buffer)) amount = sizeof(buffer);
        ssize_t got = pread(fd, buffer, (size_t)amount, (off_t)offset);
        if (got < 0) { if (errno == EINTR) continue; return -1; }
        if (!got) { errno = ESTALE; return -1; }
        if (memcmp(buffer, bytes + offset, (size_t)got)) { errno = EEXIST; return -1; }
        offset += (uint64_t)got;
    }
    if (fstat(fd, &after)) return -1;
    uint64_t a[9], b[9]; file_words(&before, a); file_words(&after, b);
    if (memcmp(a, b, sizeof(a))) { errno = ESTALE; return -1; }
    *verified = after; return 0;
}

static int exclusive_rename(int source, const char *stage, int destination, const char *leaf) {
#if defined(__APPLE__)
    return renameatx_np(source, stage, destination, leaf, RENAME_EXCL);
#elif defined(__linux__)
    return renameat2(source, stage, destination, leaf, RENAME_NOREPLACE);
#else
    (void)source; (void)stage; (void)destination; (void)leaf; errno = ENOTSUP; return -1;
#endif
}

/* Cleanup's identity check preserves displaced names under the reserved-stage producer contract. */
static int cleanup_stage(NVRootOwner *owner, const char *stage, int heldfd) {
    struct stat named, held_value;
    if (fstat(heldfd, &held_value)) return -1;
    const struct stat *held = &held_value;
    if (fstatat(owner->directory, stage, &named, AT_SYMLINK_NOFOLLOW)) return errno == ENOENT ? 0 : -1;
    /* Empty ExFAT files can share an allocation-placeholder inode. Preserve that ambiguity. */
    if (!held->st_size) { errno = ESTALE; return -1; }
    if (!S_ISREG(named.st_mode) || named.st_dev != held->st_dev || named.st_ino != held->st_ino || named.st_nlink != 1) { errno = ESTALE; return -1; }
    if (unlinkat(owner->directory, stage, 0)) return -1;
    NV_REPOSITORY_EVENT("stage-cleaned", owner->directory);
    return 0;
}

static void make_directory(NVRootOwner *owner, const char *relative, NVRootInstallResult *result, int exclusive) {
    *result = (NVRootInstallResult){.outcome = NV_ROOT_INSTALL_NO_EFFECT};
    if (nv_root_validate(owner)) { result->error = errno; result->root_lost = 1; return; }
    FilePath path; int fd = -1;
    if (path_open(owner, relative, 0, &path, &result->namespace_changed) || path_check(owner, &path)) goto failed;
    int parent = path.fd[path.count-1];
    if (mkdirat(parent, path.leaf, 0700)) { if (errno != EEXIST || exclusive) goto failed; }
    else { result->namespace_changed = 1; NV_REPOSITORY_EVENT("directory-created", parent); }
    fd = openat(parent, path.leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) goto failed;
    struct stat held, named;
    if (fstat(fd, &held) || fstatat(parent, path.leaf, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    if (!S_ISDIR(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; goto failed; }
    if (result->namespace_changed) {
        int barrier;
        do { barrier = fsync(fd); } while (barrier && errno == EINTR);
        if (barrier) goto failed;
        do { barrier = fsync(parent); } while (barrier && errno == EINTR);
        if (barrier) goto failed;
        NV_REPOSITORY_EVENT("directory-synced", parent);
    }
    if (path_check(owner, &path)) goto failed;
    result->outcome = NV_ROOT_INSTALL_VERIFIED;
    goto done;
failed:
    result->error = errno;
    if (result->namespace_changed || result->error == EIO || result->error == ESTALE) result->outcome = NV_ROOT_INSTALL_UNCERTAIN;
done:
    if (fd >= 0) close(fd);
    path_close(&path);
    if (nv_root_validate(owner)) { result->root_lost = 1; result->error = errno; result->outcome = NV_ROOT_INSTALL_UNCERTAIN; }
}

void nv_root_make_directory(NVRootOwner *owner, const char *relative, NVRootInstallResult *result) {
    make_directory(owner, relative, result, 0);
}
void nv_root_create_directory(NVRootOwner *owner, const char *relative, NVRootInstallResult *result) {
    make_directory(owner, relative, result, 1);
}

static int write_stage(int fd, const uint8_t *bytes, uint64_t count) {
    NV_REPOSITORY_EVENT("stage-created", fd);
    for (uint64_t offset = 0; offset < count;) {
        ssize_t amount = write(fd, bytes + offset, (size_t)(count - offset));
        if (amount < 0) { if (errno == EINTR) continue; return -1; }
        if (!amount) { errno = EIO; return -1; }
        offset += (uint64_t)amount;
        NV_REPOSITORY_EVENT("stage-written", fd);
    }
    return 0;
}

static void prepare_stage(NVRootOwner *owner, const char *stage, const uint8_t *bytes,
                          uint64_t count, uint64_t expected[9], int *retained, NVRootInstallResult *result) {
    *result = (NVRootInstallResult){.outcome = NV_ROOT_INSTALL_NO_EFFECT};
    if (nv_root_validate(owner)) { result->error = errno; result->root_lost = 1; return; }
    if (!count || count > NV_PROTOCOL_BYTES || !file_component(stage) || strncmp(stage, ".nv-stage-", 10) || strchr(stage, '/')) { result->error = EINVAL; return; }
    int fd = openat(owner->directory, stage, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { result->error = errno; return; }
    struct stat verified, held, named;
    if (write_stage(fd, bytes, count) || verify_fd(fd, bytes, count, &verified)) goto failed;
    NV_REPOSITORY_EVENT("stage-verified", fd);
    if (file_barrier(fd) || fstat(fd, &held) ||
        fstatat(owner->directory, stage, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    if (!S_ISREG(named.st_mode) || named.st_nlink != 1 || held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; goto failed; }
    if (nv_root_validate(owner)) { result->root_lost = 1; goto failed; }
    file_words(&held, expected);
    result->outcome = NV_ROOT_INSTALL_VERIFIED;
    result->stage_retained = 1;
    if (retained) *retained = fd; else close(fd);
    return;
failed:
    result->error = errno;
    if (result->error == EIO || result->error == ESTALE || result->root_lost) result->outcome = NV_ROOT_INSTALL_UNCERTAIN;
    if (cleanup_stage(owner, stage, fd)) { result->stage_retained = 1; result->cleanup_error = errno; }
    close(fd);
}

struct NVRootPreparedStage { NVRootOwner *owner; char *name; int descriptor; uint64_t expected[9]; };

NVRootPreparedStage *nv_root_prepare_owned_stage(NVRootOwner *owner, const char *name,
    const uint8_t *bytes, uint64_t count, NVRootInstallResult *result) {
    NVRootPreparedStage *stage = calloc(1, sizeof(*stage));
    if (!stage) { *result = (NVRootInstallResult){.error=errno}; return NULL; }
    stage->descriptor = -1; stage->owner = owner; stage->name = strdup(name);
    if (!stage->name) { *result = (NVRootInstallResult){.error=errno}; free(stage); return NULL; }
    prepare_stage(owner, name, bytes, count, stage->expected, &stage->descriptor, result);
    if (result->outcome != NV_ROOT_INSTALL_VERIFIED) { nv_root_prepared_stage_close(stage); return NULL; }
    return stage;
}

void nv_root_prepared_stage_close(NVRootPreparedStage *stage) {
    if (!stage) return;
    if (stage->descriptor >= 0) close(stage->descriptor);
    free(stage->name); free(stage);
}

static void install_stage(NVRootOwner *owner, const char *relative, const char *stage,
                          NVRootPreparedStage *held, const uint8_t *bytes, uint64_t count,
                          NVRootInstallResult *result) {
    const uint64_t *expected = held ? held->expected : NULL;
    *result = (NVRootInstallResult){.outcome = NV_ROOT_INSTALL_NO_EFFECT};
    result->stage_retained = expected ? 1 : 0;
    if (nv_root_validate(owner)) { result->error = errno; result->root_lost = 1; return; }
    if (!count || count > NV_PROTOCOL_BYTES || !file_component(stage) || strncmp(stage, ".nv-stage-", 10) || strchr(stage, '/')) { result->error = EINVAL; return; }
    FilePath path; int stagefd = -1, finalfd = -1, stage_owned = 0, renamed = 0, uncertain = 0;
    struct stat staged = {0}, verified;
    if (path_open(owner, relative, expected ? 0 : 1, &path, &result->namespace_changed)) goto failed;
    if (path_check(owner, &path)) goto failed;
    if (held && (held->owner != owner || strcmp(held->name, stage))) { errno = ESTALE; goto failed; }
    stagefd = held ? fcntl(held->descriptor, F_DUPFD_CLOEXEC, 0)
                  : openat(owner->directory, stage, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (expected ? 0 : O_CREAT | O_EXCL), 0600);
    if (stagefd < 0) goto failed;
    stage_owned = expected ? 0 : 1;
    if (fstat(stagefd, &staged)) goto failed;
    if (expected) {
        uint64_t actual[9]; file_words(&staged, actual);
        /* The live descriptor binds identity across metadata-only provider changes. */
        if (memcmp(actual, expected, 5 * sizeof(uint64_t))) { errno = ESTALE; goto failed; }
    }
    if (!expected && write_stage(stagefd, bytes, count)) goto failed;
    if (verify_fd(stagefd, bytes, count, &verified)) goto failed;
    stage_owned = 1;
    NV_REPOSITORY_EVENT("stage-verified", stagefd);
    if (file_barrier(stagefd) || path_check(owner, &path)) goto failed;
    if (fstat(stagefd, &staged)) goto failed;
    /* Recheck the owned source immediately before the indivisible namespace operation. */
    struct stat named;
    if (fstatat(owner->directory, stage, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    if (named.st_dev != staged.st_dev || named.st_ino != staged.st_ino || !S_ISREG(named.st_mode) || named.st_nlink != 1) { errno = ESTALE; goto failed; }
    uncertain = 1;
    if (exclusive_rename(owner->directory, stage, path.fd[path.count-1], path.leaf)) {
        if (errno != EEXIST) goto failed;
        uncertain = 0;
        result->existing = 1;
    } else { renamed = 1; result->namespace_changed = 1; result->stage_retained = 0; NV_REPOSITORY_EVENT("name-installed", path.fd[path.count-1]); }
    finalfd = openat(path.fd[path.count-1], path.leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (finalfd < 0 || verify_fd(finalfd, bytes, count, &verified)) goto failed;
    uncertain = 1;
    if (fstat(stagefd, &staged)) goto failed;
    if (renamed && (verified.st_dev != staged.st_dev || verified.st_ino != staged.st_ino)) { errno = ESTALE; goto failed; }
    NV_REPOSITORY_EVENT("final-verified", finalfd);
    if (file_barrier(finalfd)) goto failed;
    if (!renamed) {
        if (cleanup_stage(owner, stage, stagefd)) { result->cleanup_error = errno; goto failed; }
        stage_owned = 0;
    }
    for (unsigned i = path.count; i > 0; i--) {
        int barrier;
        do { barrier = fsync(path.fd[i-1]); } while (barrier && errno == EINTR);
        if (barrier) goto failed;
        NV_REPOSITORY_EVENT("directory-synced", path.fd[i-1]);
    }
    /* The final hardware-cache request follows the complete namespace barrier sequence. */
    if (file_barrier(finalfd) || path_check(owner, &path)) goto failed;
    if (fstatat(path.fd[path.count-1], path.leaf, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    uint64_t a[9], b[9]; file_words(&verified, a); file_words(&named, b);
    if (memcmp(a, b, sizeof(a))) { errno = ESTALE; goto failed; }
    result->outcome = NV_ROOT_INSTALL_VERIFIED;
    NV_REPOSITORY_EVENT("installation-verified", finalfd);
    goto done;
failed:
    result->error = errno;
    /* A lost rename return or later barrier failure preserves the exact-input retry obligation. */
    if (uncertain || renamed || result->namespace_changed || result->error == EIO || result->error == ESTALE) result->outcome = NV_ROOT_INSTALL_UNCERTAIN;
done:
    if (stage_owned && !renamed) {
        if (cleanup_stage(owner, stage, stagefd)) { result->stage_retained = 1; result->cleanup_error = errno; }
        else { result->stage_retained = 0; }
    }
    if (stagefd >= 0) close(stagefd);
    if (finalfd >= 0) close(finalfd);
    path_close(&path);
    if (nv_root_validate(owner)) {
        result->root_lost = 1;
        if (!result->error) result->error = errno;
        result->outcome = NV_ROOT_INSTALL_UNCERTAIN;
    }
}

void nv_root_install(NVRootOwner *owner, const char *relative, const char *stage,
                     const uint8_t *bytes, uint64_t count, NVRootInstallResult *result) {
    install_stage(owner, relative, stage, NULL, bytes, count, result);
}

void nv_root_install_owned_stage(NVRootOwner *owner, const char *relative, NVRootPreparedStage *stage,
    const uint8_t *bytes, uint64_t count, NVRootInstallResult *result) {
    if (!stage) { *result=(NVRootInstallResult){.error=EINVAL}; return; }
    install_stage(owner, relative, stage->name, stage, bytes, count, result);
}
