#import "NVRootedDirectoryTestHooks.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/xattr.h>
#import <objc/runtime.h>

static int *NVTestDirectoryDescriptorSlot(NVRootedDirectory *directory) {
	Ivar ivar = class_getInstanceVariable([NVRootedDirectory class], "directoryFileDescriptor");
	return ivar ? (int *)((uint8_t *)(void *)directory + ivar_getOffset(ivar)) : NULL;
}

NSString *NVTestTemporaryFilenameForWrite(id hooks, NSString *filename) {
	NSString *result = [hooks respondsToSelector:@selector(_temporaryFilenameForFileNamed:)] ?
		[hooks _temporaryFilenameForFileNamed:filename] : nil;
	return result ?: [@".nv-write-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
}

int NVTestRenameFileExclusivelyForWrite(id hooks, NSString *filename,
	int oldDirectoryFD, const char *oldName, int newDirectoryFD, const char *newName) {
	int injectedError = [hooks respondsToSelector:@selector(_exclusiveRenameErrorForFileNamed:)] ?
		[hooks _exclusiveRenameErrorForFileNamed:filename] : 0;
	if (!injectedError)
		return renameatx_np(oldDirectoryFD, oldName, newDirectoryFD, newName, RENAME_EXCL);
	errno = injectedError;
	return -1;
}

int NVTestUnlinkTemporaryForWrite(id hooks, NSString *filename,
	int directoryFD, const char *name) {
	int injectedError = [hooks respondsToSelector:@selector(_temporaryRemovalErrorForFileNamed:)] ?
		[hooks _temporaryRemovalErrorForFileNamed:filename] : 0;
	if (!injectedError) return unlinkat(directoryFD, name, 0);
	errno = injectedError;
	return -1;
}

ssize_t NVTestGetExtendedAttributeForSnapshot(id hooks, int fileDescriptor,
	const char *name, void *value, size_t size, BOOL readingValue) {
	int injectedError = [hooks respondsToSelector:
		@selector(_extendedAttributeReadErrorForName:readingValue:)] ?
		[hooks _extendedAttributeReadErrorForName:name readingValue:readingValue] : 0;
	if (!injectedError) return fgetxattr(fileDescriptor, name, value, size, 0, 0);
	errno = injectedError;
	return -1;
}

@implementation NVRootedDirectory (NVRootedDirectoryTestHooks)

- (int)_statSnapshotName:(const char*)name status:(struct stat*)status {
	int *directoryFD = NVTestDirectoryDescriptorSlot(self);
	if (directoryFD) return fstatat(*directoryFD, name, status, AT_SYMLINK_NOFOLLOW);
	errno = EBADF;
	return -1;
}

- (BOOL)performWithInvalidDirectoryDescriptor:(BOOL (^)(void))operation {
	int *directoryFD = NVTestDirectoryDescriptorSlot(self);
	if (!directoryFD) return NO;
	int savedDirectoryFD = *directoryFD;
	*directoryFD = -1;
	BOOL result = operation ? operation() : NO;
	*directoryFD = savedDirectoryFD;
	return result;
}

@end

@implementation NVTestRootedDirectory

- (void)setHookTarget:(id)target {
	if (target == hookTarget) return;
	previousHookTarget = hookTarget;
	hookTarget = target;
}

- (void)removeHookTarget:(id)target {
	if (target == hookTarget) {
		hookTarget = previousHookTarget;
		previousHookTarget = nil;
	} else if (target == previousHookTarget) previousHookTarget = nil;
}

- (BOOL)respondsToSelector:(SEL)selector {
	return [super respondsToSelector:selector] || [hookTarget respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
	return [hookTarget respondsToSelector:selector] ? hookTarget :
		[super forwardingTargetForSelector:selector];
}

- (int)_statSnapshotName:(const char*)name status:(struct stat*)status {
	int injectedError = [hookTarget respondsToSelector:
		@selector(_snapshotStatErrorAfterPreparingName:)] ?
		[hookTarget _snapshotStatErrorAfterPreparingName:name] : 0;
	if (injectedError) {
		errno = injectedError;
		return -1;
	}
	return [super _statSnapshotName:name status:status];
}

- (NSData*)dataFromFileNamed:(NSString*)filename error:(NSError**)error {
	[hookTarget _didReadNoteDataForTesting];
	return [super dataFromFileNamed:filename error:error];
}

- (NVFileSnapshot*)snapshotForFileNamed:(NSString*)filename error:(NSError**)error {
	[hookTarget _didReadNoteDataForTesting];
	if ([hookTarget _shouldFailSnapshotNamed:filename error:error]) return nil;
	return [super snapshotForFileNamed:filename error:error];
}

- (NVFileObservation*)observationForFileNamed:(NSString*)filename error:(NSError**)error {
	if ([hookTarget _shouldFailObservationNamed:filename error:error]) return nil;
	return [super observationForFileNamed:filename error:error];
}

- (BOOL)regularFileExistsNamed:(NSString*)filename {
	NSNumber *injected = [hookTarget _injectedExistenceResultForName:filename];
	return injected ? [injected boolValue] : [super regularFileExistsNamed:filename];
}

- (BOOL)renameFileNamed:(NSString*)oldName toUnusedName:(NSString*)newName error:(NSError**)error {
	if ([hookTarget _consumeRenameFailureFromName:oldName toName:newName error:error]) return NO;
	return [super renameFileNamed:oldName toUnusedName:newName error:error];
}

- (NVFileWriteResult*)createNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime {
	NVFileWriteResult *failure = [hookTarget _injectedNoteStoreFailureForName:filename];
	return failure ?: [super createNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime];
}

- (NVFileWriteResult*)replaceNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime
	expectedSnapshot:(NVFileSnapshot*)snapshot {
	NVFileWriteResult *failure = [hookTarget _injectedNoteStoreFailureForName:filename];
	return failure ?: [super replaceNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime expectedSnapshot:snapshot];
}

- (NVFileWriteResult*)overwriteNoteFileNamed:(NSString*)filename withData:(NSData*)data
	encoding:(NSStringEncoding)encoding tags:(NSArray*)tags
	creationTime:(CFAbsoluteTime)creationTime modificationTime:(CFAbsoluteTime)modificationTime {
	NVFileWriteResult *failure = [hookTarget _injectedNoteStoreFailureForName:filename];
	return failure ?: [super overwriteNoteFileNamed:filename withData:data encoding:encoding tags:tags
		creationTime:creationTime modificationTime:modificationTime];
}

- (BOOL)synchronize:(NSError**)error {
	int injectedError = [hookTarget respondsToSelector:@selector(_directorySynchronizationError)] ?
		[hookTarget _directorySynchronizationError] : 0;
	if (!injectedError) return [super synchronize:error];
	if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
		code:injectedError userInfo:nil];
	return NO;
}

- (BOOL)moveFileToTrashUsingWorkspaceNamed:(NSString*)filename
	resultingURL:(NSURL**)resultingURL error:(NSError**)error {
	if ([hookTarget _shouldFailTrashForTesting]) {
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
		return NO;
	}
	if ([hookTarget _usesTestTrashForTesting]) {
		BOOL removed = [self removeFileNamed:filename error:error];
		if (removed) [hookTarget _didUseTestTrash];
		if (resultingURL) *resultingURL = nil;
		return removed;
	}
	NSURL *URL = nil;
	BOOL moved = [super moveFileToTrashUsingWorkspaceNamed:filename resultingURL:&URL error:error];
	if (moved) [hookTarget _didTrashURLForTesting:URL];
	if (resultingURL) *resultingURL = URL;
	return moved;
}

@end
