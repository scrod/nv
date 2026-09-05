#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>
#include <errno.h>

// Synthetic fixtures only. Observations, not a rename-log completeness test.
// ponytail: one bounded sequential fixture; no production watcher or parser.
static NSFileHandle *resultLog;
static void Check(BOOL ok, NSString *operation) {
    if (!ok) { fprintf(stderr, "FAIL %s errno=%d\n", operation.UTF8String, errno); exit(1); }
}
static void JSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    Check(data != nil, @"encode result");
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    [resultLog writeData:data]; [resultLog writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
static void OpenLog(NSString *fixture) {
    NSString *path = [fixture stringByAppendingPathComponent:@"observations.jsonl"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        Check([[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil], @"create observation log");
    resultLog = [NSFileHandle fileHandleForWritingAtPath:path];
    Check(resultLog != nil, @"open observation log"); [resultLog seekToEndOfFile];
}
static NSString *DatabaseUUID(dev_t device) {
    CFUUIDRef uuid = FSEventsCopyUUIDForDevice(device);
    if (!uuid) return @"unavailable";
    NSString *value = [(NSString *)CFUUIDCreateString(NULL, uuid) autorelease];
    CFRelease(uuid); return value;
}
static NSDictionary *Snapshot(NSString *path) {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s)) return @{@"errno": @(errno)};
    id doc = nil;
    [[NSURL fileURLWithPath:path] getResourceValue:&doc forKey:NSURLDocumentIdentifierKey error:NULL];
    return @{@"device": @(s.st_dev), @"fileID": @(s.st_ino), @"links": @(s.st_nlink),
             @"size": @(s.st_size), @"docID": doc ?: [NSNull null]};
}
typedef struct { NSMutableArray *events; BOOL historyDone; } Capture;
static void Callback(ConstFSEventStreamRef stream, void *info, size_t n, void *paths,
                     const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    Capture *capture = info;
    NSArray *items = (NSArray *)paths;
    for (size_t i = 0; i < n; i++) {
        NSDictionary *item = items[i];
        NSMutableArray *names = [NSMutableArray array];
#define FLAG(f) if (flags[i] & kFSEventStreamEventFlag##f) [names addObject:@#f]
        FLAG(ItemCreated); FLAG(ItemRemoved); FLAG(ItemRenamed); FLAG(ItemModified);
        FLAG(ItemIsHardlink); FLAG(ItemIsLastHardlink); FLAG(ItemCloned); FLAG(ItemInodeMetaMod); FLAG(OwnEvent); FLAG(HistoryDone);
        FLAG(MustScanSubDirs); FLAG(UserDropped); FLAG(KernelDropped); FLAG(EventIdsWrapped); FLAG(RootChanged);
#undef FLAG
        [capture->events addObject:@{@"id": @(ids[i]), @"flags": @(flags[i]), @"names": names,
            @"historical": @(!capture->historyDone), @"data": item}];
        if (flags[i] & kFSEventStreamEventFlagHistoryDone) capture->historyDone = YES;
    }
}
static FSEventStreamRef Start(NSString *root, FSEventStreamEventId cursor, Capture *capture) {
    struct stat s, alias; struct statfs fs;
    Check(stat(root.fileSystemRepresentation, &s) == 0 && statfs(root.fileSystemRepresentation, &fs) == 0, @"stat root");
    NSString *mount = [NSString stringWithUTF8String:fs.f_mntonname];
    NSString *relative = nil;
    if ([mount isEqualToString:@"/"]) relative = [root substringFromIndex:1];
    else if ([root hasPrefix:[mount stringByAppendingString:@"/"]]) relative = [root substringFromIndex:mount.length + 1];
    else {
        // Verify the Data-volume firmlink spelling; do not guess another volume.
        NSString *candidate = [mount stringByAppendingString:root];
        JSON(@{@"stage": @"volume-relative-check", @"root": root, @"mount": mount, @"candidate": candidate});
        Check(stat(candidate.fileSystemRepresentation, &alias) == 0 && s.st_dev == alias.st_dev && s.st_ino == alias.st_ino,
              @"resolve volume-relative path");
        relative = [root substringFromIndex:1];
    }
    FSEventStreamContext context = {0, capture, NULL, NULL, NULL};
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
        kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagFullHistory |
        kFSEventStreamCreateWithDocID | kFSEventStreamCreateFlagMarkSelf | kFSEventStreamCreateFlagWatchRoot;
    FSEventStreamRef stream = FSEventStreamCreateRelativeToDevice(NULL, Callback, &context, s.st_dev,
        (CFArrayRef)@[relative], cursor, 0.2, flags);
    Check(stream != NULL, @"create stream");
    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    Check(FSEventStreamStart(stream), @"start stream");
    JSON(@{@"stage": @"stream", @"root": root, @"relative": relative, @"mount": mount,
        @"device": @(s.st_dev), @"databaseUUID": DatabaseUUID(s.st_dev), @"cursor": @(cursor), @"flags": @(flags)});
    return stream;
}
static void Pump(NSTimeInterval seconds) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}
static BOOL SawLeaf(Capture *capture, NSString *leaf) {
    for (NSDictionary *e in capture->events) {
        NSString *p = e[@"data"][(NSString *)kFSEventStreamEventExtendedDataPathKey];
        if ([p.lastPathComponent isEqualToString:leaf]) return YES;
    }
    return NO;
}
static void Stop(FSEventStreamRef stream) {
    FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream);
}
static void Put(NSString *path, NSString *body) {
    Check([[body dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:NSDataWritingWithoutOverwriting error:NULL], @"create synthetic file");
}
static void Move(NSString *from, NSString *to) {
    NSDictionary *before = Snapshot(from);
    Check(rename(from.fileSystemRepresentation, to.fileSystemRepresentation) == 0, @"rename synthetic file");
    JSON(@{@"stage": @"rename", @"from": from, @"to": to, @"before": before, @"after": Snapshot(to)});
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: FSEventsHistoryProbe run PARENT | replay FIXTURE\n"); return 2; }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *argument = [NSString stringWithUTF8String:argv[2]];
        if ([mode isEqualToString:@"replay"]) {
            char *canonical = realpath(argument.fileSystemRepresentation, NULL);
            Check(canonical != NULL, @"canonical replay fixture");
            argument = [NSString stringWithUTF8String:canonical]; free(canonical);
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[argument stringByAppendingPathComponent:@"manifest.plist"]];
            Check(manifest != nil, @"read fixture manifest");
            OpenLog(argument);
            NSString *root = manifest[@"root"]; struct stat s;
            Check([root isEqualToString:[argument stringByAppendingPathComponent:@"tree"]], @"fixture-scoped replay root");
            Check(stat(root.fileSystemRepresentation, &s) == 0, @"stat replay root");
            NSString *uuid = DatabaseUUID(s.st_dev);
            if ([uuid isEqual:@"unavailable"] || ![uuid isEqual:manifest[@"databaseUUID"]]) {
                JSON(@{@"inconclusive": @"historical database unavailable or changed"}); return 3;
            }
            Capture capture = {[NSMutableArray array], NO};
            FSEventStreamRef stream = Start(root, [manifest[@"cursor"] unsignedLongLongValue], &capture);
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
            while (!capture.historyDone && limit.timeIntervalSinceNow > 0) Pump(0.1);
            Pump(0.5); Stop(stream);
            JSON(@{@"stage": @"replay", @"historyDone": @(capture.historyDone), @"events": capture.events});
            return capture.historyDone ? 0 : 3; // Unavailable/inconclusive, not an API contract violation.
        }
        Check([mode isEqualToString:@"run"], @"mode");
        char *template = strdup([[argument stringByAppendingPathComponent:@"nv-fsevents-history-XXXXXX"] fileSystemRepresentation]);
        Check(mkdtemp(template) != NULL, @"make fixture");
        char *canonical = realpath(template, NULL); Check(canonical != NULL, @"canonical fixture path");
        NSString *fixture = [NSString stringWithUTF8String:canonical]; free(canonical); free(template);
        OpenLog(fixture);
        NSString *root = [fixture stringByAppendingPathComponent:@"tree"];
        NSString *outside = [fixture stringByAppendingPathComponent:@"outside"];
        Check([fm createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:NULL], @"make watched tree");
        Check([fm createDirectoryAtPath:outside withIntermediateDirectories:NO attributes:nil error:NULL], @"make outside tree");
        for (NSString *leaf in @[@"A", @"Return", @"Safe", @"Reuse", @"Unchanged"]) Put([root stringByAppendingPathComponent:leaf], @"initial");
        Capture baseline = {[NSMutableArray array], YES}; // SinceNow sends no HistoryDone sentinel.
        FSEventStreamRef stream = Start(root, kFSEventStreamEventIdSinceNow, &baseline);
        Put([root stringByAppendingPathComponent:@"baseline-marker"], @"marker");
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!SawLeaf(&baseline, @"baseline-marker") && limit.timeIntervalSinceNow > 0) Pump(0.1);
        if (!SawLeaf(&baseline, @"baseline-marker")) { Stop(stream); JSON(@{@"inconclusive": @"no baseline event", @"fixture": fixture}); return 3; }
        FSEventStreamEventId cursor = FSEventStreamGetLatestEventId(stream);
        struct stat s; Check(stat(root.fileSystemRepresentation, &s) == 0, @"stat baseline");
        NSString *uuid = DatabaseUUID(s.st_dev);
        if ([uuid isEqual:@"unavailable"]) { Stop(stream); JSON(@{@"inconclusive": @"historical database unavailable"}); return 3; }
        NSDictionary *manifest = @{@"root": root, @"cursor": @(cursor), @"databaseUUID": uuid};
        Check([manifest writeToFile:[fixture stringByAppendingPathComponent:@"manifest.plist"] atomically:YES], @"save local cursor");
        baseline.events = [NSMutableArray array]; // Keep the live stream, then replay in a new process.
        Move([root stringByAppendingPathComponent:@"A"], [root stringByAppendingPathComponent:@"B"]);
        Move([root stringByAppendingPathComponent:@"Return"], [outside stringByAppendingPathComponent:@"Return"]);
        Move([outside stringByAppendingPathComponent:@"Return"], [root stringByAppendingPathComponent:@"Return"]);
        Put([root stringByAppendingPathComponent:@"stage"], @"replacement");
        JSON(@{@"stage": @"before-replace", @"old": Snapshot([root stringByAppendingPathComponent:@"Safe"])});
        Move([root stringByAppendingPathComponent:@"stage"], [root stringByAppendingPathComponent:@"Safe"]);
        Check([fm copyItemAtPath:[root stringByAppendingPathComponent:@"B"] toPath:[root stringByAppendingPathComponent:@"Copy"] error:NULL], @"copy synthetic file");
        Move([root stringByAppendingPathComponent:@"Copy"], [root stringByAppendingPathComponent:@"CopyMoved"]);
        Check(link([[root stringByAppendingPathComponent:@"B"] fileSystemRepresentation], [[root stringByAppendingPathComponent:@"Hard"] fileSystemRepresentation]) == 0, @"hard link");
        Move([root stringByAppendingPathComponent:@"Hard"], [root stringByAppendingPathComponent:@"HardMoved"]);
        JSON(@{@"stage": @"before-delete", @"old": Snapshot([root stringByAppendingPathComponent:@"Reuse"])});
        Check(unlink([[root stringByAppendingPathComponent:@"Reuse"] fileSystemRepresentation]) == 0, @"delete synthetic file");
        Put([root stringByAppendingPathComponent:@"Reuse"], @"new incarnation");
        Put([root stringByAppendingPathComponent:@"end-marker"], @"marker");
        limit = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!SawLeaf(&baseline, @"end-marker") && limit.timeIntervalSinceNow > 0) Pump(0.1);
        Pump(0.5); Stop(stream);
        NSMutableDictionary *current = [NSMutableDictionary dictionary];
        for (NSString *leaf in [fm contentsOfDirectoryAtPath:root error:NULL]) current[leaf] = Snapshot([root stringByAppendingPathComponent:leaf]);
        JSON(@{@"stage": @"live", @"events": baseline.events, @"current": current, @"fixture": fixture,
            @"os": [NSProcessInfo processInfo].operatingSystemVersionString});
        NSTask *child = [[[NSTask alloc] init] autorelease];
        child.launchPath = [[[NSString stringWithUTF8String:argv[0]] stringByStandardizingPath] stringByResolvingSymlinksInPath];
        child.arguments = @[@"replay", fixture];
        Check([child launchAndReturnError:NULL], @"launch fresh replay process"); [child waitUntilExit];
        [resultLog seekToEndOfFile]; // Child appended to the same retained observation log.
        JSON(@{@"stage": @"complete", @"fixtureRetained": fixture, @"replayExit": @(child.terminationStatus)});
        return child.terminationStatus;
    }
}
