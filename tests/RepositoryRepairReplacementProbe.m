#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

static void Require(BOOL value) { if (!value) abort(); }
static NSString *Body(NSURL *item, BOOL directory) {
    NSURL *leaf = directory ? [item URLByAppendingPathComponent:@"body"] : item;
    return [[[NSString alloc] initWithContentsOfURL:leaf encoding:NSUTF8StringEncoding error:NULL] autorelease];
}
static void Create(NSURL *item, BOOL directory, NSString *body) {
    if (directory) Require([[NSFileManager defaultManager] createDirectoryAtURL:item withIntermediateDirectories:NO attributes:nil error:NULL]);
    Require([body writeToURL:directory ? [item URLByAppendingPathComponent:@"body"] : item atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
}

/* A pipe places a real uncoordinated writer immediately after the last expected-entry check. */
int main(int argc, const char **argv) {
    if (argc != 4) return 2;
    @autoreleasepool {
        BOOL directory = !strcmp(argv[2], "directory"), race = strcmp(argv[3], "none") != 0;
        BOOL childEdit = !strcmp(argv[3], "child");
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSURL *current = [root URLByAppendingPathComponent:@"current"], *other = [root URLByAppendingPathComponent:@"concurrent"];
        NSURL *original = [root URLByAppendingPathComponent:@"original"], *backup = [root URLByAppendingPathComponent:@"backup"];
        Create(current, directory, @"old"); Create(other, directory, @"concurrent");
        NSURL *staging = [[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:current create:YES error:NULL];
        Require(staging != nil);
        NSURL *stage = [staging URLByAppendingPathComponent:@"replacement"];
        Create(stage, directory, @"replacement");
        const char *currentPath = [current fileSystemRepresentation], *otherPath = [other fileSystemRepresentation];
        const char *originalPath = [original fileSystemRepresentation];
        const char *childPath = [[current URLByAppendingPathComponent:@"body"] fileSystemRepresentation];
        struct stat before; Require(lstat(currentPath, &before) == 0);
        int start[2], finished[2]; Require(pipe(start) == 0 && pipe(finished) == 0);
        pid_t child = fork(); Require(child >= 0);
        if (child == 0) {
            close(start[1]); close(finished[0]); char signal;
            if (read(start[0], &signal, 1) != 1) _exit(3);
            if (race) {
                if (childEdit) {
                    int fd = open(childPath, O_WRONLY | O_TRUNC | O_NOFOLLOW);
                    if (fd < 0 || write(fd, "concurrent", 10) != 10 || close(fd)) _exit(4);
                } else if (rename(currentPath, originalPath) || rename(otherPath, currentPath)) _exit(5);
            }
            if (write(finished[1], "x", 1) != 1) _exit(6);
            _exit(0);
        }
        close(start[0]); close(finished[1]);
        int trigger = start[1], completion = finished[0];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block BOOL entered = NO, checked = NO, replaced = NO;
        __block NSError *effectError = nil;
        NSError *coordinationError = nil;
        [coordinator coordinateWritingItemAtURL:stage options:NSFileCoordinatorWritingForMoving
            writingItemAtURL:current options:NSFileCoordinatorWritingForReplacing error:&coordinationError
            byAccessor:^(NSURL *from, NSURL *to) {
                entered = YES;
                struct stat now;
                checked = lstat([to fileSystemRepresentation], &now) == 0 && now.st_dev == before.st_dev && now.st_ino == before.st_ino && [Body(to, directory) isEqual:@"old"];
                Require(checked);
                Require(write(trigger, "x", 1) == 1);
                char signal; Require(read(completion, &signal, 1) == 1);
                replaced = [[NSFileManager defaultManager] replaceItemAtURL:to withItemAtURL:from backupItemName:@"backup"
                    options:NSFileManagerItemReplacementWithoutDeletingBackupItem | NSFileManagerItemReplacementUsingNewMetadataOnly
                    resultingItemURL:NULL error:&effectError];
            }];
        if (!entered) Require(write(start[1], "x", 1) == 1);
        int status; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        close(start[1]); close(finished[0]);
        NSString *installed = Body(current, directory) ?: @"unavailable", *displaced = Body(backup, directory) ?: @"unavailable";
        NSDictionary *result = @{@"kind": directory ? @"directory" : @"file", @"race": [NSString stringWithUTF8String:argv[3]],
            @"coordinated": @(entered && coordinationError == nil), @"checkedOld": @(checked), @"apiSucceeded": @(replaced),
            @"current": installed, @"backup": displaced, @"noWriteMismatch": @(!race || [installed isEqual:@"concurrent"]),
            @"error": @([(effectError ?: coordinationError) code])};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        Require(fwrite([json bytes], 1, [json length], stdout) == [json length]); puts("");
        [coordinator release];
    }
    return 0;
}
