//
//  NotationController.h
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "FastListDataSource.h"
#import "LabelsListController.h"
#import "WALController.h"

#define kMaxFileIteratorCount 100

//enum { kUISearch, kUINewNote, kUIDeleteNote, kUIRenameNote, kUILabelOperation };

typedef struct _NoteCatalogEntry {
    UTCDateTime lastModified;
    UInt32 logicalSize;
    OSType fileType;
    UInt32 nodeID;
    CFMutableStringRef filename;
    UniChar *filenameChars;
    UniCharCount filenameCharCount;
} NoteCatalogEntry;

@class NoteObject;
@class NotationPrefs;
@class NoteAttributeColumn;
@class NoteBookmark;
@class GlobalPrefs;

@interface NotationController : NSObject {
    NSMutableArray *allNotes;
    FastListDataSource *notesListDataSource;
    LabelsListController *labelsListController;
	GlobalPrefs *prefsController;
	id delegate;
	
	NoteAttributeColumn* sortColumn;
	
    NoteObject **allNotesBuffer;
	unsigned allNotesBufferSize;
    
    NSUInteger selectedNoteIndex;
    char *currentFilterStr, *manglingString;
    int lastWordInFilterStr;
    
	BOOL directoryChangesFound;
    
    NotationPrefs *notationPrefs;
	
	NSMutableArray *deletedNotes;
    
	int volumeSupportsExchangeObjects;
    FNSubscriptionUPP subscriptionCallback;
    FNSubscriptionRef noteDirSubscription;
    FSCatalogInfo *fsCatInfoArray;
    HFSUniStr255 *HFSUniNameArray;
	    
    size_t catEntriesCount, totalCatEntriesCount;
    NoteCatalogEntry *catalogEntries, **sortedCatalogEntries;
    
	unsigned int lastCheckedDateInHours;
    long blockSize;
    FSRef noteDirectoryRef, noteDatabaseRef;
    AliasHandle aliasHandle;
    BOOL aliasNeedsUpdating;
    OSStatus lastWriteError;
    
    WALStorageController *walWriter;
    NSMutableSet *unwrittenNotes;
	BOOL notesChanged;
	NSTimer *changeWritingTimer;
	NSUndoManager *undoManager;
}

NSInteger compareCatalogEntryName(const void *one, const void *two);
NSInteger compareCatalogValueNodeID(id *a, id *b);
void NotesDirFNSubscriptionProc(FNMessage message, OptionBits flags, void * refcon, FNSubscriptionRef subscription);

- (id)init;
- (id)initWithAliasData:(NSData*)data error:(OSStatus*)err;
- (id)initWithDefaultDirectoryReturningError:(OSStatus*)err;
- (id)initWithDirectoryRef:(FSRef*)directoryRef error:(OSStatus*)err;
- (void)setAliasNeedsUpdating:(BOOL)needsUpdate;
- (BOOL)aliasNeedsUpdating;
- (NSData*)aliasDataForNoteDirectory;
- (OSStatus)_readAndInitializeSerializedNotes;
- (void)processRecoveredNotes:(NSDictionary*)dict;
- (BOOL)initializeJournaling;
- (void)handleJournalError;
- (void)checkJournalExistence;
- (void)closeJournal;
- (void)stopFileNotifications;
- (BOOL)flushAllNoteChanges;
- (void)flushEverything;

- (id)delegate;
- (void)setDelegate:(id)theDelegate;

- (void)databaseEncryptionSettingsChanged;
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat;

- (int)currentNoteStorageFormat;
- (BOOL)synchronizeNotesFromDirectory;
- (void)synchronizeNoteChanges:(NSTimer*)timer;
- (BOOL)_readFilesInDirectory;
- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry;
- (void)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount;
- (void)processNotesAdded:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;

- (void)updateDateStringsIfNecessary;
- (void)restyleAllNotes;
- (void)setUndoManager:(NSUndoManager*)anUndoManager;
- (NSUndoManager*)undoManager;
- (void)noteDidNotWrite:(NoteObject*)note errorCode:(OSStatus)error;
- (void)scheduleWriteForNote:(NoteObject*)note;
- (void)trashRemainingNoteFilesInDirectory;
- (void)checkIfNotationIsTrashed;
- (void)updateLinksToNote:(NoteObject*)aNoteObject fromOldName:(NSString*)oldname;
- (void)addNotes:(NSArray*)noteArray;
- (void)addNewNote:(NoteObject*)aNoteObject;
- (void)_addNote:(NoteObject*)aNoteObject;
- (void)removeNote:(NoteObject*)aNoteObject;
- (void)removeNotes:(NSArray*)noteArray;
- (void)_registerDeletionUndoForNote:(NoteObject*)aNote;
- (NoteObject*)addNote:(NSAttributedString*)attributedContents withTitle:(NSString*)title;
- (NoteObject*)addNoteFromCatalogEntry:(NoteCatalogEntry*)catEntry;

- (void)restoreNoteBookmark:(NoteBookmark*)bookmark;

- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;

- (void)filterNotesFromLabelAtIndex:(int)labelIndex;
- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet;

- (void)refilterNotes;
- (BOOL)filterNotesFromString:(NSString*)string;
- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached;
- (NSUInteger)preferredSelectedNoteIndex;
- (BOOL)preferredSelectedNoteMatchesSearchString;
- (NoteObject*)noteObjectAtFilteredIndex:(int)noteIndex;
- (NSArray*)notesAtIndexes:(NSIndexSet*)indexSet;
- (NSIndexSet*)indexesOfNotes:(NSArray*)noteSet;
- (NSUInteger)indexInFilteredListForNoteIdenticalTo:(NoteObject*)note;
- (NSUInteger)totalNoteCount;

- (void)scheduleUpdateListForAttribute:(NSString*)attribute;
- (NoteAttributeColumn*)sortColumn;
- (void)setSortColumn:(NoteAttributeColumn*)col;
- (void)resortAllNotes;
- (void)sortAndRedisplayNotes;

//for setting up the nstableviews
- (id)labelsListDataSource;
- (id)notesListDataSource;

- (void)dealloc;

@end


@interface NSObject (NotationControllerDelegate)
- (BOOL)notationListShouldChange:(NotationController*)someNotation;
- (void)notationListMightChange:(NotationController*)someNotation;
- (void)notationListDidChange:(NotationController*)someNotation;
- (void)notation:(NotationController*)notation wantsToSearchForString:(NSString*)string;
- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note;
- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes;
- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject;
- (void)titleUpdatedForNote:(NoteObject*)aNoteObject;

@end
