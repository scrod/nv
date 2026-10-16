#import "NVAppleProjectionReplacement.h"
#import "NVAppleNamespaceInternal.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#ifndef NV_PROJECTION_FILE_MANAGER
#define NV_PROJECTION_FILE_MANAGER [NSFileManager defaultManager]
#endif

CFURLRef NVAppleProjectionURL(CFURLRef root, CFStringRef leaf) {
    NSString *name = (__bridge NSString *)leaf;
    const char *encoded = name.UTF8String;
    if (!CFURLIsFileReferenceURL(root) || !encoded || !strlen(encoded) || strlen(encoded) > 255 ||
        strchr(encoded, '/') || !strcmp(encoded, ".") || !strcmp(encoded, "..") ||
        [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != strlen(encoded)) return NULL;
    return CFBridgingRetain([NSURL fileURLWithPath:name isDirectory:NO relativeToURL:(__bridge NSURL *)root]);
}

/* The C primitive invokes this borrowed block synchronously within coordination. */
static int Replace(void *context, int descriptor) {
    int (^operation)(int) = (__bridge int (^)(int))context;
    return operation(descriptor);
}

static int Code(NSError *error) {
    if ([error.domain isEqual:NSPOSIXErrorDomain] && error.code > 0 && error.code <= INT_MAX) return (int)error.code;
    if ([error.domain isEqual:NSCocoaErrorDomain] && error.code == NSUserCancelledError) return ECANCELED;
    return EIO;
}

typedef void (^ProjectionMoveNotice)(int restoring, int completed);
static void SourceMoveNotice(void *context, int restoring, int completed) {
    ((__bridge ProjectionMoveNotice)context)(restoring, completed);
}

void NVAppleQuarantineProjection(NSFileCoordinator *coordinator, CFURLRef root, NVRootOwner *owner,
    const char *source, const char *recovery, const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    NVProjectionSourceResult *result) {
    *result = (NVProjectionSourceResult){0};
    NSString *sourceName = [NSString stringWithUTF8String:source], *recoveryName = [NSString stringWithUTF8String:recovery];
    if (!sourceName || !recoveryName) { result->error = EINVAL; return; }
    CFURLRef from = NVAppleProjectionURL(root, (__bridge CFStringRef)sourceName);
    CFURLRef to = NVAppleProjectionURL(root, (__bridge CFStringRef)recoveryName);
    if (!from || !to) {
        if (from) CFRelease(from); if (to) CFRelease(to);
        result->error = EINVAL; return;
    }
    NSError *error = nil;
    __block BOOL entered = NO;
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)from options:NSFileCoordinatorWritingForMoving
        writingItemAtURL:(__bridge NSURL *)to options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *actualSource, NSURL *actualRecovery) {
            entered = YES;
            if (!NVAppleNamespaceHasRoot((__bridge CFURLRef)actualSource, root, (__bridge CFStringRef)sourceName) ||
                !NVAppleNamespaceHasRoot((__bridge CFURLRef)actualRecovery, root, (__bridge CFStringRef)recoveryName)) {
                result->error = ESTALE; return;
            }
            ProjectionMoveNotice notice = ^(int restoring, int completed) {
                NSURL *oldURL = restoring ? actualRecovery : actualSource;
                NSURL *newURL = restoring ? actualSource : actualRecovery;
                if (completed) [coordinator itemAtURL:oldURL didMoveToURL:newURL];
                else [coordinator itemAtURL:oldURL willMoveToURL:newURL];
            };
            nv_projection_quarantine_source(owner, source, recovery, expected, maximum, descriptor,
                (__bridge void *)notice, SourceMoveNotice, result);
        }];
    CFRelease(from); CFRelease(to);
    if (!entered) {
        result->error = Code(error);
        if (nv_root_validate(owner)) result->root_lost = 1;
    } else if (error) { result->outcome = NV_PROJECTION_SOURCE_UNCERTAIN; result->error = Code(error); }
}

void NVAppleRemoveProjectionSource(NSFileCoordinator *coordinator, CFURLRef root, NVRootOwner *owner,
    const char *source, const char *recovery, const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    NVProjectionCleanupResult *result) {
    *result = (NVProjectionCleanupResult){0};
    NSString *name = [NSString stringWithUTF8String:source], *key = [NSString stringWithUTF8String:recovery];
    CFURLRef target = name ? NVAppleProjectionURL(root, (__bridge CFStringRef)name) : NULL;
    CFURLRef reserved = key ? NVAppleProjectionURL(root, (__bridge CFStringRef)key) : NULL;
    NSString *directory = [key stringByAppendingString:@".cleanup"];
    if (!target || !reserved || [directory lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) {
        if (target) CFRelease(target);
        if (reserved) CFRelease(reserved);
        result->error = EINVAL; return;
    }
    CFRelease(reserved);
    NSURL *protected = [NSURL fileURLWithPath:directory isDirectory:YES relativeToURL:(__bridge NSURL *)root];
    NSURL *child = [NSURL fileURLWithPath:@"item" isDirectory:NO relativeToURL:protected];
    __block BOOL entered = NO; NSError *error = nil;
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)target options:NSFileCoordinatorWritingForDeleting
        writingItemAtURL:child options:0 error:&error byAccessor:^(NSURL *actual, NSURL *to) {
            entered = YES;
            if (!NVAppleNamespaceHasRoot((__bridge CFURLRef)actual, root, (__bridge CFStringRef)name) ||
                !NVAppleNamespaceHasRoot((__bridge CFURLRef)to, root, (__bridge CFStringRef)[directory stringByAppendingPathComponent:@"item"])) {
                result->error = ESTALE; return;
            }
            nv_projection_remove_source(owner, source, recovery, expected, maximum, descriptor, result);
        }];
    CFRelease(target);
    if (!entered) {
        result->error = Code(error);
        if (nv_root_validate(owner)) result->root_lost = 1;
    } else if (error) { result->outcome = NV_PROJECTION_CLEANUP_UNCERTAIN; result->error = Code(error); }
}

void NVAppleRelocateProjection(NSFileCoordinator *coordinator, CFURLRef root, CFURLRef stageURL,
    NVRootOwner *owner, NVProjectionStage *stage, const char *source, const char *destination, const char *backup,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionRelocationResult *result) {
    *result = (NVProjectionRelocationResult){0};
    NSString *sourceName = [NSString stringWithUTF8String:source], *destinationName = [NSString stringWithUTF8String:destination];
    CFURLRef from = sourceName ? NVAppleProjectionURL(root, (__bridge CFStringRef)sourceName) : NULL;
    CFURLRef to = destinationName ? NVAppleProjectionURL(root, (__bridge CFStringRef)destinationName) : NULL;
    if (!from || !to) {
        if (from) CFRelease(from); if (to) CFRelease(to);
        result->replacement.installation.error = EINVAL; return;
    }
    NSError *error = nil;
    __block BOOL entered = NO;
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)from options:NSFileCoordinatorWritingForMoving
        writingItemAtURL:(__bridge NSURL *)to options:0 error:&error byAccessor:^(NSURL *actualSource, NSURL *actualDestination) {
            if (!NVAppleNamespaceHasRoot((__bridge CFURLRef)actualSource, root, (__bridge CFStringRef)sourceName) ||
                !NVAppleNamespaceHasRoot((__bridge CFURLRef)actualDestination, root, (__bridge CFStringRef)destinationName)) {
                result->replacement.installation.error = ESTALE; return;
            }
            /* The two-write accessor permits this single-write nesting for its private stage. */
            NSError *stageError = nil;
            [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)stageURL options:NSFileCoordinatorWritingForMoving
                error:&stageError byAccessor:^(NSURL *actualStage) {
                    entered = YES;
                    const char *path = actualStage.fileSystemRepresentation;
                    int staged = path ? open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) : -1;
                    if (staged < 0) { result->replacement.installation.error = path ? errno : ESTALE; return; }
                    [coordinator itemAtURL:actualSource willMoveToURL:actualDestination];
                    nv_projection_relocate(owner, stage, source, destination, backup, expected, maximum, descriptor, staged,
                        bytes, count, metadata, result);
                    close(staged);
                    if (result->replacement.installation.outcome == NV_PROJECTION_INSTALLED)
                        [coordinator itemAtURL:actualSource didMoveToURL:actualDestination];
                }];
            if (stageError) {
                if (entered) result->replacement.installation.outcome = NV_PROJECTION_UNCERTAIN;
                result->replacement.installation.error = Code(stageError);
            }
        }];
    CFRelease(from); CFRelease(to);
    if (!entered) {
        if (!result->replacement.installation.error) result->replacement.installation.error = Code(error);
        if (nv_root_validate(owner)) result->replacement.installation.root_lost = 1;
    } else if (error) {
        result->replacement.installation.outcome = NV_PROJECTION_UNCERTAIN;
        result->replacement.installation.error = Code(error);
    }
}

void NVAppleReplaceProjection(NSFileCoordinator *coordinator, CFURLRef root, CFURLRef stageURL,
    NVRootOwner *owner, NVProjectionStage *stage, const char *destination, const char *backup,
    const uint64_t *expected, const uint8_t *previous, uint64_t previousCount,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionReplacementResult *result) {
    *result = (NVProjectionReplacementResult){0};
    NSString *leaf = [NSString stringWithUTF8String:destination], *backupName = [NSString stringWithUTF8String:backup];
    if (!leaf || !backupName) { result->installation.error = EINVAL; return; }
    CFURLRef requested = NVAppleProjectionURL(root, (__bridge CFStringRef)leaf);
    if (!requested) { result->installation.error = EINVAL; return; }
    NSError *error = nil;
    __block BOOL entered = NO;
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)stageURL options:NSFileCoordinatorWritingForMoving
        writingItemAtURL:(__bridge NSURL *)requested options:0 error:&error
        byAccessor:^(NSURL *from, NSURL *to) {
            entered = YES;
            if (!NVAppleNamespaceHasRoot((__bridge CFURLRef)to, root, (__bridge CFStringRef)leaf)) {
                result->installation.error = ESTALE; return;
            }
            int (^replace)(int) = ^int(int descriptor) {
                const char *path = from.fileSystemRepresentation;
                if (!path) return ESTALE;
                int actual = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
                if (actual < 0) return errno;
                struct stat held, named;
                int observed = fstat(descriptor, &held) || fstat(actual, &named);
                int saved = errno; close(actual);
                if (observed) return saved;
                if (!S_ISREG(named.st_mode) || named.st_nlink != 1 ||
                    held.st_dev != named.st_dev || held.st_ino != named.st_ino) return ESTALE;
                NSError *replacementError = nil;
                /* The stage already carries preserved custom metadata and exact note-owned values. */
                BOOL replaced = [NV_PROJECTION_FILE_MANAGER replaceItemAtURL:to withItemAtURL:from
                    backupItemName:backupName options:NSFileManagerItemReplacementUsingNewMetadataOnly |
                        NSFileManagerItemReplacementWithoutDeletingBackupItem
                    resultingItemURL:NULL error:&replacementError];
                return replaced ? 0 : Code(replacementError);
            };
            nv_projection_replace(owner, stage, destination, backup, expected, previous, previousCount,
                bytes, count, metadata, (__bridge void *)replace, Replace, result);
        }];
    CFRelease(requested);
    if (!entered) {
        result->installation.error = Code(error);
        if (nv_root_validate(owner)) result->installation.root_lost = 1;
    } else if (error) {
        result->installation.outcome = NV_PROJECTION_UNCERTAIN;
        result->installation.error = Code(error);
    }
}
