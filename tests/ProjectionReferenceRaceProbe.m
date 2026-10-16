/* Places an uncoordinated replacement after the final check and before Foundation. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>

static void Require(BOOL value) { if (!value) abort(); }
static NSString *Body(NSURL *url) {
    return [[[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] autorelease] ?: @"absent";
}
int main(int argc, const char **argv) {
    if (argc != 3 && argc != 4) return 2;
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *fixture = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *root = [fixture URLByAppendingPathComponent:@"notes"], *outside = [fixture URLByAppendingPathComponent:@"outside"];
        Require([fm createDirectoryAtURL:root withIntermediateDirectories:NO attributes:nil error:NULL]);
        Require([fm createDirectoryAtURL:outside withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSURL *current = [root URLByAppendingPathComponent:@"note.txt"], *other = [fixture URLByAppendingPathComponent:@"concurrent.txt"];
        BOOL moveRoot = argc == 4 && !strcmp(argv[3], "root");
        BOOL backupCollision = argc == 4 && !strcmp(argv[3], "backup");
        NSURL *movedRoot = [outside URLByAppendingPathComponent:@"moved-root"];
        NSURL *moved = moveRoot ? [movedRoot URLByAppendingPathComponent:@"note.txt"] : [outside URLByAppendingPathComponent:@"moved.txt"];
        Require([@"old" writeToURL:current atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        Require([@"concurrent" writeToURL:other atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        NSURL *directory = [fm URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:current create:YES error:NULL];
        Require(directory != nil);
        NSURL *stage = [directory URLByAppendingPathComponent:@"stage"];
        Require([@"new" writeToURL:stage atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        NSURL *requested = !strcmp(argv[2], "file") ? current.fileReferenceURL :
            !strcmp(argv[2], "parent") ? [root.fileReferenceURL URLByAppendingPathComponent:@"note.txt"] : current;
        if (!strcmp(argv[2], "relative")) requested = [NSURL URLWithString:@"note.txt" relativeToURL:root.fileReferenceURL];
        if (!strcmp(argv[2], "file-relative")) requested = [NSURL fileURLWithPath:@"note.txt" isDirectory:NO relativeToURL:root.fileReferenceURL];
        if (!strcmp(argv[2], "cf-parent")) requested = [(NSURL *)CFURLCreateCopyAppendingPathComponent(
            kCFAllocatorDefault, (CFURLRef)root.fileReferenceURL, CFSTR("note.txt"), false) autorelease];
        Require(requested != nil);
        const char *currentPath = current.fileSystemRepresentation, *otherPath = other.fileSystemRepresentation;
        const char *movedPath = moved.fileSystemRepresentation;
        const char *rootPath = root.fileSystemRepresentation, *movedRootPath = movedRoot.fileSystemRepresentation;
        const char *backupPath = [root URLByAppendingPathComponent:@"retained-original"].fileSystemRepresentation;
        int start[2], finished[2]; Require(pipe(start) == 0 && pipe(finished) == 0);
        pid_t child = fork(); Require(child >= 0);
        if (!child) {
            close(start[1]); close(finished[0]); char signal;
            if (read(start[0], &signal, 1) != 1) _exit(3);
            if (backupCollision) {
                if (rename(otherPath, backupPath)) _exit(4);
            } else if (moveRoot) {
                if (rename(rootPath, movedRootPath) || mkdir(rootPath, 0700) || rename(otherPath, currentPath)) _exit(4);
            } else if (rename(currentPath, movedPath) || rename(otherPath, currentPath)) _exit(4);
            if (write(finished[1], "x", 1) != 1) _exit(5);
            _exit(0);
        }
        close(start[0]); close(finished[1]);
        int trigger = start[1], completion = finished[0];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block BOOL entered = NO, replaced = NO, actualReference = NO;
        __block NSError *effectError = nil; NSError *coordinateError = nil;
        [coordinator coordinateWritingItemAtURL:stage options:NSFileCoordinatorWritingForMoving
            writingItemAtURL:requested options:NSFileCoordinatorWritingForReplacing error:&coordinateError
            byAccessor:^(NSURL *from, NSURL *to) {
                entered = YES; actualReference = to.isFileReferenceURL;
                Require([Body(current) isEqual:@"old"] && [Body(to) isEqual:@"old"]);
                Require(![fm fileExistsAtPath:[root URLByAppendingPathComponent:@"retained-original"].path]);
                Require(write(trigger, "x", 1) == 1); char signal;
                Require(read(completion, &signal, 1) == 1);
                replaced = [fm replaceItemAtURL:to withItemAtURL:from backupItemName:@"retained-original"
                    options:NSFileManagerItemReplacementWithoutDeletingBackupItem resultingItemURL:NULL error:&effectError];
            }];
        if (!entered) Require(write(start[1], "x", 1) == 1);
        close(start[1]); close(finished[0]); int status;
        Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        NSDictionary *result = @{@"requested": [NSString stringWithUTF8String:argv[2]], @"actualReference": @(actualReference),
            @"moveRoot": @(moveRoot), @"requestedHasReferenceAnchor": @([requested.absoluteString containsString:@"/.file/"]),
            @"entered": @(entered), @"replaced": @(replaced), @"error": @((effectError ?: coordinateError).code),
            @"current": Body(current), @"movedOutside": Body(moved),
            @"rootBackup": Body([root URLByAppendingPathComponent:@"retained-original"]),
            @"outsideBackup": Body([(moveRoot ? movedRoot : outside) URLByAppendingPathComponent:@"retained-original"])};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        Require(fwrite(json.bytes, 1, json.length, stdout) == json.length); puts("");
        [coordinator release];
    }
    return 0;
}
