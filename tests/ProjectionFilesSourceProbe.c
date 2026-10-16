/* Exercises preservation through the production source-quarantine syscall boundary. */
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
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/attr.h>
#endif
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

enum { NORMAL, EMPTY, BEFORE_CHANGED, LATE_CHANGED, LATE_EQUAL, LATE_METADATA,
    OCCUPIED, LATE_OCCUPIED, NEW_SOURCE, RESTORE_OCCUPIED, BEFORE_ERROR,
    AFTER_ERROR, RESTORE_ERROR, CHANGED_ARTIFACT, FINAL_ARTIFACT,
    WRONG_KIND, HARD_LINK, BOUNDED_READ, ROOT_MOVED, ROOT_LOST, WRONG_BYTES,
    LATE_OVERSIZE, LATE_SYMLINK, NO_SPACE, OBSERVATION_ERROR,
    BEFORE_METADATA, BEFORE_MODE, LATE_UNLINK, INVALID_ATTRIBUTE,
    INVALID_DESCRIPTOR, FOREIGN_DESCRIPTOR, CLOSED_DESCRIPTOR, CAPTURE_UNLINK, CASE_COUNT };
static int scenario, root_fd, rename_calls, successful_moves;
static int name_error;
static const char *crash_at;
static char root_path[4096], moved_path[4096];
#define Require(value) do { if (!(value)) { fprintf(stderr, "scenario %d line %d: %s (errno %d)\n", scenario, __LINE__, #value, errno); abort(); } } while (0)
static void Create(const char *leaf, const char *body) {
    int fd = openat(root_fd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    Require(fd >= 0); size_t count = strlen(body);
    Require(write(fd, body, count) == (ssize_t)count && close(fd) == 0);
}
static void Body(const char *leaf, const char *expected) {
    int fd = openat(root_fd, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); Require(fd >= 0);
    char bytes[64]; ssize_t count = pread(fd, bytes, sizeof(bytes), 0);
    Require(count == (ssize_t)strlen(expected) && !memcmp(bytes, expected, (size_t)count)); close(fd);
}
static void Attribute(const char *leaf, const char *value) {
    int fd = openat(root_fd, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); Require(fd >= 0);
#if defined(__APPLE__)
    Require(fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", value, strlen(value), 0, 0) == 0);
#else
    Require(fsetxattr(fd, "user.com.apple.metadata:kMDItemOMUserTags", value, strlen(value), 0) == 0);
#endif
    close(fd);
}
static void Event(const char *name, int fd) {
    (void)fd;
    if (crash_at && !strcmp(crash_at, name)) _exit(71);
    if (!strcmp(name, "source-final-check") && scenario == OBSERVATION_ERROR) name_error = 1;
    if (!strcmp(name, "source-before-quarantine")) {
        struct stat pinned; Require(fstat(fd, &pinned) == 0 && S_ISREG(pinned.st_mode));
        if (scenario == LATE_UNLINK) {
            Require(unlinkat(root_fd, "Note.txt", 0) == 0); Create("Note.txt", "original"); Attribute("Note.txt", "old");
            struct stat fresh; Require(fstatat(root_fd, "Note.txt", &fresh, 0) == 0);
            Require(pinned.st_ino != fresh.st_ino);
        }
        if (scenario == LATE_CHANGED || scenario == LATE_EQUAL || scenario == RESTORE_OCCUPIED || scenario == RESTORE_ERROR || scenario == LATE_OVERSIZE || scenario == LATE_SYMLINK) {
            struct stat old; Require(fstatat(root_fd, "Note.txt", &old, AT_SYMLINK_NOFOLLOW) == 0);
            Require(renameat(root_fd, "Note.txt", root_fd, "saved.txt") == 0);
            if (scenario == LATE_SYMLINK) {
                Create("outside", "preserved target"); Require(symlinkat("outside", root_fd, "Note.txt") == 0);
            } else Create("Note.txt", scenario == LATE_EQUAL ? "original" : "concurrent");
            if (scenario == LATE_EQUAL) {
                Attribute("Note.txt", "old");
                int current = openat(root_fd, "Note.txt", O_RDONLY | O_CLOEXEC); Require(current >= 0);
#if defined(__APPLE__)
                struct attrlist attributes = {0}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
                attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
                struct { struct timespec birth, modified; } dates = {old.st_birthtimespec, old.st_mtimespec};
                Require(fsetattrlist(current, &attributes, &dates, sizeof(dates), 0) == 0);
#else
                struct timespec dates[2] = {old.st_atim, old.st_mtim}; Require(futimens(current, dates) == 0);
#endif
                close(current);
            }
        } else if (scenario == LATE_METADATA) Attribute("Note.txt", "changed");
        else if (scenario == LATE_OCCUPIED) Create("recovery", "foreign");
        else if (scenario == ROOT_MOVED) {
            Require(rename(root_path, moved_path) == 0 && mkdir(root_path, 0700) == 0);
            int held = root_fd; root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); Require(root_fd >= 0);
            Create("Note.txt", "foreign"); close(root_fd); root_fd = held;
        }
    } else if (!strcmp(name, "source-quarantined")) {
        if (scenario == NEW_SOURCE) Create("Note.txt", "fresh");
        if (scenario == CHANGED_ARTIFACT) {
            Require(renameat(root_fd, "recovery", root_fd, "preserved") == 0); Create("recovery", "changed");
        }
    } else if (!strcmp(name, "source-before-restore") && scenario == RESTORE_OCCUPIED) Create("Note.txt", "fresh");
    else if (!strcmp(name, "source-final-check") && scenario == FINAL_ARTIFACT) {
        Require(renameat(root_fd, "recovery", root_fd, "preserved") == 0); Create("recovery", "changed");
    }
}
static int Rename(int from, const char *source, int to, const char *destination);
int OverwritingRename(int from, const char *source, int to, const char *destination);
static int Observe(int directory, const char *leaf, struct stat *st, int flags) {
    if (name_error && !strcmp(leaf, "Note.txt")) { name_error = 0; errno = EACCES; return -1; }
    return fstatat(directory, leaf, st, flags);
}
#define NV_PROJECTION_EVENT(name, fd) Event(name, fd)
#define NV_PROJECTION_SOURCE_RENAME Rename
#define fstatat Observe
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef fstatat
static int Rename(int from, const char *source, int to, const char *destination) {
    rename_calls++;
    if (scenario == BEFORE_ERROR || (scenario == RESTORE_ERROR && rename_calls == 2)) { errno = EIO; return -1; }
    if (scenario == NO_SPACE) { errno = ENOSPC; return -1; }
    int result = projection_rename_exclusive(from, source, to, destination);
    if (scenario == AFTER_ERROR && result == 0) { errno = EIO; return -1; }
    if (result == 0) successful_moves++;
    return result;
}

/* Counts the deliberately overwriting mutation through the same notification oracle. */
int OverwritingRename(int from, const char *source, int to, const char *destination) {
    rename_calls++;
    int result = renameat(from, source, to, destination);
    if (result == 0) successful_moves++;
    return result;
}

#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
#import "../NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m"
static int announced_moves, notified_moves;
@interface SourceCoordinator : NSFileCoordinator
@end
@implementation SourceCoordinator
- (void)itemAtURL:(NSURL *)oldURL willMoveToURL:(NSURL *)newURL {
    Require(![oldURL isEqual:newURL]);
    Require([oldURL.lastPathComponent isEqualToString:announced_moves == 0 ? @"Note.txt" : @"recovery"]);
    Require([newURL.lastPathComponent isEqualToString:announced_moves == 0 ? @"recovery" : @"Note.txt"]);
    announced_moves++;
    [super itemAtURL:oldURL willMoveToURL:newURL];
}
- (void)itemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL {
    Require(announced_moves == notified_moves + 1);
    Require([oldURL.lastPathComponent isEqualToString:notified_moves == 0 ? @"Note.txt" : @"recovery"]);
    Require([newURL.lastPathComponent isEqualToString:notified_moves == 0 ? @"recovery" : @"Note.txt"]);
    notified_moves++;
    [super itemAtURL:oldURL didMoveToURL:newURL];
}
@end
static void SourceOperation(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, NVProjectionSourceResult *result) {
    @autoreleasepool {
        NSURL *directory = [[NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path] isDirectory:YES] fileReferenceURL];
        Require(directory != nil);
        announced_moves = 0; notified_moves = 0;
        NSFileCoordinator *coordinator = [[SourceCoordinator alloc] initWithFilePresenter:nil];
        NVAppleQuarantineProjection(coordinator, (__bridge CFURLRef)directory, owner, source, recovery, expected, maximum, descriptor, result);
        Require(announced_moves == rename_calls);
        Require(notified_moves == successful_moves);
    }
}
#else
static void SourceOperation(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, NVProjectionSourceResult *result) {
    nv_projection_quarantine_source(owner, source, recovery, expected, maximum, descriptor, NULL, NULL, result);
}
#endif

int main(int argc, char **argv) {
    Require(argc == 2 || argc == 3); Require(mkdir(argv[1], 0700) == 0);
    crash_at = argc == 3 ? argv[2] : NULL;
    for (scenario = NORMAL; scenario < CASE_COUNT; scenario++) {
        Require(snprintf(root_path, sizeof(root_path), "%s/case-%d", argv[1], scenario) > 0);
        Require(snprintf(moved_path, sizeof(moved_path), "%s/moved-%d", argv[1], scenario) > 0);
        Require(mkdir(root_path, 0700) == 0);
        NVRootOwner *owner = nv_root_open(root_path); Require(owner); root_fd = owner->directory; rename_calls = 0; successful_moves = 0;
        const char *original = scenario == EMPTY ? "" : "original";
        Create("Note.txt", original); Attribute("Note.txt", "old");
        uint64_t expected[9]; Require(nv_root_snapshot(owner, "Note.txt", expected) == 0);
        NVProjectionRead *captured = NULL; int descriptor = -1, foreign = -1;
        Require(nv_projection_read_retaining(owner, "Note.txt", expected, 1024, &captured, &descriptor) == 0 && captured);
        Require(fcntl(descriptor, F_GETFD) >= 0);
        if (scenario == FOREIGN_DESCRIPTOR) {
            Create("foreign", "original"); foreign = openat(root_fd, "foreign", O_RDONLY | O_CLOEXEC); Require(foreign >= 0);
        }
        if (scenario == CLOSED_DESCRIPTOR) Require(close(descriptor) == 0);
        if (scenario == CAPTURE_UNLINK) {
            struct stat held, fresh; Require(fstat(descriptor, &held) == 0);
            Require(unlinkat(root_fd, "Note.txt", 0) == 0); Create("Note.txt", original); Attribute("Note.txt", "old");
            Require(fstatat(root_fd, "Note.txt", &fresh, 0) == 0 && held.st_ino != fresh.st_ino);
        }
        if (scenario == WRONG_BYTES) memcpy(captured->bytes, "mismatch", 8);
        if (scenario == INVALID_ATTRIBUTE) captured->tags.state = 3;
        if (scenario == BEFORE_METADATA || scenario == BEFORE_MODE) {
            if (scenario == BEFORE_METADATA) Attribute("Note.txt", "changed");
            else { int file = openat(root_fd, "Note.txt", O_RDONLY | O_CLOEXEC); Require(file >= 0 && fchmod(file, 0640) == 0); close(file); }
            /* Isolate mandatory metadata checks with equal stat words, including on fine-clock filesystems. */
            Require(nv_root_snapshot(owner, "Note.txt", captured->words) == 0);
        }
        if (scenario == BEFORE_CHANGED) { Require(renameat(root_fd, "Note.txt", root_fd, "saved.txt") == 0); Create("Note.txt", "changed"); }
        if (scenario == OCCUPIED) Create("recovery", "foreign");
        if (scenario == WRONG_KIND) { Require(renameat(root_fd, "Note.txt", root_fd, "saved.txt") == 0); Require(mkdirat(root_fd, "Note.txt", 0700) == 0); }
        if (scenario == HARD_LINK) Require(linkat(root_fd, "Note.txt", root_fd, "alias", 0) == 0);
        if (scenario == ROOT_LOST) owner->invalidated = 1;
        NVProjectionSourceResult result;
        SourceOperation(owner, "Note.txt", "recovery", captured,
            scenario == BOUNDED_READ ? 0 : scenario == LATE_OVERSIZE ? 8 : 1024,
            scenario == INVALID_DESCRIPTOR ? -1 : scenario == FOREIGN_DESCRIPTOR ? foreign : descriptor, &result);
        if (scenario != CLOSED_DESCRIPTOR) Require(fcntl(descriptor, F_GETFD) >= 0);
        int captures = scenario == NORMAL || scenario == EMPTY || scenario == NEW_SOURCE || scenario == ROOT_MOVED;
        Require((result.outcome == NV_PROJECTION_SOURCE_CAPTURED) == captures);
        if (captures) {
            Body("recovery", original); Require(result.artifact_state == NV_PROJECTION_NAME_PRESENT && result.artifact_words[2] == expected[2]);
            Require(result.source_state == (scenario == NEW_SOURCE ? NV_PROJECTION_NAME_PRESENT : NV_PROJECTION_NAME_ABSENT));
            if (scenario == NEW_SOURCE) Body("Note.txt", "fresh");
        } else if (scenario == LATE_CHANGED || scenario == LATE_EQUAL || scenario == LATE_METADATA || scenario == CHANGED_ARTIFACT || scenario == LATE_UNLINK) {
            Require(result.outcome == NV_PROJECTION_SOURCE_RESTORED && result.source_state == NV_PROJECTION_NAME_PRESENT && result.artifact_state == NV_PROJECTION_NAME_ABSENT);
            Body("Note.txt", scenario == LATE_EQUAL || scenario == LATE_METADATA || scenario == LATE_UNLINK ? original : scenario == CHANGED_ARTIFACT ? "changed" : "concurrent");
            if (scenario == LATE_CHANGED || scenario == LATE_EQUAL) Body("saved.txt", original);
            if (scenario == CHANGED_ARTIFACT) Body("preserved", original);
        } else if (scenario == RESTORE_OCCUPIED || scenario == RESTORE_ERROR) {
            if (scenario == RESTORE_OCCUPIED) Require(result.outcome == NV_PROJECTION_SOURCE_RETAINED);
            else Require(result.outcome == NV_PROJECTION_SOURCE_UNCERTAIN);
            Body("recovery", "concurrent"); Body("saved.txt", original);
            if (scenario == RESTORE_OCCUPIED) Body("Note.txt", "fresh");
        } else if (scenario == FINAL_ARTIFACT) {
            Require(result.outcome == NV_PROJECTION_SOURCE_UNCERTAIN && result.error == ESTALE);
            Body("recovery", "changed"); Body("preserved", original);
        } else if (scenario == AFTER_ERROR) {
            Require(result.outcome == NV_PROJECTION_SOURCE_UNCERTAIN && result.error == EIO); Body("recovery", original);
        } else if (scenario == LATE_OVERSIZE || scenario == LATE_SYMLINK) {
            Require(result.outcome == NV_PROJECTION_SOURCE_RETAINED && result.artifact_state == NV_PROJECTION_NAME_PRESENT && result.source_state == NV_PROJECTION_NAME_ABSENT);
            Require(result.error == (scenario == LATE_OVERSIZE ? EFBIG : ENOTDIR)); Body("saved.txt", original);
            if (scenario == LATE_OVERSIZE) Body("recovery", "concurrent");
            else {
                struct stat st; Require(fstatat(root_fd, "recovery", &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode));
                Body("outside", "preserved target");
            }
        } else if (scenario == OBSERVATION_ERROR) {
            Require(result.outcome == NV_PROJECTION_SOURCE_UNCERTAIN && result.error == EACCES);
            Require(result.source_state == NV_PROJECTION_NAME_UNAVAILABLE && result.artifact_state == NV_PROJECTION_NAME_PRESENT);
            Body("recovery", original);
        } else if (scenario != WRONG_KIND) {
            Body("Note.txt", scenario == BEFORE_CHANGED ? "changed" : original);
            if (scenario == OCCUPIED || scenario == LATE_OCCUPIED) Body("recovery", "foreign");
            if (scenario == ROOT_LOST) Require(result.root_lost);
            if (scenario == NO_SPACE) Require(result.error == ENOSPC && result.outcome == NV_PROJECTION_SOURCE_UNCERTAIN);
            if (scenario == WRONG_BYTES || scenario == BEFORE_METADATA || scenario == BEFORE_MODE || scenario == INVALID_ATTRIBUTE || scenario == OCCUPIED ||
                scenario == INVALID_DESCRIPTOR || scenario == FOREIGN_DESCRIPTOR || scenario == CLOSED_DESCRIPTOR || scenario == CAPTURE_UNLINK) {
                Require(result.outcome == NV_PROJECTION_SOURCE_NO_EFFECT && rename_calls == 0);
            }
        } else {
            struct stat st; Require(fstatat(root_fd, "Note.txt", &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode));
            Require(result.outcome == NV_PROJECTION_SOURCE_NO_EFFECT && result.error == ENOTDIR);
        }
        if (scenario == ROOT_MOVED) {
            int held = root_fd; root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); Require(root_fd >= 0);
            Body("Note.txt", "foreign"); close(root_fd); root_fd = held;
        }
        nv_projection_read_close(captured);
        if (scenario != CLOSED_DESCRIPTOR) Require(close(descriptor) == 0);
        if (foreign >= 0) Require(close(foreign) == 0);
        nv_root_close(owner);
    }
    printf("PASS: projection source quarantine %d native scenarios\n", CASE_COUNT);
    return 0;
}
