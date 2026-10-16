/* Observes cooperating editor state through the real projection adapters. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
static BOOL failCleanup;
static int ProtectedUnlink(int directory, const char *leaf, int flags) {
    if (failCleanup) { errno=EIO; return -1; }
    return unlinkat(directory,leaf,flags);
}
#define NV_PROJECTION_CLEANUP_UNLINK ProtectedUnlink
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"
#include "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#ifndef NV_APPLE_PROJECTION_SOURCE
#define NV_APPLE_PROJECTION_SOURCE "../NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m"
#endif
#import NV_APPLE_PROJECTION_SOURCE

#define Require(v) do { if (!(v)) { fprintf(stderr,"presenter line %d: %s (errno %d)\n",__LINE__,#v,errno); abort(); } } while (0)

static NSMutableArray *accessors;
static NSUInteger moveNotices;
static BOOL pathURLs;
static BOOL foreignSource, foreignDestination;
static NSURL *foreignRoot;
@interface ProjectionProbeCoordinator : NSFileCoordinator
@end
@implementation ProjectionProbeCoordinator
- (void)coordinateWritingItemAtURL:(NSURL *)first options:(NSFileCoordinatorWritingOptions)firstOptions
    writingItemAtURL:(NSURL *)second options:(NSFileCoordinatorWritingOptions)secondOptions
    error:(NSError **)error byAccessor:(void (NS_NOESCAPE ^)(NSURL *,NSURL *))writer {
    [super coordinateWritingItemAtURL:first options:firstOptions writingItemAtURL:second options:secondOptions error:error
        byAccessor:^(NSURL *from,NSURL *to) {
            if (pathURLs) {
                from=[NSURL fileURLWithPath:from.path];
                to=[NSURL fileURLWithPath:to.path];
            }
            if (foreignSource) from=[foreignRoot URLByAppendingPathComponent:from.lastPathComponent];
            if (foreignDestination) {
                NSString *relative=[to.lastPathComponent isEqualToString:@"item"] ? @"recovery.cleanup/item" : to.lastPathComponent;
                to=[foreignRoot URLByAppendingPathComponent:relative];
            }
            [accessors addObject:@{@"sourceRequested":first.absoluteString,@"destinationRequested":second.absoluteString,
                @"sourceActual":from.absoluteString,@"destinationActual":to.absoluteString,
                @"sourceEqual":@([from isEqual:first]),@"destinationEqual":@([to isEqual:second])}];
            writer(from,to);
        }];
}
- (void)itemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL {
    moveNotices++; [super itemAtURL:oldURL didMoveToURL:newURL];
}
@end

/* Implements the documented URL tracking and close/save decisions on its own queue. */
@interface ProjectionEditor : NSObject <NSFilePresenter> {
    NSURL *_url;
    NSOperationQueue *_queue;
    NSMutableArray<NSString *> *_events;
    BOOL _closed, _refuse, _keep;
    NSString *_dirty;
    NSCondition *_moveCondition;
    NSUInteger _moves;
}
- (instancetype)initWithURL:(NSURL *)url policy:(NSString *)policy;
- (NSDictionary *)report;
- (void)saveLater;
- (void)finish;
- (BOOL)awaitMoves:(NSUInteger)count;
@end

@implementation ProjectionEditor
- (instancetype)initWithURL:(NSURL *)url policy:(NSString *)policy {
    if ((self=[super init])) {
        _url=url; _queue=[NSOperationQueue new]; _queue.maxConcurrentOperationCount=1;
        _events=[NSMutableArray new]; _refuse=[policy isEqualToString:@"refuse"];
        _moveCondition=[NSCondition new];
        _keep=[policy isEqualToString:@"keep"];
        _dirty=[policy isEqualToString:@"dirty"]?@"dirty":nil;
    }
    return self;
}
- (NSURL *)presentedItemURL { @synchronized(self) { return _url; } }
- (NSOperationQueue *)presentedItemOperationQueue { return _queue; }
- (void)event:(NSString *)name { @synchronized(self) { [_events addObject:name]; } }
- (void)presentedItemDidMoveToURL:(NSURL *)url {
    @synchronized(self) { _url=url; [_events addObject:@"move"]; }
    [_moveCondition lock]; _moves++; [_moveCondition broadcast]; [_moveCondition unlock];
}
- (BOOL)awaitMoves:(NSUInteger)count {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    [_moveCondition lock];
    while (_moves<count && [_moveCondition waitUntilDate:deadline]) {}
    BOOL reached=_moves>=count; [_moveCondition unlock]; return reached;
}
- (void)presentedItemDidChange { [self event:@"change"]; }
- (void)relinquishPresentedItemToWriter:(void (^)(void (^ _Nullable)(void)))writer {
    [self event:@"borrow-write"];
    writer(^{ [self event:@"reacquire-write"]; });
}
- (void)relinquishPresentedItemToReader:(void (^)(void (^ _Nullable)(void)))reader {
    [self event:@"borrow-read"];
    reader(^{ [self event:@"reacquire-read"]; });
}
- (NSError *)saveBody:(NSString *)body {
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:self];
    __block NSError *failure=nil; NSError *error=nil;
    [coordinator coordinateWritingItemAtURL:self.presentedItemURL options:0 error:&error byAccessor:^(NSURL *actual) {
        if (![[body dataUsingEncoding:NSUTF8StringEncoding] writeToURL:actual options:NSDataWritingAtomic error:&failure]) return;
        [self event:@"saved"];
        @synchronized(self) { self->_dirty=nil; }
    }];
    return error?:failure;
}
- (void)savePresentedItemChangesWithCompletionHandler:(void (^)(NSError *))completion {
    [self event:@"requested-save"];
    NSString *body; @synchronized(self) { body=_dirty; }
    completion(body?[self saveBody:body]:nil);
}
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completion {
    [self event:@"requested-delete"];
    if (_refuse) { completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]); return; }
    NSString *body; @synchronized(self) { body=_dirty; }
    NSError *error=body?[self saveBody:body]:nil;
    if (!error && !_keep) {
        @synchronized(self) { _closed=YES; }
        [NSFileCoordinator removeFilePresenter:self];
        [self event:@"closed"];
    }
    completion(error);
}
- (void)saveLater {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [_queue addOperationWithBlock:^{
        BOOL closed; @synchronized(self) { closed=self->_closed; }
        if (!closed) Require([self saveBody:@"later"]==nil);
        dispatch_semaphore_signal(done);
    }];
    Require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
}
- (NSDictionary *)report {
    [_queue waitUntilAllOperationsAreFinished];
    @synchronized(self) { return @{@"url":_url.path?:@"",@"closed":@(_closed),@"events":[_events copy],@"dirty":_dirty?:[NSNull null]}; }
}
- (void)finish { [NSFileCoordinator removeFilePresenter:self]; [_queue waitUntilAllOperationsAreFinished]; }
@end

static void Register(ProjectionEditor *editor) {
    NSError *error=nil; __block BOOL entered=NO;
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:editor.presentedItemURL options:NSFileCoordinatorReadingWithoutChanges
        error:&error byAccessor:^(NSURL *actual) {
            Require([actual isEqual:editor.presentedItemURL]);
            [NSFileCoordinator addFilePresenter:editor]; entered=YES;
        }];
    Require(entered && !error);
}

static NSDictionary *Files(NSURL *root) {
    NSMutableDictionary *files=[NSMutableDictionary new];
    NSDirectoryEnumerator *all=[[NSFileManager defaultManager] enumeratorAtPath:root.path];
    for (NSString *relative in all) {
        NSURL *url=[root URLByAppendingPathComponent:relative];
        NSNumber *regular=nil; Require([url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL]);
        if (!regular.boolValue) continue;
        NSData *data=[NSData dataWithContentsOfURL:url]; Require(data);
        files[relative]=[data base64EncodedStringWithOptions:0];
    }
    return files;
}

static BOOL NamesCurrentFile(NSURL *url,int root,const char *leaf) {
    const char *path=url.fileSystemRepresentation;
    struct stat presented,named;
    return path && !lstat(path,&presented) && !fstatat(root,leaf,&named,AT_SYMLINK_NOFOLLOW) &&
        S_ISREG(presented.st_mode) && named.st_nlink==1 && presented.st_dev==named.st_dev && presented.st_ino==named.st_ino;
}

int main(int argc,char **argv) {
    @autoreleasepool {
        Require(argc==4);
        accessors=[NSMutableArray new]; moveNotices=0;
        NSURL *root=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES] URLByResolvingSymlinksInPath];
        NSString *mode=[NSString stringWithUTF8String:argv[2]], *policy=[NSString stringWithUTF8String:argv[3]];
        pathURLs=[mode hasSuffix:@"-path"];
        failCleanup=[mode hasSuffix:@"-unlink-error"];
        foreignSource=[mode hasSuffix:@"-foreign-source"];
        foreignDestination=[mode hasSuffix:@"-foreign-destination"];
        foreignRoot=[root URLByAppendingPathExtension:@"foreign"];
        Require([[NSFileManager defaultManager] createDirectoryAtURL:foreignRoot withIntermediateDirectories:NO attributes:nil error:NULL]);
        NVRootOwner *owner=nv_root_create(root.fileSystemRepresentation); Require(owner);
        NSURL *note=[root URLByAppendingPathComponent:@"Note.txt"];
        Require([[@"old" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:note options:NSDataWritingWithoutOverwriting error:NULL]);
        Require(chmod(note.fileSystemRepresentation,0600)==0);
        if ([mode isEqualToString:@"move-public-occupied"] || [mode isEqualToString:@"relocate-occupied"]) {
            Require([[@"foreign" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[root URLByAppendingPathComponent:@"Moved.txt"]
                options:NSDataWritingWithoutOverwriting error:NULL]);
        }
        uint64_t words[9]; NVProjectionRead *original=NULL; int descriptor=-1;
        Require(nv_root_snapshot(owner,"Note.txt",words)==0);
        Require(nv_projection_read_retaining(owner,"Note.txt",words,1024,&original,&descriptor)==0);
        const char *publicTarget=[mode isEqualToString:@"relocate-case"] || [mode isEqualToString:@"control-case"]?"note.txt":
            [mode isEqualToString:@"relocate-format"]?"Note.html":"Moved.txt";
        struct stat alias;
        BOOL caseAliases=(!strcmp(publicTarget,"note.txt") && !fstatat(owner->directory,publicTarget,&alias,AT_SYMLINK_NOFOLLOW) &&
            (uint64_t)alias.st_dev==words[1] && (uint64_t)alias.st_ino==words[2] && alias.st_nlink==1);
        ProjectionEditor *editor=[[ProjectionEditor alloc] initWithURL:note policy:policy]; Register(editor);
        ProjectionEditor *destinationEditor=nil;
        if ([mode isEqualToString:@"relocate-occupied"]) {
            destinationEditor=[[ProjectionEditor alloc] initWithURL:[root URLByAppendingPathComponent:@"Moved.txt"] policy:@"normal"];
            Register(destinationEditor);
        }
        NSURL *reference=root.fileReferenceURL; Require(reference);
        int outcome=-1,error=0,directoryCreated=-1; BOOL delivered=YES;
        if ([mode hasPrefix:@"update"] || [mode hasPrefix:@"relocate"]) {
            NSURL *directory=[[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                appropriateForURL:reference create:YES error:NULL]; Require(directory);
            int stageFD=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); Require(stageFD>=0);
            static const uint8_t encoding[]="UTF-8;134217984";
            NVProjectionMetadata metadata={.encoding={encoding,sizeof(encoding)-1,1},.tags={NULL,0,1},.permissions=0600,
                .modified_seconds=1700000000};
            NVProjectionEffect prepared;
            NVProjectionStage *stage=nv_projection_prepare_replacement(owner,stageFD,"prepared","Note.txt",words,
                (const uint8_t *)"old",3,(const uint8_t *)"new",3,&metadata,&prepared);
            Require(stage && prepared.outcome==NV_PROJECTION_STAGED);
            if ([mode hasPrefix:@"relocate"]) {
                NVProjectionRelocationResult result;
                NVAppleRelocateProjection([[ProjectionProbeCoordinator alloc] initWithFilePresenter:nil],(__bridge CFURLRef)reference,
                    (__bridge CFURLRef)[directory URLByAppendingPathComponent:@"prepared"],owner,stage,"Note.txt",publicTarget,"backup",original,
                    1024,descriptor,(const uint8_t *)"new",3,&metadata,&result);
                outcome=result.replacement.installation.outcome; error=result.replacement.installation.error;
                if (outcome==NV_PROJECTION_INSTALLED && !caseAliases) delivered=[editor awaitMoves:1];
            } else {
                NVProjectionReplacementResult result;
                NVAppleReplaceProjection([[ProjectionProbeCoordinator alloc] initWithFilePresenter:nil],(__bridge CFURLRef)reference,
                    (__bridge CFURLRef)[directory URLByAppendingPathComponent:@"prepared"],owner,stage,"Note.txt","backup",words,
                    (const uint8_t *)"old",3,(const uint8_t *)"new",3,&metadata,&result);
                outcome=result.installation.outcome; error=result.installation.error;
            }
            nv_projection_stage_close(stage); Require(close(stageFD)==0);
        } else if ([mode hasPrefix:@"delete-direct"]) {
            NVProjectionCleanupResult result;
            NVAppleRemoveProjectionSource([[ProjectionProbeCoordinator alloc] initWithFilePresenter:nil],(__bridge CFURLRef)reference,
                owner,"Note.txt","recovery",original,1024,descriptor,&result);
            outcome=result.outcome; error=result.error; directoryCreated=result.directory_created;
        } else if ([mode hasPrefix:@"move-public"]) {
            NVProjectionSourceResult result;
            NVAppleQuarantineProjection([[ProjectionProbeCoordinator alloc] initWithFilePresenter:nil],(__bridge CFURLRef)reference,
                owner,"Note.txt","Moved.txt",original,1024,descriptor,&result);
            outcome=result.outcome; error=result.error;
            if (result.outcome==NV_PROJECTION_SOURCE_CAPTURED) delivered=[editor awaitMoves:1];
        } else if ([mode isEqualToString:@"control-move"] || [mode isEqualToString:@"control-case"]) {
            BOOL caseOnly=[mode isEqualToString:@"control-case"];
            NSFileCoordinator *coordinator=[[ProjectionProbeCoordinator alloc] initWithFilePresenter:nil];
            NSURL *to=[root URLByAppendingPathComponent:caseOnly?@"note.txt":@"Moved.txt"]; NSError *failure=nil; __block BOOL entered=NO;
            [coordinator coordinateWritingItemAtURL:note options:NSFileCoordinatorWritingForMoving writingItemAtURL:to
                options:caseOnly?0:NSFileCoordinatorWritingForReplacing error:&failure byAccessor:^(NSURL *actual,NSURL *destination) {
                    entered=YES;
                    [coordinator itemAtURL:actual willMoveToURL:destination];
                    if (caseOnly) {
                        /* The sole fixture writer supplies the ordinary same-item case-rename control. */
                        Require(renameat(owner->directory,"Note.txt",owner->directory,"note.txt")==0);
                    } else Require([[NSFileManager defaultManager] moveItemAtURL:actual toURL:destination error:NULL]);
                    [coordinator itemAtURL:actual didMoveToURL:destination];
                }];
            outcome=entered?1:0; error=failure?(int)failure.code:0;
            if (entered && !caseAliases) delivered=[editor awaitMoves:1];
        } else {
            NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
            NSError *failure=nil; __block BOOL entered=NO;
            NSFileCoordinatorWritingOptions options=[mode isEqualToString:@"control-delete"]?NSFileCoordinatorWritingForDeleting:
                [mode isEqualToString:@"control-merging"]?NSFileCoordinatorWritingForMerging:0;
            [coordinator coordinateWritingItemAtURL:note options:options error:&failure byAccessor:^(NSURL *actual) {
                entered=YES;
                if ([mode isEqualToString:@"control-delete"]) Require([[NSFileManager defaultManager] removeItemAtURL:actual error:NULL]);
                else Require([[@"new" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:actual options:NSDataWritingAtomic error:NULL]);
            }];
            outcome=entered?1:0; error=failure?(int)failure.code:0;
        }
        NSDictionary *before=[editor report], *filesBefore=Files(root);
        if (caseAliases && ([mode isEqualToString:@"relocate-case"] || [mode isEqualToString:@"control-case"]))
            delivered=[before[@"events"] containsObject:@"move"];
        BOOL namesBefore=NamesCurrentFile(editor.presentedItemURL,owner->directory,publicTarget);
        [editor saveLater];
        NSDictionary *report=@{@"mode":mode,@"policy":policy,@"outcome":@(outcome),@"error":@(error),
            @"movesDelivered":@(delivered),@"moveNotices":@(moveNotices),@"accessors":accessors,
            @"directoryCreated":@(directoryCreated),
            @"caseAliases":@(caseAliases),@"namesDestinationBefore":@(namesBefore),
            @"namesDestinationAfter":@(NamesCurrentFile(editor.presentedItemURL,owner->directory,publicTarget)),
            @"editorBeforeSave":before,@"filesBeforeSave":filesBefore,@"editorAfterSave":[editor report],@"filesAfterSave":Files(root),
            @"destinationEditor":destinationEditor?[destinationEditor report]:[NSNull null],
            @"foreignFiles":Files(foreignRoot)};
        [editor finish]; [destinationEditor finish]; nv_projection_read_close(original); Require(close(descriptor)==0); nv_root_close(owner);
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL]; Require(encoded);
        Require(fwrite(encoded.bytes,1,encoded.length,stdout)==encoded.length); puts("");
    }
    return 0;
}
