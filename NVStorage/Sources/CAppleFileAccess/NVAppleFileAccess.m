#import "NVAppleFileAccess.h"
#include "../CStorageIO/NVRepositoryRootInternal.h"
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

CFURLRef NVAppleCreateRootReference(NVRootOwner *owner, const char *selectedPath) {
    if (nv_root_validate(owner)) return NULL;
    NSString *alias = [NSString stringWithFormat:@"/dev/fd/%d", owner->directory];
    NSURL *reference = [NSURL fileURLWithPath:alias isDirectory:YES].fileReferenceURL;
    NSString *resolved = reference.path;
    bool same = resolved && nv_root_compare(owner, resolved.fileSystemRepresentation) == 1;
    if (reference && !resolved) {
        /* Descriptor duplication retains the tested alias binding for a pathless long reference. */
        struct stat observed;
        int duplicate = open(alias.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        same = duplicate >= 0 && !fcntl(duplicate, F_SETFD, FD_CLOEXEC) && !fstat(duplicate, &observed)
            && observed.st_dev == owner->device && observed.st_ino == owner->inode;
        if (duplicate >= 0) close(duplicate);
    }
    if (!same && nv_root_compare(owner, selectedPath) == 1) {
        /* Supplies a physically checked pathname candidate for filesystems such as HFS+. */
        NSURL *candidate = [NSURL fileURLWithFileSystemRepresentation:selectedPath isDirectory:YES relativeToURL:nil];
        reference = candidate.fileReferenceURL;
        resolved = reference.path;
        same = resolved && nv_root_compare(owner, resolved.fileSystemRepresentation) == 1;
    }
    if (!reference || !same || nv_root_validate(owner)) {
        errno = ESTALE; return NULL;
    }
    return CFBridgingRetain(reference);
}

CFURLRef NVAppleAppendReference(CFURLRef root, CFStringRef relative) {
    NSURL *value = (__bridge NSURL *)root;
    for (NSString *component in [(__bridge NSString *)relative componentsSeparatedByString:@"/"]) {
        if (component.length) value = [value URLByAppendingPathComponent:component];
    }
    return CFBridgingRetain(value);
}

bool NVAppleReferenceHasRoot(CFURLRef actual, CFURLRef root, CFStringRef relative) {
    if (!CFURLIsFileReferenceURL(actual) && ![(__bridge NSURL *)actual isFileURL]) return false;
    CFURLRef requested = NVAppleAppendReference(root, relative);
    bool exact = CFEqual(actual, requested);
    CFRelease(requested);
    if (exact) return true;
    CFURLRef candidate = CFRetain(actual);
    NSArray<NSString *> *components = [(__bridge NSString *)relative componentsSeparatedByString:@"/"];
    for (NSString *component in components.reverseObjectEnumerator) {
        if (!component.length) continue;
        CFStringRef leaf = CFURLCopyLastPathComponent(candidate);
        bool equal = leaf && CFEqual(leaf, (__bridge CFStringRef)component);
        if (leaf) CFRelease(leaf);
        if (!equal) { CFRelease(candidate); return false; }
        CFURLRef parent = CFURLCreateCopyDeletingLastPathComponent(kCFAllocatorDefault, candidate);
        CFRelease(candidate); candidate = parent;
        if (!candidate) return false;
    }
    CFURLRef reference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, candidate, NULL);
    CFRelease(candidate);
    bool equal = reference && CFEqual(reference, root);
    if (reference) CFRelease(reference);
    return equal;
}

void NVAppleCoordinateRead(NSFileCoordinator *coordinator, CFURLRef url, NSFileCoordinatorReadingOptions options,
    NSError **error, void (NS_NOESCAPE ^accessor)(CFURLRef)) {
    [coordinator coordinateReadingItemAtURL:(__bridge NSURL *)url options:options error:error
        byAccessor:^(NSURL *actual) { accessor((__bridge CFURLRef)actual); }];
}
void NVAppleCoordinateWrite(NSFileCoordinator *coordinator, CFURLRef url, NSFileCoordinatorWritingOptions options,
    NSError **error, void (NS_NOESCAPE ^accessor)(CFURLRef)) {
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)url options:options error:error
        byAccessor:^(NSURL *actual) { accessor((__bridge CFURLRef)actual); }];
}
void NVAppleCoordinateInstall(NSFileCoordinator *coordinator, CFURLRef source, CFURLRef destination,
    NSError **error, void (NS_NOESCAPE ^accessor)(CFURLRef, CFURLRef)) {
    [coordinator coordinateWritingItemAtURL:(__bridge NSURL *)source options:NSFileCoordinatorWritingForDeleting
        writingItemAtURL:(__bridge NSURL *)destination options:0 error:error
        byAccessor:^(NSURL *actualSource, NSURL *actualDestination) {
            accessor((__bridge CFURLRef)actualSource, (__bridge CFURLRef)actualDestination);
        }];
}
void NVAppleCoordinateCopy(NSFileCoordinator *coordinator, CFURLRef source, CFURLRef destination,
    NSError **error, void (NS_NOESCAPE ^accessor)(CFURLRef, CFURLRef)) {
    [coordinator coordinateReadingItemAtURL:(__bridge NSURL *)source options:NSFileCoordinatorReadingWithoutChanges
        writingItemAtURL:(__bridge NSURL *)destination options:0 error:error
        byAccessor:^(NSURL *actualSource, NSURL *actualDestination) {
            accessor((__bridge CFURLRef)actualSource, (__bridge CFURLRef)actualDestination);
        }];
}

static int errorDomain(NSError *error) {
    if (!error) return 0;
    if ([error.domain isEqual:NSPOSIXErrorDomain]) return 1;
    if ([error.domain isEqual:NSCocoaErrorDomain]) return 2;
    if ([error.domain isEqual:@"NSFileProviderErrorDomain"]) return 3;
    return 4;
}
static int optionalBoolean(NSNumber *value) { return value ? value.boolValue : -1; }
void NVAppleReadAvailability(CFURLRef url, NVAppleAvailability *status) {
    *status = (NVAppleAvailability){.ubiquitous = -1, .downloading = -1, .uploaded = -1, .unresolved = -1};
    NSURL *value = (__bridge NSURL *)url;
    [value removeAllCachedResourceValues];
    NSError *error = nil;
    NSDictionary<NSURLResourceKey, id> *values = [value resourceValuesForKeys:@[NSURLIsUbiquitousItemKey,
        NSURLUbiquitousItemDownloadingStatusKey, NSURLUbiquitousItemIsDownloadingKey,
        NSURLUbiquitousItemIsUploadedKey, NSURLUbiquitousItemHasUnresolvedConflictsKey,
        NSURLUbiquitousItemDownloadingErrorKey, NSURLUbiquitousItemUploadingErrorKey] error:&error];
    status->status_domain = errorDomain(error); status->status_code = error.code;
    status->ubiquitous = optionalBoolean(values[NSURLIsUbiquitousItemKey]);
    if (status->ubiquitous != 1) return;
    status->downloading = optionalBoolean(values[NSURLUbiquitousItemIsDownloadingKey]);
    status->uploaded = optionalBoolean(values[NSURLUbiquitousItemIsUploadedKey]);
    status->unresolved = optionalBoolean(values[NSURLUbiquitousItemHasUnresolvedConflictsKey]);
    NSString *download = values[NSURLUbiquitousItemDownloadingStatusKey];
    if ([download isEqual:NSURLUbiquitousItemDownloadingStatusNotDownloaded]) status->download = 1;
    if ([download isEqual:NSURLUbiquitousItemDownloadingStatusDownloaded]) status->download = 2;
    if ([download isEqual:NSURLUbiquitousItemDownloadingStatusCurrent]) status->download = 3;
    NSError *downloading = values[NSURLUbiquitousItemDownloadingErrorKey], *uploading = values[NSURLUbiquitousItemUploadingErrorKey];
    status->download_domain = errorDomain(downloading); status->download_code = downloading.code;
    status->upload_domain = errorDomain(uploading); status->upload_code = uploading.code;
}
bool NVAppleRequestMaterialization(CFURLRef url, NSError **error) {
    return [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:(__bridge NSURL *)url error:error];
}

@interface NVReferencePresenter : NSObject<NSFilePresenter> {
    NSLock *_lock;
    NSURL *_location;
    BOOL _registered;
}
@property(nonatomic, readonly) NSOperationQueue *presentedItemOperationQueue;
@property(nonatomic, copy, readonly) void (^event)(NVApplePresenterEvent);
- (instancetype)initWithURL:(NSURL *)url event:(void (^)(NVApplePresenterEvent))event;
- (void)registerAtURL:(NSURL *)url;
- (BOOL)isRegistered;
- (void)unregister;
- (void)stop;
@end

@implementation NVReferencePresenter
- (instancetype)initWithURL:(NSURL *)url event:(void (^)(NVApplePresenterEvent))event {
    if ((self = [super init])) {
        _lock = [[NSLock alloc] init]; _location = [url copy]; _event = [event copy];
        _presentedItemOperationQueue = [[NSOperationQueue alloc] init];
        _presentedItemOperationQueue.name = @"org.notationalvelocity.storage.presenter";
        _presentedItemOperationQueue.maxConcurrentOperationCount = 1;
        _presentedItemOperationQueue.qualityOfService = NSQualityOfServiceUtility;
    }
    return self;
}
- (NSURL *)presentedItemURL { [_lock lock]; NSURL *value = _location; [_lock unlock]; return value; }
- (BOOL)isRegistered { [_lock lock]; BOOL value = _registered; [_lock unlock]; return value; }
- (void)registerAtURL:(NSURL *)url {
    [_lock lock]; BOOL add = !_registered; _location = [url copy]; _registered = YES; [_lock unlock];
    if (add) {
        [NSFileCoordinator addFilePresenter:self];
        if (!self.isRegistered) [NSFileCoordinator removeFilePresenter:self];
    }
}
- (void)unregister {
    [_lock lock]; BOOL remove = _registered; _registered = NO; _location = nil; [_lock unlock];
    if (remove) [NSFileCoordinator removeFilePresenter:self];
}
- (void)stop { [self unregister]; [_presentedItemOperationQueue waitUntilAllOperationsAreFinished]; }
- (void)notify:(NVApplePresenterEvent)event { if (self.isRegistered) _event(event); }
- (void)relinquishPresentedItemToReader:(void (^)(void (^ _Nullable)(void)))reader { reader(nil); }
- (void)relinquishPresentedItemToWriter:(void (^)(void (^ _Nullable)(void)))writer {
    __weak NVReferencePresenter *weakSelf = self;
    writer(^{ [weakSelf notify:NVApplePresenterChanged]; });
}
- (void)savePresentedItemChangesWithCompletionHandler:(void (^)(NSError * _Nullable))completion { completion(nil); }
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError * _Nullable))completion {
    [self notify:NVApplePresenterDeleting]; completion(nil);
}
- (void)accommodatePresentedItemEvictionWithCompletionHandler:(void (^)(NSError * _Nullable))completion {
    [self notify:NVApplePresenterEvicting]; [self unregister]; completion(nil);
}
- (void)presentedItemDidMoveToURL:(NSURL *)url {
    [_lock lock]; if (_registered) _location = [url copy]; BOOL active = _registered; [_lock unlock];
    if (active) _event(NVApplePresenterMoved);
}
- (void)presentedItemDidChange { [self notify:NVApplePresenterChanged]; }
- (void)presentedItemDidChangeUbiquityAttributes:(NSSet<NSURLResourceKey> *)attributes {
    (void)attributes; [self notify:NVApplePresenterChanged];
}
- (void)presentedItemDidGainVersion:(NSFileVersion *)version { (void)version; [self notify:NVApplePresenterChanged]; }
- (void)presentedItemDidLoseVersion:(NSFileVersion *)version { (void)version; [self notify:NVApplePresenterChanged]; }
- (void)presentedItemDidResolveConflictVersion:(NSFileVersion *)version { (void)version; [self notify:NVApplePresenterChanged]; }
- (void)accommodatePresentedSubitemDeletionAtURL:(NSURL *)url completionHandler:(void (^)(NSError * _Nullable))completion {
    (void)url; [self notify:NVApplePresenterChanged]; completion(nil);
}
- (void)presentedSubitemDidAppearAtURL:(NSURL *)url { (void)url; [self notify:NVApplePresenterChanged]; }
- (void)presentedSubitemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL { (void)oldURL; (void)newURL; [self notify:NVApplePresenterChanged]; }
- (void)presentedSubitemDidChangeAtURL:(NSURL *)url { (void)url; [self notify:NVApplePresenterChanged]; }
- (void)presentedSubitemAtURL:(NSURL *)url didGainVersion:(NSFileVersion *)version { (void)url; (void)version; [self notify:NVApplePresenterChanged]; }
- (void)presentedSubitemAtURL:(NSURL *)url didLoseVersion:(NSFileVersion *)version { (void)url; (void)version; [self notify:NVApplePresenterChanged]; }
- (void)presentedSubitemAtURL:(NSURL *)url didResolveConflictVersion:(NSFileVersion *)version { (void)url; (void)version; [self notify:NVApplePresenterChanged]; }
@end

NVApplePresenter *NVApplePresenterCreate(CFURLRef url, void (^event)(NVApplePresenterEvent)) {
    return (NVApplePresenter *)CFBridgingRetain([[NVReferencePresenter alloc] initWithURL:(__bridge NSURL *)url event:event]);
}
NSFileCoordinator *NVApplePresenterCoordinator(NVApplePresenter *presenter) {
    return [[NSFileCoordinator alloc] initWithFilePresenter:(__bridge NVReferencePresenter *)presenter];
}
void NVApplePresenterRegister(NVApplePresenter *presenter, CFURLRef url) {
    [(__bridge NVReferencePresenter *)presenter registerAtURL:(__bridge NSURL *)url];
}
bool NVApplePresenterIsRegistered(NVApplePresenter *presenter) { return [(__bridge NVReferencePresenter *)presenter isRegistered]; }
void NVApplePresenterClose(NVApplePresenter *presenter) {
    NVReferencePresenter *owned = CFBridgingRelease(presenter); [owned stop];
}
