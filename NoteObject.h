//
//  NoteObject.h
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "NotationController.h"
#import "SynchronizedNoteProtocol.h"

@class LabelObject;
@class WALStorageController;


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
	unsigned int serverModifiedTime;
	
	//more metadata
	CFAbsoluteTime modifiedDate, createdDate;
	NSRange selectedRange;
	float scrolledProportion;
	
	//each note has its own undo manager--isn't that nice?
	NSUndoManager *undoManager;
}


int compareDateModified(id *a, id *b);
int compareDateCreated(id *a, id *b);
int compareLabelString(id *a, id *b);
int compareTitleString(id *a, id *b);
int compareUniqueNoteIDBytes(id *a, id *b);


int compareDateModifiedReverse(id *a, id *b);
int compareDateCreatedReverse(id *a, id *b);
int compareLabelStringReverse(id *a, id *b);
int compareTitleStringReverse(id *a, id *b);

int compareFilename(id *a, id *b);
int compareNodeID(id *a, id *b);

//syncing w/ server and from journal
- (CFUUIDBytes *)uniqueNoteIDBytes;
- (unsigned int)serverModifiedDate;
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;

- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

	//syncing w/ files in directory
	int storageFormatOfNote(NoteObject *note);
	NSString* filenameOfNote(NoteObject *note);
	UInt32 fileNodeIDOfNote(NoteObject *note);
	UTCDateTime fileModifiedDateOfNote(NoteObject *note);

	NSStringEncoding fileEncodingOfNote(NoteObject *note);

	//note display
	NSString* titleOfNote(NoteObject *note);
	NSAttributedString* tableTitleOfNote(NoteObject *note);
	NSString* labelsOfNote(NoteObject *note);
	NSString *dateCreatedStringOfNote(NoteObject *note);
	NSString *dateModifiedStringOfNote(NoteObject *note);
	NSString* wordCountOfNote(NoteObject *note);

	void resetFoundPtrsForNote(NoteObject *note);
	BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context);
	BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen);

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

- (void)_setFileEncoding:(NSStringEncoding)encoding;
- (BOOL)setFileEncodingAndUpdate:(NSStringEncoding)encoding;
- (BOOL)updateFromFile;
- (BOOL)updateFromCatalogEntry:(NoteCatalogEntry*)catEntry;
- (BOOL)updateFromData:(NSMutableData*)data;

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
- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont;
- (void)updateDateStrings;
- (void)setDateModified:(CFAbsoluteTime)newTime;
- (void)setDateAdded:(CFAbsoluteTime)newTime;
- (void)setSelectedRange:(NSRange)newRange;
- (NSRange)lastSelectedRange;

- (NSUndoManager*)undoManager;
- (void)_undoManagerDidChange:(NSNotification *)notification;

@end

@interface NSObject (NoteObjectDelegate)
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute;
@end

