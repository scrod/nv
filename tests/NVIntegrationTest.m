#import <Cocoa/Cocoa.h>

#import "../FrozenNotation.h"
#import "../AppController.h"
#import "../GlobalPrefs.h"
#import "../StartupRecovery.h"
#import "../NotationController.h"
#import "../NotationDirectoryManager.h"
#import "NVRootedDirectoryTestHooks.h"
#import "../NotationPrefs.h"
#import "../NotationSyncServiceManager.h"
#import "../PassphraseRetriever.h"
#import "../DeletionManager.h"
#import "../NoteObject.h"
#import "../ExternalEditingSession/ExternalEditingSession.h"
#import "../ExternalEditorListController.h"
#import "../TemporaryFileCachePreparer.h"
#import "../WALController.h"
#import "../NSFileManager_NV.h"
#import "../NSData_transformations.h"
#import "../ImportingUtils.h"

#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#import <objc/runtime.h>

extern char **environ;


@class AlienNoteImporter;

@interface ExternalEditingSession (NVTesting)
- (NSString*)createScratchFileNamed:(NSString*)filename data:(NSData*)data;
- (BOOL)processScratchFileAtPath:(NSString*)path endingSession:(BOOL)endingSession;
- (void)stopScratchWatcher;
- (void)openDidCompleteForSessionPath:(NSString*)path application:(NSRunningApplication*)application;
- (void)checkFinishRequests;
- (BOOL)openURL:(NSURL*)URL inEditor:(ExternalEditor*)editor sessionPath:(NSString*)sessionPath;
@end

@interface WALStorageController (NVTesting)
- (BOOL)writeNoteObject:(id<SynchronizedNote>)object;
@end

@interface WALRecoveryController (NVTesting)
- (NSDictionary*)recoveredNotesWithIncompleteRecovery:(BOOL*)incomplete;
@end

@interface NVScratchRaceNote : NoteObject {
	NSData *raceReplacementData;
}
- (void)replaceScratchDuringNextMergeWithData:(NSData*)data;
@end

@implementation NVScratchRaceNote
- (void)dealloc {
	[raceReplacementData release];
	[super dealloc];
}
- (void)replaceScratchDuringNextMergeWithData:(NSData*)data {
	[data retain];
	[raceReplacementData release];
	raceReplacementData = data;
}
- (BOOL)externalEditingSession:(ExternalEditingSession*)editor didModifyFileData:(NSData*)data
	baseData:(NSData*)baseData path:(NSString*)path context:(NSDictionary*)context {
	BOOL accepted = [super externalEditingSession:editor didModifyFileData:data
		baseData:baseData path:path context:context];
	if (raceReplacementData) {
		NSData *replacement = [[raceReplacementData retain] autorelease];
		[raceReplacementData release];
		raceReplacementData = nil;
		if (![replacement writeToFile:path options:NSDataWritingAtomic error:NULL])
			[NSException raise:NSInternalInconsistencyException
				format:@"Could not inject scratch-file save race at %@", path];
	}
	return accepted;
}
@end

@interface NVTestExternalEditor : ExternalEditor {
	BOOL editsDirectly;
}
- (id)initWithDirectEditing:(BOOL)direct;
@end

@implementation NVTestExternalEditor
- (id)initWithDirectEditing:(BOOL)direct {
	self = [super initWithBundleID:@"com.notationalvelocity.integration-test-editor"
		resolvedURL:[NSURL fileURLWithPath:@"/Applications/Test Editor.app"]];
	if (self) editsDirectly = direct;
	return self;
}
- (BOOL)canEditNoteDirectly:(NoteObject*)note { (void)note; return editsDirectly; }
@end

extern NSString *NVMergedText(NSString *base, NSString *local, NSString *external);

void FSEventsCallback(ConstFSEventStreamRef stream, void *info, size_t numEvents,
	void *eventPaths, const FSEventStreamEventFlags flags[],
	const FSEventStreamEventId eventIDs[]);

#define REQUIRE(condition) do { \
	if (!(condition)) \
		[NSException raise:NSInternalInconsistencyException \
					format:@"%s:%d: requirement failed: %s", __FILE__, __LINE__, #condition]; \
} while (0)

static NSString *CreateTestScratchFile(ExternalEditingSession *editor,
	NSString *name, NSData *data) {
	TemporaryFileCachePreparer *preparer = [editor valueForKey:@"editingSpacePreparer"];
	NVRootedDirectory *directory = [preparer preparedDirectory];
	NVFileWriteResult *result = [directory createFileNamed:name withData:data];
	REQUIRE([result disposition] == NVFileWriteInstalledVerified);
	NSString *path = [[directory transientFileReferenceURLForFileNamed:name error:NULL] path];
	REQUIRE([path length] > 0);
	return path;
}

static NSMutableDictionary *TestScratchSession(NoteObject *note,
	NSString *path, NSData *data) {
	return [NSMutableDictionary dictionaryWithObjectsAndKeys:
		note, @"client", path, @"path", [path lastPathComponent], @"leafName",
		data, @"data", data, @"mergeBaseData", nil];
}

static NSUInteger controllerDeallocationCount;
static NSUInteger injectedControllerFlushFailures;
static NSUInteger observedInjectedControllerFlushFailures;
static NSUInteger injectedFreshJournalInitializationFailures;
static NSUInteger injectedRecoveryDirectorySyncFailures;
static NSUInteger injectedRecoveryJournalRenameFailures;
static BOOL observeJournalInitializations;
static NSUInteger observedJournalInitializations;
static int injectedJournalFlockError;
static NSModalResponse injectedLegacyRecoveryResponse = NSAlertFirstButtonReturn;
static NSModalResponse injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
static NSUInteger legacyRecoveryPromptCount;
static NSUInteger failedWALRecoveryPromptCount;
static NSUInteger partialWALRecoveryWarningCount;
static NSUInteger legacyRecoveryQuitCount;
static BOOL liveFSEventsEnabled;
static BOOL observeExternalDatabaseInitialization;
static NSUInteger observedExternalDatabaseInitializations;
enum { NVTestJournalingError = -819, NVTestPassCanceledError = -823 };
static IMP originalJournalFlockImplementation;
static IMP originalExternalDatabaseInitializationImplementation;
static IMP originalPassphraseRetrieverImplementation;
static NSData *injectedDatabasePassphrase;
static IMP originalExternalEditorOpenImplementation;
static BOOL interceptExternalEditorOpen;
static NSURL *observedExternalEditorURL;
static NSString *observedExternalEditorSessionPath;
static NSData *EncryptionTestPassphrase(void);

@interface NotationController (StartupRecoveryTesting)
- (BOOL)_synchronizeRecoveryDirectory:(NSError**)error;
@end

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

static void NVObservedExternalDatabaseInitialization(id object, SEL selector,
	NotationPrefs *prefs) {
	if (observeExternalDatabaseInitialization) {
		observedExternalDatabaseInitializations++;
		return;
	}
	((void (*)(id, SEL, NotationPrefs*))originalExternalDatabaseInitializationImplementation)(
		object, selector, prefs);
}

static void InstallExternalDatabaseInitializationObservation(void) {
	if (originalExternalDatabaseInitializationImplementation) return;
	Method method = class_getInstanceMethod([ExternalEditingSession class],
		@selector(initializeDatabase:));
	REQUIRE(method != NULL);
	originalExternalDatabaseInitializationImplementation = method_getImplementation(method);
	method_setImplementation(method, (IMP)NVObservedExternalDatabaseInitialization);
}

static int NVInjectedLoadedUserPassphraseData(id object, SEL selector) {
	if (!injectedDatabasePassphrase)
		return ((int (*)(id, SEL))originalPassphraseRetrieverImplementation)(object, selector);
	Ivar prefsIvar = class_getInstanceVariable([PassphraseRetriever class], "notationPrefs");
	NotationPrefs *prefs = object_getIvar(object, prefsIvar);
	return [prefs canLoadPassphraseData:injectedDatabasePassphrase] ? 1 : 0;
}

static void InstallPassphraseRetrieverInjection(void) {
	if (originalPassphraseRetrieverImplementation) return;
	Method method = class_getInstanceMethod([PassphraseRetriever class],
		@selector(loadedUserPassphraseData));
	REQUIRE(method != NULL);
	originalPassphraseRetrieverImplementation = method_getImplementation(method);
	method_setImplementation(method, (IMP)NVInjectedLoadedUserPassphraseData);
}

static BOOL NVInterceptExternalEditorOpen(id object, SEL selector, NSURL *URL,
	ExternalEditor *editor, NSString *sessionPath) {
	if (!interceptExternalEditorOpen)
		return ((BOOL (*)(id, SEL, NSURL*, ExternalEditor*, NSString*))
			originalExternalEditorOpenImplementation)(object, selector, URL, editor, sessionPath);
	[observedExternalEditorURL release];
	observedExternalEditorURL = [URL retain];
	[observedExternalEditorSessionPath release];
	observedExternalEditorSessionPath = [sessionPath copy];
	return YES;
}

static void InstallExternalEditorOpenInterception(void) {
	if (originalExternalEditorOpenImplementation) return;
	Method method = class_getInstanceMethod([ExternalEditingSession class],
		@selector(openURL:inEditor:sessionPath:));
	REQUIRE(method != NULL);
	originalExternalEditorOpenImplementation = method_getImplementation(method);
	method_setImplementation(method, (IMP)NVInterceptExternalEditorOpen);
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
static void WaitForNextMetadataTickIfNeeded(void);

static BOOL SetTestOpenMetaTagsOnly(NotationController *controller, NSArray *tags,
	NSString *filename, NSError **error) {
	NSURL *URL = [[controller noteDirectory]
		transientFileReferenceURLForFileNamed:filename error:error];
	NSData *data = URL ? [NSPropertyListSerialization dataWithPropertyList:tags
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:error] : nil;
	const char *path = [URL fileSystemRepresentation];
	if (!data || !path || setxattr(path, "com.apple.metadata:kMDItemOMUserTags",
		[data bytes], [data length], 0, 0) < 0) {
		if (error && !*error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
			code:(path ? errno : ENAMETOOLONG) userInfo:nil];
		return NO;
	}
	return YES;
}

static BOOL SetTestOpenMetaTags(NotationController *controller, NSArray *tags,
	NSString *filename, NSError **error) {
	if (!SetTestOpenMetaTagsOnly(controller, tags, filename, error)) return NO;
	NSURL *URL = [[controller noteDirectory]
		transientFileReferenceURLForFileNamed:filename error:error];
	return [URL setResourceValue:NVSemanticTagNames(tags)
		forKey:NSURLTagNamesKey error:error];
}

static BOOL SetTestTextEncoding(NotationController *controller, NSStringEncoding encoding,
	NSString *filename, NSError **error) {
	NSURL *URL = [[controller noteDirectory]
		transientFileReferenceURLForFileNamed:filename error:error];
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

@interface NotationController (NVDirectoryPreparationTest)
- (NoteObject*)_preparedNoteForCatalogEntry:(NoteCatalogEntry*)entry
	fallbackNote:(NoteObject*)fallbackNote error:(NSError**)error;
- (BOOL)_readFilesInDirectory;
- (BOOL)_catalogContainsCaseInsensitiveCollision;
- (BOOL)modifyNoteIfNecessary:(NoteObject*)note usingCatalogEntry:(NoteCatalogEntry*)entry;
- (BOOL)processNotesAddedByIdentity:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (BOOL)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (BOOL)_configureDirEventStream;
@end

@interface WALController (NVIntegrationTest)
- (void)_closeLogFile;
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

@interface NVStorageFormatChangeProbe : NSObject {
	int requestedFormat;
	NSUInteger didChangeCount;
	NSUInteger followupCount;
}
- (id)initWithFormat:(int)format;
- (int)notesStorageFormatInProgress;
- (NSUInteger)didChangeCount;
- (NSUInteger)followupCount;
@end

@implementation NVStorageFormatChangeProbe
- (id)initWithFormat:(int)format {
	self = [super init];
	if (self) requestedFormat = format;
	return self;
}
- (int)notesStorageFormatInProgress { return requestedFormat; }
- (void)notesStorageFormatDidChange { didChangeCount++; }
- (void)runQueuedStorageFormatChangeInvocation { followupCount++; }
- (NSUInteger)didChangeCount { return didChangeCount; }
- (NSUInteger)followupCount { return followupCount; }
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

@interface AppController (NVLaunchDirectoryTesting)
- (void)application:(NSApplication*)sender openFiles:(NSArray*)filenames;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
@end

@interface NVLaunchDirectoryPrefs : GlobalPrefs
@end

@implementation NVLaunchDirectoryPrefs
- (void)registerWithTarget:(id)sender forChangesInSettings:(SEL)firstSEL, ... {
	(void)sender;
	(void)firstSEL;
}
@end

@interface NVLaunchDirectoryAppController : AppController {
	NSArray *importedLaunchPaths;
}
- (NSArray*)importedLaunchPaths;
- (NSURL*)currentNotesDirectoryURL;
- (void)closeForTesting;
@end

@implementation NVLaunchDirectoryAppController
- (id)init {
	self = [super init];
	if (self) {
		prefsController = [[NVLaunchDirectoryPrefs alloc] init];
		windowUndoManager = [[NSUndoManager alloc] init];
	}
	return self;
}
- (void)restoreListStateUsingPreferences {}
- (BOOL)importFilePaths:(NSArray*)paths usingImporter:(AlienNoteImporter*)importer {
	(void)importer;
	[importedLaunchPaths release];
	importedLaunchPaths = [paths copy];
	return YES;
}
- (NSArray*)importedLaunchPaths { return importedLaunchPaths; }
- (NSURL*)currentNotesDirectoryURL { return [notationController noteDirectoryURL]; }
- (void)closeForTesting {
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[NSObject cancelPreviousPerformRequestsWithTarget:notationController];
	[notationController setDelegate:nil];
	[notationController closeAllResources];
	[notationController release];
	notationController = nil;
	[pathsToOpenOnLaunch release];
	pathsToOpenOnLaunch = nil;
}
- (void)dealloc {
	[self closeForTesting];
	[importedLaunchPaths release];
	[prefsController release];
	prefsController = nil;
	[[NSAppleEventManager sharedAppleEventManager] removeEventHandlerForEventClass:
		kInternetEventClass andEventID:kAEGetURL];
	[super dealloc];
}
@end

@interface NVSelectionAppController : AppController
- (id)initForTestingWithCurrentNote:(NoteObject*)note;
@end

@implementation NVSelectionAppController
- (id)initForTestingWithCurrentNote:(NoteObject*)note {
	currentNote = [note retain];
	return self;
}
- (void)dealloc {
	[currentNote release];
	currentNote = nil;
	[super dealloc];
}
@end

@interface NVTestRunningApplication : NSObject {
	BOOL terminated;
	pid_t processIdentifier;
}
@property(nonatomic, getter=isTerminated) BOOL terminated;
- (id)initWithProcessIdentifier:(pid_t)identifier;
- (pid_t)processIdentifier;
@end

@implementation NVTestRunningApplication
- (id)initWithProcessIdentifier:(pid_t)identifier {
	self = [super init];
	if (self) processIdentifier = identifier;
	return self;
}
- (BOOL)isTerminated { return terminated; }
- (void)setTerminated:(BOOL)value {
	if (terminated == value) return;
	terminated = value;
	if (value) [[[NSWorkspace sharedWorkspace] notificationCenter]
		postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
		userInfo:@{ NSWorkspaceApplicationKey: self }];
}
- (pid_t)processIdentifier { return processIdentifier; }
- (BOOL)isEqual:(id)object {
	return object == self || ([object isKindOfClass:[NVTestRunningApplication class]] &&
		[(NVTestRunningApplication*)object processIdentifier] == processIdentifier);
}
- (NSUInteger)hash { return (NSUInteger)processIdentifier; }
@end

@interface NVTerminationAppController : AppController {
	BOOL confirmsExternalEditingTermination;
	NSUInteger teardownFailures;
}
- (id)initForTestingWithNotationController:(NotationController*)controller;
- (void)setConfirmsExternalEditingTermination:(BOOL)confirms;
- (NSUInteger)teardownFailures;
@end

@interface AppController (NVTerminationTesting)
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)application;
- (BOOL)windowShouldClose:(id)sender;
- (BOOL)_externalEditingQuitResponseShouldTerminate:(NSModalResponse)response;
- (void)_confirmQuittingExternalEditingWithCompletionHandler:
	(void (^)(BOOL shouldQuit))completionHandler;
@end

@implementation NVTerminationAppController
- (id)initForTestingWithNotationController:(NotationController*)controller {
	notationController = [controller retain];
	waitedForUncommittedChanges = YES;
	return self;
}
- (void)setConfirmsExternalEditingTermination:(BOOL)confirms {
	confirmsExternalEditingTermination = confirms;
}
- (void)externalEditingSessionTeardownFailed { teardownFailures++; }
- (NSUInteger)teardownFailures { return teardownFailures; }
- (void)_confirmQuittingExternalEditingWithCompletionHandler:
	(void (^)(BOOL shouldQuit))completionHandler {
	BOOL shouldQuit = confirmsExternalEditingTermination;
	dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(shouldQuit); });
}
- (void)dealloc {
	[notationController release];
	notationController = nil;
	[super dealloc];
}
@end

@interface NVTerminationApplication : NSObject {
	BOOL receivedReply;
	BOOL terminationReply;
	ExternalEditingSession *editor;
	id client;
	BOOL sessionActiveAtReply;
}
- (id)initWithEditor:(ExternalEditingSession*)anEditor client:(id)aClient;
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate;
- (BOOL)receivedReply;
- (BOOL)terminationReply;
- (BOOL)sessionActiveAtReply;
@end

@implementation NVTerminationApplication
- (id)initWithEditor:(ExternalEditingSession*)anEditor client:(id)aClient {
	self = [super init];
	if (self) {
		editor = anEditor;
		client = aClient;
	}
	return self;
}
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate {
	sessionActiveAtReply = editor && [editor hasActiveScratchEditingSessionForClient:client];
	receivedReply = YES;
	terminationReply = shouldTerminate;
}
- (BOOL)receivedReply { return receivedReply; }
- (BOOL)terminationReply { return terminationReply; }
- (BOOL)sessionActiveAtReply { return sessionActiveAtReply; }
@end

static char NVPreparedNoteDeallocationProbeKey;

@interface NotationController (NVIntegrationRootedInitialization)
- (id)_initWithRootedDirectory:(NVRootedDirectory*)directory
	recoveredNotes:(NSDictionary*)recoveredNotes stagingRecovery:(BOOL)stagingRecovery
	error:(OSStatus*)error;
@end

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
	BOOL snapshotCocoaTagsUnavailable;
	BOOL failCocoaTagWrites;
	NSString *extendedAttributeReadFailureName;
	BOOL extendedAttributeReadFailureDuringValueRead;
	NSUInteger extendedAttributeReadFailuresRemaining;
	BOOL forceExclusiveRenameUnavailable;
	NSUInteger temporaryRemovalFailures;
	NSString *forcedTemporaryFilename;
	NSString *installedBoundaryMutationName;
	NSData *installedBoundaryReplacementData;
	NSString *preInstallBoundaryMutationName;
	NSData *preInstallBoundaryReplacementData;
	NSString *preInstallBoundaryRemovalName;
	NSString *postExchangeBoundaryMutationName;
	NSData *postExchangeBoundaryReplacementData;
	NSString *postExchangeBoundaryRemovalName;
	NSString *exchangedMetadataFailureName;
	NSString *inPlaceBoundaryMutationName;
	NSData *inPlaceBoundaryReplacementData;
	BOOL mutateDuringTagSynchronization;
	BOOL mutateDuringEncodingSynchronization;
	NSString *removeBeforeRenameExistenceCheckName;
	NSUInteger renameExistenceCheckCount;
	NSString *removeRenameCollisionDestinationName;
	NSUInteger noteRenameFailures;
	NSUInteger noteStoreFailures;
	NSString *noteStoreFailureName;
	NSURL *lastTrashedURL;
	BOOL forceTrashFailure;
	BOOL useTestTrash;
	NSUInteger trashMoveCount;
	NSUInteger externalEditingDurabilityFailures;
	NSUInteger directorySynchronizationFailures;
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
- (BOOL)journalFileStillExists;
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
- (void)setSnapshotCocoaTagsUnavailable:(BOOL)unavailable;
- (void)setFailCocoaTagWrites:(BOOL)fail;
- (void)failNextExtendedAttributeReadNamed:(NSString*)name readingValue:(BOOL)readingValue;
- (void)forceNextExclusiveRenameUnavailable;
- (void)failNextTemporaryRemoval;
- (void)useTemporaryFilename:(NSString*)filename;
- (void)replaceInstalledNoteNamed:(NSString*)filename withData:(NSData*)data;
- (void)replaceNoteNamed:(NSString*)filename beforeInstallWithData:(NSData*)data;
- (void)removeNoteNamedBeforeInstall:(NSString*)filename;
- (void)replaceNoteNamed:(NSString*)filename afterExchangeWithData:(NSData*)data;
- (void)removeNoteNamedAfterExchange:(NSString*)filename;
- (void)failExchangedMetadataFinalizationForNoteNamed:(NSString*)filename;
- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringTagSynchronization:(BOOL)tags;
- (void)mutateNoteNamed:(NSString*)filename withData:(NSData*)data duringEncodingSynchronization:(BOOL)encoding;
- (void)removeNoteBeforeRenameExistenceCheck:(NSString*)filename;
- (NSUInteger)renameExistenceCheckCount;
- (void)removeRenameCollisionDestination:(NSString*)filename;
- (void)failNextNoteRename;
- (void)failNextNoteStore;
- (void)failNextNoteStoreNamed:(NSString*)filename;
- (NSURL*)lastTrashedURL;
- (void)setForceTrashFailure:(BOOL)force;
- (void)setUseTestTrash:(BOOL)use;
- (NSUInteger)trashMoveCount;
- (void)setExternalEditingDurabilityFailures:(NSUInteger)failures;
- (void)failNextDirectorySynchronization;
- (BOOL)databaseChangesPending;
- (void)restoreDeletionCandidates;
- (void)processDeletionCandidates;
@end

@implementation NVTestNotationController

- (id)_initWithRootedDirectory:(NVRootedDirectory*)directory
	recoveredNotes:(NSDictionary*)recoveredNotes stagingRecovery:(BOOL)stagingRecovery
	error:(OSStatus*)error {
	self = [super _initWithRootedDirectory:directory recoveredNotes:recoveredNotes
		stagingRecovery:stagingRecovery error:error];
	if (self && [directory isKindOfClass:[NVTestRootedDirectory class]])
		[(NVTestRootedDirectory*)directory setHookTarget:self];
	return self;
}

- (NVRootedDirectory*)newRootedDirectoryForURL:(NSURL*)URL error:(NSError**)error {
	NVTestRootedDirectory *root = [[NVTestRootedDirectory alloc]
		initWithFileReferenceURL:URL error:error];
	[root setHookTarget:self];
	return root;
}

- (NSModalResponse)_legacyDatabaseRecoveryResponse {
	legacyRecoveryPromptCount++;
	return injectedLegacyRecoveryResponse;
}

- (NSModalResponse)_failedWALRecoveryResponse {
	failedWALRecoveryPromptCount++;
	return injectedFailedWALRecoveryResponse;
}

- (void)_showPartialWALRecoveryWarning {
	partialWALRecoveryWarningCount++;
}

- (void)_quitAfterDecliningLegacyDatabaseRecovery {
	legacyRecoveryQuitCount++;
}

- (BOOL)flushAllNoteChanges {
	if (injectedControllerFlushFailures) {
		injectedControllerFlushFailures--;
		observedInjectedControllerFlushFailures++;
		return NO;
	}
	return [super flushAllNoteChanges];
}

- (BOOL)initializeJournaling {
	if (observeJournalInitializations) observedJournalInitializations++;
	if (injectedFreshJournalInitializationFailures &&
		![[self noteDirectory] regularFileExistsNamed:NVJournalFilename]) {
		injectedFreshJournalInitializationFailures--;
		return NO;
	}
	return [super initializeJournaling];
}

- (BOOL)_synchronizeRecoveryDirectory:(NSError**)error {
	if (injectedRecoveryDirectorySyncFailures) {
		injectedRecoveryDirectorySyncFailures--;
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
		return NO;
	}
	return [super _synchronizeRecoveryDirectory:error];
}

- (BOOL)_consumeRenameFailureFromName:(NSString*)oldName toName:(NSString*)newName
	error:(NSError**)error {
	if (noteRenameFailures) {
		noteRenameFailures--;
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
		return YES;
	}
	if (injectedRecoveryJournalRenameFailures &&
		[oldName isEqualToString:NVJournalFilename] &&
		[newName rangeOfString:@" recovery "].location != NSNotFound) {
		injectedRecoveryJournalRenameFailures--;
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
		return YES;
	}
	return NO;
}

- (NVFileWriteResult*)_injectedNoteStoreFailureForName:(NSString*)filename {
	if (noteStoreFailures && (!noteStoreFailureName ||
		[noteStoreFailureName isEqualToString:filename])) {
		noteStoreFailures--;
		[noteStoreFailureName release];
		noteStoreFailureName = nil;
		return [[[NVFileWriteResult alloc] initWithDisposition:NVFileWriteNotInstalled
			capability:NVFileWriteStrongAtomicCapability installedSnapshot:nil
			error:[NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]
			recoveryFilename:nil] autorelease];
	}
	return nil;
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

- (NSNumber*)_injectedExistenceResultForName:(NSString*)filename {
	renameExistenceCheckCount++;
	if ([filename isEqualToString:removeBeforeRenameExistenceCheckName]) {
		REQUIRE([[self noteDirectory] removeFileNamed:filename error:NULL]);
		[removeBeforeRenameExistenceCheckName release];
		removeBeforeRenameExistenceCheckName = nil;
		return @YES;
	}
	return nil;
}

- (NSUInteger)renameExistenceCheckCount {
	return renameExistenceCheckCount;
}

- (BOOL)_shouldFailTrashForTesting { return forceTrashFailure; }
- (BOOL)_usesTestTrashForTesting { return useTestTrash; }
- (void)_didUseTestTrash { trashMoveCount++; }
- (void)_didTrashURLForTesting:(NSURL*)URL {
	[lastTrashedURL release];
	lastTrashedURL = [URL retain];
}

- (NSURL*)lastTrashedURL { return lastTrashedURL; }
- (void)setForceTrashFailure:(BOOL)force { forceTrashFailure = force; }
- (void)setUseTestTrash:(BOOL)use { useTestTrash = use; }
- (NSUInteger)trashMoveCount { return trashMoveCount; }
- (void)failNextExtendedAttributeReadNamed:(NSString*)name readingValue:(BOOL)readingValue {
	[extendedAttributeReadFailureName release];
	extendedAttributeReadFailureName = [name copy];
	extendedAttributeReadFailureDuringValueRead = readingValue;
	extendedAttributeReadFailuresRemaining = 1;
}
- (int)_extendedAttributeReadErrorForName:(const char*)name readingValue:(BOOL)readingValue {
	if (!extendedAttributeReadFailuresRemaining || !extendedAttributeReadFailureName ||
		![extendedAttributeReadFailureName isEqualToString:[NSString stringWithUTF8String:name]] ||
		extendedAttributeReadFailureDuringValueRead != readingValue) return 0;
	if (!--extendedAttributeReadFailuresRemaining) {
		[extendedAttributeReadFailureName release];
		extendedAttributeReadFailureName = nil;
	}
	return EIO;
}
- (void)forceNextExclusiveRenameUnavailable { forceExclusiveRenameUnavailable = YES; }
- (int)_exclusiveRenameErrorForFileNamed:(NSString*)filename {
	(void)filename;
	if (!forceExclusiveRenameUnavailable) return 0;
	forceExclusiveRenameUnavailable = NO;
	return ENOTSUP;
}
- (void)failNextTemporaryRemoval { temporaryRemovalFailures++; }
- (int)_temporaryRemovalErrorForFileNamed:(NSString*)filename {
	(void)filename;
	if (!temporaryRemovalFailures) return 0;
	temporaryRemovalFailures--;
	return EIO;
}
- (void)useTemporaryFilename:(NSString*)filename {
	[forcedTemporaryFilename release];
	forcedTemporaryFilename = [filename copy];
}
- (NSString*)_temporaryFilenameForFileNamed:(NSString*)filename {
	(void)filename;
	NSString *result = [[forcedTemporaryFilename retain] autorelease];
	[forcedTemporaryFilename release];
	forcedTemporaryFilename = nil;
	return result;
}
- (void)setExternalEditingDurabilityFailures:(NSUInteger)failures {
	externalEditingDurabilityFailures = failures;
}
- (void)failNextDirectorySynchronization { directorySynchronizationFailures++; }
- (int)_directorySynchronizationError {
	if (!directorySynchronizationFailures) return 0;
	directorySynchronizationFailures--;
	return EIO;
}
- (BOOL)databaseChangesPending { return notesChanged; }
- (BOOL)makeNoteDurableForExternalEditing:(NoteObject*)note {
	if (externalEditingDurabilityFailures) {
		externalEditingDurabilityFailures--;
		return NO;
	}
	return [super makeNoteDurableForExternalEditing:note];
}
- (void)restoreDeletionCandidates { [deletionManager restoreAction:nil]; }
- (void)processDeletionCandidates { [deletionManager processDeletedNotes]; }

- (void)removeRenameCollisionDestination:(NSString*)filename {
	[removeRenameCollisionDestinationName release];
	removeRenameCollisionDestinationName = [filename copy];
}

- (void)failNextNoteRename { noteRenameFailures++; }
- (void)failNextNoteStore { noteStoreFailures++; }
- (void)failNextNoteStoreNamed:(NSString*)filename {
	noteStoreFailures++;
	[noteStoreFailureName release];
	noteStoreFailureName = [filename copy];
}

- (void)_didObserveRenameCollisionFromName:(NSString*)oldName toName:(NSString*)newName {
	(void)oldName;
	if (![newName isEqualToString:removeRenameCollisionDestinationName]) return;
	REQUIRE([[self noteDirectory] removeFileNamed:newName error:NULL]);
	[removeRenameCollisionDestinationName release];
	removeRenameCollisionDestinationName = nil;
}

- (OSStatus)atomicVerificationResult {
	return atomicVerificationResult;
}

- (NSUInteger)directoryStreamNoteCount {
	BOOL previous = forceFoundationEnumeration;
	forceFoundationEnumeration = YES;
	BOOL succeeded = [self _readFilesInDirectory];
	forceFoundationEnumeration = previous;
	if (!succeeded) return NSNotFound;
	NSUInteger allowedCount = 0;
	NVRootedDirectoryCatalog *catalog = directoryCatalog;
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++)
		if ([notationPrefs catalogEntryAllowed:&entries[index]]) allowedCount++;
	return allowedCount;
}

- (void)_didUseFoundationCatalogEnumeration { foundationEnumerationCount++; }

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
	NVRootedDirectoryCatalog *catalog = directoryCatalog;
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++)
		if ([notationPrefs catalogEntryAllowed:&entries[index]]) allowedCount++;
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
	NVRootedDirectoryCatalog *catalog = directoryCatalog;
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++)
		if ([notationPrefs catalogEntryAllowed:&entries[index]]) publishedCount++;
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
	[walWriter _closeLogFile];
}

- (BOOL)journalFileStillExists { return [walWriter logFileStillExists]; }

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
	/* Most scenarios run synchronously on the main thread, so dispatch-queue
	 * FSEvents teardown cannot release its final callback retain until the scenario
	 * returns.  Only the live FSEvents scenario needs an OS subscription. */
	if (!liveFSEventsEnabled) return YES;
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
	NVRootedDirectoryCatalog *catalog = directoryCatalog;
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++)
		if ([(NSString*)entries[index].filename isEqualToString:filename])
			return entries[index].documentID;
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

- (void)_didReadNoteDataForTesting { noteDataReadCount++; }

- (BOOL)_shouldFailSnapshotNamed:(NSString*)filename error:(NSError**)error {
	if ([filename isEqualToString:failingSnapshotName]) {
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
		return YES;
	}
	return NO;
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
	if (snapshotCocoaTagsUnavailable) return nil;
	if (snapshotBoundaryObservedTags &&
		[[URL lastPathComponent] isEqualToString:snapshotBoundaryMutationName])
		return snapshotBoundaryObservedTags;
	id tags = nil;
	return [URL getResourceValue:&tags forKey:NSURLTagNamesKey error:NULL] ? (tags ?: @[]) : nil;
}

- (void)setSnapshotCocoaTagsUnavailable:(BOOL)unavailable {
	snapshotCocoaTagsUnavailable = unavailable;
}

- (void)setFailCocoaTagWrites:(BOOL)fail {
	failCocoaTagWrites = fail;
}

- (BOOL)_setCocoaTags:(NSArray*)tags atURL:(NSURL*)URL error:(NSError**)error {
	if (!failCocoaTagWrites)
		return [URL setResourceValue:tags forKey:NSURLTagNamesKey error:error];
	if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
		code:EOPNOTSUPP userInfo:nil];
	return NO;
}

- (int)_snapshotStatErrorAfterPreparingName:(const char*)name {
	snapshotAttemptCount++;
	if (transientSnapshotFailures) {
		transientSnapshotFailures--;
		return EAGAIN;
	}
	NSString *filename = [NSString stringWithUTF8String:name];
	if (snapshotBoundaryReplacementData && snapshotBoundaryMutationsRemaining &&
		[filename isEqualToString:snapshotBoundaryMutationName]) {
		REQUIRE([[[self noteDirectory] overwriteFileNamed:filename
			withData:snapshotBoundaryReplacementData] disposition] ==
			NVFileWriteInstalledVerified);
			snapshotBoundaryMutationsRemaining--;
	}
	return 0;
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
	NSFileHandle *handle = [[[NSFileHandle alloc] initWithFileDescriptor:fileDescriptor
		closeOnDealloc:NO] autorelease];
	return [[self noteDirectory] fileHandle:handle isStillNamed:[URL lastPathComponent]];
}

- (void)replaceInstalledNoteNamed:(NSString*)filename withData:(NSData*)data {
	[installedBoundaryMutationName release];
	[installedBoundaryReplacementData release];
	installedBoundaryMutationName = [filename copy];
	installedBoundaryReplacementData = [data retain];
}

- (void)_didInstallNoteFileNamed:(NSString*)filename {
	if ([filename isEqualToString:installedBoundaryMutationName]) {
		NSData *replacementData = [installedBoundaryReplacementData retain];
		[installedBoundaryMutationName release];
		[installedBoundaryReplacementData release];
		installedBoundaryMutationName = nil;
		installedBoundaryReplacementData = nil;
		REQUIRE([[[self noteDirectory] overwriteFileNamed:filename
			withData:replacementData] disposition] ==
			NVFileWriteInstalledVerified);
		[replacementData release];
	}
}

- (void)replaceNoteNamed:(NSString*)filename beforeInstallWithData:(NSData*)data {
	[preInstallBoundaryMutationName release];
	[preInstallBoundaryReplacementData release];
	preInstallBoundaryMutationName = [filename copy];
	preInstallBoundaryReplacementData = [data retain];
}

- (void)removeNoteNamedBeforeInstall:(NSString*)filename {
	[preInstallBoundaryRemovalName release];
	preInstallBoundaryRemovalName = [filename copy];
}

- (void)replaceNoteNamed:(NSString*)filename afterExchangeWithData:(NSData*)data {
	[postExchangeBoundaryMutationName release];
	[postExchangeBoundaryReplacementData release];
	postExchangeBoundaryMutationName = [filename copy];
	postExchangeBoundaryReplacementData = [data retain];
}

- (void)removeNoteNamedAfterExchange:(NSString*)filename {
	[postExchangeBoundaryRemovalName release];
	postExchangeBoundaryRemovalName = [filename copy];
}

- (void)failExchangedMetadataFinalizationForNoteNamed:(NSString*)filename {
	[exchangedMetadataFailureName release];
	exchangedMetadataFailureName = [filename copy];
}

- (void)_didPrepareNoteFileNamed:(NSString*)filename {
	if ([filename isEqualToString:preInstallBoundaryMutationName]) {
		NSData *replacement = [[preInstallBoundaryReplacementData retain] autorelease];
		[preInstallBoundaryMutationName release];
		[preInstallBoundaryReplacementData release];
		preInstallBoundaryMutationName = nil;
		preInstallBoundaryReplacementData = nil;
		REQUIRE([[[self noteDirectory] overwriteFileNamed:filename withData:replacement]
			disposition] == NVFileWriteInstalledVerified);
	}
}

- (void)_didRejectAtomicSwapForNoteNamed:(NSString*)filename {
	if ([filename isEqualToString:preInstallBoundaryRemovalName]) {
		[preInstallBoundaryRemovalName release];
		preInstallBoundaryRemovalName = nil;
		REQUIRE([[self noteDirectory] removeFileNamed:filename error:NULL]);
	}
}

- (void)_didExchangeNoteFileNamed:(NSString*)filename {
	if ([filename isEqualToString:postExchangeBoundaryRemovalName]) {
		[postExchangeBoundaryRemovalName release];
		postExchangeBoundaryRemovalName = nil;
		REQUIRE([[self noteDirectory] removeFileNamed:filename error:NULL]);
		return;
	}
	if ([filename isEqualToString:postExchangeBoundaryMutationName]) {
		NSData *replacement = [[postExchangeBoundaryReplacementData retain] autorelease];
		[postExchangeBoundaryMutationName release];
		[postExchangeBoundaryReplacementData release];
		postExchangeBoundaryMutationName = nil;
		postExchangeBoundaryReplacementData = nil;
		REQUIRE([[[self noteDirectory] overwriteFileNamed:filename withData:replacement]
			disposition] == NVFileWriteInstalledVerified);
	}
}

- (int)_metadataFinalizationErrorAfterExchangingNoteNamed:(NSString*)filename {
	if (![filename isEqualToString:exchangedMetadataFailureName]) return 0;
	[exchangedMetadataFailureName release];
	exchangedMetadataFailureName = nil;
	return EIO;
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
	NSFileHandle *mutationHandle = [[self noteDirectory]
		openExistingRegularFileForUpdatingNamed:filename error:NULL];
	REQUIRE(mutationHandle != nil);
	int mutationFD = [mutationHandle fileDescriptor];
	struct stat status, mutationStatus;
	REQUIRE(mutationFD >= 0 && fstat(fileDescriptor, &status) == 0 &&
		fstat(mutationFD, &mutationStatus) == 0 && status.st_dev == mutationStatus.st_dev &&
		status.st_ino == mutationStatus.st_ino);
	REQUIRE((off_t)[inPlaceBoundaryReplacementData length] == status.st_size);
	REQUIRE(pwrite(mutationFD, [inPlaceBoundaryReplacementData bytes],
		[inPlaceBoundaryReplacementData length], 0) == (ssize_t)[inPlaceBoundaryReplacementData length]);
	struct timespec times[2] = { status.st_atimespec, status.st_mtimespec };
	REQUIRE(futimens(mutationFD, times) == 0 && fsync(mutationFD) == 0);
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
	return [(NVTestRootedDirectory*)[self noteDirectory]
		performWithInvalidDirectoryDescriptor:^{ return [self synchronizeNotesFromDirectory]; }];
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
		NSFileHandle *handle = [[self noteDirectory]
			openExistingRegularFileForUpdatingNamed:mutationBeforeFenceName error:NULL];
		REQUIRE(handle != nil);
		int fd = [handle fileDescriptor];
		REQUIRE(fd >= 0);
		REQUIRE(ftruncate(fd, 0) == 0);
		REQUIRE(write(fd, [mutationBeforeFenceData bytes], [mutationBeforeFenceData length]) ==
			(ssize_t)[mutationBeforeFenceData length]);
		REQUIRE(fsync(fd) == 0);
		[mutationBeforeFenceName release];
		[mutationBeforeFenceData release];
		mutationBeforeFenceName = nil;
		mutationBeforeFenceData = nil;
	}
	if (!syntheticCatalogNames) return [super _readFilesInDirectory];
	NVRootedDirectoryCatalog *catalog = [[NVRootedDirectoryCatalog alloc] init];
	for (NSString *name in syntheticCatalogNames)
		REQUIRE([catalog appendOwnedFilename:(CFStringRef)[name copy]
			attributeChangeTime:(struct timespec){ 0 } documentID:0 fileID:0 generationCount:0]);
	[directoryCatalog release];
	directoryCatalog = catalog;
	return YES;
}

- (void)resetCatalogReadCount { catalogReadCount = 0; }
- (NSUInteger)catalogReadCount { return catalogReadCount; }

- (BOOL)_shouldFailObservationNamed:(NSString*)filename error:(NSError**)error {
	if (missingMetadataFailuresRemaining && [filename isEqualToString:missingMetadataName]) {
		missingMetadataFailuresRemaining--;
		if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
		return YES;
	}
	return NO;
}

- (BOOL)foundationScanRetriesThenRejectsVanishedFilename:(NSString*)filename {
	[missingMetadataName release];
	missingMetadataName = [filename copy];
	missingMetadataFailuresRemaining = 1;
	BOOL previous = forceFoundationEnumeration;
	forceFoundationEnumeration = YES;
	BOOL retrySucceeded = [self _readFilesInDirectory];
	NSUInteger matchingEntries = 0;
	NVRootedDirectoryCatalog *catalog = directoryCatalog;
	NoteCatalogEntry *entries = [catalog entries];
	for (size_t index = 0; index < [catalog count]; index++)
		if ([(NSString*)entries[index].filename isEqualToString:filename]) matchingEntries++;
	missingMetadataFailuresRemaining = 2;
	BOOL persistentSucceeded = [self _readFilesInDirectory];
	BOOL persistentCatalogWasEmpty = !persistentSucceeded;
	forceFoundationEnumeration = previous;
	[missingMetadataName release];
	missingMetadataName = nil;
	missingMetadataFailuresRemaining = 0;
	return retrySucceeded && matchingEntries == 1 && !persistentSucceeded && persistentCatalogWasEmpty;
}

- (BOOL)hasCaseCollisionForNames:(NSArray*)names {
	NVRootedDirectoryCatalog *catalog = [[NVRootedDirectoryCatalog alloc] init];
	for (NSString *name in names)
		REQUIRE([catalog appendOwnedFilename:(CFStringRef)[name copy]
			attributeChangeTime:(struct timespec){ 0 } documentID:0 fileID:0 generationCount:0]);
	[directoryCatalog release];
	directoryCatalog = catalog;
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
	if ([[self noteDirectory] isKindOfClass:[NVTestRootedDirectory class]])
		[(NVTestRootedDirectory*)[self noteDirectory] removeHookTarget:self];
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
	[extendedAttributeReadFailureName release];
	[forcedTemporaryFilename release];
	[installedBoundaryMutationName release];
	[installedBoundaryReplacementData release];
	[preInstallBoundaryMutationName release];
	[preInstallBoundaryReplacementData release];
	[preInstallBoundaryRemovalName release];
	[postExchangeBoundaryMutationName release];
	[postExchangeBoundaryReplacementData release];
	[postExchangeBoundaryRemovalName release];
	[exchangedMetadataFailureName release];
	[inPlaceBoundaryMutationName release];
	[inPlaceBoundaryReplacementData release];
	[removeBeforeRenameExistenceCheckName release];
	[removeRenameCollisionDestinationName release];
	[noteStoreFailureName release];
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

static NSUInteger corruptArchiveDecodeCount;

@implementation NVCorruptArchiveObject

- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }

- (id)initWithCoder:(NSCoder *)coder {
	(void)coder;
	corruptArchiveDecodeCount++;
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

static NVRootedDirectory *RootedDirectoryForPath(NSString *path) {
	NSError *error = nil;
	NVRootedDirectory *directory = [[[NVRootedDirectory alloc]
		initWithFileReferenceURL:FileReferenceURLForPath(path) error:&error] autorelease];
	REQUIRE(directory != nil && error == nil);
	return directory;
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
	return [WALNotesDirectoryPath(rootPath) stringByAppendingPathComponent:NVJournalFilename];
}

static NSData *TestDatabaseData(NSString *text, UInt32 epoch, NSUInteger paddingLength) {
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:text] autorelease]
		title:text format:SingleDatabaseFormat labels:@""];
	NSData *database = [FrozenNotation frozenDataWithExistingNotes:
		[NSMutableArray arrayWithObject:note] deletedNotes:[NSMutableSet set] prefs:prefs];
	NSError *error = nil;
	NSMutableDictionary *archive = [NSPropertyListSerialization propertyListWithData:database
		options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
	NSMutableArray *objects = [archive objectForKey:@"$objects"];
	REQUIRE(note != nil && database != nil && archive != nil && objects != nil && error == nil);
	BOOL replacedEpoch = NO;
	for (id object in objects) {
		if ([object isKindOfClass:[NSMutableDictionary class]] &&
			[object objectForKey:@"epochIteration"]) {
			[object setObject:[NSNumber numberWithUnsignedInt:epoch] forKey:@"epochIteration"];
			replacedEpoch = YES;
		}
	}
	if (paddingLength)
		[objects addObject:[@"x" stringByPaddingToLength:paddingLength withString:@"x" startingAtIndex:0]];
	NSData *result = [NSPropertyListSerialization dataWithPropertyList:archive
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
	REQUIRE(replacedEpoch && result != nil && error == nil);
	[note release];
	[prefs release];
	return result;
}

static void WriteTestFile(NSData *data, NSString *path, time_t modificationTime) {
	NSError *error = nil;
	REQUIRE([data writeToFile:path options:0 error:&error] && error == nil);
	struct timespec times[2] = {
		{ .tv_sec = modificationTime, .tv_nsec = 0 },
		{ .tv_sec = modificationTime, .tv_nsec = 0 }
	};
	REQUIRE(utimensat(AT_FDCWD, [path fileSystemRepresentation], times, 0) == 0);
}

static void SetTestFileModificationTime(NSString *path, time_t seconds, long nanoseconds) {
	struct timespec times[2] = {
		{ .tv_sec = seconds, .tv_nsec = nanoseconds },
		{ .tv_sec = seconds, .tv_nsec = nanoseconds }
	};
	REQUIRE(utimensat(AT_FDCWD, [path fileSystemRepresentation], times, 0) == 0);
}

static NSData *CreateCorruptTestJournal(NSString *directoryPath) {
	int directoryFD = open([directoryPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	REQUIRE(directoryFD >= 0);
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	WALStorageController *writer = [[WALStorageController alloc]
		initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
		encryptionKey:[prefs WALSessionKey]];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"corrupt WAL record"] autorelease]
		title:@"Corrupt WAL" format:SingleDatabaseFormat labels:@""];
	REQUIRE(writer != nil && note != nil && [writer writeEstablishedNote:note] && [writer synchronize]);
	[note release];
	[writer release];
	[prefs release];
	close(directoryFD);

	NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
	NSMutableData *journal = [NSMutableData dataWithContentsOfFile:path];
	REQUIRE([journal length] > 0);
	((uint8_t*)[journal mutableBytes])[[journal length] - 1] ^= 0xFF;
	NSError *error = nil;
	REQUIRE([journal writeToFile:path options:0 error:&error] && error == nil);
	return journal;
}

enum { NVTestWALRecordHeaderLength = 44 };

static NSUInteger WALRecordOffset(NSData *journal, NSUInteger recordIndex) {
	NSUInteger offset = 0;
	for (NSUInteger index = 0; index <= recordIndex; index++) {
		REQUIRE(offset + NVTestWALRecordHeaderLength <= [journal length]);
		if (index == recordIndex) return offset;
		uint32_t storedLength = 0;
		[journal getBytes:&storedLength range:NSMakeRange(offset + sizeof(uint32_t),
			sizeof(storedLength))];
		offset += NVTestWALRecordHeaderLength + CFSwapInt32BigToHost(storedLength);
	}
	return NSNotFound;
}

static NSData *CreateTestJournal(NSString *directoryPath, NSArray *objects) {
	int directoryFD = open([directoryPath fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	REQUIRE(directoryFD >= 0);
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	WALStorageController *writer = [[WALStorageController alloc]
		initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
		encryptionKey:[prefs WALSessionKey]];
	REQUIRE(writer != nil);
	for (id object in objects)
		REQUIRE([writer writeNoteObject:(id<SynchronizedNote>)object]);
	REQUIRE([writer synchronize]);
	[writer release];
	[prefs release];
	close(directoryFD);
	return [NSData dataWithContentsOfFile:
		[directoryPath stringByAppendingPathComponent:NVJournalFilename]];
}

static void CorruptWALChecksum(NSString *directoryPath, NSUInteger recordIndex) {
	NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
	NSMutableData *journal = [NSMutableData dataWithContentsOfFile:path];
	NSUInteger offset = WALRecordOffset(journal, recordIndex);
	uint32_t checksum = 0;
	[journal getBytes:&checksum range:NSMakeRange(offset + 2 * sizeof(uint32_t),
		sizeof(checksum))];
	checksum ^= CFSwapInt32HostToBig(1);
	[journal replaceBytesInRange:NSMakeRange(offset + 2 * sizeof(uint32_t), sizeof(checksum))
		withBytes:&checksum];
	REQUIRE([journal writeToFile:path atomically:NO]);
}

static void UpdateWALPayloadChecksum(NSMutableData *journal, NSUInteger recordOffset,
	NSUInteger payloadLength) {
	NSData *payload = [journal subdataWithRange:NSMakeRange(
		recordOffset + NVTestWALRecordHeaderLength, payloadLength)];
	uint32_t checksum = CFSwapInt32HostToBig((uint32_t)[payload CRC32]);
	[journal replaceBytesInRange:NSMakeRange(recordOffset + 2 * sizeof(uint32_t),
		sizeof(checksum)) withBytes:&checksum];
}

static void CorruptWALCiphertext(NSString *directoryPath, NSUInteger recordIndex,
	BOOL preserveValidEncryption) {
	NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
	NSMutableData *journal = [NSMutableData dataWithContentsOfFile:path];
	NSUInteger offset = WALRecordOffset(journal, recordIndex);
	uint32_t storedLength = 0;
	[journal getBytes:&storedLength range:NSMakeRange(offset + sizeof(uint32_t),
		sizeof(storedLength))];
	NSUInteger payloadLength = CFSwapInt32BigToHost(storedLength);
	NSRange payloadRange = NSMakeRange(offset + NVTestWALRecordHeaderLength, payloadLength);
	NSMutableData *payload = [NSMutableData dataWithData:
		[journal subdataWithRange:payloadRange]];
	if (preserveValidEncryption) {
		NSData *salt = [journal subdataWithRange:NSMakeRange(offset + 3 * sizeof(uint32_t), 32)];
		NotationPrefs *prefs = [[NotationPrefs alloc] init];
		NSData *sessionKey = [prefs WALSessionKey];
		NSData *recordKey = [sessionKey derivedKeyOfLength:(int)[sessionKey length]
			salt:salt iterations:1];
		REQUIRE([payload decryptAESDataWithKey:recordKey
			iv:[salt subdataWithRange:NSMakeRange(0, 16)]]);
		((uint8_t*)[payload mutableBytes])[0] ^= 0xFF;
		REQUIRE([payload encryptAESDataWithKey:recordKey
			iv:[salt subdataWithRange:NSMakeRange(0, 16)]]);
		[prefs release];
	} else {
		NSUInteger bytesToCorrupt = MIN((NSUInteger)16, [payload length]);
		uint8_t *bytes = [payload mutableBytes];
		for (NSUInteger index = 0; index < bytesToCorrupt; index++)
			bytes[[payload length] - 1 - index] ^= (uint8_t)(0xA5 + index);
	}
	REQUIRE([payload length] == payloadLength);
	[journal replaceBytesInRange:payloadRange withBytes:[payload bytes]];
	UpdateWALPayloadChecksum(journal, offset, payloadLength);
	REQUIRE([journal writeToFile:path atomically:NO]);
}

static NoteObject *TestWALNote(NSString *text) {
	return [[[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:text] autorelease]
		title:text format:SingleDatabaseFormat labels:@""] autorelease];
}

typedef NS_ENUM(NSUInteger, NVWALLengthMutation) {
	NVWALLengthTooLarge,
	NVWALLengthHalf,
	NVWALLengthOneByteShort
};

static void SetWALOriginalLength(NSString *directoryPath, NSUInteger recordIndex,
	NVWALLengthMutation mutation) {
	NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
	NSMutableData *journal = [NSMutableData dataWithContentsOfFile:path];
	NSUInteger offset = WALRecordOffset(journal, recordIndex);
	uint32_t storedLength = 0;
	[journal getBytes:&storedLength range:NSMakeRange(offset, sizeof(storedLength))];
	uint32_t length = CFSwapInt32BigToHost(storedLength);
	if (mutation == NVWALLengthTooLarge) length += 100;
	else if (mutation == NVWALLengthHalf) length = MAX(1U, length / 2);
	else length = MAX(1U, length - 1);
	storedLength = CFSwapInt32HostToBig(length);
	[journal replaceBytesInRange:NSMakeRange(offset, sizeof(storedLength)) withBytes:&storedLength];
	REQUIRE([journal writeToFile:path atomically:NO]);
}

static void SetWALOriginalLengthToZero(NSString *directoryPath, NSUInteger recordIndex) {
	NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
	NSMutableData *journal = [NSMutableData dataWithContentsOfFile:path];
	NSUInteger offset = WALRecordOffset(journal, recordIndex);
	uint32_t zero = 0;
	[journal replaceBytesInRange:NSMakeRange(offset, sizeof(zero)) withBytes:&zero];
	REQUIRE([journal writeToFile:path atomically:NO]);
}

static NSDictionary *RecoverTestJournal(NSString *directoryPath, BOOL *incomplete) {
	int directoryFD = open([directoryPath fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	REQUIRE(directoryFD >= 0);
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	WALRecoveryController *reader = [[WALRecoveryController alloc]
		initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
		encryptionKey:[prefs WALSessionKey]
		error:NULL journalInUse:NULL];
	REQUIRE(reader != nil);
	NSDictionary *notes = [[[reader recoveredNotesWithIncompleteRecovery:incomplete]
		retain] autorelease];
	[reader release];
	[prefs release];
	close(directoryFD);
	return notes;
}

static void RemoveTemporaryDirectory(NSString *path);

static BOOL RecoveredNotesContainText(NSDictionary *notes, NSString *text) {
	for (NoteObject *note in [notes allValues])
		if ([[[note contentString] string] rangeOfString:text].location != NSNotFound) return YES;
	return NO;
}

static void TestWALRecordRecovery(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	int directoryFD = -1;
	WALStorageController *writer = nil;
	WALRecoveryController *reader = nil;
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	@try {
		CreateTestJournal(directoryPath, [NSArray array]);
		BOOL incomplete = YES;
		NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
		REQUIRE(!incomplete && [notes count] == 0);
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		directoryFD = open([directoryPath fileSystemRepresentation],
			O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		REQUIRE(directoryFD >= 0);
		writer = [[WALStorageController alloc] initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
			encryptionKey:[prefs WALSessionKey]];
		NoteObject *first = [[[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"recover first"] autorelease]
			title:@"First" format:SingleDatabaseFormat labels:@""] autorelease];
		NoteObject *last = [[[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"recover last"] autorelease]
			title:@"Last" format:SingleDatabaseFormat labels:@""] autorelease];
		REQUIRE(writer != nil);
		corruptArchiveDecodeCount = 0;
		REQUIRE([writer writeNoteObject:first]);
		REQUIRE([writer writeNoteObject:(id<SynchronizedNote>)
			[[[NVCorruptArchiveObject alloc] init] autorelease]]);
		REQUIRE([writer writeNoteObject:last]);
		REQUIRE([writer synchronize]);
		[writer release];
		writer = nil;

		reader = [[WALRecoveryController alloc] initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
			encryptionKey:[prefs WALSessionKey] error:NULL journalInUse:NULL];
		BOOL incomplete = NO;
		NSDictionary *notes = [reader recoveredNotesWithIncompleteRecovery:&incomplete];
		REQUIRE(reader != nil && incomplete);
		REQUIRE([notes count] == 2);
		REQUIRE(corruptArchiveDecodeCount == 1);
		REQUIRE(RecoveredNotesContainText(notes, @"recover first"));
		REQUIRE(RecoveredNotesContainText(notes, @"recover last"));
	} @finally {
		[reader release];
		[writer destroyLogFile];
		[writer release];
		[prefs release];
		if (directoryFD >= 0) close(directoryFD);
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"clean first"), TestWALNote(@"clean last"), nil]);
		BOOL incomplete = YES;
		NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
		REQUIRE(!incomplete && [notes count] == 2);
		REQUIRE(RecoveredNotesContainText(notes, @"clean first"));
		REQUIRE(RecoveredNotesContainText(notes, @"clean last"));
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSUInteger corruptionCase = 0; corruptionCase < 2; corruptionCase++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
				TestWALNote(@"crypto first"), TestWALNote(@"crypto bad"),
				TestWALNote(@"crypto last"), nil]);
			CorruptWALCiphertext(directoryPath, 1, corruptionCase == 1);
			BOOL incomplete = NO;
			NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
			REQUIRE(incomplete && [notes count] == 1);
			REQUIRE(RecoveredNotesContainText(notes, @"crypto first"));
			REQUIRE(!RecoveredNotesContainText(notes, @"crypto last"));
		} @finally {
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	for (NVWALLengthMutation lengthCase = NVWALLengthTooLarge;
		lengthCase <= NVWALLengthOneByteShort; lengthCase++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
				TestWALNote(@"length first"), TestWALNote(@"length bad"),
				TestWALNote(@"length last"), nil]);
			SetWALOriginalLength(directoryPath, 1, lengthCase);
			BOOL incomplete = NO;
			NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
			REQUIRE(incomplete && [notes count] == 2);
			REQUIRE(RecoveredNotesContainText(notes, @"length first"));
			REQUIRE(RecoveredNotesContainText(notes, @"length last"));
			REQUIRE(!RecoveredNotesContainText(notes, @"length bad"));
		} @finally {
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"checksum first"), TestWALNote(@"checksum bad"),
			TestWALNote(@"checksum last"), nil]);
		CorruptWALChecksum(directoryPath, 1);
		BOOL incomplete = NO;
		NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
		REQUIRE(incomplete && [notes count] == 1);
		REQUIRE(RecoveredNotesContainText(notes, @"checksum first"));
		REQUIRE(!RecoveredNotesContainText(notes, @"checksum last"));
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"protocol first"), @"not a synchronized note",
			TestWALNote(@"protocol last"), nil]);
		BOOL incomplete = NO;
		NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
		REQUIRE(incomplete && [notes count] == 2);
		REQUIRE(RecoveredNotesContainText(notes, @"protocol first"));
		REQUIRE(RecoveredNotesContainText(notes, @"protocol last"));
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSUInteger tailCase = 0; tailCase < 2; tailCase++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			NSData *journal = CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
				TestWALNote(@"tail first"), TestWALNote(@"tail last"), nil]);
			NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
			NSMutableData *truncated = [NSMutableData dataWithData:journal];
			if (tailCase == 0)
				[truncated setLength:WALRecordOffset(truncated, 1) + 7];
			else
				[truncated setLength:[truncated length] - 1];
			REQUIRE([truncated writeToFile:path atomically:NO]);
			BOOL incomplete = YES;
			NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
			REQUIRE(!incomplete && [notes count] == 1);
			REQUIRE(RecoveredNotesContainText(notes, @"tail first"));
		} @finally {
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"zero first"), TestWALNote(@"zero bad"),
			TestWALNote(@"zero last"), nil]);
		SetWALOriginalLengthToZero(directoryPath, 1);
		BOOL incomplete = NO;
		NSDictionary *notes = RecoverTestJournal(directoryPath, &incomplete);
		REQUIRE(incomplete && [notes count] == 1);
		REQUIRE(RecoveredNotesContainText(notes, @"zero first"));
		REQUIRE(!RecoveredNotesContainText(notes, @"zero last"));
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	directoryFD = -1;
	int journalWriteFD = -1;
	reader = nil;
	prefs = [[NotationPrefs alloc] init];
	@try {
		CreateTestJournal(directoryPath, [NSArray arrayWithObject:
			TestWALNote(@"unexpected short read")]);
		NSString *path = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
		journalWriteFD = open([path fileSystemRepresentation], O_WRONLY | O_CLOEXEC);
		REQUIRE(journalWriteFD >= 0);
		directoryFD = open([directoryPath fileSystemRepresentation],
			O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		reader = [[WALRecoveryController alloc] initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
			encryptionKey:[prefs WALSessionKey] error:NULL journalInUse:NULL];
		REQUIRE(reader != nil);
		REQUIRE(ftruncate(journalWriteFD, 7) == 0);
		BOOL incomplete = NO;
		NSDictionary *notes = [reader recoveredNotesWithIncompleteRecovery:&incomplete];
		REQUIRE(incomplete && [notes count] == 0);
	} @finally {
		[reader release];
		[prefs release];
		if (journalWriteFD >= 0) close(journalWriteFD);
		if (directoryFD >= 0) close(directoryFD);
		RemoveTemporaryDirectory(directoryPath);
	}
}

static NSArray *FilenamesWithPrefix(NSString *directoryPath, NSString *prefix) {
	NSMutableArray *matches = [NSMutableArray array];
	for (NSString *name in [[NSFileManager defaultManager]
		contentsOfDirectoryAtPath:directoryPath error:NULL])
		if ([name hasPrefix:prefix]) [matches addObject:name];
	return matches;
}

static void CloseController(NVTestNotationController **controller);

static void AssertLegacyRecoveryRejected(NSData *database, time_t databaseTime,
	NSString *candidateName, NSData *candidate, time_t candidateTime) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
	NSString *candidatePath = [directoryPath stringByAppendingPathComponent:candidateName];
	@try {
		WriteTestFile(database, databasePath, databaseTime);
		WriteTestFile(candidate, candidatePath, candidateTime);
		NSData *journal = CreateCorruptTestJournal(directoryPath);
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSModalResponse previousResponse = injectedFailedWALRecoveryResponse;
		injectedFailedWALRecoveryResponse = NSAlertSecondButtonReturn;
		OSStatus status = noErr;
		NVTestNotationController *controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		injectedFailedWALRecoveryResponse = previousResponse;
		REQUIRE(controller == nil && status == NVTestPassCanceledError);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount + 1);
		REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:candidatePath] isEqualToData:candidate]);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]
			isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (legacy recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (legacy recovery ") count] == 0);
	} @finally {
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void AssertLockContentionBypassesRecovery(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	WALStorageController *writer = nil;
	@try {
		time_t now = time(NULL);
		NSData *database = TestDatabaseData(@"live lock database", 4, 0);
		NSData *candidate = TestDatabaseData(@"live lock candidate", 4, 4096);
		WriteTestFile(database, [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName], now - 2);
		WriteTestFile(candidate, [directoryPath stringByAppendingPathComponent:@".010203-779701622-1"], now - 1);
		int directoryFD = open([directoryPath fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		NotationPrefs *prefs = [[NotationPrefs alloc] init];
		writer = [[WALStorageController alloc] initWithRootedDirectory:RootedDirectoryForPath(directoryPath)
			encryptionKey:[prefs WALSessionKey]];
		[prefs release];
		close(directoryFD);
		REQUIRE(writer != nil);
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		OSStatus status = noErr;
		NVTestNotationController *controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status == fBsyErr);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName]]
			isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:@".010203-779701622-1"]]
			isEqualToData:candidate]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (legacy recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (legacy recovery ") count] == 0);
	} @finally {
		[writer destroyLogFile];
		[writer release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void AssertLegacyRecoveryChoiceLeavesFilesUnchanged(NSModalResponse response,
	OSStatus expectedStatus, BOOL expectsQuit) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestNotationController *controller = nil;
	@try {
		time_t now = time(NULL);
		NSData *database = TestDatabaseData(@"recovery choice database", 4, 0);
		NSData *candidate = TestDatabaseData(@"recovery choice candidate", 4, 4096);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSString *candidatePath = [directoryPath stringByAppendingPathComponent:
			@".010203-779701629-1"];
		WriteTestFile(database, databasePath, now - 2);
		WriteTestFile(candidate, candidatePath, now - 1);
		NSData *journal = CreateCorruptTestJournal(directoryPath);
		NSUInteger promptCount = legacyRecoveryPromptCount;
		NSUInteger quitCount = legacyRecoveryQuitCount;
		injectedLegacyRecoveryResponse = response;
		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status == expectedStatus);
		REQUIRE(legacyRecoveryPromptCount == promptCount + 1);
		REQUIRE(legacyRecoveryQuitCount == quitCount + (expectsQuit ? 1 : 0));
		REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:candidatePath] isEqualToData:candidate]);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			NVJournalFilename]] isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (legacy recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (legacy recovery ") count] == 0);
	} @finally {
		injectedLegacyRecoveryResponse = NSAlertFirstButtonReturn;
		CloseController(&controller);
		RemoveTemporaryDirectory(directoryPath);
	}
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

static NSString *FileContainingText(NSString *directoryPath, NSString *text,
	NSString *excludingFilename) {
	for (NSString *name in [[NSFileManager defaultManager]
		contentsOfDirectoryAtPath:directoryPath error:NULL]) {
		if ([name isEqualToString:excludingFilename]) continue;
		NSString *path = [directoryPath stringByAppendingPathComponent:name];
		NSString *contents = [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:NULL];
		if ([contents isEqualToString:text]) return path;
	}
	return nil;
}

static NoteObject *AddTestNote(NotationController *controller, NSString *title, NSString *body) {
	NoteObject *note = [[[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:body] autorelease]
		title:title format:[controller currentNoteStorageFormat] labels:@""] autorelease];
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

static void WaitForFileText(NSString *path, NSString *expectedText) {
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSString *text = [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:NULL];
		if ([text isEqualToString:expectedText]) return;
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
	}
	REQUIRE([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
		error:NULL] isEqualToString:expectedText]);
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

static NSInteger SnapshotStressVersionIndex(NVFileSnapshot *snapshot,
	NSArray *contents, NSArray *encodings, NSArray *tags) {
	for (NSUInteger index = 0; index < [contents count]; index++) {
		if (![[snapshot data] isEqualToData:[contents objectAtIndex:index]]) continue;
		if ([snapshot encoding] != [[encodings objectAtIndex:index] unsignedIntegerValue]) return NSNotFound;
		id expectedTags = [tags objectAtIndex:index];
		if (expectedTags == [NSNull null]) return [snapshot tags] == nil ? (NSInteger)index : NSNotFound;
		return [[snapshot tags] isEqual:expectedTags] ? (NSInteger)index : NSNotFound;
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
		[controller setSnapshotCocoaTagsUnavailable:YES];
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
			NSError *error = nil;
			NVFileSnapshot *snapshot = [[controller noteDirectory]
				snapshotForFileNamed:@"Snapshot Stress.txt" error:&error];
			if (snapshot) {
				NSInteger version = SnapshotStressVersionIndex(snapshot, contents, encodings, expectedTags);
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
		[controller setSnapshotCocoaTagsUnavailable:YES];
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
			NSError *error = nil;
			NVFileSnapshot *snapshot = [[controller noteDirectory]
				snapshotForFileNamed:@"In Place Stress.txt" error:&error];
			if (snapshot) {
				NSInteger version = SnapshotStressVersionIndex(snapshot, contents, encodings, expectedTags);
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
		[controller setSnapshotCocoaTagsUnavailable:YES];
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
		NVFileSnapshot *snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:NULL];
		REQUIRE(snapshot != nil);
		REQUIRE([snapshot.tags isEqual:finderTags] && snapshot.encoding == NSUTF8StringEncoding);

		const char numericEncoding[] = "US-ASCII;1536";
		REQUIRE(setxattr([path fileSystemRepresentation], "com.apple.TextEncoding",
			numericEncoding, sizeof(numericEncoding) - 1, 0, 0) == 0);
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:NULL];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshot.encoding == NSASCIIStringEncoding && [snapshot.tags isEqual:finderTags]);
		REQUIRE(removexattr([path fileSystemRepresentation], "com.apple.TextEncoding", 0) == 0);
		REQUIRE(removexattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", 0) == 0);
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:NULL];
		REQUIRE(snapshot != nil);
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
		NSError *error = nil;
		NVFileSnapshot *snapshot = [[controller noteDirectory]
			snapshotForFileNamed:filename error:&error];
		REQUIRE(snapshot != nil);
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
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&error];
		REQUIRE(snapshot != nil);
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
		NSError *metadataError = nil;
		NVFileObservation *info = [[controller noteDirectory]
			observationForFileNamed:@"Capability.txt" error:&metadataError];
		REQUIRE(metadataError == nil && [info fileID] != 0);
		NSUInteger foundationCount = [controller foundationEnumerationsForDirectoryScan];
		REQUIRE(foundationCount != NSNotFound);
		NVFileSnapshot *snapshot = [[controller noteDirectory]
			snapshotForFileNamed:@"Capability.txt" error:NULL];
		REQUIRE(snapshot != nil);

		id foundationDocumentID = nil;
		BOOL foundationDocumentIDAvailable = [[NSURL fileURLWithPath:capabilityPath]
			getResourceValue:&foundationDocumentID forKey:NSURLDocumentIdentifierKey error:NULL];
		if (foundationDocumentIDAvailable && [info documentID] && [foundationDocumentID unsignedIntValue])
			REQUIRE([info documentID] == [foundationDocumentID unsignedIntValue]);

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
		if ([expectedFilesystem isEqualToString:@"hfs"]) {
			NSString *conditionalName = @"Conditional Replacement.txt";
			NSString *conditionalPath = [directoryPath stringByAppendingPathComponent:conditionalName];
			NSData *initial = [@"initial scratch bytes" dataUsingEncoding:NSUTF8StringEncoding];
			NSData *replacement = [@"replacement scratch bytes" dataUsingEncoding:NSUTF8StringEncoding];
			REQUIRE([initial writeToFile:conditionalPath options:0 error:NULL]);
			NVFileSnapshot *initialSnapshot = [[controller noteDirectory]
				snapshotForFileNamed:conditionalName error:NULL];
			REQUIRE(initialSnapshot != nil);
			NVFileWriteResult *writeResult = [[controller noteDirectory]
				replaceFileNamed:conditionalName withData:replacement expectedSnapshot:initialSnapshot];
			REQUIRE([writeResult disposition] == NVFileWriteInstalledVerified &&
				[writeResult capability] == NVFileWriteHFSCompatibilityCapability &&
				[[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:replacement]);
			writeResult = [[controller noteDirectory] replaceFileNamed:conditionalName
				withData:initial expectedSnapshot:initialSnapshot];
			NSError *replacementError = [writeResult error];
			REQUIRE([writeResult disposition] == NVFileWriteNotInstalled);
			REQUIRE([[replacementError domain] isEqualToString:NSPOSIXErrorDomain] &&
				[replacementError code] == EAGAIN &&
				[[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:replacement]);
			RequireNoTemporaryFiles(directoryPath);
		}

		NSLog(@"filesystem capabilities: fs=%s case-sensitive=%@ xattrs=%@ enumeration=%@ "
			"document-id=%u foundation-document-id=%@ file-id=%llu generation=%@:%u ctime=%lld.%09ld",
			volume.f_fstypename, caseSensitive ? @"yes" : @"no", supportsXattrs ? @"yes" : @"no",
			foundationCount ? @"Foundation" : @"bulk", [info documentID],
			foundationDocumentIDAvailable ? foundationDocumentID : @"unavailable",
			(unsigned long long)[info fileID], generationAvailable ? @"available" : @"unavailable",
			generation.generationCount, (long long)[info attributeModificationTime].tv_sec,
			(long)[info attributeModificationTime].tv_nsec);
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
		NoteObject *note = AddTestNote(controller, @"System Tags", @"system tag producer");
		[note setLabelString:@"StaleOpenMeta"];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		NSError *error = nil;
		SpawnScenarioWithEnvironment(@"system-tag-writer-child", "NV_SYSTEM_TAG_PATH", path, 0);
		ssize_t rawTagLength = getxattr([path fileSystemRepresentation],
			"com.apple.metadata:kMDItemOMUserTags", NULL, 0, 0, 0);
		int rawTagError = rawTagLength < 0 ? errno : 0;
		id systemTags = nil;
		BOOL tagsAvailable = [[NSURL fileURLWithPath:path]
			getResourceValue:&systemTags forKey:NSURLTagNamesKey error:&error];
		NVFileSnapshot *snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&error];
		REQUIRE(snapshot != nil);
		NSLog(@"system tag producer after child exit: NSURL=%@ snapshot=%@ raw-xattr=%ld errno=%d",
			tagsAvailable ? systemTags : @"unavailable", snapshot.tags, (long)rawTagLength, rawTagError);
		NSArray *expectedNames = @[ @"Red", @"Caf\u00e9\u6771\u4eac" ];
		NSArray *snapshotNames = NVSemanticTagNames(snapshot.tags);
		REQUIRE(tagsAvailable && TagSetsEqual(NVSemanticTagNames(systemTags), expectedNames));
		REQUIRE(TagSetsEqual(snapshotNames, expectedNames));
		REQUIRE(rawTagLength >= 0 && rawTagError == 0);
		REQUIRE([[[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]]
			isEqual:@[ @"StaleOpenMeta" ]]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE(TagSetsEqual([note orderedLabelTitles], expectedNames));

		WaitForNextMetadataTickIfNeeded();
		REQUIRE([[NSURL fileURLWithPath:path] setResourceValue:@[]
			forKey:NSURLTagNamesKey error:&error]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[note orderedLabelTitles] count] == 0);
		WaitForNextMetadataTickIfNeeded();
		REQUIRE(SetTestOpenMetaTagsOnly(controller, @[ @"OpenMetaOnly" ], filename, &error));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[note orderedLabelTitles] count] == 0);

		[controller setSnapshotCocoaTagsUnavailable:YES];
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&error];
		REQUIRE(snapshot != nil);
		REQUIRE([snapshot.tags isEqual:@[ @"OpenMetaOnly" ]]);
		[controller setSnapshotCocoaTagsUnavailable:NO];
		[controller replaceSnapshotCocoaTags:nil afterReadingTags:@[ @1 ]
			forNoteNamed:filename atIdentityChecks:0];
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&error];
		REQUIRE(snapshot != nil);
		REQUIRE([snapshot.tags isEqual:@[ @"OpenMetaOnly" ]]);
		[controller replaceSnapshotCocoaTags:nil afterReadingTags:nil
			forNoteNamed:filename atIdentityChecks:0];

		[note setLabelString:@"NVRewritten"];
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"system tag producer rewritten"] autorelease]];
		[controller setFailCocoaTagWrites:YES];
		REQUIRE([controller flushAllNoteChanges]);
		[controller setFailCocoaTagWrites:NO];
		NSArray *openMetaTags = [[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]];
		NSArray *writtenTags = [note orderedLabelTitles];
		REQUIRE([openMetaTags isEqual:writtenTags]);
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
		title:@"WAL Crash Recovery" format:SingleDatabaseFormat labels:@""];
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

static void TestLegacyTemporaryDatabaseRecovery(void) {
	time_t now = time(NULL);
	NSData *staleDatabase = TestDatabaseData(@"stale database", 4, 0);
	NSData *olderCandidate = TestDatabaseData(@"older temporary database", 4, 2048);
	NSData *tiedCandidate = TestDatabaseData(@"lexically earlier temporary database", 4, 3072);
	NSData *nanosecondCandidate = TestDatabaseData(@"nanosecond-newest temporary database", 4, 3584);
	NSData *newestCandidate = TestDatabaseData(@"newest temporary database", 4, 4096);
	NSData *ignoredCandidate = TestDatabaseData(@"ignored nonmatching database", 4, 8192);
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSString *olderName = @".010203-779701620-1";
		NSString *tiedName = @".010203-779701621-1";
		NSString *nanosecondName = @".010203-779701621-0";
		NSString *newestName = @".010203-779701621-2";
		NSString *ignoredName = @".010203-779701623-3-extra";
		NSString *shortName = @".010203";
		NSString *symlinkName = @".010203-779701999-1";
		WriteTestFile(staleDatabase, databasePath, now - 40);
		WriteTestFile(olderCandidate, [directoryPath stringByAppendingPathComponent:olderName], now - 30);
		WriteTestFile(tiedCandidate, [directoryPath stringByAppendingPathComponent:tiedName], now - 20);
		NSString *nanosecondPath = [directoryPath stringByAppendingPathComponent:nanosecondName];
		WriteTestFile(nanosecondCandidate, nanosecondPath, now - 20);
		SetTestFileModificationTime(nanosecondPath, now - 20, 500);
		WriteTestFile(newestCandidate, [directoryPath stringByAppendingPathComponent:newestName], now - 20);
		WriteTestFile(ignoredCandidate, [directoryPath stringByAppendingPathComponent:ignoredName], now - 10);
		WriteTestFile(ignoredCandidate, [directoryPath stringByAppendingPathComponent:shortName], now - 5);
		REQUIRE(symlink([newestName fileSystemRepresentation],
			[[directoryPath stringByAppendingPathComponent:symlinkName] fileSystemRepresentation]) == 0);
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"candidate WAL recovery"), TestWALNote(@"candidate corrupt record"), nil]);
		CorruptWALChecksum(directoryPath, 1);
		NSData *corruptJournal = [NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]];

		NSUInteger promptCount = legacyRecoveryPromptCount;
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSUInteger warningCount = partialWALRecoveryWarningCount;
		controller = CreateController(directoryPath, delegate);
		REQUIRE(legacyRecoveryPromptCount == promptCount + 1);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount);
		REQUIRE(partialWALRecoveryWarningCount == warningCount);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"nanosecond-newest temporary database") != nil);
		REQUIRE(NoteContaining(controller, @"candidate WAL recovery") != nil);
		REQUIRE(NoteContaining(controller, @"older temporary database") == nil);
		REQUIRE(NoteContaining(controller, @"ignored nonmatching database") == nil);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:newestName]] isEqualToData:newestCandidate]);
		REQUIRE([[NSData dataWithContentsOfFile:nanosecondPath]
			isEqualToData:nanosecondCandidate]);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:olderName]] isEqualToData:olderCandidate]);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:tiedName]] isEqualToData:tiedCandidate]);
		struct stat symlinkInfo;
		REQUIRE(lstat([[directoryPath stringByAppendingPathComponent:symlinkName] fileSystemRepresentation],
			&symlinkInfo) == 0 && S_ISLNK(symlinkInfo.st_mode));
		NSArray *databaseBackups = FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (legacy recovery ");
		NSArray *journalBackups = FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (legacy recovery ");
		REQUIRE([databaseBackups count] == 1 && [journalBackups count] == 1);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[databaseBackups objectAtIndex:0]]] isEqualToData:staleDatabase]);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[journalBackups objectAtIndex:0]]] isEqualToData:corruptJournal]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		REQUIRE(legacyRecoveryPromptCount == promptCount + 1);
		REQUIRE(partialWALRecoveryWarningCount == warningCount);
		REQUIRE([[controller notationPrefs] epochIteration] == EPOC_ITERATION);
		REQUIRE(NoteContaining(controller, @"nanosecond-newest temporary database") != nil);
		REQUIRE(NoteContaining(controller, @"candidate WAL recovery") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	/* Isolate the lexical tie-breaker so a later nanosecond candidate cannot
	 * accidentally make this assertion pass. */
	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		WriteTestFile(TestDatabaseData(@"tie database", 4, 0),
			[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName], now - 20);
		WriteTestFile(TestDatabaseData(@"lexically earlier candidate", 4, 2048),
			[directoryPath stringByAppendingPathComponent:@".010203-779701621-1"], now - 10);
		WriteTestFile(TestDatabaseData(@"lexically later candidate", 4, 3072),
			[directoryPath stringByAppendingPathComponent:@".010203-779701621-2"], now - 10);
		CreateCorruptTestJournal(directoryPath);
		controller = CreateController(directoryPath, delegate);
		REQUIRE(NoteContaining(controller, @"lexically later candidate") != nil);
		REQUIRE(NoteContaining(controller, @"lexically earlier candidate") == nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	AssertLegacyRecoveryRejected(TestDatabaseData(@"newer database", 4, 0), now - 10,
		@".010203-779701624-1", TestDatabaseData(@"older candidate", 4, 4096), now - 20);
	AssertLegacyRecoveryRejected(TestDatabaseData(@"larger database", 4, 4096), now - 20,
		@".010203-779701625-1", TestDatabaseData(@"smaller candidate", 4, 0), now - 10);
	AssertLegacyRecoveryRejected(TestDatabaseData(@"epoch five database", 5, 0), now - 20,
		@".010203-779701626-1", TestDatabaseData(@"epoch four candidate", 4, 4096), now - 10);
	AssertLegacyRecoveryRejected(TestDatabaseData(@"matching-name database", 4, 0), now - 20,
		@".010203-779701627-1-extra", TestDatabaseData(@"nonmatching candidate", 4, 4096), now - 10);

	directoryPath = CreateTemporaryDirectory();
	@try {
		NSData *database = TestDatabaseData(@"rollback database", 4, 0);
		NSMutableData *invalidCandidate = [NSMutableData dataWithLength:[database length] + 4096];
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSString *candidatePath = [directoryPath stringByAppendingPathComponent:@".010203-779701628-1"];
		WriteTestFile(database, databasePath, now - 20);
		WriteTestFile(invalidCandidate, candidatePath, now - 10);
		NSData *journal = CreateCorruptTestJournal(directoryPath);
		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status != noErr);
		REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:candidatePath] isEqualToData:invalidCandidate]);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]
			isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (legacy recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (legacy recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (failed recovery ") count] == 1);
	} @finally {
		CloseController(&controller);
		RemoveTemporaryDirectory(directoryPath);
	}

	AssertLegacyRecoveryChoiceLeavesFilesUnchanged(NSAlertSecondButtonReturn,
		NVTestPassCanceledError, NO);
	AssertLegacyRecoveryChoiceLeavesFilesUnchanged(NSAlertThirdButtonReturn,
		NVTestJournalingError, YES);
}

static void TestWALRecoveryWorkflows(void) {
	time_t now = time(NULL);
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		WriteTestFile(TestDatabaseData(@"epoch four startup", 4, 0),
			[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName], now - 10);
		observeJournalInitializations = YES;
		observedJournalInitializations = 0;
		controller = CreateController(directoryPath, delegate);
		REQUIRE(observedJournalInitializations == 1);
		REQUIRE(NoteContaining(controller, @"epoch four startup") != nil);
		CloseController(&controller);
		observeJournalInitializations = NO;
		controller = CreateController(directoryPath, delegate);
		REQUIRE([[controller notationPrefs] epochIteration] == EPOC_ITERATION);
	} @finally {
		observeJournalInitializations = NO;
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		NSData *staleDatabase = TestDatabaseData(@"epoch four stale database", 4, 0);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		NSString *journalPath = [directoryPath stringByAppendingPathComponent:NVJournalFilename];
		WriteTestFile(staleDatabase, databasePath, now - 10);
		NSData *journal = CreateTestJournal(directoryPath,
			[NSArray arrayWithObject:TestWALNote(@"epoch four WAL-only note")]);
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		NSUInteger warningCount = partialWALRecoveryWarningCount;

		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"epoch four stale database") != nil);
		REQUIRE(NoteContaining(controller, @"epoch four WAL-only note") != nil);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
		REQUIRE(partialWALRecoveryWarningCount == warningCount);
		NSData *freshJournal = [NSData dataWithContentsOfFile:journalPath];
		REQUIRE(freshJournal != nil && ![freshJournal isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (WAL recovery ") count] == 0);
		NSData *migratedDatabase = [NSData dataWithContentsOfFile:databasePath];
		REQUIRE(migratedDatabase != nil && ![migratedDatabase isEqualToData:staleDatabase]);

		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		REQUIRE([[controller notationPrefs] epochIteration] == EPOC_ITERATION);
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"epoch four stale database") != nil);
		REQUIRE(NoteContaining(controller, @"epoch four WAL-only note") != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		NSData *database = TestDatabaseData(@"old database note", 5, 0);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		WriteTestFile(database, databasePath, now - 10);
		NSData *journal = CreateCorruptTestJournal(directoryPath);
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		NSUInteger warningCount = partialWALRecoveryWarningCount;
		injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE(NoteContaining(controller, @"old database note") != nil);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount + 1);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
		REQUIRE(partialWALRecoveryWarningCount == warningCount);
		NSArray *journalBackups = FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (failed recovery ");
		REQUIRE([journalBackups count] == 1);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[journalBackups objectAtIndex:0]]] isEqualToData:journal]);
		REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount + 1);
	} @finally {
		injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		NSData *database = TestDatabaseData(@"partial database note", 5, 0);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		WriteTestFile(database, databasePath, now - 10);
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"partial recovered note"), TestWALNote(@"partial lost note"), nil]);
		CorruptWALChecksum(directoryPath, 1);
		NSData *journal = [NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]];
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		NSUInteger warningCount = partialWALRecoveryWarningCount;
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE(NoteContaining(controller, @"partial database note") != nil);
		REQUIRE(NoteContaining(controller, @"partial recovered note") != nil);
		REQUIRE(NoteContaining(controller, @"partial lost note") == nil);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
		REQUIRE(partialWALRecoveryWarningCount == warningCount + 1);
		NSArray *databaseBackups = FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (partial recovery ");
		NSArray *journalBackups = FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (partial recovery ");
		REQUIRE([databaseBackups count] == 1 && [journalBackups count] == 1);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[databaseBackups objectAtIndex:0]]] isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[journalBackups objectAtIndex:0]]] isEqualToData:journal]);
		CloseController(&controller);
		controller = CreateController(directoryPath, delegate);
		REQUIRE(NoteContaining(controller, @"partial database note") != nil);
		REQUIRE(NoteContaining(controller, @"partial recovered note") != nil);
		REQUIRE(NoteContaining(controller, @"partial lost note") == nil);
		REQUIRE(partialWALRecoveryWarningCount == warningCount + 1);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		WriteTestFile(TestDatabaseData(@"complete rollback database", 5, 0),
			[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName], now - 10);
		NSData *journal = CreateTestJournal(directoryPath,
			[NSArray arrayWithObject:TestWALNote(@"complete rollback recovered")]);
		injectedFreshJournalInitializationFailures = 1;
		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status == NVTestJournalingError);
		REQUIRE([[NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]
			isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (WAL recovery ") count] == 0);
		controller = CreateController(directoryPath, delegate);
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE(NoteContaining(controller, @"complete rollback recovered") != nil);
	} @finally {
		injectedFreshJournalInitializationFailures = 0;
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSModalResponse response = NSAlertSecondButtonReturn;
		response <= NSAlertThirdButtonReturn; response++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			NSData *database = TestDatabaseData(@"declined old database", 5, 0);
			NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
			WriteTestFile(database, databasePath, now - 10);
			NSData *journal = CreateCorruptTestJournal(directoryPath);
			NSUInteger quitCount = legacyRecoveryQuitCount;
			injectedFailedWALRecoveryResponse = response;
			OSStatus status = noErr;
			controller = [[NVTestNotationController alloc]
				initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
			REQUIRE(controller == nil);
			REQUIRE(status == (response == NSAlertSecondButtonReturn ?
				NVTestPassCanceledError : NVTestJournalingError));
			REQUIRE(legacyRecoveryQuitCount == quitCount +
				(response == NSAlertThirdButtonReturn ? 1 : 0));
			REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
			REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
				NVJournalFilename]] isEqualToData:journal]);
			REQUIRE([FilenamesWithPrefix(directoryPath,
				@"Interim Note-Changes (failed recovery ") count] == 0);
		} @finally {
			injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
			CloseController(&controller);
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		NSData *database = TestDatabaseData(@"partial rollback database", 5, 0);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		WriteTestFile(database, databasePath, now - 10);
		CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
			TestWALNote(@"partial rollback recovered"), TestWALNote(@"partial rollback lost"), nil]);
		CorruptWALChecksum(directoryPath, 1);
		NSData *journal = [NSData dataWithContentsOfFile:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]];
		injectedControllerFlushFailures = 1;
		observedInjectedControllerFlushFailures = 0;
		NSUInteger warningCount = partialWALRecoveryWarningCount;
		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status == NVTestJournalingError);
		REQUIRE(observedInjectedControllerFlushFailures == 1);
		REQUIRE(partialWALRecoveryWarningCount == warningCount);
		REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			NVJournalFilename]] isEqualToData:journal]);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Notes & Settings (partial recovery ") count] == 0);
		REQUIRE([FilenamesWithPrefix(directoryPath,
			@"Interim Note-Changes (partial recovery ") count] == 0);
	} @finally {
		injectedControllerFlushFailures = 0;
		CloseController(&controller);
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSUInteger failureCase = 0; failureCase < 3; failureCase++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			NSData *database = TestDatabaseData(@"transaction rollback database", 5, 0);
			NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
			WriteTestFile(database, databasePath, now - 10);
			CreateTestJournal(directoryPath, [NSArray arrayWithObjects:
				TestWALNote(@"transaction recovered"), TestWALNote(@"transaction lost"), nil]);
			CorruptWALChecksum(directoryPath, 1);
			NSString *journalPath = [directoryPath stringByAppendingPathComponent:
				NVJournalFilename];
			NSData *journal = [NSData dataWithContentsOfFile:journalPath];
			if (failureCase == 0) injectedRecoveryDirectorySyncFailures = 1;
			else if (failureCase == 1) injectedRecoveryJournalRenameFailures = 1;
			else injectedFreshJournalInitializationFailures = 1;
			OSStatus status = noErr;
			controller = [[NVTestNotationController alloc]
				initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
			REQUIRE(controller == nil && status == NVTestJournalingError);
			REQUIRE(injectedRecoveryDirectorySyncFailures == 0 &&
				injectedRecoveryJournalRenameFailures == 0 &&
				injectedFreshJournalInitializationFailures == 0);
			REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
			REQUIRE([[NSData dataWithContentsOfFile:journalPath] isEqualToData:journal]);
			REQUIRE([FilenamesWithPrefix(directoryPath,
				@"Notes & Settings (partial recovery ") count] == 0);
			REQUIRE([FilenamesWithPrefix(directoryPath,
				@"Interim Note-Changes (partial recovery ") count] == 0);
			REQUIRE([FilenamesWithPrefix(directoryPath,
				@"Notes & Settings (failed recovery ") count] == 1);
		} @finally {
			injectedRecoveryDirectorySyncFailures = 0;
			injectedRecoveryJournalRenameFailures = 0;
			injectedFreshJournalInitializationFailures = 0;
			CloseController(&controller);
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	for (NSUInteger failureCase = 0; failureCase < 2; failureCase++) {
		directoryPath = CreateTemporaryDirectory();
		@try {
			NSData *database = TestDatabaseData(@"old-notes rollback database", 5, 0);
			NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
			WriteTestFile(database, databasePath, now - 10);
			NSData *journal = CreateCorruptTestJournal(directoryPath);
			if (failureCase == 0) injectedFreshJournalInitializationFailures = 1;
			else {
				injectedRecoveryDirectorySyncFailures = 1;
				InstallExternalDatabaseInitializationObservation();
				[[NSRunLoop currentRunLoop] runUntilDate:
					[NSDate dateWithTimeIntervalSinceNow:0.01]];
				observedExternalDatabaseInitializations = 0;
				observeExternalDatabaseInitialization = YES;
			}
			injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
			OSStatus status = noErr;
			controller = [[NVTestNotationController alloc]
				initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
			REQUIRE(controller == nil && status == NVTestJournalingError);
			REQUIRE(injectedFreshJournalInitializationFailures == 0 &&
				injectedRecoveryDirectorySyncFailures == 0);
			REQUIRE([[NSData dataWithContentsOfFile:databasePath] isEqualToData:database]);
			REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
				NVJournalFilename]] isEqualToData:journal]);
			REQUIRE([FilenamesWithPrefix(directoryPath,
				@"Interim Note-Changes (failed recovery ") count] == 0);
			if (failureCase == 1) {
				[[NSRunLoop currentRunLoop] runUntilDate:
					[NSDate dateWithTimeIntervalSinceNow:0.01]];
				REQUIRE(observedExternalDatabaseInitializations == 0);
			}
		} @finally {
			observeExternalDatabaseInitialization = NO;
			injectedFreshJournalInitializationFailures = 0;
			injectedRecoveryDirectorySyncFailures = 0;
			injectedFailedWALRecoveryResponse = NSAlertFirstButtonReturn;
			CloseController(&controller);
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	directoryPath = CreateTemporaryDirectory();
	@try {
		WriteTestFile(TestDatabaseData(@"unrelated journal error", 5, 0),
			[directoryPath stringByAppendingPathComponent:NotesDatabaseFileName], now - 10);
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		NSUInteger failedPromptCount = failedWALRecoveryPromptCount;
		NSUInteger legacyPromptCount = legacyRecoveryPromptCount;
		OSStatus status = noErr;
		controller = [[NVTestNotationController alloc]
			initWithDirectoryURL:FileReferenceURLForPath(directoryPath) error:&status];
		REQUIRE(controller == nil && status == NVTestJournalingError);
		REQUIRE(failedWALRecoveryPromptCount == failedPromptCount);
		REQUIRE(legacyRecoveryPromptCount == legacyPromptCount);
	} @finally {
		CloseController(&controller);
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
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:WALJournalPath(rootPath)]);
		REQUIRE([FilenamesWithPrefix(WALNotesDirectoryPath(rootPath),
			@"Interim Note-Changes (WAL recovery ") count] == 0);
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
	OSStatus status = noErr;
	NVTestNotationController *controller = [[NVTestNotationController alloc]
		initWithDirectoryURL:ResolveWALBookmark(rootPath) error:&status];
	REQUIRE(controller == nil && status == NVTestJournalingError);
	REQUIRE(observedInjectedControllerFlushFailures == 1);
	REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:WALJournalPath(rootPath)]);
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
	[[controller notationPrefs] setConfirmsFileDeletion:NO];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"file outbox baseline"] autorelease]
		title:@"File Outbox Crash" format:PlainTextFormat labels:@""];
	[controller addNewNote:note];
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"file outbox WAL edit"] autorelease]];
	REQUIRE(chmod([directoryPath fileSystemRepresentation], 0500) == 0);
	[controller synchronizeNoteChanges:nil];
	NoteObject *newNote = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"file outbox WAL-only new note"] autorelease]
		title:@"WAL-only New Note" format:PlainTextFormat labels:@""];
	[controller addNewNote:newNote];
	REQUIRE([controller pendingFileWriteCount] == 2 &&
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
		NoteObject *newNote = NoteContaining(controller, @"file outbox WAL-only new note");
		REQUIRE(note != nil && newNote != nil && [controller pendingFileWriteCount] == 0);
		REQUIRE([controller deletionCandidateCount] == 0);
		NSString *disk = [NSString stringWithContentsOfFile:[[note absoluteUNIXPath] path]
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([disk isEqualToString:@"file outbox WAL edit"]);
		REQUIRE([[NSString stringWithContentsOfFile:[[newNote absoluteUNIXPath] path]
			encoding:NSUTF8StringEncoding error:NULL]
			isEqualToString:@"file outbox WAL-only new note"]);
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
			title:@"Remounted Bookmark" format:SingleDatabaseFormat labels:@""];
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
			title:@"Live Detach" format:PlainTextFormat labels:@"detach"];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		heldNoteFD = open([[note absoluteUNIXPath] fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
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

		NSError *error = nil;
		BOOL snapshotSucceeded = [[controller noteDirectory]
			snapshotForFileNamed:filenameOfNote(note) error:&error] != nil;
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
			title:@"Disk Full Recovery" format:PlainTextFormat labels:@""];
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
		REQUIRE([[controller noteDirectory] synchronize:NULL]);
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
		NVFileWriteResult *createResult = [[controller noteDirectory]
			createFileNamed:@"Read Or Create Database" withData:[NSData data]];
		REQUIRE([createResult disposition] == NVFileWriteInstalledVerified);
		NSData *newEmptyData = [[controller noteDirectory]
			dataFromFileNamed:@"Read Or Create Database" error:&error];
		REQUIRE([newEmptyData length] == 0 && error == nil);
		NSString *readOrCreatePath = [directoryPath
			stringByAppendingPathComponent:@"Read Or Create Database"];
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:readOrCreatePath]);
		NSData *existingData = [@"existing" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([existingData writeToFile:readOrCreatePath atomically:NO]);
		error = nil;
		REQUIRE([[[controller noteDirectory] dataFromFileNamed:@"Read Or Create Database" error:&error]
			isEqualToData:existingData]);
		REQUIRE(error == nil);
		NSArray *collidingNames = @[ @"Case.txt", @"case.TXT" ];
		NSArray *distinctNames = @[ @"One.txt", @"Two.txt" ];
		REQUIRE([controller hasCaseCollisionForNames:collidingNames]);
		REQUIRE(![controller hasCaseCollisionForNames:distinctNames]);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"metadata baseline"] autorelease]
			title:@"Metadata Identity" format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		NSError *snapshotError = nil;
		NVFileSnapshot *snapshot = [[controller noteDirectory]
			snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshotError == nil);
		REQUIRE([[[[NSString alloc] initWithData:snapshot.data encoding:NSUTF8StringEncoding]
			autorelease] isEqualToString:@"metadata baseline"]);
		REQUIRE(snapshot.encoding == NSUTF8StringEncoding);
		REQUIRE([snapshot.tags count] == 0);
		REQUIRE([[snapshot observation] fileID] == sessionFileIDOfNote(note));

		const char *tagsAttribute = "com.apple.metadata:kMDItemOMUserTags";
		REQUIRE(removexattr([path fileSystemRepresentation], tagsAttribute, 0) == 0);
		snapshotError = nil;
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshot.tags != nil && [snapshot.tags count] == 0);
		snapshotError = nil;
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));
		REQUIRE(snapshotError == nil);
		snapshotError = nil;
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshotError == nil && snapshot.tags != nil && [snapshot.tags count] == 0);
		id cocoaTags = nil;
		REQUIRE([[[controller noteDirectory]
			transientFileReferenceURLForFileNamed:filename error:&snapshotError]
			getResourceValue:&cocoaTags forKey:NSURLTagNamesKey error:&snapshotError]);
		REQUIRE(snapshotError == nil && [cocoaTags count] == 0);
		NSArray *mirroredTags = @[ @"Red\n6", @"Plain" ];
		REQUIRE(SetTestOpenMetaTags(controller, mirroredTags, filename, &snapshotError));
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE([snapshot.tags isEqual:NVSemanticTagNames(mirroredTags)]);
		REQUIRE([[[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[path fileSystemRepresentation]] isEqual:mirroredTags]);
		cocoaTags = nil;
		REQUIRE([[[controller noteDirectory]
			transientFileReferenceURLForFileNamed:filename error:&snapshotError]
			getResourceValue:&cocoaTags forKey:NSURLTagNamesKey error:&snapshotError]);
		REQUIRE(TagSetsEqual(cocoaTags, NVSemanticTagNames(mirroredTags)));
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));

		NSData *badTags = [@"not a property list" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE(setxattr([path fileSystemRepresentation], tagsAttribute,
			[badTags bytes], [badTags length], 0, 0) == 0);
		snapshotError = nil;
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshotError == nil && [snapshot.tags count] == 0);
		[controller setSnapshotCocoaTagsUnavailable:YES];
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError] == nil);
		REQUIRE(snapshotError != nil);

		NSData *wrongTypeTags = [NSPropertyListSerialization dataWithPropertyList:@[ @1 ]
			format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
		REQUIRE(setxattr([path fileSystemRepresentation], tagsAttribute,
			[wrongTypeTags bytes], [wrongTypeTags length], 0, 0) == 0);
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError] == nil);
		REQUIRE(snapshotError != nil);
		[controller setSnapshotCocoaTagsUnavailable:NO];
		snapshotError = nil;
		REQUIRE(SetTestOpenMetaTags(controller, @[], filename, &snapshotError));
		REQUIRE(snapshotError == nil);

		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil && [[snapshot observation] generationCount] != 0);
		NVFileObservation *encodingInfo = [snapshot observation];
		NVFileObservation *wrongGenerationInfo = [[[NVFileObservation alloc]
			initWithCreationTime:[encodingInfo creationTime]
			modificationTime:[encodingInfo modificationTime]
			attributeModificationTime:[encodingInfo attributeModificationTime]
			logicalSize:[encodingInfo logicalSize] fileID:[encodingInfo fileID]
			documentID:[encodingInfo documentID]
			generationCount:[encodingInfo generationCount] + 1] autorelease];
		NVFileSnapshot *wrongGenerationSnapshot = [[[NVFileSnapshot alloc]
			initWithData:[snapshot data] tags:[snapshot tags] encoding:[snapshot encoding]
			observation:wrongGenerationInfo] autorelease];
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] setTextEncoding:NSUTF8StringEncoding
			forFileNamed:filename expectedSnapshot:wrongGenerationSnapshot error:&snapshotError] == nil);
		REQUIRE(snapshotError != nil);
		NVFileObservation *generationAgnosticInfo = [[[NVFileObservation alloc]
			initWithCreationTime:[encodingInfo creationTime]
			modificationTime:[encodingInfo modificationTime]
			attributeModificationTime:[encodingInfo attributeModificationTime]
			logicalSize:[encodingInfo logicalSize] fileID:[encodingInfo fileID]
			documentID:[encodingInfo documentID] generationCount:0] autorelease];
		NVFileSnapshot *generationAgnosticSnapshot = [[[NVFileSnapshot alloc]
			initWithData:[snapshot data] tags:[snapshot tags] encoding:[snapshot encoding]
			observation:generationAgnosticInfo] autorelease];
		snapshotError = nil;
		NVFileSnapshot *resultingEncodingSnapshot = [[controller noteDirectory]
			setTextEncoding:NSUTF8StringEncoding forFileNamed:filename
			expectedSnapshot:generationAgnosticSnapshot error:&snapshotError];
		REQUIRE(snapshotError == nil &&
			[[resultingEncodingSnapshot observation] generationCount] != 0);
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		NSMutableData *concurrentEncodingData = [[snapshot.data mutableCopy] autorelease];
		((uint8_t*)[concurrentEncodingData mutableBytes])[0] ^= 1;
		[controller mutateNoteNamed:filename withData:concurrentEncodingData
			duringEncodingSynchronization:YES];
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] setTextEncoding:NSISOLatin1StringEncoding
			forFileNamed:filename expectedSnapshot:snapshot error:&snapshotError] == nil);
		REQUIRE(snapshotError != nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:concurrentEncodingData]);
		WriteExternalFileInPlace(@"metadata baseline", path);
		REQUIRE(SetTestTextEncoding(controller, NSUTF8StringEncoding, filename, &snapshotError));

		const char *encodingAttribute = "com.apple.TextEncoding";
		const char *badEncoding = "not-an-encoding";
		REQUIRE(setxattr([path fileSystemRepresentation], encodingAttribute,
			badEncoding, strlen(badEncoding), 0, 0) == 0);
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError] == nil);
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
		snapshot = [[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
		REQUIRE(snapshot != nil);
		REQUIRE(snapshotError == nil && [controller snapshotAttemptCount] == 2);
		[controller setTransientSnapshotFailures:2];
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:filename error:&snapshotError] == nil);
		REQUIRE([[snapshotError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[snapshotError code] == EAGAIN && [controller snapshotAttemptCount] == 2);

		NSString *symlinkName = @"Metadata Symlink.txt";
		NSString *symlinkPath = [directoryPath stringByAppendingPathComponent:symlinkName];
		REQUIRE(symlink([filename fileSystemRepresentation], [symlinkPath fileSystemRepresentation]) == 0);
		snapshotError = nil;
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:symlinkName error:&snapshotError] == nil);
		REQUIRE(snapshotError != nil);
		REQUIRE([[controller noteDirectory] observationForFileNamed:symlinkName error:NULL] == nil);
		NVFileWriteResult *symlinkWrite = [[controller noteDirectory]
			overwriteFileNamed:symlinkName withData:[@"must not follow" dataUsingEncoding:NSUTF8StringEncoding]];
		REQUIRE([symlinkWrite disposition] == NVFileWriteNotInstalled);
		REQUIRE(![[controller noteDirectory] renameFileNamed:symlinkName
			toUnusedName:@"Renamed Symlink.txt" error:NULL]);
		REQUIRE(![[controller noteDirectory] removeFileNamed:symlinkName error:NULL]);
		struct stat symlinkStatus;
		REQUIRE(lstat([symlinkPath fileSystemRepresentation], &symlinkStatus) == 0 &&
			S_ISLNK(symlinkStatus.st_mode));
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
		REQUIRE(NVCompareTimespecs(previousChangeTime, currentChangeTime) != NSOrderedSame);

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

		for (NSNumber *documentTier in @[ @YES, @NO ]) {
			BOOL useDocumentIdentifier = [documentTier boolValue];
			NoteObject *duplicateRemoved = [[NoteObject alloc] initWithNoteBody:
				[[[NSAttributedString alloc] initWithString:@"duplicate removed identity"] autorelease]
				title:@"Duplicate Removed Identity" format:PlainTextFormat labels:@""];
			uint64_t identifier = useDocumentIdentifier ? 0x34567890 : 0x0102030405060708ULL;
			NoteCatalogEntry removedIdentity = { fileAttributeChangeTimeOfNote(note),
				useDocumentIdentifier ? 0 : identifier, (CFStringRef)unsavedFilename,
				useDocumentIdentifier ? (uint32_t)identifier : 0 };
			[note updateFileIdentityFromCatalogEntry:&removedIdentity];
			removedIdentity.filename = CFSTR("Duplicate Removed Identity.txt");
			[duplicateRemoved updateFileIdentityFromCatalogEntry:&removedIdentity];
			NoteCatalogEntry addedIdentity = removedIdentity;
			addedIdentity.filename = CFSTR("Ambiguous Removed Identity.txt");
			added = [NSMutableArray arrayWithObject:[NSValue valueWithPointer:&addedIdentity]];
			removed = [NSMutableArray arrayWithObjects:note, duplicateRemoved, nil];
			[controller setInterceptContentFallback:YES];
			[controller processNotesAddedByIdentity:added removed:removed];
			REQUIRE([controller contentFallbackCalled]);
			REQUIRE([added count] == 1 && [removed count] == 2);
			[controller setInterceptContentFallback:NO];
			[duplicateRemoved release];
		}

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
			title:@"Coarse CTime" format:PlainTextFormat labels:@""];
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

static void TestInterleavedDirectoryMerge(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		for (NSString *name in @[ @"B Existing.txt", @"D Deleted.txt",
			@"F Changed.txt", @"H Deleted.txt" ])
			WriteExternalFile(PlainTextFormat, name,
				[directoryPath stringByAppendingPathComponent:name]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *existing = NoteContaining(controller, @"B Existing.txt");
		NoteObject *changed = NoteContaining(controller, @"F Changed.txt");
		REQUIRE(existing != nil && changed != nil);

		WriteExternalFile(PlainTextFormat, @"addition before",
			[directoryPath stringByAppendingPathComponent:@"A Added.txt"]);
		WriteExternalFile(PlainTextFormat, @"addition between",
			[directoryPath stringByAppendingPathComponent:@"E Added.txt"]);
		WriteExternalFile(PlainTextFormat, @"addition after",
			[directoryPath stringByAppendingPathComponent:@"Z Added.txt"]);
		WriteExternalFile(PlainTextFormat, @"unsupported",
			[directoryPath stringByAppendingPathComponent:@"G Unsupported.md"]);
		WriteExternalFileInPlace(@"changed in place",
			[directoryPath stringByAppendingPathComponent:@"F Changed.txt"]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:
			[directoryPath stringByAppendingPathComponent:@"D Deleted.txt"] error:NULL]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:
			[directoryPath stringByAppendingPathComponent:@"H Deleted.txt"] error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE(NoteContaining(controller, @"B Existing.txt") == existing);
		REQUIRE(NoteContaining(controller, @"changed in place") == changed);
		REQUIRE(NoteContaining(controller, @"addition before") != nil);
		REQUIRE(NoteContaining(controller, @"addition between") != nil);
		REQUIRE(NoteContaining(controller, @"addition after") != nil);
		REQUIRE(NoteContaining(controller, @"unsupported") == nil);
		REQUIRE([controller deletionCandidateCount] == 2);

		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:
			[directoryPath stringByAppendingPathComponent:@"Z Added.txt"] error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller deletionCandidateCount] == 3);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestDirectoryReconciliation(void) {
	TestInterleavedDirectoryMerge();
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
		REQUIRE(NVCompareTimespecs(metadataBeforeFailedRefresh,
			fileAttributeChangeTimeOfNote(importedNote)) == NSOrderedSame);
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
		NSString *conflictPath = FileContainingText(directoryPath,
			@"conflicting disk edit", filenameOfNote(importedNote));
		REQUIRE([[conflictPath lastPathComponent] rangeOfString:@"(conflict)"].location != NSNotFound);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:conflictPath error:NULL]);

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
			title:@"Fallback First" format:PlainTextFormat labels:@""];
		secondFallbackNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"same-size-B"] autorelease]
			title:@"Fallback Second" format:PlainTextFormat labels:@""];
		[controller addNewNote:firstFallbackNote];
		[controller addNewNote:secondFallbackNote];
		REQUIRE([controller flushAllNoteChanges]);
		NoteCatalogEntry zeroIdentity = { fileAttributeChangeTimeOfNote(firstFallbackNote), 0,
			(CFStringRef)filenameOfNote(firstFallbackNote), 0 };
		[firstFallbackNote updateFileIdentityFromCatalogEntry:&zeroIdentity];
		zeroIdentity.attributeChangeTime = fileAttributeChangeTimeOfNote(secondFallbackNote);
		zeroIdentity.filename = (CFStringRef)filenameOfNote(secondFallbackNote);
		[secondFallbackNote updateFileIdentityFromCatalogEntry:&zeroIdentity];
		NSString *firstPath = [[firstFallbackNote absoluteUNIXPath] path];
		NSString *secondPath = [[secondFallbackNote absoluteUNIXPath] path];
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
			REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[note absoluteUNIXPath] path] error:NULL]);
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
		[controller setSnapshotCocoaTagsUnavailable:YES];
		REQUIRE(setxattr([renamedPath fileSystemRepresentation], tagsAttribute,
			[badTags bytes], [badTags length], 0, 0) == 0);
		WriteExternalFileInPlace(@"deferred after xattr failure", renamedPath);
		struct timespec metadataBeforeXattrFailure = fileAttributeChangeTimeOfNote(note);
		[controller resetPushScheduleCount];
		[delegate resetContentsUpdatedCount];
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"stable import"]);
		REQUIRE(NVCompareTimespecs(metadataBeforeXattrFailure,
			fileAttributeChangeTimeOfNote(note)) == NSOrderedSame);
		REQUIRE([controller pushScheduleCount] == 0 && [delegate contentsUpdatedCount] == 0);
		REQUIRE(SetTestOpenMetaTags(controller, @[], renamedFilename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([[[note contentString] string] isEqualToString:@"deferred after xattr failure"]);
		[controller setSnapshotCocoaTagsUnavailable:NO];

		NSError *attributeError = nil;
		[controller failNextExtendedAttributeReadNamed:@"com.apple.TextEncoding" readingValue:NO];
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:renamedFilename
			error:&attributeError] == nil);
		REQUIRE([[attributeError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[attributeError code] == EIO);
		REQUIRE(SetTestTextEncoding(controller, NSUTF8StringEncoding,
			renamedFilename, NULL));
		REQUIRE(SetTestOpenMetaTagsOnly(controller, @[], renamedFilename, NULL));
		[controller setSnapshotCocoaTagsUnavailable:YES];
		attributeError = nil;
		[controller failNextExtendedAttributeReadNamed:
			@"com.apple.metadata:kMDItemOMUserTags" readingValue:YES];
		REQUIRE([[controller noteDirectory] snapshotForFileNamed:renamedFilename
			error:&attributeError] == nil);
		REQUIRE([[attributeError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[attributeError code] == EIO);
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
		REQUIRE(NVCompareTimespecs(metadataBeforeDecodeFailure,
			fileAttributeChangeTimeOfNote(note)) == NSOrderedSame);
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
			title:@"Ambiguous First" format:PlainTextFormat labels:@"ghost-tag"];
		NoteObject *second = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"identical content"] autorelease]
			title:@"Ambiguous Second" format:PlainTextFormat labels:@"ghost-tag"];
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
			REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[note absoluteUNIXPath] path] error:NULL]);
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
			title:@"Deleted Candidate" format:PlainTextFormat labels:@""];
		[controller addNewNote:deletedCandidate];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[deletedCandidate absoluteUNIXPath] path]
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
		NSString *conflictPath = FileContainingText(directoryPath,
			@"external conflict", filename);
		REQUIRE(conflictPath != nil);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:conflictPath error:NULL]);

		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"file sink succeeds independently"] autorelease]];
		[controller breakJournalDescriptor];
		REQUIRE(![controller journalFileStillExists]);
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
			title:@"Epoch Five" format:PlainTextFormat labels:@""];
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

/* Hidden helper for tools/test-epoch4-v5-compatibility.sh.  Keep the writer
 * here so the smoke test always creates its input with the current archive
 * implementation instead of checking in a versioned database fixture. */
static void TestWriteEpochFiveCompatibilityDatabase(void) {
	NSString *directoryPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_EPOCH5_DATABASE_DIRECTORY"];
	REQUIRE([directoryPath length]);
	NSError *error = nil;
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:directoryPath
		withIntermediateDirectories:YES attributes:nil error:&error]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:
				@"epoch five compatibility body"] autorelease]
			title:@"Epoch Five Compatibility" format:SingleDatabaseFormat
			labels:@"critical,epoch5"];
		/* Keep these values stable so the historical reader checks the archived
		 * metadata fields as well as the note's visible content. */
		[note setSelectedRange:NSMakeRange(6, 4)];
		[note setFilename:@"epoch-five-compatibility.txt" withExternalTrigger:NO];
		note->fileEncoding = NSISOLatin1StringEncoding;
		[controller addNewNote:note];
		/* addNewNote marks the note dirty and refreshes modifiedDate, so set the
		 * archived timestamps after it has performed that normal bookkeeping. */
		[note setDateAdded:123456789.125];
		[note setDateModified:123456999.875];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *databasePath = [directoryPath stringByAppendingPathComponent:NotesDatabaseFileName];
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:databasePath]);
	} @finally {
		CloseController(&controller);
		[delegate release];
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
	NoteObject *earlier = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"earlier"] autorelease]
		title:@"Earlier" format:SingleDatabaseFormat labels:@""];
	NoteObject *later = [[NoteObject alloc] initWithNoteBody:
		[[[NSAttributedString alloc] initWithString:@"later"] autorelease]
		title:@"Later" format:SingleDatabaseFormat labels:@""];
	[earlier setDateModified:1000.125];
	[later setDateModified:1000.625];
	[earlier setDateAdded:2000.125];
	[later setDateAdded:2000.625];
	id earlierObject = earlier, laterObject = later;
	REQUIRE(compareDateModified(&earlierObject, &laterObject) < 0);
	REQUIRE(compareDateModifiedReverse(&earlierObject, &laterObject) > 0);
	REQUIRE(compareDateCreated(&earlierObject, &laterObject) < 0);
	REQUIRE(compareDateCreatedReverse(&earlierObject, &laterObject) > 0);
	[earlier release];
	[later release];

	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	/* MRC weak loads retain/autorelease their value.  Drain those temporary
	 * references before asserting that the controller itself was released. */
	NSAutoreleasePool *controllerPool = [[NSAutoreleasePool alloc] init];
	NSUInteger originalCount = controllerDeallocationCount;

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller resetLabelAddCount];
		NoteObject *detached = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"detached body"] autorelease]
			title:@"Detached" format:PlainTextFormat labels:@"ghost"];
		REQUIRE(detached != nil && [detached delegate] == nil && filenameOfNote(detached) == nil);
		REQUIRE([controller labelAddCount] == 0);
		[detached _setLabelString:@""];
		[detached attachToDelegate:controller];
		REQUIRE([detached delegate] == controller && filenameOfNote(detached) != nil);
		[detached attachToDelegate:nil];
		REQUIRE([detached delegate] == nil);
		[detached release];
		REQUIRE([[NoteObject alloc] initWithNoteBody:nil title:@"Invalid"
			format:PlainTextFormat labels:@""] == nil);
		CloseController(&controller);
		[controllerPool drain];
		controllerPool = nil;
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (controllerDeallocationCount == originalCount && [deadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
		REQUIRE(controllerDeallocationCount == originalCount + 1);
	} @finally {
		CloseController(&controller);
		[controllerPool drain];
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
		NSAutoreleasePool *controllerPool = [[NSAutoreleasePool alloc] init];
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
		[controllerPool drain];
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
		NVFileWriteResult *result = [[controller noteDirectory]
			overwriteFileNamed:@"Relocated Install.txt" withData:contents
			preparedDataVerifier:^BOOL(NSData *readBackData, NSError **verificationError) {
				(void)readBackData;
				moved = [[NSFileManager defaultManager] moveItemAtPath:oldPath
					toPath:newPath error:verificationError];
				return moved;
			}];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified && moved);
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
		REQUIRE([[[controller noteDirectory] overwriteFileNamed:@"Rename A.txt"
			withData:contents] disposition] ==
			NVFileWriteInstalledVerified);
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
			REQUIRE([[controller noteDirectory] renameFileNamed:currentName
				toUnusedName:nextName error:&error]);
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
		REQUIRE([contents isEqualToData:[[controller noteDirectory]
			dataFromFileNamed:currentName error:&readError]]);
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
	NSString *originalPath = [[original absoluteUNIXPath] path];
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
	WaitForNoteCount(controller, 1);
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
			title:duplicateTitle format:format labels:@"alpha beta"];
		REQUIRE(first != nil);
		[controller addNewNote:first];
		NoteObject *duplicate = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Duplicate-name companion"] autorelease]
			title:duplicateTitle format:format labels:@"gamma"];
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
			: [[first absoluteUNIXPath] path];
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
			REQUIRE([[first absoluteUNIXPath] getResourceValue:&cocoaTags
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
			if (format == HTMLFormat) {
				NSString *path = [[renamed absoluteUNIXPath] path];
				NSMutableString *HTML = [[[NSMutableString alloc] initWithData:
					[NSData dataWithContentsOfFile:path] encoding:NSUTF8StringEncoding] autorelease];
				NSRange body = [HTML rangeOfString:@"<body" options:NSCaseInsensitiveSearch];
				NSRange bodyEnd = body.location == NSNotFound ? NSMakeRange(NSNotFound, 0) :
					[HTML rangeOfString:@">" options:0
						range:NSMakeRange(body.location, [HTML length] - body.location)];
				REQUIRE(body.location != NSNotFound && bodyEnd.location != NSNotFound);
				[HTML insertString:@"<!-- externally authored -->" atIndex:NSMaxRange(bodyEnd)];
				REQUIRE([HTML writeToFile:path atomically:YES
					encoding:NSUTF8StringEncoding error:NULL]);
				REQUIRE([controller synchronizeNotesFromDirectory]);
				NSString *expected = [[[[AllNotes(controller) objectAtIndex:0]
					contentString] string] copy];
				[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
				[controller stopFileNotifications];
				REQUIRE([controller totalNoteCount] == 1);
				renamed = [AllNotes(controller) objectAtIndex:0];
				REQUIRE([[[renamed absoluteUNIXPath] pathExtension]
					caseInsensitiveCompare:@"txt"] == NSOrderedSame);
				REQUIRE([[NSString stringWithContentsOfURL:[renamed absoluteUNIXPath]
					encoding:NSUTF8StringEncoding error:NULL] isEqualToString:expected]);
				[expected release];
			}
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
			title:@"Storage Transition" format:SingleDatabaseFormat labels:@""];
		REQUIRE(note != nil);
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);

		NSString *filePath = [directoryPath stringByAppendingPathComponent:filenameOfNote(note)];
		NSData *externalData = [@"newer external file" dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([externalData writeToFile:filePath options:NSDataWritingAtomic error:NULL]);
		note.fileMergeBaseText = @"newer external file";
		note.fileMergeBaseLabels = @"";
		[controller failNextNoteStoreNamed:filenameOfNote(note)];

		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller recordedWriteError] == EIO);
		REQUIRE(storageFormatOfNote(note) == SingleDatabaseFormat);
		NSString *preservedPath = FileContainingText(directoryPath,
			@"newer external file", nil);
		REQUIRE(preservedPath != nil);
		REQUIRE([preservedPath isEqualToString:filePath]);
		REQUIRE([[NSData dataWithContentsOfFile:preservedPath] isEqualToData:externalData]);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Storage Transition") count] == 1);
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(storageFormatOfNote(note) == SingleDatabaseFormat);
		REQUIRE([filenameOfNote(note) isEqualToString:@"Storage Transition.txt"]);
		NSData *memoryData = [memoryText dataUsingEncoding:NSUTF8StringEncoding];
		[controller mutateNoteNamed:filenameOfNote(note) withData:memoryData
			duringTagSynchronization:YES];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(storageFormatOfNote(note) == PlainTextFormat);
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([[NSData dataWithContentsOfFile:filePath] isEqualToData:memoryData]);
		NSString *conflictPath = FileContainingText(directoryPath,
			@"newer external file", filenameOfNote(note));
		REQUIRE(conflictPath != nil);
		REQUIRE([[NSData dataWithContentsOfFile:conflictPath] isEqualToData:externalData]);
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(storageFormatOfNote(note) == PlainTextFormat);
		REQUIRE([controller pendingFileWriteCount] == 0);
		NSString *storedText = [NSString stringWithContentsOfFile:filePath
			encoding:NSUTF8StringEncoding error:NULL];
		REQUIRE([storedText isEqualToString:memoryText]);
		REQUIRE([[[note contentString] string] isEqualToString:memoryText]);
		REQUIRE([[conflictPath lastPathComponent] rangeOfString:@"(conflict)"].location != NSNotFound);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Storage Transition") count] == 2);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 2);
		NoteObject *conflict = NoteContaining(controller, @"newer external file");
		REQUIRE(conflict != nil);
		REQUIRE([[[conflict contentString] string] isEqualToString:@"newer external file"]);
		REQUIRE([filenameOfNote(conflict) isEqualToString:[conflictPath lastPathComponent]]);
		REQUIRE([[filenameOfNote(conflict) pathExtension] caseInsensitiveCompare:@"txt"] == NSOrderedSame);
		REQUIRE([[NSData dataWithContentsOfURL:[conflict absoluteUNIXPath]] isEqualToData:externalData]);
	} @finally {
		[note release];
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSNumber *formatNumber in @[ @(RTFTextFormat), @(HTMLFormat) ]) {
		int format = [formatNumber intValue];
		directoryPath = CreateTemporaryDirectory();
		delegate = [[NVTestControllerDelegate alloc] init];
		controller = nil;
		note = nil;
		@try {
			controller = CreateController(directoryPath, delegate);
			[[controller notationPrefs] setNotesStorageFormat:format];
			[controller stopFileNotifications];
			note = [[NoteObject alloc] initWithNoteBody:
				[[[NSAttributedString alloc] initWithString:@"initial rich note"] autorelease]
				title:@"Rich Storage Transition" format:format labels:@""];
			REQUIRE(note != nil);
			[controller addNewNote:note];
			REQUIRE([controller flushAllNoteChanges]);
			NSString *filePath = [[note absoluteUNIXPath] path];
			NSData *identicalData = [[[NSData dataWithContentsOfFile:filePath] copy] autorelease];

			[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
			REQUIRE([identicalData writeToFile:filePath options:NSDataWritingAtomic error:NULL]);
			[[controller notationPrefs] setNotesStorageFormat:format];
			[controller stopFileNotifications];
			REQUIRE([controller totalNoteCount] == 1);
			REQUIRE([FilenamesWithPrefix(directoryPath, @"Rich Storage Transition") count] == 1);
			REQUIRE([[NSData dataWithContentsOfFile:filePath] isEqualToData:identicalData]);
			[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
			NSString *memoryText = @"authoritative rich database note";
			[note setContentString:[[[NSAttributedString alloc]
				initWithString:memoryText] autorelease]];
			REQUIRE([controller flushAllNoteChanges]);
			NSMutableData *externalData = [NSMutableData dataWithData:
				DataForExternalFile(format, memoryText)];
			if (format == RTFTextFormat)
				[externalData appendData:[@"\n " dataUsingEncoding:NSUTF8StringEncoding]];
			else {
				NSMutableString *HTML = [[[NSMutableString alloc] initWithData:externalData
					encoding:NSUTF8StringEncoding] autorelease];
				NSRange body = [HTML rangeOfString:@"<body" options:NSCaseInsensitiveSearch];
				NSRange bodyEnd = body.location == NSNotFound ? NSMakeRange(NSNotFound, 0) :
					[HTML rangeOfString:@">" options:0 range:NSMakeRange(body.location,
						[HTML length] - body.location)];
				REQUIRE(bodyEnd.location != NSNotFound);
				[HTML insertString:@"<!-- externally authored -->" atIndex:NSMaxRange(bodyEnd)];
				[externalData setData:[HTML dataUsingEncoding:NSUTF8StringEncoding]];
			}
			REQUIRE([externalData writeToFile:filePath options:NSDataWritingAtomic error:NULL]);
			note.fileMergeBaseData = externalData;

			[[controller notationPrefs] setNotesStorageFormat:format];
			[controller stopFileNotifications];
			NSData *storedData = [NSData dataWithContentsOfFile:filePath];
			NSAttributedString *storedContent = format == RTFTextFormat ?
				[[[NSAttributedString alloc] initWithRTF:storedData documentAttributes:NULL] autorelease] :
				[[[NSAttributedString alloc] initWithHTML:storedData documentAttributes:NULL] autorelease];
			REQUIRE([[storedContent string] rangeOfString:memoryText].location != NSNotFound);
			REQUIRE(![storedData isEqualToData:externalData]);
			REQUIRE([[[note absoluteUNIXPath] path] isEqualToString:filePath]);
			REQUIRE([[[note contentString] string] isEqualToString:memoryText]);
			REQUIRE([FilenamesWithPrefix(directoryPath, @"Rich Storage Transition") count] == 2);
			REQUIRE([controller synchronizeNotesFromDirectory]);
			REQUIRE([controller totalNoteCount] == 2);
			NoteObject *conflict = nil;
			for (NoteObject *candidate in AllNotes(controller))
				if ([filenameOfNote(candidate) rangeOfString:@"(conflict)"].location != NSNotFound)
					conflict = candidate;
			REQUIRE(conflict != nil);
			REQUIRE(conflict != note);
			REQUIRE([filenameOfNote(conflict) rangeOfString:@"(conflict)"].location != NSNotFound);
			NSString *conflictText = [[conflict contentString] string];
			REQUIRE([conflictText rangeOfString:memoryText].location != NSNotFound);
			REQUIRE([conflictText rangeOfString:@"\\rtf"].location == NSNotFound);
			REQUIRE([conflictText rangeOfString:@"<html"
				options:NSCaseInsensitiveSearch].location == NSNotFound);
			REQUIRE([[filenameOfNote(conflict) pathExtension] caseInsensitiveCompare:
				[NotationPrefs pathExtensionForFormat:format]] == NSOrderedSame);
			REQUIRE([[NSData dataWithContentsOfURL:[conflict absoluteUNIXPath]] isEqualToData:externalData]);
		} @finally {
			[note release];
			CloseController(&controller);
			[delegate release];
			RemoveTemporaryDirectory(directoryPath);
		}
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	controller = nil;
	note = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		[controller stopFileNotifications];
		note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"old rich file"] autorelease]
			title:@"Wrong Format Guard" format:RTFTextFormat labels:@""];
		REQUIRE(note != nil);
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *oldPath = [[[[note absoluteUNIXPath] path] copy] autorelease];
		NSData *oldData = [[[NSData dataWithContentsOfFile:oldPath] copy] autorelease];

		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		NSString *memoryText = @"plain database note";
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:memoryText] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *plainPath = [[oldPath stringByDeletingPathExtension]
			stringByAppendingPathExtension:@"txt"];
		NSData *externalData = [@"existing plain destination"
			dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([externalData writeToFile:plainPath options:NSDataWritingAtomic error:NULL]);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE([[[note absoluteUNIXPath] path] isEqualToString:plainPath]);
		REQUIRE([[plainPath pathExtension] caseInsensitiveCompare:@"txt"] == NSOrderedSame);
		REQUIRE([[NSString stringWithContentsOfFile:plainPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:memoryText]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:oldPath]);
		REQUIRE([[NSData dataWithContentsOfFile:oldPath] isEqualToData:oldData]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller totalNoteCount] == 2);
		NoteObject *conflict = NoteContaining(controller, @"existing plain destination");
		REQUIRE(conflict != nil && conflict != note);
		REQUIRE([filenameOfNote(conflict) rangeOfString:@"(conflict)"].location != NSNotFound);
		REQUIRE([[filenameOfNote(conflict) pathExtension]
			caseInsensitiveCompare:@"txt"] == NSOrderedSame);
		REQUIRE([[NSData dataWithContentsOfURL:[conflict absoluteUNIXPath]] isEqualToData:externalData]);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Wrong Format Guard") count] == 3);
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

		NSArray *paths = @[ [[knownNote absoluteUNIXPath] path], importPath ];
		REQUIRE([controller openFiles:paths]);
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE([[delegate revealedNotes] containsObject:knownNote]);
		REQUIRE(NoteContaining(controller, @"imported through openFiles") != nil);
		REQUIRE([[NSString stringWithContentsOfFile:importPath
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"imported through openFiles"]);

		NSString *ordinaryDirectoryPath = [importDirectoryPath stringByAppendingPathComponent:@"Ordinary Folder"];
		NSString *dataDirectoryPath = [importDirectoryPath stringByAppendingPathComponent:@"NV Data Folder"];
		NSString *databaseDirectoryPath = [importDirectoryPath stringByAppendingPathComponent:@"Database Is A Directory"];
		NSFileManager *manager = [NSFileManager defaultManager];
		REQUIRE([manager createDirectoryAtPath:ordinaryDirectoryPath withIntermediateDirectories:NO
			attributes:nil error:NULL]);
		REQUIRE([manager createDirectoryAtPath:dataDirectoryPath withIntermediateDirectories:NO
			attributes:nil error:NULL]);
		REQUIRE([manager createDirectoryAtPath:databaseDirectoryPath withIntermediateDirectories:NO
			attributes:nil error:NULL]);
		REQUIRE([@"" writeToFile:[dataDirectoryPath stringByAppendingPathComponent:NotesDatabaseFileName]
			atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
		REQUIRE([manager createDirectoryAtPath:
			[databaseDirectoryPath stringByAppendingPathComponent:NotesDatabaseFileName]
			withIntermediateDirectories:NO attributes:nil error:NULL]);

		REQUIRE([NVNotationalVelocityDataDirectoryPath(@[ dataDirectoryPath ])
			isEqualToString:dataDirectoryPath]);
		REQUIRE(NVNotationalVelocityDataDirectoryPath(@[ ordinaryDirectoryPath ]) == nil);
		REQUIRE(NVNotationalVelocityDataDirectoryPath(@[ databaseDirectoryPath ]) == nil);
		REQUIRE(NVNotationalVelocityDataDirectoryPath(@[ dataDirectoryPath, importPath ]) == nil);

		NSString *folderImportPath = [dataDirectoryPath stringByAppendingPathComponent:@"Folder Import.txt"];
		WriteExternalFile(PlainTextFormat, @"imported from qualifying data folder", folderImportPath);
		NSURL *originalDirectoryURL = [[controller noteDirectoryURL] retain];
		NSData *originalBookmark = [[[GlobalPrefs defaultPrefs] bookmarkDataForDefaultDirectory] copy];
		NSData *originalAlias = [[[GlobalPrefs defaultPrefs] aliasDataForDefaultDirectory] copy];
		REQUIRE([controller openFiles:@[ dataDirectoryPath ]]);
		REQUIRE(NoteContaining(controller, @"imported from qualifying data folder") != nil);
		REQUIRE(URLsReferToSameItem(originalDirectoryURL, [controller noteDirectoryURL]));
		REQUIRE((!originalBookmark && ![[GlobalPrefs defaultPrefs] bookmarkDataForDefaultDirectory]) ||
			[originalBookmark isEqual:[[GlobalPrefs defaultPrefs] bookmarkDataForDefaultDirectory]]);
		REQUIRE((!originalAlias && ![[GlobalPrefs defaultPrefs] aliasDataForDefaultDirectory]) ||
			[originalAlias isEqual:[[GlobalPrefs defaultPrefs] aliasDataForDefaultDirectory]]);
		[originalAlias release];
		[originalBookmark release];
		[originalDirectoryURL release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(importDirectoryPath);
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestLaunchDirectoryOverride(void) {
	NSString *defaultDirectoryPath = CreateTemporaryDirectory();
	NSString *launchDirectoryPath = CreateTemporaryDirectory();
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	id savedAlias = [[defaults objectForKey:@"DirectoryAlias"] retain];
	id savedBookmark = [[defaults objectForKey:@"DirectoryBookmark"] retain];
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NVLaunchDirectoryAppController *appController = nil;
	@try {
		controller = CreateController(defaultDirectoryPath, delegate);
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		controller = CreateController(launchDirectoryPath, delegate);
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);

		GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
		REQUIRE([prefs setDefaultDirectoryURL:FileReferenceURLForPath(defaultDirectoryPath)
			sender:nil error:NULL]);
		NSData *configuredAlias = [[prefs aliasDataForDefaultDirectory] copy];
		NSData *configuredBookmark = [[prefs bookmarkDataForDefaultDirectory] copy];

		appController = [[NVLaunchDirectoryAppController alloc] init];
		[appController application:NSApp openFiles:@[ launchDirectoryPath ]];
		[appController applicationDidFinishLaunching:[NSNotification notificationWithName:
			NSApplicationDidFinishLaunchingNotification object:NSApp]];

		REQUIRE(URLsReferToSameItem([appController currentNotesDirectoryURL],
			[NSURL fileURLWithPath:launchDirectoryPath]));
		REQUIRE([appController importedLaunchPaths] == nil);
		REQUIRE([configuredAlias isEqual:[prefs aliasDataForDefaultDirectory]]);
		REQUIRE([configuredBookmark isEqual:[prefs bookmarkDataForDefaultDirectory]]);
		[configuredBookmark release];
		[configuredAlias release];
	} @finally {
		[appController closeForTesting];
		[appController release];
		CloseController(&controller);
		[delegate release];
		if (savedAlias) [defaults setObject:savedAlias forKey:@"DirectoryAlias"];
		else [defaults removeObjectForKey:@"DirectoryAlias"];
		if (savedBookmark) [defaults setObject:savedBookmark forKey:@"DirectoryBookmark"];
		else [defaults removeObjectForKey:@"DirectoryBookmark"];
		[savedBookmark release];
		[savedAlias release];
		RemoveTemporaryDirectory(launchDirectoryPath);
		RemoveTemporaryDirectory(defaultDirectoryPath);
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
		NSPanel *deletionPanel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 371, 222)
			styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES] autorelease];
		NSScrollView *deletionScrollView = [[[NSScrollView alloc]
			initWithFrame:NSMakeRect(20, 82, 331, 40)] autorelease];
		NSTableView *deletionTableView = [[[NSTableView alloc]
			initWithFrame:[[deletionScrollView contentView] bounds]] autorelease];
		NSView *deletionHeading = [[[NSView alloc] initWithFrame:NSMakeRect(99, 142, 247, 64)] autorelease];
		[deletionScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[deletionHeading setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[deletionScrollView setDocumentView:deletionTableView];
		[[deletionPanel contentView] addSubview:deletionScrollView];
		[[deletionPanel contentView] addSubview:deletionHeading];
		DeletionManager *sizingManager = [[[DeletionManager alloc]
			initWithNotationController:controller] autorelease];
		[sizingManager setValue:deletionPanel forKey:@"window"];
		[sizingManager setValue:deletionTableView forKey:@"tableView"];
		[deletionTableView setDataSource:sizingManager];
		[[sizingManager valueForKey:@"deletedNotes"] addObjectsFromArray:@[ @1, @2, @3, @4 ]];
		CGFloat oldPanelHeight = NSHeight([deletionPanel frame]);
		CGFloat oldScrollHeight = NSHeight([deletionScrollView frame]);
		CGFloat oldHeadingY = NSMinY([deletionHeading frame]);
		[sizingManager _updatePanelForNotes];
		CGFloat panelGrowth = NSHeight([deletionPanel frame]) - oldPanelHeight;
		REQUIRE([deletionTableView numberOfRows] == 4);
		REQUIRE(fabs(NSHeight([deletionScrollView frame]) - oldScrollHeight - panelGrowth) < 0.5);
		REQUIRE(fabs(NSMinY([deletionHeading frame]) - oldHeadingY - panelGrowth) < 0.5);
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
		NSString *firstPath = [[first absoluteUNIXPath] path];
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
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:[[second absoluteUNIXPath] path] error:NULL]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE([controller deletionCandidateCount] == 2);
		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		[controller processDeletionCandidates];
		REQUIRE([controller totalNoteCount] == 0);

		NoteObject *failed = AddTestNote(controller, @"Failed Trash", @"must remain after failure");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *failedPath = [[failed absoluteUNIXPath] path];
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

		NSArray *formats = @[ @(RTFTextFormat), @(PlainTextFormat), @(HTMLFormat),
			@(RTFTextFormat), @(HTMLFormat), @(PlainTextFormat) ];
		NSString *expectedBody = @"format transition body";
		NSUInteger transition = 0;
		for (NSNumber *format in formats) {
			expectedBody = [NSString stringWithFormat:@"%@\nunflushed edit %lu",
				expectedBody, (unsigned long)++transition];
			[note setContentString:[[[NSAttributedString alloc]
				initWithString:expectedBody] autorelease]];
			[[controller notationPrefs] setNotesStorageFormat:[format intValue]];
			[controller stopFileNotifications];
			REQUIRE([controller flushAllNoteChanges]);
			REQUIRE([controller synchronizeNotesFromDirectory]);
			REQUIRE([controller totalNoteCount] == 1);
			REQUIRE([[[note contentString] string] isEqualToString:expectedBody]);
			NSString *path = [[note absoluteUNIXPath] path];
			REQUIRE([[path pathExtension] caseInsensitiveCompare:
				[NotationPrefs pathExtensionForFormat:[format intValue]]] == NSOrderedSame);
			REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:path]);
			if ([format intValue] == PlainTextFormat)
				REQUIRE([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
					error:NULL] isEqualToString:expectedBody]);
			else {
				NSData *storedData = [NSData dataWithContentsOfFile:path];
				NSString *latestEdit = [NSString stringWithFormat:@"unflushed edit %lu",
					(unsigned long)transition];
				NSData *latestEditData = [latestEdit dataUsingEncoding:NSUTF8StringEncoding];
				REQUIRE([storedData rangeOfData:latestEditData options:0
					range:NSMakeRange(0, [storedData length])].location != NSNotFound);
			}
			REQUIRE([FilenamesWithPrefix(directoryPath, @"Transition Matrix") count] == 1);
		}

		NSString *sourcePath = [[note absoluteUNIXPath] path];
		NSString *retryBody = [expectedBody stringByAppendingString:@"\npreflight retry edit"];
		[note setContentString:[[[NSAttributedString alloc] initWithString:retryBody] autorelease]];
		injectedControllerFlushFailures = 1;
		observedInjectedControllerFlushFailures = 0;
		[controller setUseTestTrash:YES];
		NVStorageFormatChangeProbe *probe = [[[NVStorageFormatChangeProbe alloc]
			initWithFormat:SingleDatabaseFormat] autorelease];
		[[controller notationPrefs] noteFilesCleanupSheetDidEnd:nil
			returnCode:NSAlertThirdButtonReturn contextInfo:probe];
		REQUIRE(observedInjectedControllerFlushFailures == 1);
		REQUIRE([controller currentNoteStorageFormat] == PlainTextFormat);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller trashMoveCount] == 0);
		REQUIRE([probe didChangeCount] == 1 && [probe followupCount] == 0);
		REQUIRE([[[note absoluteUNIXPath] path] isEqualToString:sourcePath]);
		REQUIRE([[NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:expectedBody]);

		REQUIRE([controller flushAllNoteChanges]);
		expectedBody = retryBody;
		WriteExternalFileInPlace(@"unreadable during reconciliation", sourcePath);
		[controller setFailingSnapshotName:filenameOfNote(note)];
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		REQUIRE([controller currentNoteStorageFormat] == PlainTextFormat);
		REQUIRE([[[note absoluteUNIXPath] path] isEqualToString:sourcePath]);
		REQUIRE([[[note contentString] string] isEqualToString:expectedBody]);
		[controller setFailingSnapshotName:nil];
		WriteExternalFileInPlace(expectedBody, sourcePath);

		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller currentNoteStorageFormat] == RTFTextFormat);
		REQUIRE(storageFormatOfNote(note) == RTFTextFormat);
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([[[[NSAttributedString alloc] initWithRTF:
			[NSData dataWithContentsOfURL:[note absoluteUNIXPath]] documentAttributes:NULL]
			autorelease].string isEqualToString:expectedBody]);

		sourcePath = [[note absoluteUNIXPath] path];
		[controller failNextNoteRename];
		[[controller notationPrefs] setNotesStorageFormat:HTMLFormat];
		[controller stopFileNotifications];
		REQUIRE([controller currentNoteStorageFormat] == HTMLFormat);
		REQUIRE(storageFormatOfNote(note) == RTFTextFormat);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller recordedWriteError] == EACCES);
		REQUIRE([[[note absoluteUNIXPath] path] isEqualToString:sourcePath]);
		REQUIRE([[sourcePath pathExtension] caseInsensitiveCompare:@"rtf"] == NSOrderedSame);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Transition Matrix") count] == 1);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(storageFormatOfNote(note) == HTMLFormat);
		REQUIRE([[[note absoluteUNIXPath] pathExtension] caseInsensitiveCompare:@"html"] == NSOrderedSame);

		[controller failNextNoteStore];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller currentNoteStorageFormat] == PlainTextFormat);
		REQUIRE(storageFormatOfNote(note) == HTMLFormat);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([controller recordedWriteError] == EIO);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(storageFormatOfNote(note) == PlainTextFormat);
		REQUIRE([[NSString stringWithContentsOfURL:[note absoluteUNIXPath]
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:expectedBody]);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Transition Matrix") count] == 1);
		NSString *plainPath = [[note absoluteUNIXPath] path];

		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		REQUIRE([controller flushAllNoteChanges]);
		expectedBody = [expectedBody stringByAppendingString:@"\ndatabase-only edit"];
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:expectedBody] autorelease]];
		[note setLabelString:@"database-only-label"];
		REQUIRE([controller flushAllNoteChanges]);
		WriteExternalFile(PlainTextFormat, expectedBody, plainPath);
		REQUIRE(SetTestOpenMetaTags(controller, @[ @"external-only-label" ],
			filenameOfNote(note), NULL));
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(storageFormatOfNote(note) == PlainTextFormat);
		REQUIRE([labelsOfNote(note) isEqualToString:@"database-only-label"]);
		REQUIRE([[NSString stringWithContentsOfFile:plainPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:expectedBody]);
		NSArray *storedTags = [[NSFileManager defaultManager]
			getOpenMetaTagsAtFSPath:[plainPath fileSystemRepresentation]];
		REQUIRE([storedTags containsObject:@"database-only-label"]);
		REQUIRE(![storedTags containsObject:@"external-only-label"]);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Transition Matrix") count] == 1);

		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		REQUIRE([controller flushAllNoteChanges]);
		[controller setUseTestTrash:YES];
		[controller trashRemainingNoteFilesInDirectory];
		REQUIRE([controller trashMoveCount] == 1);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:plainPath]);
		CloseController(&controller);

		controller = CreateController(directoryPath, delegate);
		REQUIRE([controller currentNoteStorageFormat] == SingleDatabaseFormat);
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE(NoteContaining(controller, expectedBody) != nil);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NSString *base = @"first line\nsecond line\nthird line\n";
		NSString *local = @"FIRST LINE\nsecond line\nthird line\n";
		NSString *external = @"first line\nsecond line\nTHIRD LINE\n";
		NSString *merged = @"FIRST LINE\nsecond line\nTHIRD LINE\n";
		NoteObject *note = AddTestNote(controller, @"Merge Then Convert", base);
		REQUIRE([controller flushAllNoteChanges]);
		NSString *path = [[note absoluteUNIXPath] path];
		[note setContentString:[[[NSAttributedString alloc] initWithString:local] autorelease]];
		WriteExternalFile(PlainTextFormat, external, path);
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 1);
		REQUIRE([[[note contentString] string] isEqualToString:merged]);
		REQUIRE([[[note absoluteUNIXPath] pathExtension] caseInsensitiveCompare:@"rtf"] == NSOrderedSame);
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Merge Then Convert") count] == 1);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		[controller stopFileNotifications];
		NoteObject *note = AddTestNote(controller, @"Rich Conflict Then Convert", @"rich base");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *path = [[note absoluteUNIXPath] path];
		[note setContentString:[[[NSAttributedString alloc] initWithString:@"rich local"] autorelease]];
		REQUIRE(note.fileMergeBaseData != nil);
		WriteExternalFile(RTFTextFormat, @"rich external", path);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		REQUIRE([controller totalNoteCount] == 2);
		REQUIRE([[[note contentString] string] isEqualToString:@"rich local"]);
		NoteObject *conflict = NoteContaining(controller, @"rich external");
		REQUIRE(conflict != nil);
		for (NoteObject *converted in AllNotes(controller)) {
			REQUIRE([[filenameOfNote(converted) pathExtension]
				caseInsensitiveCompare:@"txt"] == NSOrderedSame);
			REQUIRE([[NSString stringWithContentsOfURL:[converted absoluteUNIXPath]
				encoding:NSUTF8StringEncoding error:NULL]
				isEqualToString:[[converted contentString] string]]);
		}
		REQUIRE([FilenamesWithPrefix(directoryPath, @"Rich Conflict Then Convert") count] == 2);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	for (NSNumber *sourceFormat in @[ @(RTFTextFormat) ]) {
		directoryPath = CreateTemporaryDirectory();
		delegate = [[NVTestControllerDelegate alloc] init];
		@try {
			controller = CreateController(directoryPath, delegate);
			[[controller notationPrefs] setNotesStorageFormat:[sourceFormat intValue]];
			[controller stopFileNotifications];
			NSString *extension = [NotationPrefs pathExtensionForFormat:[sourceFormat intValue]];
			NSString *filename = [@"Noncanonical Rich" stringByAppendingPathExtension:extension];
			NSString *path = [directoryPath stringByAppendingPathComponent:filename];
			NSMutableData *sourceData = [NSMutableData dataWithData:
				DataForExternalFile([sourceFormat intValue], @"noncanonical rich source")];
			if ([sourceFormat intValue] == HTMLFormat) {
				NSMutableString *HTML = [[[NSMutableString alloc] initWithData:sourceData
					encoding:NSUTF8StringEncoding] autorelease];
				NSRange body = [HTML rangeOfString:@"<body" options:NSCaseInsensitiveSearch];
				NSRange bodyEnd = body.location == NSNotFound ? NSMakeRange(NSNotFound, 0) :
					[HTML rangeOfString:@">" options:0 range:NSMakeRange(body.location,
						[HTML length] - body.location)];
				REQUIRE(bodyEnd.location != NSNotFound);
				[HTML insertString:@"<!-- externally authored -->" atIndex:NSMaxRange(bodyEnd)];
				[sourceData setData:[HTML dataUsingEncoding:NSUTF8StringEncoding]];
			} else {
				[sourceData appendData:[@"\n \n" dataUsingEncoding:NSUTF8StringEncoding]];
			}
			REQUIRE([sourceData writeToFile:path options:NSDataWritingAtomic error:NULL]);
			REQUIRE([controller synchronizeNotesFromDirectory]);
			REQUIRE([controller totalNoteCount] == 1);
			NoteObject *note = [AllNotes(controller) objectAtIndex:0];
			NSString *expected = [[[note contentString] string] copy];
			[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
			[controller stopFileNotifications];
			REQUIRE([controller totalNoteCount] == 1);
			REQUIRE([[[note contentString] string] isEqualToString:expected]);
			REQUIRE([[[note absoluteUNIXPath] pathExtension] caseInsensitiveCompare:@"txt"] == NSOrderedSame);
			REQUIRE([[NSString stringWithContentsOfURL:[note absoluteUNIXPath]
				encoding:NSUTF8StringEncoding error:NULL] isEqualToString:expected]);
			REQUIRE([FilenamesWithPrefix(directoryPath, @"Noncanonical Rich") count] == 1);
			[expected release];
		} @finally {
			CloseController(&controller);
			[delegate release];
			RemoveTemporaryDirectory(directoryPath);
		}
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

static void TestExternalEditorWriterChild(void) {
	NSString *path = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_EXTERNAL_EDITOR_PATH"];
	REQUIRE([path length]);
	WriteExternalFileInPlace(@"changed through the live direct-file watcher", path);
}

static void TestLiveFSEvents(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSAutoreleasePool *controllerPool = [[NSAutoreleasePool alloc] init];
	NSUInteger originalDeallocationCount = controllerDeallocationCount;
	BOOL controllerWasCreated = NO;
	pid_t child = -1;
	NoteObject *note = nil;
	NSString *backupProbePath = nil;
	@try {
		liveFSEventsEnabled = YES;
		controller = CreateController(directoryPath, delegate);
		controllerWasCreated = YES;
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[[controller notationPrefs] setConfirmsFileDeletion:NO];
		ExternalEditingSession *scratchEditor = [ExternalEditingSession sharedExternalEditingSession];
		[NSObject cancelPreviousPerformRequestsWithTarget:scratchEditor
			selector:@selector(initializeDatabase:) object:[controller notationPrefs]];
		[scratchEditor initializeDatabase:[controller notationPrefs]];
		backupProbePath = [scratchEditor createScratchFileNamed:@"Backup Exclusion Probe"
			data:[@"scratch" dataUsingEncoding:NSUTF8StringEncoding]];
		REQUIRE(backupProbePath != nil);
		NSString *backupRootPath = [backupProbePath stringByDeletingLastPathComponent];
		const char *backupExclusionName = "com.apple.metadata:com_apple_backup_excludeItem";
		ssize_t backupExclusionLength = getxattr([backupRootPath fileSystemRepresentation],
			backupExclusionName, NULL, 0, 0, 0);
		REQUIRE(backupExclusionLength > 0);
		NSMutableData *backupExclusionValue = [NSMutableData dataWithLength:(NSUInteger)backupExclusionLength];
		REQUIRE(getxattr([backupRootPath fileSystemRepresentation], backupExclusionName,
			[backupExclusionValue mutableBytes], (size_t)backupExclusionLength, 0, 0) == backupExclusionLength);
		NSData *expectedBackupExclusionValue = [NSPropertyListSerialization
			dataWithPropertyList:@"com.apple.backupd" format:NSPropertyListBinaryFormat_v1_0
			options:0 error:NULL];
		REQUIRE([backupExclusionValue isEqualToData:expectedBackupExclusionValue]);
		errno = 0;
		REQUIRE(getxattr([backupProbePath fileSystemRepresentation], backupExclusionName,
			NULL, 0, 0, 0) < 0 && errno == ENOATTR);

		NoteObject *scratchNote = AddTestNote(controller, @"Live Scratch Event", @"scratch");
		InstallExternalEditorOpenInterception();
		interceptExternalEditorOpen = YES;
		ExternalEditor *testEditor = [[NVTestExternalEditor alloc] initWithDirectEditing:NO];
		REQUIRE([scratchEditor editNote:scratchNote inEditor:testEditor context:nil]);
		REQUIRE([observedExternalEditorSessionPath length] &&
			[[observedExternalEditorURL path] isEqualToString:observedExternalEditorSessionPath]);
		struct stat scratchInfo = { 0 };
		REQUIRE(stat([observedExternalEditorSessionPath fileSystemRepresentation],
			&scratchInfo) == 0 && (scratchInfo.st_mode & 0777) == 0600);
		REQUIRE([@"changed through the live scratch watcher"
			writeToFile:observedExternalEditorSessionPath
			atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
		NSDate *scratchDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
		while (![[[scratchNote contentString] string]
			isEqualToString:@"changed through the live scratch watcher"] &&
			[scratchDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([[[scratchNote contentString] string]
			isEqualToString:@"changed through the live scratch watcher"]);
		[scratchEditor abortAllEditingSessionsForClient:scratchNote];
		REQUIRE(![[NSFileManager defaultManager]
			fileExistsAtPath:observedExternalEditorSessionPath]);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(unlink([backupProbePath fileSystemRepresentation]) == 0);
		interceptExternalEditorOpen = NO;
		[testEditor release];
		[observedExternalEditorURL release];
		observedExternalEditorURL = nil;
		[observedExternalEditorSessionPath release];
		observedExternalEditorSessionPath = nil;
		interceptExternalEditorOpen = YES;
		ExternalEditor *directEditor = [[NVTestExternalEditor alloc] initWithDirectEditing:YES];
		REQUIRE([scratchEditor editNote:scratchNote inEditor:directEditor context:nil]);
		REQUIRE(observedExternalEditorSessionPath == nil &&
			[[observedExternalEditorURL path] isEqualToString:[[scratchNote absoluteUNIXPath] path]]);
		SpawnScenarioWithEnvironment(@"external-editor-writer-child",
			"NV_EXTERNAL_EDITOR_PATH", [observedExternalEditorURL path], 0);
		NSDate *directDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
		while (![[[scratchNote contentString] string]
			isEqualToString:@"changed through the live direct-file watcher"] &&
			[directDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([[[scratchNote contentString] string]
			isEqualToString:@"changed through the live direct-file watcher"]);
		NSArray *liveTags = @[ @"Red", @"Caf\u00e9\u6771\u4eac" ];
		SpawnScenarioWithEnvironment(@"system-tag-writer-child", "NV_SYSTEM_TAG_PATH",
			[observedExternalEditorURL path], 0);
		NSDate *tagDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
		while (!TagSetsEqual([scratchNote orderedLabelTitles], liveTags) &&
			[tagDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE(TagSetsEqual([scratchNote orderedLabelTitles], liveTags));
		interceptExternalEditorOpen = NO;
		[directEditor release];
		[observedExternalEditorURL release];
		observedExternalEditorURL = nil;
		[controller removeNote:scratchNote];
		REQUIRE([controller totalNoteCount] == 0);
		backupProbePath = nil;
		[scratchEditor stopScratchWatcher];
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

		/* Exercise the real encrypted external-editing route. The preparer exposes a
		 * path here only after production code has verified the HFS RAM disk. */
		[[controller notationPrefs] setNotesStorageFormat:SingleDatabaseFormat];
		[[controller notationPrefs] setPassphraseData:EncryptionTestPassphrase()
			inKeychain:NO];
		[[controller notationPrefs] setDoesEncryption:YES];
		[NSObject cancelPreviousPerformRequestsWithTarget:scratchEditor
			selector:@selector(initializeDatabase:) object:[controller notationPrefs]];
		TemporaryFileCachePreparer *encryptedPreparer =
			[scratchEditor valueForKey:@"editingSpacePreparer"];
		NSDate *encryptionDeadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
		while (![[encryptedPreparer preparedCachePath] length] &&
			[encryptionDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		NSString *encryptedRoot = [encryptedPreparer preparedCachePath];
		REQUIRE([[encryptedRoot stringByDeletingLastPathComponent] isEqualToString:
			[NSTemporaryDirectory() stringByAppendingPathComponent:@"NVProtectedEditingSpace"]]);
		struct statfs encryptedFileSystem = { 0 };
		REQUIRE(statfs([encryptedRoot fileSystemRepresentation], &encryptedFileSystem) == 0);
		REQUIRE(strcmp(encryptedFileSystem.f_fstypename, "hfs") == 0);

		NoteObject *encryptedNote = AddTestNote(controller, @"Encrypted External Edit",
			@"encrypted scratch baseline");
		interceptExternalEditorOpen = YES;
		ExternalEditor *encryptedEditor = [[NVTestExternalEditor alloc]
			initWithDirectEditing:NO];
		REQUIRE([scratchEditor editNote:encryptedNote inEditor:encryptedEditor context:nil]);
		NSString *encryptedScratchPath = [[observedExternalEditorSessionPath copy] autorelease];
		NSString *encryptedScratchName = [encryptedScratchPath lastPathComponent];
		REQUIRE([[encryptedPreparer preparedDirectory]
			regularFileExistsNamed:encryptedScratchName]);
		REQUIRE(URLsReferToSameItem(
			[NSURL fileURLWithPath:[encryptedScratchPath stringByDeletingLastPathComponent]],
			[NSURL fileURLWithPath:encryptedRoot]));
		REQUIRE([@"encrypted scratch watcher secret"
			writeToFile:encryptedScratchPath atomically:YES
			encoding:NSUTF8StringEncoding error:NULL]);
		NSDate *encryptedEditDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
		while (![[[encryptedNote contentString] string]
			isEqualToString:@"encrypted scratch watcher secret"] &&
			[encryptedEditDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([[[encryptedNote contentString] string]
			isEqualToString:@"encrypted scratch watcher secret"]);
		[scratchEditor abortAllEditingSessionsForClient:encryptedNote];
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:encryptedScratchPath]);
		interceptExternalEditorOpen = NO;
		[encryptedEditor release];
	} @finally {
		interceptExternalEditorOpen = NO;
		[observedExternalEditorURL release];
		observedExternalEditorURL = nil;
		[observedExternalEditorSessionPath release];
		observedExternalEditorSessionPath = nil;
		[note release];
		if (backupProbePath) [[NSFileManager defaultManager] removeItemAtPath:backupProbePath error:NULL];
		[[ExternalEditingSession sharedExternalEditingSession] stopScratchWatcher];
		if (child > 0) {
			kill(child, SIGTERM);
			waitpid(child, NULL, 0);
		}
		CloseController(&controller);
		[controllerPool drain];
		controllerPool = nil;
		liveFSEventsEnabled = NO;
		if (controllerWasCreated) {
			NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
			while (controllerDeallocationCount == originalDeallocationCount &&
				[deadline timeIntervalSinceNow] > 0.0)
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
			REQUIRE(controllerDeallocationCount == originalDeallocationCount + 1);
		}
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
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:[[slash absoluteUNIXPath] path]]);
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

static NSUInteger CaseInsensitiveFilenameCount(NSString *directoryPath,
	NSString *filename) {
	NSUInteger count = 0;
	for (NSString *name in [[NSFileManager defaultManager]
		contentsOfDirectoryAtPath:directoryPath error:NULL])
		if ([name caseInsensitiveCompare:filename] == NSOrderedSame) count++;
	return count;
}

static void TestCaseSensitiveFilenameCollisions(void) {
	REQUIRE([[[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_EXPECT_CASE_SENSITIVE"] boolValue]);
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];

		NSString *untrackedCreateName = @"untracked collision.txt";
		NSString *untrackedCreatePath = [directoryPath
			stringByAppendingPathComponent:untrackedCreateName];
		WriteExternalFile(PlainTextFormat, @"external create collision",
			untrackedCreatePath);
		NoteObject *createdNote = AddTestNote(controller, @"Untracked Collision",
			@"local create collision");
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([filenameOfNote(createdNote)
			caseInsensitiveCompare:untrackedCreateName] != NSOrderedSame);
		REQUIRE([[NSString stringWithContentsOfFile:untrackedCreatePath
			encoding:NSUTF8StringEncoding error:NULL]
			isEqualToString:@"external create collision"]);
		REQUIRE(CaseInsensitiveFilenameCount(directoryPath, untrackedCreateName) == 1);

		NoteObject *renamedNote = AddTestNote(controller, @"Rename Source",
			@"local rename collision");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *renameSourceName = [[filenameOfNote(renamedNote) copy] autorelease];
		NSString *renameSourcePath = [directoryPath
			stringByAppendingPathComponent:renameSourceName];
		NSString *untrackedRenameName = @"rename target.txt";
		NSString *untrackedRenamePath = [directoryPath
			stringByAppendingPathComponent:untrackedRenameName];
		WriteExternalFile(PlainTextFormat, @"external rename collision",
			untrackedRenamePath);
		[renamedNote setTitleString:@"Rename Target"];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([filenameOfNote(renamedNote)
			caseInsensitiveCompare:untrackedRenameName] != NSOrderedSame);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:renameSourcePath]);
		REQUIRE([[NSString stringWithContentsOfFile:untrackedRenamePath
			encoding:NSUTF8StringEncoding error:NULL]
			isEqualToString:@"external rename collision"]);
		REQUIRE(CaseInsensitiveFilenameCount(directoryPath, untrackedRenameName) == 1);

		NoteObject *caseOnlyNote = AddTestNote(controller, @"Case Only Note",
			@"case-only rename");
		REQUIRE([controller flushAllNoteChanges]);
		[caseOnlyNote setTitleString:@"case only note"];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([filenameOfNote(caseOnlyNote) isEqualToString:@"case only note.txt"]);
		REQUIRE(CaseInsensitiveFilenameCount(directoryPath,
			@"case only note.txt") == 1);

		NSArray *modelBeforeCollision = [[AllNotes(controller) copy] autorelease];
		NSString *physicalUpperPath = [directoryPath
			stringByAppendingPathComponent:@"Physical Collision.txt"];
		NSString *physicalLowerPath = [directoryPath
			stringByAppendingPathComponent:@"physical collision.TXT"];
		WriteExternalFile(PlainTextFormat, @"upper physical collision", physicalUpperPath);
		WriteExternalFile(PlainTextFormat, @"lower physical collision", physicalLowerPath);
		REQUIRE(CaseInsensitiveFilenameCount(directoryPath,
			@"physical collision.txt") == 2);
		REQUIRE(![controller synchronizeNotesFromDirectory]);
		REQUIRE([AllNotes(controller) isEqualToArray:modelBeforeCollision]);
		REQUIRE(NoteContaining(controller, @"upper physical collision") == nil);
		REQUIRE(NoteContaining(controller, @"lower physical collision") == nil);
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
	AssertLockContentionBypassesRecovery();
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

		NSString *mergeFilename = @"Latin One Merge.txt";
		NSString *mergePath = [directoryPath stringByAppendingPathComponent:mergeFilename];
		NSString *mergeBase = @"caf\u00e9 first line\nsecond line\nthird line\n";
		REQUIRE([[mergeBase dataUsingEncoding:NSISOLatin1StringEncoding]
			writeToFile:mergePath options:0 error:NULL]);
		REQUIRE(SetTestTextEncoding(controller, NSISOLatin1StringEncoding,
			mergeFilename, NULL));
		REQUIRE([controller synchronizeNotesFromDirectory]);
		NoteObject *mergeNote = NoteContaining(controller, mergeBase);
		REQUIRE(mergeNote != nil);
		REQUIRE(fileEncodingOfNote(mergeNote) == NSISOLatin1StringEncoding);
		NSString *mergeLocal = @"\u6771 caf\u00e9 first line\nsecond line\nthird line\n";
		NSString *mergeExternal = @"caf\u00e9 first line\nsecond line\nTHIRD LINE\n";
		NSString *mergeExpected = @"\u6771 caf\u00e9 first line\nsecond line\nTHIRD LINE\n";
		[mergeNote setContentString:[[[NSAttributedString alloc]
			initWithString:mergeLocal] autorelease]];
		REQUIRE([[mergeExternal dataUsingEncoding:NSISOLatin1StringEncoding]
			writeToFile:mergePath options:0 error:NULL]);
		REQUIRE(removexattr([mergePath fileSystemRepresentation],
			"com.apple.TextEncoding", 0) == 0);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(fileEncodingOfNote(mergeNote) == NSUTF8StringEncoding);
		REQUIRE([[NSData dataWithContentsOfFile:mergePath]
			isEqualToData:[mergeExpected dataUsingEncoding:NSUTF8StringEncoding]]);
		REQUIRE([[NSFileManager defaultManager] textEncodingAttributeOfFSPath:
			[mergePath fileSystemRepresentation]] == NSUTF8StringEncoding);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestFilesystemCRUD(void) {
	NSError *decodeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
	NSData *wrongTags = [NSPropertyListSerialization dataWithPropertyList:@{}
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
	REQUIRE(NVOpenMetaTagsFromData(wrongTags, &decodeError) == nil && [decodeError code] == EINVAL);
	struct timespec earlier = { 42, 1 }, later = { 42, 2 };
	REQUIRE(NVCompareTimespecs(earlier, later) == NSOrderedAscending);
	REQUIRE(NVCompareTimespecs(later, earlier) == NSOrderedDescending);
	REQUIRE(NVCompareTimespecs(earlier, earlier) == NSOrderedSame);
	CFAbsoluteTime beforeReferenceDate = -3600.25;
	REQUIRE(NVAbsoluteTimeFromTimespec(
		NVTimespecFromAbsoluteTime(beforeReferenceDate)) == beforeReferenceDate);

	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];
		NoteObject *note = AddTestNote(controller, @"Filesystem CRUD", @"created on test volume");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *directoryName = @"Not A Regular File";
		NSString *symlinkName = @"Regular File Link.txt";
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:
			[directoryPath stringByAppendingPathComponent:directoryName]
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		REQUIRE(symlink([filenameOfNote(note) fileSystemRepresentation],
			[[directoryPath stringByAppendingPathComponent:symlinkName]
				fileSystemRepresentation]) == 0);
		REQUIRE([[controller noteDirectory] caseInsensitiveRegularFileExistsNamed:
			[filenameOfNote(note) uppercaseString] excludingName:nil]);
		REQUIRE(![[controller noteDirectory] caseInsensitiveRegularFileExistsNamed:
			directoryName excludingName:nil]);
		REQUIRE(![[controller noteDirectory] caseInsensitiveRegularFileExistsNamed:
			symlinkName excludingName:nil]);
		NSString *oldPath = [[note absoluteUNIXPath] path];
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

static void TestFileBarrierSync(void) {
	char temporaryPath[] = "/tmp/nv-file-barrier.XXXXXX";
	int fileDescriptor = mkstemp(temporaryPath);
	REQUIRE(fileDescriptor >= 0);
	REQUIRE(write(fileDescriptor, "x", 1) == 1);
	REQUIRE(NVBarrierSyncFileDescriptor(fileDescriptor) == 0);
	REQUIRE(close(fileDescriptor) == 0);
	REQUIRE(unlink(temporaryPath) == 0);

	/* Character devices do not support the barrier command, while fsync() on
	 * /dev/null succeeds.  This exercises the compatibility fallback. */
	fileDescriptor = open("/dev/null", O_WRONLY | O_CLOEXEC);
	REQUIRE(fileDescriptor >= 0);
	REQUIRE(fcntl(fileDescriptor, F_BARRIERFSYNC, 0) < 0);
	REQUIRE(NVBarrierSyncFileDescriptor(fileDescriptor) == 0);
	REQUIRE(close(fileDescriptor) == 0);
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
			title:@"Rename Before" format:PlainTextFormat labels:@""];
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
		REQUIRE(![[controller noteDirectory] renameFileNamed:oldName
			toUnusedName:newName error:&error]);
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
		REQUIRE(!NVURLIsInTrash([[controller noteDirectory] transientFileReferenceURL]));
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
			title:@"Moved Directory Note" format:SingleDatabaseFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[newPath stringByAppendingPathComponent:NotesDatabaseFileName]]);
		REQUIRE([[NSData dataWithContentsOfURL:databaseReferenceURL] length] > 0);
		REQUIRE([[[directoryReferenceURL path] lastPathComponent] isEqualToString:[newPath lastPathComponent]]);
		REQUIRE(!NVURLIsInTrash([[controller noteDirectory] transientFileReferenceURL]));
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
			title:@"Location Migration" format:SingleDatabaseFormat labels:@""];
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
	NVRootedDirectory *persistentRoot = nil;
	NSURL *deepURL = nil;
	NSMutableArray *directoryFDs = [NSMutableArray array];
	NSMutableArray *components = [NSMutableArray array];
	BOOL moved = NO;

	@try {
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:notesPath
			withIntermediateDirectories:YES attributes:nil error:NULL]);
		deepURL = [FileReferenceURLForPath(notesPath) retain];
		NSError *rootError = nil;
		persistentRoot = [[NVRootedDirectory alloc]
			initWithFileReferenceURL:deepURL error:&rootError];
		REQUIRE(persistentRoot != nil && rootError == nil);
		OSStatus openStatus = noErr;
		controller = [[NVTestNotationController alloc]
			initWithRootedDirectory:persistentRoot error:&openStatus];
		REQUIRE(controller != nil && openStatus == noErr);
		[controller setDelegate:delegate];
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
		NSError *deepOpenError = nil;
		REQUIRE(![persistentRoot relocateIntoDirectoryReferenceURL:deepURL error:&deepOpenError]);
		REQUIRE([[deepOpenError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[deepOpenError code] == EINVAL);
		REQUIRE(!NVURLIsInTrash([[controller noteDirectory] transientFileReferenceURL]));

		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"Stored beyond PATH_MAX"] autorelease]
			title:@"Deep Note" format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(URLIsReferenceBased([note absoluteUNIXPath]));
		NSError *readError = nil;
		NSData *storedData = [[controller noteDirectory]
			dataFromFileNamed:filenameOfNote(note) error:&readError];
		REQUIRE(storedData != nil);
		REQUIRE(readError == nil);
		NSString *storedString = [[[NSString alloc] initWithData:storedData encoding:NSUTF8StringEncoding] autorelease];
		REQUIRE([storedString rangeOfString:@"beyond PATH_MAX"].location != NSNotFound);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		REQUIRE(NoteContaining(controller, @"beyond PATH_MAX") != nil);
		[note release];
		note = nil;
		CloseController(&controller);
		OSStatus reopenStatus = noErr;
		controller = [[NVTestNotationController alloc]
			initWithRootedDirectory:persistentRoot error:&reopenStatus];
		REQUIRE(controller != nil && reopenStatus == noErr);
		[controller setDelegate:delegate];
		[controller stopFileNotifications];
		note = [NoteContaining(controller, @"beyond PATH_MAX") retain];
		REQUIRE(note != nil);

		NSData *externalData = [@"Externally changed beyond PATH_MAX" dataUsingEncoding:NSUTF8StringEncoding];
		NSFileHandle *noteHandle = [[controller noteDirectory]
			openExistingRegularFileForUpdatingNamed:filenameOfNote(note) error:NULL];
		REQUIRE(noteHandle != nil);
		int noteFD = [noteHandle fileDescriptor];
		REQUIRE(noteFD >= 0);
		REQUIRE(ftruncate(noteFD, 0) == 0);
		REQUIRE(write(noteFD, [externalData bytes], [externalData length]) == (ssize_t)[externalData length]);
		REQUIRE(fsync(noteFD) == 0);
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
		[persistentRoot release];
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
		NSString *verifiedName = @"Verified Install.dat";
		[controller failNextDirectorySynchronization];
		NVFileWriteResult *verified = [[controller noteDirectory]
			overwriteFileNamed:verifiedName withData:replacement];
		REQUIRE([verified disposition] == NVFileWriteInstalledVerified);
		REQUIRE([verified installedSnapshot] != nil);
		REQUIRE([[[verified installedSnapshot] data] isEqualToData:replacement]);
		REQUIRE([verified error] == nil);
		REQUIRE([[[controller noteDirectory] dataFromFileNamed:verifiedName error:NULL]
			isEqualToData:replacement]);
		NSError *synchronizationError = nil;
		REQUIRE(![[controller noteDirectory] synchronize:&synchronizationError]);
		REQUIRE([[synchronizationError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[synchronizationError code] == EIO);

		NoteObject *databaseNote = AddTestNote(controller, @"Database Durability",
			@"database state must remain pending after directory sync failure");
		[controller failNextDirectorySynchronization];
		REQUIRE(![controller flushAllNoteChanges]);
		REQUIRE([controller databaseChangesPending]);
		REQUIRE([controller writeRetryIsScheduled]);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE(![controller databaseChangesPending]);
		(void)databaseNote;

		NSString *createName = @"Create Only.dat";
		NSString *createPath = [directoryPath stringByAppendingPathComponent:createName];
		NVFileWriteResult *result = [[controller noteDirectory] createFileNamed:createName
			withData:baseline];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		result = [[controller noteDirectory] createFileNamed:createName withData:replacement];
		error = [result error];
		REQUIRE([result disposition] == NVFileWriteNotInstalled);
		REQUIRE([[error domain] isEqualToString:NSCocoaErrorDomain] &&
			[error code] == NSFileWriteFileExistsError);
		REQUIRE([[NSData dataWithContentsOfFile:createPath] isEqualToData:baseline]);
		RequireNoTemporaryFiles(directoryPath);

		NSString *collidingTemporaryName = @".nv-write-existing";
		NSString *collidingTemporaryPath = [directoryPath
			stringByAppendingPathComponent:collidingTemporaryName];
		NSData *unownedTemporaryData = [@"not owned by this write"
			dataUsingEncoding:NSUTF8StringEncoding];
		REQUIRE([unownedTemporaryData writeToFile:collidingTemporaryPath options:0 error:NULL]);
		[controller useTemporaryFilename:collidingTemporaryName];
		result = [[controller noteDirectory] createFileNamed:@"Temporary Collision.dat"
			withData:replacement];
		REQUIRE([result disposition] == NVFileWriteNotInstalled);
		REQUIRE([[NSData dataWithContentsOfFile:collidingTemporaryPath]
			isEqualToData:unownedTemporaryData]);
		REQUIRE([[NSFileManager defaultManager] removeItemAtPath:collidingTemporaryPath error:NULL]);

		NSString *cleanupFailureName = @"Cleanup Failure.dat";
		[controller forceNextExclusiveRenameUnavailable];
		[controller failNextTemporaryRemoval];
		result = [[controller noteDirectory] createFileNamed:cleanupFailureName withData:replacement];
		REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
		REQUIRE([result capability] == NVFileWriteHFSCompatibilityCapability);
		REQUIRE([[[result installedSnapshot] data] isEqualToData:replacement]);
		REQUIRE([[[result error] domain] isEqualToString:NSPOSIXErrorDomain] &&
			[[result error] code] == EIO && [[result recoveryFilename] length] > 0);
		REQUIRE([[controller noteDirectory] removeFileNamed:[result recoveryFilename] error:NULL]);

		NSString *conditionalName = @"Conditional.dat";
		NSString *conditionalPath = [directoryPath stringByAppendingPathComponent:conditionalName];
		result = [[controller noteDirectory] overwriteFileNamed:conditionalName withData:baseline];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		REQUIRE(chmod([conditionalPath fileSystemRepresentation], 0640) == 0);
		REQUIRE(setxattr([conditionalPath fileSystemRepresentation],
			"com.notationalvelocity.integration-test", [sentinel bytes], [sentinel length], 0, 0) == 0);
		NVFileSnapshot *baselineSnapshot = [[controller noteDirectory]
			snapshotForFileNamed:conditionalName error:NULL];
		NVFileSnapshot *wrongSnapshot = [[[NVFileSnapshot alloc] initWithData:replacement
			tags:[baselineSnapshot tags] encoding:[baselineSnapshot encoding]
			observation:[baselineSnapshot observation]] autorelease];
		result = [[controller noteDirectory] replaceFileNamed:conditionalName
			withData:replacement expectedSnapshot:wrongSnapshot];
		error = [result error];
		REQUIRE([result disposition] == NVFileWriteNotInstalled);
		REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == EAGAIN);
		REQUIRE([[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:baseline]);
		result = [[controller noteDirectory] replaceFileNamed:conditionalName
			withData:replacement expectedSnapshot:baselineSnapshot];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified &&
			[[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:replacement]);
		REQUIRE([IntegrationTestAttribute(conditionalPath) isEqualToData:sentinel]);
		RequireMode(conditionalPath, 0640);
		RequireNoTemporaryFiles(directoryPath);

		NSString *conflictName = @"Atomic Conflict.txt";
		NSString *conflictPath = [directoryPath stringByAppendingPathComponent:conflictName];
		NSData *racingData = [@"third-party racing contents" dataUsingEncoding:NSUTF8StringEncoding];
		result = [[controller noteDirectory] overwriteFileNamed:conflictName withData:baseline];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:conflictName error:NULL];
		[controller replaceNoteNamed:conflictName beforeInstallWithData:racingData];
		result = [[controller noteDirectory] replaceNoteFileNamed:conflictName withData:replacement
			encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
			modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
		error = [result error];
		REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
		REQUIRE(error != nil && [[result recoveryFilename] length] > 0);
		REQUIRE([[NSData dataWithContentsOfFile:conflictPath] isEqualToData:replacement]);
		NSMutableArray *recoveryNames = [NSMutableArray array];
		for (NSString *name in [[NSFileManager defaultManager]
			contentsOfDirectoryAtPath:directoryPath error:NULL])
			if ([name hasPrefix:@"Atomic Conflict (conflict recovery "] &&
				[[name pathExtension] isEqualToString:@"txt"])
				[recoveryNames addObject:name];
		REQUIRE([recoveryNames count] == 1);
		REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
			[recoveryNames objectAtIndex:0]]] isEqualToData:racingData]);
		RequireNoTemporaryFiles(directoryPath);

		NSArray *invalidNames = @[ @"", @".", @"..", @"../escape",
			[NSString stringWithFormat:@"nul%Cname", (unichar)0] ];
		for (NSString *invalidName in invalidNames) {
			result = [[controller noteDirectory] overwriteFileNamed:invalidName withData:baseline];
			REQUIRE([result disposition] == NVFileWriteNotInstalled && [result error] != nil);
			error = nil;
			REQUIRE([[NSFileManager defaultManager] fileReferenceURLForFilename:invalidName
				inDirectoryURL:[controller noteDirectoryURL] error:&error] == nil && error != nil);
		}
		result = [[controller noteDirectory] overwriteFileNamed:[path lastPathComponent]
			withData:baseline];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		REQUIRE(chmod([path fileSystemRepresentation], 0640) == 0);
		REQUIRE(setxattr([path fileSystemRepresentation], "com.notationalvelocity.integration-test",
			[sentinel bytes], [sentinel length], 0, 0) == 0);

		[controller setAtomicVerificationResult:ioErr];
		result = [[controller noteDirectory] overwriteFileNamed:[path lastPathComponent]
			withData:replacement preparedDataVerifier:^BOOL(NSData *readBackData,
				NSError **verificationError) {
				(void)readBackData;
				if ([controller atomicVerificationResult] == noErr) return YES;
				if (verificationError) *verificationError = [NSError errorWithDomain:NSOSStatusErrorDomain
					code:[controller atomicVerificationResult] userInfo:nil];
				return NO;
			}];
		error = [result error];
		REQUIRE([result disposition] == NVFileWriteNotInstalled);
		REQUIRE(error != nil);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:baseline]);
		REQUIRE([IntegrationTestAttribute(path) isEqualToData:sentinel]);
		RequireMode(path, 0640);
		RequireNoTemporaryFiles(directoryPath);

		[controller setAtomicVerificationResult:noErr];
		result = [[controller noteDirectory] overwriteFileNamed:[path lastPathComponent]
			withData:replacement preparedDataVerifier:^BOOL(NSData *readBackData,
				NSError **verificationError) {
				(void)verificationError;
				return [readBackData isEqualToData:replacement];
			}];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		REQUIRE([[NSData dataWithContentsOfFile:path] isEqualToData:replacement]);
		RequireMode(path, 0640);
		RequireNoTemporaryFiles(directoryPath);

		NoteObject *exportNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"shared export writer"] autorelease]
			title:@"Export" format:PlainTextFormat labels:@"tag"];
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
		NSString *boundaryBase = @"abcdefghijklmnopqrstuvwxyz--------------------1234567890";
		NSString *boundaryLocal = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567890";
		NSString *boundaryExternal = @"abcXXXXXXXXXXdefghijklmnopqrstuvwxyz--------------------1234567YYYYYYYYYY890";
		NSMutableString *boundaryTagLocal = [[boundaryLocal mutableCopy] autorelease];
		while ([boundaryTagLocal length] < [boundaryExternal length])
			[boundaryTagLocal appendString:@"_"];
		REQUIRE([boundaryTagLocal length] == [boundaryExternal length]);
		REQUIRE(NVMergedText(boundaryBase, boundaryTagLocal, boundaryExternal) == nil);
		NoteObject *boundaryNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:boundaryBase] autorelease]
			title:@"Installed Boundary" format:PlainTextFormat labels:@"tag"];
		[controller addNewNote:boundaryNote];
		REQUIRE([controller flushAllNoteChanges]);
		NSString *boundaryFilename = [[filenameOfNote(boundaryNote) copy] autorelease];
		NSData *externalReplacement = [boundaryExternal dataUsingEncoding:NSUTF8StringEncoding];
		[controller replaceInstalledNoteNamed:boundaryFilename withData:externalReplacement];
		[boundaryNote setContentString:[[[NSAttributedString alloc]
			initWithString:boundaryLocal] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller pendingFileWriteCount] == 1);
		NSString *externalDisk = [[[NSString alloc]
			initWithData:[[controller noteDirectory] dataFromFileNamed:boundaryFilename error:NULL]
			encoding:NSUTF8StringEncoding] autorelease];
		REQUIRE([externalDisk isEqualToString:boundaryExternal]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([[[boundaryNote contentString] string] isEqualToString:boundaryExternal]);

		[boundaryNote setContentString:[[[NSAttributedString alloc]
			initWithString:boundaryBase] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		NSData *tagRaceReplacement = [boundaryExternal dataUsingEncoding:NSUTF8StringEncoding];
		[controller mutateNoteNamed:boundaryFilename withData:tagRaceReplacement
			duringTagSynchronization:YES];
		[boundaryNote setContentString:[[[NSAttributedString alloc]
			initWithString:boundaryTagLocal] autorelease]];
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([boundaryNote writeUsingCurrentFileFormat]);
		REQUIRE([controller pendingFileWriteCount] == 1);
		REQUIRE([[[controller noteDirectory] dataFromFileNamed:boundaryFilename error:NULL]
			isEqualToData:tagRaceReplacement]);
		REQUIRE([controller synchronizeNotesFromDirectory]);
		[controller synchronizeNoteChanges:nil];
		REQUIRE([controller pendingFileWriteCount] == 0);
		REQUIRE([[[boundaryNote contentString] string] isEqualToString:boundaryExternal]);
		[boundaryNote release];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}
}

static void TestAtomicReplacementCapabilities(void) {
	NSString *filesystem = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_EXPECT_FSTYPE"];
	REQUIRE([filesystem isEqualToString:@"apfs"] || [filesystem isEqualToString:@"hfs"] ||
		[filesystem isEqualToString:@"exfat"]);
	BOOL supportsRecoverableReplacement = ![filesystem isEqualToString:@"exfat"];
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSData *baseline = [@"known destination bytes" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *replacement = [@"prepared replacement bytes" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *racingData = [@"concurrent writer bytes" dataUsingEncoding:NSUTF8StringEncoding];

	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		NSError *error = nil;

		NSString *conditionalName = @"Conditional Replacement.dat";
		NSString *conditionalPath = [directoryPath stringByAppendingPathComponent:conditionalName];
		NVFileWriteResult *result = [[controller noteDirectory]
			overwriteFileNamed:conditionalName withData:baseline];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified);
		NVFileSnapshot *baselineSnapshot = [[controller noteDirectory]
			snapshotForFileNamed:conditionalName error:NULL];
		NVFileSnapshot *wrongSnapshot = [[[NVFileSnapshot alloc] initWithData:replacement
			tags:[baselineSnapshot tags] encoding:[baselineSnapshot encoding]
			observation:[baselineSnapshot observation]] autorelease];
		result = [[controller noteDirectory] replaceFileNamed:conditionalName
			withData:replacement expectedSnapshot:wrongSnapshot];
		error = [result error];
		REQUIRE([result disposition] == NVFileWriteNotInstalled);
		REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == EAGAIN);
		REQUIRE([[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:baseline]);
		result = [[controller noteDirectory] replaceFileNamed:conditionalName
			withData:replacement expectedSnapshot:baselineSnapshot];
		REQUIRE([result disposition] == NVFileWriteInstalledVerified &&
			[[NSData dataWithContentsOfFile:conditionalPath] isEqualToData:replacement]);
		RequireNoTemporaryFiles(directoryPath);

		if (supportsRecoverableReplacement) {
			NSString *preparedName = @"Prepared Note.txt";
			NSString *preparedPath = [directoryPath stringByAppendingPathComponent:preparedName];
			NSData *sentinel = [@"preserved metadata" dataUsingEncoding:NSUTF8StringEncoding];
			result = [[controller noteDirectory] overwriteFileNamed:preparedName withData:baseline];
			REQUIRE([result disposition] == NVFileWriteInstalledVerified);
			REQUIRE(chmod([preparedPath fileSystemRepresentation], 0640) == 0);
			REQUIRE(setxattr([preparedPath fileSystemRepresentation],
				"com.notationalvelocity.integration-test", [sentinel bytes], [sentinel length], 0, 0) == 0);
			baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:preparedName error:NULL];
			result = [[controller noteDirectory] replaceNoteFileNamed:preparedName withData:replacement
				encoding:NSUTF8StringEncoding tags:@[ @"prepared" ] creationTime:1000000.0
				modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
			REQUIRE([result disposition] == NVFileWriteInstalledVerified);
			error = nil;
			NVFileObservation *namedInfo = [[controller noteDirectory] observationForFileNamed:preparedName
				error:&error];
			REQUIRE(error == nil && [[[result installedSnapshot] observation] fileID] ==
				[namedInfo fileID]);
			REQUIRE([[NSData dataWithContentsOfFile:preparedPath] isEqualToData:replacement]);
			REQUIRE([IntegrationTestAttribute(preparedPath) isEqualToData:sentinel]);
			RequireMode(preparedPath, 0640);
			REQUIRE([[NSFileManager defaultManager] textEncodingAttributeOfFSPath:
				[preparedPath fileSystemRepresentation]] == NSUTF8StringEncoding);
			NSDictionary *attributes = [[NSFileManager defaultManager]
				attributesOfItemAtPath:preparedPath error:&error];
			REQUIRE(attributes != nil && error == nil);
			REQUIRE(fabs([[attributes objectForKey:NSFileCreationDate]
				timeIntervalSinceReferenceDate] - 1000000.0) < 1.0);
			REQUIRE(fabs([[attributes objectForKey:NSFileModificationDate]
				timeIntervalSinceReferenceDate] - 1000100.0) < 1.0);

			NSString *conflictName = @"Atomic Conflict.txt";
			NSString *conflictPath = [directoryPath stringByAppendingPathComponent:conflictName];
			result = [[controller noteDirectory] overwriteFileNamed:conflictName withData:baseline];
			REQUIRE([result disposition] == NVFileWriteInstalledVerified);
			baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:conflictName error:NULL];
			[controller replaceNoteNamed:conflictName beforeInstallWithData:racingData];
			result = [[controller noteDirectory] replaceNoteFileNamed:conflictName withData:replacement
				encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
				modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
			error = [result error];
			REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
			REQUIRE(error != nil && [[result recoveryFilename] length] > 0);
			REQUIRE([[NSData dataWithContentsOfFile:conflictPath] isEqualToData:replacement]);
			NSMutableArray *recoveryNames = [NSMutableArray array];
			for (NSString *name in [[NSFileManager defaultManager]
				contentsOfDirectoryAtPath:directoryPath error:NULL])
				if ([name hasPrefix:@"Atomic Conflict (conflict recovery "])
					[recoveryNames addObject:name];
			REQUIRE([recoveryNames count] == 1);
			REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
				[recoveryNames objectAtIndex:0]]] isEqualToData:racingData]);

			if ([filesystem isEqualToString:@"hfs"]) {
				NSString *removedName = @"Removed Before Exchange.txt";
				result = [[controller noteDirectory] overwriteFileNamed:removedName withData:baseline];
				REQUIRE([result disposition] == NVFileWriteInstalledVerified);
				baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:removedName error:NULL];
				[controller removeNoteNamedBeforeInstall:removedName];
				result = [[controller noteDirectory] replaceNoteFileNamed:removedName withData:replacement
					encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
					modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
				error = [result error];
				REQUIRE([result disposition] == NVFileWriteNotInstalled);
				REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] &&
					[error code] == ENOENT);
				REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:
					[directoryPath stringByAppendingPathComponent:removedName]]);

				NSString *handoffName = @"Exchange Handoff Race.txt";
				NSString *handoffPath = [directoryPath stringByAppendingPathComponent:handoffName];
				result = [[controller noteDirectory] overwriteFileNamed:handoffName withData:baseline];
				REQUIRE([result disposition] == NVFileWriteInstalledVerified);
				baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:handoffName error:NULL];
				[controller replaceNoteNamed:handoffName afterExchangeWithData:racingData];
				result = [[controller noteDirectory] replaceNoteFileNamed:handoffName withData:replacement
					encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
					modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
				error = [result error];
				REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
				REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] &&
					[error code] == EAGAIN);
				REQUIRE([[NSData dataWithContentsOfFile:handoffPath] isEqualToData:racingData]);
				recoveryNames = [NSMutableArray array];
				for (NSString *name in [[NSFileManager defaultManager]
					contentsOfDirectoryAtPath:directoryPath error:NULL])
					if ([name hasPrefix:@"Exchange Handoff Race (conflict recovery "])
						[recoveryNames addObject:name];
				REQUIRE([recoveryNames count] == 1);
				REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
					[recoveryNames objectAtIndex:0]]] isEqualToData:baseline]);

				NSString *removedAfterExchangeName = @"Removed After Exchange.txt";
				NSString *removedAfterExchangePath = [directoryPath
					stringByAppendingPathComponent:removedAfterExchangeName];
				result = [[controller noteDirectory] overwriteFileNamed:removedAfterExchangeName
					withData:baseline];
				REQUIRE([result disposition] == NVFileWriteInstalledVerified);
				baselineSnapshot = [[controller noteDirectory]
					snapshotForFileNamed:removedAfterExchangeName error:NULL];
				[controller removeNoteNamedAfterExchange:removedAfterExchangeName];
				result = [[controller noteDirectory] replaceNoteFileNamed:removedAfterExchangeName
					withData:replacement encoding:NSUTF8StringEncoding tags:@[]
					creationTime:1000000.0 modificationTime:1000100.0
					expectedSnapshot:baselineSnapshot];
				error = [result error];
				REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
				REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] &&
					[error code] == EAGAIN);
				REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:removedAfterExchangePath]);
				recoveryNames = [NSMutableArray array];
				for (NSString *name in [[NSFileManager defaultManager]
					contentsOfDirectoryAtPath:directoryPath error:NULL])
					if ([name hasPrefix:@"Removed After Exchange (conflict recovery "])
						[recoveryNames addObject:name];
				REQUIRE([recoveryNames count] == 1);
				REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
					[recoveryNames objectAtIndex:0]]] isEqualToData:baseline]);

				NSString *failureName = @"Metadata Finalization Failure.txt";
				NSString *failurePath = [directoryPath stringByAppendingPathComponent:failureName];
				result = [[controller noteDirectory] overwriteFileNamed:failureName withData:baseline];
				REQUIRE([result disposition] == NVFileWriteInstalledVerified);
				baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:failureName error:NULL];
				[controller failExchangedMetadataFinalizationForNoteNamed:failureName];
				result = [[controller noteDirectory] replaceNoteFileNamed:failureName withData:replacement
					encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
					modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
				error = [result error];
				REQUIRE([result disposition] == NVFileWriteInstalledNeedsReconciliation);
				REQUIRE(error != nil && [[result recoveryFilename] length] > 0);
				REQUIRE([[NSData dataWithContentsOfFile:failurePath] isEqualToData:replacement]);
				recoveryNames = [NSMutableArray array];
				for (NSString *name in [[NSFileManager defaultManager]
					contentsOfDirectoryAtPath:directoryPath error:NULL])
					if ([name hasPrefix:@"Metadata Finalization Failure (conflict recovery "])
						[recoveryNames addObject:name];
				REQUIRE([recoveryNames count] == 1);
				REQUIRE([[NSData dataWithContentsOfFile:[directoryPath stringByAppendingPathComponent:
					[recoveryNames objectAtIndex:0]]] isEqualToData:baseline]);
			}
		} else {
			NSString *conflictName = @"Best Effort Conflict.txt";
			NSString *conflictPath = [directoryPath stringByAppendingPathComponent:conflictName];
			result = [[controller noteDirectory] overwriteFileNamed:conflictName withData:baseline];
			REQUIRE([result disposition] == NVFileWriteInstalledVerified &&
				[result capability] == NVFileWriteBestEffortCapability);
			baselineSnapshot = [[controller noteDirectory] snapshotForFileNamed:conflictName error:NULL];
			[controller replaceNoteNamed:conflictName beforeInstallWithData:racingData];
			result = [[controller noteDirectory] replaceNoteFileNamed:conflictName withData:replacement
				encoding:NSUTF8StringEncoding tags:@[] creationTime:1000000.0
				modificationTime:1000100.0 expectedSnapshot:baselineSnapshot];
			error = [result error];
			REQUIRE([result disposition] == NVFileWriteNotInstalled);
			REQUIRE([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == EAGAIN);
			REQUIRE([[NSData dataWithContentsOfFile:conflictPath] isEqualToData:racingData]);

			NSString *createName = @"Create Only.dat";
			NSString *createPath = [directoryPath stringByAppendingPathComponent:createName];
			result = [[controller noteDirectory] createFileNamed:createName withData:baseline];
			REQUIRE([result disposition] == NVFileWriteInstalledVerified);
			result = [[controller noteDirectory] createFileNamed:createName withData:replacement];
			error = [result error];
			REQUIRE([result disposition] == NVFileWriteNotInstalled);
			REQUIRE([[error domain] isEqualToString:NSCocoaErrorDomain] &&
				[error code] == NSFileWriteFileExistsError);
			REQUIRE([[NSData dataWithContentsOfFile:createPath] isEqualToData:baseline]);

		}
		RequireNoTemporaryFiles(directoryPath);
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
		NSString *identityParentPath = [directoryPath stringByAppendingPathComponent:@"Identity Parent"];
		NSString *identityOtherPath = [directoryPath stringByAppendingPathComponent:@"Identity Other"];
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:identityParentPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:identityOtherPath
			withIntermediateDirectories:NO attributes:nil error:NULL]);
		NSURL *identityParentURL = [NSURL fileURLWithPath:identityParentPath isDirectory:YES];
		NSURL *identityParentReferenceURL = FileReferenceURLForPath(identityParentPath);
		NSURL *identityOtherURL = [NSURL fileURLWithPath:identityOtherPath isDirectory:YES];
		NSURL *missingURL = [NSURL fileURLWithPath:
			[directoryPath stringByAppendingPathComponent:@"Missing Identity"] isDirectory:YES];
		REQUIRE(NVURLsReferToSameItem(identityParentURL, identityParentReferenceURL));
		REQUIRE(!NVURLsReferToSameItem(identityParentURL, identityOtherURL));
		REQUIRE(!NVURLsReferToSameItem(nil, identityParentURL));
		REQUIRE(!NVURLsReferToSameItem(identityParentURL, nil));
		REQUIRE(!NVURLsReferToSameItem(missingURL, identityParentURL));

		controller = CreateController(directoryPath, delegate);
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		[controller stopFileNotifications];

		NoteObject *caseNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"original path identity contents"] autorelease]
			title:@"Case Edge" format:PlainTextFormat labels:@""];
		NoteObject *unicodeNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"decomposed Unicode filename"] autorelease]
			title:@"Cafe\u0301 東京" format:PlainTextFormat labels:@""];
		NSMutableString *longTitle = [NSMutableString string];
		while ([longTitle length] < 280)
			[longTitle appendString:@"LongTitle"];
		NoteObject *longNote = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:@"long component filename"] autorelease]
			title:longTitle format:PlainTextFormat labels:@""];
		[controller addNewNote:caseNote];
		[controller addNewNote:unicodeNote];
		[controller addNewNote:longNote];
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([controller directoryStreamNoteCount] == 3);
		REQUIRE([[filenameOfNote(unicodeNote) precomposedStringWithCanonicalMapping]
			isEqualToString:[@"Caf\u00e9 東京.txt" precomposedStringWithCanonicalMapping]]);
		REQUIRE([filenameOfNote(longNote) length] <= 255);

		NoteObject *originalIdentity = [caseNote retain];
		NSString *originalPath = [[[caseNote absoluteUNIXPath] path] copy];
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
		REQUIRE([[[originalIdentity absoluteUNIXPath] lastPathComponent] isEqualToString:caseFilename]);
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

static NSData *EncryptionTestPassphrase(void) {
	return [@"integration-test-passphrase" dataUsingEncoding:NSUTF8StringEncoding];
}

static void TestEncryptedWALChild(void) {
	NSString *directoryPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_ENCRYPTED_WAL_DIRECTORY"];
	REQUIRE([directoryPath length]);
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = CreateController(directoryPath, delegate);
	[controller stopFileNotifications];
	NoteObject *note = AddTestNote(controller, @"Encrypted WAL",
		@"encrypted database baseline");
	[[controller notationPrefs] setPassphraseData:EncryptionTestPassphrase() inKeychain:NO];
	[[controller notationPrefs] setDoesEncryption:YES];
	REQUIRE([controller flushAllNoteChanges]);
	[note setContentString:[[[NSAttributedString alloc]
		initWithString:@"encrypted WAL-only edit"] autorelease]];
	[controller synchronizeNoteChanges:nil];
	REQUIRE([controller synchronizeJournalOnly]);
	_exit(76);
}

static void TestEncryption(void) {
	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	NSData *passphrase = EncryptionTestPassphrase();
	NSString *secret = @"SECRET-PLAINTEXT-5B575E23-東京";

	@try {
		controller = CreateController(directoryPath, delegate);
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:secret] autorelease]
			title:@"Encrypted Note" format:SingleDatabaseFormat labels:@""];
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

		CloseController(&controller);
		RemoveTemporaryDirectory(directoryPath);
		directoryPath = CreateTemporaryDirectory();
		SpawnScenarioWithEnvironment(@"encrypted-wal-child",
			"NV_ENCRYPTED_WAL_DIRECTORY", directoryPath, 76);
		InstallPassphraseRetrieverInjection();
		injectedDatabasePassphrase = passphrase;
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		REQUIRE([[controller notationPrefs] epochIteration] == EPOC_ITERATION);
		REQUIRE([[controller notationPrefs] doesEncryption]);
		NoteObject *recovered = NoteContaining(controller, @"encrypted WAL-only edit");
		REQUIRE(recovered != nil);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]);
		[recovered setContentString:[[[NSAttributedString alloc]
			initWithString:@"encrypted post-recovery edit"] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:
			[directoryPath stringByAppendingPathComponent:NVJournalFilename]]);
		controller = CreateController(directoryPath, delegate);
		REQUIRE(NoteContaining(controller, @"encrypted post-recovery edit") != nil);
	} @finally {
		injectedDatabasePassphrase = nil;
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
			title:uniqueTitle format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		trashArtifact = [[note absoluteUNIXPath] retain];
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

static void TestFIFOJournalChild(void) {
	NSString *rootPath = [[[NSProcessInfo processInfo] environment]
		objectForKey:@"NV_FIFO_JOURNAL_DIRECTORY"];
	REQUIRE([rootPath length]);
	OSStatus status = noErr;
	NVTestNotationController *controller = [[NVTestNotationController alloc]
		initWithDirectoryURL:FileReferenceURLForPath(rootPath) error:&status];
	REQUIRE(controller == nil && status == NVTestJournalingError);
	struct stat journalInfo = { 0 };
	REQUIRE(lstat([[rootPath stringByAppendingPathComponent:NVJournalFilename]
		fileSystemRepresentation], &journalInfo) == 0 && S_ISFIFO(journalInfo.st_mode));
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
		NVRootedDirectory *deletedRoot = [[NVRootedDirectory alloc]
			initWithFileReferenceURL:deletedReference error:&openError];
		REQUIRE(deletedRoot == nil);
		REQUIRE(openError != nil);
		[deletedRoot release];
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
			title:@"Read Only Failure" format:PlainTextFormat labels:@""];
		[controller addNewNote:note];
		[note release];
		REQUIRE([controller recordedWriteError] != noErr);
	} @finally {
		chmod([rootPath fileSystemRepresentation], 0700);
		CloseController(&controller);
		RemoveTemporaryDirectory(rootPath);
		[delegate release];
	}

	rootPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	@try {
		controller = CreateController(rootPath, delegate);
		REQUIRE([controller flushAllNoteChanges]);
		CloseController(&controller);
		NSString *journalPath = [rootPath stringByAppendingPathComponent:
			NVJournalFilename];
		REQUIRE(mkfifo([journalPath fileSystemRepresentation], 0600) == 0);
		const char *oldValue = getenv("NV_FIFO_JOURNAL_DIRECTORY");
		NSString *savedValue = oldValue ? [NSString stringWithUTF8String:oldValue] : nil;
		REQUIRE(setenv("NV_FIFO_JOURNAL_DIRECTORY",
			[rootPath fileSystemRepresentation], 1) == 0);
		NSString *executable = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
		char *arguments[] = {
			(char*)[executable fileSystemRepresentation], "fifo-journal-child", NULL
		};
		pid_t child = -1;
		int spawnResult = posix_spawn(&child, arguments[0], NULL, NULL, arguments, environ);
		if (savedValue) REQUIRE(setenv("NV_FIFO_JOURNAL_DIRECTORY",
			[savedValue UTF8String], 1) == 0);
		else REQUIRE(unsetenv("NV_FIFO_JOURNAL_DIRECTORY") == 0);
		REQUIRE(spawnResult == 0 && child > 0);
		int childStatus = 0;
		NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
		pid_t waitResult = 0;
		while ((waitResult = waitpid(child, &childStatus, WNOHANG)) == 0 &&
			[deadline timeIntervalSinceNow] > 0.0)
			usleep(10000);
		if (waitResult == 0) {
			kill(child, SIGKILL);
			waitpid(child, &childStatus, 0);
			REQUIRE(!"FIFO journal recovery blocked");
		}
		REQUIRE(waitResult == child);
		REQUIRE(WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(rootPath);
	}
}

static void TestExternalEditingTextMerge(void) {
	NSString *cacheRoot = CreateTemporaryDirectory();
	NSString *legacyScratchPath = [cacheRoot stringByAppendingPathComponent:@"legacy active.txt"];
	REQUIRE([@"legacy scratch" writeToFile:legacyScratchPath atomically:NO
		encoding:NSUTF8StringEncoding error:NULL]);
	NSString *staleWorkspace = [cacheRoot stringByAppendingPathComponent:@"NVEditing-Stale"];
	REQUIRE([[NSFileManager defaultManager] createDirectoryAtPath:staleWorkspace
		withIntermediateDirectories:NO attributes:nil error:NULL]);
	NSString *staleScratchPath = [staleWorkspace stringByAppendingPathComponent:@"stale plaintext.txt"];
	REQUIRE([@"stale plaintext" writeToFile:staleScratchPath atomically:NO
		encoding:NSUTF8StringEncoding error:NULL]);
	REQUIRE([@"" writeToFile:[staleWorkspace stringByAppendingPathComponent:
		@".NVExternalEditing.lock"] atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
	TemporaryFileCachePreparer *firstPreparer = [[TemporaryFileCachePreparer alloc] init];
	[firstPreparer _finishPreparationWithPath:cacheRoot];
	NSString *firstWorkspace = [[firstPreparer preparedCachePath] copy];
	REQUIRE([firstWorkspace hasPrefix:[cacheRoot stringByAppendingString:@"/"]]);
	REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:staleWorkspace]);
	REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:legacyScratchPath]);
	TemporaryFileCachePreparer *contendingPreparer = [[TemporaryFileCachePreparer alloc] init];
	[contendingPreparer _finishPreparationWithPath:cacheRoot];
	REQUIRE([[contendingPreparer preparedCachePath] length] &&
		![[contendingPreparer preparedCachePath] isEqualToString:firstWorkspace]);
	NSString *activeScratchPath = [[contendingPreparer preparedCachePath]
		stringByAppendingPathComponent:@"active scratch.txt"];
	REQUIRE([@"active scratch" writeToFile:activeScratchPath atomically:NO
		encoding:NSUTF8StringEncoding error:NULL]);
	[firstPreparer release];
	TemporaryFileCachePreparer *thirdPreparer = [[TemporaryFileCachePreparer alloc] init];
	[thirdPreparer _finishPreparationWithPath:cacheRoot];
	REQUIRE([[thirdPreparer preparedCachePath] length]);
	REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:firstWorkspace]);
	REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:activeScratchPath]);
	[firstWorkspace release];
	[contendingPreparer release];
	[thirdPreparer release];
	RemoveTemporaryDirectory(cacheRoot);

	NSString *base = @"first line\nsecond line\nthird line\n";
	NSString *local = @"FIRST LINE\nsecond line\nthird line\n";
	NSString *external = @"first line\nsecond line\nTHIRD LINE\n";
	REQUIRE([NVMergedText(base, local, external)
		isEqualToString:@"FIRST LINE\nsecond line\nTHIRD LINE\n"]);
	REQUIRE([NVMergedText(base, base, external) isEqualToString:external]);
	REQUIRE([NVMergedText(base, local, base) isEqualToString:local]);

	NSString *partialBase = @"abcdefghijklmnopqrstuvwxyz--------------------1234567890";
	NSString *partialLocal = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ--------------------1234567890";
	NSString *partialExternal = @"abcXXXXXXXXXXdefghijklmnopqrstuvwxyz--------------------1234567YYYYYYYYYY890";
	REQUIRE(NVMergedText(partialBase, partialLocal, partialExternal) == nil);

	NSString *directoryPath = CreateTemporaryDirectory();
	NVTestControllerDelegate *delegate = [[NVTestControllerDelegate alloc] init];
	NVTestNotationController *controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
		NoteObject *note = AddTestNote(controller, @"External Merge", base);
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];

		[note setContentString:[[[NSAttributedString alloc] initWithString:local] autorelease]];
		REQUIRE([note.fileMergeBaseText isEqualToString:base]);
		id archive = ArchivePropertyList(note);
		REQUIRE(!PropertyListContainsKey(archive, @"fileMergeBaseText"));
		REQUIRE(!PropertyListContainsKey(archive, @"fileMergeBaseLabels"));
		REQUIRE(!PropertyListContainsKey(archive, @"fileMergeBaseData"));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		NoteObject *roundTripped = [NSKeyedUnarchiver unarchiveObjectWithData:
			[NSKeyedArchiver archivedDataWithRootObject:note]];
#pragma clang diagnostic pop
		REQUIRE(roundTripped.fileMergeBaseText == nil &&
			roundTripped.fileMergeBaseLabels == nil && roundTripped.fileMergeBaseData == nil);

		WriteExternalFile(PlainTextFormat, external, path);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[[note contentString] string]
			isEqualToString:@"FIRST LINE\nsecond line\nTHIRD LINE\n"]);
		REQUIRE([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:[[note contentString] string]]);

		[note setContentString:[[[NSAttributedString alloc]
			initWithString:partialBase] autorelease]];
		REQUIRE([controller flushAllNoteChanges]);
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:partialLocal] autorelease]];
		WriteExternalFile(PlainTextFormat, partialExternal, path);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:partialLocal]);
		NSString *conflictPath = FileContainingText(directoryPath, partialExternal, filename);
		REQUIRE([[conflictPath lastPathComponent] rangeOfString:@"(conflict)"].location != NSNotFound);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		[controller stopFileNotifications];
		[[controller notationPrefs] setNotesStorageFormat:RTFTextFormat];
		NoteObject *note = AddTestNote(controller, @"Rich External Conflict", @"rich base");
		REQUIRE([controller flushAllNoteChanges]);
		NSString *filename = [[filenameOfNote(note) copy] autorelease];
		NSString *path = [directoryPath stringByAppendingPathComponent:filename];
		NSData *externalData = DataForExternalFile(RTFTextFormat, @"rich external");
		REQUIRE([externalData writeToFile:path options:NSDataWritingAtomic error:NULL]);
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:@"rich local"] autorelease]];
		REQUIRE(note.fileMergeBaseData == nil);
		REQUIRE([controller flushAllNoteChanges]);
		REQUIRE([[[note contentString] string] isEqualToString:@"rich local"]);
		NSString *conflictPath = nil;
		for (NSString *name in [[NSFileManager defaultManager]
			contentsOfDirectoryAtPath:directoryPath error:NULL]) {
			if ([name isEqualToString:filename]) continue;
			NSString *candidate = [directoryPath stringByAppendingPathComponent:name];
			if ([[NSData dataWithContentsOfFile:candidate] isEqualToData:externalData]) {
				conflictPath = candidate;
				break;
			}
		}
		REQUIRE([[conflictPath lastPathComponent] rangeOfString:@"(conflict)"].location != NSNotFound);
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
	}

	directoryPath = CreateTemporaryDirectory();
	delegate = [[NVTestControllerDelegate alloc] init];
	controller = nil;
	@try {
		controller = CreateController(directoryPath, delegate);
		REQUIRE([controller currentNoteStorageFormat] == SingleDatabaseFormat);
		NoteObject *note = AddTestNote(controller, @"Scratch Merge", base);
		[note setContentString:[[[NSAttributedString alloc] initWithString:local] autorelease]];
		[note externalEditingSession:nil didModifyFileData:[external dataUsingEncoding:NSUTF8StringEncoding]
			baseData:[base dataUsingEncoding:NSUTF8StringEncoding] path:@"scratch" context:nil];
		REQUIRE([[[note contentString] string]
			isEqualToString:@"FIRST LINE\nsecond line\nTHIRD LINE\n"]);
		[note setContentString:[[[NSAttributedString alloc]
			initWithString:partialLocal] autorelease]];
		[note externalEditingSession:nil
			didModifyFileData:[partialExternal dataUsingEncoding:NSUTF8StringEncoding]
			baseData:[partialBase dataUsingEncoding:NSUTF8StringEncoding]
			path:@"scratch" context:nil];
		REQUIRE([[[note contentString] string] isEqualToString:partialLocal]);
		NoteObject *conflict = NoteContaining(controller, partialExternal);
		REQUIRE(conflict != nil &&
			[titleOfNote(conflict) isEqualToString:@"Scratch Merge (conflict)"]);

		NoteObject *drainedNote = AddTestNote(controller, @"Scratch Final Drain", base);
		NSData *scratchBase = [base dataUsingEncoding:NSUTF8StringEncoding];
		NSData *scratchExternal = [external dataUsingEncoding:NSUTF8StringEncoding];
		ExternalEditingSession *scratchEditor = [ExternalEditingSession sharedExternalEditingSession];
		[NSObject cancelPreviousPerformRequestsWithTarget:scratchEditor];
		[scratchEditor initializeDatabase:[controller notationPrefs]];
		NSString *scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-drain.txt", scratchExternal);
		NSMutableDictionary *sessions = [scratchEditor valueForKey:@"_filePathsBeingEdited"];
		NoteObject *backgroundNote = AddTestNote(controller, @"Scratch Background", base);
		NoteObject *selectedNote = AddTestNote(controller, @"Scratch Selected", @"selected");
		NSString *backgroundPath = CreateTestScratchFile(scratchEditor,
			@"scratch-background.txt", scratchBase);
		NSString *unrelatedPath = CreateTestScratchFile(scratchEditor,
			@"scratch-unrelated.txt", scratchBase);
		[sessions setObject:TestScratchSession(backgroundNote, backgroundPath, scratchBase)
			forKey:backgroundPath];
		[sessions setObject:TestScratchSession(selectedNote, unrelatedPath, scratchBase)
			forKey:unrelatedPath];
		NVSelectionAppController *selectionController = class_createInstance(
			[NVSelectionAppController class], 0);
		[selectionController initForTestingWithCurrentNote:backgroundNote];
		[selectionController _setCurrentNote:selectedNote];
		REQUIRE([scratchEditor activeScratchEditingSessionCount] == 2);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:backgroundNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:backgroundPath]);
		[backgroundNote setContentString:[[[NSAttributedString alloc]
			initWithString:local] autorelease]];
		NSDate *localBackgroundDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![[NSString stringWithContentsOfFile:backgroundPath
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:local] &&
			[localBackgroundDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([[NSString stringWithContentsOfFile:backgroundPath
			encoding:NSUTF8StringEncoding error:NULL] isEqualToString:local]);
		REQUIRE([scratchExternal writeToFile:backgroundPath options:NSDataWritingAtomic error:NULL]);
		[controller setExternalEditingDurabilityFailures:1];
		__block NSUInteger backgroundFinishCalls = 0;
		__block BOOL backgroundFinishSucceeded = NO;
		[scratchEditor finishScratchEditingSessionsForClients:@[ backgroundNote ]
			completionHandler:^(BOOL success) {
				backgroundFinishCalls++;
				backgroundFinishSucceeded = success;
			}];
		REQUIRE(backgroundFinishCalls == 0);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:backgroundNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:backgroundPath]);
		NSDate *backgroundDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (!backgroundFinishCalls && [backgroundDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE(backgroundFinishCalls == 1 && backgroundFinishSucceeded);
		REQUIRE([[[backgroundNote contentString] string] isEqualToString:external]);
		REQUIRE([scratchEditor activeScratchEditingSessionCount] == 1);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:backgroundPath]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:unrelatedPath]);
		[scratchEditor finishScratchEditingSessionsForClients:@[ selectedNote ]
			completionHandler:nil];
		NSDate *unrelatedDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([scratchEditor activeScratchEditingSessionCount] &&
			[unrelatedDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([scratchEditor activeScratchEditingSessionCount] == 0);
		[selectionController release];

		NoteObject *deletionNote = AddTestNote(controller, @"Scratch Delete", base);
		NSString *deletionPath = CreateTestScratchFile(scratchEditor,
			@"scratch-delete.txt", scratchExternal);
		[sessions setObject:TestScratchSession(deletionNote, deletionPath, scratchBase)
			forKey:deletionPath];
		[controller setExternalEditingDurabilityFailures:1];
		[controller removeNote:deletionNote];
		REQUIRE([AllNotes(controller) indexOfObjectIdenticalTo:deletionNote] != NSNotFound);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:deletionNote]);
		NSDate *deletionDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([AllNotes(controller) indexOfObjectIdenticalTo:deletionNote] != NSNotFound &&
			[deletionDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([AllNotes(controller) indexOfObjectIdenticalTo:deletionNote] == NSNotFound);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:deletionNote]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:deletionPath]);

		NoteObject *terminationNote = AddTestNote(controller, @"Scratch Termination", base);
		NoteObject *sharedTerminationNote = AddTestNote(controller,
			@"Scratch Shared Termination", base);
		NSString *terminationPath = CreateTestScratchFile(scratchEditor,
			@"scratch-termination.txt", scratchExternal);
		NSString *sharedTerminationPath = CreateTestScratchFile(scratchEditor,
			@"scratch-shared-termination.txt", scratchExternal);
		[sessions setObject:TestScratchSession(terminationNote, terminationPath, scratchBase)
			forKey:terminationPath];
		[sessions setObject:TestScratchSession(sharedTerminationNote,
			sharedTerminationPath, scratchBase) forKey:sharedTerminationPath];
		NVTestRunningApplication *firstTestApplication = [[[NVTestRunningApplication alloc]
			initWithProcessIdentifier:4242] autorelease];
		NVTestRunningApplication *lastTestApplication = [[[NVTestRunningApplication alloc]
			initWithProcessIdentifier:4243] autorelease];
		NVTestRunningApplication *equivalentLastTestApplication =
			[[[NVTestRunningApplication alloc] initWithProcessIdentifier:4243] autorelease];
		[scratchEditor openDidCompleteForSessionPath:terminationPath
			application:(NSRunningApplication*)firstTestApplication];
		[scratchEditor openDidCompleteForSessionPath:terminationPath
			application:(NSRunningApplication*)lastTestApplication];
		[scratchEditor openDidCompleteForSessionPath:sharedTerminationPath
			application:(NSRunningApplication*)equivalentLastTestApplication];
		firstTestApplication.terminated = YES;
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:terminationNote]);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:sharedTerminationNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:terminationPath]);
		lastTestApplication.terminated = YES;
		NSDate *terminationDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while ([scratchEditor hasActiveScratchEditingSessionForClient:terminationNote] &&
			[terminationDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:terminationNote]);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:sharedTerminationNote]);
		REQUIRE([[[terminationNote contentString] string] isEqualToString:external]);
		REQUIRE([[[sharedTerminationNote contentString] string] isEqualToString:external]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:terminationPath]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:sharedTerminationPath]);

		NoteObject *failedLaunchNote = AddTestNote(controller, @"Scratch Launch Failure", base);
		NSString *failedLaunchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-launch-failure.txt", scratchBase);
		NSMutableDictionary *failedLaunchSession = TestScratchSession(failedLaunchNote,
			failedLaunchPath, scratchBase);
		[failedLaunchSession setObject:@2 forKey:@"pendingOpenCount"];
		[sessions setObject:failedLaunchSession forKey:failedLaunchPath];
		[scratchEditor openDidCompleteForSessionPath:failedLaunchPath application:nil];
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:failedLaunchNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:failedLaunchPath]);
		[scratchEditor openDidCompleteForSessionPath:failedLaunchPath application:nil];
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:failedLaunchNote]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:failedLaunchPath]);

		NoteObject *modalFinishNote = AddTestNote(controller, @"Scratch Modal Finish", base);
		NSString *modalFinishPath = CreateTestScratchFile(scratchEditor,
			@"scratch-modal-finish.txt", scratchExternal);
		[sessions setObject:TestScratchSession(modalFinishNote, modalFinishPath, scratchBase)
			forKey:modalFinishPath];
		[controller setExternalEditingDurabilityFailures:1];
		__block BOOL modalFinishDelivered = NO;
		[scratchEditor finishScratchEditingSessionsForClients:@[ modalFinishNote ]
			completionHandler:^(BOOL success) { modalFinishDelivered = success; }];
		REQUIRE(!modalFinishDelivered);
		CFRunLoopAddCommonMode(CFRunLoopGetCurrent(),
			(CFStringRef)NSModalPanelRunLoopMode);
		NSDate *modalFinishDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (!modalFinishDelivered && [modalFinishDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSModalPanelRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE(modalFinishDelivered);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:modalFinishNote]);
		REQUIRE([scratchEditor activeScratchEditingSessionCount] == 0);
		NVTerminationAppController *terminationController = class_createInstance(
			[NVTerminationAppController class], 0);
		[terminationController initForTestingWithNotationController:controller];
		NVTerminationApplication *directFileTerminationApplication =
			[[[NVTerminationApplication alloc] init] autorelease];
		REQUIRE([terminationController applicationShouldTerminate:
			(NSApplication*)directFileTerminationApplication] == NSTerminateNow);
		REQUIRE(![directFileTerminationApplication receivedReply]);

		NoteObject *quitNote = AddTestNote(controller, @"Scratch Quit", base);
		NSString *quitPath = CreateTestScratchFile(scratchEditor,
			@"scratch-quit.txt", scratchExternal);
		[sessions setObject:TestScratchSession(quitNote, quitPath, scratchBase)
			forKey:quitPath];
		NVTerminationApplication *terminationApplication = [[[NVTerminationApplication alloc]
			init] autorelease];
		REQUIRE([terminationController _externalEditingQuitResponseShouldTerminate:
			NSAlertFirstButtonReturn]);
		REQUIRE(![terminationController _externalEditingQuitResponseShouldTerminate:
			NSAlertSecondButtonReturn]);
		[terminationController setConfirmsExternalEditingTermination:NO];
		REQUIRE([terminationController applicationShouldTerminate:
			(NSApplication*)terminationApplication] == NSTerminateLater);
		REQUIRE(![terminationApplication receivedReply]);
		REQUIRE(![terminationController windowShouldClose:nil]);
		REQUIRE([[scratchEditor valueForKey:@"_scratchEditingSuspensionCount"]
			unsignedIntegerValue] == 1);
		NSDate *cancelDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![terminationApplication receivedReply] &&
			[cancelDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([terminationApplication receivedReply] &&
			![terminationApplication terminationReply]);
		REQUIRE([terminationController windowShouldClose:nil]);
		REQUIRE(![[terminationController valueForKey:@"waitedForUncommittedChanges"]
			boolValue]);
		REQUIRE([[scratchEditor valueForKey:@"_scratchEditingSuspensionCount"]
			unsignedIntegerValue] == 0);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:quitNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:quitPath]);
		[terminationController setConfirmsExternalEditingTermination:YES];
		NVTerminationApplication *quitTerminationApplication =
			[[[NVTerminationApplication alloc] initWithEditor:scratchEditor client:quitNote]
				autorelease];
		REQUIRE([terminationController applicationShouldTerminate:
			(NSApplication*)quitTerminationApplication] == NSTerminateLater);
		REQUIRE(![quitTerminationApplication receivedReply]);
		NSDate *quitDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![quitTerminationApplication receivedReply] &&
			[quitDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([quitTerminationApplication receivedReply] &&
			[quitTerminationApplication terminationReply]);
		REQUIRE(![quitTerminationApplication sessionActiveAtReply]);
		REQUIRE([[scratchEditor valueForKey:@"_scratchEditingSuspensionCount"]
			unsignedIntegerValue] == 0);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:quitNote]);
		REQUIRE([[[quitNote contentString] string] isEqualToString:external]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:quitPath]);
		NoteObject *failedFinishNote = AddTestNote(controller, @"Scratch Finish Failure", base);
		NSString *failedFinishPath = CreateTestScratchFile(scratchEditor,
			@"scratch-finish-failure.txt", scratchExternal);
		[sessions setObject:TestScratchSession(failedFinishNote, failedFinishPath, scratchBase)
			forKey:failedFinishPath];
		NoteObject *failedFinishWithAppNote = AddTestNote(controller,
			@"Scratch Finish Failure With App", base);
		NSString *failedFinishWithAppPath = CreateTestScratchFile(scratchEditor,
			@"scratch-finish-failure-with-app.txt", scratchExternal);
		[sessions setObject:TestScratchSession(failedFinishWithAppNote,
			failedFinishWithAppPath, scratchBase) forKey:failedFinishWithAppPath];
		NVTestRunningApplication *failedFinishApplication =
			[[[NVTestRunningApplication alloc] initWithProcessIdentifier:4244] autorelease];
		[scratchEditor openDidCompleteForSessionPath:failedFinishWithAppPath
			application:(NSRunningApplication*)failedFinishApplication];
		[controller setExternalEditingDurabilityFailures:100];
		NVTerminationApplication *failedTerminationApplication =
			[[[NVTerminationApplication alloc] init] autorelease];
		REQUIRE([terminationController applicationShouldTerminate:
			(NSApplication*)failedTerminationApplication] == NSTerminateLater);
		NSMutableArray *finishRequests = [scratchEditor valueForKey:@"_finishRequests"];
		NSDate *finishRequestDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![finishRequests count] && [finishRequestDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([finishRequests count] == 1);
		[[finishRequests objectAtIndex:0] setValue:[NSDate distantPast] forKey:@"deadline"];
		[scratchEditor checkFinishRequests];
		REQUIRE(![failedTerminationApplication receivedReply]);
		NSDate *failedFinishDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![failedTerminationApplication receivedReply] &&
			[failedFinishDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([failedTerminationApplication receivedReply] &&
			![failedTerminationApplication terminationReply]);
		REQUIRE([terminationController teardownFailures] == 1);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:failedFinishNote]);
		REQUIRE([scratchEditor hasActiveScratchEditingSessionForClient:failedFinishWithAppNote]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:failedFinishPath]);
		REQUIRE([[NSFileManager defaultManager] fileExistsAtPath:failedFinishWithAppPath]);
		REQUIRE(![[sessions objectForKey:failedFinishPath] objectForKey:@"pendingEnd"]);
		REQUIRE(![[sessions objectForKey:failedFinishWithAppPath] objectForKey:@"pendingEnd"]);
		[controller setExternalEditingDurabilityFailures:0];
		NVTerminationApplication *retryTerminationApplication =
			[[[NVTerminationApplication alloc] init] autorelease];
		REQUIRE([terminationController applicationShouldTerminate:
			(NSApplication*)retryTerminationApplication] == NSTerminateLater);
		NSDate *failedFinishCleanupDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
		while (![retryTerminationApplication receivedReply] &&
			[failedFinishCleanupDeadline timeIntervalSinceNow] > 0.0)
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
		REQUIRE([retryTerminationApplication receivedReply] &&
			[retryTerminationApplication terminationReply]);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:failedFinishNote]);
		REQUIRE(![scratchEditor hasActiveScratchEditingSessionForClient:failedFinishWithAppNote]);
		[terminationController release];

		[sessions setObject:TestScratchSession(drainedNote, scratchPath, scratchBase)
			forKey:scratchPath];
		[scratchEditor abortAllEditingSessionsForClient:drainedNote];
		REQUIRE([[[drainedNote contentString] string] isEqualToString:external]);
		REQUIRE(![[NSFileManager defaultManager] fileExistsAtPath:scratchPath]);
		REQUIRE([sessions objectForKey:scratchPath] == nil);
		[NSObject cancelPreviousPerformRequestsWithTarget:scratchEditor];

		NSString *roundTripBase = @"one\ntwo\nthree\n";
		NSString *roundTripFour = [roundTripBase stringByAppendingString:@"four\n"];
		NSString *roundTripFive = [roundTripFour stringByAppendingString:@"five\n"];
		NSString *roundTripSix = [roundTripFive stringByAppendingString:@"six\n"];
		NSData *roundTripBaseData = [roundTripBase dataUsingEncoding:NSUTF8StringEncoding];
		NoteObject *roundTripNote = AddTestNote(controller, @"Scratch Round Trip", roundTripBase);
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-round-trip.txt", roundTripBaseData);
		[sessions setObject:TestScratchSession(roundTripNote, scratchPath, roundTripBaseData)
			forKey:scratchPath];
		REQUIRE([[roundTripFour dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[[roundTripNote contentString] string] isEqualToString:roundTripFour]);
		[roundTripNote setContentString:[[[NSAttributedString alloc]
			initWithString:roundTripFive] autorelease]];
		WaitForFileText(scratchPath, roundTripFive);
		struct stat afterLocalWrite = { 0 }, afterNoOp = { 0 };
		REQUIRE(stat([scratchPath fileSystemRepresentation], &afterLocalWrite) == 0);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE(stat([scratchPath fileSystemRepresentation], &afterNoOp) == 0 &&
			afterLocalWrite.st_ino == afterNoOp.st_ino);
		REQUIRE([[roundTripSix dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[[roundTripNote contentString] string] isEqualToString:roundTripSix]);
		REQUIRE([[NSString stringWithContentsOfFile:scratchPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:roundTripSix]);
		[scratchEditor abortAllEditingSessionsForClient:roundTripNote];

		NoteObject *externalNote = AddTestNote(controller, @"Scratch External Write", base);
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-external.txt", scratchBase);
		[sessions setObject:TestScratchSession(externalNote, scratchPath, scratchBase)
			forKey:scratchPath];
		REQUIRE([scratchExternal writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		struct stat beforeExternalRead = { 0 }, afterExternalRead = { 0 };
		REQUIRE(stat([scratchPath fileSystemRepresentation], &beforeExternalRead) == 0);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[[externalNote contentString] string] isEqualToString:external]);
		REQUIRE(stat([scratchPath fileSystemRepresentation], &afterExternalRead) == 0 &&
			beforeExternalRead.st_ino == afterExternalRead.st_ino);
		[scratchEditor abortAllEditingSessionsForClient:externalNote];

		NoteObject *concurrentNote = AddTestNote(controller, @"Scratch Concurrent Write", base);
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-concurrent.txt", scratchBase);
		[sessions setObject:TestScratchSession(concurrentNote, scratchPath, scratchBase)
			forKey:scratchPath];
		REQUIRE([scratchExternal writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		[concurrentNote setContentString:[[[NSAttributedString alloc] initWithString:local] autorelease]];
		NSString *merged = @"FIRST LINE\nsecond line\nTHIRD LINE\n";
		WaitForFileText(scratchPath, merged);
		REQUIRE([[[concurrentNote contentString] string] isEqualToString:merged]);
		[scratchEditor abortAllEditingSessionsForClient:concurrentNote];

		NVScratchRaceNote *raceNote = [[[NVScratchRaceNote alloc] initWithNoteBody:
			[[[NSAttributedString alloc] initWithString:base] autorelease]
			title:@"Scratch Save Race" format:SingleDatabaseFormat labels:@""]
			autorelease];
		[controller addNewNote:raceNote];
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-race.txt", scratchBase);
		[sessions setObject:TestScratchSession(raceNote, scratchPath, scratchBase)
			forKey:scratchPath];
		REQUIRE([scratchExternal writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		[raceNote setContentString:[[[NSAttributedString alloc] initWithString:local] autorelease]];
		NSString *secondExternal = @"first line\nSECOND LINE\nTHIRD LINE\n";
		[raceNote replaceScratchDuringNextMergeWithData:
			[secondExternal dataUsingEncoding:NSUTF8StringEncoding]];
		REQUIRE(![scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[NSString stringWithContentsOfFile:scratchPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:secondExternal]);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[[raceNote contentString] string] isEqualToString:secondExternal]);
		REQUIRE([[NSString stringWithContentsOfFile:scratchPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:secondExternal]);
		[scratchEditor abortAllEditingSessionsForClient:raceNote];

		NoteObject *conflictingNote = AddTestNote(controller, @"Scratch Write Conflict", partialBase);
		NSData *partialBaseData = [partialBase dataUsingEncoding:NSUTF8StringEncoding];
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-conflict.txt", partialBaseData);
		[sessions setObject:TestScratchSession(conflictingNote, scratchPath, partialBaseData)
			forKey:scratchPath];
		NSUInteger beforeConflictCount = [controller totalNoteCount];
		REQUIRE([[partialExternal dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		[conflictingNote setContentString:[[[NSAttributedString alloc]
			initWithString:partialLocal] autorelease]];
		[NSObject cancelPreviousPerformRequestsWithTarget:scratchEditor];
		[controller setExternalEditingDurabilityFailures:1];
		REQUIRE(![scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[NSString stringWithContentsOfFile:scratchPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:partialExternal]);
		REQUIRE([controller totalNoteCount] == beforeConflictCount + 1);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		WaitForFileText(scratchPath, partialLocal);
		REQUIRE([[[conflictingNote contentString] string] isEqualToString:partialLocal]);
		REQUIRE([controller totalNoteCount] == beforeConflictCount + 1);
		NoteObject *writeConflict = nil;
		for (NoteObject *candidate in AllNotes(controller))
			if ([titleOfNote(candidate) isEqualToString:@"Scratch Write Conflict (conflict)"])
				writeConflict = candidate;
		REQUIRE(writeConflict != nil &&
			[[[writeConflict contentString] string] isEqualToString:partialExternal]);
		[scratchEditor abortAllEditingSessionsForClient:conflictingNote];

		NoteObject *invalidNote = AddTestNote(controller, @"Scratch Invalid UTF-8", base);
		scratchPath = CreateTestScratchFile(scratchEditor,
			@"scratch-invalid.txt", scratchBase);
		[sessions setObject:TestScratchSession(invalidNote, scratchPath, scratchBase)
			forKey:scratchPath];
		const unsigned char invalidByte = 0xff;
		NSData *invalidData = [NSData dataWithBytes:&invalidByte length:1];
		REQUIRE([invalidData writeToFile:scratchPath options:NSDataWritingAtomic error:NULL]);
		REQUIRE([scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([[NSString stringWithContentsOfFile:scratchPath encoding:NSUTF8StringEncoding
			error:NULL] isEqualToString:base]);
		NoteObject *invalidConflict = nil;
		for (NoteObject *candidate in AllNotes(controller))
			if ([titleOfNote(candidate) isEqualToString:
				@"Scratch Invalid UTF-8 (conflict - undecodable data)"])
				invalidConflict = candidate;
		REQUIRE(invalidConflict != nil && [[[[invalidConflict contentString] string]
			componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
			containsObject:@"/w=="]);

		NSString *movedScratchPath = [scratchPath stringByAppendingString:@".saving"];
		REQUIRE(rename([scratchPath fileSystemRepresentation],
			[movedScratchPath fileSystemRepresentation]) == 0);
		REQUIRE(![scratchEditor processScratchFileAtPath:scratchPath endingSession:NO]);
		REQUIRE([sessions objectForKey:scratchPath] != nil);
		REQUIRE(rename([movedScratchPath fileSystemRepresentation],
			[scratchPath fileSystemRepresentation]) == 0);
		[scratchEditor abortAllEditingSessionsForClient:invalidNote];
	} @finally {
		CloseController(&controller);
		[delegate release];
		RemoveTemporaryDirectory(directoryPath);
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
		else if ([scenario isEqualToString:@"legacy-temporary-database-recovery"])
			TestLegacyTemporaryDatabaseRecovery();
		else if ([scenario isEqualToString:@"wal-record-recovery"])
			TestWALRecordRecovery();
		else if ([scenario isEqualToString:@"wal-recovery-workflows"])
			TestWALRecoveryWorkflows();
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
		else if ([scenario isEqualToString:@"encrypted-wal-child"])
			TestEncryptedWALChild();
		else if ([scenario isEqualToString:@"fifo-journal-child"])
			TestFIFOJournalChild();
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
		else if ([scenario isEqualToString:@"write-epoch-five-compatibility-database"])
			TestWriteEpochFiveCompatibilityDatabase();
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
		else if ([scenario isEqualToString:@"open-files-workflow"]) {
			TestOpenFilesWorkflow();
			TestLaunchDirectoryOverride();
		}
		else if ([scenario isEqualToString:@"deletion-contracts"])
			TestDeletionContracts();
		else if ([scenario isEqualToString:@"storage-transitions"])
			TestStorageTransitions();
		else if ([scenario isEqualToString:@"fsevents-live"])
			TestLiveFSEvents();
		else if ([scenario isEqualToString:@"fsevents-writer-child"])
			TestFSEventsWriterChild();
		else if ([scenario isEqualToString:@"external-editor-writer-child"])
			TestExternalEditorWriterChild();
		else if ([scenario isEqualToString:@"filename-collisions"])
			TestFilenameCollisions();
		else if ([scenario isEqualToString:@"case-sensitive-filename-collisions"])
			TestCaseSensitiveFilenameCollisions();
		else if ([scenario isEqualToString:@"concurrent-controllers"])
			TestConcurrentControllers();
		else if ([scenario isEqualToString:@"plain-text-encodings"])
			TestPlainTextEncodings();
		else if ([scenario isEqualToString:@"filesystem-crud"])
			TestFilesystemCRUD();
		else if ([scenario isEqualToString:@"file-barrier-sync"])
			TestFileBarrierSync();
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
		else if ([scenario isEqualToString:@"atomic-replacement-capabilities"])
			TestAtomicReplacementCapabilities();
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
		else if ([scenario isEqualToString:@"external-editing-text-merge"])
			TestExternalEditingTextMerge();
		else
			REQUIRE(!"unknown integration-test scenario");
	} @catch (NSException *exception) {
		NSLog(@"%@", exception);
		result = 1;
	}

	[pool drain];
	return result;
}
