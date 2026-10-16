/* Measures staged metadata and descriptor identity through Foundation safe replacement. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/wait.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define Require(value) do { if (!(value)) { fprintf(stderr, "line %d: %s (errno %d)\n", __LINE__, #value, errno); abort(); } } while (0)
static NSData *Attribute(int fd, const char *name) {
    char bytes[256]; ssize_t size = fgetxattr(fd, name, bytes, sizeof(bytes), 0, 0);
    Require(size >= 0); return [NSData dataWithBytes:bytes length:(NSUInteger)size];
}
static void Set(int fd, const char *name, const char *value) {
    Require(fsetxattr(fd, name, value, strlen(value), 0, 0) == 0);
}
static NSString *Text(NSData *value) {
    return [[[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] autorelease];
}
/* Captures the named inode's bytes independently of Foundation URL loading. */
static NSString *RawBody(NSURL *url) {
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        int saved = errno;
        fprintf(stderr, "raw fixture open failed: %s: %s\n", url.fileSystemRepresentation, strerror(saved));
        errno = saved;
    }
    Require(fd >= 0);
    struct stat before, after; Require(fstat(fd, &before) == 0 && before.st_size == 3);
    char bytes[3]; Require(pread(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
    Require(fstat(fd, &after) == 0 && before.st_ino == after.st_ino && before.st_size == after.st_size);
    close(fd);
    return Text([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}

typedef struct { unsigned old_count, new_count, inconsistent; } ReaderResult;
static void Observe(const char *path, int ready, int finished) {
    ReaderResult result = {0};
    time_t deadline = time(NULL) + 15;
    while (time(NULL) < deadline) {
        int fd = open(path, O_RDONLY | O_NOFOLLOW);
        if (fd < 0) continue;
        struct stat before, after;
        char body[8] = {0}, encoding[32] = {0}, tags[32] = {0}, stamp[32] = {0};
        BOOL complete = fstat(fd, &before) == 0 && read(fd, body, sizeof(body)) == 3 &&
            fgetxattr(fd, "com.apple.TextEncoding", encoding, sizeof(encoding) - 1, 0, 0) > 0 &&
            fgetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", tags, sizeof(tags) - 1, 0, 0) > 0 &&
            fgetxattr(fd, "org.notationalvelocity.projection#S", stamp, sizeof(stamp) - 1, 0, 0) > 0 &&
            fstat(fd, &after) == 0;
        close(fd);
        if (!complete || before.st_ino != after.st_ino || before.st_dev != after.st_dev ||
            before.st_size != after.st_size || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
            before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
            before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) continue;
        if (!strcmp(body, "old") && !strcmp(encoding, "old-encoding") &&
            !strcmp(tags, "old-tags") && !strcmp(stamp, "old-stamp") &&
            after.st_mtimespec.tv_sec == 1700000001 && after.st_mtimespec.tv_nsec == 123456789) {
            if (++result.old_count == 1 && write(ready, "x", 1) != 1) _exit(5);
        } else if (!strcmp(body, "new") && !strcmp(encoding, "new-encoding") &&
            !strcmp(tags, "new-tags") && !strcmp(stamp, "new-stamp") &&
            after.st_mtimespec.tv_sec == 1700000003 && after.st_mtimespec.tv_nsec == 234567890) {
            result.new_count++; break;
        } else { result.inconsistent++; break; }
    }
    if (write(finished, &result, sizeof(result)) != sizeof(result)) _exit(6);
    _exit(0);
}

int main(int argc, const char **argv) {
    if (argc != 3) return 2;
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *destination = [root URLByAppendingPathComponent:@"note.txt"];
        Require([@"old" writeToURL:destination atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        int original = open(destination.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW); Require(original >= 0);
        Set(original, "com.apple.TextEncoding", "old-encoding");
        Set(original, "com.apple.metadata:kMDItemOMUserTags", "old-tags");
        Set(original, "org.notationalvelocity.projection#S", "old-stamp");
        Set(original, "org.notationalvelocity.test-unrelated", "unrelated");
        const struct timespec oldDates[2] = {{1700000000, 0}, {1700000001, 123456789}};
        Require(futimens(original, oldDates) == 0);
        NSURL *directory = [fm URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:destination create:YES error:NULL];
        Require(directory != nil);
        NSURL *stage = [directory URLByAppendingPathComponent:@"stage"];
        Require([@"new" writeToURL:stage atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        int staged = open(stage.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW); Require(staged >= 0);
        Set(staged, "com.apple.TextEncoding", "new-encoding");
        Set(staged, "com.apple.metadata:kMDItemOMUserTags", "new-tags");
        Set(staged, "org.notationalvelocity.projection#S", "new-stamp");
        Set(staged, "org.notationalvelocity.test-unrelated", "unrelated");
        const struct timespec newDates[2] = {{1700000002, 0}, {1700000003, 234567890}};
        Require(futimens(staged, newDates) == 0);
        Require(fsync(staged) == 0);
        NSURL *reference = destination.fileReferenceURL; Require(reference != nil);
        const char *observedPath = destination.fileSystemRepresentation;
        int ready[2], finished[2]; Require(pipe(ready) == 0 && pipe(finished) == 0);
        pid_t reader = fork(); Require(reader >= 0);
        if (!reader) {
            close(ready[0]); close(finished[0]); Observe(observedPath, ready[1], finished[1]);
        }
        close(ready[1]); close(finished[1]);
        char signal; Require(read(ready[0], &signal, 1) == 1); close(ready[0]);
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block BOOL entered = NO, replaced = NO; __block NSError *replaceError = nil;
        NSError *coordinateError = nil;
        NSUInteger options = NSFileManagerItemReplacementWithoutDeletingBackupItem;
        if (!strcmp(argv[2], "new")) options |= NSFileManagerItemReplacementUsingNewMetadataOnly;
        [coordinator coordinateWritingItemAtURL:stage options:NSFileCoordinatorWritingForMoving
            writingItemAtURL:reference options:NSFileCoordinatorWritingForReplacing error:&coordinateError
            byAccessor:^(NSURL *from, NSURL *to) {
                entered = YES;
                replaced = [fm replaceItemAtURL:to withItemAtURL:from backupItemName:@"retained-original"
                    options:options resultingItemURL:NULL error:&replaceError];
            }];
        int installed = open(destination.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW); Require(installed >= 0);
        ReaderResult readerResult; Require(read(finished[0], &readerResult, sizeof(readerResult)) == sizeof(readerResult));
        close(finished[0]); int readerStatus;
        Require(waitpid(reader, &readerStatus, 0) == reader && WIFEXITED(readerStatus) && WEXITSTATUS(readerStatus) == 0);
        struct stat held, named; Require(fstat(staged, &held) == 0 && fstat(installed, &named) == 0);
        NSURL *backup = [root URLByAppendingPathComponent:@"retained-original"];
        NSError *backupReadError = nil;
        NSData *backupData = [NSData dataWithContentsOfURL:backup options:0 error:&backupReadError];
        NSDictionary *result = @{@"options": [NSString stringWithUTF8String:argv[2]],
            @"entered": @(entered), @"replaced": @(replaced), @"error": @((replaceError ?: coordinateError).code),
            @"stageIdentity": @(held.st_dev == named.st_dev && held.st_ino == named.st_ino),
            @"mtimeSeconds": @(named.st_mtimespec.tv_sec), @"mtimeNanos": @(named.st_mtimespec.tv_nsec),
            @"readerOld": @(readerResult.old_count), @"readerNew": @(readerResult.new_count),
            @"readerInconsistent": @(readerResult.inconsistent),
            @"body": Text([NSData dataWithContentsOfURL:destination]) ?: @"unreadable",
            @"backup": Text(backupData) ?: @"unreadable",
            @"backupReadError": @(backupReadError.code), @"backupReadDomain": backupReadError.domain ?: @"",
            @"rawBackup": RawBody(backup), @"rawBody": RawBody(destination),
            @"encoding": Text(Attribute(installed, "com.apple.TextEncoding")),
            @"tags": Text(Attribute(installed, "com.apple.metadata:kMDItemOMUserTags")),
            @"stamp": Text(Attribute(installed, "org.notationalvelocity.projection#S")),
            @"unrelated": Text(Attribute(installed, "org.notationalvelocity.test-unrelated"))};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        Require(fwrite(json.bytes, 1, json.length, stdout) == json.length); puts("");
        Require(readerResult.old_count > 0 && readerResult.new_count > 0 && readerResult.inconsistent == 0);
        close(original); close(staged); close(installed); [coordinator release];
    }
    return 0;
}
