#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "NVProjectionFiles.h"
#include "NVRepositoryRootInternal.h"
#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <sys/vnode.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <copyfile.h>
#include <sys/acl.h>
#include <stdio.h>
#else
#include <stdio.h>
#include <sys/syscall.h>
#endif

#ifndef NV_PROJECTION_EVENT
#define NV_PROJECTION_EVENT(name, fd) ((void)(fd))
#endif
#define NV_PROJECTION_MAX_ATTRIBUTE (64U * 1024 * 1024)

static int projection_leaf(const char *leaf) {
    size_t length = strnlen(leaf, 256);
    return length && length < 256 && !strchr(leaf, '/') &&
        strcmp(leaf, ".") && strcmp(leaf, "..");
}

static void projection_words(const struct stat *st, uint64_t words[9]) {
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

static int projection_expected(const struct stat *st, const uint64_t expected[9]) {
    uint64_t actual[9]; projection_words(st, actual);
    if (memcmp(actual, expected, sizeof(actual))) { errno = ESTALE; return -1; }
    return 0;
}

static int projection_rename_exclusive(int from, const char *source, int to, const char *destination) {
#if defined(__APPLE__)
    return renameatx_np(from, source, to, destination, RENAME_EXCL);
#elif defined(SYS_renameat2)
    return (int)syscall(SYS_renameat2, from, source, to, destination, 1U);
#else
    (void)from; (void)source; (void)to; (void)destination;
    errno = ENOTSUP; return -1;
#endif
}

#ifndef NV_PROJECTION_SOURCE_RENAME
#define NV_PROJECTION_SOURCE_RENAME projection_rename_exclusive
#endif

static ssize_t projection_xattr(int fd, const char *name, void *bytes, size_t count) {
#if defined(__APPLE__)
    return fgetxattr(fd, name, bytes, count, 0, 0);
#else
    return fgetxattr(fd, name, bytes, count);
#endif
}

static int projection_attribute(int fd, const char *name, NVProjectionAttribute *value) {
    ssize_t count = projection_xattr(fd, name, NULL, 0);
    if (count < 0) {
#if defined(__APPLE__)
        if (errno == ENOATTR) return 0;
#else
        if (errno == ENODATA) return 0;
#endif
        if (errno == ENOTSUP) { value->state = 2; return 0; }
        return -1;
    }
    if ((uint64_t)count > NV_PROJECTION_MAX_ATTRIBUTE) { errno = EFBIG; return -1; }
    value->bytes = malloc(count ? (size_t)count : 1);
    if (!value->bytes) return -1;
    /* Even empty values receive a real read, so removal cannot become empty presence. */
    ssize_t actual = projection_xattr(fd, name, value->bytes, count ? (size_t)count : 1);
    if (actual < 0) return -1;
    if (actual != count) { errno = ESTALE; return -1; }
    value->count = (uint32_t)count; value->state = 1;
    return 0;
}

void nv_projection_read_close(NVProjectionRead *read) {
    if (!read) return;
    free(read->bytes); free(read->encoding.bytes); free(read->tags.bytes);
    free(read->finder_tags.bytes); free(read->stamp.bytes); free(read);
}

struct NVProjectionStage {
    NVRootOwner *owner;
    dev_t root_device;
    ino_t root_inode;
    int directory, descriptor, prepared, whole_seconds;
    char *leaf, *source_leaf;
    uint64_t expected[9], source_words[9];
    int stamp_error, finder_tags_error;
};

static int projection_barrier(int fd) {
    int result;
    do { result = fsync(fd); } while (result && errno == EINTR);
    if (result) return -1;
#if defined(__APPLE__)
    do { result = fcntl(fd, F_FULLFSYNC); } while (result && errno == EINTR);
#endif
    return result;
}

static int projection_value_valid(NVProjectionAttributeValue value) {
    return (value.present == 0 && value.count == 0) ||
        (value.present == 1 && value.count <= NV_PROJECTION_MAX_ATTRIBUTE && (value.bytes || !value.count));
}

static int projection_metadata_valid(const NVProjectionMetadata *value) {
    return value && value->permissions <= 0777 && (value->has_birth == 0 || value->has_birth == 1) &&
        value->encoding.present == 1 && value->tags.present == 1 &&
        value->birth_nanoseconds < 1000000000 && value->modified_nanoseconds < 1000000000 &&
        projection_value_valid(value->encoding) && projection_value_valid(value->tags) &&
        projection_value_valid(value->finder_tags) && projection_value_valid(value->stamp);
}

static int projection_set_attribute(int fd, const char *name, NVProjectionAttributeValue value) {
    if (!value.present) {
#if defined(__APPLE__)
        int removed = fremovexattr(fd, name, 0);
        if (removed && errno == ENOATTR) return 0;
#else
        int removed = fremovexattr(fd, name);
        if (removed && errno == ENODATA) return 0;
#endif
        return removed;
    }
    const uint8_t empty = 0;
#if defined(__APPLE__)
    return fsetxattr(fd, name, value.count ? value.bytes : &empty, value.count, 0, 0);
#else
    return fsetxattr(fd, name, value.count ? value.bytes : &empty, value.count, 0);
#endif
}

static int projection_check_attribute(int fd, const char *name, NVProjectionAttributeValue expected) {
    NVProjectionAttribute value = {0};
    int result = projection_attribute(fd, name, &value);
    if (!result && (value.state != expected.present || value.count != expected.count ||
        (value.count && memcmp(value.bytes, expected.bytes, value.count)))) { errno = ESTALE; result = -1; }
    int saved = errno; free(value.bytes); errno = saved; return result;
}

#if defined(__APPLE__)
#define NV_PROJECTION_ENCODING "com.apple.TextEncoding"
#define NV_PROJECTION_TAGS "com.apple.metadata:kMDItemOMUserTags"
#define NV_PROJECTION_FINDER_TAGS "com.apple.metadata:_kMDItemUserTags"
#define NV_PROJECTION_STAMP "org.notationalvelocity.projection#S"
#else
#define NV_PROJECTION_ENCODING "user.com.apple.TextEncoding"
#define NV_PROJECTION_TAGS "user.com.apple.metadata:kMDItemOMUserTags"
#define NV_PROJECTION_FINDER_TAGS "user.com.apple.metadata:_kMDItemUserTags"
#define NV_PROJECTION_STAMP "user.org.notationalvelocity.projection#S"
#endif

static int projection_set_dates(int fd, const NVProjectionMetadata *value) {
#if defined(__APPLE__)
    if (value->has_birth) {
        struct attrlist attributes = {0}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
        attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
        struct { struct timespec creation, modification; } dates = {
            { value->birth_seconds, (long)value->birth_nanoseconds },
            { value->modified_seconds, (long)value->modified_nanoseconds }
        };
        return fsetattrlist(fd, &attributes, &dates, sizeof(dates), 0);
    }
#else
    if (value->has_birth) { errno = ENOTSUP; return -1; }
#endif
    struct timespec times[2] = {{0, UTIME_OMIT}, {value->modified_seconds, (long)value->modified_nanoseconds}};
    return futimens(fd, times);
}

/* HFS+/HFSX stores whole seconds; other qualified adapters retain exact nanoseconds. */
static int projection_date_precision(int directory, int *whole_seconds) {
    *whole_seconds = 0;
#if defined(__APPLE__)
    struct statfs volume;
    if (fstatfs(directory, &volume)) return -1;
    *whole_seconds = strcmp(volume.f_fstypename, "hfs") == 0;
#else
    (void)directory;
#endif
    return 0;
}

/* Checks the requested dates in the stage volume's qualified representation. */
static int projection_dates_match(const struct stat *observed, const NVProjectionMetadata *metadata, int whole_seconds) {
    long modified = whole_seconds ? 0 : (long)metadata->modified_nanoseconds;
#if defined(__APPLE__)
    long birth = whole_seconds ? 0 : (long)metadata->birth_nanoseconds;
    return observed->st_mtimespec.tv_sec == metadata->modified_seconds && observed->st_mtimespec.tv_nsec == modified &&
        (!metadata->has_birth || (observed->st_birthtimespec.tv_sec == metadata->birth_seconds && observed->st_birthtimespec.tv_nsec == birth));
#else
    return observed->st_mtim.tv_sec == metadata->modified_seconds && observed->st_mtim.tv_nsec == modified;
#endif
}

static int projection_verify_output(int fd, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, int whole_seconds, int stamp_error, int finder_error, struct stat *verified) {
    struct stat before, after;
    if (fstat(fd, &before)) return -1;
    if (!S_ISREG(before.st_mode) || before.st_nlink != 1 || before.st_size < 0 ||
        (uint64_t)before.st_size != count || (uint32_t)(before.st_mode & 07777) != metadata->permissions) {
        errno = ESTALE; return -1;
    }
    uint8_t buffer[16384];
    for (uint64_t offset = 0; offset < count;) {
        size_t request = (size_t)(count - offset > sizeof(buffer) ? sizeof(buffer) : count - offset);
        ssize_t got = pread(fd, buffer, request, (off_t)offset);
        if (got < 0) { if (errno == EINTR) continue; return -1; }
        if (!got || memcmp(buffer, bytes + offset, (size_t)got)) { errno = ESTALE; return -1; }
        offset += (uint64_t)got;
    }
    if (projection_check_attribute(fd, NV_PROJECTION_ENCODING, metadata->encoding) ||
        projection_check_attribute(fd, NV_PROJECTION_TAGS, metadata->tags) ||
        (!stamp_error && projection_check_attribute(fd, NV_PROJECTION_STAMP, metadata->stamp)) ||
        (!finder_error && projection_check_attribute(fd, NV_PROJECTION_FINDER_TAGS, metadata->finder_tags))) return -1;
    if (!projection_dates_match(&before, metadata, whole_seconds)) { errno = ESTALE; return -1; }
    uint64_t expected[9]; projection_words(&before, expected);
    if (fstat(fd, &after) || projection_expected(&after, expected)) return -1;
    if (!projection_dates_match(&after, metadata, whole_seconds)) { errno = ESTALE; return -1; }
    *verified = after; return 0;
}

static int projection_stage_named(NVProjectionStage *stage) {
    struct stat held, named;
    if (fstat(stage->descriptor, &held) || fstatat(stage->directory, stage->leaf, &named, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISREG(named.st_mode) || named.st_nlink != 1 || named.st_dev != held.st_dev || named.st_ino != held.st_ino) {
        errno = ESTALE; return -1;
    }
    return 0;
}

void nv_projection_stage_close(NVProjectionStage *stage) {
    if (!stage) return;
    if (stage->descriptor >= 0) close(stage->descriptor);
    if (stage->directory >= 0) close(stage->directory);
    free(stage->leaf); free(stage->source_leaf); free(stage);
}

static NVProjectionStage *projection_prepare(NVRootOwner *owner, int private_directory, int metadata_source,
    const char *leaf, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect) {
    *effect = (NVProjectionEffect){0};
    if (nv_root_validate(owner)) { effect->error = errno; effect->root_lost = 1; return NULL; }
    if (!projection_leaf(leaf) || !projection_metadata_valid(metadata) ||
        count > INT64_MAX || count > SIZE_MAX || (count && !bytes)) { effect->error = EINVAL; return NULL; }
    struct stat directory;
    if (fstat(private_directory, &directory)) { effect->error = errno; return NULL; }
    if (!S_ISDIR(directory.st_mode) || directory.st_uid != geteuid() || (directory.st_mode & 0077) ||
        directory.st_dev != owner->device || directory.st_ino == owner->inode) { effect->error = EACCES; return NULL; }
    NVProjectionStage *stage = calloc(1, sizeof(*stage));
    if (!stage) { effect->error = errno; return NULL; }
    stage->descriptor = -1; stage->directory = -1; stage->owner = owner;
    stage->root_device = owner->device; stage->root_inode = owner->inode;
    if (projection_date_precision(private_directory, &stage->whole_seconds)) goto unowned;
    stage->leaf = strdup(leaf);
    if (!stage->leaf) goto unowned;
    stage->directory = fcntl(private_directory, F_DUPFD_CLOEXEC, 0);
    if (stage->directory < 0) goto unowned;
    stage->descriptor = openat(stage->directory, leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (stage->descriptor < 0) goto unowned;
    effect->outcome = NV_PROJECTION_UNCERTAIN;
    NV_PROJECTION_EVENT("stage-created", stage->descriptor);
    for (uint64_t offset = 0; offset < count;) {
        size_t amount = (size_t)(count - offset > 1024 * 1024 ? 1024 * 1024 : count - offset);
        ssize_t written = write(stage->descriptor, bytes + offset, amount);
        if (written < 0) { if (errno == EINTR) continue; goto failed; }
        if (!written) { errno = EIO; goto failed; }
        offset += (uint64_t)written;
    }
    if (metadata_source >= 0) {
#if defined(__APPLE__)
        if (fcopyfile(metadata_source, stage->descriptor, NULL, COPYFILE_METADATA)) goto failed;
#else
        errno = ENOTSUP; goto failed;
#endif
    }
    if (fchmod(stage->descriptor, (mode_t)metadata->permissions) ||
        projection_set_attribute(stage->descriptor, NV_PROJECTION_ENCODING, metadata->encoding) ||
        projection_set_attribute(stage->descriptor, NV_PROJECTION_TAGS, metadata->tags)) goto failed;
    if (projection_set_attribute(stage->descriptor, NV_PROJECTION_STAMP, metadata->stamp)) stage->stamp_error = errno;
    if (projection_set_attribute(stage->descriptor, NV_PROJECTION_FINDER_TAGS, metadata->finder_tags)) stage->finder_tags_error = errno;
    if (projection_set_dates(stage->descriptor, metadata)) goto failed;
    NV_PROJECTION_EVENT("stage-prepared", stage->descriptor);
    if (projection_barrier(stage->descriptor)) goto failed;
    struct stat verified;
    if (projection_verify_output(stage->descriptor, bytes, count, metadata, stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &verified) ||
        projection_stage_named(stage)) goto failed;
    if (nv_root_validate(owner)) { effect->root_lost = 1; goto failed; }
    projection_words(&verified, stage->expected); stage->prepared = 1;
    effect->outcome = NV_PROJECTION_STAGED;
    effect->stamp_error = stage->stamp_error; effect->finder_tags_error = stage->finder_tags_error;
    return stage;
unowned:
    effect->error = errno; nv_projection_stage_close(stage); return NULL;
failed:
    effect->error = errno; effect->stamp_error = stage->stamp_error; effect->finder_tags_error = stage->finder_tags_error;
    if (nv_root_validate(owner)) effect->root_lost = 1;
    return stage;
}

NVProjectionStage *nv_projection_prepare(NVRootOwner *owner, int private_directory,
    const char *leaf, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect) {
    return projection_prepare(owner, private_directory, -1, leaf, bytes, count, metadata, effect);
}

/* Compares complete bytes through the open file, distinguishing changed content from I/O failure. */
static int projection_equal_bytes(int fd, const struct stat *observed, const uint8_t *bytes, uint64_t count) {
    if (observed->st_size < 0) { errno = EOVERFLOW; return -1; }
    if ((uint64_t)observed->st_size != count) return 0;
    uint8_t buffer[16384];
    for (uint64_t offset = 0; offset < count;) {
        size_t request = (size_t)(count - offset > sizeof(buffer) ? sizeof(buffer) : count - offset);
        ssize_t got = pread(fd, buffer, request, (off_t)offset);
        if (got < 0) { if (errno == EINTR) continue; return -1; }
        if (!got) { errno = ESTALE; return -1; }
        if (memcmp(buffer, bytes + offset, (size_t)got)) return 0;
        offset += (uint64_t)got;
    }
    return 1;
}

/* Holds the exact named regular file through a bracketed content comparison. */
static int projection_open_previous(NVRootOwner *owner, const char *leaf, const uint64_t expected[9],
    const uint8_t *bytes, uint64_t count, struct stat *observed) {
    if (!projection_leaf(leaf) || !expected || expected[3] != count || count > INT64_MAX ||
        count > SIZE_MAX || (count && !bytes)) { errno = EINVAL; return -1; }
    int fd = openat(owner->directory, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat named;
    if (fstat(fd, observed)) goto failed;
    if (!S_ISREG(observed->st_mode) || observed->st_nlink != 1) { errno = ESTALE; goto failed; }
    if (projection_expected(observed, expected)) goto failed;
    int equal = projection_equal_bytes(fd, observed, bytes, count);
    if (equal <= 0) { if (!equal) errno = ESTALE; goto failed; }
    if (fstat(fd, observed) || projection_expected(observed, expected) ||
        fstatat(owner->directory, leaf, &named, AT_SYMLINK_NOFOLLOW) || projection_expected(&named, expected)) goto failed;
    return fd;
failed:;
    int saved = errno; close(fd); errno = saved; return -1;
}

NVProjectionStage *nv_projection_prepare_replacement(NVRootOwner *owner, int private_directory,
    const char *leaf, const char *destination, const uint64_t expected[9],
    const uint8_t *previous, uint64_t previous_count, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect) {
    *effect = (NVProjectionEffect){0};
    if (nv_root_validate(owner)) { effect->error = errno; effect->root_lost = 1; return NULL; }
    if (!projection_metadata_valid(metadata)) { effect->error = EINVAL; return NULL; }
    struct stat original, after;
    int source = projection_open_previous(owner, destination, expected, previous, previous_count, &original);
    if (source < 0) { effect->error = errno; return NULL; }
    if ((uint32_t)(original.st_mode & 07777) != metadata->permissions) {
        close(source); effect->error = ESTALE; return NULL;
    }
    NVProjectionStage *stage = projection_prepare(owner, private_directory, source, leaf, bytes, count, metadata, effect);
    if (effect->outcome == NV_PROJECTION_STAGED) {
        stage->source_leaf = strdup(destination);
        if (!stage->source_leaf || fstat(source, &after) || projection_expected(&after, expected)) {
            stage->prepared = 0; effect->outcome = NV_PROJECTION_UNCERTAIN; effect->error = errno;
        } else {
            memcpy(stage->source_words, expected, sizeof(stage->source_words));
        }
    }
    close(source); return stage;
}

/* Shares exact post-install checks between exclusive creation and Foundation replacement. */
static void projection_finish_install(NVRootOwner *owner, NVProjectionStage *stage, const char *destination,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata, NVProjectionEffect *effect) {
    struct stat held, named;
    NV_PROJECTION_EVENT("projection-installed", stage->descriptor);
    if (fstat(stage->descriptor, &held) || fstatat(owner->directory, destination, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    if (!S_ISREG(named.st_mode) || held.st_dev != named.st_dev || held.st_ino != named.st_ino || named.st_nlink != 1) {
        errno = ESTALE; goto failed;
    }
    if (projection_barrier(stage->descriptor)) goto failed;
    int barrier;
    do { barrier = fsync(owner->directory); } while (barrier && errno == EINTR);
    if (barrier) effect->directory_sync_error = errno;
    NV_PROJECTION_EVENT("projection-final-check", stage->descriptor);
    if (nv_root_validate(owner)) { effect->root_lost = 1; goto failed; }
    /* Exact readback after synchronization also checks metadata on coarse-clock filesystems. */
    if (projection_verify_output(stage->descriptor, bytes, count, metadata,
        stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) goto failed;
    if (fstatat(owner->directory, destination, &named, AT_SYMLINK_NOFOLLOW)) goto failed;
    uint64_t expected[9]; projection_words(&held, expected);
    if (projection_expected(&named, expected)) goto failed;
    memcpy(effect->installed_words, expected, sizeof(expected));
#if defined(__APPLE__)
    effect->installed_has_birth = 1;
    effect->installed_birth_seconds = (int64_t)held.st_birthtimespec.tv_sec;
    effect->installed_birth_nanoseconds = (uint32_t)held.st_birthtimespec.tv_nsec;
#endif
    effect->outcome = NV_PROJECTION_INSTALLED; return;
failed:
    effect->error = errno;
    if (nv_root_validate(owner)) effect->root_lost = 1;
}

/* Installs a stage after its operation-specific source and ownership checks. */
static int projection_install_checked(NVRootOwner *owner, NVProjectionStage *stage, const char *destination,
    NVProjectionEffect *effect) {
    NV_PROJECTION_EVENT("before-exclusive-create", stage->descriptor);
    int renamed = projection_rename_exclusive(stage->directory, stage->leaf, owner->directory, destination);
    if (renamed) {
        int saved = errno;
        if (saved != EEXIST || projection_stage_named(stage)) effect->outcome = NV_PROJECTION_UNCERTAIN;
        errno = saved; goto failed;
    }
    stage->prepared = 0; effect->outcome = NV_PROJECTION_UNCERTAIN;
    return 1;
failed:
    effect->error = errno;
    if (nv_root_validate(owner)) effect->root_lost = 1;
    return 0;
}

void nv_projection_create(NVRootOwner *owner, NVProjectionStage *stage, const char *destination,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata, NVProjectionEffect *effect) {
    *effect = (NVProjectionEffect){0};
    if (!stage || stage->owner != owner || stage->root_device != owner->device || stage->root_inode != owner->inode ||
        !stage->prepared || stage->source_leaf || !projection_leaf(destination) ||
        !projection_metadata_valid(metadata) || count > INT64_MAX || count > SIZE_MAX || (count && !bytes)) {
        effect->error = EINVAL; return;
    }
    effect->outcome = NV_PROJECTION_STAGED;
    effect->stamp_error = stage->stamp_error; effect->finder_tags_error = stage->finder_tags_error;
    if (nv_root_validate(owner)) { effect->root_lost = 1; goto failed; }
    struct stat held;
    if (fstat(stage->descriptor, &held) || projection_expected(&held, stage->expected) ||
        projection_stage_named(stage) || projection_verify_output(stage->descriptor, bytes, count, metadata,
            stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) goto failed;
    if (projection_install_checked(owner, stage, destination, effect))
        projection_finish_install(owner, stage, destination, bytes, count, metadata, effect);
    return;
failed:
    effect->error = errno;
    if (nv_root_validate(owner)) effect->root_lost = 1;
}

/* Observes and compares the actual displaced item, retaining its exact named revision. */
static void projection_check_backup(NVRootOwner *owner, const char *backup,
    const uint8_t *previous, uint64_t count, NVProjectionReplacementResult *result) {
    int fd = openat(owner->directory, backup, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { result->backup_error = errno; return; }
    struct stat before, after, named;
    if (fstat(fd, &before)) goto failed;
    if (!S_ISREG(before.st_mode) || before.st_nlink != 1) { errno = ESTALE; goto failed; }
    int equal = projection_equal_bytes(fd, &before, previous, count);
    if (equal < 0) goto failed;
    projection_words(&before, result->backup_words);
    NV_PROJECTION_EVENT("replacement-backup-read", fd);
    if (fstat(fd, &after) || projection_expected(&after, result->backup_words)) goto failed;
    NV_PROJECTION_EVENT("before-backup-name-check", fd);
    if (fstatat(owner->directory, backup, &named, AT_SYMLINK_NOFOLLOW) ||
        projection_expected(&named, result->backup_words)) goto failed;
    result->backup_comparison = equal ? NV_PROJECTION_BACKUP_EXPECTED : NV_PROJECTION_BACKUP_CHANGED;
    close(fd); return;
failed:
    result->backup_error = errno; close(fd);
}

void nv_projection_replace(NVRootOwner *owner, NVProjectionStage *stage,
    const char *destination, const char *backup, const uint64_t expected[9],
    const uint8_t *previous, uint64_t previous_count, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, void *context, NVProjectionReplacementCall replace,
    NVProjectionReplacementResult *result) {
    *result = (NVProjectionReplacementResult){0};
    NVProjectionEffect *effect = &result->installation;
    if (!stage || stage->owner != owner || stage->root_device != owner->device || stage->root_inode != owner->inode ||
        !stage->prepared || !stage->source_leaf || !expected || !projection_leaf(destination) ||
        strcmp(stage->source_leaf, destination) || memcmp(stage->source_words, expected, sizeof(stage->source_words)) ||
        !projection_leaf(backup) || !strcmp(destination, backup) ||
        !replace || !projection_metadata_valid(metadata) || count > INT64_MAX || count > SIZE_MAX || (count && !bytes)) {
        effect->error = EINVAL; return;
    }
    effect->outcome = NV_PROJECTION_STAGED;
    effect->stamp_error = stage->stamp_error; effect->finder_tags_error = stage->finder_tags_error;
    if (nv_root_validate(owner)) { effect->root_lost = 1; goto failed; }
    struct stat held, occupied;
    if (fstat(stage->descriptor, &held) || projection_expected(&held, stage->expected) || projection_stage_named(stage) ||
        projection_verify_output(stage->descriptor, bytes, count, metadata, stage->whole_seconds,
            stage->stamp_error, stage->finder_tags_error, &held)) goto failed;
    int original = projection_open_previous(owner, destination, expected, previous, previous_count, &held);
    if (original < 0) goto failed;
    close(original);
    if (fstatat(owner->directory, backup, &occupied, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; goto failed; }
    if (errno != ENOENT) goto failed;
    NV_PROJECTION_EVENT("before-foundation-replace", stage->descriptor);
    stage->prepared = 0; effect->outcome = NV_PROJECTION_UNCERTAIN;
    int replacement_error = replace(context, stage->descriptor);
    /* The actual backup remains inspectable even after an ambiguous API return. */
    projection_check_backup(owner, backup, previous, previous_count, result);
    projection_finish_install(owner, stage, destination, bytes, count, metadata, effect);
    if (replacement_error || result->backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED) {
        effect->outcome = NV_PROJECTION_UNCERTAIN;
        if (replacement_error) effect->error = replacement_error;
        else if (!effect->error) effect->error = result->backup_error;
    }
    return;
failed:
    effect->error = errno;
    if (nv_root_validate(owner)) effect->root_lost = 1;
}

static int projection_read_at(NVRootOwner *owner, int directory, const char *leaf, const uint64_t expected[9],
                          uint64_t maximum, NVProjectionRead **output, int *retained) {
    *output = NULL;
    if (retained) *retained = -1;
    if (nv_root_validate(owner)) return -2;
    if (!projection_leaf(leaf)) { errno = EINVAL; return -1; }
    if (maximum > INT64_MAX || maximum > SIZE_MAX || expected[3] > maximum) { errno = EFBIG; return -1; }
    struct stat before, after;
    if (fstatat(directory, leaf, &before, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISREG(before.st_mode)) { errno = ENOTDIR; return -1; }
    if (before.st_nlink != 1) { errno = EMLINK; return -1; }
    if (projection_expected(&before, expected)) return -1;
#if defined(__APPLE__) && defined(SF_DATALESS)
    if (before.st_flags & SF_DATALESS) return 1;
#endif
    int fd = openat(directory, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    int result = -1;
    NVProjectionRead *read = calloc(1, sizeof(*read));
    if (!read) goto done;
    if (fstat(fd, &before) || projection_expected(&before, expected)) goto done;
    NV_PROJECTION_EVENT("opened", fd);
    read->count = expected[3];
    read->bytes = malloc(read->count ? (size_t)read->count : 1);
    if (!read->bytes) goto done;
    for (uint64_t offset = 0; offset < read->count;) {
        uint64_t remaining = read->count - offset;
        size_t requested = (size_t)(remaining > 1024 * 1024 ? 1024 * 1024 : remaining);
        ssize_t count = pread(fd, read->bytes + offset, requested, (off_t)offset);
        if (count < 0) { if (errno == EINTR) continue; goto done; }
        if (!count) { errno = ESTALE; goto done; }
        offset += (uint64_t)count;
    }
    NV_PROJECTION_EVENT("body-read", fd);
#if defined(__APPLE__)
#define NV_XATTR_PREFIX ""
#else
#define NV_XATTR_PREFIX "user."
#endif
    if (projection_attribute(fd, NV_XATTR_PREFIX "com.apple.TextEncoding", &read->encoding) ||
        projection_attribute(fd, NV_XATTR_PREFIX "com.apple.metadata:kMDItemOMUserTags", &read->tags) ||
        projection_attribute(fd, NV_XATTR_PREFIX "com.apple.metadata:_kMDItemUserTags", &read->finder_tags) ||
        projection_attribute(fd, NV_XATTR_PREFIX "org.notationalvelocity.projection#S", &read->stamp)) goto done;
    NV_PROJECTION_EVENT("metadata-read", fd);
    if (fstat(fd, &after) || projection_expected(&after, expected)) goto done;
    if (before.st_mode != after.st_mode) { errno = ESTALE; goto done; }
#if defined(__APPLE__)
    if (before.st_birthtimespec.tv_sec != after.st_birthtimespec.tv_sec ||
        before.st_birthtimespec.tv_nsec != after.st_birthtimespec.tv_nsec) { errno = ESTALE; goto done; }
    read->has_birth = 1; read->birth_seconds = after.st_birthtimespec.tv_sec;
    read->birth_nanoseconds = (uint32_t)after.st_birthtimespec.tv_nsec;
#endif
    read->permissions = (uint32_t)(after.st_mode & 07777);
    NV_PROJECTION_EVENT("before-name-check", fd);
    if (fstatat(directory, leaf, &after, AT_SYMLINK_NOFOLLOW) || projection_expected(&after, expected)) goto done;
    if (nv_root_validate(owner)) { result = -2; goto done; }
    memcpy(read->words, expected, sizeof(read->words));
    *output = read; read = NULL; result = 0;
    if (retained) { *retained = fd; fd = -1; }
done:;
    int saved = errno; nv_projection_read_close(read); if (fd >= 0) close(fd); errno = saved; return result;
}

int nv_projection_read(NVRootOwner *owner, const char *leaf, const uint64_t expected[9],
                       uint64_t maximum, NVProjectionRead **output) {
    return projection_read_at(owner, owner->directory, leaf, expected, maximum, output, NULL);
}

int nv_projection_read_retaining(NVRootOwner *owner, const char *leaf, const uint64_t expected[9],
                                uint64_t maximum, NVProjectionRead **output, int *descriptor) {
    if (!descriptor) { *output = NULL; errno = EINVAL; return -1; }
    return projection_read_at(owner, owner->directory, leaf, expected, maximum, output, descriptor);
}

static int projection_attribute_equal(NVProjectionAttribute a, NVProjectionAttribute b) {
    return a.state == b.state && a.count == b.count && (!a.count || !memcmp(a.bytes, b.bytes, a.count));
}

static int projection_observed_attribute_valid(NVProjectionAttribute a) {
    return ((a.state == 0 || a.state == 2) && !a.count) ||
        (a.state == 1 && a.count <= NV_PROJECTION_MAX_ATTRIBUTE && (!a.count || a.bytes));
}

/* A rename changes ctime; exact bytes and captured note metadata establish the moved state. */
static int projection_moved_equal(const NVProjectionRead *a, const NVProjectionRead *b) {
    return !memcmp(a->words, b->words, 7 * sizeof(uint64_t)) && a->count == b->count &&
        (!a->count || !memcmp(a->bytes, b->bytes, (size_t)a->count)) && a->permissions == b->permissions &&
        a->has_birth == b->has_birth && a->birth_seconds == b->birth_seconds && a->birth_nanoseconds == b->birth_nanoseconds &&
        projection_attribute_equal(a->encoding, b->encoding) && projection_attribute_equal(a->tags, b->tags) &&
        projection_attribute_equal(a->finder_tags, b->finder_tags) && projection_attribute_equal(a->stamp, b->stamp);
}

/* Reports the actual surviving names independently of an earlier syscall result. */
static int projection_source_names(NVRootOwner *owner, const char *source, const char *recovery,
    NVProjectionSourceResult *result) {
    struct stat st;
    int failure = 0;
    if (!fstatat(owner->directory, source, &st, AT_SYMLINK_NOFOLLOW)) {
        result->source_state = NV_PROJECTION_NAME_PRESENT; projection_words(&st, result->source_words);
    } else if (errno == ENOENT) result->source_state = NV_PROJECTION_NAME_ABSENT;
    else failure = errno;
    if (!fstatat(owner->directory, recovery, &st, AT_SYMLINK_NOFOLLOW)) {
        result->artifact_state = NV_PROJECTION_NAME_PRESENT; projection_words(&st, result->artifact_words);
    } else if (errno == ENOENT) result->artifact_state = NV_PROJECTION_NAME_ABSENT;
    else if (!failure) failure = errno;
    if (failure) { errno = failure; return -1; }
    return 0;
}

void nv_projection_quarantine_source(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int lease,
    void *context, NVProjectionSourceMoveNotice notify,
    NVProjectionSourceResult *result) {
    *result = (NVProjectionSourceResult){0};
    NVProjectionRead *before = NULL, *moved = NULL;
    if (!owner || !expected || lease < 0 || !projection_leaf(source) || !projection_leaf(recovery) || !strcmp(source, recovery) ||
        expected->count > SIZE_MAX || expected->count > INT64_MAX || maximum < expected->count || maximum > SIZE_MAX || maximum > INT64_MAX ||
        expected->words[3] != expected->count || (expected->count && !expected->bytes) ||
        !projection_observed_attribute_valid(expected->encoding) || !projection_observed_attribute_valid(expected->tags) ||
        !projection_observed_attribute_valid(expected->finder_tags) || !projection_observed_attribute_valid(expected->stamp) ||
        (expected->has_birth != 0 && expected->has_birth != 1) || expected->birth_nanoseconds >= 1000000000U) {
        result->error = EINVAL; return;
    }
    if (nv_root_validate(owner)) { result->error = errno; result->root_lost = 1; return; }
    int read = nv_projection_read(owner, source, expected->words, maximum, &before);
    if (read) { result->error = read == 1 ? EAGAIN : errno; goto done; }
    if (!projection_moved_equal(expected, before)) { result->error = ESTALE; goto done; }
    /* The caller retains this exact read descriptor from capture through return. */
    struct stat pinned, candidate;
    if (fstat(lease, &pinned) || projection_expected(&pinned, before->words)) { result->error = errno; goto done; }
    if (!fstatat(owner->directory, recovery, &candidate, AT_SYMLINK_NOFOLLOW)) { result->error = EEXIST; goto done; }
    if (errno != ENOENT) { result->error = errno; goto done; }
    NV_PROJECTION_EVENT("source-before-quarantine", lease);
    if (notify) notify(context, 0, 0);
    if (NV_PROJECTION_SOURCE_RENAME(owner->directory, source, owner->directory, recovery)) {
        result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->error = errno; goto done;
    }
    if (notify) notify(context, 0, 1);
    result->outcome = NV_PROJECTION_SOURCE_RETAINED;
    NV_PROJECTION_EVENT("source-quarantined", owner->directory);
    uint64_t actual[9];
    if (nv_root_snapshot(owner, recovery, actual)) { result->error = errno; goto done; }
    read = nv_projection_read(owner, recovery, actual, maximum, &moved);
    if (read) { result->error = read == 1 ? EAGAIN : errno; goto done; }
    if (projection_moved_equal(expected, moved)) {
        result->outcome = NV_PROJECTION_SOURCE_CAPTURED;
    } else {
        result->error = ESTALE;
        NV_PROJECTION_EVENT("source-before-restore", owner->directory);
        if (notify) notify(context, 1, 0);
        if (!NV_PROJECTION_SOURCE_RENAME(owner->directory, recovery, owner->directory, source)) {
            if (notify) notify(context, 1, 1);
            result->outcome = NV_PROJECTION_SOURCE_RESTORED;
        } else if (errno != EEXIST) {
            result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->error = errno;
        }
    }
done:
    NV_PROJECTION_EVENT("source-final-check", owner->directory);
    if (projection_source_names(owner, source, recovery, result)) {
        if (result->outcome != NV_PROJECTION_SOURCE_NO_EFFECT) result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN;
        result->error = errno;
    }
    if (result->outcome == NV_PROJECTION_SOURCE_CAPTURED &&
        (result->artifact_state != NV_PROJECTION_NAME_PRESENT || !moved || memcmp(result->artifact_words, moved->words, sizeof(moved->words)))) {
        result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->error = ESTALE;
    }
    if (result->outcome == NV_PROJECTION_SOURCE_RESTORED &&
        (result->source_state != NV_PROJECTION_NAME_PRESENT || !moved || memcmp(result->source_words, moved->words, 7 * sizeof(uint64_t)))) {
        result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->error = ESTALE;
    }
    if (result->outcome != NV_PROJECTION_SOURCE_NO_EFFECT && fsync(owner->directory)) result->directory_sync_error = errno;
    if (nv_root_validate(owner)) {
        result->root_lost = 1; result->error = errno;
        if (result->outcome != NV_PROJECTION_SOURCE_NO_EFFECT) result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN;
    }
    nv_projection_read_close(before); nv_projection_read_close(moved);
}

void nv_projection_relocate(NVRootOwner *owner, NVProjectionStage *stage,
    const char *source, const char *destination, const char *backup,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, int prepared_descriptor,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionRelocationResult *result) {
    *result = (NVProjectionRelocationResult){0};
    NVProjectionEffect *effect = &result->replacement.installation;
    int installed = 0;
    uint64_t captured_words[9] = {0};
    if (!owner || !stage || !expected || stage->owner != owner ||
        stage->root_device != owner->device || stage->root_inode != owner->inode || !stage->prepared ||
        !stage->source_leaf || !projection_leaf(source) || strcmp(stage->source_leaf, source) ||
        memcmp(stage->source_words, expected->words, sizeof(stage->source_words)) ||
        !projection_leaf(destination) || !strcmp(source, destination) || !projection_leaf(backup) ||
        !strcmp(source, backup) || !strcmp(destination, backup) ||
        !projection_metadata_valid(metadata) || count > INT64_MAX || count > SIZE_MAX || (count && !bytes)) {
        effect->error = EINVAL; return;
    }
    effect->outcome = NV_PROJECTION_STAGED;
    effect->stamp_error = stage->stamp_error; effect->finder_tags_error = stage->finder_tags_error;
    if (nv_root_validate(owner)) { effect->root_lost = 1; goto failed; }
    struct stat held, destination_state, granted_stage;
    if (fstat(prepared_descriptor, &granted_stage) || projection_expected(&granted_stage, stage->expected)) goto failed;
    if (fstat(stage->descriptor, &held) || projection_expected(&held, stage->expected) ||
        projection_stage_named(stage) || projection_verify_output(stage->descriptor, bytes, count, metadata,
            stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) goto failed;
    if (!fstatat(owner->directory, destination, &destination_state, AT_SYMLINK_NOFOLLOW)) {
        /* A single-link original can also be addressed by its new case/Unicode spelling. */
        if (projection_expected(&destination_state, expected->words)) { errno = EEXIST; goto failed; }
    } else if (errno != ENOENT) goto failed;
    NV_PROJECTION_EVENT("relocation-before-capture", descriptor);
    nv_projection_quarantine_source(owner, source, backup, expected, maximum, descriptor, NULL, NULL, &result->source);
    if (result->source.outcome != NV_PROJECTION_SOURCE_CAPTURED) {
        effect->error = result->source.error;
        if (result->source.outcome == NV_PROJECTION_SOURCE_RETAINED || result->source.outcome == NV_PROJECTION_SOURCE_UNCERTAIN)
            effect->outcome = NV_PROJECTION_UNCERTAIN;
        goto done;
    }
    memcpy(captured_words, result->source.artifact_words, sizeof(captured_words));
    NV_PROJECTION_EVENT("relocation-captured", descriptor);
    if (nv_root_validate(owner)) { effect->root_lost = 1; effect->outcome = NV_PROJECTION_UNCERTAIN; goto failed; }
    if (fstat(stage->descriptor, &held) || projection_expected(&held, stage->expected) ||
        projection_stage_named(stage) || projection_verify_output(stage->descriptor, bytes, count, metadata,
            stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) effect->error = errno;
    else installed = projection_install_checked(owner, stage, destination, effect);
    NV_PROJECTION_EVENT("relocation-after-install", descriptor);
    if (effect->outcome == NV_PROJECTION_STAGED) {
        /* Restoration preserves every late public occupant through exclusive installation. */
        if (!projection_rename_exclusive(owner->directory, backup, owner->directory, source)) {
            result->source.outcome = NV_PROJECTION_SOURCE_RESTORED;
            if (fsync(owner->directory)) result->source.directory_sync_error = errno;
        } else {
            result->source.outcome = NV_PROJECTION_SOURCE_RETAINED;
            result->source.error = errno;
        }
    } else {
        projection_check_backup(owner, backup, expected->bytes, expected->count, &result->replacement);
        if (result->replacement.backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED) {
            effect->outcome = NV_PROJECTION_UNCERTAIN;
            if (!effect->error) effect->error = result->replacement.backup_error;
        }
    }
done:
    NV_PROJECTION_EVENT("relocation-final", descriptor);
    if (projection_source_names(owner, source, backup, &result->source)) {
        result->source.error = errno;
        if (result->source.outcome != NV_PROJECTION_SOURCE_NO_EFFECT) result->source.outcome = NV_PROJECTION_SOURCE_UNCERTAIN;
    }
    if (result->source.outcome == NV_PROJECTION_SOURCE_CAPTURED &&
        (result->source.artifact_state != NV_PROJECTION_NAME_PRESENT ||
         memcmp(captured_words, result->source.artifact_words, sizeof(captured_words)))) {
        result->source.outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->source.error = ESTALE;
    }
    if (result->source.outcome == NV_PROJECTION_SOURCE_RESTORED &&
        (result->source.source_state != NV_PROJECTION_NAME_PRESENT ||
         memcmp(expected->words, result->source.source_words, 7 * sizeof(uint64_t)))) {
        result->source.outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->source.error = ESTALE;
    }
    if (installed) {
        projection_finish_install(owner, stage, destination, bytes, count, metadata, effect);
        if (result->replacement.backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED)
            effect->outcome = NV_PROJECTION_UNCERTAIN;
    }
    if (nv_root_validate(owner)) {
        result->source.root_lost = 1; effect->root_lost = 1; effect->error = errno;
        if (effect->outcome != NV_PROJECTION_STAGED) effect->outcome = NV_PROJECTION_UNCERTAIN;
    }
    return;
failed:
    effect->error = errno;
    goto done;
}

#ifndef NV_PROJECTION_CLEANUP_UNLINK
#define NV_PROJECTION_CLEANUP_UNLINK unlinkat
#endif
#ifndef NV_PROJECTION_CLEANUP_CAPTURE
#define NV_PROJECTION_CLEANUP_CAPTURE projection_rename_exclusive
#endif

/* The durable attempt's public recovery leaf also determines this retained directory. */
static int projection_cleanup_name(const char *artifact, char name[256]) {
    if (!projection_leaf(artifact)) { errno = EINVAL; return -1; }
    int count = snprintf(name, 256, "%s.cleanup", artifact);
    if (count < 0 || count >= 256) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

/* Verifies that a held child directory remains the same named member of the owned root. */
static int projection_cleanup_directory(NVRootOwner *owner, const char *name, int directory) {
    struct stat held, named;
    if (nv_root_validate(owner) || fstat(directory, &held) ||
        fstatat(owner->directory, name, &named, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISDIR(held.st_mode) || !held.st_nlink || held.st_uid != geteuid() || (held.st_mode & 0077) ||
        held.st_dev != owner->device || !S_ISDIR(named.st_mode) ||
        held.st_dev != named.st_dev || held.st_ino != named.st_ino) { errno = ESTALE; return -1; }
    return 0;
}

/* Establishes owner-only access before any source bytes enter the fresh directory. */
static int projection_cleanup_privacy(int directory) {
    if (fchmod(directory, 0700)) return -1;
#if defined(__APPLE__)
    acl_t empty = acl_init(0);
    if (!empty) return -1;
    int result = acl_set_fd(directory, empty), saved = errno;
    acl_free(empty); errno = saved;
    return result;
#else
    /* chmod clears the effective group/extended-ACL mask on POSIX ACL filesystems. */
    return 0;
#endif
}

int nv_projection_read_cleanup(NVRootOwner *owner, const char *artifact, uint64_t maximum,
    NVProjectionRead **output) {
    *output = NULL;
    char name[256];
    if (nv_root_validate(owner)) return -2;
    if (projection_cleanup_name(artifact, name)) return -1;
    int directory = openat(owner->directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return -1;
    int result = -1;
    struct stat st;
    if (projection_cleanup_directory(owner, name, directory) ||
        fstatat(directory, "item", &st, AT_SYMLINK_NOFOLLOW)) goto done;
    uint64_t words[9]; projection_words(&st, words);
    result = projection_read_at(owner, directory, "item", words, maximum, output, NULL);
    if (!result && projection_cleanup_directory(owner, name, directory)) {
        int saved = errno; nv_projection_read_close(*output); *output = NULL; errno = saved; result = -1;
    }
done:;
    int saved = errno; close(directory); errno = saved; return result;
}

static void projection_remove_source(NVRootOwner *owner, const char *artifact, const char *private_name,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    NVProjectionCleanupResult *result) {
    *result = (NVProjectionCleanupResult){0};
    NVProjectionRead *observed = NULL, *captured = NULL;
    int directory = -1;
    struct stat held, named;
    if (!owner || !expected || descriptor < 0 || !projection_leaf(artifact) || !projection_leaf(private_name) ||
        !strcmp(artifact, private_name) ||
        maximum < expected->count || maximum > SIZE_MAX || maximum > INT64_MAX ||
        expected->count > SIZE_MAX || expected->count > INT64_MAX || expected->words[3] != expected->count ||
        (expected->count && !expected->bytes) ||
        !projection_observed_attribute_valid(expected->encoding) || !projection_observed_attribute_valid(expected->tags) ||
        !projection_observed_attribute_valid(expected->finder_tags) || !projection_observed_attribute_valid(expected->stamp) ||
        (expected->has_birth != 0 && expected->has_birth != 1) || expected->birth_nanoseconds >= 1000000000U) {
        result->error = EINVAL; return;
    }
    if (nv_root_validate(owner)) { result->root_lost = 1; result->error = errno; return; }
    NV_PROJECTION_EVENT("source-cleanup-preflight", descriptor);
    int read = nv_projection_read(owner, artifact, expected->words, maximum, &observed);
    if (read) { result->error = read == 1 ? EAGAIN : errno; goto done; }
    if (!projection_moved_equal(expected, observed)) { result->error = ESTALE; goto done; }
    if (fstat(descriptor, &held) || projection_expected(&held, observed->words)) { result->error = errno; goto done; }
    NV_PROJECTION_EVENT("source-cleanup-checked", descriptor);
    if (nv_root_validate(owner)) { result->root_lost = 1; result->error = errno; goto done; }
    if (fstatat(owner->directory, artifact, &named, AT_SYMLINK_NOFOLLOW) || projection_expected(&named, observed->words)) {
        result->error = errno; goto done;
    }
    if (mkdirat(owner->directory, private_name, 0700)) {
        result->error = errno; goto done;
    }
    result->directory_created = 1;
    directory = openat(owner->directory, private_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0 || projection_cleanup_privacy(directory) ||
        projection_cleanup_directory(owner, private_name, directory) || fsync(directory) || fsync(owner->directory)) {
        result->error = errno; goto done;
    }
    NV_PROJECTION_EVENT("source-cleanup-before-capture", descriptor);
    result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN;
    if (NV_PROJECTION_CLEANUP_CAPTURE(owner->directory, artifact, directory, "item")) {
        result->error = errno; goto done;
    }
    NV_PROJECTION_EVENT("source-cleanup-captured", descriptor);
    if (fsync(directory) || fsync(owner->directory)) { result->error = errno; goto done; }
    if (projection_cleanup_directory(owner, private_name, directory) ||
        fstatat(directory, "item", &named, AT_SYMLINK_NOFOLLOW)) { result->error = errno; goto done; }
    uint64_t moved_words[9]; projection_words(&named, moved_words);
    read = projection_read_at(owner, directory, "item", moved_words, maximum, &captured, NULL);
    if (read || !projection_moved_equal(expected, captured)) {
        result->error = read ? (read == 1 ? EAGAIN : errno) : ESTALE;
        /* Restoration is add-only; another public occupant keeps its own name and bytes. */
        if (!projection_cleanup_directory(owner, private_name, directory) &&
            !projection_rename_exclusive(directory, "item", owner->directory, artifact)) {
            if (fsync(directory) || fsync(owner->directory)) result->directory_sync_error = errno;
        }
        goto done;
    }
    if (fstat(descriptor, &held) || projection_expected(&held, captured->words) ||
        projection_cleanup_directory(owner, private_name, directory)) { result->error = errno; goto done; }
    NV_PROJECTION_EVENT("source-cleanup-private-checked", descriptor);
    if (NV_PROJECTION_CLEANUP_UNLINK(directory, "item", 0)) {
        result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN; result->error = errno; goto done;
    }
    result->outcome = NV_PROJECTION_CLEANUP_REMOVED;
    NV_PROJECTION_EVENT("source-cleanup-unlinked", descriptor);
    if (fsync(directory) || fsync(owner->directory)) result->directory_sync_error = errno;
done:
    NV_PROJECTION_EVENT("source-cleanup-final", descriptor);
    if (!fstatat(owner->directory, artifact, &named, AT_SYMLINK_NOFOLLOW)) {
        result->artifact_state = NV_PROJECTION_NAME_PRESENT; projection_words(&named, result->artifact_words);
    } else if (errno == ENOENT) result->artifact_state = NV_PROJECTION_NAME_ABSENT;
    else { result->error = errno; if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT) result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN; }
    if (directory >= 0) {
        if (projection_cleanup_directory(owner, private_name, directory)) {
            result->error = errno;
            if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT) result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN;
        } else if (!fstatat(directory, "item", &named, AT_SYMLINK_NOFOLLOW)) {
            result->captured_state = NV_PROJECTION_NAME_PRESENT; projection_words(&named, result->captured_words);
        } else if (errno == ENOENT) result->captured_state = NV_PROJECTION_NAME_ABSENT;
        else {
            result->error = errno;
            if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT) result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN;
        }
    }
    if (result->outcome == NV_PROJECTION_CLEANUP_REMOVED &&
        (result->artifact_state != NV_PROJECTION_NAME_ABSENT || result->captured_state != NV_PROJECTION_NAME_ABSENT)) {
        result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN; result->error = ESTALE;
    }
    if (nv_root_validate(owner)) {
        result->root_lost = 1; result->error = errno;
        if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT) result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN;
    }
    if (directory >= 0) close(directory);
    nv_projection_read_close(observed); nv_projection_read_close(captured);
}

void nv_projection_remove_source(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, NVProjectionCleanupResult *result) {
    char name[256];
    if (projection_cleanup_name(recovery, name)) {
        *result = (NVProjectionCleanupResult){.error = errno}; return;
    }
    projection_remove_source(owner, source, name, expected, maximum, descriptor, result);
}
