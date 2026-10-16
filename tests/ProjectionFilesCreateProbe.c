/* Challenges the production exclusive installer through real native effects. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#include <sys/mount.h>
#endif
#include <unistd.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

static int fault, write_calls, root_fd, stage_fd, optional_hits, installed;
static char root_path[1024], moved_path[1024];
static const char *hook;
enum { NORMAL, SHORT_WRITE, WRITE_EIO, WRITE_ENOSPC, WRITE_ZERO, BAD_ENCODING,
    BAD_TAGS, BAD_STAMP, BAD_FINDER, PREPARE_SYNC, INSTALL_SYNC, DIRECTORY_SYNC,
    COLLISION, LATE_REPLACE, LATE_EDIT, FINAL_METADATA, LOST_RENAME, ROOT_MOVE,
    STAGE_CORRUPT, STAGE_COLLISION, FOREIGN_STAGE, WRONG_OWNER, EMPTY_OUTPUT,
    STAGE_NOT_PRIVATE, INVALID_LEAF, BAD_BODY_ARGUMENT, BIRTH_TIME, ROOT_LOSS, STAGE_TAG_CORRUPT,
    ABSENT_ENCODING, ABSENT_TAGS, STAGE_DATE_CORRUPT, STAGE_BIRTH_CORRUPT, FINAL_DATE, FINAL_BIRTH, FINAL_NAME, CASE_COUNT };

static void leaf(int parent, const char *name, const char *body) {
    int fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    assert(fd >= 0); assert(write(fd, body, strlen(body)) == (ssize_t)strlen(body)); assert(close(fd) == 0);
}
static void body(int parent, const char *name, const char *expected) {
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); assert(fd >= 0);
    char bytes[64] = {0}; ssize_t got = read(fd, bytes, sizeof(bytes));
    assert(got == (ssize_t)strlen(expected) && !memcmp(bytes, expected, (size_t)got)); assert(close(fd) == 0);
}
static void raw_attribute(int fd, const char *name, const uint8_t *bytes, size_t count) {
    uint8_t value[128];
#if defined(__APPLE__)
    ssize_t got = fgetxattr(fd, name, value, sizeof(value), 0, 0);
#else
    ssize_t got = fgetxattr(fd, name, value, sizeof(value));
#endif
    assert(got == (ssize_t)count && !memcmp(value, bytes, count));
}
static void overwrite_attribute(int fd, int tags) {
#if defined(__APPLE__)
    assert(fsetxattr(fd, tags ? "com.apple.metadata:kMDItemOMUserTags" : "com.apple.TextEncoding", "altered", 7, 0, 0) == 0);
#else
    assert(fsetxattr(fd, tags ? "user.com.apple.metadata:kMDItemOMUserTags" : "user.com.apple.TextEncoding", "altered", 7, 0) == 0);
#endif
}
static void overwrite_date(int fd, int birth) {
#if defined(__APPLE__)
    struct attrlist attributes = {0}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = birth ? ATTR_CMN_CRTIME : ATTR_CMN_MODTIME;
    struct timespec changed = {1700000042, 0};
    assert(fsetattrlist(fd, &attributes, &changed, sizeof(changed), 0) == 0);
#else
    assert(!birth);
    struct timespec changed[2] = {{0, UTIME_OMIT}, {1700000042, 0}};
    assert(futimens(fd, changed) == 0);
#endif
}
static void event(const char *name, int fd) {
    if (!strcmp(name, "projection-installed")) installed = 1;
    if (!hook || strcmp(hook, name)) return;
    hook = NULL;
    switch (fault) {
        case COLLISION: leaf(root_fd, "Note.txt", "concurrent"); break;
        case LATE_REPLACE: case FINAL_NAME:
            assert(renameat(root_fd, "Note.txt", root_fd, "preserved.txt") == 0);
            leaf(root_fd, "Note.txt", "concurrent"); break;
        case LATE_EDIT: assert(pwrite(fd, "changed", 7, 0) == 7); break;
        case FINAL_METADATA: overwrite_attribute(fd, 0); break;
        case ROOT_MOVE:
            assert(rename(root_path, moved_path) == 0); assert(mkdir(root_path, 0700) == 0);
            { int replacement = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); assert(replacement >= 0);
              leaf(replacement, "Note.txt", "foreign root"); close(replacement); }
            break;
        case STAGE_CORRUPT: assert(pwrite(fd, "changed", 7, 0) == 7); break;
        case STAGE_TAG_CORRUPT: overwrite_attribute(fd, 1); break;
        case STAGE_DATE_CORRUPT: case FINAL_DATE: overwrite_date(fd, 0); break;
        case STAGE_BIRTH_CORRUPT: case FINAL_BIRTH: overwrite_date(fd, 1); break;
        case FOREIGN_STAGE:
            assert(renameat(stage_fd, "prepared", stage_fd, "preserved-stage") == 0);
            leaf(stage_fd, "prepared", "foreign stage"); break;
        case ROOT_LOSS:
            assert(rename(moved_path, root_path) == 0); break;
        default: abort();
    }
}
static ssize_t fault_write(int fd, const void *bytes, size_t count) {
    write_calls++;
    if (fault == WRITE_EIO || fault == WRITE_ENOSPC) { errno = fault == WRITE_EIO ? EIO : ENOSPC; return -1; }
    if (fault == WRITE_ZERO) return 0;
    if (fault == SHORT_WRITE) {
        if (write_calls == 1) { errno = EINTR; return -1; }
        if (count > 1) count = 1;
    }
    return write(fd, bytes, count);
}
static int fault_sync(int fd) {
    if (fault == PREPARE_SYNC || (fault == INSTALL_SYNC && installed) ||
        (fault == DIRECTORY_SYNC && fd == root_fd)) { errno = EIO; return -1; }
    return fsync(fd);
}
#if defined(__APPLE__)
static int fault_setxattr(int fd, const char *name, const void *bytes, size_t count, uint32_t position, int flags) {
#else
static int fault_setxattr(int fd, const char *name, const void *bytes, size_t count, int flags) {
#endif
    if ((fault == BAD_ENCODING && strstr(name, "TextEncoding")) ||
        (fault == BAD_TAGS && strstr(name, "kMDItemOMUserTags")) ||
        (fault == BAD_STAMP && strstr(name, "projection#S")) ||
        (fault == BAD_FINDER && strstr(name, "_kMDItemUserTags"))) {
        optional_hits++; errno = ENOTSUP; return -1;
    }
#if defined(__APPLE__)
    return fsetxattr(fd, name, bytes, count, position, flags);
#else
    return fsetxattr(fd, name, bytes, count, flags);
#endif
}
#if defined(__APPLE__)
static int fault_rename(int from, const char *source, int to, const char *destination, unsigned flags) {
    int result = renameatx_np(from, source, to, destination, flags);
#else
static long fault_rename(long number, int from, const char *source, int to, const char *destination, unsigned flags) {
    long result = syscall(number, from, source, to, destination, flags);
#endif
    if (!result && fault == LOST_RENAME) { errno = EIO; return -1; }
    return result;
}
#define write fault_write
#define fsync fault_sync
#define fsetxattr fault_setxattr
#if defined(__APPLE__)
#define renameatx_np fault_rename
#else
#define syscall fault_rename
#endif
#define NV_PROJECTION_EVENT(name, fd) event(name, fd)
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef write
#undef fsync
#undef fsetxattr
#if defined(__APPLE__)
#undef renameatx_np
#else
#undef syscall
#endif

int main(int argc, char **argv) {
    assert(argc == 2); assert(mkdir(argv[1], 0700) == 0);
    const uint8_t encoding[] = "UTF-8;134217984", tags[] = {0xff, 0x00, 0xab}, stamp[] = "stamp";
    const uint8_t empty = 0;
    unsigned checks = 0;
    for (fault = NORMAL; fault < CASE_COUNT; fault++) {
        char private_path[1024];
        assert(snprintf(root_path, sizeof(root_path), "%s/root-%d", argv[1], fault) > 0);
        assert(snprintf(moved_path, sizeof(moved_path), "%s/moved-%d", argv[1], fault) > 0);
        assert(snprintf(private_path, sizeof(private_path), "%s/private-%d", argv[1], fault) > 0);
        assert(mkdir(root_path, 0700) == 0 && mkdir(private_path, 0700) == 0);
        NVRootOwner *owner = nv_root_open(root_path); assert(owner); root_fd = owner->directory;
        stage_fd = open(private_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); assert(stage_fd >= 0);
        NVProjectionMetadata metadata = {
            .encoding = {encoding, sizeof(encoding) - 1, 1}, .tags = {tags, sizeof(tags), 1},
            .finder_tags = {&empty, 0, 1}, .stamp = {stamp, sizeof(stamp) - 1, 1},
            .permissions = 0640, .modified_seconds = 1700000003, .modified_nanoseconds = 234567890,
            .birth_seconds = 1700000001, .birth_nanoseconds = 123456789,
            .has_birth = fault == BIRTH_TIME || fault == STAGE_BIRTH_CORRUPT || fault == FINAL_BIRTH
        };
        if (fault == ABSENT_ENCODING) metadata.encoding = (NVProjectionAttributeValue){0};
        if (fault == ABSENT_TAGS) metadata.tags = (NVProjectionAttributeValue){0};
        write_calls = 0; installed = 0; optional_hits = 0; hook = NULL;
        if (fault == STAGE_COLLISION) leaf(stage_fd, "prepared", "other stage");
        if (fault == STAGE_NOT_PRIVATE) assert(fchmod(stage_fd, 0755) == 0);
        if (fault == STAGE_CORRUPT || fault == STAGE_TAG_CORRUPT ||
            fault == STAGE_DATE_CORRUPT || fault == STAGE_BIRTH_CORRUPT) hook = "stage-prepared";
        const char *contents = fault == EMPTY_OUTPUT ? "" : "desired";
        NVProjectionEffect effect;
        NVProjectionStage *stage = nv_projection_prepare(owner, stage_fd, "prepared", (const uint8_t *)contents,
            strlen(contents), &metadata, &effect);
        int preparation_fails = (fault >= WRITE_EIO && fault <= BAD_TAGS) || fault == PREPARE_SYNC ||
            fault == STAGE_CORRUPT || fault == STAGE_COLLISION || fault == STAGE_NOT_PRIVATE || fault == STAGE_TAG_CORRUPT ||
            fault == ABSENT_ENCODING || fault == ABSENT_TAGS || fault == STAGE_DATE_CORRUPT || fault == STAGE_BIRTH_CORRUPT;
#if !defined(__APPLE__)
        preparation_fails = preparation_fails || metadata.has_birth;
#endif
        if (preparation_fails) {
            assert(effect.outcome != NV_PROJECTION_STAGED && effect.error != 0);
            assert(faccessat(root_fd, "Note.txt", F_OK, 0) == -1 && errno == ENOENT);
            if (fault == STAGE_COLLISION) { assert(!stage && effect.error == EEXIST); body(stage_fd, "prepared", "other stage"); }
            if (fault == STAGE_NOT_PRIVATE) assert(!stage && effect.error == EACCES);
            if (fault == ABSENT_ENCODING || fault == ABSENT_TAGS) assert(!stage && effect.error == EINVAL);
#if !defined(__APPLE__)
            if (metadata.has_birth) assert(stage && effect.error == ENOTSUP);
#endif
            if (stage) {
                NVProjectionEffect retry;
                nv_projection_create(owner, stage, "Note.txt", (const uint8_t *)contents, strlen(contents), &metadata, &retry);
                assert(retry.outcome == NV_PROJECTION_NO_EFFECT && retry.error == EINVAL);
            }
        } else {
            assert(stage && effect.outcome == NV_PROJECTION_STAGED && effect.error == 0);
            assert(effect.stamp_error == (fault == BAD_STAMP ? ENOTSUP : 0));
            assert(effect.finder_tags_error == (fault == BAD_FINDER ? ENOTSUP : 0));
            if (fault == BAD_STAMP || fault == BAD_FINDER) assert(optional_hits == 1);
            if (fault == COLLISION || fault == ROOT_MOVE || fault == FOREIGN_STAGE || fault == ROOT_LOSS) hook = "before-exclusive-create";
            if (fault == LATE_REPLACE || fault == LATE_EDIT) hook = "projection-installed";
            if (fault == FINAL_METADATA || fault == FINAL_DATE || fault == FINAL_BIRTH || fault == FINAL_NAME) hook = "projection-final-check";
            NVRootOwner *different = NULL;
            if (fault == WRONG_OWNER || fault == ROOT_LOSS) { assert(mkdir(moved_path, 0700) == 0); }
            if (fault == WRONG_OWNER) { different = nv_root_open(moved_path); assert(different); }
            nv_projection_create(different ? different : owner, stage, fault == INVALID_LEAF ? "../escape" : "Note.txt",
                (const uint8_t *)(fault == BAD_BODY_ARGUMENT ? "changed" : contents), strlen(contents), &metadata, &effect);
            if (different) nv_root_close(different);
            int succeeds = fault == NORMAL || fault == SHORT_WRITE || fault == BAD_STAMP || fault == BAD_FINDER ||
                fault == DIRECTORY_SYNC || fault == ROOT_MOVE || fault == EMPTY_OUTPUT || fault == BIRTH_TIME;
            assert((effect.outcome == NV_PROJECTION_INSTALLED) == succeeds);
            assert(effect.root_lost == (fault == ROOT_LOSS ? 1 : 0));
            if (succeeds) {
                assert(effect.error == 0); body(root_fd, "Note.txt", contents);
                int fd = openat(root_fd, "Note.txt", O_RDONLY | O_NOFOLLOW | O_CLOEXEC); assert(fd >= 0);
                struct stat info; assert(fstat(fd, &info) == 0 && (info.st_mode & 0777) == 0640);
#if defined(__APPLE__)
                struct statfs filesystem; assert(fstatfs(fd, &filesystem) == 0);
                int seconds_only = !strcmp(filesystem.f_fstypename, "hfs");
                assert(info.st_mtimespec.tv_sec == 1700000003 && info.st_mtimespec.tv_nsec == (seconds_only ? 0 : 234567890));
                if (metadata.has_birth) assert(info.st_birthtimespec.tv_sec == 1700000001 &&
                    info.st_birthtimespec.tv_nsec == (seconds_only ? 0 : 123456789));
#else
                assert(info.st_mtim.tv_sec == 1700000003 && info.st_mtim.tv_nsec == 234567890);
#endif
                raw_attribute(fd, NV_PROJECTION_ENCODING, encoding, sizeof(encoding) - 1);
                raw_attribute(fd, NV_PROJECTION_TAGS, tags, sizeof(tags));
                if (fault != BAD_STAMP) raw_attribute(fd, NV_PROJECTION_STAMP, stamp, sizeof(stamp) - 1);
                assert(effect.directory_sync_error == (fault == DIRECTORY_SYNC ? EIO : 0));
                assert(close(fd) == 0);
                if (fault == ROOT_MOVE) {
                    int other = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); assert(other >= 0);
                    body(other, "Note.txt", "foreign root"); close(other);
                }
            } else if (fault == COLLISION) {
                assert(effect.outcome == NV_PROJECTION_STAGED && effect.error == EEXIST);
                body(root_fd, "Note.txt", "concurrent"); body(stage_fd, "prepared", contents);
            } else if (fault == LATE_REPLACE || fault == FINAL_NAME) {
                assert(effect.outcome == NV_PROJECTION_UNCERTAIN);
                body(root_fd, "Note.txt", "concurrent"); body(root_fd, "preserved.txt", contents);
            } else if (fault == FOREIGN_STAGE) {
                assert(effect.outcome == NV_PROJECTION_UNCERTAIN);
                body(root_fd, "Note.txt", "foreign stage"); body(stage_fd, "preserved-stage", contents);
            } else if (fault == LOST_RENAME || fault == INSTALL_SYNC || fault == FINAL_METADATA || fault == FINAL_DATE || fault == FINAL_BIRTH) {
                assert(effect.outcome == NV_PROJECTION_UNCERTAIN); body(root_fd, "Note.txt", contents);
            } else if (fault == LATE_EDIT) {
                assert(effect.outcome == NV_PROJECTION_UNCERTAIN); body(root_fd, "Note.txt", "changed");
            } else {
                assert(effect.error != 0); body(stage_fd, "prepared", contents);
                assert(faccessat(root_fd, "Note.txt", F_OK, 0) == -1 && errno == ENOENT);
            }
        }
        nv_projection_stage_close(stage); close(stage_fd); nv_root_close(owner); checks++;
    }
    assert(checks == CASE_COUNT);
    printf("PASS: projection exclusive creation %u native scenarios\n", checks);
    return 0;
}
