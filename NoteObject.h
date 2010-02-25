//
//  NoteObject.h
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import <Cocoa/Cocoa.h>
#import "NotationController.h"
#import "SynchronizedNoteProtocol.h"

@class LabelObject;
@class WALStorageController;
@class NotesTableView;

typedef struct _NoteFilterContext {
	char* needle;
	BOOL useCachedPositions;
} NoteFilterContext;

@interface NoteObject : NSObject <NSCoding, SynchronizedNote> {
	NSAttributedString *tableTitleString;
	NSString *titleString, *labelString;
	NSMutableAttributedString *contentString;
    
	//caching/searching purposes only -- created at runtime
	char *cTitle, *cContents, *cLabels, *cTitleFoundPtr, *cContentsFoundPtr, *cLabelsFoundPtr;
	NSMutableSet *labelSet;
	BOOL contentsWere7Bit, contentCacheNeedsUpdate;
	
	NSString *wordCountString;
	NSString *dateModifiedString, *dateCreatedString;
	
	id delegate; //the notes controller
	
	//for syncing to text file
	NSString *filename;
	UInt32 nodeID;
	UInt32 logicalSize;
	UTCDateTime fileModifiedDate;
	int currentFormatID;
	NSStringEncoding fileEncoding;
	BOOL shouldWriteToFile;
	
	//for storing in write-ahead-log
	unsigned int logSequenceNumber;
	
	//not determined until it's time to read to or write from a text file
	FSRef *noteFileRef;

	//the first for syncing w/ NV server, as the ID cannot be encrypted
	CFUUIDBytes uniqueNoteIDBytes;
	
	NSMutableDictionary *syncServicesMD;
	
	//more metadata
	CFAbsoluteTime modifiedDate, createdDate;
	NSRange selectedRange;
	
	//each note has its own undo manager--isn't that nice?
	NSUndoManager *undoManager;
}


NSInteger compareDateModified(id *a, id *b);
NSInteger compareDateCreated(id *a, id *b);
NSInteger compareLabelString(id *a, id *b);
NSInteger compareTitleString(id *a, id *b);
NSInteger compareUniqueNoteIDBytes(id *a, id *b);


NSInteger compareDateModifiedReverse(id *a, id *b);
NSInteger compareDateCreatedReverse(id *a, id *b);
NSInteger compareLabelStringReverse(id *a, id *b);
NSInteger compareTitleStringReverse(id *a, id *b);

NSInteger compareFilename(id *a, id *b);
NSInteger compareNodeID(id *a, id *b);
NSInteger compareFileSize(id *a, id *b);

//syncing w/ server and from journal
- (CFUUIDBytes *)uniqueNoteIDBytes;
- (NSDictionary*)syncServicesMD;
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;

- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

	//syncing w/ files in directory
	int storageFormatOfNote(NoteObject *note);
	NSString* filenameOfNote(NoteObject *note);
	UInt32 fileNodeIDOfNote(NoteObject *note);
	UInt32 fileSizeOfNote(NoteObject *note);
	UTCDateTime fileModifiedDateOfNote(NoteObject *note);
	CFAbsoluteTime modifiedDateOfNote(NoteObject *note);
	CFAbsoluteTime createdDateOfNote(NoteObject *note);

	NSStringEncoding fileEncodingOfNote(NoteObject *note);

	NSString* titleOfNote(NoteObject *note);
	NSString* labelsOfNote(NoteObject *note);

#define DefColAttrAccessor(__FName, __IVar) force_inline id __FName(NotesTableView *tv, NoteObject *note) { return note->__IVar; }
#define DefModelAttrAccessor(__FName, __IVar) force_inline typeof (((NoteObject *)0)->__IVar) __FName(NoteObject *note) { return note->__IVar; }

	//return types are NSString or NSAttributedString, satisifying NSTableDataSource protocol otherwise
	id titleOfNote2(NotesTableView *tv, NoteObject *note);
	id tableTitleOfNote(NotesTableView *tv, NoteObject *note);
	id properlyHighlightingTableTitleOfNote(NotesTableView *tv, NoteObject *note);
	id labelsOfNote2(NotesTableView *tv, NoteObject *note);
	id dateCreatedStringOfNote(NotesTableView *tv, NoteObject *note);
	id dateModifiedStringOfNote(NotesTableView *tv, NoteObject *note);
	id wordCountOfNote(NotesTableView *tv, NoteObject *note);

	void resetFoundPtrsForNote(NoteObject *note);
	BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context);
	BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen);
	BOOL noteTitleMatchesUTF8String(NoteObject *note, const char* fullString);

- (id)delegate;
- (void)setDelegate:(id)theDelegate;
- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle uniqueFilename:(NSString*)aFilename format:(int)formatID;
- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry delegate:(id)aDelegate;

- (NSSet*)labelSet;
- (void)replaceMatchingLabelSet:(NSSet*)aLabelSet;
- (void)replaceMatchingLabel:(LabelObject*)label;
- (void)updateLabelConnectionsAfterDecoding;
- (void)updateLabelConnections;
- (void)setLabelString:(NSString*)newLabels;

- (void)setSyncObjectAndKeyMD:(NSDictionary*)aDict forService:(NSString*)serviceName;
- (void)removeAllSyncMDForService:(NSString*)serviceName;
//- (void)removeKey:(NSString*)aKey forService:(NSString*)serviceName;
- (void)updateWithSyncBody:(NSString*)newBody andTitle:(NSString*)newTitle;
- (void)registerModificationWithOwnedServices;

- (OSStatus)writeCurrentFileEncodingToFSRef:(FSRef*)fsRef;
- (void)_setFileEncoding:(NSStringEncoding)encoding;
- (BOOL)setFileEncodingAndReinterpret:(NSStringEncoding)encoding;
- (BOOL)upgradeToUTF8IfUsingSystemEncoding;
- (BOOL)upgradeEncodingToUTF8;
- (BOOL)updateFromFile;
- (BOOL)updateFromCatalogEntry:(NoteCatalogEntry*)catEntry;
- (BOOL)updateFromData:(NSMutableData*)data;

- (OSStatus)writeFileDatesAndUpdateTrackingInfo;

- (NSString*)noteFilePath;
- (void)invalidateFSRef;

- (BOOL)writeUsingJournal:(WALStorageController*)wal;

- (BOOL)writeUsingCurrentFileFormatIfNecessary;
- (BOOL)writeUsingCurrentFileFormatIfNonExistingOrChanged;
- (BOOL)writeUsingCurrentFileFormat;
- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile;

- (void)moveFileToTrash;
- (void)removeFileFromDirectory;
- (BOOL)removeUsingJournal:(WALStorageController*)wal;

- (OSStatus)exportToDirectoryRef:(FSRef*)directoryRef withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite;
- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange;

- (void)setFilenameFromTitle;
- (void)setFilename:(NSString*)aString withExternalTrigger:(BOOL)externalTrigger;
- (BOOL)_setTitleString:(NSString*)aNewTitle;
- (void)setTitleString:(NSString*)aNewTitle;
- (void)updateTablePreviewString;
- (void)initContentCacheCString;
- (void)updateContentCacheCStringIfNecessary;
- (void)setContentString:(NSAttributedString*)attributedString;
- (NSAttributedString*)contentString;
- (NSAttributedString*)printableStringRelativeToBodyFont:(NSFont*)bodyFont;
- (NSString*)combinedContentWithContextSeparator:(NSString*)sepWContext;
- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont;
- (void)updateDateStrings;
- (void)setDateModified:(CFAbsoluteTime)newTime;
- (void)setDateAdded:(CFAbsoluteTime)newTime;
- (void)setSelectedRange:(NSRange)newRange;
- (NSRange)lastSelectedRange;
- (BOOL)contentsWere7Bit;

- (NSUndoManager*)undoManager;
- (void)_undoManagerDidChange:(NSNotification *)notification;

@end

@interface NSObject (NoteObjectDelegate)
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute;
@end

