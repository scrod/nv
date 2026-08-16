// Integration-test-only seams for deterministic filesystem race injection.

#import "../NVRootedDirectory_Private.h"

NSString *NVTestTemporaryFilenameForWrite(id hooks, NSString *filename);
int NVTestRenameFileExclusivelyForWrite(id hooks, NSString *filename,
	int oldDirectoryFD, const char *oldName, int newDirectoryFD, const char *newName);
int NVTestUnlinkTemporaryForWrite(id hooks, NSString *filename,
	int directoryFD, const char *name);
ssize_t NVTestGetExtendedAttributeForSnapshot(id hooks, int fileDescriptor,
	const char *name, void *value, size_t size, BOOL readingValue);

#define NVTemporaryFilenameForWrite NVTestTemporaryFilenameForWrite
#define NVRenameFileExclusivelyForWrite NVTestRenameFileExclusivelyForWrite
#define NVUnlinkTemporaryForWrite NVTestUnlinkTemporaryForWrite
#define NVGetExtendedAttributeForSnapshot NVTestGetExtendedAttributeForSnapshot

@interface NSObject (NVRootedDirectoryTestHookTarget)
- (void)_didPrepareNoteFileNamed:(NSString*)filename;
- (void)_didRejectAtomicSwapForNoteNamed:(NSString*)filename;
- (void)_didExchangeNoteFileNamed:(NSString*)filename;
- (int)_metadataFinalizationErrorAfterExchangingNoteNamed:(NSString*)filename;
- (void)_didInstallNoteFileNamed:(NSString*)filename;
- (void)_didObserveRenameCollisionFromName:(NSString*)oldName toName:(NSString*)newName;
- (void)_didSetTextEncodingForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (BOOL)_snapshotTagURL:(NSURL*)URL referencesFileDescriptor:(int)fileDescriptor;
- (id)_snapshotCocoaTagsAtURL:(NSURL*)URL;
- (BOOL)_setCocoaTags:(NSArray*)tags atURL:(NSURL*)URL error:(NSError**)error;
- (void)_didSynchronizeTagsForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (int)_extendedAttributeReadErrorForName:(const char*)name readingValue:(BOOL)readingValue;
- (int)_exclusiveRenameErrorForFileNamed:(NSString*)filename;
- (int)_temporaryRemovalErrorForFileNamed:(NSString*)filename;
- (NSString*)_temporaryFilenameForFileNamed:(NSString*)filename;
- (int)_directorySynchronizationError;
- (int)_getattrlistbulk:(int)directoryFD attributes:(void*)attributes
	buffer:(void*)buffer size:(size_t)bufferSize options:(uint64_t)options;
- (void)_didUseFoundationCatalogEnumeration;

- (int)_snapshotStatErrorAfterPreparingName:(const char*)name;
- (void)_didReadNoteDataForTesting;
- (BOOL)_shouldFailSnapshotNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)_shouldFailObservationNamed:(NSString*)filename error:(NSError**)error;
- (NSNumber*)_injectedExistenceResultForName:(NSString*)filename;
- (BOOL)_consumeRenameFailureFromName:(NSString*)oldName toName:(NSString*)newName
	error:(NSError**)error;
- (NVFileWriteResult*)_injectedNoteStoreFailureForName:(NSString*)filename;
- (BOOL)_shouldFailTrashForTesting;
- (BOOL)_usesTestTrashForTesting;
- (void)_didUseTestTrash;
- (void)_didTrashURLForTesting:(NSURL*)URL;
@end

@interface NVRootedDirectory (NVRootedDirectoryTestHooks)
- (int)_statSnapshotName:(const char*)name status:(struct stat*)status;
- (BOOL)performWithInvalidDirectoryDescriptor:(BOOL (^)(void))operation;
@end

@interface NVTestRootedDirectory : NVRootedDirectory {
	id hookTarget; // non-retained; the controller owns this root
	id previousHookTarget; // non-retained during a recovery-controller handoff
}
- (void)setHookTarget:(id)target;
- (void)removeHookTarget:(id)target;
@end
