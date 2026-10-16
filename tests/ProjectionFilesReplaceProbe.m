/* Exercises the production Foundation adapter and native verification with real namespace races. */
#import <Foundation/Foundation.h>
#include <assert.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <copyfile.h>
#include <sys/wait.h>
#include <time.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

enum { NORMAL, EMPTY, OMIT_STAMP, BEFORE_CHANGED, BACKUP_OCCUPIED, LATE_TARGET,
    ROOT_MOVED, FINAL_TARGET, FINAL_TAGS, BACKUP_CHANGED, BACKUP_MOVED, WRONG_INPUT,
    WRONG_STAGE, STAGE_CHANGED, COPY_FAILURE, BEFORE_EFFECT_ERROR, AFTER_EFFECT_ERROR,
    REPLACEMENT_CANCELLED, CASE_COUNT };
static int scenario, root_fd, install_calls, replaced;
static char root_path[2048], moved_path[2048];
static const char *hook;
static const char *crash_boundary;
#define Require(value) do { if (!(value)) { fprintf(stderr, "scenario %d line %d: %s (errno %d)\n", scenario, __LINE__, #value, errno); abort(); } } while (0)

static void Create(int directory, const char *name, const char *body) {
    int fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0640); Require(fd >= 0);
    Require(fchmod(fd, 0640) == 0 && write(fd, body, strlen(body)) == (ssize_t)strlen(body));
    Require(fsetxattr(fd, "org.notationalvelocity.test-unrelated", "keep", 4, 0, 0) == 0);
    Require(fsetxattr(fd, "org.notationalvelocity.projection#S", "previous", 8, 0, 0) == 0);
    struct attrlist attributes = {0}; attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
    struct { struct timespec birth, modified; } dates = {{1700000001, 123456789}, {1700000002, 0}};
    Require(fsetattrlist(fd, &attributes, &dates, sizeof(dates), 0) == 0 && fsync(fd) == 0);
    close(fd);
}
static void Body(int directory, const char *name, const char *expected) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); Require(fd >= 0);
    char bytes[64]; ssize_t count = pread(fd, bytes, sizeof(bytes), 0);
    Require(count == (ssize_t)strlen(expected) && !memcmp(bytes, expected, (size_t)count)); close(fd);
}
static void Event(const char *name, int fd) {
    if (crash_boundary && !strcmp(crash_boundary, name)) _exit(71);
    if (!strcmp(name, "projection-installed")) replaced = 1;
    if (!hook || strcmp(name, hook)) return;
    hook = NULL;
    if (scenario == LATE_TARGET || scenario == FINAL_TARGET) {
        Require(renameat(root_fd, "Note.txt", root_fd, "other.txt") == 0); Create(root_fd, "Note.txt", "concurrent");
    } else if (scenario == ROOT_MOVED) {
        Require(rename(root_path, moved_path) == 0 && mkdir(root_path, 0700) == 0);
        int other = open(root_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); Require(other >= 0);
        Create(other, "Note.txt", "foreign"); close(other);
    } else if (scenario == FINAL_TAGS) {
        Require(fsetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", "changed", 7, 0, 0) == 0);
    } else if (scenario == BACKUP_CHANGED) {
        int backup = openat(root_fd, "backup", O_WRONLY | O_NOFOLLOW | O_CLOEXEC); Require(backup >= 0);
        Require(pwrite(backup, "changed", 7, 0) == 7); close(backup);
    } else if (scenario == BACKUP_MOVED) {
        Require(renameat(root_fd, "backup", root_fd, "preserved-backup") == 0); Create(root_fd, "backup", "other");
    } else if (scenario == STAGE_CHANGED) {
        Require(pwrite(fd, "changed", 7, 0) == 7);
    } else { abort(); }
}
static int Copy(int source, int destination, copyfile_state_t state, copyfile_flags_t flags) {
    if (scenario == COPY_FAILURE) { errno = EIO; return -1; }
    return fcopyfile(source, destination, state, flags);
}
#define fcopyfile Copy
#define NV_PROJECTION_EVENT(name, fd) Event(name, fd)
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef fcopyfile

@interface ProjectionReplacementManager : NSFileManager
@end
#define NV_PROJECTION_FILE_MANAGER [ProjectionReplacementManager new]
#ifndef NV_APPLE_PROJECTION_SOURCE
#define NV_APPLE_PROJECTION_SOURCE "../NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m"
#endif
#include NV_APPLE_PROJECTION_SOURCE

/* Counts the production Foundation invocation and injects errors around that exact call. */
@implementation ProjectionReplacementManager
- (BOOL)replaceItemAtURL:(NSURL *)oldURL withItemAtURL:(NSURL *)newURL backupItemName:(NSString *)backup
    options:(NSFileManagerItemReplacementOptions)options resultingItemURL:(NSURL **)result error:(NSError **)error {
    install_calls++;
    if (scenario == BEFORE_EFFECT_ERROR) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]; return NO; }
    BOOL replacedItem = [super replaceItemAtURL:oldURL withItemAtURL:newURL backupItemName:backup options:options resultingItemURL:result error:error];
    if (scenario == AFTER_EFFECT_ERROR && replacedItem) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]; return NO;
    }
    return replacedItem;
}
@end

@interface ProjectionReplacementCoordinator : NSFileCoordinator
@end
@implementation ProjectionReplacementCoordinator
- (void)coordinateWritingItemAtURL:(NSURL *)first options:(NSFileCoordinatorWritingOptions)firstOptions
    writingItemAtURL:(NSURL *)second options:(NSFileCoordinatorWritingOptions)secondOptions
    error:(NSError **)error byAccessor:(void (NS_NOESCAPE ^)(NSURL *, NSURL *))accessor {
    [super coordinateWritingItemAtURL:first options:firstOptions writingItemAtURL:second
        options:secondOptions error:error byAccessor:accessor];
    if (error && *error) NSLog(@"Synthetic replacement coordination: %@", *error);
}
@end

typedef struct { unsigned old_count, new_count, inconsistent; } ProjectionReaderResult;

static int AttributeEquals(int fd, const char *name, const void *expected, size_t count) {
    char bytes[64];
    ssize_t actual = fgetxattr(fd, name, bytes, sizeof(bytes), 0, 0);
    return actual == (ssize_t)count && !memcmp(bytes, expected, count);
}

/* Uses an independent descriptor for every complete old-or-new body/metadata observation. */
static void ObserveReplacement(int ready, int finished, const struct stat *old, const struct stat *staged) {
    ProjectionReaderResult result = {0};
    time_t deadline = time(NULL) + 15;
    while (time(NULL) < deadline && !result.new_count) {
        int fd = openat(root_fd, "Note.txt", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) { result.inconsistent++; continue; }
        char bytes[4]; struct stat observed;
        ssize_t count = pread(fd, bytes, sizeof(bytes), 0);
        int is_old = count == 3 && !memcmp(bytes, "old", 3);
        int is_new = count == 3 && !memcmp(bytes, "new", 3);
        const struct stat *expected = is_old ? old : staged;
        const uint8_t new_tags[] = {0, 255, 17};
        int matches = (is_old || is_new) && fstat(fd, &observed) == 0 &&
            observed.st_size == 3 && (observed.st_mode & 0777) == 0640 &&
            observed.st_birthtimespec.tv_sec == expected->st_birthtimespec.tv_sec &&
            observed.st_birthtimespec.tv_nsec == expected->st_birthtimespec.tv_nsec &&
            observed.st_mtimespec.tv_sec == expected->st_mtimespec.tv_sec &&
            observed.st_mtimespec.tv_nsec == expected->st_mtimespec.tv_nsec &&
            AttributeEquals(fd, "com.apple.TextEncoding", is_old ? "old-encoding" : "UTF-8;134217984", is_old ? 12 : 15) &&
            AttributeEquals(fd, "com.apple.metadata:kMDItemOMUserTags", is_old ? (const void *)"old" : new_tags, 3) &&
            AttributeEquals(fd, "org.notationalvelocity.projection#S", is_old ? "previous" : "new-stamp", is_old ? 8 : 9) &&
            AttributeEquals(fd, "org.notationalvelocity.test-unrelated", "keep", 4);
        close(fd);
        if (!matches) result.inconsistent++;
        if (is_old && result.old_count++ == 0) {
            char value = 'r'; if (write(ready, &value, 1) != 1) _exit(72);
        }
        if (is_new) result.new_count++;
    }
    if (write(finished, &result, sizeof(result)) != sizeof(result)) _exit(73);
    _exit(result.old_count && result.new_count && !result.inconsistent ? 0 : 74);
}

int main(int argc, const char **argv) {
    Require((argc >= 2 && argc <= 4) && mkdir(argv[1], 0700) == 0);
    crash_boundary = argc >= 3 ? argv[2] : NULL;
    Require(argc != 4 || !strcmp(argv[3], "late-target"));
    @autoreleasepool {
        const uint8_t encoding[] = "UTF-8;134217984", tags[] = {0, 255, 17}, stamp[] = "new-stamp";
        for (scenario = argc == 4 ? LATE_TARGET : NORMAL; scenario < CASE_COUNT; scenario++) {
            @autoreleasepool {
                Require(snprintf(root_path, sizeof(root_path), "%s/root-%d", argv[1], scenario) > 0);
                Require(snprintf(moved_path, sizeof(moved_path), "%s/moved-%d", argv[1], scenario) > 0);
                Require(mkdir(root_path, 0700) == 0);
                NVRootOwner *owner = nv_root_open(root_path); Require(owner); root_fd = owner->directory;
                Create(root_fd, "Note.txt", "old");
                int original = openat(root_fd, "Note.txt", O_RDWR | O_NOFOLLOW); Require(original >= 0);
                Require(fsetxattr(original, "com.apple.TextEncoding", "old-encoding", 12, 0, 0) == 0);
                Require(fsetxattr(original, "com.apple.metadata:kMDItemOMUserTags", "old", 3, 0, 0) == 0);
                struct stat original_metadata; Require(fstat(original, &original_metadata) == 0); close(original);
                uint64_t expected[9]; Require(nv_root_snapshot(owner, "Note.txt", expected) == 0);
                NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path] isDirectory:YES].fileReferenceURL;
                Require(root != nil);
                NSURL *directory = [[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory
                    inDomain:NSUserDomainMask appropriateForURL:root create:YES error:NULL]; Require(directory != nil);
                int stage_fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); Require(stage_fd >= 0);
                NVProjectionMetadata metadata = { .encoding = {encoding, sizeof(encoding)-1, 1}, .tags = {tags, sizeof(tags), 1},
                    .stamp = {stamp, sizeof(stamp)-1, 1}, .permissions = 0640, .has_birth = 1,
                    .birth_seconds = 1700000001, .birth_nanoseconds = 123456789,
                    .modified_seconds = 1700000003, .modified_nanoseconds = 234567890 };
                if (scenario == OMIT_STAMP) metadata.stamp = (NVProjectionAttributeValue){0};
                const char *output = scenario == EMPTY ? "" : "new";
                hook = scenario == STAGE_CHANGED ? "stage-prepared" : NULL;
                NVProjectionEffect preparation;
                NVProjectionStage *stage = scenario == WRONG_STAGE ?
                    nv_projection_prepare(owner, stage_fd, "prepared", (const uint8_t *)output, strlen(output), &metadata, &preparation) :
                    nv_projection_prepare_replacement(owner, stage_fd, "prepared", "Note.txt", expected,
                        (const uint8_t *)"old", 3, (const uint8_t *)output, strlen(output), &metadata, &preparation);
                if (scenario == COPY_FAILURE || scenario == STAGE_CHANGED) {
                    Require(stage && preparation.outcome == NV_PROJECTION_UNCERTAIN && preparation.error != 0);
                    Body(root_fd, "Note.txt", "old"); nv_projection_stage_close(stage); close(stage_fd); nv_root_close(owner); continue;
                }
                Require(stage && preparation.outcome == NV_PROJECTION_STAGED && preparation.error == 0);
                if (scenario == BEFORE_CHANGED) {
                    Require(renameat(root_fd, "Note.txt", root_fd, "other.txt") == 0); Create(root_fd, "Note.txt", "concurrent");
                }
                if (scenario == BACKUP_OCCUPIED) Create(root_fd, "backup", "unrelated");
                if (scenario == WRONG_INPUT) expected[2]++;
                hook = scenario == LATE_TARGET || scenario == ROOT_MOVED ? "before-foundation-replace" :
                    scenario == FINAL_TARGET || scenario == FINAL_TAGS ? "projection-final-check" :
                    scenario == BACKUP_CHANGED ? "replacement-backup-read" :
                    scenario == BACKUP_MOVED ? "before-backup-name-check" : NULL;
                NSURL *staged = [directory URLByAppendingPathComponent:@"prepared"];
                int ready[2] = {-1, -1}, finished[2] = {-1, -1}; pid_t reader = -1;
                if (scenario == NORMAL && !crash_boundary) {
                    int prepared = openat(stage_fd, "prepared", O_RDONLY | O_NOFOLLOW); Require(prepared >= 0);
                    struct stat staged_metadata; Require(fstat(prepared, &staged_metadata) == 0); close(prepared);
                    Require(pipe(ready) == 0 && pipe(finished) == 0);
                    reader = fork(); Require(reader >= 0);
                    if (!reader) {
                        close(ready[0]); close(finished[0]);
                        ObserveReplacement(ready[1], finished[1], &original_metadata, &staged_metadata);
                    }
                    close(ready[1]); close(finished[1]);
                    char value; Require(read(ready[0], &value, 1) == 1 && value == 'r'); close(ready[0]);
                }
                NSFileCoordinator *coordinator = [[ProjectionReplacementCoordinator alloc] initWithFilePresenter:nil];
                if (scenario == REPLACEMENT_CANCELLED) [coordinator cancel];
                NVProjectionReplacementResult result; install_calls = 0; replaced = 0;
                NVAppleReplaceProjection(coordinator, (__bridge CFURLRef)root, (__bridge CFURLRef)staged,
                    owner, stage, "Note.txt", "backup", expected, (const uint8_t *)"old", 3,
                    (const uint8_t *)output, strlen(output), &metadata, &result);
                if (reader > 0) {
                    ProjectionReaderResult observed; int status;
                    Require(read(finished[0], &observed, sizeof(observed)) == sizeof(observed)); close(finished[0]);
                    Require(waitpid(reader, &status, 0) == reader && WIFEXITED(status) && WEXITSTATUS(status) == 0);
                    Require(observed.old_count > 0 && observed.new_count > 0 && observed.inconsistent == 0);
                    fprintf(stderr, "reader old=%u new=%u inconsistent=%u\n", observed.old_count, observed.new_count, observed.inconsistent);
                }
                BOOL before = scenario == BEFORE_CHANGED || scenario == BACKUP_OCCUPIED || scenario == WRONG_INPUT ||
                    scenario == WRONG_STAGE || scenario == REPLACEMENT_CANCELLED;
                BOOL uncertain = scenario == FINAL_TARGET || scenario == FINAL_TAGS || scenario == BACKUP_CHANGED || scenario == BACKUP_MOVED ||
                    scenario == BEFORE_EFFECT_ERROR || scenario == AFTER_EFFECT_ERROR;
                fprintf(stderr, "scenario %d: outcome=%d error=%d backup=%d backupError=%d\n", scenario,
                    result.installation.outcome, result.installation.error, result.backup_comparison, result.backup_error);
                Require((result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain));
                Require(install_calls == (before ? 0 : 1));
                if (before || scenario == BEFORE_EFFECT_ERROR) {
                    Body(root_fd, "Note.txt", scenario == BEFORE_CHANGED ? "concurrent" : "old");
                    Require(result.backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED);
                    if (scenario == BACKUP_OCCUPIED) Body(root_fd, "backup", "unrelated");
                } else {
                    Body(root_fd, "Note.txt", scenario == FINAL_TARGET ? "concurrent" : output);
                    Body(root_fd, scenario == BACKUP_MOVED ? "preserved-backup" : "backup",
                        scenario == LATE_TARGET ? "concurrent" : scenario == BACKUP_CHANGED ? "changed" : "old");
                    if (!uncertain) {
                        Require(result.backup_comparison == (scenario == LATE_TARGET ? NV_PROJECTION_BACKUP_CHANGED : NV_PROJECTION_BACKUP_EXPECTED));
                        int fd = openat(root_fd, "Note.txt", O_RDONLY | O_NOFOLLOW); Require(fd >= 0);
                        char attr[16]; Require(fgetxattr(fd, "org.notationalvelocity.test-unrelated", attr, sizeof(attr), 0, 0) == 4 && !memcmp(attr, "keep", 4));
                        struct stat current; Require(fstat(fd, &current) == 0 && (current.st_mode & 0777) == 0640);
                        close(fd);
                    }
                }
                if (scenario == ROOT_MOVED) {
                    int other = open(root_path, O_RDONLY | O_DIRECTORY); Require(other >= 0); Body(other, "Note.txt", "foreign"); close(other);
                }
                nv_projection_stage_close(stage); close(stage_fd); nv_root_close(owner);
                Require(crash_boundary == NULL);
            }
        }
        printf("PASS: projection replacement %d native/Foundation scenarios\n", CASE_COUNT);
    }
}
