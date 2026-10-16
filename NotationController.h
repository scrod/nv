//
//  NotationController.h
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import <Cocoa/Cocoa.h>
#import "FastListDataSource.h"
#import "LabelsListController.h"
#import "WALController.h"

//enum { kUISearch, kUINewNote, kUIDeleteNote, kUIRenameNote, kUILabelOperation };

typedef struct _NoteCatalogEntry NoteCatalogEntry;

extern NSString * const NotesDatabaseFileName;

@class NoteObject;
@class DeletedNoteObject;
@class SyncSessionController;
@class NotationPrefs;
@class NoteAttributeColumn;
@class NoteBookmark;
@class DeletionManager;
@class GlobalPrefs;
@class NVDirectoryTransaction;
@class NVRootedDirectory;

@interface NotationController : NSObject {
    NSMutableArray *allNotes;
    FastListDataSource *notesListDataSource;
    LabelsListController *labelsListController;
	GlobalPrefs *prefsController;
	SyncSessionController *syncSessionController;
	DeletionManager *deletionManager;
	id delegate;
	
	float titleColumnWidth;
	NoteAttributeColumn* sortColumn;
	
    NoteObject **allNotesBuffer;
	unsigned int allNotesBufferSize;
    
    NSUInteger selectedNoteIndex;
	NSString *_filterString;
    char *currentFilterStr, *manglingString;
    int lastWordInFilterStr;
    
	NVDirectoryTransaction *directoryTransaction;
	BOOL directoryScanScheduled, directoryScanRunning;
	BOOL directoryStreamNeedsReconfiguration;
	NSTimer *directoryRetryTimer;
	NSUInteger directoryRetryAttempt;
	BOOL directoryRetryPending, writeRetryPending;
    
    NotationPrefs *notationPrefs;
	
	NSMutableSet *deletedNotes;
    
	FSEventStreamRef noteDirEventStreamRef;
	BOOL eventStreamStarted;
	    
	id directoryCatalog; // private NVRootedDirectoryCatalog
    
	unsigned int lastCheckedDateInHours;
	int lastLayoutStyleGenerated;
	NSString *currentFileMetadataVolumeUUID;
	NVRootedDirectory *noteDirectory;
	NSError *lastWriteError;
    
    WALStorageController *walWriter;
	NSMutableSet *pendingFileWrites, *pendingJournalWrites;
	BOOL notesChanged;
	NSTimer *changeWritingTimer;
	NSUndoManager *undoManager;
}

@property(retain,nonatomic) NSString *filterString;
@property (nonatomic, retain) NSTimer *directoryRetryTimer;
@property (nonatomic, retain) NSTimer *changeWritingTimer;
@property (nonatomic, retain) NSError *lastWriteError;
@property (nonatomic, retain) WALStorageController *walWriter;

- (id)init;
- (id)initWithAliasData:(NSData*)data error:(OSStatus*)err;
- (id)initWithDefaultDirectoryReturningError:(OSStatus*)err;
- (id)initWithDirectoryURL:(NSURL*)directoryURL error:(OSStatus*)err;
- (id)initWithRootedDirectory:(NVRootedDirectory*)directory error:(OSStatus*)err;
- (NSURL*)noteDirectoryURL;
- (NVRootedDirectory*)noteDirectory;
- (OSStatus)_readAndInitializeSerializedNotesWithUnlockedPrefs:(NotationPrefs*)unlockedPrefs;
- (void)processRecoveredNotes:(NSDictionary*)dict;
- (BOOL)initializeJournaling;
- (void)handleJournalError;
- (void)checkJournalExistence;
- (void)closeJournal;
- (BOOL)flushAllNoteChanges;
- (void)flushEverything;

- (void)upgradeDatabaseIfNecessary;

- (id)delegate;
- (void)setDelegate:(id)theDelegate;

- (void)databaseEncryptionSettingsChanged;
- (void)databaseSettingsChangedFromOldFormat:(int)oldFormat;

- (int)currentNoteStorageFormat;
- (void)synchronizeNoteChanges:(NSTimer*)timer;
- (BOOL)makeNoteDurableForExternalEditing:(NoteObject*)note;

- (void)updateDateStringsIfNecessary;
- (void)makeForegroundTextColorMatchGlobalPrefs;
- (void)setForegroundTextColor:(NSColor*)aColor;
- (void)restyleAllNotes;
- (void)setUndoManager:(NSUndoManager*)anUndoManager;
- (NSUndoManager*)undoManager;
- (void)noteDidNotWrite:(NoteObject*)note error:(NSError*)error;
- (void)scheduleWriteForNote:(NoteObject*)note;
- (void)closeAllResources;
- (void)trashRemainingNoteFilesInDirectory;
- (void)updateLinksToNote:(NoteObject*)aNoteObject fromOldName:(NSString*)oldname;
- (void)updateTitlePrefixConnections;
- (void)addNotes:(NSArray<NoteObject*>*)noteArray;
- (void)addNotesFromSync:(NSArray<NoteObject*>*)noteArray;
- (void)addNewNote:(NoteObject*)aNoteObject;
- (void)_addNote:(NoteObject*)aNoteObject;
- (void)removeNote:(NoteObject*)aNoteObject;
- (void)removeNotes:(NSArray*)noteArray;
- (void)_purgeAlreadyDistributedDeletedNotes;
- (void)removeSyncMDFromDeletedNotesInSet:(NSSet*)notesToOrphan forService:(NSString*)serviceName;
- (DeletedNoteObject*)_addDeletedNote:(id<SynchronizedNote>)aNote;
- (void)_registerDeletionUndoForNote:(NoteObject*)aNote;

- (BOOL)openFiles:(NSArray*)filenames;

- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;

- (void)filterNotesFromLabelAtIndex:(int)labelIndex;
- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet;
- (void)updateLabelConnectionsAfterDecoding;

- (void)refilterNotes;
- (BOOL)filterNotesFromString:(NSString*)string;
- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached;
- (NSUInteger)preferredSelectedNoteIndex;
- (NSArray*)noteTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex;
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

- (float)titleColumnWidth;
- (void)regeneratePreviewsForColumn:(NSTableColumn*)col visibleFilteredRows:(NSRange)rows forceUpdate:(BOOL)force;
- (void)regenerateAllPreviews;

//for setting up the nstableviews
- (id)labelsListDataSource;
- (id)notesListDataSource;

- (NotationPrefs*)notationPrefs;
- (SyncSessionController*)syncSessionController;

- (void)dealloc;

@end


enum { NVDefaultReveal = 0, NVDoNotChangeScrollPosition = 1, NVOrderFrontWindow = 2, NVEditNoteToReveal = 4 };

@interface NSObject (NotationControllerDelegate)
- (BOOL)notationListShouldChange:(NotationController*)someNotation;
- (void)notationListMightChange:(NotationController*)someNotation;
- (void)notationListDidChange:(NotationController*)someNotation;
- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts;
- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes;

- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject;
- (void)titleUpdatedForNote:(NoteObject*)aNoteObject;
- (void)rowShouldUpdate:(NSInteger)affectedRow;
- (void)externalEditingSessionTeardownFailed;

@end
