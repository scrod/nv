#import <Cocoa/Cocoa.h>

#import "../FrozenNotation.h"
#import "../AppController.h"
#import "../GlobalPrefs.h"
#import "../NotationController.h"
#import "../NotationDirectoryManager.h"
#import "../NotationFileManager.h"
#import "../NotationPrefs.h"
#import "../NotationSyncServiceManager.h"
#import "../DeletionManager.h"
#import "../NoteObject.h"
#import "../WALController.h"
#import "../NSFileManager_NV.h"
#import "../NSData_transformations.h"

#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#import <objc/runtime.h>

extern char **environ;

void FSEventsCallback(ConstFSEventStreamRef stream, void *info, size_t numEvents,
	void *eventPaths, const FSEventStreamEventFlags flags[],
	const FSEventStreamEventId eventIDs[]);

#define REQUIRE(condition) do { \
	if (!(condition)) \
		[NSException raise:NSInternalInconsistencyException \
					format:@"%s:%d: requirement failed: %s", __FILE__, __LINE__, #condition]; \
} while (0)

static NSUInteger controllerDeallocationCount;
static NSUInteger injectedControllerFlushFailures;
static NSUInteger observedInjectedControllerFlushFailures;
static int injectedJournalFlockError;
static IMP originalJournalFlockImplementation;

static int NVInjectedJournalFlock(id object, SEL selector) {
	if (injectedJournalFlockError) {
		errno = injectedJournalFlockError;
		return -1;
	}
	return ((int (*)(id, SEL))originalJournalFlockImplementation)(object, selector);
}

static void InstallJournalFlockInjection(void) {
	if (originalJournalFlockImplementation) return;
	Method method = class_getInstanceMethod([WALController class],
		NSSelectorFromString(@"_flockJournalFile"));
	REQUIRE(method != NULL);
	originalJournalFlockImplementation = method_getImplementation(method);
	method_setImplementation(method, (IMP)NVInjectedJournalFlock);
}

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	uint32_t error;
	attrreference_t name;
	fsobj_type_t objectType;
	struct timespec changeTime;
	uint32_t generationCount;
	uint32_t documentID;
	uint64_t fileID;
	char filename[16];
} NVTestBulkRecord;

typedef NS_ENUM(NSUInteger, NVInjectedBulkFailure) {
	NVInjectedBulkUnsupportedAfterPartial = 1,
	NVInjectedBulkMalformedAfterPartial,
	NVInjectedBulkPersistentENOENT,
	NVInjectedBulkInvalidUTF8AfterPartial
};

static NVTestBulkRecord TestBulkRecord(uint32_t documentID);
static NSArray *CocoaTagNamesFromRawTags(NSArray *tags);

static BOOL SetTestOpenMetaTags(NotationController *controller, NSArray *tags,
	NSString *filename, NSError **error) {
	NSURL *URL = [controller fileReferenceURLForNoteNamed:filename error:error];
	NSData *data = URL ? [NSPropertyListSerialization dataWithPropertyList:tags
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error] : nil;
	const char *path = [URL fileSystemRepresentation];
	if (!data || !path || setxattr(path, "com.apple.metadata:kMDItemOMUserTags",
		[data bytes], [data length], 0, 0) < 0) {
		if (error && !*error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
			code:(path ? errno : ENAMETOOLONG) userInfo:nil];
		return NO;
	}
	return [URL setResourceValue:CocoaTagNamesFromRawTags(tags)
		forKey:NSURLTagNamesKey error:error];
}

static BOOL SetTestTextEncoding(NotationController *controller, NSStringEncoding encoding,
	NSString *filename, NSError **error) {
	NSURL *URL = [controller fileReferenceURLForNoteNamed:filename error:error];
	if (!URL) return NO;
	CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
	NSString *value = [(NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding)
		stringByAppendingFormat:@";%u", (unsigned int)cfEncoding];
	const char *path = [URL fileSystemRepresentation];
	const char *bytes = [value UTF8String];
	if (path && bytes && setxattr(path, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) == 0)
		return YES;
	if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
		code:(path ? errno : ENAMETOOLONG) userInfo:nil];
	return NO;
}

@interface NotationController (NVDirectoryFallbackTest)
- (void)_resetCatalogEntries;
- (BOOL)_readFilesUsingFoundation;
- (int)_getattrlistbulk:(int)directoryFD attributes:(void*)attributes
	buffer:(void*)buffer size:(size_t)bufferSize options:(uint64_t)options;
- (BOOL)_appendCatalogEntryFilename:(CFStringRef)filename
	attributeChangeTime:(struct timespec)changeTime documentID:(uint32_t)documentID
	fileID:(uint64_t)fileID generationCount:(uint32_t)generationCount;
@end

@interface NotationController (NVSnapshotTest)
- (BOOL)_readNoteFileSnapshotOnce:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error;
- (BOOL)_snapshotTagURL:(NSURL*)URL referencesFileDescriptor:(int)fileDescriptor;
- (id)_snapshotCocoaTagsAtURL:(NSURL*)URL;
- (int)_statSnapshotName:(const char*)name status:(struct stat*)status;
- (void)_didInstallNoteFileNamed:(NSString*)filename;
- (void)_didSynchronizeTagsForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (void)_didSetTextEncodingForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor;
- (BOOL)setTextEncoding:(NSStringEncoding)encoding forNoteNamed:(NSString*)filename
	matchingFileInfo:(const NVFileInfo*)expectedInfo expectedData:(NSData*)expectedData
	resultingFileInfo:(NVFileInfo*)resultingInfo error:(NSError**)error;
- (BOOL)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename
	preparationBlock:(BOOL (^)(int fileDescriptor, NSError **error))preparationBlock
	verificationBlock:(NVFileVerificationBlock)verificationBlock error:(NSError**)error;
@end

@interface NotationController (NVDirectoryPreparationTest)
- (NoteObject*)_preparedNoteForCatalogEntry:(NoteCatalogEntry*)entry
	fallbackNote:(NoteObject*)fallbackNote error:(NSError**)error;
- (BOOL)_configureDirEventStream;
@end

@interface NVDeallocationProbe : NSObject {
	BOOL *deallocated;
}
- (id)initWithFlag:(BOOL*)flag;
@end

@implementation NVDeallocationProbe
- (id)initWithFlag:(BOOL*)flag {
	self = [super init];
	if (self) deallocated = flag;
	return self;
}
- (void)dealloc {
	if (deallocated) *deallocated = YES;
	[super dealloc];
}
@end

@interface NVReferenceCountingFileManager : NSFileManager {
	NSUInteger referenceConversionCount;
}
- (NSUInteger)referenceConversionCount;
@end

@implementation NVReferenceCountingFileManager
- (NSURL*)fileReferenceURLForURL:(NSURL*)URL error:(NSError**)error {
	referenceConversionCount++;
	return [super fileReferenceURLForURL:URL error:error];
}
- (NSUInteger)referenceConversionCount { return referenceConversionCount; }
@end

@interface NVAppControllerWindow : NSObject {
	NSUndoManager *routedUndoManager;
}
- (id)initWithUndoManager:(NSUndoManager*)undoManager;
@end

@implementation NVAppControllerWindow
- (id)initWithUndoManager:(NSUndoManager*)undoManager {
	self = [super init];
	if (self) routedUndoManager = [undoManager retain];
	return self;
}
- (id)attachedSheet { return self; }
- (NSUndoManager*)undoManager { return routedUndoManager; }
- (void)dealloc {
	[routedUndoManager release];
	[super dealloc];
}
@end

@interface NVDeleteNotesTableView : NSObject {
	NSUInteger selectedRowIndexesCallCount;
}
- (NSUInteger)selectedRowIndexesCallCount;
@end

@implementation NVDeleteNotesTableView
- (NSIndexSet*)selectedRowIndexes {
	selectedRowIndexesCallCount++;
	return [NSIndexSet indexSet];
}
- (NSUInteger)selectedRowIndexesCallCount { return selectedRowIndexesCallCount; }
@end

@interface NVDeletionAppController : AppController
- (id)initWithWindow:(id)aWindow notesTableView:(id)aNotesTableView;
@end

@implementation NVDeletionAppController
- (id)initWithWindow:(id)aWindow notesTableView:(id)aNotesTableView {
	self = [super init];
	if (self) {
		window = aWindow;
		notesTableView = aNotesTableView;
	}
	return self;
}
- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[notationController release];
	notationController = nil;
	[super dealloc];
}
@end

static char NVPreparedNoteDeallocationProbeKey;

@interface NVTestNotationController : NotationController {
	OSStatus recordedWriteError;
	OSStatus atomicVerificationResult;
	BOOL interceptContentFallback;
	BOOL contentFallbackCalled;
	NSUInteger noteDataReadCount;
	NSArray *syntheticCatalogNames;
	NSString *missingMetadataName;
	NSUInteger missingMetadataFailuresRemaining;
	NSString *failingSnapshotName;
	NSUInteger transientSnapshotFailures;
	NSUInteger snapshotAttemptCount;
	NSUInteger pushScheduleCount;
	NSUInteger labelAddCount;
	NSUInteger resortCount;
	NSUInteger synchronizeCount;
	BOOL injectPartialBulkFailure;
	NVInjectedBulkFailure injectedBulkFailure;
	BOOL forceFoundationEnumeration;
	NSUInteger injectedBulkCallCount;
	int injectedFirstBulkCount;
	NSUInteger foundationEnumerationCount;
	NSString *mutationBeforeFenceName;
	NSData *mutationBeforeFenceData;
	NSUInteger mutationCatalogReadCount;
	NSString *preparedNoteProbeName;
	BOOL *preparedNoteProbeFlag;
	NSString *directoryMoveOldPath;
	NSString *directoryMoveNewPath;
	NSUInteger directoryMoveCatalogCall;
	NSUInteger directoryMoveCatalogReadCount;
	BOOL directoryMoveWasPerformed;
	NSUInteger directoryStreamReconfigurationCount;
	NSUInteger directoryStreamConfigurationFailuresRemaining;
	BOOL simulateDirectoryStreamConfiguration;
	NSUInteger catalogReadCount;
	NSString *snapshotBoundaryMutationName;
	NSData *snapshotBoundaryReplacementData;
	NSArray *snapshotBoundaryReplacementTags;
	NSArray *snapshotBoundaryObservedTags;
	NSUInteger snapshotBoundaryMutationsRemaining;
	NSString *installedBoundaryMutationName;
	NSData *installedBoundaryReplacementData;
	NSString *inPlaceBoundaryMutationName;
	NSData *inPlaceBoundaryReplacementData;
	BOOL mutateDuringTagSynchronization;
	BOOL mutateDuringEncodingSynchronization;
	NSString *removeBeforeRenameExistenceCheckName;
	NSUInteger renameExistenceCheckCount;
	NSString *removeRenameCollisionDestinationName;
	NSURL *lastTrashedURL;
	BOOL forceTrashFailure;
	BOOL useTestTrash;
	NSUInteger trashMoveCount;
}
- (OSStatus)recordedWriteError;
- (void)setAtomicVerificationResult:(OSStatus)result;
- (OSStatus)atomicVerificationResult;
- (NSUInteger)directoryStreamNoteCount;
- (uint32_t)catalogDocumentIdentifierForFilename:(NSString*)filename;
- (NSTimeInterval)bulkScanElapsed;
- (void)setInterceptContentFallback:(BOOL)intercept;
- (BOOL)contentFallbackCalled;
- (BOOL)hasCaseCollisionForNames:(NSArray*)names;
- (void)resetNoteDataReadCount;
- (NSUInteger)noteDataReadCount;
- (BOOL)synchronizeWithClosedDirectoryDescriptor;
- (BOOL)reconcileNoteUsingFoundation:(NoteObject*)note;
- (void)setSyntheticCatalogNames:(NSArray*)names;
- (BOOL)foundationScanRetriesThenRejectsVanishedFilename:(NSString*)filename;
- (void)setFailingSnapshotName:(NSString*)filename;
- (void)setTransientSnapshotFailures:(NSUInteger)failures;
- (NSUInteger)snapshotAttemptCount;
- (void)resetPushScheduleCount;
- (NSUInteger)pushScheduleCount;
- (void)resetLabelAddCount;
- (NSUInteger)labelAddCount;
- (void)resetResortCount;
- (NSUInteger)resortCount;
- (void)resetSynchronizeCount;
- (NSUInteger)synchronizeCount;
- (BOOL)partialBulkFallbackDiscardsCatalog;
- (BOOL)bulkFailure:(NVInjectedBulkFailure)failure discardsCatalogUsingFoundation:(BOOL)usesFoundation;
- (NSUInteger)foundationEnumerationsForDirectoryScan;
- (BOOL)synchronizeJournalOnly;
- (NSUInteger)pendingFileWriteCount;
- (NSUInteger)pendingJournalWriteCount;
- (BOOL)writeRetryIsScheduled;
- (BOOL)directoryRetryIsScheduled;
- (BOOL)changeWriteTimerIsScheduled;
- (NSUInteger)deletionCandidateCount;
- (void)setMutationBeforeFenceName:(NSString*)filename content:(NSString*)content;
- (void)breakJournalDescriptor;
- (void)setPreparedNoteProbeName:(NSString*)filename deallocationFlag:(BOOL*)flag;
- (void)setDirectoryMoveFromPath:(NSString*)oldPath toPath:(NSString*)newPath
	onCatalogRead:(NSUInteger)catalogRead;
- (BOOL)directoryMoveWasPerformed;
- (void)resetDirectoryStreamReconfigurationCount;
- (NSUInteger)directoryStreamReconfigurationCount;
- (void)simulateDirectoryStreamWithConfigurationFailures:(NSUInteger)failures;
- (void)resetCatalogReadCount;
- (NSUInteger)catalogReadCount;
- (BOOL)bufferJournalForNoteWithoutRetiringObligation:(NoteObject*)note;
- (NSUInteger)journalBufferedByteCount;
- (void)replaceSnapshotName:(NSString*)filename withData:(NSData*)data
	atFinalIdentityChecks:(NSUInteger)checks;
- (void)replaceSnapshotCocoaTags:(NSArray*)tags afterReadingTags:(NSArray*)observedTags
	forNoteNamed:(NSString*)filename atIdentityChecks:(NSUInteger)checks;
- (void)replaceInstalledNoteNamed:(NSString*)filename withData:(NSData*)data;
- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringTagSynchronization:(BOOL)tags;
- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringEncodingSynchronization:(BOOL)encoding;
- (void)removeNoteBeforeRenameExistenceCheck:(NSString*)filename;
- (NSUInteger)renameExistenceCheckCount;
- (void)removeRenameCollisionDestination:(NSString*)filename;
- (NSURL*)lastTrashedURL;
- (void)setForceTrashFailure:(BOOL)force;
- (void)setUseTestTrash:(BOOL)use;
- (NSUInteger)trashMoveCount;
- (void)restoreDeletionCandidates;
- (void)processDeletionCandidates;
- (int)testNoteDirectoryFileDescriptor;
@end

@implementation NVTestNotationController

- (int)testNoteDirectoryFileDescriptor {
	return noteDirectoryFileDescriptor;
}

- (BOOL)flushAllNoteChanges {
	if (injectedControllerFlushFailures) {
		injectedControllerFlushFailures--;
		observedInjectedControllerFlushFailures++;
		return NO;
	}
	return [super flushAllNoteChanges];
}

- (void)noteDidNotWrite:(NoteObject *)note error:(NSError*)error {
	(void)note;
	recordedWriteError = error ? (OSStatus)[error code] : noErr;
}

- (OSStatus)recordedWriteError {
	return recordedWriteError;
}

- (void)setAtomicVerificationResult:(OSStatus)result {
	atomicVerificationResult = result;
}

- (void)removeNoteBeforeRenameExistenceCheck:(NSString*)filename {
	[removeBeforeRenameExistenceCheckName release];
	removeBeforeRenameExistenceCheckName = [filename copy];
	if (filename) renameExistenceCheckCount = 0;
}

- (BOOL)noteExistsWithName:(NSString*)filename {
	renameExistenceCheckCount++;
	if ([filename isEqualToString:removeBeforeRenameExistenceCheckName]) {
		REQUIRE(unlinkat(noteDirectoryFileDescriptor, [filename fileSystemRepresentation], 0) == 0);
		[removeBeforeRenameExistenceCheckName release];
		removeBeforeRenameExistenceCheckName = nil;
		return YES;
	}
	return [super noteExistsWithName:filename];
}

- (NSUInteger)renameExistenceCheckCount {
	return renameExistenceCheckCount;
}

- (BOOL)moveNoteToTrashNamed:(NSString*)filename resultingURL:(NSURL**)resultingURL
	error:(NSError**)error {
	if (forceTrashFailure) {
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
		return NO;
	}
	if (useTestTrash) {
		if (unlinkat(noteDirectoryFileDescriptor, [filename fileSystemRepresentation], 0) < 0) {
			if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
			return NO;
		}
		trashMoveCount++;
		if (resultingURL) *resultingURL = nil;
		return YES;
	}
	NSURL *URL = nil;
	BOOL moved = [super moveNoteToTrashNamed:filename resultingURL:&URL error:error];
	if (moved) {
		[lastTrashedURL release];
		lastTrashedURL = [URL retain];
	}
	if (resultingURL) *resultingURL = URL;
	return moved;
}

- (NSURL*)lastTrashedURL { return lastTrashedURL; }
- (void)setForceTrashFailure:(BOOL)force { forceTrashFailure = force; }
- (void)setUseTestTrash:(BOOL)use { useTestTrash = use; }
- (NSUInteger)trashMoveCount { return trashMoveCount; }
- (void)restoreDeletionCandidates { [deletionManager restoreAction:nil]; }
- (void)processDeletionCandidates { [deletionManager processDeletedNotes]; }

- (void)removeRenameCollisionDestination:(NSString*)filename {
	[removeRenameCollisionDestinationName release];
	removeRenameCollisionDestinationName = [filename copy];
}

- (void)_didObserveRenameCollisionFromName:(NSString*)oldName toName:(NSString*)newName {
	(void)oldName;
	if (![newName isEqualToString:removeRenameCollisionDestinationName]) return;
	REQUIRE(unlinkat(noteDirectoryFileDescriptor, [newName fileSystemRepresentation], 0) == 0);
	[removeRenameCollisionDestinationName release];
	removeRenameCollisionDestinationName = nil;
}

- (OSStatus)atomicVerificationResult {
	return atomicVerificationResult;
}

- (NSUInteger)directoryStreamNoteCount {
	[self _resetCatalogEntries];
	if (![self _readFilesUsingFoundation]) return NSNotFound;
	NSUInteger allowedCount = 0;
	for (size_t index = 0; index < catEntriesCount; index++)
		if ([notationPrefs catalogEntryAllowed:&catalogEntries[index]]) allowedCount++;
	return allowedCount;
}

- (BOOL)_readFilesUsingFoundation {
	foundationEnumerationCount++;
	return [super _readFilesUsingFoundation];
}

- (int)_getattrlistbulk:(int)directoryFD attributes:(void*)attributes
	buffer:(void*)buffer size:(size_t)bufferSize options:(uint64_t)options {
	if (forceFoundationEnumeration) {
		errno = ENOTSUP;
		return -1;
	}
	if (!injectPartialBulkFailure && !injectedBulkFailure)
		return getattrlistbulk(directoryFD, attributes, buffer, bufferSize, options);
	injectedBulkCallCount++;
	if (injectedBulkFailure == NVInjectedBulkPersistentENOENT) {
		NVTestBulkRecord record = TestBulkRecord(0);
		record.returned.commonattr = ATTR_CMN_ERROR;
		record.error = ENOENT;
		memcpy(buffer, &record, sizeof(record));
		return 1;
	}
	if (injectedBulkCallCount == 1) {
		injectedFirstBulkCount = getattrlistbulk(directoryFD, attributes, buffer,
			MIN(bufferSize, (size_t)256), options);
		return injectedFirstBulkCount;
	}
	if (injectedBulkFailure == NVInjectedBulkMalformedAfterPartial ||
		injectedBulkFailure == NVInjectedBulkInvalidUTF8AfterPartial) {
		NVTestBulkRecord record = TestBulkRecord(0);
		if (injectedBulkFailure == NVInjectedBulkMalformedAfterPartial)
			record.name.attr_dataoffset = 0;
		else {
			const char invalidUTF8[] = { (char)0xC3, '(', '\0' };
			memcpy(record.filename, invalidUTF8, sizeof(invalidUTF8));
			record.name.attr_length = sizeof(invalidUTF8);
		}
		memcpy(buffer, &record, sizeof(record));
		return 1;
	}
	errno = ENOTSUP;
	return -1;
}

- (BOOL)partialBulkFallbackDiscardsCatalog {
	injectPartialBulkFailure = YES;
	injectedBulkCallCount = 0;
	injectedFirstBulkCount = 0;
	foundationEnumerationCount = 0;
	BOOL succeeded = [self _readFilesInDirectory];
	injectPartialBulkFailure = NO;
	NSUInteger fallbackCount = foundationEnumerationCount;
	NSUInteger allowedCount = 0;
	for (size_t index = 0; index < catEntriesCount; index++)
		if ([notationPrefs catalogEntryAllowed:&catalogEntries[index]]) allowedCount++;
	NSUInteger expectedCount = [self directoryStreamNoteCount];
	return succeeded && injectedFirstBulkCount > 0 && injectedBulkCallCount == 2 &&
		fallbackCount == 1 && allowedCount == expectedCount;
}

- (BOOL)bulkFailure:(NVInjectedBulkFailure)failure discardsCatalogUsingFoundation:(BOOL)usesFoundation {
	injectedBulkFailure = failure;
	injectedBulkCallCount = 0;
	injectedFirstBulkCount = 0;
	foundationEnumerationCount = 0;
	BOOL succeeded = [self _readFilesInDirectory];
	injectedBulkFailure = 0;
	NSUInteger fallbackCount = foundationEnumerationCount;
	NSUInteger publishedCount = 0;
	for (size_t index = 0; index < catEntriesCount; index++)
		if ([notationPrefs catalogEntryAllowed:&catalogEntries[index]]) publishedCount++;
	if (usesFoundation) {
		NSUInteger expectedCount = [self directoryStreamNoteCount];
		return succeeded && injectedFirstBulkCount > 0 && injectedBulkCallCount == 2 && fallbackCount == 1 &&
			publishedCount == expectedCount;
	}
	return !succeeded && injectedBulkCallCount == 2 && fallbackCount == 0 && publishedCount == 0;
}

- (NSUInteger)foundationEnumerationsForDirectoryScan {
	foundationEnumerationCount = 0;
	return [self _readFilesInDirectory] ? foundationEnumerationCount : NSNotFound;
}

- (BOOL)synchronizeJournalOnly {
	return walWriter && [walWriter synchronize];
}

- (NSUInteger)pendingFileWriteCount { return [pendingFileWrites count]; }
- (NSUInteger)pendingJournalWriteCount { return [pendingJournalWrites count]; }
- (BOOL)writeRetryIsScheduled { return writeRetryPending && directoryRetryTimer != nil; }
- (BOOL)directoryRetryIsScheduled { return directoryRetryPending && directoryRetryTimer != nil; }
- (BOOL)changeWriteTimerIsScheduled { return changeWritingTimer != nil; }
- (NSUInteger)deletionCandidateCount {
	return [[deletionManager valueForKey:@"deletedNotes"] count];
}

- (void)breakJournalDescriptor {
	int descriptor = [[walWriter valueForKey:@"logFD"] intValue];
	REQUIRE(descriptor >= 0 && close(descriptor) == 0);
	[walWriter setValue:[NSNumber numberWithInt:-1] forKey:@"logFD"];
}

- (BOOL)bufferJournalForNoteWithoutRetiringObligation:(NoteObject*)note {
	return walWriter && [walWriter writeEstablishedNote:note];
}

- (NSUInteger)journalBufferedByteCount {
	return [[walWriter valueForKey:@"unwrittenData"] length];
}

- (void)setPreparedNoteProbeName:(NSString*)filename deallocationFlag:(BOOL*)flag {
	[preparedNoteProbeName release];
	preparedNoteProbeName = [filename copy];
	preparedNoteProbeFlag = flag;
}

- (NoteObject*)_preparedNoteForCatalogEntry:(NoteCatalogEntry*)entry
	fallbackNote:(NoteObject*)fallbackNote error:(NSError**)error {
	NoteObject *note = [super _preparedNoteForCatalogEntry:entry fallbackNote:fallbackNote error:error];
	if (note && preparedNoteProbeFlag &&
		[(NSString*)entry->filename isEqualToString:preparedNoteProbeName]) {
		NVDeallocationProbe *probe = [[[NVDeallocationProbe alloc]
			initWithFlag:preparedNoteProbeFlag] autorelease];
		objc_setAssociatedObject(note, &NVPreparedNoteDeallocationProbeKey, probe,
			OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[preparedNoteProbeName release];
		preparedNoteProbeName = nil;
		preparedNoteProbeFlag = NULL;
	}
	return note;
}

- (void)setDirectoryMoveFromPath:(NSString*)oldPath toPath:(NSString*)newPath
	onCatalogRead:(NSUInteger)catalogRead {
	[directoryMoveOldPath release];
	[directoryMoveNewPath release];
	directoryMoveOldPath = [oldPath copy];
	directoryMoveNewPath = [newPath copy];
	directoryMoveCatalogCall = catalogRead;
	directoryMoveCatalogReadCount = 0;
	directoryMoveWasPerformed = NO;
}

- (BOOL)directoryMoveWasPerformed { return directoryMoveWasPerformed; }
- (void)resetDirectoryStreamReconfigurationCount { directoryStreamReconfigurationCount = 0; }
- (NSUInteger)directoryStreamReconfigurationCount { return directoryStreamReconfigurationCount; }
- (void)simulateDirectoryStreamWithConfigurationFailures:(NSUInteger)failures {
	[self stopFileNotifications];
	eventStreamStarted = YES;
	simulateDirectoryStreamConfiguration = YES;
	directoryStreamConfigurationFailuresRemaining = failures;
}

- (BOOL)_configureDirEventStream {
	directoryStreamReconfigurationCount++;
	if (simulateDirectoryStreamConfiguration) {
		if (directoryStreamConfigurationFailuresRemaining) {
			directoryStreamConfigurationFailuresRemaining--;
			return NO;
		}
		return YES;
	}
	return [super _configureDirEventStream];
}

- (void)setMutationBeforeFenceName:(NSString*)filename content:(NSString*)content {
	[mutationBeforeFenceName release];
	[mutationBeforeFenceData release];
	mutationBeforeFenceName = [filename copy];
	mutationBeforeFenceData = [[content dataUsingEncoding:NSUTF8StringEncoding] retain];
	mutationCatalogReadCount = 0;
}

- (uint32_t)catalogDocumentIdentifierForFilename:(NSString*)filename {
	if (![self _readFilesInDirectory]) return UINT32_MAX;
	for (size_t index = 0; index < catEntriesCount; index++)
		if ([(NSString*)catalogEntries[index].filename isEqualToString:filename])
			return catalogEntries[index].documentID;
	return UINT32_MAX;
}

- (NSTimeInterval)bulkScanElapsed {
	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC_RAW, &start);
	BOOL succeeded = [self _readFilesInDirectory];
	clock_gettime(CLOCK_MONOTONIC_RAW, &end);
	if (!succeeded) return -1.0;
	return (NSTimeInterval)(end.tv_sec - start.tv_sec) +
		(NSTimeInterval)(end.tv_nsec - start.tv_nsec) / NSEC_PER_SEC;
}

- (void)setInterceptContentFallback:(BOOL)intercept {
	interceptContentFallback = intercept;
	contentFallbackCalled = NO;
}

- (BOOL)contentFallbackCalled {
	return contentFallbackCalled;
}

- (NSData*)dataFromNoteNamed:(NSString*)filename error:(NSError**)error {
	noteDataReadCount++;
	return [super dataFromNoteNamed:filename error:error];
}

- (BOOL)readNoteFileSnapshot:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error {
	noteDataReadCount++;
	if ([filename isEqualToString:failingSnapshotName]) {
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
		return NO;
	}
	BOOL succeeded = [super readNoteFileSnapshot:snapshot forNoteNamed:filename error:error];
	return succeeded;
}

- (BOOL)_readNoteFileSnapshotOnce:(NVNoteFileSnapshot*)snapshot
				forNoteNamed:(NSString*)filename error:(NSError**)error {
	snapshotAttemptCount++;
	if (![super _readNoteFileSnapshotOnce:snapshot forNoteNamed:filename error:error]) return NO;
	if (transientSnapshotFailures) {
		transientSnapshotFailures--;
		bzero(snapshot, sizeof(*snapshot));
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EAGAIN userInfo:nil];
		return NO;
	}
	return YES;
}

- (void)replaceSnapshotName:(NSString*)filename withData:(NSData*)data
	atFinalIdentityChecks:(NSUInteger)checks {
	[snapshotBoundaryMutationName release];
	[snapshotBoundaryReplacementData release];
	[snapshotBoundaryReplacementTags release];
	[snapshotBoundaryObservedTags release];
	snapshotBoundaryMutationName = [filename copy];
	snapshotBoundaryReplacementData = [data retain];
	snapshotBoundaryReplacementTags = nil;
	snapshotBoundaryObservedTags = nil;
	snapshotBoundaryMutationsRemaining = checks;
}

- (void)replaceSnapshotCocoaTags:(NSArray*)tags afterReadingTags:(NSArray*)observedTags
	forNoteNamed:(NSString*)filename atIdentityChecks:(NSUInteger)checks {
	[snapshotBoundaryMutationName release];
	[snapshotBoundaryReplacementData release];
	[snapshotBoundaryReplacementTags release];
	snapshotBoundaryMutationName = [filename copy];
	snapshotBoundaryReplacementData = nil;
	snapshotBoundaryReplacementTags = [tags copy];
	[snapshotBoundaryObservedTags release];
	snapshotBoundaryObservedTags = [observedTags copy];
	snapshotBoundaryMutationsRemaining = checks;
}

- (id)_snapshotCocoaTagsAtURL:(NSURL*)URL {
	if (snapshotBoundaryObservedTags &&
		[[URL lastPathComponent] isEqualToString:snapshotBoundaryMutationName])
		return snapshotBoundaryObservedTags;
	return [super _snapshotCocoaTagsAtURL:URL];
}

- (int)_statSnapshotName:(const char*)name status:(struct stat*)status {
	NSString *filename = [NSString stringWithUTF8String:name];
	if (snapshotBoundaryReplacementData && snapshotBoundaryMutationsRemaining &&
		[filename isEqualToString:snapshotBoundaryMutationName]) {
		REQUIRE([self storeDataAtomicallyInNotesDirectory:snapshotBoundaryReplacementData
			withName:filename verificationBlock:nil error:NULL]);
		snapshotBoundaryMutationsRemaining--;
	}
	return [super _statSnapshotName:name status:status];
}

- (BOOL)_snapshotTagURL:(NSURL*)URL referencesFileDescriptor:(int)fileDescriptor {
	if (snapshotBoundaryReplacementTags && snapshotBoundaryMutationsRemaining &&
		[[URL lastPathComponent] isEqualToString:snapshotBoundaryMutationName]) {
		const char marker = 'x';
		REQUIRE(fsetxattr(fileDescriptor, "com.notationalvelocity.snapshot-boundary",
			&marker, sizeof(marker), 0, 0) == 0);
		[snapshotBoundaryObservedTags release];
		snapshotBoundaryObservedTags = [snapshotBoundaryReplacementTags copy];
		snapshotBoundaryMutationsRemaining--;
	}
	return [super _snapshotTagURL:URL referencesFileDescriptor:fileDescriptor];
}

- (void)replaceInstalledNoteNamed:(NSString*)filename withData:(NSData*)data {
	[installedBoundaryMutationName release];
	[installedBoundaryReplacementData release];
	installedBoundaryMutationName = [filename copy];
	installedBoundaryReplacementData = [data retain];
}

- (void)_didInstallNoteFileNamed:(NSString*)filename {
	if ([filename isEqualToString:installedBoundaryMutationName]) {
		REQUIRE([self storeDataAtomicallyInNotesDirectory:installedBoundaryReplacementData
			withName:filename verificationBlock:nil error:NULL]);
		[installedBoundaryMutationName release];
		[installedBoundaryReplacementData release];
		installedBoundaryMutationName = nil;
		installedBoundaryReplacementData = nil;
	}
}

- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringTagSynchronization:(BOOL)tags {
	[inPlaceBoundaryMutationName release];
	[inPlaceBoundaryReplacementData release];
	inPlaceBoundaryMutationName = [filename copy];
	inPlaceBoundaryReplacementData = [data retain];
	mutateDuringTagSynchronization = tags;
}

- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringEncodingSynchronization:(BOOL)encoding {
	[inPlaceBoundaryMutationName release];
	[inPlaceBoundaryReplacementData release];
	inPlaceBoundaryMutationName = [filename copy];
	inPlaceBoundaryReplacementData = [data retain];
	mutateDuringEncodingSynchronization = encoding;
}

- (void)_performInPlaceBoundaryMutationForName:(NSString*)filename
	fileDescriptor:(int)fileDescriptor enabled:(BOOL*)enabled {
	if (!*enabled || ![filename isEqualToString:inPlaceBoundaryMutationName]) return;
	int mutationFD = openat(noteDirectoryFileDescriptor, [filename fileSystemRepresentation],
		O_RDWR | O_CLOEXEC | O_NOFOLLOW);
	struct stat status, mutationStatus;
	REQUIRE(mutationFD >= 0 && fstat(fileDescriptor, &status) == 0 &&
		fstat(mutationFD, &mutationStatus) == 0 && status.st_dev == mutationStatus.st_dev &&
		status.st_ino == mutationStatus.st_ino);
	REQUIRE((off_t)[inPlaceBoundaryReplacementData length] == status.st_size);
	REQUIRE(pwrite(mutationFD, [inPlaceBoundaryReplacementData bytes],
		[inPlaceBoundaryReplacementData length], 0) == (ssize_t)[inPlaceBoundaryReplacementData length]);
	struct timespec times[2] = { status.st_atimespec, status.st_mtimespec };
	REQUIRE(futimens(mutationFD, times) == 0 && fsync(mutationFD) == 0);
	REQUIRE(close(mutationFD) == 0);
	*enabled = NO;
}

- (void)_didSynchronizeTagsForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor {
	[self _performInPlaceBoundaryMutationForName:filename fileDescriptor:fileDescriptor
		enabled:&mutateDuringTagSynchronization];
}

- (void)_didSetTextEncodingForNoteNamed:(NSString*)filename fileDescriptor:(int)fileDescriptor {
	[self _performInPlaceBoundaryMutationForName:filename fileDescriptor:fileDescriptor
		enabled:&mutateDuringEncodingSynchronization];
}

- (void)setTransientSnapshotFailures:(NSUInteger)failures {
	transientSnapshotFailures = failures;
	snapshotAttemptCount = 0;
}

- (NSUInteger)snapshotAttemptCount {
	return snapshotAttemptCount;
}

- (void)schedulePushToAllSyncServicesForNote:(id<SynchronizedNote>)note {
	pushScheduleCount++;
	[super schedulePushToAllSyncServicesForNote:note];
}

- (void)resetPushScheduleCount {
	pushScheduleCount = 0;
}

- (NSUInteger)pushScheduleCount {
	return pushScheduleCount;
}

- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet {
	if ([labelSet count]) labelAddCount++;
	[super note:note didAddLabelSet:labelSet];
}

- (void)resetLabelAddCount {
	labelAddCount = 0;
}

- (NSUInteger)labelAddCount {
	return labelAddCount;
}

- (void)resortAllNotes {
	resortCount++;
	[super resortAllNotes];
}

- (void)resetResortCount {
	resortCount = 0;
}

- (NSUInteger)resortCount {
	return resortCount;
}

- (BOOL)synchronizeNotesFromDirectory {
	synchronizeCount++;
	return [super synchronizeNotesFromDirectory];
}

- (void)resetSynchronizeCount {
	synchronizeCount = 0;
}

- (NSUInteger)synchronizeCount {
	return synchronizeCount;
}

- (void)setFailingSnapshotName:(NSString*)filename {
	[failingSnapshotName release];
	failingSnapshotName = [filename copy];
}

- (void)resetNoteDataReadCount {
	noteDataReadCount = 0;
}

- (NSUInteger)noteDataReadCount {
	return noteDataReadCount;
}

- (BOOL)synchronizeWithClosedDirectoryDescriptor {
	int savedDescriptor = dup(noteDirectoryFileDescriptor);
	REQUIRE(savedDescriptor >= 0);
	REQUIRE(close(noteDirectoryFileDescriptor) == 0);
	noteDirectoryFileDescriptor = -1;
	BOOL result = [self synchronizeNotesFromDirectory];
	noteDirectoryFileDescriptor = savedDescriptor;
	return result;
}

- (BOOL)reconcileNoteUsingFoundation:(NoteObject*)note {
	(void)note;
	forceFoundationEnumeration = YES;
	BOOL result = [self synchronizeNotesFromDirectory];
	forceFoundationEnumeration = NO;
	return result;
}

- (void)setSyntheticCatalogNames:(NSArray*)names {
	[syntheticCatalogNames release];
	syntheticCatalogNames = [names copy];
}

- (BOOL)_readFilesInDirectory {
	catalogReadCount++;
	if (directoryMoveOldPath && ++directoryMoveCatalogReadCount == directoryMoveCatalogCall) {
		NSError *moveError = nil;
		REQUIRE([[NSFileManager defaultManager] moveItemAtPath:directoryMoveOldPath
			toPath:directoryMoveNewPath error:&moveError]);
		directoryMoveWasPerformed = YES;
		[directoryMoveOldPath release];
		[directoryMoveNewPath release];
		directoryMoveOldPath = directoryMoveNewPath = nil;
	}
	if (mutationBeforeFenceName && ++mutationCatalogReadCount == 2) {
		int fd = openat(noteDirectoryFileDescriptor, [mutationBeforeFenceName fileSystemRepresentation],
			O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW);
		REQUIRE(fd >= 0);
		REQUIRE(write(fd, [mutationBeforeFenceData bytes], [mutationBeforeFenceData length]) ==
			(ssize_t)[mutationBeforeFenceData length]);
		REQUIRE(fsync(fd) == 0 && close(fd) == 0);
		[mutationBeforeFenceName release];
		[mutationBeforeFenceData release];
		mutationBeforeFenceName = nil;
		mutationBeforeFenceData = nil;
	}
	if (!syntheticCatalogNames) return [super _readFilesInDirectory];
	[self _resetCatalogEntries];
	for (NSString *name in syntheticCatalogNames)
		REQUIRE([self _appendCatalogEntryFilename:(CFStringRef)[name copy]
			attributeChangeTime:(struct timespec){ 0 } documentID:0 fileID:0 generationCount:0]);
	for (size_t index = 0; index < catEntriesCount; index++)
		sortedCatalogEntries[index] = &catalogEntries[index];
	return YES;
}

- (void)resetCatalogReadCount { catalogReadCount = 0; }
- (NSUInteger)catalogReadCount { return catalogReadCount; }

- (BOOL)getFileInfo:(NVFileInfo*)info forNoteNamed:(NSString*)filename error:(NSError**)error {
	if (missingMetadataFailuresRemaining && [filename isEqualToString:missingMetadataName]) {
		missingMetadataFailuresRemaining--;
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
		return NO;
	}
	return [super getFileInfo:info forNoteNamed:filename error:error];
}

- (BOOL)foundationScanRetriesThenRejectsVanishedFilename:(NSString*)filename {
	[missingMetadataName release];
	missingMetadataName = [filename copy];
	missingMetadataFailuresRemaining = 1;
	[self _resetCatalogEntries];
	BOOL retrySucceeded = [self _readFilesUsingFoundation];
	NSUInteger matchingEntries = 0;
	for (size_t index = 0; index < catEntriesCount; index++)
		if ([(NSString*)catalogEntries[index].filename isEqualToString:filename]) matchingEntries++;
	missingMetadataFailuresRemaining = 2;
	BOOL persistentSucceeded = [self _readFilesUsingFoundation];
	BOOL persistentCatalogWasEmpty = catEntriesCount == 0;
	[missingMetadataName release];
	missingMetadataName = nil;
	missingMetadataFailuresRemaining = 0;
	return retrySucceeded && matchingEntries == 1 && !persistentSucceeded && persistentCatalogWasEmpty;
}

- (BOOL)hasCaseCollisionForNames:(NSArray*)names {
	[self _resetCatalogEntries];
	for (NSString *name in names)
		REQUIRE([self _appendCatalogEntryFilename:(CFStringRef)[name copy]
			attributeChangeTime:(struct timespec){ 0 } documentID:0 fileID:0 generationCount:0]);
	for (size_t index = 0; index < catEntriesCount; index++)
		sortedCatalogEntries[index] = &catalogEntries[index];
	return [self _catalogContainsCaseInsensitiveCollision];
}

- (BOOL)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries {
	contentFallbackCalled = YES;
	if (!interceptContentFallback)
		return [super processNotesAddedByContent:addedEntries removed:removedEntries];
	return YES;
}

- (BOOL)modifyNoteIfNecessary:(NoteObject*)note
	usingCatalogEntry:(NoteCatalogEntry*)entry {
	// Synthetic identity-order tests call the matcher without a filesystem transaction.
	if (!directoryTransaction) {
		[note applyCatalogEntry:entry filename:(NSString*)entry->filename
			title:[(NSString*)entry->filename stringByDeletingPathExtension]];
		return YES;
	}
	return [super modifyNoteIfNecessary:note usingCatalogEntry:entry];
}

- (void)dealloc {
	controllerDeallocationCount++;
	[syntheticCatalogNames release];
	[missingMetadataName release];
	[failingSnapshotName release];
	[mutationBeforeFenceName release];
	[mutationBeforeFenceData release];
	[preparedNoteProbeName release];
	[directoryMoveOldPath release];
	[directoryMoveNewPath release];
	[snapshotBoundaryMutationName release];
	[snapshotBoundaryReplacementData release];
	[snapshotBoundaryReplacementTags release];
	[snapshotBoundaryObservedTags release];
	[installedBoundaryMutationName release];
	[installedBoundaryReplacementData release];
	[inPlaceBoundaryMutationName release];
	[inPlaceBoundaryReplacementData release];
	[removeBeforeRenameExistenceCheckName release];
	[removeRenameCollisionDestinationName release];
	[lastTrashedURL release];
	[super dealloc];
}

@end

@interface NVFSEventsProbe : NSObject {
	NSUInteger configureCount;
	NSUInteger synchronizeCount;
	BOOL scheduled;
	BOOL rootChanged;
}
- (NSUInteger)configureCount;
- (NSUInteger)synchronizeCount;
@end

@implementation NVFSEventsProbe

- (void)_directoryEventOccurredWithRootChange:(BOOL)didMoveRoot invalidated:(BOOL)invalidated {
	if (didMoveRoot || invalidated) rootChanged = YES;
	if (scheduled) return;
	scheduled = YES;
	[self performSelector:@selector(_performScheduledDirectoryScan) withObject:nil afterDelay:0.0];
}
- (void)_performScheduledDirectoryScan {
	scheduled = NO;
	if (rootChanged) {
		rootChanged = NO;
		[self _configureDirEventStream];
	}
	[self synchronizeNotesFromDirectory];
}
- (BOOL)_configureDirEventStream { configureCount++; return YES; }
- (BOOL)synchronizeNotesFromDirectory { synchronizeCount++; return YES; }
- (NSUInteger)configureCount { return configureCount; }
- (NSUInteger)synchronizeCount { return synchronizeCount; }

@end

@interface NVTestControllerDelegate : NSObject {
	NSUInteger contentsUpdatedCount;
	NSMutableArray *revealedNotes;
}
- (void)resetContentsUpdatedCount;
- (NSUInteger)contentsUpdatedCount;
- (NSArray*)revealedNotes;
@end

@implementation NVTestControllerDelegate

- (id)init {
	self = [super init];
	if (self) revealedNotes = [[NSMutableArray alloc] init];
	return self;
}

- (BOOL)notationListShouldChange:(NotationController *)notation {
	(void)notation;
	return YES;
}

- (void)notationListMightChange:(NotationController *)notation { (void)notation; }
- (void)notationListDidChange:(NotationController *)notation { (void)notation; }
- (void)notation:(NotationController *)notation revealNote:(NoteObject *)note options:(NSUInteger)options {
	(void)notation; (void)options;
	if (note) [revealedNotes addObject:note];
}
- (void)notation:(NotationController *)notation revealNotes:(NSArray *)notes {
	(void)notation;
	[revealedNotes addObjectsFromArray:notes];
}
- (void)contentsUpdatedForNote:(NoteObject *)note { (void)note; contentsUpdatedCount++; }
- (void)resetContentsUpdatedCount { contentsUpdatedCount = 0; }
- (NSUInteger)contentsUpdatedCount { return contentsUpdatedCount; }
- (NSArray*)revealedNotes { return revealedNotes; }
- (void)titleUpdatedForNote:(NoteObject *)note { (void)note; }
- (void)rowShouldUpdate:(NSInteger)row { (void)row; }

- (void)dealloc {
	[revealedNotes release];
	[super dealloc];
}

@end

@interface NVCorruptArchiveObject : NSObject <NSCoding>
@end

@implementation NVCorruptArchiveObject

- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }

- (id)initWithCoder:(NSCoder *)coder {
	(void)coder;
	[NSException raise:NSInvalidUnarchiveOperationException format:@"intentional corrupt database fixture"];
	return nil;
}

@end

static NSString *CreateTemporaryDirectory(void) {
	NSString *root = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_TEST_VOLUME_ROOT"];
	if (![root length]) root = NSTemporaryDirectory();
	NSString *path = [root stringByAppendingPathComponent:
		[NSString stringWithFormat:@"NVIntegrationTest-%@", [[NSUUID UUID] UUIDString]]];
	NSError *error = nil;
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:path
									withIntermediateDirectories:YES attributes:nil error:&error]);
	return path;
}

static NSURL *FileReferenceURLForPath(NSString *path) {
	NSURL *url = [NSURL fileURLWithPath:path];
	NSError *error = nil;
	NSURL *referenceURL = [[NSFileManager defaultManager] fileReferenceURLForURL:url error:&error];
	REQUIRE(referenceURL != nil);
	REQUIRE([referenceURL isFileReferenceURL]);
	REQUIRE(error == nil);
	return referenceURL;
}

static NVTestNotationController *CreateControllerWithURL(NSURL *directoryURL, NVTestControllerDelegate *delegate) {
	OSStatus status = noErr;
	NVTestNotationController *controller = [[NVTestNotationController alloc] initWithDirectoryURL:directoryURL error:&status];
	REQUIRE(controller != nil);
	REQUIRE(status == noErr);
	[controller setDelegate:delegate];
	return controller;
}

static NVTestNotationController *CreateController(NSString *directoryPath, NVTestControllerDelegate *delegate) {
	return CreateControllerWithURL(FileReferenceURLForPath(directoryPath), delegate);
}

static BOOL URLsReferToSameItem(NSURL *one, NSURL *two);

static NSString *WALNotesDirectoryPath(NSString *rootPath) {
	return [rootPath stringByAppendingPathComponent:@"Notes"];
}

static NSString *WALBookmarkPath(NSString *rootPath) {
	return [rootPath stringByAppendingPathComponent:@"Notes.bookmark"];
}

static NSString *WALJournalPath(NSString *rootPath) {
	return [WALNotesDirectoryPath(rootPath) stringByAppendingPathComponent:@"Interim Note-Changes"];
}

static void PrepareWALBookmarkFixture(NSString *rootPath) {
	NSString *directoryPath = WALNotesDirectoryPath(rootPath);
	NSError *error = nil;
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
		withIntermediateDirectories:NO attributes:nil error:&error]);
	NSURL *referenceURL = FileReferenceURLForPath(directoryPath);
	NSData *bookmark = [[NSFileManager defaultManager]
		bookmarkDataForFileReferenceURL:referenceURL error:&error];
	REQUIRE(bookmark != nil && error == nil);
	REQUIRE([bookmark writeToFile:WALBookmarkPath(rootPath)
		options:NSDataWritingAtomic error:&error]);
	REQUIRE(error == nil);
}

static NSURL *ResolveWALBookmark(NSString *rootPath) {
	NSData *bookmark = [NSData dataWithContentsOfFile:WALBookmarkPath(rootPath)];
	BOOL stale = NO;
	NSError *error = nil;
	NSURL *referenceURL = [[NSFileManager defaultManager]
		fileReferenceURLFromBookmarkData:bookmark stale:&stale error:&error];
	REQUIRE(referenceURL != nil && error == nil && [referenceURL isFileReferenceURL]);
	REQUIRE(URLsReferToSameItem(referenceURL,
		[NSURL fileURLWithPath:WALNotesDirectoryPath(rootPath)]));
	return referenceURL;
}

static NVTestNotationController *CreateControllerResolvingWALBookmark(
	NSString *rootPath, NVTestControllerDelegate *delegate) {
	return CreateControllerWithURL(ResolveWALBookmark(rootPath), delegate);
}

static BOOL URLsReferToSameItem(NSURL *one, NSURL *two) {
	int oneFD = open([one fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
	int twoFD = open([two fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
	struct stat oneInfo;
	struct stat twoInfo;
	BOOL same = oneFD >= 0 && twoFD >= 0 && fstat(oneFD, &oneInfo) == 0 &&
		fstat(twoFD, &twoInfo) == 0 && oneInfo.st_dev == twoInfo.st_dev && oneInfo.st_ino == twoInfo.st_ino;
	if (oneFD >= 0) close(oneFD);
	if (twoFD >= 0) close(twoFD);
	return same;
}

static BOOL URLIsReferenceBased(NSURL *url) {
	return [url isFileReferenceURL] || [[url baseURL] isFileReferenceURL];
}

static void CloseController(NVTestNotationController **controller) {
	if (*controller) {
		[NSObject cancelPreviousPerformRequestsWithTarget:*controller];
		[*controller closeAllResources];
		[*controller release];
		*controller = nil;
	}
}

static void RemoveTemporaryDirectory(NSString *path) {
	chmod([path fileSystemRepresentation], 0700);
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSArray *AllNotes(NotationController *controller) {
	return [controller valueForKey:@"allNotes"];
}

static NoteObject *NoteContaining(NotationController *controller, NSString *text) {
	for (NoteObject *note in AllNotes(controller)) {
		if ([[[note contentString] string] rangeOfString:text].location != NSNotFound)
			return note;
	}
	return nil;
}

static NoteObject *AddTestNote(NotationController *controller, NSString *title, NSString *body) {
	NoteObject *note = [[[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:body] autorelease]
		title:title delegate:controller format:[controller currentNoteStorageFormat] labels:@""] autorelease];
	REQUIRE(note != nil);
	[controller addNewNote:note];
	return note;
}

static NSMutableAttributedString *StyledBody(NSString *version) {
	NSString *string = [NSString stringWithFormat:@"Unicode café 東京 — bold and italic — %@", version];
	NSFont *bodyFont = [NSFont systemFontOfSize:13.0];
	NSMutableAttributedString *body = [[[NSMutableAttributedString alloc] initWithString:string
		attributes:@{ NSFontAttributeName: bodyFont }] autorelease];
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	NSRange boldRange = [string rangeOfString:@"bold"];
	NSRange italicRange = [string rangeOfString:@"italic"];
	[body addAttribute:NSFontAttributeName
				 value:[fontManager convertFont:bodyFont toHaveTrait:NSBoldFontMask]
				 range:boldRange];
	[body addAttribute:NSFontAttributeName
				 value:[fontManager convertFont:bodyFont toHaveTrait:NSItalicFontMask]
				 range:italicRange];
	return body;
}

static BOOL BodyPreservesStyles(NSAttributedString *body) {
	NSString *string = [body string];
	NSRange boldRange = [string rangeOfString:@"bold"];
	NSRange italicRange = [string rangeOfString:@"italic"];
	if (boldRange.location == NSNotFound || italicRange.location == NSNotFound)
		return NO;
	NSFontManager *fontManager = [NSFontManager sharedFontManager];
	NSFont *boldFont = [body attribute:NSFontAttributeName atIndex:boldRange.location effectiveRange:NULL];
	NSFont *italicFont = [body attribute:NSFontAttributeName atIndex:italicRange.location effectiveRange:NULL];
	return ([fontManager traitsOfFont:boldFont] & NSBoldFontMask) &&
		([fontManager traitsOfFont:italicFont] & NSItalicFontMask);
}

static NSData *DataForExternalFile(int format, NSString *string) {
	NSAttributedString *body = [[[NSAttributedString alloc] initWithString:string] autorelease];
	if (format == PlainTextFormat)
		return [string dataUsingEncoding:NSUTF8StringEncoding];
	if (format == RTFTextFormat)
		return [body RTFFromRange:NSMakeRange(0, [body length]) documentAttributes:@{}];
	NSError *error = nil;
	NSData *data = [body dataFromRange:NSMakeRange(0, [body length])
				  documentAttributes:@{ NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType }
							 error:&error];
	REQUIRE(data != nil);
	REQUIRE(error == nil);
	return data;
}

static void WriteExternalFile(int format, NSString *string, NSString *path) {
	NSError *error = nil;
	REQUIRE([DataForExternalFile(format, string) writeToFile:path options:NSDataWritingAtomic error:&error]);
}

static void WriteExternalFileInPlace(NSString *string, NSString *path) {
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	int descriptor = open([path fileSystemRepresentation], O_WRONLY | O_TRUNC | O_CLOEXEC);
	REQUIRE(descriptor >= 0);
	REQUIRE(write(descriptor, [data bytes], [data length]) == (ssize_t)[data length]);
	REQUIRE(fsync(descriptor) == 0);
	REQUIRE(close(descriptor) == 0);
}

typedef struct {
	const void *data;
	size_t dataLength;
	const void *encoding;
	size_t encodingLength;
	const void *tags;
	size_t tagsLength;
} NVSnapshotStressVersion;

static BOOL WriteAll(int descriptor, const void *bytes, size_t length) {
	while (length) {
		ssize_t amount = write(descriptor, bytes, length);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) return NO;
		bytes = (const uint8_t*)bytes + amount;
		length -= (size_t)amount;
	}
	return YES;
}

static BOOL InstallSnapshotStressVersion(int directoryFD, const char *filename,
	const NVSnapshotStressVersion *version, unsigned int sequence) {
	char temporaryName[128];
	if (snprintf(temporaryName, sizeof(temporaryName), ".NVSnapshotStress-%d-%u",
		getpid(), sequence) >= (int)sizeof(temporaryName)) return NO;
	int descriptor = openat(directoryFD, temporaryName,
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	if (descriptor < 0) return NO;
	BOOL succeeded = WriteAll(descriptor, version->data, version->dataLength) &&
		(!version->encoding || fsetxattr(descriptor, "com.apple.TextEncoding",
			version->encoding, version->encodingLength, 0, 0) == 0) &&
		(!version->tags || fsetxattr(descriptor, "com.apple.metadata:kMDItemOMUserTags",
			version->tags, version->tagsLength, 0, 0) == 0) &&
		fsync(descriptor) == 0;
	if (close(descriptor) < 0) succeeded = NO;
	if (succeeded && renameat(directoryFD, temporaryName, directoryFD, filename) < 0)
		succeeded = NO;
	if (!succeeded) (void)unlinkat(directoryFD, temporaryName, 0);
	return succeeded;
}

static void RemoveTrashArtifact(NSURL *url) {
	if (url)
		[[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
}

static void RequireNoTemporaryFiles(NSString *directoryPath) {
	NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:NULL];
	for (NSString *name in names)
		REQUIRE(![name hasPrefix:@"."]);
}

static void RequireMode(NSString *path, NSUInteger expectedMode) {
	NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
	REQUIRE(([[attributes objectForKey:NSFilePosixPermissions] unsignedIntegerValue] & 0777) == expectedMode);
}

static void WaitForNoteCount(NotationController *controller, NSUInteger expectedCount) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
	while ([controller totalNoteCount] != expectedCount && [deadline timeIntervalSinceNow] > 0.0)
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
	REQUIRE([controller totalNoteCount] == expectedCount);
}

static NVTestBulkRecord TestBulkRecord(uint32_t documentID) {
	NVTestBulkRecord record = { 0 };
	record.length = (uint32_t)sizeof(record);
	record.returned.commonattr = ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |
		ATTR_CMN_CHGTIME | ATTR_CMN_GEN_COUNT | ATTR_CMN_DOCUMENT_ID | ATTR_CMN_FILEID;
	record.name.attr_dataoffset = (int32_t)offsetof(NVTestBulkRecord, filename) -
		(int32_t)offsetof(NVTestBulkRecord, name);
	record.name.attr_length = 9;
	record.objectType = VREG;
	record.changeTime = (struct timespec){ 123, 456 };
	record.generationCount = 0x10203040;
	record.documentID = documentID;
	record.fileID = 0x1122334455667788ULL;
	memcpy(record.filename, "note.txt", 9);
	return record;
}

static void TestBulkParser(void) {
	NVTestBulkRecord record = TestBulkRecord(0xAABBCCDD);
	size_t recordLength = 0, nameLength = 0;
	const char *name = NULL;
	struct timespec changeTime = { 0 };
	uint32_t documentID = 0;
	uint32_t generationCount = 0;
	uint64_t fileID = 0;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), &recordLength, &name,
		&nameLength, &changeTime, &documentID, &fileID, &generationCount) == NVBulkCatalogRecordFile);
	REQUIRE(recordLength == sizeof(record));
	REQUIRE(nameLength == 8 && memcmp(name, "note.txt", 8) == 0);
	REQUIRE(changeTime.tv_sec == 123 && changeTime.tv_nsec == 456);
	REQUIRE(documentID == 0xAABBCCDD);
	REQUIRE(fileID == 0x1122334455667788ULL);
	REQUIRE(generationCount == 0x10203040);

	record = TestBulkRecord(0);
	documentID = UINT32_MAX;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		&documentID, NULL, NULL) == NVBulkCatalogRecordFile);
	REQUIRE(documentID == 0);

	record = TestBulkRecord(1);
	record.returned.commonattr &= ~ATTR_CMN_GEN_COUNT;
	generationCount = UINT32_MAX;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, &generationCount) == NVBulkCatalogRecordFile);
	REQUIRE(generationCount == 0);

	record = TestBulkRecord(1);
	record.returned.commonattr |= ATTR_CMN_MODTIME;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordFile);

	record = TestBulkRecord(1);
	record.returned.commonattr &= ~ATTR_CMN_FILEID;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordUnsupported);

	record = TestBulkRecord(1);
	record.error = EACCES;
	record.returned.commonattr = ATTR_CMN_ERROR;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordUnsupported);

	record.error = ENOENT;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordTransient);

	record = TestBulkRecord(1);
	record.length = sizeof(record) - 1;
	record.name.attr_length = sizeof(record.filename) + 1;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordMalformed);

	record = TestBulkRecord(1);
	record.name.attr_dataoffset = 0;
	record.name.attr_length = 8;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordMalformed);

	record = TestBulkRecord(1);
	record.name.attr_dataoffset = INT32_MAX;
	record.name.attr_length = UINT32_MAX;
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordMalformed);

	record = TestBulkRecord(1);
	memcpy(record.filename, "note\0txt", 9);
	REQUIRE(NVParseBulkCatalogRecord(&record, sizeof(record), NULL, NULL, NULL, NULL,
		NULL, NULL, NULL) == NVBulkCatalogRecordMalformed);
}

static uint32_t NextFuzzValue(uint32_t *state) {
	*state ^= *state << 13;
	*state ^= *state >> 17;
	*state ^= *state << 5;
	return *state;
}

static void RequireSafeBulkParse(const void *bytes, size_t available) {
	size_t recordLength = 0, nameLength = 0;
	const char *name = NULL;
	NVBulkCatalogParseResult result = NVParseBulkCatalogRecord(bytes, available,
		&recordLength, &name, &nameLength, NULL, NULL, NULL, NULL);
	REQUIRE(result >= NVBulkCatalogRecordMalformed && result <= NVBulkCatalogRecordFile);
	if (result != NVBulkCatalogRecordFile) return;
	REQUIRE(recordLength > 0 && recordLength <= available);
	REQUIRE(nameLength > 0 && name >= (const char*)bytes &&
		name + nameLength <= (const char*)bytes + recordLength);
	REQUIRE(memchr(name, '\0', nameLength) == NULL);
	CFStringRef decodedName = CFStringCreateWithBytes(kCFAllocatorDefault,
		(const UInt8*)name, nameLength, kCFStringEncodingUTF8, false);
	if (decodedName) CFRelease(decodedName);
}

static void TestBulkParserFuzz(void) {
	NVTestBulkRecord valid = TestBulkRecord(0x12345678);
	size_t pageSize = (size_t)getpagesize();
	uint8_t *pages = mmap(NULL, pageSize * 2, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANON, -1, 0);
	REQUIRE(pages != MAP_FAILED);
	REQUIRE(mprotect(pages + pageSize, pageSize, PROT_NONE) == 0);
	for (size_t available = 0; available <= sizeof(valid); available++) {
		uint8_t *bytes = pages + pageSize - available;
		if (available) memcpy(bytes, &valid, available);
		RequireSafeBulkParse(bytes, available);
	}
	REQUIRE(munmap(pages, pageSize * 2) == 0);

	uint32_t state = 0x4E565455U;
	for (NSUInteger iteration = 0; iteration < 50000; iteration++) {
		uint8_t bytes[sizeof(NVTestBulkRecord) + 32];
		for (size_t index = 0; index < sizeof(bytes); index++)
			bytes[index] = (uint8_t)NextFuzzValue(&state);
		if (iteration & 1) {
			memcpy(bytes, &valid, sizeof(valid));
			size_t mutations = 1 + NextFuzzValue(&state) % 6;
			for (size_t index = 0; index < mutations; index++)
				bytes[NextFuzzValue(&state) % sizeof(bytes)] ^= (uint8_t)NextFuzzValue(&state);
		}
		RequireSafeBulkParse(bytes, NextFuzzValue(&state) % (sizeof(bytes) + 1));
	}
}

static uint32_t FoundationDocumentIdentifier(NSString *path) {
	id value = nil;
	NSURL *URL = [NSURL fileURLWithPath:path];
	REQUIRE([URL getResourceValue:&value forKey:NSURLDocumentIdentifierKey error:NULL]);
	return (uint32_t)[value unsignedIntValue];
}

static NSInteger SnapshotStressVersionIndex(NVNoteFileSnapshot *snapshot,
	NSArray *contents, NSArray *encodings, NSArray *tags) {
	for (NSUInteger index = 0; index < [contents count]; index++) {
		if (![snapshot->data isEqualToData:[contents objectAtIndex:index]]) continue;
		if (snapshot->encoding != [[encodings objectAtIndex:index] unsignedIntegerValue]) return NSNotFound;
		id expectedTags = [tags objectAtIndex:index];
		if (expectedTags == [NSNull null]) return snapshot->tags == nil ? (NSInteger)index : NSNotFound;
		return [snapshot->tags isEqual:expectedTags] ? (NSInteger)index : NSNotFound;
	}
	return NSNotFound;
}

static void TestSnapshotStress(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	pid_t writer = -1;
	int directoryFD = -1;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		directoryFD = open([directoryPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		REQUIRE(directoryFD >= 0);

		NSData *contentA = [@"snapshot-version-A" dataUsingEncoding:NSUTF8StringEncoding];
		NSData *contentB = [@"snapshot-version-B" dataUsingEncoding:NSUTF8StringEncoding];
		NSMutableData *contentC = [NSMutableData dataWithLength:32768];
		memset([contentC mutableBytes], 'C', [contentC length]);
		memcpy([contentC mutableBytes], "snapshot-version-C", strlen("snapshot-version-C"));
		NSArray *tagsA = @[ @"Red\n6", @"Caf\u00e9 \u6771\u4eac\n3" ];
		NSArray *tagsC = @[ @"Blue\n4" ];
		NSData *tagsAData = [NSPropertyListSerialization dataWithPropertyList:tagsA
			format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		NSData *tagsCData = [NSPropertyListSerialization dataWithPropertyList:tagsC
			format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
		const char encodingA[] = "utf-8";
		const char encodingC[] = "US-ASCII;1536";
		NVSnapshotStressVersion versions[] = {
			{ [contentA bytes], [contentA length], encodingA, sizeof(encodingA) - 1,
				[tagsAData bytes], [tagsAData length] },
			{ [contentB bytes], [contentB length], NULL, 0, NULL, 0 },
			{ [contentC bytes], [contentC length], encodingC, sizeof(encodingC) - 1,
				[tagsCData bytes], [tagsCData length] }
		};
		NSArray *contents = @[ contentA, contentB, contentC ];
		NSArray *encodings = @[ @(NSUTF8StringEncoding), @0, @(NSASCIIStringEncoding) ];
		NSArray *expectedTags = @[ tagsA, [NSNull null], tagsC ];
		const char *filename = "Snapshot Stress.txt";
		REQUIRE(InstallSnapshotStressVersion(directoryFD, filename, &versions[0], 0));

		writer = fork();
		REQUIRE(writer >= 0);
		if (writer == 0) {
			const char *awayName = ".NVSnapshotStress-away";
			for (unsigned int iteration = 1; iteration <= 600; iteration++) {
				if (!InstallSnapshotStressVersion(directoryFD, filename,
					&versions[iteration % 3], iteration)) _exit(10);
				if (iteration % 23 == 0) {
					(void)unlinkat(directoryFD, awayName, 0);
					if (renameat(directoryFD, filename, directoryFD, awayName) < 0) _exit(11);
					usleep(75);
					if (renameat(directoryFD, awayName, directoryFD, filename) < 0) _exit(12);
				}
				usleep(100);
			}
			_exit(0);
		}

		NSUInteger successes = 0, retryableFailures = 0, mixtures = 0;
		NSUInteger observed[3] = { 0, 0, 0 };
		int writerStatus = 0;
		while (waitpid(writer, &writerStatus, WNOHANG) == 0) {
			NSAutoreleasePool *iterationPool = [[NSAutoreleasePool alloc] init];
			NVNoteFileSnapshot snapshot;
			NSError *error = nil;
			if ([controller readNoteFileSnapshot:&snapshot forNoteNamed:@"Snapshot Stress.txt" error:&error]) {
				NSInteger version = SnapshotStressVersionIndex(&snapshot, contents, encodings, expectedTags);
				if (version == NSNotFound) mixtures++;
				else observed[version]++;
				successes++;
			} else {
				REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain]);
				REQUIRE([error code] == EAGAIN || [error code] == ENOENT);
				retryableFailures++;
			}
			[iterationPool drain];
		}
		writer = -1;
		REQUIRE(WIFEXITED(writerStatus) && WEXITSTATUS(writerStatus) == 0);
		REQUIRE(successes > 10 && mixtures == 0);
		REQUIRE(observed[0] && observed[1] && observed[2]);
		struct statfs volume;
		REQUIRE(statfs([directoryPath fileSystemRepresentation], &volume) == 0);
		NSLog(@"snapshot stress (%s): %lu coherent, %lu retryable; versions %lu/%lu/%lu",
			volume.f_fstypename, (unsigned long)successes, (unsigned long)retryableFailures,
			(unsigned long)observed[0], (unsigned long)observed[1], (unsigned long)observed[2]);
	} @finally {
		if (writer > 0) {
			kill(writer, SIGKILL);
			(void)waitpid(writer, NULL, 0);
		}
		if (directoryFD >= 0) close(directoryFD);
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestInPlaceSnapshotObservation(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	pid_t writer = -1;
	int directoryFD = -1;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		directoryFD = open([directoryPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		REQUIRE(directoryFD >= 0);
		NSData *contentA = [@"in-place-version-A" dataUsingEncoding:NSUTF8StringEncoding];
		NSData *contentB = [@"in-place-version-B" dataUsingEncoding:NSUTF8StringEncoding];
		NSArray *tagsA = @[ @"Red\n6" ];
		NSArray *tagsB = @[ @"Blue\n4" ];
		NSData *tagsAData = [NSPropertyListSerialization dataWithPropertyList:tagsA
			format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		NSData *tagsBData = [NSPropertyListSerialization dataWithPropertyList:tagsB
			format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		const char encodingA[] = "utf-8";
		const char encodingB[] = "US-ASCII;1536";
		NVSnapshotStressVersion versions[] = {
			{ [contentA bytes], [contentA length], encodingA, sizeof(encodingA) - 1,
				[tagsAData bytes], [tagsAData length] },
			{ [contentB bytes], [contentB length], encodingB, sizeof(encodingB) - 1,
				[tagsBData bytes], [tagsBData length] }
		};
		NSArray *contents = @[ contentA, contentB ];
		NSArray *encodings = @[ @(NSUTF8StringEncoding), @(NSASCIIStringEncoding) ];
		NSArray *expectedTags = @[ tagsA, tagsB ];
		const char *filename = "In Place Stress.txt";
		REQUIRE(InstallSnapshotStressVersion(directoryFD, filename, &versions[0], 0));

		writer = fork();
		REQUIRE(writer >= 0);
		if (writer == 0) {
			int descriptor = openat(directoryFD, filename, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
			if (descriptor < 0) _exit(20);
			for (unsigned int iteration = 1; iteration <= 400; iteration++) {
				NVSnapshotStressVersion *version = &versions[iteration % 2];
				if (ftruncate(descriptor, 0) < 0 || lseek(descriptor, 0, SEEK_SET) < 0 ||
					!WriteAll(descriptor, version->data, version->dataLength) || fsync(descriptor) < 0)
					_exit(21);
				usleep(300);
				if (fsetxattr(descriptor, "com.apple.TextEncoding", version->encoding,
					version->encodingLength, 0, 0) < 0) _exit(22);
				usleep(150);
				if (fsetxattr(descriptor, "com.apple.metadata:kMDItemOMUserTags", version->tags,
					version->tagsLength, 0, 0) < 0 || fsync(descriptor) < 0) _exit(23);
				usleep(300);
			}
			close(descriptor);
			_exit(0);
		}

		NSUInteger coherent = 0, mixed = 0, rejected = 0;
		NSUInteger observed[2] = { 0, 0 };
		int writerStatus = 0;
		while (waitpid(writer, &writerStatus, WNOHANG) == 0) {
			NSAutoreleasePool *iterationPool = [[NSAutoreleasePool alloc] init];
			NVNoteFileSnapshot snapshot;
			NSError *error = nil;
			if ([controller readNoteFileSnapshot:&snapshot forNoteNamed:@"In Place Stress.txt" error:&error]) {
				NSInteger version = SnapshotStressVersionIndex(&snapshot, contents, encodings, expectedTags);
				if (version == NSNotFound) mixed++;
				else { observed[version]++; coherent++; }
			} else {
				REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain]);
				rejected++;
			}
			[iterationPool drain];
		}
		writer = -1;
		REQUIRE(WIFEXITED(writerStatus) && WEXITSTATUS(writerStatus) == 0);
		REQUIRE(coherent > 10 && observed[0] && observed[1]);
		NSLog(@"in-place snapshot observation: coherent=%lu mixed=%lu rejected=%lu",
			(unsigned long)coherent, (unsigned long)mixed, (unsigned long)rejected);
	} @finally {
		if (writer > 0) {
			kill(writer, SIGKILL);
			(void)waitpid(writer, NULL, 0);
		}
		if (directoryFD >= 0) close(directoryFD);
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestXattrInteroperability(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Finder Metadata.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"Finder metadata", path);
		NSArray *finderTags = @[ @"Red\n6", @"Caf\u00e9 \u6771\u4eac\n3", @"Plain" ];
		NSData *tagData = [NSPropertyListSerialization dataWithPropertyList:finderTags
			format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
		REQUIRE(setxattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", [tagData bytes], [tagData length], 0, 0) == 0);
		const char encodingName[] = "utf-8";
		REQUIRE(setxattr([path fileSystemRepresentation], "com.apple.TextEncoding",
			encodingName, sizeof(encodingName) - 1, 0, 0) == 0);
		NVNoteFileSnapshot snapshot;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:NULL]);
		REQUIRE([snapshot.tags isEqual:finderTags] && snapshot.encoding == NSUTF8StringEncoding);

		const char numericEncoding[] = "US-ASCII;1536";
		REQUIRE(setxattr([path fileSystemRepresentation], "com.apple.TextEncoding",
			numericEncoding, sizeof(numericEncoding) - 1, 0, 0) == 0);
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:NULL]);
		REQUIRE(snapshot.encoding == NSASCIIStringEncoding && [snapshot.tags isEqual:finderTags]);
		REQUIRE(removexattr([path fileSystemRepresentation], "com.apple.TextEncoding", 0) == 0);
		REQUIRE(removexattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", 0) == 0);
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:NULL]);
		REQUIRE(snapshot.encoding == 0 && snapshot.tags == nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestSnapshotBoundaryRaces(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Snapshot Boundary.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"before final identity lookup", path);
		NSData *replacement = [@"after final identity lookup" dataUsingEncoding:NSUTF8StringEncoding];
		[controller setTransientSnapshotFailures:0];
		[controller replaceSnapshotName:filename withData:replacement atFinalIdentityChecks:1];
		NVNoteFileSnapshot snapshot;
		NSError *error = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&error]);
		REQUIRE(error == nil && [controller snapshotAttemptCount] == 2);
		REQUIRE([snapshot.data isEqualToData:replacement]);

		NSArray *beforeTags = @[ @"before-cocoa-tag" ];
		NSArray *afterTags = @[ @"after-cocoa-tag" ];
		if (removexattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", 0) < 0)
			REQUIRE(errno == ENOATTR);
		[controller setTransientSnapshotFailures:0];
		[controller replaceSnapshotCocoaTags:afterTags afterReadingTags:beforeTags
			forNoteNamed:filename atIdentityChecks:1];
		error = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&error]);
		REQUIRE(error == nil && [controller snapshotAttemptCount] == 2);
		REQUIRE([snapshot.tags isEqual:afterTags]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestPartialBulkFallback(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		for (NSUInteger index = 0; index < 40; index++)
			WriteExternalFile(PlainTextFormat, @"bulk fallback",
				[directoryPath stringByAppendingPathComponent:
					[NSString stringWithFormat:@"Bulk Fallback %02lu.txt", (unsigned long)index]]);
		REQUIRE([controller partialBulkFallbackDiscardsCatalog]);
		REQUIRE([controller bulkFailure:NVInjectedBulkMalformedAfterPartial
			discardsCatalogUsingFoundation:YES]);
		REQUIRE([controller bulkFailure:NVInjectedBulkInvalidUTF8AfterPartial
			discardsCatalogUsingFoundation:YES]);
		REQUIRE([controller bulkFailure:NVInjectedBulkPersistentENOENT
			discardsCatalogUsingFoundation:NO]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

typedef struct __attribute__((packed, aligned(4))) {
	uint32_t length;
	attribute_set_t returned;
	uint32_t generationCount;
} NVGenerationCountRecord;

static void TestFilesystemCapabilities(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSString *capabilityPath = [directoryPath stringByAppendingPathComponent:@"Capability.txt"];
	NSString *upperPath = [directoryPath stringByAppendingPathComponent:@"Case Probe.txt"];
	NSString *lowerPath = [directoryPath stringByAppendingPathComponent:@"case probe.txt"];
	@try {
		WriteExternalFile(PlainTextFormat, @"filesystem capability", capabilityPath);
		int upperFD = open([upperPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
		REQUIRE(upperFD >= 0);
		REQUIRE(close(upperFD) == 0);
		int lowerFD = open([lowerPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
		BOOL caseSensitive = lowerFD >= 0;
		if (lowerFD >= 0) REQUIRE(close(lowerFD) == 0);
		else REQUIRE(errno == EEXIST);
		[[NSFileManager defaultManager] removeItemAtPath:lowerPath error:NULL];
		[[NSFileManager defaultManager] removeItemAtPath:upperPath error:NULL];

		const char xattrValue[] = "nv";
		BOOL supportsXattrs = setxattr([capabilityPath fileSystemRepresentation],
			"com.notationalvelocity.filesystem-test", xattrValue, sizeof(xattrValue) - 1, 0, 0) == 0;
		if (supportsXattrs)
			REQUIRE(removexattr([capabilityPath fileSystemRepresentation],
				"com.notationalvelocity.filesystem-test", 0) == 0);
		else REQUIRE(errno == ENOTSUP || errno == EPERM);

		struct statfs volume;
		REQUIRE(statfs([directoryPath fileSystemRepresentation], &volume) == 0);
		NSString *expectedFilesystem = [[[NSProcessInfo processInfo] environment]
			objectForKey:@"NV_EXPECT_FSTYPE"];
		if ([expectedFilesystem length])
			REQUIRE([expectedFilesystem isEqualToString:
				[NSString stringWithUTF8String:volume.f_fstypename]]);
		NSString *expectedCase = [[[NSProcessInfo processInfo] environment]
			objectForKey:@"NV_EXPECT_CASE_SENSITIVE"];
		if ([expectedCase length]) REQUIRE(caseSensitive == [expectedCase boolValue]);

		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NVFileInfo info;
		NSError *metadataError = nil;
		REQUIRE([controller getFileInfo:&info forNoteNamed:@"Capability.txt" error:&metadataError]);
		REQUIRE(metadataError == nil && info.fileID != 0);
		NSUInteger foundationCount = [controller foundationEnumerationsForDirectoryScan];
		REQUIRE(foundationCount != NSNotFound);
		NVNoteFileSnapshot snapshot;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:@"Capability.txt" error:NULL]);

		id foundationDocumentID = nil;
		BOOL foundationDocumentIDAvailable = [[NSURL fileURLWithPath:capabilityPath]
			getResourceValue:&foundationDocumentID forKey:NSURLDocumentIdentifierKey error:NULL];
		if (foundationDocumentIDAvailable && info.documentID && [foundationDocumentID unsignedIntValue])
			REQUIRE(info.documentID == [foundationDocumentID unsignedIntValue]);

		int fileFD = open([capabilityPath fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
		REQUIRE(fileFD >= 0);
		struct attrlist requested;
		bzero(&requested, sizeof(requested));
		requested.bitmapcount = ATTR_BIT_MAP_COUNT;
		requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_GEN_COUNT;
		NVGenerationCountRecord generation = { 0 };
		BOOL generationQuerySucceeded = fgetattrlist(fileFD, &requested, &generation,
			sizeof(generation), FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS) == 0;
		REQUIRE(close(fileFD) == 0);
		BOOL generationAvailable = generationQuerySucceeded &&
			(generation.returned.commonattr & ATTR_CMN_GEN_COUNT) != 0;
		if ([expectedFilesystem length]) {
			REQUIRE(foundationCount == 0);
			REQUIRE(supportsXattrs);
			if ([expectedFilesystem isEqualToString:@"apfs"]) REQUIRE(generationAvailable);
			if ([expectedFilesystem isEqualToString:@"exfat"]) REQUIRE(!generationAvailable);
		}

		NSLog(@"filesystem capabilities: fs=%s case-sensitive=%@ xattrs=%@ enumeration=%@ "
			"document-id=%u foundation-document-id=%@ file-id=%llu generation=%@:%u ctime=%lld.%09ld",
			volume.f_fstypename, caseSensitive ? @"yes" : @"no", supportsXattrs ? @"yes" : @"no",
			foundationCount ? @"Foundation" : @"bulk", info.documentID,
			foundationDocumentIDAvailable ? foundationDocumentID : @"unavailable",
			(unsigned long long)info.fileID, generationAvailable ? @"available" : @"unavailable",
			generation.generationCount, (long long)info.attributeModificationTime.tv_sec,
			(long)info.attributeModificationTime.tv_nsec);
	} @finally {
		CloseController(&controller);
		[delegate release];
		[[NSFileManager defaultManager] removeItemAtPath:lowerPath error:NULL];
		[[NSFileManager defaultManager] removeItemAtPath:upperPath error:NULL];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void SpawnScenarioWithEnvironment(NSString *scenario, const char *variable,
	NSString *value, int expectedExitStatus) {
	const char *oldValue = getenv(variable);
	NSString *savedValue = oldValue ? [NSString stringWithUTF8String:oldValue] : nil;
	REQUIRE(setenv(variable, [value fileSystemRepresentation], 1) == 0);
	NSString *executable = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
	char *childArguments[] = {
		(char*)[executable fileSystemRepresentation], (char*)[scenario UTF8String], NULL
	};
	pid_t child = -1;
	int spawnResult = posix_spawn(&child, childArguments[0], NULL, NULL, childArguments, environ);
	if (savedValue) REQUIRE(setenv(variable, [savedValue UTF8String], 1) == 0);
	else REQUIRE(unsetenv(variable) == 0);
	REQUIRE(spawnResult == 0 && child > 0);
	int status = 0;
	REQUIRE(waitpid(child, &status, 0) == child);
	REQUIRE(WIFEXITED(status) && WEXITSTATUS(status) == expectedExitStatus);
}

static void TestSystemTagWriterChild(void) {
	NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_SYSTEM_TAG_PATH"];
	REQUIRE([path length]);
	NSArray *tags = @[ @"Red", @"Caf\u00e9\u6771\u4eac" ];
	NSError *error = nil;
	REQUIRE([[NSURL fileURLWithPath:path]
		setResourceValue:tags forKey:NSURLTagNamesKey error:&error]);
	REQUIRE(error == nil);
}

static NSArray *CocoaTagNamesFromRawTags(NSArray *tags) {
	if (!tags) return nil;
	NSMutableArray *names = [NSMutableArray arrayWithCapacity:[tags count]];
	for (NSString *tag in tags) {
		NSUInteger length = [tag length];
		if (length >= 2 && [tag characterAtIndex:length - 2] == '\n' &&
			[tag characterAtIndex:length - 1] >= '0' && [tag characterAtIndex:length - 1] <= '7')
			[names addObject:[tag substringToIndex:length - 2]];
		else [names addObject:tag];
	}
	return names;
}

static BOOL TagSetsEqual(NSArray *one, NSArray *two) {
	return [one count] == [two count] &&
		[[NSSet setWithArray:one] isEqualToSet:[NSSet setWithArray:two]];
}

static void TestSystemTagProducer(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"System Tags.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"system tag producer", path);
		SpawnScenarioWithEnvironment(@"system-tag-writer-child", "NV_SYSTEM_TAG_PATH", path, 0);
		NSError *error = nil;
		ssize_t rawTagLength = getxattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", NULL, 0, 0, 0);
		int rawTagError = rawTagLength < 0 ? errno : 0;
		id systemTags = nil;
		BOOL tagsAvailable = [[NSURL fileURLWithPath:path]
			getResourceValue:&systemTags forKey:NSURLTagNamesKey error:&error];
		NVNoteFileSnapshot snapshot;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&error]);
		NSLog(@"system tag producer after child exit: NSURL=%@ snapshot=%@ raw-xattr=%ld errno=%d",
			tagsAvailable ? systemTags : @"unavailable", snapshot.tags, (long)rawTagLength, rawTagError);
		NSArray *expectedNames = @[ @"Red", @"Caf\u00e9\u6771\u4eac" ];
		NSArray *snapshotNames = CocoaTagNamesFromRawTags(snapshot.tags);
		REQUIRE(tagsAvailable && TagSetsEqual(CocoaTagNamesFromRawTags(systemTags), expectedNames));
		REQUIRE(TagSetsEqual(snapshotNames, expectedNames));
		REQUIRE(rawTagLength >= 0 || rawTagError == ENOATTR);
		if (rawTagLength >= 0) {
			NSArray *rawTags = [[NSFileManager defaultManager]
				getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]];
			REQUIRE(TagSetsEqual(CocoaTagNamesFromRawTags(rawTags), expectedNames));
			REQUIRE(removexattr([path fileSystemRepresentation],
				"com.apple.metadata:kMDItemOMUserTags", 0) == 0);
		}
		[controller replaceSnapshotCocoaTags:expectedNames afterReadingTags:expectedNames
			forNoteNamed:filename atIdentityChecks:0];
		error = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&error]);
		REQUIRE(error == nil && TagSetsEqual(snapshot.tags, expectedNames));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		REQUIRE(TagSetsEqual([note orderedLabelTitles], expectedNames));
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"system tag producer rewritten"] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		NSArray *openMetaTags = [[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]];
		systemTags = nil;
		REQUIRE([[NSURL fileURLWithPath:path] getResourceValue:&systemTags
			forKey:NSURLTagNamesKey error:&error]);
		NSArray *writtenTags = [note orderedLabelTitles];
		REQUIRE([openMetaTags isEqual:writtenTags]);
		REQUIRE(TagSetsEqual(CocoaTagNamesFromRawTags(systemTags),
			CocoaTagNamesFromRawTags(writtenTags)));
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestWALCrashChild(void) {
	NSString *directoryPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_CRASH_DIRECTORY"];
	REQUIRE([directoryPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateController(directoryPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"WAL baseline"] autorelease]
		title:@"WAL Crash Recovery" delegate:controller format:SingleDatabaseFormat labels:@""];
	[controller addNewNote:note];
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"WAL crash-only edit"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(73);
}

static void TestWALCrashRecovery(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		SpawnScenarioWithEnvironment(@"wal-crash-child", "NV_WAL_CRASH_DIRECTORY",
			directoryPath, 73);

		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"WAL crash-only edit") != nil);
		NSLog(@"WAL crash recovery: recovered synchronized journal edit after _exit");
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestWALHistoryCrashChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_HISTORY_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *updated = AddTestNote(controller, @"WAL Updated", @"updated baseline");
	NoteObject *deleted = AddTestNote(controller, @"WAL Deleted", @"deleted baseline");
	AddTestNote(controller, @"WAL Unchanged", @"unchanged baseline");
	REQUIRE([controller flushAllNoteChanges]);

	[updated setContentString:[[[NSAttributedString alloc]
		initWithString:@"updated intermediate"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	[updated setContentString:[[[NSAttributedString alloc]
		initWithString:@"updated final"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	[deleted setContentString:[[[NSAttributedString alloc]
		initWithString:@"deleted pending edit"] autorelease]];
	[controller removeNote:deleted];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(81);
}

static void TestWALHistoryRecovery(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		SpawnScenarioWithEnvironment(@"wal-history-child", "NV_WAL_HISTORY_ROOT",
			rootPath, 81);
		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"updated final") != nil);
		REQUIRE(NoteContaining(controller, @"updated intermediate") == nil);
		REQUIRE(NoteContaining(controller, @"deleted pending edit") == nil);
		REQUIRE(NoteContaining(controller, @"unchanged baseline") != nil);
		CloseController(&controller);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"updated final") != nil);
		REQUIRE(NoteContaining(controller, @"deleted pending edit") == nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestWALDamagedTailChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_DAMAGED_TAIL_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *prefix = AddTestNote(controller, @"WAL Prefix", @"prefix baseline");
	NoteObject *tail = AddTestNote(controller, @"WAL Tail", @"tail baseline");
	REQUIRE([controller flushAllNoteChanges]);

	[prefix setContentString:[[[NSAttributedString alloc]
		initWithString:@"complete prefix record"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	NSDictionary *attributes = [[NSFileManager defaultManager]
		attributesOfItemAtPath:WALJournalPath(rootPath) error:NULL];
	unsigned long long prefixLength = [attributes fileSize];
	REQUIRE(prefixLength > 0);
	NSString *prefixLengthString = [NSString stringWithFormat:@"%llu", prefixLength];
	REQUIRE([prefixLengthString
		writeToFile:[rootPath stringByAppendingPathComponent:@"ValidPrefixLength"]
		atomically:YES encoding:NSUTF8StringEncoding error:NULL]);

	[tail setContentString:[[[NSAttributedString alloc]
		initWithString:@"truncated tail record"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	attributes = [[NSFileManager defaultManager]
		attributesOfItemAtPath:WALJournalPath(rootPath) error:NULL];
	REQUIRE([attributes fileSize] > prefixLength);
	_exit(82);
}

static void TestWALDamagedTailRecovery(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		SpawnScenarioWithEnvironment(@"wal-damaged-tail-child",
			"NV_WAL_DAMAGED_TAIL_ROOT", rootPath, 82);
		unsigned long long prefixLength = [[NSString stringWithContentsOfFile:
			[rootPath stringByAppendingPathComponent:@"ValidPrefixLength"]
			encoding:NSUTF8StringEncoding error:NULL] longLongValue];
		int journalFD = open([WALJournalPath(rootPath) fileSystemRepresentation], O_RDWR | O_CLOEXEC);
		struct stat journalInfo;
		REQUIRE(journalFD >= 0 && fstat(journalFD, &journalInfo) == 0);
		REQUIRE((unsigned long long)journalInfo.st_size > prefixLength + 1);
		off_t truncatedLength = (off_t)(prefixLength +
			((unsigned long long)journalInfo.st_size - prefixLength) / 2);
		REQUIRE(truncatedLength > (off_t)prefixLength);
		REQUIRE(ftruncate(journalFD, truncatedLength) == 0 && fsync(journalFD) == 0);
		REQUIRE(close(journalFD) == 0);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"complete prefix record") != nil);
		REQUIRE(NoteContaining(controller, @"prefix baseline") == nil);
		REQUIRE(NoteContaining(controller, @"tail baseline") != nil);
		REQUIRE(NoteContaining(controller, @"truncated tail record") == nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestWALRecoveryRetryInitialChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_RECOVERY_RETRY_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *note = AddTestNote(controller, @"WAL Recovery Retry", @"retry baseline");
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"recovery retry final"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(83);
}

static void TestWALRecoveryRetryFailureChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_RECOVERY_RETRY_ROOT"];
	REQUIRE([rootPath length]);
	injectedControllerFlushFailures = 1;
	observedInjectedControllerFlushFailures = 0;
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	REQUIRE(observedInjectedControllerFlushFailures == 1);
	REQUIRE([controller totalNoteCount] == 1);
	REQUIRE(NoteContaining(controller, @"recovery retry final") != nil);
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(84);
}

static void TestWALRecoveryRetryIdempotence(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		SpawnScenarioWithEnvironment(@"wal-recovery-retry-initial-child",
			"NV_WAL_RECOVERY_RETRY_ROOT", rootPath, 83);
		SpawnScenarioWithEnvironment(@"wal-recovery-retry-failure-child",
			"NV_WAL_RECOVERY_RETRY_ROOT", rootPath, 84);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"recovery retry final") != nil);
		CloseController(&controller);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"recovery retry final") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestWALDatabaseOrderingStaleChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_DATABASE_ORDERING_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *ordered = AddTestNote(controller, @"WAL Database Ordering", @"ordering baseline");
	AddTestNote(controller, @"WAL Database Deletion", @"ordering deletion baseline");
	REQUIRE([controller flushAllNoteChanges]);

	[ordered setContentString:[[[NSAttributedString alloc]
		initWithString:@"stale WAL state"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	NSData *staleWAL = [NSData dataWithContentsOfFile:WALJournalPath(rootPath)];
	REQUIRE([staleWAL length] > 0);
	REQUIRE([staleWAL writeToFile:[rootPath stringByAppendingPathComponent:@"StaleWAL"]
		options:NSDataWritingAtomic error:NULL]);

	[ordered setContentString:[[[NSAttributedString alloc]
		initWithString:@"newer database state"] autorelease]];
	REQUIRE([controller flushAllNoteChanges]);
	_exit(85);
}

static void TestWALDatabaseOrderingNewerChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_DATABASE_ORDERING_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	NoteObject *ordered = NoteContaining(controller, @"newer database state");
	NoteObject *deleted = NoteContaining(controller, @"ordering deletion baseline");
	REQUIRE(ordered != nil && deleted != nil);
	[ordered setContentString:[[[NSAttributedString alloc]
		initWithString:@"newer WAL state"] autorelease]];
	[controller removeNote:deleted];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(86);
}

static void TestWALDatabaseOrdering(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		SpawnScenarioWithEnvironment(@"wal-database-ordering-stale-child",
			"NV_WAL_DATABASE_ORDERING_ROOT", rootPath, 85);
		NSData *staleWAL = [NSData dataWithContentsOfFile:
			[rootPath stringByAppendingPathComponent:@"StaleWAL"]];
		int journalFD = open([WALJournalPath(rootPath) fileSystemRepresentation],
			O_WRONLY | O_TRUNC | O_CLOEXEC);
		REQUIRE(journalFD >= 0 && [staleWAL length] > 0);
		REQUIRE(WriteAll(journalFD, [staleWAL bytes], [staleWAL length]));
		REQUIRE(fsync(journalFD) == 0 && close(journalFD) == 0);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"newer database state") != nil);
		REQUIRE(NoteContaining(controller, @"stale WAL state") == nil);
		CloseController(&controller);

		SpawnScenarioWithEnvironment(@"wal-database-ordering-newer-child",
			"NV_WAL_DATABASE_ORDERING_ROOT", rootPath, 86);
		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"newer WAL state") != nil);
		REQUIRE(NoteContaining(controller, @"newer database state") == nil);
		REQUIRE(NoteContaining(controller, @"ordering deletion baseline") == nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

typedef NS_ENUM(NSUInteger, NVWALDurabilityBoundary) {
	NVWALBeforeJournalSynchronization,
	NVWALAfterJournalSynchronization,
	NVWALAfterDatabasePersistence
};

static NSString *WALDurabilityContent(NVWALDurabilityBoundary boundary) {
	switch (boundary) {
		case NVWALBeforeJournalSynchronization: return @"pending memory only";
		case NVWALAfterJournalSynchronization: return @"journal synchronized";
		case NVWALAfterDatabasePersistence: return @"database persisted";
	}
	return nil;
}

static void TestWALDurabilityChild(NVWALDurabilityBoundary boundary) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_WAL_DURABILITY_ROOT"];
	REQUIRE([rootPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *note = AddTestNote(controller, @"WAL Durability", @"durability baseline");
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:WALDurabilityContent(boundary)] autorelease]];
	if (boundary >= NVWALAfterJournalSynchronization) {
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller synchronizeJournalOnly]);
	}
	if (boundary >= NVWALAfterDatabasePersistence)
		REQUIRE([controller flushAllNoteChanges]);
	_exit((int)(87 + boundary));
}

static void AssertWALDurabilityBoundary(NSString *scenario,
	NVWALDurabilityBoundary boundary, NSString *expectedContent) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		SpawnScenarioWithEnvironment(scenario, "NV_WAL_DURABILITY_ROOT", rootPath,
			(int)(87 + boundary));
		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, expectedContent) != nil);
		if (![expectedContent isEqualToString:WALDurabilityContent(boundary)])
			REQUIRE(NoteContaining(controller, WALDurabilityContent(boundary)) == nil);
		CloseController(&controller);

		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, expectedContent) != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestWALDurabilityBoundaries(void) {
	AssertWALDurabilityBoundary(@"wal-before-journal-sync-child",
		NVWALBeforeJournalSynchronization, @"durability baseline");
	AssertWALDurabilityBoundary(@"wal-after-journal-sync-child",
		NVWALAfterJournalSynchronization, @"journal synchronized");
	AssertWALDurabilityBoundary(@"wal-after-database-persistence-child",
		NVWALAfterDatabasePersistence, @"database persisted");
}

static void TestUnsupportedJournalLockCrashChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_UNSUPPORTED_JOURNAL_LOCK_ROOT"];
	REQUIRE([rootPath length]);
	injectedJournalFlockError = [[NSString stringWithContentsOfFile:
		[rootPath stringByAppendingPathComponent:@"LockError"]
		encoding:NSUTF8StringEncoding error:NULL] intValue];
	InstallJournalFlockInjection();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
	NoteObject *note = AddTestNote(controller, @"Unsupported Journal Lock", @"lock baseline");
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"lock recovery final"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(90);
}

static void AssertUnsupportedJournalLockError(int lockError) {
	NSString *rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		PrepareWALBookmarkFixture(rootPath);
		NSString *errorString = [NSString stringWithFormat:@"%d", lockError];
		REQUIRE([errorString writeToFile:[rootPath stringByAppendingPathComponent:@"LockError"]
			atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
		SpawnScenarioWithEnvironment(@"unsupported-journal-lock-child",
			"NV_UNSUPPORTED_JOURNAL_LOCK_ROOT", rootPath, 90);
		injectedJournalFlockError = lockError;
		InstallJournalFlockInjection();
		controller = CreateControllerResolvingWALBookmark(rootPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"lock recovery final") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestUnsupportedJournalLocks(void) {
	AssertUnsupportedJournalLockError(ENOTSUP);
	AssertUnsupportedJournalLockError(EINVAL);

	NSString *rootPath = CreateTemporaryDirectory();
	@try {
		PrepareWALBookmarkFixture(rootPath);
		injectedJournalFlockError = EWOULDBLOCK;
		InstallJournalFlockInjection();
		OSStatus status = noErr;
		NVTestNotationController *controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:ResolveWALBookmark(rootPath) error:&status];
		REQUIRE(controller == nil && status != noErr);
	} @finally {
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestFileOutboxCrashChild(void) {
	NSString *directoryPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_FILE_OUTBOX_CRASH_DIRECTORY"];
	REQUIRE([directoryPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateController(directoryPath, delegate);
	[controller stopFileNotifications];
	[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"file outbox baseline"] autorelease]
		title:@"File Outbox Crash" delegate:controller format:PlainTextFormat labels:@""];
	[controller addNewNote:note];
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"file outbox WAL edit"] autorelease]];
	REQUIRE(chmod([directoryPath fileSystemRepresentation], 0500) == 0);
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller pendingFileWriteCount] == 1 &&
		[controller pendingJournalWriteCount] == 0 && [controller synchronizeJournalOnly]);
	REQUIRE(chmod([directoryPath fileSystemRepresentation], 0700) == 0);
	_exit(74);
}

static void TestFileOutboxCrashRecovery(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		SpawnScenarioWithEnvironment(@"file-outbox-crash-child",
			"NV_FILE_OUTBOX_CRASH_DIRECTORY", directoryPath, 74);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		NoteObject *note = NoteContaining(controller, @"file outbox WAL edit");
		REQUIRE(note != nil && [controller pendingFileWriteCount] == 0);
		NSString *disk = [NSString stringWithContentsOfFile:[[note noteFileURL] path]
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([disk isEqualToString:@"file outbox WAL edit"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestBookmarkCreate(void) {
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *directoryPath = [environment objectForKey:@"NV_BOOKMARK_DIRECTORY"];
	NSString *bookmarkPath = [environment objectForKey:@"NV_BOOKMARK_FILE"];
	REQUIRE([directoryPath length] && [bookmarkPath length]);
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
		withIntermediateDirectories:YES attributes:nil error:NULL]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"bookmark survives remount"] autorelease]
			title:@"Remounted Bookmark" delegate:controller format:SingleDatabaseFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		NSError *error = nil;
		NSData *bookmark = [[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:[controller noteDirectoryURL] error:&error];
		REQUIRE(bookmark != nil && error == nil);
		REQUIRE([bookmark writeToFile:bookmarkPath options:NSDataWritingAtomic error:&error]);
	} @finally {
		CloseController(&controller);
		[delegate release];
	}
}

static void TestBookmarkResolve(void) {
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *bookmarkPath = [environment objectForKey:@"NV_BOOKMARK_FILE"];
	REQUIRE([bookmarkPath length]);
	NSData *bookmark = [NSData dataWithContentsOfFile:bookmarkPath];
	BOOL stale = NO;
	NSError *error = nil;
	NSURL *referenceURL = [[NSFileManager defaultManager]
		fileReferenceURLFromBookmarkData:bookmark stale:&stale error:&error];
	REQUIRE(referenceURL != nil && error == nil && [referenceURL isFileReferenceURL]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateControllerWithURL(referenceURL, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		NoteObject *note = NoteContaining(controller, @"bookmark survives remount");
		REQUIRE(note != nil);
		NSString *expectedContent = [environment objectForKey:@"NV_BOOKMARK_EXPECTED_CONTENT"];
		if ([expectedContent length])
			REQUIRE([[[note contentString] string] isEqualToString:expectedContent]);
		NSLog(@"bookmark remount recovery: resolved %@%@", [referenceURL path],
			stale ? @" (stale bookmark repaired)" : @"");
	} @finally {
		CloseController(&controller);
		[delegate release];
	}
}

static void TestLiveDetachChild(void) {
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *directoryPath = [environment objectForKey:@"NV_LIVE_DETACH_DIRECTORY"];
	NSString *bookmarkPath = [environment objectForKey:@"NV_BOOKMARK_FILE"];
	NSString *readyPath = [environment objectForKey:@"NV_LIVE_DETACH_READY"];
	NSString *continuePath = [environment objectForKey:@"NV_LIVE_DETACH_CONTINUE"];
	REQUIRE([directoryPath length] && [bookmarkPath length] && [readyPath length] && [continuePath length]);
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
		withIntermediateDirectories:YES attributes:nil error:NULL]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	int heldNoteFD = -1;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"bookmark survives remount"] autorelease]
			title:@"Live Detach" delegate:controller format:PlainTextFormat labels:@"detach"];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		heldNoteFD = open([[note noteFileURL] fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
		REQUIRE(heldNoteFD >= 0);
		NSData *bookmark = [[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:[controller noteDirectoryURL] error:NULL];
		REQUIRE([bookmark writeToFile:bookmarkPath options:NSDataWritingAtomic error:NULL]);
		REQUIRE([@"ready" writeToFile:readyPath atomically:YES
			encoding:NSUTF8StringEncoding error:NULL]);
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
		while (![[NSFileManager defaultManager] fileExistsAtPath:continuePath] &&
			[deadline timeIntervalSinceNow] > 0.0) usleep(10000);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:continuePath]);

		NVNoteFileSnapshot snapshot;
		NSError *error = nil;
		BOOL snapshotSucceeded = [controller readNoteFileSnapshot:&snapshot
			forNoteNamed:filenameOfNote(note) error:&error];
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"bookmark survives remount after live detach"] autorelease]];
		BOOL flushSucceeded = [controller flushAllNoteChanges];
		BOOL scanSucceeded = [controller synchronizeNotesFromDirectory];
		REQUIRE(!snapshotSucceeded && !flushSucceeded && !scanSucceeded);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE([[[note contentString] string]
			isEqualToString:@"bookmark survives remount after live detach"]);
		NSLog(@"live detach with root/note descriptors: snapshot=%@ flush=%@ scan=%@ error=%@",
			snapshotSucceeded ? @"yes" : @"no", flushSucceeded ? @"yes" : @"no",
			scanSucceeded ? @"yes" : @"no", error);
		[note release];
	} @finally {
		if (heldNoteFD >= 0) close(heldNoteFD);
		CloseController(&controller);
		[delegate release];
	}
}

static uint64_t FillDiskImage(NSString *reservePath, NSString *fillerPath) {
	size_t blockSize = 1024 * 1024;
	uint8_t *block = malloc(blockSize);
	REQUIRE(block != NULL);
	uint32_t state = 0x4E56464CU;
	for (size_t index = 0; index < blockSize; index++) {
		state = state * 1664525U + 1013904223U;
		block[index] = (uint8_t)(state >> 24);
	}
	int reserveFD = open([reservePath fileSystemRepresentation],
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	REQUIRE(reserveFD >= 0);
	for (NSUInteger index = 0; index < 8; index++) REQUIRE(WriteAll(reserveFD, block, blockSize));
	REQUIRE(fsync(reserveFD) == 0 && close(reserveFD) == 0);

	int fillerFD = open([fillerPath fileSystemRepresentation],
		O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
	REQUIRE(fillerFD >= 0);
	(void)fcntl(fillerFD, F_NOCACHE, 1);
	uint64_t bytesWritten = 0;
	BOOL full = NO;
	while (!full) {
		ssize_t amount = write(fillerFD, block, blockSize);
		if (amount < 0) {
			if (errno == ENOSPC || errno == EDQUOT) { full = YES; break; }
			if (errno == EINTR) continue;
			REQUIRE(!"unexpected filler write failure");
		}
		REQUIRE(amount > 0);
		bytesWritten += (uint64_t)amount;
		if ((bytesWritten % (8 * blockSize)) == 0 && fsync(fillerFD) < 0) {
			REQUIRE(errno == ENOSPC || errno == EDQUOT);
			full = YES;
		}
	}
	(void)close(fillerFD);
	free(block);
	REQUIRE(full);
	return bytesWritten;
}

static NSString *LargeUncompressibleNoteBody(void) {
	NSMutableData *data = [NSMutableData dataWithLength:4 * 1024 * 1024];
	uint8_t *bytes = [data mutableBytes];
	uint32_t state = 0x4E56454EU;
	for (NSUInteger index = 0; index < [data length]; index++) {
		state = state * 1103515245U + 12345U;
		bytes[index] = (uint8_t)(32 + ((state >> 16) % 95));
	}
	const char prefix[] = "Disk Full Recovery\n";
	memcpy(bytes, prefix, sizeof(prefix) - 1);
	return [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
}

static BOOL TestingExpectedHFSVolume(void) {
	return [[[[NSProcessInfo processInfo] environment] objectForKey:@"NV_EXPECT_FSTYPE"]
		isEqualToString:@"hfs"];
}

static void WaitForNextMetadataTickIfNeeded(void) {
	if (!TestingExpectedHFSVolume()) return;
	time_t initialSecond = time(NULL);
	struct timespec pause = { 0, 5000000 };
	while (time(NULL) == initialSecond) nanosleep(&pause, NULL);
}

static void TestDiskFullRecoveryContract(void) {
	REQUIRE([[[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_TEST_REQUIRE_DISK_IMAGE"] boolValue]);
	NSString *directoryPath = CreateTemporaryDirectory();
	NSString *reservePath = [directoryPath stringByAppendingPathComponent:@".NV-space-reserve"];
	NSString *fillerPath = [directoryPath stringByAppendingPathComponent:@".NV-space-filler"];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Disk Full Recovery\nbaseline"] autorelease]
			title:@"Disk Full Recovery" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		uint64_t fillerBytes = FillDiskImage(reservePath, fillerPath);
		REQUIRE(fillerBytes > 16 * 1024 * 1024);
		NSString *desired = LargeUncompressibleNoteBody();
		[note setContentString:[[[NSAttributedString alloc] initWithString:desired] autorelease]];
		BOOL firstFlush = [controller flushAllNoteChanges];
		REQUIRE(!firstFlush && [controller recordedWriteError] != noErr);
		REQUIRE(unlink([fillerPath fileSystemRepresentation]) == 0);
		REQUIRE(unlink([reservePath fileSystemRepresentation]) == 0);
		REQUIRE(fsync([controller testNoteDirectoryFileDescriptor]) == 0);
		BOOL recoveryFlush = [controller flushAllNoteChanges];
		NSString *diskContent = [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:NULL];
		NSLog(@"disk-full recovery: filler=%llu first-flush=%@ recovery-flush=%@ disk-current=%@",
			(unsigned long long)fillerBytes, firstFlush ? @"yes" : @"no",
			recoveryFlush ? @"yes" : @"no", [diskContent isEqualToString:desired] ? @"yes" : @"no");
		REQUIRE(recoveryFlush && [diskContent isEqualToString:desired]);
	} @finally {
		(void)unlink([fillerPath fileSystemRepresentation]);
		(void)unlink([reservePath fileSystemRepresentation]);
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFileMetadata(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSError *error = nil;
		NSData *newEmptyData = [controller dataFromNoteNamed:@"Read Or Create Database"
			creatingIfMissing:YES error:&error];
		REQUIRE(newEmptyData != nil && [newEmptyData length] == 0 && error == nil);
		NSString *readOrCreatePath = [directoryPath
			stringByAppendingPathComponent:@"Read Or Create Database"];
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:readOrCreatePath]);
		NSData *existingData = [@"existing" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([existingData writeToFile:readOrCreatePath atomically:NO]);
		error = nil;
		REQUIRE([[controller dataFromNoteNamed:@"Read Or Create Database"
			creatingIfMissing:YES error:&error] isEqualToData:existingData]);
		REQUIRE(error == nil);
		NSArray *collidingNames = @[ @"Case.txt", @"case.TXT" ];
		NSArray *distinctNames = @[ @"One.txt", @"Two.txt" ];
		REQUIRE([controller hasCaseCollisionForNames:collidingNames]);
		REQUIRE(![controller hasCaseCollisionForNames:distinctNames]);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"metadata baseline"] autorelease]
			title:@"Metadata Identity" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		NVNoteFileSnapshot snapshot;
		NSError *snapshotError = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError == nil);
		REQUIRE([[[[NSString alloc] initWithData:snapshot.data encoding:NSUTF8StringEncoding]
			autorelease] isEqualToString:@"metadata baseline"]);
		REQUIRE(snapshot.encoding == NSUTF8StringEncoding);
		REQUIRE([snapshot.tags count] == 0);
		REQUIRE(snapshot.info.fileID == sessionFileIDOfNote(note));

		const char *tagsAttribute = "com.apple.metadata:kMDItemOMUserTags";
		REQUIRE(removexattr([path fileSystemRepresentation], tagsAttribute, 0) == 0);
		snapshotError = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshot.tags == nil);
		snapshotError = nil;
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));
		REQUIRE(snapshotError == nil);
		snapshotError = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError == nil && snapshot.tags != nil && [snapshot.tags count] == 0);
		id cocoaTags = nil;
		REQUIRE([[controller fileReferenceURLForNoteNamed:filename error:&snapshotError]
			getResourceValue:&cocoaTags forKey:NSURLTagNamesKey error:&snapshotError]);
		REQUIRE(snapshotError == nil && [cocoaTags count] == 0);
		NSArray *mirroredTags = @[ @"Red\n6", @"Plain" ];
		REQUIRE(SetTestOpenMetaTags(controller, mirroredTags, filename, &snapshotError));
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE([snapshot.tags isEqual:mirroredTags]);
		REQUIRE([[[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]] isEqual:mirroredTags]);
		cocoaTags = nil;
		REQUIRE([[controller fileReferenceURLForNoteNamed:filename error:&snapshotError]
			getResourceValue:&cocoaTags forKey:NSURLTagNamesKey error:&snapshotError]);
		REQUIRE(TagSetsEqual(cocoaTags, CocoaTagNamesFromRawTags(mirroredTags)));
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));

		NSData *badTags = [@"not a property list" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE(setxattr([path fileSystemRepresentation], tagsAttribute,
			[badTags bytes], [badTags length], 0, 0) == 0);
		NVNoteFileSnapshot failedSnapshot = { [NSData data], @[], NSUTF8StringEncoding, { { 0 }, { 0 }, { 0 }, 0, 42, 0 } };
		snapshotError = nil;
		REQUIRE(![controller readNoteFileSnapshot:&failedSnapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError != nil && failedSnapshot.data == nil && failedSnapshot.tags == nil &&
			failedSnapshot.encoding == 0 && failedSnapshot.info.fileID == 0);

		NSData *wrongTypeTags = [NSPropertyListSerialization dataWithPropertyList:@[ @1 ]
			format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		REQUIRE(setxattr([path fileSystemRepresentation], tagsAttribute,
			[wrongTypeTags bytes], [wrongTypeTags length], 0, 0) == 0);
		snapshotError = nil;
		REQUIRE(![controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError != nil);
		snapshotError = nil;
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));
		REQUIRE(snapshotError == nil);

		NVFileInfo encodingInfo = { 0 }, resultingEncodingInfo = { 0 };
		REQUIRE([controller getFileInfo:&encodingInfo forNoteNamed:filename error:&snapshotError]);
		REQUIRE(encodingInfo.generationCount != 0);
		NVFileInfo wrongGenerationInfo = encodingInfo;
		wrongGenerationInfo.generationCount++;
		snapshotError = nil;
		REQUIRE(![controller setTextEncoding:NSUTF8StringEncoding forNoteNamed:filename
			matchingFileInfo:&wrongGenerationInfo expectedData:nil
			resultingFileInfo:&resultingEncodingInfo
			error:&snapshotError]);
		REQUIRE(snapshotError != nil);
		encodingInfo.generationCount = 0;
		snapshotError = nil;
		REQUIRE([controller setTextEncoding:NSUTF8StringEncoding forNoteNamed:filename
			matchingFileInfo:&encodingInfo expectedData:nil resultingFileInfo:&resultingEncodingInfo
			error:&snapshotError]);
		REQUIRE(snapshotError == nil && resultingEncodingInfo.generationCount != 0);
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		NSMutableData *concurrentEncodingData = [[snapshot.data mutableCopy] autorelease];
		((uint8_t*)[concurrentEncodingData mutableBytes])[0] ^= 1;
		[controller mutateNoteNamed:filename withData:concurrentEncodingData
			duringEncodingSynchronization:YES];
		snapshotError = nil;
		REQUIRE(![controller setTextEncoding:NSISOLatin1StringEncoding forNoteNamed:filename
			matchingFileInfo:&snapshot.info expectedData:snapshot.data
			resultingFileInfo:&resultingEncodingInfo error:&snapshotError]);
		REQUIRE(snapshotError != nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:concurrentEncodingData]);
		WriteExternalFileInPlace(@"metadata baseline", path);
		REQUIRE(SetTestTextEncoding(controller, NSUTF8StringEncoding, filename, &snapshotError));

		const char *encodingAttribute = "com.apple.TextEncoding";
		const char *badEncoding = "not-an-encoding";
		REQUIRE(setxattr([path fileSystemRepresentation], encodingAttribute,
			badEncoding, strlen(badEncoding), 0, 0) == 0);
		snapshotError = nil;
		REQUIRE(![controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError != nil);
		snapshotError = nil;
		REQUIRE(SetTestTextEncoding(controller, NSUTF8StringEncoding, filename, &snapshotError));
		REQUIRE(snapshotError == nil);

		NSString *contentBeforeFailedReinterpret = [[[note contentString] string] copy];
		NSStringEncoding encodingBeforeFailedReinterpret = fileEncodingOfNote(note);
		ssize_t encodingLength = getxattr([path fileSystemRepresentation], encodingAttribute,
			NULL, 0, 0, 0);
		REQUIRE(encodingLength > 0);
		NSMutableData *encodingBeforeFailure = [NSMutableData dataWithLength:(NSUInteger)encodingLength];
		REQUIRE(getxattr([path fileSystemRepresentation], encodingAttribute,
			[encodingBeforeFailure mutableBytes], (size_t)encodingLength, 0, 0) == encodingLength);
		REQUIRE(chmod([path fileSystemRepresentation], 0400) == 0);
		[controller resetPushScheduleCount];
		REQUIRE(![note setFileEncodingAndReinterpret:NSISOLatin1StringEncoding]);
		REQUIRE(fileEncodingOfNote(note) == encodingBeforeFailedReinterpret);
		REQUIRE([[[note contentString] string] isEqualToString:contentBeforeFailedReinterpret]);
		REQUIRE([controller pushScheduleCount] == 0);
		NSMutableData *encodingAfterFailure = [NSMutableData dataWithLength:(NSUInteger)encodingLength];
		REQUIRE(getxattr([path fileSystemRepresentation], encodingAttribute,
			[encodingAfterFailure mutableBytes], (size_t)encodingLength, 0, 0) == encodingLength);
		REQUIRE([encodingAfterFailure isEqualToData:encodingBeforeFailure]);
		REQUIRE(chmod([path fileSystemRepresentation], 0600) == 0);
		[contentBeforeFailedReinterpret release];

		[controller setTransientSnapshotFailures:1];
		snapshotError = nil;
		REQUIRE([controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE(snapshotError == nil && [controller snapshotAttemptCount] == 2);
		[controller setTransientSnapshotFailures:2];
		snapshotError = nil;
		REQUIRE(![controller readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&snapshotError]);
		REQUIRE([[snapshotError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[snapshotError code] == EAGAIN && [controller snapshotAttemptCount] == 2);

		NSString *symlinkName = @"Metadata Symlink.txt";
		NSString *symlinkPath = [directoryPath stringByAppendingPathComponent:symlinkName];
		REQUIRE(symlink([filename fileSystemRepresentation], [symlinkPath fileSystemRepresentation]) == 0);
		snapshotError = nil;
		REQUIRE(![controller readNoteFileSnapshot:&snapshot forNoteNamed:symlinkName error:&snapshotError]);
		REQUIRE(snapshotError != nil);
		NVFileInfo symlinkInfo;
		REQUIRE(![controller getFileInfo:&symlinkInfo forNoteNamed:symlinkName error:NULL]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:symlinkPath error:NULL]);

		uint32_t bulkDocumentID = [controller catalogDocumentIdentifierForFilename:filename];
		uint32_t foundationDocumentID = FoundationDocumentIdentifier(path);
		REQUIRE(bulkDocumentID != UINT32_MAX && bulkDocumentID == foundationDocumentID);

		NSString *renamedFilename = @"Metadata Identity Renamed.txt";
		NSString *renamedPath = [directoryPath stringByAppendingPathComponent:renamedFilename];
		REQUIRE(rename([path fileSystemRepresentation], [renamedPath fileSystemRepresentation]) == 0);
		uint32_t movedBulkID = [controller catalogDocumentIdentifierForFilename:renamedFilename];
		uint32_t movedFoundationID = FoundationDocumentIdentifier(renamedPath);
		REQUIRE(movedBulkID == movedFoundationID);
		if (bulkDocumentID) REQUIRE(movedBulkID == bulkDocumentID);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(note) isEqualToString:renamedFilename]);

		struct stat beforeEdit;
		REQUIRE(stat([renamedPath fileSystemRepresentation], &beforeEdit) == 0);
		NSData *replacement = [@"metadata changed with mtime preserved" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([replacement writeToFile:renamedPath options:NSDataWritingAtomic error:NULL]);
		uint32_t safeSaveBulkID = [controller catalogDocumentIdentifierForFilename:renamedFilename];
		uint32_t safeSaveFoundationID = FoundationDocumentIdentifier(renamedPath);
		REQUIRE(safeSaveBulkID == safeSaveFoundationID);
		if (movedBulkID) REQUIRE(safeSaveBulkID == movedBulkID);
		struct timespec preservedTimes[2] = { beforeEdit.st_atimespec, beforeEdit.st_mtimespec };
		REQUIRE(utimensat(AT_FDCWD, [renamedPath fileSystemRepresentation], preservedTimes, 0) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"metadata changed with mtime preserved"]);

		struct timespec previousChangeTime = fileAttributeChangeTimeOfNote(note);
		const char marker = 'x';
		WaitForNextMetadataTickIfNeeded();
		REQUIRE(setxattr([renamedPath fileSystemRepresentation], "com.notationalvelocity.ctime-test",
			&marker, sizeof(marker), 0, 0) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		struct timespec currentChangeTime = fileAttributeChangeTimeOfNote(note);
		REQUIRE(previousChangeTime.tv_sec != currentChangeTime.tv_sec ||
			previousChangeTime.tv_nsec != currentChangeTime.tv_nsec);

		[note setContentString:[[[NSAttributedString alloc] initWithString:@"unsaved rename wins"] autorelease]];
		NSString *unsavedFilename = @"Unsaved Metadata Rename.txt";
		NSString *unsavedPath = [directoryPath stringByAppendingPathComponent:unsavedFilename];
		REQUIRE(rename([renamedPath fileSystemRepresentation], [unsavedPath fileSystemRepresentation]) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(note) isEqualToString:unsavedFilename]);
		REQUIRE([[[note contentString] string] isEqualToString:@"unsaved rename wins"]);

		NSString *volumeUUID = [[[[controller notationPrefs] fileMetadataVolumeUUID] copy] autorelease];
		REQUIRE([volumeUUID length] > 0);
		NoteCatalogEntry oldDocumentEntry = { fileAttributeChangeTimeOfNote(note), 0,
			(CFStringRef)unsavedFilename, 0x12345678 };
		[note updateFileIdentityFromCatalogEntry:&oldDocumentEntry];
		NoteCatalogEntry newDocumentEntry = { oldDocumentEntry.attributeChangeTime, 0,
			CFSTR("Synthetic Document Rename.txt"), oldDocumentEntry.documentID };
		NSMutableArray *added = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:&newDocumentEntry]];
		NSMutableArray *removed = [NSMutableArray arrayWithObject:note];
		[controller processNotesAddedByIdentity:added removed:removed];
		REQUIRE(![added count] && ![removed count]);
		REQUIRE([filenameOfNote(note) isEqualToString:(NSString*)newDocumentEntry.filename]);
		REQUIRE(![controller contentFallbackCalled]);

		NoteCatalogEntry duplicateDocumentEntry = newDocumentEntry;
		duplicateDocumentEntry.filename = CFSTR("Ambiguous Document Rename.txt");
		added = [NSMutableArray arrayWithObjects:[NSValue valueWithPointer:&newDocumentEntry],
			[NSValue valueWithPointer:&duplicateDocumentEntry], nil];
		removed = [NSMutableArray arrayWithObject:note];
		[controller setInterceptContentFallback:YES];
		[controller processNotesAddedByIdentity:added removed:removed];
		REQUIRE([controller contentFallbackCalled]);
		REQUIRE([added count] == 2 && [removed count] == 1);
		REQUIRE([filenameOfNote(note) isEqualToString:(NSString*)newDocumentEntry.filename]);
		[controller setInterceptContentFallback:NO];

		[note setFilename:unsavedFilename withExternalTrigger:YES];
		oldDocumentEntry.filename = (CFStringRef)unsavedFilename;
		oldDocumentEntry.documentID = 0x87654321;
		[note updateFileIdentityFromCatalogEntry:&oldDocumentEntry];
		newDocumentEntry.documentID = oldDocumentEntry.documentID;
		added = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:&newDocumentEntry]];
		removed = [NSMutableArray arrayWithObject:note];
		[[controller notationPrefs] setFileMetadataVolumeUUID:@"00000000-0000-0000-0000-000000000000"];
		[controller setInterceptContentFallback:YES];
		[controller processNotesAddedByIdentity:added removed:removed];
		REQUIRE([controller contentFallbackCalled]);
		REQUIRE([added count] == 1 && [removed count] == 1);
		[controller setInterceptContentFallback:NO];
		[[controller notationPrefs] setFileMetadataVolumeUUID:volumeUUID];

		NoteCatalogEntry oldSessionEntry = { fileAttributeChangeTimeOfNote(note),
			0x0102030405060708ULL, (CFStringRef)unsavedFilename, 0, 17 };
		[note updateFileIdentityFromCatalogEntry:&oldSessionEntry];
		NoteCatalogEntry newSessionEntry = { oldSessionEntry.attributeChangeTime,
			oldSessionEntry.fileID, CFSTR("Reused Session ID.txt"), 0, 18 };
		added = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:&newSessionEntry]];
		removed = [NSMutableArray arrayWithObject:note];
		[controller setInterceptContentFallback:YES];
		[controller processNotesAddedByIdentity:added removed:removed];
		REQUIRE(![added count] && ![removed count]);
		REQUIRE(![controller contentFallbackCalled]);
		REQUIRE(sessionFileGenerationOfNote(note) == 18);
		[controller setInterceptContentFallback:NO];
		[note setFilename:unsavedFilename withExternalTrigger:YES];

		REQUIRE([controller flushAllNoteChanges]);
		NoteCatalogEntry zeroIdentity = { fileAttributeChangeTimeOfNote(note), 0,
			(CFStringRef)unsavedFilename, 0 };
		[note updateFileIdentityFromCatalogEntry:&zeroIdentity];
		NSString *contentFilename = @"Content Fallback Rename.txt";
		NSString *contentPath = [directoryPath stringByAppendingPathComponent:contentFilename];
		REQUIRE(rename([unsavedPath fileSystemRepresentation], [contentPath fileSystemRepresentation]) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller contentFallbackCalled]);
		REQUIRE([filenameOfNote(note) isEqualToString:contentFilename]);
		REQUIRE([[[note contentString] string] isEqualToString:@"unsaved rename wins"]);
		[note release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestCoarseCTimeObservation(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"coarse ctime"] autorelease]
			title:@"Coarse CTime" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		WaitForNextMetadataTickIfNeeded();
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		[controller resetNoteDataReadCount];
		REQUIRE(SetTestOpenMetaTags(controller, @[ @"same-second-tag" ], filename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 1);
		REQUIRE([labelsOfNote(note) rangeOfString:@"same-second-tag"].location != NSNotFound);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestDirectoryReconciliation(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NoteObject *firstFallbackNote = nil;
	NoteObject *secondFallbackNote = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		NSString *databaseModePath = [directoryPath stringByAppendingPathComponent:@"Not A Database Note.txt"];
		WriteExternalFile(PlainTextFormat, @"must not be imported in database mode", databaseModePath);
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 0);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:databaseModePath error:NULL]);

		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *importedFilename = @"Cafe\u0301 Imported.txt";
		NSString *importedPath = [directoryPath stringByAppendingPathComponent:importedFilename];
		WriteExternalFile(PlainTextFormat, @"initial external import", importedPath);
		WriteExternalFile(PlainTextFormat, @"hidden", [directoryPath stringByAppendingPathComponent:@".Hidden.txt"]);
		WriteExternalFile(PlainTextFormat, @"unsupported", [directoryPath stringByAppendingPathComponent:@"Ignored.md"]);
		NSString *vanishedFilename = @"Vanished During Fallback.txt";
		NSString *vanishedPath = [directoryPath stringByAppendingPathComponent:vanishedFilename];
		WriteExternalFile(PlainTextFormat, @"transient fallback entry", vanishedPath);
		REQUIRE([controller foundationScanRetriesThenRejectsVanishedFilename:vanishedFilename]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:vanishedPath error:NULL]);
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:
			[directoryPath stringByAppendingPathComponent:@"Directory.txt"]
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 1);
		NoteObject *importedNote = [AllNotes(controller) objectAtIndex:0];
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"initial external import"]);
		REQUIRE([[filenameOfNote(importedNote) precomposedStringWithCanonicalMapping]
			isEqualToString:[@"Caf\u00e9 Imported.txt" precomposedStringWithCanonicalMapping]]);
		NSArray *unknownFiles = nil;
		NSSet *knownNotes = [controller notesWithFilenames:@[
			[directoryPath stringByAppendingPathComponent:@"CAF\u00c9 IMPORTED.TXT"],
			[directoryPath stringByAppendingPathComponent:@"Unknown.txt"]
		] unknownFiles:&unknownFiles];
		REQUIRE([knownNotes isEqualToSet:[NSSet setWithObject:importedNote]]);
		REQUIRE([unknownFiles count] == 1 &&
			[[[unknownFiles objectAtIndex:0] lastPathComponent] isEqualToString:@"Unknown.txt"]);

		[controller resetNoteDataReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 0);
		REQUIRE([AllNotes(controller) objectAtIndex:0] == importedNote);

		struct timespec metadataBeforeFailedRefresh = fileAttributeChangeTimeOfNote(importedNote);
		[controller filterNotesFromString:@"needle"];
		REQUIRE([[controller notesListDataSource] count] == 0);
		[delegate resetContentsUpdatedCount];
		[controller resetPushScheduleCount];
		[controller resetResortCount];
		[controller setFailingSnapshotName:filenameOfNote(importedNote)];
		WaitForNextMetadataTickIfNeeded();
		WriteExternalFileInPlace(@"deferred external refresh needle", importedPath);
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"initial external import"]);
		REQUIRE(metadataBeforeFailedRefresh.tv_sec == fileAttributeChangeTimeOfNote(importedNote).tv_sec &&
			metadataBeforeFailedRefresh.tv_nsec == fileAttributeChangeTimeOfNote(importedNote).tv_nsec);
		REQUIRE([delegate contentsUpdatedCount] == 0);
		REQUIRE([controller pushScheduleCount] == 0);
		REQUIRE([[controller notesListDataSource] count] == 0);
		REQUIRE([controller resortCount] == 0);
		[controller setFailingSnapshotName:nil];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"deferred external refresh needle"]);
		REQUIRE([[controller notesListDataSource] count] == 1);
		REQUIRE([delegate contentsUpdatedCount] == 1);
		REQUIRE([controller pushScheduleCount] == 1);
		REQUIRE([controller resortCount] == 1);
		[controller filterNotesFromString:@""];
		[controller setSyntheticCatalogNames:@[ @"Case.txt", @"case.TXT" ]];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE([AllNotes(controller) objectAtIndex:0] == importedNote);
		[controller setSyntheticCatalogNames:nil];

		[controller resetNoteDataReadCount];
		REQUIRE([controller reconcileNoteUsingFoundation:importedNote]);
		REQUIRE([controller noteDataReadCount] == 0);

		NSError *error = nil;
		WaitForNextMetadataTickIfNeeded();
		REQUIRE(SetTestOpenMetaTags(controller, @[ @"external-tag" ],
			filenameOfNote(importedNote), &error));
		REQUIRE(error == nil);
		[controller resetNoteDataReadCount];
		REQUIRE([controller reconcileNoteUsingFoundation:importedNote]);
		REQUIRE([controller noteDataReadCount] == 1);
		REQUIRE([labelsOfNote(importedNote) rangeOfString:@"external-tag"].location != NSNotFound);
		[controller resetNoteDataReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 0);

		const char *tagsAttribute = "com.apple.metadata:kMDItemOMUserTags";
		REQUIRE(removexattr([importedPath fileSystemRepresentation], tagsAttribute, 0) == 0);
		WaitForNextMetadataTickIfNeeded();
		WriteExternalFileInPlace(@"tagless external refresh", importedPath);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([labelsOfNote(importedNote) rangeOfString:@"external-tag"].location != NSNotFound);
		errno = 0;
		REQUIRE(getxattr([importedPath fileSystemRepresentation], tagsAttribute, NULL, 0, 0, 0) < 0 &&
			errno == ENOATTR);
		WaitForNextMetadataTickIfNeeded();
		REQUIRE(SetTestOpenMetaTags(controller, @[], filenameOfNote(importedNote), &error));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([labelsOfNote(importedNote) length] == 0);

		[importedNote setContentString:[[[NSAttributedString alloc]
			initWithString:@"unsaved memory wins"] autorelease]];
		WriteExternalFile(PlainTextFormat, @"conflicting disk edit", importedPath);
		[controller resetNoteDataReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 0);
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"unsaved memory wins"]);
		REQUIRE([controller flushAllNoteChanges]);
		NSString *flushedText = [NSString stringWithContentsOfFile:importedPath
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([flushedText isEqualToString:@"unsaved memory wins"]);

		NSString *renamedFilename = @"Renamed And Edited.txt";
		NSString *renamedPath = [directoryPath stringByAppendingPathComponent:renamedFilename];
		REQUIRE(rename([importedPath fileSystemRepresentation], [renamedPath fileSystemRepresentation]) == 0);
		WriteExternalFileInPlace(@"equal-size-before", renamedPath);
		[controller resetNoteDataReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 1);
		REQUIRE([AllNotes(controller) objectAtIndex:0] == importedNote);
		REQUIRE([filenameOfNote(importedNote) isEqualToString:renamedFilename]);
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"equal-size-before"]);

		struct stat beforeSameSizeEdit;
		REQUIRE(stat([renamedPath fileSystemRepresentation], &beforeSameSizeEdit) == 0);
		REQUIRE([@"equal-size-before" length] == [@"equal-size-change" length]);
		WaitForNextMetadataTickIfNeeded();
		WriteExternalFileInPlace(@"equal-size-change", renamedPath);
		struct timespec preservedTimes[2] = {
			beforeSameSizeEdit.st_atimespec, beforeSameSizeEdit.st_mtimespec
		};
		REQUIRE(utimensat(AT_FDCWD, [renamedPath fileSystemRepresentation], preservedTimes, 0) == 0);
		[controller resetNoteDataReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller noteDataReadCount] == 1);
		REQUIRE([[[importedNote contentString] string] isEqualToString:@"equal-size-change"]);

		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:renamedPath error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		WriteExternalFile(PlainTextFormat, @"reappeared before deletion was committed", renamedPath);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([AllNotes(controller) containsObject:importedNote]);
		REQUIRE([[[importedNote contentString] string]
			isEqualToString:@"reappeared before deletion was committed"]);

		firstFallbackNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"same-size-A"] autorelease]
			title:@"Fallback First" delegate:controller format:PlainTextFormat labels:@""];
		secondFallbackNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"same-size-B"] autorelease]
			title:@"Fallback Second" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:firstFallbackNote];
		[controller addNewNote:secondFallbackNote];
		REQUIRE([controller flushAllNoteChanges]);
		NoteCatalogEntry zeroIdentity = { fileAttributeChangeTimeOfNote(firstFallbackNote), 0,
			(CFStringRef)filenameOfNote(firstFallbackNote), 0 };
		[firstFallbackNote updateFileIdentityFromCatalogEntry:&zeroIdentity];
		zeroIdentity.attributeChangeTime = fileAttributeChangeTimeOfNote(secondFallbackNote);
		zeroIdentity.filename = (CFStringRef)filenameOfNote(secondFallbackNote);
		[secondFallbackNote updateFileIdentityFromCatalogEntry:&zeroIdentity];
		NSString *firstPath = [[firstFallbackNote noteFileURL] path];
		NSString *secondPath = [[secondFallbackNote noteFileURL] path];
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:firstPath error:NULL]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:secondPath error:NULL]);
		NSString *firstRenamedFilename = @"Zeta Content Match.txt";
		NSString *secondRenamedFilename = @"Alpha Content Match.txt";
		WriteExternalFile(PlainTextFormat, @"same-size-A",
			[directoryPath stringByAppendingPathComponent:firstRenamedFilename]);
		WriteExternalFile(PlainTextFormat, @"same-size-B",
			[directoryPath stringByAppendingPathComponent:secondRenamedFilename]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(firstFallbackNote) isEqualToString:firstRenamedFilename]);
		REQUIRE([filenameOfNote(secondFallbackNote) isEqualToString:secondRenamedFilename]);

		NSString *actualAddition = @"Actual Addition.txt";
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:
			[directoryPath stringByAppendingPathComponent:firstRenamedFilename] error:NULL]);
		WriteExternalFile(PlainTextFormat, @"unrelated replacement with a different size",
			[directoryPath stringByAppendingPathComponent:actualAddition]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		WaitForNoteCount(controller, 3);
		REQUIRE(![AllNotes(controller) containsObject:firstFallbackNote]);
		REQUIRE(NoteContaining(controller, @"unrelated replacement") != nil);

		NSUInteger countBeforeFailure = [controller totalNoteCount];
		[controller resetNoteDataReadCount];
		REQUIRE(![controller synchronizeWithClosedDirectoryDescriptor]);
		REQUIRE([controller totalNoteCount] == countBeforeFailure);
		REQUIRE([controller noteDataReadCount] == 0);

		for (NoteObject *note in [[AllNotes(controller) copy] autorelease])
			REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[note noteFileURL] path] error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		WaitForNoteCount(controller, 0);
	} @finally {
		[firstFallbackNote release];
		[secondFallbackNote release];
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	NVFSEventsProbe *probe = [[NVFSEventsProbe alloc] init];
	FSEventStreamEventFlags ordinaryFlags[] = { 0 };
	FSEventStreamEventFlags movedFlags[] = { kFSEventStreamEventFlagRootChanged };
	FSEventStreamEventFlags droppedFlags[] = { kFSEventStreamEventFlagKernelDropped };
	FSEventStreamEventId eventIDs[] = { 0 };
	FSEventsCallback(NULL, probe, 1, NULL, ordinaryFlags, eventIDs);
	FSEventsCallback(NULL, probe, 1, NULL, ordinaryFlags, eventIDs);
	FSEventsCallback(NULL, probe, 1, NULL, droppedFlags, eventIDs);
	FSEventsCallback(NULL, probe, 1, NULL, movedFlags, eventIDs);
	REQUIRE([probe synchronizeCount] == 0);
	REQUIRE([probe configureCount] == 0);
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
	while (([probe synchronizeCount] != 1 || [probe configureCount] != 1) &&
		[deadline timeIntervalSinceNow] > 0.0)
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
	REQUIRE([probe synchronizeCount] == 1);
	REQUIRE([probe configureCount] == 1);
	[probe release];
}

static void TestSnapshotFailurePropagation(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Unreadable New Note.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"stable import", path);
		[controller setFailingSnapshotName:filename];
		[controller resetPushScheduleCount];
		[delegate resetContentsUpdatedCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 0);
		REQUIRE([controller pushScheduleCount] == 0 && [delegate contentsUpdatedCount] == 0);

		[controller setFailingSnapshotName:nil];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 1);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		REQUIRE([[[note contentString] string] isEqualToString:@"stable import"]);

		NSString *renamedFilename = @"Unreadable Renamed Note.txt";
		NSString *renamedPath = [directoryPath stringByAppendingPathComponent:renamedFilename];
		REQUIRE(rename([path fileSystemRepresentation], [renamedPath fileSystemRepresentation]) == 0);
		[controller setFailingSnapshotName:renamedFilename];
		[controller resetPushScheduleCount];
		[delegate resetContentsUpdatedCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 1 && [AllNotes(controller) objectAtIndex:0] == note);
		REQUIRE([filenameOfNote(note) isEqualToString:filename]);
		REQUIRE([controller pushScheduleCount] == 0 && [delegate contentsUpdatedCount] == 0);

		[controller setFailingSnapshotName:nil];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(note) isEqualToString:renamedFilename]);

		const char *tagsAttribute = "com.apple.metadata:kMDItemOMUserTags";
		NSData *badTags = [@"malformed tags" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE(setxattr([renamedPath fileSystemRepresentation], tagsAttribute,
			[badTags bytes], [badTags length], 0, 0) == 0);
		WriteExternalFileInPlace(@"deferred after xattr failure", renamedPath);
		struct timespec metadataBeforeXattrFailure = fileAttributeChangeTimeOfNote(note);
		[controller resetPushScheduleCount];
		[delegate resetContentsUpdatedCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"stable import"]);
		REQUIRE(metadataBeforeXattrFailure.tv_sec == fileAttributeChangeTimeOfNote(note).tv_sec &&
			metadataBeforeXattrFailure.tv_nsec == fileAttributeChangeTimeOfNote(note).tv_nsec);
		REQUIRE([controller pushScheduleCount] == 0 && [delegate contentsUpdatedCount] == 0);
		REQUIRE(SetTestOpenMetaTags(controller, @[], renamedFilename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"deferred after xattr failure"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		NSData *invalidRTF = [@"not rtf" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([invalidRTF writeToFile:[directoryPath stringByAppendingPathComponent:@"Broken.rtf"]
			options:0 error:NULL]);
		[controller resetPushScheduleCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 0 && [controller pushScheduleCount] == 0);

		NSString *brokenPath = [directoryPath stringByAppendingPathComponent:@"Broken.rtf"];
		WriteExternalFile(RTFTextFormat, @"valid rtf", brokenPath);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		struct timespec metadataBeforeDecodeFailure = fileAttributeChangeTimeOfNote(note);
		REQUIRE([invalidRTF writeToFile:brokenPath options:NSDataWritingAtomic error:NULL]);
		[controller resetPushScheduleCount];
		[delegate resetContentsUpdatedCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"valid rtf"]);
		REQUIRE(metadataBeforeDecodeFailure.tv_sec == fileAttributeChangeTimeOfNote(note).tv_sec &&
			metadataBeforeDecodeFailure.tv_nsec == fileAttributeChangeTimeOfNote(note).tv_nsec);
		REQUIRE([controller pushScheduleCount] == 0 && [delegate contentsUpdatedCount] == 0);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestAmbiguousContentFallback(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *first = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"identical content"] autorelease]
			title:@"Ambiguous First" delegate:controller format:PlainTextFormat labels:@"ghost-tag"];
		NoteObject *second = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"identical content"] autorelease]
			title:@"Ambiguous Second" delegate:controller format:PlainTextFormat labels:@"ghost-tag"];
		[controller addNewNote:first];
		[controller addNewNote:second];
		REQUIRE([controller flushAllNoteChanges]);

		NSString *firstName = [[filenameOfNote(first) copy] autorelease];
		NSString *secondName = [[filenameOfNote(second) copy] autorelease];
		NoteCatalogEntry noIdentity = { fileAttributeChangeTimeOfNote(first), 0,
			(CFStringRef)firstName, 0 };
		[first updateFileIdentityFromCatalogEntry:&noIdentity];
		noIdentity.attributeChangeTime = fileAttributeChangeTimeOfNote(second);
		noIdentity.filename = (CFStringRef)secondName;
		[second updateFileIdentityFromCatalogEntry:&noIdentity];
		REQUIRE(rename([[directoryPath stringByAppendingPathComponent:firstName] fileSystemRepresentation],
			[[directoryPath stringByAppendingPathComponent:@"Ambiguous New A.txt"] fileSystemRepresentation]) == 0);
		REQUIRE(rename([[directoryPath stringByAppendingPathComponent:secondName] fileSystemRepresentation],
			[[directoryPath stringByAppendingPathComponent:@"Ambiguous New B.txt"] fileSystemRepresentation]) == 0);

		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		[controller resetLabelAddCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller contentFallbackCalled]);
		REQUIRE([controller totalNoteCount] == 4);
		REQUIRE([filenameOfNote(first) isEqualToString:firstName]);
		REQUIRE([filenameOfNote(second) isEqualToString:secondName]);
		REQUIRE([controller labelAddCount] == 2);
		WaitForNoteCount(controller, 2);
		NSMutableSet *remainingNames = [NSMutableSet set];
		for (NoteObject *note in AllNotes(controller)) [remainingNames addObject:filenameOfNote(note)];
		NSSet *expectedNames = [NSSet setWithObjects:@"Ambiguous New A.txt", @"Ambiguous New B.txt", nil];
		REQUIRE([remainingNames isEqualToSet:expectedNames]);
		[first release];
		[second release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void RunAmbiguityCardinalityCase(NSUInteger oldCount, NSUInteger newCount,
	NSString *content, BOOL hardLinks) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		for (NSUInteger index = 0; index < oldCount; index++)
			WriteExternalFile(PlainTextFormat, content, [directoryPath stringByAppendingPathComponent:
				[NSString stringWithFormat:@"Old Ambiguous %lu.txt", (unsigned long)index]]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == oldCount);
		for (NoteObject *note in AllNotes(controller)) {
			NoteCatalogEntry noIdentity = { fileAttributeChangeTimeOfNote(note), 0,
				(CFStringRef)filenameOfNote(note), 0 };
			[note updateFileIdentityFromCatalogEntry:&noIdentity];
			REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[note noteFileURL] path] error:NULL]);
		}
		NSString *firstNewPath = nil;
		for (NSUInteger index = 0; index < newCount; index++) {
			NSString *path = [directoryPath stringByAppendingPathComponent:
				[NSString stringWithFormat:@"New Ambiguous %lu.txt", (unsigned long)index]];
			if (hardLinks && index) {
				REQUIRE(link([firstNewPath fileSystemRepresentation], [path fileSystemRepresentation]) == 0);
			} else {
				WriteExternalFile(PlainTextFormat, content, path);
				if (!firstNewPath) firstNewPath = path;
			}
		}
		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller contentFallbackCalled]);
		REQUIRE([controller totalNoteCount] == oldCount + newCount);
		WaitForNoteCount(controller, newCount);
		for (NoteObject *note in AllNotes(controller))
			REQUIRE([filenameOfNote(note) hasPrefix:@"New Ambiguous "]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestAmbiguityStress(void) {
	RunAmbiguityCardinalityCase(2, 1, @"same content", NO);
	RunAmbiguityCardinalityCase(1, 2, @"same content", NO);
	RunAmbiguityCardinalityCase(2, 2, @"", NO);
	RunAmbiguityCardinalityCase(1, 2, @"hard-linked content", YES);

	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *oldName = @"Case Only Rename.txt";
		NSString *newName = @"case only rename.txt";
		WriteExternalFile(PlainTextFormat, @"case-preserving identity",
			[directoryPath stringByAppendingPathComponent:oldName]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		REQUIRE(rename([[directoryPath stringByAppendingPathComponent:oldName] fileSystemRepresentation],
			[[directoryPath stringByAppendingPathComponent:newName] fileSystemRepresentation]) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(note) isEqualToString:newName]);

		NSString *decomposedName = @"Cafe\u0301 Unicode.txt";
		WriteExternalFile(PlainTextFormat, @"normalized name",
			[directoryPath stringByAppendingPathComponent:decomposedName]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *unicodeNote = NoteContaining(controller, @"normalized name");
		REQUIRE([[filenameOfNote(unicodeNote) precomposedStringWithCanonicalMapping]
			isEqualToString:@"Caf\u00e9 Unicode.txt"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static BOOL DirectoryScanWasAtomicWithFailureAtIndex(NSUInteger failureIndex) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	BOOL atomic = NO;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSArray *names = @[ @"A Atomic.txt", @"M Atomic.txt", @"Z Atomic.txt" ];
		NSArray *original = @[ @"original A", @"original M", @"original Z" ];
		NSArray *changed = @[ @"changed A", @"changed M", @"changed Z" ];
		for (NSUInteger index = 0; index < [names count]; index++)
			WriteExternalFile(PlainTextFormat, [original objectAtIndex:index],
				[directoryPath stringByAppendingPathComponent:[names objectAtIndex:index]]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		for (NSUInteger index = 0; index < [names count]; index++) {
			WriteExternalFileInPlace([changed objectAtIndex:index],
				[directoryPath stringByAppendingPathComponent:[names objectAtIndex:index]]);
			NSError *tagError = nil;
			REQUIRE(SetTestOpenMetaTags(controller, @[ @"changed-label" ],
				[names objectAtIndex:index], &tagError));
			REQUIRE(tagError == nil);
		}
		[[controller notationPrefs] setFileMetadataVolumeUUID:@"must-survive-failed-scan"];
		[controller setFailingSnapshotName:[names objectAtIndex:failureIndex]];
		[controller filterNotesFromString:@"changed"];
		[controller resetPushScheduleCount];
		[controller resetResortCount];
		[delegate resetContentsUpdatedCount];
		BOOL succeeded = [controller synchronizeNotesFromDirectory];
		atomic = !succeeded && [controller pushScheduleCount] == 0 &&
			[controller resortCount] == 0 && [delegate contentsUpdatedCount] == 0 &&
			[[controller notesListDataSource] count] == 0 &&
			[controller deletionCandidateCount] == 0 &&
			[[[controller notationPrefs] fileMetadataVolumeUUID]
				isEqualToString:@"must-survive-failed-scan"];
		for (NSUInteger index = 0; atomic && index < [original count]; index++) {
			NoteObject *originalNote = NoteContaining(controller, [original objectAtIndex:index]);
			atomic = originalNote != nil && [labelsOfNote(originalNote) length] == 0;
		}
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
	return atomic;
}

static BOOL DirectoryImportWasAtomicWithFailureAtIndex(NSUInteger failureIndex) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	BOOL atomic = NO;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *deletedCandidate = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"candidate remains live"] autorelease]
			title:@"Deleted Candidate" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:deletedCandidate];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[deletedCandidate noteFileURL] path]
			error:NULL]);
		[deletedCandidate release];
		NSArray *names = @[ @"A Import.txt", @"M Import.txt", @"Z Import.txt" ];
		for (NSUInteger index = 0; index < [names count]; index++)
			WriteExternalFile(PlainTextFormat,
				[NSString stringWithFormat:@"import %lu", (unsigned long)index],
				[directoryPath stringByAppendingPathComponent:[names objectAtIndex:index]]);
		[controller setFailingSnapshotName:[names objectAtIndex:failureIndex]];
		[[controller notationPrefs] setFileMetadataVolumeUUID:@"must-survive-failed-import"];
		[controller resetPushScheduleCount];
		[controller resetResortCount];
		[delegate resetContentsUpdatedCount];
		BOOL succeeded = [controller synchronizeNotesFromDirectory];
		atomic = !succeeded && [controller totalNoteCount] == 1 &&
			[controller pushScheduleCount] == 0 && [controller resortCount] == 0 &&
			[delegate contentsUpdatedCount] == 0 && [controller deletionCandidateCount] == 0 &&
			NoteContaining(controller, @"candidate remains live") != nil &&
			[[[controller notationPrefs] fileMetadataVolumeUUID]
				isEqualToString:@"must-survive-failed-import"];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
	return atomic;
}

static void TestDirectoryScanAtomicityContract(void) {
	BOOL first = DirectoryScanWasAtomicWithFailureAtIndex(0);
	BOOL middle = DirectoryScanWasAtomicWithFailureAtIndex(1);
	BOOL final = DirectoryScanWasAtomicWithFailureAtIndex(2);
	BOOL firstImport = DirectoryImportWasAtomicWithFailureAtIndex(0);
	BOOL middleImport = DirectoryImportWasAtomicWithFailureAtIndex(1);
	BOOL finalImport = DirectoryImportWasAtomicWithFailureAtIndex(2);
	NSLog(@"scan atomicity updates: first=%@ middle=%@ final=%@; imports: first=%@ middle=%@ final=%@",
		first ? @"yes" : @"no", middle ? @"yes" : @"no", final ? @"yes" : @"no",
		firstImport ? @"yes" : @"no", middleImport ? @"yes" : @"no", finalImport ? @"yes" : @"no");
	REQUIRE(first && middle && final && firstImport && middleImport && finalImport);
}

static void TestFailedScanRetryContract(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Retry Once.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"before retry", path);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		WriteExternalFileInPlace(@"after retry", path);
		[controller setTransientSnapshotFailures:2];
		[controller resetSynchronizeCount];
		FSEventStreamEventFlags flags[] = { 0 };
		FSEventStreamEventId eventIDs[] = { 2 };
		FSEventsCallback(NULL, controller, 1, NULL, flags, eventIDs);
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![[[note contentString] string] isEqualToString:@"after retry"] &&
			[deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		NSLog(@"failed-scan retry: scans=%lu snapshots=%lu content=%@",
			(unsigned long)[controller synchronizeCount], (unsigned long)[controller snapshotAttemptCount],
			[[note contentString] string]);
		REQUIRE([[[note contentString] string] isEqualToString:@"after retry"]);
		REQUIRE([controller synchronizeCount] >= 2);

		WriteExternalFileInPlace(@"retry cancelled", path);
		[controller setTransientSnapshotFailures:2];
		[controller resetSynchronizeCount];
		FSEventsCallback(NULL, controller, 1, NULL, flags, eventIDs);
		deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([controller synchronizeCount] == 0 && [deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE([controller synchronizeCount] == 1);
		[controller stopFileNotifications];
		deadline = [NSDate dateWithTimeIntervalSinceNow:0.25];
		while ([deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
		REQUIRE([controller synchronizeCount] == 1);
		REQUIRE([[[note contentString] string] isEqualToString:@"after retry"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestCatalogFenceContract(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Catalog Fence.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"before fence", path);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		WriteExternalFileInPlace(@"prepared version", path);
		[controller setMutationBeforeFenceName:filename content:@"fenced version"];
		[controller resetSynchronizeCount];
		BOOL firstResult = [controller synchronizeNotesFromDirectory];
		BOOL firstPassCommitted = [[[note contentString] string] isEqualToString:@"prepared version"];
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([controller synchronizeCount] < 2 && [deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		BOOL converged = [[[note contentString] string] isEqualToString:@"fenced version"];
		REQUIRE(!firstResult && !firstPassCommitted && [controller synchronizeCount] >= 2 && converged);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestDirectoryFenceModes(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		WriteExternalFile(PlainTextFormat, @"two passes",
			[directoryPath stringByAppendingPathComponent:@"Fence Mode.txt"]);
		[controller resetCatalogReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		/* FSEvents is only an invalidation source; every transaction uses the exact
		 * two-pass catalog fence regardless of scheduler/monitoring state. */
		REQUIRE([controller catalogReadCount] == 2);

		/* A failed root-watch rebuild is an obligation, not a reason to run forever
		 * without monitoring. The existing filesystem retry timer must restore it. */
		[controller simulateDirectoryStreamWithConfigurationFailures:1];
		[controller resetDirectoryStreamReconfigurationCount];
		[controller resetCatalogReadCount];
		[controller resetSynchronizeCount];
		FSEventStreamEventFlags rootFlags[] = { kFSEventStreamEventFlagRootChanged };
		FSEventStreamEventId rootEventIDs[] = { 0 };
		FSEventsCallback(NULL, controller, 1, NULL, rootFlags, rootEventIDs);
		REQUIRE([controller directoryStreamReconfigurationCount] == 0);
		REQUIRE([controller synchronizeCount] == 0);
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([controller directoryStreamReconfigurationCount] == 0 &&
			[deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE([controller directoryStreamReconfigurationCount] == 1);
		REQUIRE([controller directoryRetryIsScheduled]);
		REQUIRE([controller synchronizeCount] == 1);
		REQUIRE([controller catalogReadCount] == 2);
		while (([controller directoryStreamReconfigurationCount] < 2 ||
			[controller directoryRetryIsScheduled]) && [deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE([controller directoryStreamReconfigurationCount] == 2);
		REQUIRE(![controller directoryRetryIsScheduled]);
		REQUIRE([controller synchronizeCount] == 2);
		REQUIRE([controller catalogReadCount] == 4);

		[controller stopFileNotifications];
		[controller resetCatalogReadCount];
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller catalogReadCount] == 2);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestUnsavedWriteRecoveryContract(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Unsaved Recovery.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"baseline", path);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		[note setContentString:[[[NSAttributedString alloc] initWithString:@"memory wins"] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller pendingJournalWriteCount] == 1);
		WriteExternalFile(PlainTextFormat, @"external conflict", path);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"memory wins"]);
		REQUIRE(chmod([directoryPath fileSystemRepresentation], 0500) == 0);
		BOOL failedFlush = ![controller flushAllNoteChanges];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller pendingJournalWriteCount] == 0);
		REQUIRE(chmod([directoryPath fileSystemRepresentation], 0700) == 0);
		BOOL recoveryFlush = [controller flushAllNoteChanges];
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([controller pendingJournalWriteCount] == 0);
		NSString *diskContent = [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:NULL];
		NSLog(@"unsaved recovery: failed-flush=%@ recovery-flush=%@ disk=%@",
			failedFlush ? @"yes" : @"no", recoveryFlush ? @"yes" : @"no", diskContent);
		REQUIRE(failedFlush && recoveryFlush && [diskContent isEqualToString:@"memory wins"]);

		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"file sink succeeds independently"] autorelease]];
		[controller breakJournalDescriptor];
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([controller pendingJournalWriteCount] == 0);
		REQUIRE(![controller flushAllNoteChanges]);
		diskContent = [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([diskContent isEqualToString:@"file sink succeeds independently"]);
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"WAL retry remains owned"] autorelease]];
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller pendingFileWriteCount] == 0 &&
			[controller pendingJournalWriteCount] == 0 && [controller writeRetryIsScheduled]);
	} @finally {
		chmod([directoryPath fileSystemRepresentation], 0700);
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static NSTimeInterval MedianBulkScan(NVTestNotationController *controller) {
	NSMutableArray *samples = [NSMutableArray array];
	REQUIRE([controller bulkScanElapsed] >= 0.0);
	for (NSUInteger index = 0; index < 9; index++)
		[samples addObject:[NSNumber numberWithDouble:[controller bulkScanElapsed]]];
	[samples sortUsingSelector:@selector(compare:)];
	return [[samples objectAtIndex:[samples count] / 2] doubleValue];
}

static NSTimeInterval MedianUnchangedDirectoryScan(NVTestNotationController *controller) {
	NSMutableArray *samples = [NSMutableArray array];
	REQUIRE([controller synchronizeNotesFromDirectory]);
	for (NSUInteger index = 0; index < 5; index++) {
		struct timespec start, end;
		clock_gettime(CLOCK_MONOTONIC_RAW, &start);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		clock_gettime(CLOCK_MONOTONIC_RAW, &end);
		[samples addObject:[NSNumber numberWithDouble:(NSTimeInterval)(end.tv_sec - start.tv_sec) +
			(NSTimeInterval)(end.tv_nsec - start.tv_nsec) / NSEC_PER_SEC]];
	}
	[samples sortUsingSelector:@selector(compare:)];
	return [[samples objectAtIndex:[samples count] / 2] doubleValue];
}

static void CreateBenchmarkFiles(NSString *directoryPath, NSUInteger first, NSUInteger count) {
	int directoryFD = open([directoryPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	REQUIRE(directoryFD >= 0);
	for (NSUInteger index = first; index < first + count; index++) {
		char name[64];
		snprintf(name, sizeof(name), "benchmark-%05lu.txt", (unsigned long)index);
		int fileFD = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
		REQUIRE(fileFD >= 0);
		close(fileFD);
	}
	close(directoryFD);
}

static void BenchmarkBulkEnumeration(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		CreateBenchmarkFiles(directoryPath, 0, 1000);
		NSTimeInterval oneThousand = MedianBulkScan(controller);
		NSTimeInterval fullOneThousand = MedianUnchangedDirectoryScan(controller);
		CreateBenchmarkFiles(directoryPath, 1000, 9000);
		NSTimeInterval tenThousand = MedianBulkScan(controller);
		NSTimeInterval fullTenThousand = MedianUnchangedDirectoryScan(controller);
		printf("bulk warm median: 1,000 %.3f ms; 10,000 %.3f ms\n",
			oneThousand * 1000.0, tenThousand * 1000.0);
		printf("full unchanged scan median: 1,000 %.3f ms; 10,000 %.3f ms\n",
			fullOneThousand * 1000.0, fullTenThousand * 1000.0);
		REQUIRE(oneThousand < 0.0012);
		REQUIRE(tenThousand < 0.014);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static BOOL PropertyListContainsKey(id object, NSString *key) {
	if ([object isKindOfClass:[NSDictionary class]]) {
		if ([object objectForKey:key]) return YES;
		for (id value in [object allValues])
			if (PropertyListContainsKey(value, key)) return YES;
	} else if ([object isKindOfClass:[NSArray class]]) {
		for (id value in object)
			if (PropertyListContainsKey(value, key)) return YES;
	}
	return NO;
}

static id ArchivePropertyList(id object) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
	return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
		format:NULL error:NULL];
}

static void TestEpochFiveArchive(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"epoch five metadata"] autorelease]
			title:@"Epoch Five" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		id noteArchive = ArchivePropertyList(note);
		NSArray *newNoteKeys = @[ @"fileModificationSeconds", @"fileModificationNanoseconds",
			@"fileAttributeChangeSeconds", @"fileAttributeChangeNanoseconds", @"fileLogicalSize64",
			@"fileDocumentIdentifier" ];
		for (NSString *key in newNoteKeys) REQUIRE(PropertyListContainsKey(noteArchive, key));
		for (NSString *key in @[ @"fileModifiedDate", @"logicalSize", @"perDiskInfoGroups" ])
			REQUIRE(!PropertyListContainsKey(noteArchive, key));

		NotationPrefs *prefs = [controller notationPrefs];
		id prefsArchive = ArchivePropertyList(prefs);
		REQUIRE(PropertyListContainsKey(prefsArchive, @"fileMetadataVolumeUUID"));
		REQUIRE(!PropertyListContainsKey(prefsArchive, @"seenDiskUUIDEntries"));
		for (NSUInteger index = 0; index < 4; index++)
			REQUIRE(!PropertyListContainsKey(prefsArchive,
				[NSString stringWithFormat:@"typeStrings.%lu", (unsigned long)index]));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NotationPrefs *roundTrippedPrefs = [NSKeyedUnarchiver unarchiveObjectWithData:
			[NSKeyedArchiver archivedDataWithRootObject:prefs]];
#pragma clang diagnostic pop
		REQUIRE([roundTrippedPrefs epochIteration] == EPOC_ITERATION);
		[note release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static NSData *IntegrationTestAttribute(NSString *path) {
	const char *name = "com.notationalvelocity.integration-test";
	const char *filePath = [path fileSystemRepresentation];
	ssize_t length = getxattr(filePath, name, NULL, 0, 0, 0);
	if (length < 0)
		return nil;
	NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
	REQUIRE(getxattr(filePath, name, [data mutableBytes], (size_t)length, 0, 0) == length);
	return data;
}

static void TestLifecycle(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSUInteger originalCount = controllerDeallocationCount;

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller resetLabelAddCount];
		NoteObject *detached = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"detached body"] autorelease]
			title:@"Detached" delegate:controller format:PlainTextFormat labels:@"ghost"];
		REQUIRE(detached != nil && [detached delegate] == nil && filenameOfNote(detached) == nil);
		REQUIRE([controller labelAddCount] == 0);
		[detached _setLabelString:@""];
		[detached attachToDelegate:controller];
		REQUIRE([detached delegate] == controller && filenameOfNote(detached) != nil);
		[detached setDelegate:nil];
		REQUIRE([detached delegate] == nil);
		[detached release];
		REQUIRE([[NoteObject alloc] initWithNoteBody:nil title:@"Invalid" delegate:controller
			format:PlainTextFormat labels:@""] == nil);
		CloseController(&controller);
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (controllerDeallocationCount == originalCount && [deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE(controllerDeallocationCount == originalCount + 1);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static NSUInteger OpenFileDescriptorCount(void) {
	NSUInteger count = 0;
	int descriptorLimit = getdtablesize();
	for (int descriptor = 0; descriptor < descriptorLimit; descriptor++) {
		errno = 0;
		if (fcntl(descriptor, F_GETFD) >= 0 || errno != EBADF) count++;
	}
	return count;
}

static void WarmControllerLifecycle(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateController(directoryPath, delegate);
	[controller stopFileNotifications];
	CloseController(&controller);
	[delegate release];
	RemoveTemporaryDirectory(directoryPath);
	[pool drain];
}

static void TestResourceLifecycle(void) {
	WarmControllerLifecycle();
	NSUInteger baselineDescriptorCount = OpenFileDescriptorCount();
	NSUInteger originalDeallocationCount = controllerDeallocationCount;
	const NSUInteger iterationCount = 8;

	for (NSUInteger iteration = 0; iteration < iterationCount; iteration++) {
		NSAutoreleasePool *iterationPool = [[NSAutoreleasePool alloc] init];
		NSString *directoryPath = CreateTemporaryDirectory();
		NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
		NVTestNotationController *controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];

		NSString *liveFilename = @"M Live.txt";
		WriteExternalFile(PlainTextFormat, @"live baseline",
			[directoryPath stringByAppendingPathComponent:liveFilename]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *liveNote = NoteContaining(controller, @"live baseline");
		REQUIRE(liveNote != nil);

		NSString *preparedFilename = @"A Prepared.txt";
		NSString *failingFilename = @"Z Failure.txt";
		WriteExternalFile(PlainTextFormat, @"prepared and discarded",
			[directoryPath stringByAppendingPathComponent:preparedFilename]);
		WriteExternalFile(PlainTextFormat, @"transaction failure",
			[directoryPath stringByAppendingPathComponent:failingFilename]);
		BOOL preparedNoteWasDeallocated = NO;
		[controller setPreparedNoteProbeName:preparedFilename
			deallocationFlag:&preparedNoteWasDeallocated];
		[controller setFailingSnapshotName:failingFilename];
		NSAutoreleasePool *transactionPool = [[NSAutoreleasePool alloc] init];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		[transactionPool drain];
		REQUIRE(preparedNoteWasDeallocated);
		REQUIRE([controller directoryRetryIsScheduled]);

		[liveNote setContentString:[[[NSAttributedString alloc]
			initWithString:@"pending lifecycle obligations"] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller pendingJournalWriteCount] == 1);
		REQUIRE([controller changeWriteTimerIsScheduled]);
		[controller breakJournalDescriptor];
		REQUIRE([controller bufferJournalForNoteWithoutRetiringObligation:liveNote]);
		REQUIRE([controller journalBufferedByteCount] > 0);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller pendingJournalWriteCount] == 1);

		REQUIRE(chmod([directoryPath fileSystemRepresentation], 0500) == 0);
		CloseController(&controller);
		NSDate *deallocationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
		while (controllerDeallocationCount < originalDeallocationCount + iteration + 1 &&
			[deallocationDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE(controllerDeallocationCount == originalDeallocationCount + iteration + 1);
		REQUIRE(chmod([directoryPath fileSystemRepresentation], 0700) == 0);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
		[iterationPool drain];
		REQUIRE(OpenFileDescriptorCount() == baselineDescriptorCount);
	}

	NSLog(@"resource lifecycle: %lu failed transactions/outbox teardowns, %lu open descriptors",
		(unsigned long)iterationCount, (unsigned long)baselineDescriptorCount);
}

static void TestAtomicInstallAcrossDirectoryMove(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *oldPath = [rootPath stringByAppendingPathComponent:@"Atomic Before Move"];
	NSString *newPath = [rootPath stringByAppendingPathComponent:@"Atomic After Move"];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:oldPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		controller = CreateController(oldPath, delegate);
		[controller stopFileNotifications];
		NSData *contents = [@"installed through the original directory descriptor"
			dataUsingEncoding:NSUTF8StringEncoding];
		__block BOOL moved = NO;
		NSError *error = nil;
		REQUIRE([controller storeDataAtomicallyInNotesDirectory:contents
			withName:@"Relocated Install.txt"
			preparationBlock:^BOOL(int fileDescriptor, NSError **preparationError) {
				(void)fileDescriptor;
				moved = [[NSFileManager defaultManager] moveItemAtPath:oldPath
					toPath:newPath error:preparationError];
				return moved;
			} verificationBlock:nil error:&error]);
		REQUIRE(error == nil && moved);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
		NSString *installedPath = [newPath stringByAppendingPathComponent:@"Relocated Install.txt"];
		REQUIRE([[[NSData alloc] initWithContentsOfFile:installedPath] autorelease] != nil);
		REQUIRE([contents isEqualToData:[NSData dataWithContentsOfFile:installedPath]]);
		RequireNoTemporaryFiles(newPath);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestScanAcrossDirectoryMove(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *oldPath = [rootPath stringByAppendingPathComponent:@"Scan Before Move"];
	NSString *newPath = [rootPath stringByAppendingPathComponent:@"Scan After Move"];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:oldPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		controller = CreateController(oldPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NSString *filename = @"Relocated Scan.txt";
		NSString *oldFilePath = [oldPath stringByAppendingPathComponent:filename];
		WriteExternalFile(PlainTextFormat, @"before directory move", oldFilePath);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = NoteContaining(controller, @"before directory move");
		REQUIRE(note != nil);
		WriteExternalFileInPlace(@"after directory move", oldFilePath);

		[controller resetSynchronizeCount];
		[controller resetDirectoryStreamReconfigurationCount];
		[controller setDirectoryMoveFromPath:oldPath toPath:newPath
			onCatalogRead:2];
		BOOL firstResult = [controller synchronizeNotesFromDirectory];
		REQUIRE(firstResult && [controller directoryMoveWasPerformed]);
		REQUIRE([[[note contentString] string] isEqualToString:@"after directory move"]);
		/* A main-queue FSEvents callback cannot run until the synchronous scan returns. */
		FSEventStreamEventFlags rootFlags[] = { kFSEventStreamEventFlagRootChanged };
		FSEventStreamEventId rootEventIDs[] = { 0 };
		FSEventsCallback(NULL, controller, 1, NULL, rootFlags, rootEventIDs);

		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ((![[[note contentString] string] isEqualToString:@"after directory move"] ||
			[controller directoryStreamReconfigurationCount] == 0) &&
			[deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE([[[note contentString] string] isEqualToString:@"after directory move"]);
		REQUIRE([controller synchronizeCount] >= 2);
		REQUIRE([controller directoryStreamReconfigurationCount] >= 1);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[newPath stringByAppendingPathComponent:filename]]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestRenamesWhileDirectoryMoves(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *oldDirectoryName = @"Rename Before Move";
	NSString *newDirectoryName = @"Rename After Move";
	NSString *oldPath = [rootPath stringByAppendingPathComponent:oldDirectoryName];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	pid_t mover = -1;
	int parentFD = -1;
	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:oldPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		controller = CreateController(oldPath, delegate);
		[controller stopFileNotifications];
		NSData *contents = [@"root-relative rename survives parent movement"
			dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([controller storeDataAtomicallyInNotesDirectory:contents
			withName:@"Rename A.txt" verificationBlock:nil error:NULL]);
		parentFD = open([rootPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		REQUIRE(parentFD >= 0);

		mover = fork();
		REQUIRE(mover >= 0);
		if (mover == 0) {
			for (NSUInteger iteration = 0; iteration < 250; iteration++) {
				if (renameat(parentFD, [oldDirectoryName fileSystemRepresentation], parentFD,
					[newDirectoryName fileSystemRepresentation]) < 0) _exit(30);
				usleep(50);
				if (renameat(parentFD, [newDirectoryName fileSystemRepresentation], parentFD,
					[oldDirectoryName fileSystemRepresentation]) < 0) _exit(31);
				usleep(50);
			}
			_exit(0);
		}

		NSString *currentName = @"Rename A.txt";
		NSString *nextName = @"Rename B.txt";
		NSUInteger renameCount = 0;
		int moverStatus = 0;
		while (waitpid(mover, &moverStatus, WNOHANG) == 0) {
			NSError *error = nil;
			REQUIRE([controller renameNoteFromName:currentName toName:nextName error:&error]);
			NSString *temporary = currentName;
			currentName = nextName;
			nextName = temporary;
			renameCount++;
			usleep(20);
		}
		mover = -1;
		REQUIRE(WIFEXITED(moverStatus) && WEXITSTATUS(moverStatus) == 0);
		REQUIRE(renameCount > 20);
		NSError *readError = nil;
		REQUIRE([contents isEqualToData:[controller dataFromNoteNamed:currentName error:&readError]]);
		REQUIRE(readError == nil);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[oldPath stringByAppendingPathComponent:currentName]]);
		NSLog(@"directory move/rename stress: %lu note renames during 500 parent renames",
			(unsigned long)renameCount);
	} @finally {
		if (mover > 0) {
			kill(mover, SIGKILL);
			(void)waitpid(mover, NULL, 0);
		}
		if (parentFD >= 0) close(parentFD);
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestDirectoryRelocationRaces(void) {
	TestAtomicInstallAcrossDirectoryMove();
	TestScanAcrossDirectoryMove();
	TestRenamesWhileDirectoryMoves();
}

static void VerifyExternalChanges(NVTestNotationController *controller, int format, NSString *directoryPath) {
	REQUIRE([controller totalNoteCount] == 1);
	NoteObject *original = [[AllNotes(controller) objectAtIndex:0] retain];
	NSString *originalPath = [[original noteFileURL] path];
	NSString *externalText = @"Externally edited Unicode π content with a deliberately different size.";
	WriteExternalFile(format, externalText, originalPath);
	REQUIRE([controller synchronizeNotesFromDirectory]);
	REQUIRE([controller totalNoteCount] == 1);
	REQUIRE([AllNotes(controller) objectAtIndex:0] == original);
	REQUIRE([[[original contentString] string] rangeOfString:externalText].location != NSNotFound);

	NSString *renamedFilename = [NSString stringWithFormat:@"External Rename Ω.%@",
		[NotationPrefs pathExtensionForFormat:format]];
	NSString *renamedPath = [directoryPath stringByAppendingPathComponent:renamedFilename];
	NSError *error = nil;
	REQUIRE([[NSFileManager defaultManager] moveItemAtPath:originalPath toPath:renamedPath error:&error]);
	REQUIRE([controller synchronizeNotesFromDirectory]);
	REQUIRE([controller totalNoteCount] == 1);
	REQUIRE([AllNotes(controller) objectAtIndex:0] == original);
	REQUIRE([filenameOfNote(original) isEqualToString:renamedFilename]);

	NSString *addedFilename = [NSString stringWithFormat:@"External Add Ω.%@",
		[NotationPrefs pathExtensionForFormat:format]];
	NSString *addedPath = [directoryPath stringByAppendingPathComponent:addedFilename];
	NSString *addedText = @"A separately added note.";
	WriteExternalFile(format, addedText, addedPath);
	REQUIRE([controller synchronizeNotesFromDirectory]);
	REQUIRE([controller totalNoteCount] == 2);
	NoteObject *addedNote = NoteContaining(controller, addedText);
	REQUIRE(addedNote != nil);

	[[controller notationPrefs] setConfirmsFileDeletion:NO];
	REQUIRE([[NSFileManager defaultManager] removeItemAtPath:addedPath error:&error]);
	REQUIRE([controller synchronizeNotesFromDirectory]);
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	REQUIRE([controller totalNoteCount] == 1);
	REQUIRE([AllNotes(controller) objectAtIndex:0] == original);
	[original release];
}

static void TestStorageFormat(int format) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSURL *trashArtifact = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:format];
		[controller stopFileNotifications];
		NSString *duplicateTitle = [NSString stringWithFormat:@"Duplicate Ω 東京 %@", [[NSUUID UUID] UUIDString]];

		NoteObject *first = [[NoteObject alloc] initWithNoteBody:StyledBody(@"initial")
			title:duplicateTitle delegate:controller format:format labels:@"alpha beta"];
		REQUIRE(first != nil);
		[controller addNewNote:first];
		NoteObject *duplicate = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Duplicate-name companion"] autorelease]
			title:duplicateTitle delegate:controller format:format labels:@"gamma"];
		REQUIRE(duplicate != nil);
		[controller addNewNote:duplicate];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(![filenameOfNote(first) isEqualToString:filenameOfNote(duplicate)]);

		[first setTitleString:@"Renamed café 東京"];
		[first setLabelString:@"alpha beta updated"];
		[first setContentString:StyledBody(@"first replacement")];
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller flushAllNoteChanges]);

		NSString *storagePath = format == SingleDatabaseFormat
			? [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName]
			: [[first noteFileURL] path];
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:storagePath]);
		if (format != SingleDatabaseFormat)
			REQUIRE([[storagePath pathExtension] isEqualToString:[NotationPrefs pathExtensionForFormat:format]]);

		NSError *error = nil;
		REQUIRE([[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @0640 }
										 ofItemAtPath:storagePath error:&error]);
		[first setContentString:StyledBody(@"second replacement with more text")];
		[controller synchronizeNoteChanges:nil];
		[first setContentString:StyledBody(@"final replacement")];
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller flushAllNoteChanges]);
		RequireMode(storagePath, 0640);
		RequireNoTemporaryFiles(directoryPath);

		if (format != SingleDatabaseFormat) {
			NSArray *tags = [[NSFileManager defaultManager] getOpenMetaTagsAtFSPath:[storagePath fileSystemRepresentation]];
			REQUIRE([tags containsObject:@"alpha"]);
			REQUIRE([tags containsObject:@"updated"]);
			id cocoaTags = nil;
			REQUIRE([[first noteFileURL] getResourceValue:&cocoaTags
				forKey:NSURLTagNamesKey error:&error]);
			REQUIRE([cocoaTags containsObject:@"alpha"] && [cocoaTags containsObject:@"updated"]);
			if (format == PlainTextFormat)
				REQUIRE([[NSFileManager defaultManager] textEncodingAttributeOfFSPath:
					[storagePath fileSystemRepresentation]] == NSUTF8StringEncoding);
		}

		[first release];
		[duplicate release];
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller currentNoteStorageFormat] == format);
		REQUIRE([controller totalNoteCount] == 2);
		first = NoteContaining(controller, @"final replacement");
		duplicate = NoteContaining(controller, @"Duplicate-name companion");
		REQUIRE(first != nil);
		REQUIRE(duplicate != nil);
		REQUIRE([titleOfNote(first) isEqualToString:@"Renamed café 東京"]);
		REQUIRE([labelsOfNote(first) rangeOfString:@"updated"].location != NSNotFound);
		if (format == RTFTextFormat || format == HTMLFormat)
			REQUIRE(BodyPreservesStyles([first contentString]));

		[controller removeNote:duplicate];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([controller totalNoteCount] == 1);
		if (format != SingleDatabaseFormat) {
			trashArtifact = [[controller lastTrashedURL] retain];
			REQUIRE([trashArtifact checkResourceIsReachableAndReturnError:NULL]);
			RemoveTrashArtifact(trashArtifact);
		}

		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		if (format != SingleDatabaseFormat)
			VerifyExternalChanges(controller, format, directoryPath);
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		if (format != SingleDatabaseFormat) {
			NoteObject *renamed = [AllNotes(controller) objectAtIndex:0];
			REQUIRE([titleOfNote(renamed) isEqualToString:@"External Rename Ω"]);
			REQUIRE([[[renamed contentString] string] rangeOfString:@"Externally edited"].location != NSNotFound);
		}
	} @finally {
		CloseController(&controller);
		RemoveTrashArtifact(trashArtifact);
		[trashArtifact release];
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestStorageTransitionMemoryWins(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NoteObject *note = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller currentNoteStorageFormat] == SingleDatabaseFormat);

		NSString *memoryText = @"authoritative in-memory note";
		note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:memoryText] autorelease]
			title:@"Storage Transition" delegate:controller format:SingleDatabaseFormat labels:@""];
		REQUIRE(note != nil);
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);

		NSString *filePath = [directoryPath stringByAppendingPathComponent:filenameOfNote(note)];
		REQUIRE([@"newer external file" writeToFile:filePath atomically:NO
			encoding:NSUTF8StringEncoding error:NULL]);
		struct timespec future[2];
		REQUIRE(clock_gettime(CLOCK_REALTIME, &future[0]) == 0);
		future[0].tv_sec += 60;
		future[1] = future[0];
		REQUIRE(utimensat(AT_FDCWD, [filePath fileSystemRepresentation], future, 0) == 0);

		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSString *storedText = [NSString stringWithContentsOfFile:filePath
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([storedText isEqualToString:memoryText]);
		REQUIRE([[[note contentString] string] isEqualToString:memoryText]);
	} @finally {
		[note release];
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestOpenFilesWorkflow(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NSString *importDirectoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NoteObject *knownNote = AddTestNote(controller, @"Already Open", @"known note body");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *importPath = [importDirectoryPath stringByAppendingPathComponent:@"Imported.txt"];
		WriteExternalFile(PlainTextFormat, @"imported through openFiles", importPath);

		NSArray *paths = @[ [[knownNote noteFileURL] path], importPath ];
		REQUIRE([controller openFiles:paths]);
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE([[delegate revealedNotes] containsObject:knownNote]);
		REQUIRE(NoteContaining(controller, @"imported through openFiles") != nil);
		REQUIRE([[NSString stringWithContentsOfFile:importPath
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"imported through openFiles"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(importDirectoryPath);
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestDeletionContracts(void) {
	NVAppControllerWindow *window = [[[NVAppControllerWindow alloc] init] autorelease];
	NVDeleteNotesTableView *tableView = [[[NVDeleteNotesTableView alloc] init] autorelease];
	NVDeletionAppController *appController = [[[NVDeletionAppController alloc]
		initWithWindow:window notesTableView:tableView] autorelease];
	[appController deleteNote:nil];
	REQUIRE([tableView selectedRowIndexesCallCount] == 0);

	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSUndoManager *routedUndoManager = [[[NSUndoManager alloc] init] autorelease];
		NVAppControllerWindow *routingWindow = [[[NVAppControllerWindow alloc]
			initWithUndoManager:routedUndoManager] autorelease];
		NVDeletionAppController *undoAppController = [[NVDeletionAppController alloc]
			initWithWindow:routingWindow notesTableView:nil];
		[undoAppController setNotationController:controller];
		REQUIRE([controller undoManager] == [undoAppController valueForKey:@"windowUndoManager"]);
		[NSObject cancelPreviousPerformRequestsWithTarget:controller];
		[controller setDelegate:delegate];
		[undoAppController release];

		[controller setUseTestTrash:YES];
		NSUndoManager *undoManager = [controller undoManager];
		NoteObject *undoNote = AddTestNote(controller, @"Undo Deletion", @"undo deletion body");
		REQUIRE([controller flushAllNoteChanges]);
		[undoManager beginUndoGrouping];
		[controller removeNote:undoNote];
		[undoManager endUndoGrouping];
		REQUIRE([controller totalNoteCount] == 0 && [undoManager canUndo]);
		[undoManager undo];
		REQUIRE([controller totalNoteCount] == 1 && [AllNotes(controller) containsObject:undoNote]);
		[undoManager removeAllActions];
		[controller removeNote:undoNote];
		[undoManager removeAllActions];

		NoteObject *first = AddTestNote(controller, @"Restore First", @"restore first body");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *firstPath = [[first noteFileURL] path];
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:firstPath error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller deletionCandidateCount] == 1);
		[controller restoreDeletionCandidates];
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:firstPath]);
		REQUIRE([controller deletionCandidateCount] == 0);
		REQUIRE([controller totalNoteCount] == 1);

		NoteObject *second = AddTestNote(controller, @"Delete Second", @"delete second body");
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:firstPath error:NULL]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[second noteFileURL] path] error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller deletionCandidateCount] == 2);
		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		[controller processDeletionCandidates];
		REQUIRE([controller totalNoteCount] == 0);

		NoteObject *failed = AddTestNote(controller, @"Failed Trash", @"must remain after failure");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *failedPath = [[failed noteFileURL] path];
		[failed setContentString:[[[NSAttributedString alloc]
			initWithString:@"latest edit survives failure"] autorelease]];
		[controller setForceTrashFailure:YES];
		[controller removeNote:failed];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:failedPath]);
		REQUIRE([[NSString stringWithContentsOfFile:failedPath
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"latest edit survives failure"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestStorageTransitions(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NoteObject *note = AddTestNote(controller, @"Transition Matrix", @"format transition body");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *plainPath = [[note noteFileURL] path];

		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *rtfPath = [[note noteFileURL] path];
		REQUIRE([[rtfPath pathExtension] caseInsensitiveCompare:@"rtf"] == NSOrderedSame);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:plainPath]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:rtfPath]);

		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		REQUIRE([controller flushAllNoteChanges]);
		[controller setUseTestTrash:YES];
		[controller trashRemainingNoteFilesInDirectory];
		REQUIRE([controller trashMoveCount] == 1);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:rtfPath]);
		CloseController(&controller);

		controller = CreateController(directoryPath, delegate);
		REQUIRE([controller currentNoteStorageFormat] == SingleDatabaseFormat);
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"format transition body") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFSEventsWriterChild(void) {
	NSString *directoryPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_FSEVENTS_DIRECTORY"];
	REQUIRE([directoryPath length]);
	NSString *path = [directoryPath stringByAppendingPathComponent:@"Live Event.txt"];
	NSString *renamedPath = [directoryPath stringByAppendingPathComponent:@"Live Renamed.txt"];
	usleep(1000000);
	WriteExternalFile(PlainTextFormat, @"live event create", path);
	usleep(2500000);
	REQUIRE(rename([path fileSystemRepresentation], [renamedPath fileSystemRepresentation]) == 0);
	usleep(2500000);
	WriteExternalFileInPlace(@"live event edit", renamedPath);
	usleep(2500000);
	REQUIRE(unlink([renamedPath fileSystemRepresentation]) == 0);
}

static void TestLiveFSEvents(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	pid_t child = -1;
	NoteObject *note = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		const char *oldValue = getenv("NV_FSEVENTS_DIRECTORY");
		NSString *savedValue = oldValue ? [NSString stringWithUTF8String:oldValue] : nil;
		REQUIRE(setenv("NV_FSEVENTS_DIRECTORY", [directoryPath fileSystemRepresentation], 1) == 0);
		NSString *executable = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
		char *arguments[] = {
			(char*)[executable fileSystemRepresentation], "fsevents-writer-child", NULL
		};
		REQUIRE(posix_spawn(&child, arguments[0], NULL, NULL, arguments, environ) == 0);
		if (savedValue) REQUIRE(setenv("NV_FSEVENTS_DIRECTORY", [savedValue UTF8String], 1) == 0);
		else REQUIRE(unsetenv("NV_FSEVENTS_DIRECTORY") == 0);

		NSUInteger stage = 0;
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
		while (stage < 4 && [deadline timeIntervalSinceNow] > 0.0) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:
				[NSDate dateWithTimeIntervalSinceNow:0.01]];
			if (stage == 0 && (note = [NoteContaining(controller, @"live event create") retain]))
				stage = 1;
			else if (stage == 1 && [filenameOfNote(note) isEqualToString:@"Live Renamed.txt"])
				stage = 2;
			else if (stage == 2 && NoteContaining(controller, @"live event edit") == note)
				stage = 3;
			else if (stage == 3 && [controller totalNoteCount] == 0)
				stage = 4;
		}
		REQUIRE(stage == 4);
		int status = 0;
		REQUIRE(waitpid(child, &status, 0) == child);
		child = -1;
		REQUIRE(WIFEXITED(status) && WEXITSTATUS(status) == 0);
	} @finally {
		[note release];
		if (child > 0) {
			kill(child, SIGTERM);
			waitpid(child, NULL, 0);
		}
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFilenameCollisions(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSString *untrackedPath = [directoryPath stringByAppendingPathComponent:@"Untracked.txt"];
		WriteExternalFile(PlainTextFormat, @"untracked disk contents", untrackedPath);
		NoteObject *collision = AddTestNote(controller, @"Untracked", @"new note contents");
		NoteObject *slash = AddTestNote(controller, @"Folder/Title", @"slash title contents");
		NoteObject *caseNote = AddTestNote(controller, @"Case Name", @"case-only rename contents");
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([filenameOfNote(collision) caseInsensitiveCompare:@"Untracked.txt"] != NSOrderedSame);
		REQUIRE([[[NSString alloc] initWithContentsOfFile:untrackedPath
			encoding:NSUTF8StringEncoding error:NULL] autorelease] != nil);
		REQUIRE([[NSString stringWithContentsOfFile:untrackedPath encoding:NSUTF8StringEncoding error:NULL]
			isEqualToString:@"untracked disk contents"]);
		REQUIRE([filenameOfNote(slash) rangeOfString:@"/"].location == NSNotFound);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:[[slash noteFileURL] path]]);
		REQUIRE([titleOfNote(slash) isEqualToString:@"Folder/Title"]);

		[caseNote setTitleString:@"case name"];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([filenameOfNote(caseNote) caseInsensitiveCompare:@"case name.txt"] == NSOrderedSame);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE(NoteContaining(controller, @"untracked disk contents") != nil);
		REQUIRE(NoteContaining(controller, @"new note contents") != nil);
		REQUIRE(NoteContaining(controller, @"slash title contents") != nil);
		REQUIRE(NoteContaining(controller, @"case-only rename contents") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestConcurrentControllers(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *first = nil;
	NVTestNotationController *second = nil;
	@try {
		first = CreateController(directoryPath, delegate);
		NoteObject *note = AddTestNote(first, @"Exclusive Journal", @"first controller remains authoritative");
		REQUIRE([first flushAllNoteChanges]);
		OSStatus status = noErr;
		second = [[NVTestNotationController alloc] initWithDirectoryURL:
			FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(second == nil);
		REQUIRE(status != noErr);

		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"first controller still writes"] autorelease]];
		REQUIRE([first flushAllNoteChanges]);
		CloseController(&first);
		first = CreateController(directoryPath, delegate);
		REQUIRE(NoteContaining(first, @"first controller still writes") != nil);
	} @finally {
		CloseController(&second);
		CloseController(&first);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestPlainTextEncodings(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSString *filename = @"Latin One.txt";
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		NSString *original = @"caf\u00e9";
		REQUIRE([[original dataUsingEncoding:NSISOLatin1StringEncoding]
			writeToFile:path options:0 error:NULL]);
		REQUIRE(SetTestTextEncoding(controller, NSISOLatin1StringEncoding, filename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *note = NoteContaining(controller, original);
		REQUIRE(note != nil);
		REQUIRE(fileEncodingOfNote(note) == NSISOLatin1StringEncoding);
		const uint8_t malformedBytes[] = { 0xC3, 0x28 };
		NSData *malformedData = [NSData dataWithBytes:malformedBytes length:sizeof(malformedBytes)];
		NSString *malformedFilename = @"Malformed UTF8.txt";
		NSString *malformedPath = [directoryPath stringByAppendingPathComponent:malformedFilename];
		REQUIRE([malformedData writeToFile:malformedPath options:0 error:NULL]);
		REQUIRE(SetTestTextEncoding(controller, NSUTF8StringEncoding, malformedFilename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NSString *fallbackText = [[[NSString alloc] initWithData:malformedData
			encoding:NSMacOSRomanStringEncoding] autorelease];
		NoteObject *malformedNote = NoteContaining(controller, fallbackText);
		REQUIRE(malformedNote != nil);
		REQUIRE(fileEncodingOfNote(malformedNote) == NSMacOSRomanStringEncoding);
		[malformedNote setContentString:[[[NSAttributedString alloc]
			initWithString:fallbackText] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSData dataWithContentsOfFile:malformedPath] isEqualToData:malformedData]);

		NSString *updated = @"\u00e9l\u00e8ve";
		[note setContentString:[[[NSAttributedString alloc] initWithString:updated] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSData dataWithContentsOfFile:path]
			isEqualToData:[updated dataUsingEncoding:NSISOLatin1StringEncoding]]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		note = NoteContaining(controller, updated);
		REQUIRE(note != nil);
		REQUIRE(fileEncodingOfNote(note) == NSISOLatin1StringEncoding);
		malformedNote = NoteContaining(controller, fallbackText);
		REQUIRE(malformedNote != nil);
		REQUIRE(fileEncodingOfNote(malformedNote) == NSMacOSRomanStringEncoding);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFilesystemCRUD(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NoteObject *note = AddTestNote(controller, @"Filesystem CRUD", @"created on test volume");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *oldPath = [[note noteFileURL] path];
		NSString *newPath = [directoryPath stringByAppendingPathComponent:@"Filesystem Moved.txt"];
		REQUIRE(rename([oldPath fileSystemRepresentation], [newPath fileSystemRepresentation]) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([filenameOfNote(note) isEqualToString:@"Filesystem Moved.txt"]);
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"saved after move"] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE(NoteContaining(controller, @"saved after move") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestRenameSkipsExistencePreflight(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NoteObject *note = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"rename fixture"] autorelease]
			title:@"Rename Before" delegate:controller format:PlainTextFormat labels:@""];
		REQUIRE(note != nil);
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);

		NSString *oldName = [[filenameOfNote(note) copy] autorelease];
		NSString *newName = @"Rename After.txt";
		[controller removeNoteBeforeRenameExistenceCheck:oldName];
		[note setFilename:newName withExternalTrigger:NO];
		REQUIRE([filenameOfNote(note) isEqualToString:newName]);
		REQUIRE([controller renameExistenceCheckCount] == 0);
		[controller removeNoteBeforeRenameExistenceCheck:nil];
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:oldName]]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:newName]]);
	} @finally {
		[note release];
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestRenameENOENTRequiresMissingSource(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		NSString *oldName = @"Collision Source.txt";
		NSString *newName = @"Collision Destination.txt";
		REQUIRE([@"source" writeToFile:[directoryPath stringByAppendingPathComponent:oldName]
			atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
		REQUIRE([@"destination" writeToFile:[directoryPath stringByAppendingPathComponent:newName]
			atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
		[controller removeRenameCollisionDestination:newName];
		NSError *error = nil;
		REQUIRE(![controller renameNoteFromName:oldName toName:newName error:&error]);
		REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == EAGAIN);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:oldName]]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:newName]]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestDirectoryIdentity(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *oldPath = [rootPath stringByAppendingPathComponent:@"Notes Before Move"];
	NSString *newPath = [rootPath stringByAppendingPathComponent:@"Notes After Move"];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSData *aliasData = nil;
	NSData *bookmarkData = nil;
	NSURL *directoryReferenceURL = nil;

	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:oldPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		controller = CreateController(oldPath, delegate);
		REQUIRE(![controller notesDirectoryIsTrashed]);
		directoryReferenceURL = [[controller noteDirectoryURL] retain];
		NSURL *databaseReferenceURL = [[NSFileManager defaultManager]
			fileReferenceURLForFilename:NotesDatabaseFileName
			inDirectoryURL:directoryReferenceURL error:NULL];
		REQUIRE([databaseReferenceURL baseURL] != nil);
		bookmarkData = [[[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:directoryReferenceURL error:NULL] retain];
		NSError *error = nil;
		REQUIRE([[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error]);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Written after directory move"] autorelease]
			title:@"Moved Directory Note" delegate:controller format:SingleDatabaseFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[newPath stringByAppendingPathComponent:NotesDatabaseFileName]]);
		REQUIRE([[NSData dataWithContentsOfURL:databaseReferenceURL] length] > 0);
		REQUIRE([[[directoryReferenceURL path] lastPathComponent] isEqualToString:[newPath lastPathComponent]]);
		REQUIRE(![controller notesDirectoryIsTrashed]);
		aliasData = [[NSData legacyAliasDataForFileReferenceURL:directoryReferenceURL] copy];
		REQUIRE(aliasData != nil);
		CloseController(&controller);

		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc] initWithAliasData:aliasData error:&status];
		REQUIRE(controller != nil);
		REQUIRE(status == noErr);
		[controller setDelegate:delegate];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"Written after directory move") != nil);
		BOOL stale = NO;
		NSURL *bookmarkURL = [[NSFileManager defaultManager]
			fileReferenceURLFromBookmarkData:bookmarkData stale:&stale error:NULL];
		REQUIRE(bookmarkURL != nil);
		REQUIRE([[[bookmarkURL path] lastPathComponent] isEqualToString:[newPath lastPathComponent]]);
		NVReferenceCountingFileManager *countingManager =
			[[[NVReferenceCountingFileManager alloc] init] autorelease];
		NSURL *countedBookmarkURL = [countingManager fileReferenceURLFromBookmarkData:bookmarkData
			stale:NULL error:NULL];
		REQUIRE([countedBookmarkURL isFileReferenceURL]);
		REQUIRE(URLsReferToSameItem(countedBookmarkURL, directoryReferenceURL));
		REQUIRE([countingManager referenceConversionCount] == 0);
	} @finally {
		CloseController(&controller);
		[aliasData release];
		[bookmarkData release];
		[directoryReferenceURL release];
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestLocationMigration(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *oldPath = [rootPath stringByAppendingPathComponent:@"Legacy Notes Location"];
	NSString *newPath = [rootPath stringByAppendingPathComponent:@"Moved Notes Location"];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;

	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:oldPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		NSURL *oldReferenceURL = FileReferenceURLForPath(oldPath);
		NSData *legacyAlias = [[NSData legacyAliasDataForFileReferenceURL:oldReferenceURL] copy];
		REQUIRE(legacyAlias != nil);

		NSError *error = nil;
		NSData *bookmark = [[[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:oldReferenceURL error:&error] copy];
		REQUIRE(bookmark != nil);
		REQUIRE(error == nil);

		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc] initWithAliasData:legacyAlias error:&status];
		REQUIRE(controller != nil);
		REQUIRE(status == noErr);
		[controller setDelegate:delegate];
		REQUIRE([[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error]);

		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Written after migrating the stored location"] autorelease]
			title:@"Location Migration" delegate:controller format:SingleDatabaseFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);

		BOOL stale = NO;
		error = nil;
		NSURL *resolvedURL = [[NSFileManager defaultManager]
			fileReferenceURLFromBookmarkData:bookmark stale:&stale error:&error];
		REQUIRE(resolvedURL != nil);
		REQUIRE(error == nil);
		REQUIRE([resolvedURL isFileReferenceURL]);
		REQUIRE([[[resolvedURL path] lastPathComponent] isEqualToString:[newPath lastPathComponent]]);

		controller = CreateControllerWithURL(resolvedURL, delegate);
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, @"migrating the stored location") != nil);
		[bookmark release];
		[legacyAlias release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestPreferencesMigration(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *legacyPath = [rootPath stringByAppendingPathComponent:@"Legacy Choice"];
	NSString *bookmarkPath = [rootPath stringByAppendingPathComponent:@"Bookmark Choice"];
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	id savedAlias = [[defaults objectForKey:@"DirectoryAlias"] retain];
	id savedBookmark = [[defaults objectForKey:@"DirectoryBookmark"] retain];

	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:legacyPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:bookmarkPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		NSURL *legacyURL = FileReferenceURLForPath(legacyPath);
		NSURL *bookmarkURL = FileReferenceURLForPath(bookmarkPath);
		NSData *legacyAlias = [NSData legacyAliasDataForFileReferenceURL:legacyURL];
		NSData *conflictingBookmark = [[NSFileManager defaultManager]
			bookmarkDataForFileReferenceURL:bookmarkURL error:NULL];
		REQUIRE(legacyAlias != nil);
		REQUIRE(conflictingBookmark != nil);
		[defaults setObject:legacyAlias forKey:@"DirectoryAlias"];
		[defaults setObject:conflictingBookmark forKey:@"DirectoryBookmark"];

		BOOL repaired = NO;
		NSError *error = nil;
		GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
		NSURL *resolvedURL = [prefs defaultDirectoryURLResolvingBookmark:&repaired error:&error];
		REQUIRE(resolvedURL != nil);
		REQUIRE(error == nil);
		REQUIRE(repaired);
		REQUIRE(URLsReferToSameItem(resolvedURL, legacyURL));
		NSURL *repairedBookmarkURL = [[NSFileManager defaultManager]
			fileReferenceURLFromBookmarkData:[prefs bookmarkDataForDefaultDirectory] stale:NULL error:NULL];
		REQUIRE(URLsReferToSameItem(repairedBookmarkURL, legacyURL));

		[defaults removeObjectForKey:@"DirectoryBookmark"];
		repaired = NO;
		resolvedURL = [prefs defaultDirectoryURLResolvingBookmark:&repaired error:&error];
		REQUIRE(resolvedURL != nil);
		REQUIRE(repaired);
		REQUIRE([prefs bookmarkDataForDefaultDirectory] != nil);
		REQUIRE(URLsReferToSameItem(resolvedURL, legacyURL));
	} @finally {
		if (savedAlias) [defaults setObject:savedAlias forKey:@"DirectoryAlias"];
		else [defaults removeObjectForKey:@"DirectoryAlias"];
		if (savedBookmark) [defaults setObject:savedBookmark forKey:@"DirectoryBookmark"];
		else [defaults removeObjectForKey:@"DirectoryBookmark"];
		[savedAlias release];
		[savedBookmark release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestDeepDirectory(void) {
	NSString *rootPath = CreateTemporaryDirectory();
	NSString *movableName = @"Movable Parent";
	NSString *notesName = @"Selected Notes";
	NSString *notesPath = [[rootPath stringByAppendingPathComponent:movableName]
		stringByAppendingPathComponent:notesName];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSURL *deepURL = nil;
	NSMutableArray *directoryFDs = [NSMutableArray array];
	NSMutableArray *components = [NSMutableArray array];
	BOOL moved = NO;

	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:notesPath
			withIntermediateDirectories:YES attributes:nil error:NULL]);
		deepURL = [FileReferenceURLForPath(notesPath) retain];
		controller = CreateControllerWithURL(deepURL, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];

		int directoryFD = open([rootPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		REQUIRE(directoryFD >= 0);
		[directoryFDs addObject:[NSNumber numberWithInt:directoryFD]];
		for (NSUInteger index = 0; index < 26; index++) {
			NSString *component = [NSString stringWithFormat:@"%02lu-%@", (unsigned long)index,
				[@"x" stringByPaddingToLength:180 withString:@"x" startingAtIndex:0]];
			const char *name = [component fileSystemRepresentation];
			REQUIRE(mkdirat(directoryFD, name, 0700) == 0);
			int childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
			REQUIRE(childFD >= 0);
			[components addObject:component];
			[directoryFDs addObject:[NSNumber numberWithInt:childFD]];
			directoryFD = childFD;
		}
		int rootFD = [[directoryFDs objectAtIndex:0] intValue];
		REQUIRE(renameat(rootFD, [movableName fileSystemRepresentation], directoryFD,
			[movableName fileSystemRepresentation]) == 0);
		moved = YES;
		REQUIRE(![controller notesDirectoryIsTrashed]);

		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Stored beyond PATH_MAX"] autorelease]
			title:@"Deep Note" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(URLIsReferenceBased([note noteFileURL]));
		NSError *readError = nil;
		NSData *storedData = [controller dataFromNoteNamed:filenameOfNote(note) error:&readError];
		REQUIRE(storedData != nil);
		REQUIRE(readError == nil);
		NSString *storedString = [[[NSString alloc] initWithData:storedData encoding:NSUTF8StringEncoding] autorelease];
		REQUIRE([storedString rangeOfString:@"beyond PATH_MAX"].location != NSNotFound);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE(NoteContaining(controller, @"beyond PATH_MAX") != nil);
		[note release];
		note = nil;
		CloseController(&controller);
		controller = CreateControllerWithURL(deepURL, delegate);
		[controller stopFileNotifications];
		note = [NoteContaining(controller, @"beyond PATH_MAX") retain];
		REQUIRE(note != nil);

		NSData *externalData = [@"Externally changed beyond PATH_MAX" dataUsingEncoding:NSUTF8StringEncoding];
		int noteFD = openat([controller testNoteDirectoryFileDescriptor],
			[filenameOfNote(note) fileSystemRepresentation], O_WRONLY | O_TRUNC | O_CLOEXEC);
		REQUIRE(noteFD >= 0);
		REQUIRE(write(noteFD, [externalData bytes], [externalData length]) == (ssize_t)[externalData length]);
		REQUIRE(fsync(noteFD) == 0 && close(noteFD) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"Externally changed beyond PATH_MAX"]);
		[note release];
	} @finally {
		CloseController(&controller);
		if (moved && [directoryFDs count]) {
			int rootFD = [[directoryFDs objectAtIndex:0] intValue];
			int deepestFD = [[directoryFDs lastObject] intValue];
			(void)renameat(deepestFD, [movableName fileSystemRepresentation], rootFD,
				[movableName fileSystemRepresentation]);
		}
		for (NSUInteger count = [components count]; count > 0; count--) {
			close([[directoryFDs objectAtIndex:count] intValue]);
			(void)unlinkat([[directoryFDs objectAtIndex:count - 1] intValue],
				[[components objectAtIndex:count - 1] fileSystemRepresentation], AT_REMOVEDIR);
		}
		if ([directoryFDs count]) close([[directoryFDs objectAtIndex:0] intValue]);
		[deepURL release];
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestAtomicRollback(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSString *path = [directoryPath stringByAppendingPathComponent:@"Atomic Rollback.dat"];
	NSData *baseline = [@"known-good contents" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *replacement = [@"verified replacement contents" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *sentinel = [@"keep-this-metadata" dataUsingEncoding:NSUTF8StringEncoding];

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		NSError *error = nil;
		REQUIRE(![controller storeDataAtomicallyInNotesDirectory:baseline withName:@"../escape"
			verificationBlock:nil error:&error]);
		REQUIRE(error != nil);
		error = nil;
		REQUIRE([controller dataFromNoteNamed:@"../escape" error:&error] == nil);
		REQUIRE(error != nil);
		error = nil;
		REQUIRE([controller storeDataAtomicallyInNotesDirectory:baseline withName:[path lastPathComponent]
			verificationBlock:nil error:&error]);
		REQUIRE(error == nil);
		REQUIRE(chmod([path fileSystemRepresentation], 0640) == 0);
		REQUIRE(setxattr([path fileSystemRepresentation], "com.notationalvelocity.integration-test",
			[sentinel bytes], [sentinel length], 0, 0) == 0);

		[controller setAtomicVerificationResult:ioErr];
		error = nil;
		REQUIRE(![controller storeDataAtomicallyInNotesDirectory:replacement withName:[path lastPathComponent]
			verificationBlock:^BOOL(NSData *readBackData, NSError **verificationError) {
				(void)readBackData;
				if ([controller atomicVerificationResult] == noErr) return YES;
				if (verificationError) *verificationError = [NSError errorWithDomain:NSOSStatusErrorDomain
					code:[controller atomicVerificationResult] userInfo:nil];
				return NO;
			} error:&error]);
		REQUIRE(error != nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:baseline]);
		REQUIRE([IntegrationTestAttribute(path) isEqualToData:sentinel]);
		RequireMode(path, 0640);
		RequireNoTemporaryFiles(directoryPath);

		error = nil;
		REQUIRE(![controller storeDataAtomicallyInNotesDirectory:replacement
			withName:[path lastPathComponent]
			preparationBlock:^BOOL(int fileDescriptor, NSError **preparationError) {
				(void)fileDescriptor;
				if (preparationError) *preparationError = [NSError errorWithDomain:NSPOSIXErrorDomain
					code:EIO userInfo:nil];
				return NO;
			} verificationBlock:nil error:&error]);
		REQUIRE(error != nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:baseline]);
		REQUIRE([IntegrationTestAttribute(path) isEqualToData:sentinel]);
		RequireMode(path, 0640);
		RequireNoTemporaryFiles(directoryPath);

		[controller setAtomicVerificationResult:noErr];
		error = nil;
		REQUIRE([controller storeDataAtomicallyInNotesDirectory:replacement withName:[path lastPathComponent]
			verificationBlock:^BOOL(NSData *readBackData, NSError **verificationError) {
				(void)verificationError;
				return [readBackData isEqualToData:replacement];
			} error:&error]);
		REQUIRE(error == nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:replacement]);
		RequireMode(path, 0640);
		RequireNoTemporaryFiles(directoryPath);

		NoteObject *exportNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"shared export writer"] autorelease]
			title:@"Export" delegate:nil format:PlainTextFormat labels:@"tag"];
		[exportNote _setFileEncoding:NSUTF8StringEncoding];
		[exportNote setDateAdded:1000000.0];
		[exportNote setDateModified:1000100.0];
		NSURL *directoryReferenceURL = FileReferenceURLForPath(directoryPath);
		NSString *exportFilename = @"Shared Export.txt";
		NSString *exportPath = [directoryPath stringByAppendingPathComponent:exportFilename];
		error = nil;
		REQUIRE([exportNote exportToDirectoryURL:directoryReferenceURL withFilename:exportFilename
			usingFormat:PlainTextFormat overwrite:NO error:&error]);
		REQUIRE(error == nil);
		NSData *initialExportData = [NSData dataWithContentsOfFile:exportPath];
		REQUIRE([[[[NSString alloc] initWithData:initialExportData encoding:NSUTF8StringEncoding]
			autorelease] isEqualToString:@"shared export writer"]);
		[exportNote setContentString:[[[NSAttributedString alloc]
			initWithString:@"replacement export writer"] autorelease]];
		[exportNote setDateModified:1000100.0];
		error = nil;
		REQUIRE(![exportNote exportToDirectoryURL:directoryReferenceURL withFilename:exportFilename
			usingFormat:PlainTextFormat overwrite:NO error:&error]);
		REQUIRE([[error domain] isEqualToString:NSCocoaErrorDomain] &&
			[error code] == NSFileWriteFileExistsError);
		REQUIRE([[NSData dataWithContentsOfFile:exportPath] isEqualToData:initialExportData]);
		error = nil;
		REQUIRE([exportNote exportToDirectoryURL:directoryReferenceURL withFilename:exportFilename
			usingFormat:PlainTextFormat overwrite:YES error:&error]);
		REQUIRE(error == nil);
		REQUIRE([[[NSString stringWithContentsOfFile:exportPath encoding:NSUTF8StringEncoding
			error:&error] description] isEqualToString:@"replacement export writer"]);
		NSArray *openMetaTags = [[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[exportPath fileSystemRepresentation]];
		id cocoaTags = nil;
		REQUIRE([openMetaTags isEqual:@[ @"tag" ]]);
		REQUIRE([[NSURL fileURLWithPath:exportPath] getResourceValue:&cocoaTags
			forKey:NSURLTagNamesKey error:&error]);
		REQUIRE([cocoaTags isEqual:@[ @"tag" ]]);
		REQUIRE([[NSFileManager defaultManager] textEncodingAttributeOfFSPath:
			[exportPath fileSystemRepresentation]] == NSUTF8StringEncoding);
		NSDictionary *exportAttributes = [[NSFileManager defaultManager]
			attributesOfItemAtPath:exportPath error:&error];
		REQUIRE(fabs([[exportAttributes objectForKey:NSFileCreationDate]
			timeIntervalSinceReferenceDate] - 1000000.0) < 1.0);
		REQUIRE(fabs([[exportAttributes objectForKey:NSFileModificationDate]
			timeIntervalSinceReferenceDate] - 1000100.0) < 1.0);
		[exportNote release];
		RequireNoTemporaryFiles(directoryPath);

		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *boundaryNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"installed baseline"] autorelease]
			title:@"Installed Boundary" delegate:controller format:PlainTextFormat labels:@"tag"];
		[controller addNewNote:boundaryNote];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *boundaryFilename = [[filenameOfNote(boundaryNote) copy] autorelease];
		NSData *externalReplacement = [@"external replacement at installed boundary"
			dataUsingEncoding:NSUTF8StringEncoding];
		[controller replaceInstalledNoteNamed:boundaryFilename withData:externalReplacement];
		[boundaryNote setContentString:[[[NSAttributedString alloc]
			initWithString:@"our pending replacement"] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE(![boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller pendingFileWriteCount] == 1);
		NSString *externalDisk = [[[NSString alloc]
			initWithData:[controller dataFromNoteNamed:boundaryFilename error:NULL]
			encoding:NSUTF8StringEncoding] autorelease];
		REQUIRE([externalDisk isEqualToString:@"external replacement at installed boundary"]);
		REQUIRE([boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([controller pendingFileWriteCount] == 0);
		NSString *boundaryDisk = [[[NSString alloc]
			initWithData:[controller dataFromNoteNamed:boundaryFilename error:NULL]
			encoding:NSUTF8StringEncoding] autorelease];
		REQUIRE([boundaryDisk isEqualToString:@"our pending replacement"]);

		NSData *tagRaceReplacement = [@"evil-tag-race" dataUsingEncoding:NSUTF8StringEncoding];
		[controller mutateNoteNamed:boundaryFilename withData:tagRaceReplacement
			duringTagSynchronization:YES];
		[boundaryNote setContentString:[[[NSAttributedString alloc]
			initWithString:@"ours-tag-race"] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE(![boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([[controller dataFromNoteNamed:boundaryFilename error:NULL]
			isEqualToData:tagRaceReplacement]);
		REQUIRE([boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([controller pendingFileWriteCount] == 0);
		[boundaryNote release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestReferenceEdges(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];

		NoteObject *caseNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"original path identity contents"] autorelease]
			title:@"Case Edge" delegate:controller format:PlainTextFormat labels:@""];
		NoteObject *unicodeNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"decomposed Unicode filename"] autorelease]
			title:@"Cafe\u0301 東京" delegate:controller format:PlainTextFormat labels:@""];
		NSMutableString *longTitle = [NSMutableString string];
		while ([longTitle length] < 280)
			[longTitle appendString:@"LongTitle"];
		NoteObject *longNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"long component filename"] autorelease]
			title:longTitle delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:caseNote];
		[controller addNewNote:unicodeNote];
		[controller addNewNote:longNote];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([controller directoryStreamNoteCount] == 3);
		REQUIRE([[filenameOfNote(unicodeNote) precomposedStringWithCanonicalMapping]
			isEqualToString:[@"Caf\u00e9 東京.txt" precomposedStringWithCanonicalMapping]]);
		REQUIRE([filenameOfNote(longNote) length] <= 255);

		NoteObject *originalIdentity = [caseNote retain];
		NSString *originalPath = [[[caseNote noteFileURL] path] copy];
		NSError *error = nil;
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:originalPath error:&error]);
		NSString *replacementText = @"replacement at the same path with a new file identity and a different size";
		WriteExternalFile(PlainTextFormat, replacementText, originalPath);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 3);
		REQUIRE([AllNotes(controller) containsObject:originalIdentity]);
		REQUIRE([[[originalIdentity contentString] string] isEqualToString:replacementText]);

		NSString *caseFilename = @"case edge.txt";
		NSString *casePath = [directoryPath stringByAppendingPathComponent:caseFilename];
		REQUIRE(rename([originalPath fileSystemRepresentation], [casePath fileSystemRepresentation]) == 0);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 3);
		REQUIRE([AllNotes(controller) containsObject:originalIdentity]);
		REQUIRE([[[originalIdentity noteFileURL] lastPathComponent] isEqualToString:caseFilename]);
		[originalPath release];
		[originalIdentity release];
		[caseNote release];
		[unicodeNote release];
		[longNote release];

		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 3);
		REQUIRE(NoteContaining(controller, replacementText) != nil);
		REQUIRE(NoteContaining(controller, @"decomposed Unicode filename") != nil);
		REQUIRE(NoteContaining(controller, @"long component filename") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static NSData *LegacyFixtureData(NSString *name) {
	NSString *workingDirectory = [[NSFileManager defaultManager] currentDirectoryPath];
	NSArray *paths = @[
		[[workingDirectory stringByAppendingPathComponent:@"fixtures"] stringByAppendingPathComponent:name],
		[[workingDirectory stringByAppendingPathComponent:@"tests/fixtures"] stringByAppendingPathComponent:name]
	];
	for (NSString *path in paths) {
		NSString *base64 = [NSString stringWithContentsOfFile:path encoding:NSASCIIStringEncoding error:NULL];
		if (base64) {
			NSData *data = [[[NSData alloc] initWithBase64EncodedString:base64
				options:NSDataBase64DecodingIgnoreUnknownCharacters] autorelease];
			REQUIRE(data != nil);
			return data;
		}
	}
	REQUIRE(!"legacy fixture was not found");
	return nil;
}

static void TestLegacyFixtures(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;

	@try {
		NSData *database = LegacyFixtureData(@"LegacyUnencryptedNotesDatabase.base64");
		REQUIRE([database writeToFile:[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName]
			options:NSDataWritingAtomic error:NULL]);
		controller = CreateController(directoryPath, delegate);
		REQUIRE([controller totalNoteCount] == 1);
		NoteObject *note = [AllNotes(controller) objectAtIndex:0];
		REQUIRE([titleOfNote(note) isEqualToString:@"Legacy Fixture Note"]);
		REQUIRE([[[note contentString] string] isEqualToString:@"Legacy fixture caf\u00e9 東京"]);
		REQUIRE([labelsOfNote(note) rangeOfString:@"legacy"].location != NSNotFound);
		CloseController(&controller);

		NSData *encryptedDatabase = LegacyFixtureData(@"LegacyEncryptedNotesDatabase.base64");
		NSData *secretData = [@"LEGACY-ENCRYPTED-CONTENT" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([encryptedDatabase rangeOfData:secretData options:0
			range:NSMakeRange(0, [encryptedDatabase length])].location == NSNotFound);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		FrozenNotation *frozen = [NSKeyedUnarchiver unarchiveObjectWithData:encryptedDatabase];
#pragma clang diagnostic pop
		REQUIRE(frozen != nil);
		NotationPrefs *prefs = [frozen notationPrefs];
		NSData *passphrase = [@"legacy-fixture-passphrase" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([prefs canLoadPassphraseData:passphrase]);
		OSStatus status = noErr;
		NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&status];
		REQUIRE(status == noErr);
		REQUIRE([notes count] == 1);
		note = [notes objectAtIndex:0];
		REQUIRE([titleOfNote(note) isEqualToString:@"Legacy Encrypted Note"]);
		REQUIRE([[[note contentString] string]
			isEqualToString:@"LEGACY-ENCRYPTED-CONTENT-caf\u00e9-東京"]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestEncryption(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSData *passphrase = [@"integration-test-passphrase" dataUsingEncoding:NSUTF8StringEncoding];
	NSString *secret = @"SECRET-PLAINTEXT-5B575E23-東京";

	@try {
		controller = CreateController(directoryPath, delegate);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:secret] autorelease]
			title:@"Encrypted Note" delegate:controller format:SingleDatabaseFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		[[controller notationPrefs] setPassphraseData:passphrase inKeychain:NO];
		[[controller notationPrefs] setDoesEncryption:YES];
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);

		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSData *databaseData = [NSData dataWithContentsOfFile:databasePath];
		NSData *secretData = [secret dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE(databaseData != nil);
		REQUIRE([databaseData rangeOfData:secretData options:0
			range:NSMakeRange(0, [databaseData length])].location == NSNotFound);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		FrozenNotation *frozen = [NSKeyedUnarchiver unarchiveObjectWithData:databaseData];
#pragma clang diagnostic pop
		REQUIRE(frozen != nil);
		NotationPrefs *prefs = [frozen notationPrefs];
		REQUIRE([prefs canLoadPassphraseData:passphrase]);
		OSStatus status = noErr;
		NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&status];
		REQUIRE(status == noErr);
		REQUIRE([notes count] == 1);
		REQUIRE([[[[notes objectAtIndex:0] contentString] string] isEqualToString:secret]);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestTrash(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSURL *trashArtifact = nil;

	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSString *uniqueTitle = [NSString stringWithFormat:@"NV Trash Test %@", [[NSUUID UUID] UUIDString]];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"trash fixture"] autorelease]
			title:uniqueTitle delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		trashArtifact = [[note noteFileURL] retain];
		NSString *sourcePath = [[trashArtifact path] copy];
		[controller removeNote:note];
		[note release];
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]);
		[trashArtifact release];
		trashArtifact = [[controller lastTrashedURL] retain];
		REQUIRE([trashArtifact checkResourceIsReachableAndReturnError:NULL]);
		RemoveTrashArtifact(trashArtifact);
		REQUIRE(![trashArtifact checkResourceIsReachableAndReturnError:NULL]);
		[sourcePath release];
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 0);
	} @finally {
		CloseController(&controller);
		RemoveTrashArtifact(trashArtifact);
		[trashArtifact release];
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFailures(void) {
	OSStatus status = noErr;
	NVTestNotationController *controller = [[NVTestNotationController alloc] initWithDirectoryURL:nil error:&status];
	REQUIRE(controller == nil);
	REQUIRE(status == paramErr);

	NSString *rootPath = CreateTemporaryDirectory();
	@try {
		NSString *filePath = [rootPath stringByAppendingPathComponent:@"not-a-directory"];
		REQUIRE([@"file" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
		status = noErr;
		controller = [[NVTestNotationController alloc] initWithDirectoryURL:FileReferenceURLForPath(filePath) error:&status];
		REQUIRE(controller == nil);
		REQUIRE(status != noErr);
	} @finally {
		RemoveTemporaryDirectory(rootPath);
	}

	rootPath = CreateTemporaryDirectory();
	@try {
		NSString *deletedPath = [rootPath stringByAppendingPathComponent:@"deleted-reference"];
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:deletedPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		NSURL *deletedReference = [FileReferenceURLForPath(deletedPath) retain];
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:deletedPath error:NULL]);
		NSError *openError = nil;
		int deletedFD = [[NSFileManager defaultManager]
			openFileDescriptorForDirectoryReferenceURL:deletedReference error:&openError];
		REQUIRE(deletedFD < 0);
		REQUIRE(openError != nil);
		[deletedReference release];
	} @finally {
		RemoveTemporaryDirectory(rootPath);
	}

	rootPath = CreateTemporaryDirectory();
	@try {
		NSString *databasePath = [rootPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSError *archiveError = nil;
		NSData *corruptArchive = [NSKeyedArchiver archivedDataWithRootObject:
			[[[NVCorruptArchiveObject alloc] init] autorelease]
			requiringSecureCoding:NO error:&archiveError];
		REQUIRE(archiveError == nil);
		REQUIRE([corruptArchive writeToFile:databasePath atomically:YES]);
		status = noErr;
		controller = [[NVTestNotationController alloc] initWithDirectoryURL:FileReferenceURLForPath(rootPath) error:&status];
		REQUIRE(controller == nil);
		REQUIRE(status != noErr);
	} @finally {
		RemoveTemporaryDirectory(rootPath);
	}

	NSData *badAlias = [@"not an alias" dataUsingEncoding:NSUTF8StringEncoding];
	status = noErr;
	controller = [[NVTestNotationController alloc] initWithAliasData:badAlias error:&status];
	REQUIRE(controller == nil);
	REQUIRE(status != noErr);

	rootPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		controller = CreateController(rootPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE(chmod([rootPath fileSystemRepresentation], 0500) == 0);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"cannot write this file"] autorelease]
			title:@"Read Only Failure" delegate:controller format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller recordedWriteError] != noErr);
	} @finally {
		chmod([rootPath fileSystemRepresentation], 0700);
		CloseController(&controller);
		RemoveTemporaryDirectory(rootPath);
		[delegate release];
	}
}

static void ConfigureDefaults(void) {
	[[NSUserDefaults standardUserDefaults] setVolatileDomain:@{
		@"AutoCompleteSearches": @NO,
		@"TableColumnsHaveBodyPreview": @NO,
		@"HorizontalLayout": @NO
	} forName:NSArgumentDomain];
}

int main(int argc, const char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	ConfigureDefaults();
	int result = 0;

	@try {
		REQUIRE(argc == 2);
		NSString *scenario = [NSString stringWithUTF8String:argv[1]];
		if ([scenario isEqualToString:@"bulk-parser"])
			TestBulkParser();
		else if ([scenario isEqualToString:@"bulk-parser-fuzz"])
			TestBulkParserFuzz();
		else if ([scenario isEqualToString:@"file-metadata"])
			TestFileMetadata();
		else if ([scenario isEqualToString:@"coarse-ctime-observation"])
			TestCoarseCTimeObservation();
		else if ([scenario isEqualToString:@"snapshot-stress"])
			TestSnapshotStress();
		else if ([scenario isEqualToString:@"snapshot-boundary-races"])
			TestSnapshotBoundaryRaces();
		else if ([scenario isEqualToString:@"snapshot-in-place-observation"])
			TestInPlaceSnapshotObservation();
		else if ([scenario isEqualToString:@"xattr-interoperability"])
			TestXattrInteroperability();
		else if ([scenario isEqualToString:@"partial-bulk-fallback"])
			TestPartialBulkFallback();
		else if ([scenario isEqualToString:@"filesystem-capabilities"])
			TestFilesystemCapabilities();
		else if ([scenario isEqualToString:@"system-tag-producer"])
			TestSystemTagProducer();
		else if ([scenario isEqualToString:@"system-tag-writer-child"])
			TestSystemTagWriterChild();
		else if ([scenario isEqualToString:@"wal-crash-child"])
			TestWALCrashChild();
		else if ([scenario isEqualToString:@"wal-crash-recovery"])
			TestWALCrashRecovery();
		else if ([scenario isEqualToString:@"wal-history-child"])
			TestWALHistoryCrashChild();
		else if ([scenario isEqualToString:@"wal-history-recovery"])
			TestWALHistoryRecovery();
		else if ([scenario isEqualToString:@"wal-damaged-tail-child"])
			TestWALDamagedTailChild();
		else if ([scenario isEqualToString:@"wal-damaged-tail-recovery"])
			TestWALDamagedTailRecovery();
		else if ([scenario isEqualToString:@"wal-recovery-retry-initial-child"])
			TestWALRecoveryRetryInitialChild();
		else if ([scenario isEqualToString:@"wal-recovery-retry-failure-child"])
			TestWALRecoveryRetryFailureChild();
		else if ([scenario isEqualToString:@"wal-recovery-retry-idempotence"])
			TestWALRecoveryRetryIdempotence();
		else if ([scenario isEqualToString:@"wal-database-ordering-stale-child"])
			TestWALDatabaseOrderingStaleChild();
		else if ([scenario isEqualToString:@"wal-database-ordering-newer-child"])
			TestWALDatabaseOrderingNewerChild();
		else if ([scenario isEqualToString:@"wal-database-ordering"])
			TestWALDatabaseOrdering();
		else if ([scenario isEqualToString:@"wal-before-journal-sync-child"])
			TestWALDurabilityChild(NVWALBeforeJournalSynchronization);
		else if ([scenario isEqualToString:@"wal-after-journal-sync-child"])
			TestWALDurabilityChild(NVWALAfterJournalSynchronization);
		else if ([scenario isEqualToString:@"wal-after-database-persistence-child"])
			TestWALDurabilityChild(NVWALAfterDatabasePersistence);
		else if ([scenario isEqualToString:@"wal-durability-boundaries"])
			TestWALDurabilityBoundaries();
		else if ([scenario isEqualToString:@"unsupported-journal-lock-child"])
			TestUnsupportedJournalLockCrashChild();
		else if ([scenario isEqualToString:@"unsupported-journal-locks"])
			TestUnsupportedJournalLocks();
		else if ([scenario isEqualToString:@"file-outbox-crash-child"])
			TestFileOutboxCrashChild();
		else if ([scenario isEqualToString:@"file-outbox-crash-recovery"])
			TestFileOutboxCrashRecovery();
		else if ([scenario isEqualToString:@"bookmark-create"])
			TestBookmarkCreate();
		else if ([scenario isEqualToString:@"bookmark-resolve"])
			TestBookmarkResolve();
		else if ([scenario isEqualToString:@"live-detach-child"])
			TestLiveDetachChild();
		else if ([scenario isEqualToString:@"disk-full-recovery-contract"])
			TestDiskFullRecoveryContract();
		else if ([scenario isEqualToString:@"directory-reconciliation"])
			TestDirectoryReconciliation();
		else if ([scenario isEqualToString:@"snapshot-failures"])
			TestSnapshotFailurePropagation();
		else if ([scenario isEqualToString:@"ambiguous-content"])
			TestAmbiguousContentFallback();
		else if ([scenario isEqualToString:@"ambiguity-stress"])
			TestAmbiguityStress();
		else if ([scenario isEqualToString:@"scan-atomicity-contract"])
			TestDirectoryScanAtomicityContract();
		else if ([scenario isEqualToString:@"failed-scan-retry-contract"])
			TestFailedScanRetryContract();
		else if ([scenario isEqualToString:@"catalog-fence-contract"])
			TestCatalogFenceContract();
		else if ([scenario isEqualToString:@"directory-fence-modes"])
			TestDirectoryFenceModes();
		else if ([scenario isEqualToString:@"unsaved-write-recovery-contract"])
			TestUnsavedWriteRecoveryContract();
		else if ([scenario isEqualToString:@"epoch-five-archive"])
			TestEpochFiveArchive();
		else if ([scenario isEqualToString:@"benchmark"])
			BenchmarkBulkEnumeration();
		else if ([scenario isEqualToString:@"lifecycle"])
			TestLifecycle();
		else if ([scenario isEqualToString:@"resource-lifecycle"])
			TestResourceLifecycle();
		else if ([scenario isEqualToString:@"single-database"])
			TestStorageFormat(SingleDatabaseFormat);
		else if ([scenario isEqualToString:@"plain-text"])
			TestStorageFormat(PlainTextFormat);
		else if ([scenario isEqualToString:@"storage-transition-memory-wins"])
			TestStorageTransitionMemoryWins();
		else if ([scenario isEqualToString:@"open-files-workflow"])
			TestOpenFilesWorkflow();
		else if ([scenario isEqualToString:@"deletion-contracts"])
			TestDeletionContracts();
		else if ([scenario isEqualToString:@"storage-transitions"])
			TestStorageTransitions();
		else if ([scenario isEqualToString:@"fsevents-live"])
			TestLiveFSEvents();
		else if ([scenario isEqualToString:@"fsevents-writer-child"])
			TestFSEventsWriterChild();
		else if ([scenario isEqualToString:@"filename-collisions"])
			TestFilenameCollisions();
		else if ([scenario isEqualToString:@"concurrent-controllers"])
			TestConcurrentControllers();
		else if ([scenario isEqualToString:@"plain-text-encodings"])
			TestPlainTextEncodings();
		else if ([scenario isEqualToString:@"filesystem-crud"])
			TestFilesystemCRUD();
		else if ([scenario isEqualToString:@"rename-without-preflight"])
			TestRenameSkipsExistencePreflight();
		else if ([scenario isEqualToString:@"rename-enoent-source-proof"])
			TestRenameENOENTRequiresMissingSource();
		else if ([scenario isEqualToString:@"rtf"])
			TestStorageFormat(RTFTextFormat);
		else if ([scenario isEqualToString:@"html"])
			TestStorageFormat(HTMLFormat);
		else if ([scenario isEqualToString:@"directory-identity"])
			TestDirectoryIdentity();
		else if ([scenario isEqualToString:@"directory-relocation-races"])
			TestDirectoryRelocationRaces();
		else if ([scenario isEqualToString:@"location-migration"])
			TestLocationMigration();
		else if ([scenario isEqualToString:@"preferences-migration"])
			TestPreferencesMigration();
		else if ([scenario isEqualToString:@"deep-directory"])
			TestDeepDirectory();
		else if ([scenario isEqualToString:@"atomic-rollback"])
			TestAtomicRollback();
		else if ([scenario isEqualToString:@"reference-edges"])
			TestReferenceEdges();
		else if ([scenario isEqualToString:@"legacy-fixtures"])
			TestLegacyFixtures();
		else if ([scenario isEqualToString:@"encryption"])
			TestEncryption();
		else if ([scenario isEqualToString:@"trash"])
			TestTrash();
		else if ([scenario isEqualToString:@"failures"])
			TestFailures();
		else
			REQUIRE(!"unknown integration-test scenario");
	} @catch (NSException *exception) {
		NSLog(@"%@", exception);
		result = 1;
	}

	[pool drain];
	return result;
}
