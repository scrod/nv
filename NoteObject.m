//
//  NoteObject.m
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


#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"
#import "WALController.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "AttributedPlainText.h"
#import "NSString_CustomTruncation.h"
#import "NSFileManager_NV.h"
#include "BufferUtils.h"
#import "NotationFileManager.h"
#import "NotationSyncServiceManager.h"
#import "SyncServiceSessionProtocol.h"
#import "SyncSessionController.h"
#import "NSData_transformations.h"
#import "NSCollection_utils.h"
#import "NotesTableView.h"
#import "UnifiedCell.h"
#import "NSBezierPath_NV.h"

#if __LP64__
// Needed for compatability with data created by 32bit app
typedef struct NSRange32 {
    unsigned int location;
    unsigned int length;
} NSRange32;
#else
typedef NSRange NSRange32;
#endif

@implementation NoteObject

static FSRef *noteFileRefInit(NoteObject* obj);
static void setAttrModifiedDate(NoteObject *note, UTCDateTime *dateTime);

- (id)init {
    if ([super init]) {
	
	cTitle = cContents = cLabels = cTitleFoundPtr = cContentsFoundPtr = cLabelsFoundPtr = NULL;
	
	bzero(&fileModifiedDate, sizeof(UTCDateTime));
	
	attrModDiskPairs = calloc(1, sizeof(AttrModDiskPair));
	attrModDiskPairs[0].diskIDIndex = -1;
	attrModPairCount = 1;
	
	modifiedDate = createdDate = 0.0;
	currentFormatID = SingleDatabaseFormat;
	logSequenceNumber = logicalSize = nodeID = 0;
	fileEncoding = NSUTF8StringEncoding;
	contentsWere7Bit = NO;
	
	selectedRange = NSMakeRange(NSNotFound, 0);
	
	//these are created either when the object is initialized from disk or when it writes its files to disk
	//bzero(&noteFileRef, sizeof(FSRef));
	
	//labelSet = [[NSMutableSet alloc] init];
	
    }
	
    return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[self invalidateFSRef];
	
	[tableTitleString release];
	[titleString release];
	[labelString release];
	[labelSet release];
	[undoManager release];
	[filename release];
	[dateModifiedString release];
	[dateCreatedString release];
	[prefixParentNotes release];
	
	if (attrModDiskPairs)
		free(attrModDiskPairs);
		
	if (cTitle)
		free(cTitle);
	if (cContents)
		free(cContents);
	if (cLabels)
	    free(cLabels);
	
	[super dealloc];
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)theDelegate {
	
	if (theDelegate) {
		delegate = theDelegate;
		
		//do things that ought to have been done during init, but were not possible due to lack of delegate information
		if (!filename) filename = [[delegate uniqueFilenameForTitle:titleString fromNote:self] retain];
		if (!tableTitleString && !didUnarchive) [self updateTablePreviewString];
	}
}

static FSRef *noteFileRefInit(NoteObject* obj) {
	if (!(obj->noteFileRef)) {
		obj->noteFileRef = (FSRef*)calloc(1, sizeof(FSRef));
	}
	return obj->noteFileRef;
}

static void setAttrModifiedDate(NoteObject *note, UTCDateTime *dateTime) {
	assert(note->delegate != nil);
	assert(note->attrModDiskPairs);
	unsigned int idx = SetAttrModTimeForDiskIDIndex(dateTime, (UInt16)diskUUIDIndexForNotation(note->delegate), 
												   &(note->attrModDiskPairs), &(note->attrModPairCount));
	note->attrsModifiedDate = &(note->attrModDiskPairs[idx].attrTime);
}

UTCDateTime *attrsModifiedDateOfNote(NoteObject *note) {
	//once unarchived, the disk UUID index won't change, so this pointer will always reflect the current attr mod time
	if (!note->attrsModifiedDate) {
		
		assert(note->attrModDiskPairs);
		assert(note->delegate != nil);
		//init from delegate based on disk table index
		unsigned int i, tableIndex = diskUUIDIndexForNotation(note->delegate);
		
		for (i=0; i<note->attrModPairCount; i++) {
			if (note->attrModDiskPairs[i].diskIDIndex == tableIndex) {
				note->attrsModifiedDate = &(note->attrModDiskPairs[i].attrTime);
				goto giveDate;
			}
		}
		//this note doesn't have a file-modified date, so initialize one here
		setAttrModifiedDate(note, &(note->fileModifiedDate));
	}
giveDate:	
	return note->attrsModifiedDate;
}

NSInteger compareFilename(id *one, id *two) {
    
    return (NSInteger)CFStringCompare((CFStringRef)((*(NoteObject**)one)->filename), 
				(CFStringRef)((*(NoteObject**)two)->filename), kCFCompareCaseInsensitive);
}

NSInteger compareDateModified(id *a, id *b) {
    return (*(NoteObject**)a)->modifiedDate - (*(NoteObject**)b)->modifiedDate;
}
NSInteger compareDateCreated(id *a, id *b) {
    return (*(NoteObject**)a)->createdDate - (*(NoteObject**)b)->createdDate;
}
NSInteger compareLabelString(id *a, id *b) {    
    return (NSInteger)CFStringCompare((CFStringRef)(labelsOfNote(*(NoteObject **)a)), 
								(CFStringRef)(labelsOfNote(*(NoteObject **)b)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleString(id *a, id *b) {
    CFComparisonResult stringResult = CFStringCompare((CFStringRef)(titleOfNote(*(NoteObject**)a)), 
													  (CFStringRef)(titleOfNote(*(NoteObject**)b)), 
													  kCFCompareCaseInsensitive);
	if (stringResult == kCFCompareEqualTo) {
		
		NSInteger dateResult = compareDateCreated(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(a, b);
		
		return dateResult;
	}
	
	return (NSInteger)stringResult;
}
NSInteger compareUniqueNoteIDBytes(id *a, id *b) {
	return memcmp((&(*(NoteObject**)a)->uniqueNoteIDBytes), (&(*(NoteObject**)b)->uniqueNoteIDBytes), sizeof(CFUUIDBytes));
}


NSInteger compareDateModifiedReverse(id *a, id *b) {
    return (*(NoteObject**)b)->modifiedDate - (*(NoteObject**)a)->modifiedDate;
}
NSInteger compareDateCreatedReverse(id *a, id *b) {
    return (*(NoteObject**)b)->createdDate - (*(NoteObject**)a)->createdDate;
}
NSInteger compareLabelStringReverse(id *a, id *b) {    
    return (NSInteger)CFStringCompare((CFStringRef)(labelsOfNote(*(NoteObject **)b)), 
								(CFStringRef)(labelsOfNote(*(NoteObject **)a)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleStringReverse(id *a, id *b) {
    CFComparisonResult stringResult = CFStringCompare((CFStringRef)(titleOfNote(*(NoteObject **)b)), 
													  (CFStringRef)(titleOfNote(*(NoteObject **)a)), 
													  kCFCompareCaseInsensitive);
	
	if (stringResult == kCFCompareEqualTo) {
		NSInteger dateResult = compareDateCreatedReverse(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(b, a);
		
		return dateResult;
	}
	return (NSInteger)stringResult;	
}

NSInteger compareNodeID(id *a, id *b) {
    return (*(NoteObject**)a)->nodeID - (*(NoteObject**)b)->nodeID;
}
NSInteger compareFileSize(id *a, id *b) {
    return (*(NoteObject**)a)->logicalSize - (*(NoteObject**)b)->logicalSize;
}


#include "SynchronizedNoteMixIns.h"

//syncing w/ server and from journal;

DefModelAttrAccessor(filenameOfNote, filename)
DefModelAttrAccessor(fileNodeIDOfNote, nodeID)
DefModelAttrAccessor(fileSizeOfNote, logicalSize)
DefModelAttrAccessor(titleOfNote, titleString)
DefModelAttrAccessor(labelsOfNote, labelString)
DefModelAttrAccessor(fileModifiedDateOfNote, fileModifiedDate)
DefModelAttrAccessor(modifiedDateOfNote, modifiedDate)
DefModelAttrAccessor(createdDateOfNote, createdDate)
DefModelAttrAccessor(storageFormatOfNote, currentFormatID)
DefModelAttrAccessor(fileEncodingOfNote, fileEncoding)
DefModelAttrAccessor(prefixParentsOfNote, prefixParentNotes)

DefColAttrAccessor(wordCountOfNote, wordCountString)
DefColAttrAccessor(titleOfNote2, titleString)
DefColAttrAccessor(labelsOfNote2, labelString)
DefColAttrAccessor(dateCreatedStringOfNote, dateCreatedString)
DefColAttrAccessor(dateModifiedStringOfNote, dateModifiedString)

force_inline id tableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	if (note->tableTitleString) return note->tableTitleString;
	return titleOfNote(note);
}
force_inline id properlyHighlightingTableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	if (note->tableTitleString) {
		if ([tv isRowSelected:row]) {
			return [note->tableTitleString string];
		}
		return note->tableTitleString;
	}	
	return titleOfNote(note);
}

force_inline id labelColumnCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	
	UnifiedCell *cell = [[tv tableColumnWithIdentifier:NoteLabelsColumnString] dataCellForRow:row];
	[cell setNoteObject:note];
	
	return labelsOfNote(note);
}

force_inline id unifiedCellSingleLineForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	
	id obj = note->tableTitleString ? (id)note->tableTitleString : (id)titleOfNote(note);
	
	UnifiedCell *cell = [[[tv tableColumns] objectAtIndex:0] dataCellForRow:row];
	[cell setNoteObject:note];
	[cell setPreviewIsHidden:YES];
	
	return obj;
}

force_inline id unifiedCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	//snow leopard is stricter about applying the default highlight-attributes (e.g., no shadow unless no paragraph formatting)
	//so add the shadow here for snow leopard on selected rows
	
	UnifiedCell *cell = [[[tv tableColumns] objectAtIndex:0] dataCellForRow:row];
	[cell setNoteObject:note];
	[cell setPreviewIsHidden:NO];

	BOOL rowSelected = [tv isRowSelected:row];
	BOOL drawShadow = IsSnowLeopardOrLater || (IsLeopardOrLater && rowSelected && [tv currentEditor]);
	
	id obj = note->tableTitleString ? (rowSelected ? (id)AttributedStringForSelection(note->tableTitleString, drawShadow) : 
									   (id)note->tableTitleString) : (id)titleOfNote(note);
	
	
	return obj;
}

//make notationcontroller should send setDelegate: and setLabelString: (if necessary) to each note when unarchiving this way

//there is no measurable difference in speed when using decodeValuesOfObjCTypes, oddly enough
//the overhead of the _decodeObject* C functions must be significantly greater than the objc_msgSend and argument passing overhead
#define DECODE_INDIVIDUALLY 1

- (id)initWithCoder:(NSCoder*)decoder {
	if ([self init]) {
		
		if ([decoder allowsKeyedCoding]) {
			//(hopefully?) no versioning necessary here
			
			//for knowing when to delay certain initializations during launch (e.g., preview generation)
			didUnarchive = YES;
			
			modifiedDate = [decoder decodeDoubleForKey:VAR_STR(modifiedDate)];
			createdDate = [decoder decodeDoubleForKey:VAR_STR(createdDate)];
			selectedRange.location = [decoder decodeInt32ForKey:@"selectionRangeLocation"];
			selectedRange.length = [decoder decodeInt32ForKey:@"selectionRangeLength"];
			contentsWere7Bit = [decoder decodeBoolForKey:VAR_STR(contentsWere7Bit)];
			
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];

			currentFormatID = [decoder decodeInt32ForKey:VAR_STR(currentFormatID)];
			nodeID = [decoder decodeInt32ForKey:VAR_STR(nodeID)];
			logicalSize = [decoder decodeInt32ForKey:VAR_STR(logicalSize)];
			
			int64_t fileModifiedDate64 = [decoder decodeInt64ForKey:VAR_STR(fileModifiedDate)];
			memcpy(&fileModifiedDate, &fileModifiedDate64, sizeof(int64_t));
						
			NSUInteger decodedAttrModsByteCount = 0;
			const uint8_t *decodedAttrModsBytes = [decoder decodeBytesForKey:VAR_STR(attrModDiskPairs) returnedLength:&decodedAttrModsByteCount];
			if (decodedAttrModsBytes && decodedAttrModsByteCount) {
				CopyAttrModPairsToOrder(&attrModDiskPairs, &attrModPairCount, (AttrModDiskPair *)decodedAttrModsBytes, decodedAttrModsByteCount, 1);
			}
			
			fileEncoding = [decoder decodeInt32ForKey:VAR_STR(fileEncoding)];

			NSUInteger decodedUUIDByteCount = 0;
			const uint8_t *decodedUUIDBytes = [decoder decodeBytesForKey:VAR_STR(uniqueNoteIDBytes) returnedLength:&decodedUUIDByteCount];
			if (decodedUUIDBytes) memcpy(&uniqueNoteIDBytes, decodedUUIDBytes, MIN(decodedUUIDByteCount, sizeof(CFUUIDBytes)));
			
			syncServicesMD = [[decoder decodeObjectForKey:VAR_STR(syncServicesMD)] retain];
			
			titleString = [[decoder decodeObjectForKey:VAR_STR(titleString)] retain];
			labelString = [[decoder decodeObjectForKey:VAR_STR(labelString)] retain];
			contentString = [[decoder decodeObjectForKey:VAR_STR(contentString)] retain];
			filename = [[decoder decodeObjectForKey:VAR_STR(filename)] retain];
			
		} else {
            NSRange32 range32;
			unsigned int serverModifiedTime = 0;
			float scrolledProportion = 0.0;
            #if __LP64__
            unsigned long longTemp;
            #endif
#if DECODE_INDIVIDUALLY
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
            #if __LP64__
			[decoder decodeValueOfObjCType:"{_NSRange=II}" at:&range32];
            #else
            [decoder decodeValueOfObjCType:@encode(NSRange) at:&range32];
            #endif
			[decoder decodeValueOfObjCType:@encode(float) at:&scrolledProportion];
			
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
			
			[decoder decodeValueOfObjCType:@encode(int) at:&currentFormatID];
            #if __LP64__
            [decoder decodeValueOfObjCType:"L" at:&longTemp];
            nodeID = (UInt32)longTemp;
            #else
			[decoder decodeValueOfObjCType:@encode(UInt32) at:&nodeID];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.highSeconds];
            #if __LP64__
			[decoder decodeValueOfObjCType:"L" at:&longTemp];
            fileModifiedDate.lowSeconds = (UInt32)longTemp;
            #else
            [decoder decodeValueOfObjCType:@encode(UInt32) at:&fileModifiedDate.lowSeconds];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.fraction];	
            
            #if __LP64__
            [decoder decodeValueOfObjCType:"I" at:&fileEncoding];
            #else
            [decoder decodeValueOfObjCType:@encode(NSStringEncoding) at:&fileEncoding];
            #endif
			
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
			
			titleString = [[decoder decodeObject] retain];
			labelString = [[decoder decodeObject] retain];
			contentString = [[decoder decodeObject] retain];
			filename = [[decoder decodeObject] retain];
#else 
			[decoder decodeValuesOfObjCTypes: "dd{NSRange=ii}fIiI{UTCDateTime=SIS}I[16C]I@@@@", &modifiedDate, &createdDate, &range32, 
				&scrolledProportion, &logSequenceNumber, &currentFormatID, &nodeID, &fileModifiedDate, &fileEncoding, &uniqueNoteIDBytes, 
				&serverModifiedTime, &titleString, &labelString, &contentString, &filename];
#endif
            selectedRange.location = range32.location;
            selectedRange.length = range32.length;
			contentsWere7Bit = (*(unsigned int*)&scrolledProportion) != 0; //hacko wacko
		}
	
		//re-created at runtime to save space
		[self initContentCacheCString];
		cTitleFoundPtr = cTitle = titleString ? strdup([titleString lowercaseUTF8String]) : NULL;
		cLabelsFoundPtr = cLabels = labelString ? strdup([labelString lowercaseUTF8String]) : NULL;
		
		dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];
		dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
		
		if (!titleString && !contentString && !labelString) return nil;
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
		
	if ([coder allowsKeyedCoding]) {
		
		[coder encodeDouble:modifiedDate forKey:VAR_STR(modifiedDate)];
		[coder encodeDouble:createdDate forKey:VAR_STR(createdDate)];
		[coder encodeInt32:(unsigned int)selectedRange.location forKey:@"selectionRangeLocation"];
		[coder encodeInt32:(unsigned int)selectedRange.length forKey:@"selectionRangeLength"];
		[coder encodeBool:contentsWere7Bit forKey:VAR_STR(contentsWere7Bit)];
		
		[coder encodeInt32:logSequenceNumber forKey:VAR_STR(logSequenceNumber)];
		
		[coder encodeInt32:currentFormatID forKey:VAR_STR(currentFormatID)];
		[coder encodeInt32:nodeID forKey:VAR_STR(nodeID)];
		[coder encodeInt32:logicalSize forKey:VAR_STR(logicalSize)];

		uint8_t *flippedModDiskPairs = calloc(attrModPairCount, sizeof(AttrModDiskPair));
		CopyAttrModPairsToOrder((AttrModDiskPair**)&flippedModDiskPairs, &attrModPairCount, attrModDiskPairs, attrModPairCount * sizeof(AttrModDiskPair), 0);
		
		[coder encodeBytes:flippedModDiskPairs length:attrModPairCount * sizeof(AttrModDiskPair) forKey:VAR_STR(attrModDiskPairs)];
		free(flippedModDiskPairs);
		
		[coder encodeInt64:*(int64_t*)&fileModifiedDate forKey:VAR_STR(fileModifiedDate)];
		[coder encodeInt32:fileEncoding forKey:VAR_STR(fileEncoding)];
		
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeObject:syncServicesMD forKey:VAR_STR(syncServicesMD)];
		
		[coder encodeObject:titleString forKey:VAR_STR(titleString)];
		[coder encodeObject:labelString forKey:VAR_STR(labelString)];
		[coder encodeObject:contentString forKey:VAR_STR(contentString)];
		[coder encodeObject:filename forKey:VAR_STR(filename)];
		
	} else {
// 64bit encoding would break 32bit reading - keyed archives should be used
#if !__LP64__
		unsigned int serverModifiedTime = 0;
		float scrolledProportion = 0.0;
		*(unsigned int*)&scrolledProportion = (unsigned int)contentsWere7Bit;
#if DECODE_INDIVIDUALLY
		[coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
		[coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
        [coder encodeValueOfObjCType:@encode(NSRange) at:&selectedRange];
		[coder encodeValueOfObjCType:@encode(float) at:&scrolledProportion];
		
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
		
		[coder encodeValueOfObjCType:@encode(int) at:&currentFormatID];
		[coder encodeValueOfObjCType:@encode(UInt32) at:&nodeID];
		[coder encodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.highSeconds];
		[coder encodeValueOfObjCType:@encode(UInt32) at:&fileModifiedDate.lowSeconds];
		[coder encodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.fraction];
		[coder encodeValueOfObjCType:@encode(NSStringEncoding) at:&fileEncoding];
		
		[coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
		
		[coder encodeObject:titleString];
		[coder encodeObject:labelString];
		[coder encodeObject:contentString];
		[coder encodeObject:filename];
		
#else
		[coder encodeValuesOfObjCTypes: "dd{NSRange=ii}fIiI{UTCDateTime=SIS}I[16C]I@@@@", &modifiedDate, &createdDate, &range32, 
			&scrolledProportion, &logSequenceNumber, &currentFormatID, &nodeID, &fileModifiedDate, &fileEncoding, &uniqueNoteIDBytes, 
			&serverModifiedTime, &titleString, &labelString, &contentString, &filename];
#endif
#endif // !__LP64__
	}
}

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle delegate:(id)aDelegate format:(int)formatID {
	//delegate optional here
    if ([self init]) {
		
		if (!bodyText || !aNoteTitle) {
			return nil;
		}
		delegate = aDelegate;

		contentString = [[NSMutableAttributedString alloc] initWithAttributedString:bodyText];
		[self initContentCacheCString];
		if (!cContents) {
			NSLog(@"couldn't get UTF8 string from contents?!?");
			return nil;
		}

		if (![self _setTitleString:aNoteTitle])
		    titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		labelString = @"";
		cLabelsFoundPtr = cLabels = strdup("");
		
		currentFormatID = formatID;
		filename = [[delegate uniqueFilenameForTitle:titleString fromNote:nil] retain];
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent();
		dateCreatedString = [dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain] retain];
		UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &fileModifiedDate);
		
		//delegate is not set yet, so we cannot dirty ourselves here
		//[self makeNoteDirty];
    }
	if (delegate)
		[self updateTablePreviewString];
    
    return self;
}

//only get the fsrefs until we absolutely need them

- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry delegate:(id)aDelegate {
	NSAssert(aDelegate != nil, @"must supply a delegate");
    if ([self init]) {
		delegate = aDelegate;
		filename = [(NSString*)entry->filename copy];
		currentFormatID = [delegate currentNoteStorageFormat];
		fileModifiedDate = entry->lastModified;
		setAttrModifiedDate(self, &(entry->lastAttrModified));
		nodeID = entry->nodeID;
		logicalSize = entry->logicalSize;
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		if (![self _setTitleString:[filename stringByDeletingPathExtension]])
			titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		labelString = @""; //I'd like to get labels from getxattr
		cLabelsFoundPtr = cLabels = strdup("");	
				
		contentString = [[NSMutableAttributedString alloc] initWithString:@""];
		[self initContentCacheCString];
		
		if (![self updateFromCatalogEntry:entry]) {						
			//just initialize a blank note for now; if the file becomes readable again we'll be updated
			//but if we make modifications, well, the original is toast
			//so warn the user here and offer to trash it?
			//perhaps also offer to re-interpret using another text encoding?
			
			//additionally, it is possible that the file was deleted before we could read it
		}
		if (!modifiedDate || !createdDate) {
			modifiedDate = createdDate = CFAbsoluteTimeGetCurrent();
			dateModifiedString = [dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain] retain];	
		}
    }
	
	[self updateTablePreviewString];
    
    return self;
}

//assume any changes have been synchronized with undomanager
- (void)setContentString:(NSAttributedString*)attributedString {
	if (attributedString) {
		[contentString setAttributedString:attributedString];
		
		[self updateTablePreviewString];
		contentCacheNeedsUpdate = YES;
		//[self updateContentCacheCStringIfNecessary];
		
		[delegate note:self attributeChanged:NotePreviewString];
	
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
	}
}
- (NSAttributedString*)contentString {
	return contentString;
}

- (void)updateContentCacheCStringIfNecessary {
	if (contentCacheNeedsUpdate) {
		//NSLog(@"updating ccache strs");
		cContentsFoundPtr = cContents = replaceString(cContents, [[contentString string] lowercaseUTF8String]);
		contentCacheNeedsUpdate = NO;
		
		int len = strlen(cContents);
		contentsWere7Bit = !(ContainsHighAscii(cContents, len));
		
		//could cache dumbwordcount here for faster launch, but string creation takes more time, anyway
		//if (wordCountString) CFRelease((CFStringRef*)wordCountString); //this is CFString, so bridge will just call back to CFRelease, anyway
		//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	}
}

- (void)initContentCacheCString {

	if (contentsWere7Bit) {
		if (!(cContentsFoundPtr = cContents = [[contentString string] copyLowercaseASCIIString]))
			contentsWere7Bit = NO;
	}
	
	size_t len = -1;
	
	if (!contentsWere7Bit) {
		const char *cStringData = [[contentString string] lowercaseUTF8String];
		cContentsFoundPtr = cContents = cStringData ? strdup(cStringData) : NULL;
		
		contentsWere7Bit = cContents ? !(ContainsHighAscii(cContents, (len = strlen(cContents)))) : NO;
	}
	
	//if (len < 0) len = strlen(cContents);
	//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	
	contentCacheNeedsUpdate = NO;
}

- (BOOL)contentsWere7Bit {
	return contentsWere7Bit;
}

- (NSString*)description {
	return syncServicesMD ? [NSString stringWithFormat:@"%@ / %@", titleString, syncServicesMD] : titleString;
}

- (NSString*)combinedContentWithContextSeparator:(NSString*)sepWContext {
	//combine title and body based on separator data usually generated by -syntheticTitleAndSeparatorWithContext:bodyLoc:
	//if separator does not exist or chars do not match trailing and leading chars of title and body, respectively,
	//then just delimit with a double-newline
	
	NSString *content = [contentString string];
	
	BOOL defaultJoin = NO;
	if (![sepWContext length] || ![content length] || ![titleString length] || 
		[titleString characterAtIndex:[titleString length] - 1] != [sepWContext characterAtIndex:0] ||
		[content characterAtIndex:0] != [sepWContext characterAtIndex:[sepWContext length] - 1]) {
		defaultJoin = YES;
	}
	
	NSString *separator = @"\n\n";
	
	//if the separator lacks any actual separating characters, then concatenate with an empty string
	if (!defaultJoin) {
		separator = [sepWContext length] > 2 ? [sepWContext substringWithRange:NSMakeRange(1, [sepWContext length] - 2)] : @"";
	}
	
	NSMutableString *combined = [[NSMutableString alloc] initWithCapacity:[content length] + [titleString length] + [separator length]];
	
	[combined appendString:titleString];
	[combined appendString:separator];
	[combined appendString:content];
	
	return [combined autorelease];
}


- (NSAttributedString*)printableStringRelativeToBodyFont:(NSFont*)bodyFont {
	NSFont *titleFont = [NSFont fontWithName:[bodyFont fontName] size:[bodyFont pointSize] + 6.0f];
	
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:titleFont, NSFontAttributeName, nil];
	
	NSMutableAttributedString *largeAttributedTitleString = [[[NSMutableAttributedString alloc] initWithString:titleString attributes:dict] autorelease];
	
	NSAttributedString *noAttrBreak = [[NSAttributedString alloc] initWithString:@"\n\n\n" attributes:nil];
	[largeAttributedTitleString appendAttributedString:noAttrBreak];
	[noAttrBreak release];

	//other header things here, too? like date created/mod/printed? tags?
	NSMutableAttributedString *contentMinusColor = [[self contentString] mutableCopy];
	[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];
	
	[largeAttributedTitleString appendAttributedString:contentMinusColor];
	
	[contentMinusColor release];
	
	return largeAttributedTitleString;
}

- (void)updateTablePreviewString {
	//delegate required for this method
	[tableTitleString release];
	GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];

	if ([prefs tableColumnsShowPreview]) {
		if ([prefs horizontalLayout]) {
			//labelsPreviewImage does work only when the image is explicitly invalidated, and because updateTablePreviewString 
			//is called for visible notes at launch and resize only, generation of images for invisible notes is delayed until after launch
			NSImage *img = [self labelsPreviewImage];
			tableTitleString = [[titleString attributedMultiLinePreviewFromBodyText:contentString upToWidth:[delegate titleColumnWidth] 
																	 intrusionWidth:img ? [img size].width : 0.0] retain];
		} else {
			tableTitleString = [[titleString attributedSingleLinePreviewFromBodyText:contentString upToWidth:[delegate titleColumnWidth]] retain];
		}
	} else {
		if ([prefs horizontalLayout]) {
			tableTitleString = [[titleString attributedSingleLineTitle] retain];
		} else {
			tableTitleString = nil;
		}
	}
}

- (void)setTitleString:(NSString*)aNewTitle {
	
	NSString *oldTitle = [titleString retain];
	
    if ([self _setTitleString:aNewTitle]) {
		//do you really want to do this when the format is a single DB and the file on disk hasn't been removed?
		//the filename could get out of sync if we lose the fsref and we could end up with a second file after note is rewritten
		
		//solution: don't change the name in that case and allow its new name to be generated
		//when the format is changed and the file rewritten?
		
		
		
		//however, the filename is used for exporting and potentially other purposes, so we should also update
		//it if we know that is has no currently existing (older) counterpart in the notes directory
		
		//woe to the exporter who also left the note files in the notes directory after switching to a singledb format
		//his note names might not be up-to-date
		if ([delegate currentNoteStorageFormat] != SingleDatabaseFormat || 
			![delegate notesDirectoryContainsFile:filename returningFSRef:noteFileRefInit(self)]) {
			
			[self setFilenameFromTitle];
		}
		
		//yes, the given extension could be different from what we had before
		//but makeNoteDirty will eventually cause it to be re-written in the current format
		//and thus the format ID will be changed if that was the case
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		[self updateTablePreviewString];
		
		/*NSUndoManager *undoMan = [delegate undoManager];
		[undoMan registerUndoWithTarget:self selector:@selector(setTitleString:) object:oldTitle];
		if (![undoMan isUndoing] && ![undoMan isRedoing])
			[undoMan setActionName:[NSString stringWithFormat:@"Rename Note \"%@\"", titleString]];
		*/
		[oldTitle release];
		
		[delegate note:self attributeChanged:NoteTitleColumnString];
    }
}

- (BOOL)_setTitleString:(NSString*)aNewTitle {
    if (!aNewTitle || ![aNewTitle length] || (titleString && [aNewTitle isEqualToString:titleString]))
	return NO;
    
    [titleString release];
    titleString = [aNewTitle copy];
    
    cTitleFoundPtr = cTitle = replaceString(cTitle, [titleString lowercaseUTF8String]);
    
    return YES;
}

- (void)setFilenameFromTitle {
	[self setFilename:[delegate uniqueFilenameForTitle:titleString fromNote:self] withExternalTrigger:NO];
}

- (void)setFilename:(NSString*)aString withExternalTrigger:(BOOL)externalTrigger {
    
    if (!filename || ![aString isEqualToString:filename]) {
		NSString *oldName = filename;
		filename = [aString copy];
		
		if (!externalTrigger) {
			if ([delegate noteFileRenamed:noteFileRefInit(self) fromName:oldName toName:filename] != noErr) {
				NSLog(@"Couldn't rename note %@", titleString);
				
				//revert name
				[filename release];
				filename = [oldName retain];
				return;
			}
		} else {
			[self _setTitleString:[aString stringByDeletingPathExtension]];	
			
			[self updateTablePreviewString];
			[delegate note:self attributeChanged:NoteTitleColumnString];
		}
		
		[self makeNoteDirtyUpdateTime:YES updateFile:NO];
		
		[delegate updateLinksToNote:self fromOldName:oldName];
		//update all the notes that link to the old filename as well!!
		
		[oldName release];
    }
}

//how do we write a thousand RTF files at once, repeatedly? 

- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont {

	if ([contentString restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:baseFont] > 0) {
		[undoManager removeAllActions];
		
		if ([delegate currentNoteStorageFormat] == RTFTextFormat)
			[self makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
}

- (void)updateDateStrings {
	[dateModifiedString release];
	[dateCreatedString release];
	
	dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];
	dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
}

- (void)setDateModified:(CFAbsoluteTime)newTime {
	modifiedDate = newTime;
	
	[dateModifiedString release];
	
	dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
}

- (void)setDateAdded:(CFAbsoluteTime)newTime {
	createdDate = newTime;
	
	[dateCreatedString release];
	
	dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];	
}


- (void)setSelectedRange:(NSRange)newRange {
	//if (!newRange.length) newRange = NSMakeRange(0,0);
	
	//don't save the range if it's invalid, it's equal to the current range, or the entire note is selected
	if ((newRange.location != NSNotFound) && !NSEqualRanges(newRange, selectedRange) && 
		!NSEqualRanges(newRange, NSMakeRange(0, [contentString length]))) {
	//	NSLog(@"saving: old range: %@, new range: %@", NSStringFromRange(selectedRange), NSStringFromRange(newRange));
		selectedRange = newRange;
		[self makeNoteDirtyUpdateTime:NO updateFile:NO];
	}
}

- (NSRange)lastSelectedRange {
	return selectedRange;
}

//these two methods let us get the actual label objects in use by other notes
//they assume that the label string already contains the title of the label object(s); that there is only replacement and not addition
- (void)replaceMatchingLabelSet:(NSSet*)aLabelSet {
    [labelSet minusSet:aLabelSet];
    [labelSet unionSet:aLabelSet];
}

- (void)replaceMatchingLabel:(LabelObject*)aLabel {
    [aLabel retain]; // just in case this is actually the same label
    
    //remove the old label and add the new one; if this is the same one, well, too bad
    [labelSet removeObject:aLabel];
    [labelSet addObject:aLabel];
    [aLabel release];
}

- (void)updateLabelConnectionsAfterDecoding {
	if ([labelString length] > 0) {
		[self updateLabelConnections];
	}
}

- (void)updateLabelConnections {
	return;
	//find differences between previous labels and new ones
	NSMutableSet *oldLabelSet = labelSet;
	NSMutableSet *newLabelSet = [labelString labelSetFromWordsAndContainingNote:self];
	
	//what's left-over
	NSMutableSet *oldLabels = [oldLabelSet mutableCopy];
	[oldLabels minusSet:newLabelSet];
	
	//what wasn't there last time
	NSMutableSet *newLabels = newLabelSet;
	[newLabels minusSet:oldLabelSet];
	
	//update the currently known labels
	[labelSet minusSet:oldLabels];
	[labelSet unionSet:newLabels];
	
	//update our status within the list of all labels, adding or removing from the list and updating the labels where appropriate
	//these end up calling replaceMatchingLabel*
	[delegate note:self didRemoveLabelSet:oldLabels];
	[delegate note:self didAddLabelSet:newLabels];
}

- (void)setLabelString:(NSString*)newLabelString {
	if (newLabelString && ![newLabelString isEqualToString:labelString]) {
		
		[labelString release];
		labelString = [newLabelString copy];
		
		cLabelsFoundPtr = cLabels = replaceString(cLabels, [labelString lowercaseUTF8String]);
		
		[self updateLabelConnections];
		[self invalidateLabelsPreviewImage];
		if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
			[self updateTablePreviewString];
		}
		
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		//[self registerModificationWithOwnedServices];
		
		[delegate note:self attributeChanged:NoteLabelsColumnString];
	}
}

- (NSArray*)orderedLabelTitles {
	
	NSArray *array = nil;
	if (IsLeopardOrLater) {
		NSMutableCharacterSet *charSet = [NSMutableCharacterSet whitespaceCharacterSet];
		[charSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@","]];

		array = [labelString componentsSeparatedByCharactersInSet:charSet];
	} else {
		BOOL lacksSpace = [labelString rangeOfString:@" " options:NSLiteralSearch].location == NSNotFound;
		array = [labelString componentsSeparatedByString: lacksSpace ? @"," : @" "];
	}
	NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[array count]];
	
	NSUInteger i;
	for (i=0; i<[array count]; i++) {
		NSString *aWord = [array objectAtIndex:i];
		if ([aWord length] > 0) [titles addObject:aWord];
	}
	return titles;
}

- (void)invalidateLabelsPreviewImage {
	[labelsPreviewImage release];
	labelsPreviewImage = nil;
}

- (NSImage*)labelsPreviewImage {
	if (!labelsPreviewImage && [labelString length]) {
		labelsPreviewImage = [[self labelsPreviewImageOfColor:[NSColor colorWithCalibratedWhite:0.55 alpha:1.0]] retain];
	}
	return labelsPreviewImage;
}

- (NSImage*)labelsPreviewImageOfColor:(NSColor*)aColor {
	if ([labelString length]) {
		float tableFontSize = [[GlobalPrefs defaultPrefs] tableFontSize] - 1.0;
		NSFont *font = [NSFont systemFontOfSize:tableFontSize];
		NSDictionary *attrs = [NSDictionary dictionaryWithObject:font forKey:NSFontNameAttribute];
		
		//compute dimensions of each word first using nslayoutmanager; -sizeWithAttributes: likes to ignore the font and size here for some reason

		NSTextStorage *textStorage = [[NSTextStorage alloc] initWithString:@"" attributes:attrs];
		NSTextContainer *textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(1e7, 1e7)];
		NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
		
		[textContainer setLineFragmentPadding:0.0];
		[layoutManager addTextContainer:textContainer];
		[textStorage addLayoutManager:layoutManager];
				
		NSArray *words = [self orderedLabelTitles];
		if (![words count])
			return nil;
		
		NSBezierPath *blocksPath = [NSBezierPath bezierPath];
		NSPoint nextBoxPoint = NSZeroPoint;
		NSUInteger i;
		float imageWidth = 0.0;
		
		for (i=0; i<[words count]; i++) {
			NSString *word = [words objectAtIndex:i];
			if ([word length]) {
				
				//Force the layout manager to layout its text
				[[textStorage mutableString] setString:word];
				[textStorage setFont:font]; //will infuriatingly revert to measuring Lucida Grande 11 otherwise, despite what it actually says
				
				(void)[layoutManager glyphRangeForTextContainer:textContainer];
				NSSize wordSize = [layoutManager usedRectForTextContainer:textContainer].size;
				
				NSRect wordRect = NSMakeRect(nextBoxPoint.x, nextBoxPoint.y, roundf(wordSize.width + 4.0), roundf(tableFontSize * 1.3));
				imageWidth += wordRect.size.width + 4.0;
				
				NSBezierPath *stringPath = [NSBezierPath bezierPathWithLayoutManager:layoutManager characterRange:NSMakeRange(0,[word length]) 
																			 atPoint:NSMakePoint(nextBoxPoint.x + 2.0, 3.0)];
				wordRect.origin = nextBoxPoint;
				
				NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundRectInRect:wordRect radius:2.0f];
				
				[backgroundPath setWindingRule:NSEvenOddWindingRule];
				[backgroundPath appendBezierPath:stringPath];
				
				[blocksPath appendBezierPath:backgroundPath];
				
				nextBoxPoint = NSMakePoint(roundf(nextBoxPoint.x + wordRect.size.width + 4.0), 0.0);
			}
		}
		
				
		NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth - 4.0, tableFontSize * 1.3 + 1.5)];
		[img lockFocus];
		
		[aColor setFill];
		[blocksPath fill];
		
		[img unlockFocus];
		
		[textContainer release];
		[layoutManager release];
		[textStorage release];
		
		return [img autorelease];
	}
	return nil;
}


- (NSURL*)uniqueNoteLink {
		
	NSArray *svcs = [[SyncSessionController class] allServiceNames];
	NSMutableDictionary *idsDict = [NSMutableDictionary dictionaryWithCapacity:[svcs count] + 1];

	//include all identifying keys in case the title changes later
	NSUInteger i = 0;
	for (i=0; i<[svcs count]; i++) {
		NSString *syncID = [[syncServicesMD objectForKey:[svcs objectAtIndex:i]]
							objectForKey:[[[SyncSessionController allServiceClasses] objectAtIndex:i] nameOfKeyElement]];
		if (syncID) [idsDict setObject:syncID forKey:[svcs objectAtIndex:i]];
	}
	[idsDict setObject:[[NSData dataWithBytes:&uniqueNoteIDBytes length:16] encodeBase64WithNewlines:NO] forKey:@"NV"];
	
	return [NSURL URLWithString:[@"nv://find/" stringByAppendingFormat:@"%@/?%@", [titleString stringWithPercentEscapes], 
								 [idsDict URLEncodedString]]];
}

- (NSString*)noteFilePath {
	UniChar chars[256];
	if ([delegate refreshFileRefIfNecessary:noteFileRefInit(self) withName:filename charsBuffer:chars] == noErr)
		return [[NSFileManager defaultManager] pathWithFSRef:noteFileRefInit(self)];
	return nil;
}

- (void)invalidateFSRef {
	//bzero(&noteFileRef, sizeof(FSRef));
	if (noteFileRef)
		free(noteFileRef);
	noteFileRef = NULL;
}

- (BOOL)writeUsingCurrentFileFormatIfNecessary {
	//if note had been updated via makeNoteDirty and needed file to be rewritten
	if (shouldWriteToFile) {
		return [self writeUsingCurrentFileFormat];
	}
	return NO;
}

- (BOOL)writeUsingCurrentFileFormatIfNonExistingOrChanged {
    BOOL fileWasCreated = NO;
    BOOL fileIsOwned = NO;
	
    if ([delegate createFileIfNotPresentInNotesDirectory:noteFileRefInit(self) forFilename:filename fileWasCreated:&fileWasCreated] != noErr)
		return NO;
    
    if (fileWasCreated) {
		NSLog(@"writing note %@, because it didn't exist", titleString);
		return [self writeUsingCurrentFileFormat];
    }
    
	//createFileIfNotPresentInNotesDirectory: works by name, so if this file is not owned by us at this point, it was a race with moving it
    FSCatalogInfo info;
    if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:&fileIsOwned hasCatalogInfo:&info] != noErr)
		return NO;
    
    CFAbsoluteTime timeOnDisk, lastTime;
    OSStatus err = noErr;
    if ((err = (UCConvertUTCDateTimeToCFAbsoluteTime(&fileModifiedDate, &lastTime) == noErr)) &&
		(err = (UCConvertUTCDateTimeToCFAbsoluteTime(&info.contentModDate, &timeOnDisk) == noErr))) {
		
		if (lastTime > timeOnDisk) {
			NSLog(@"writing note %@, because it was modified", titleString);
			return [self writeUsingCurrentFileFormat];
		}
    } else {
		NSLog(@"Could not convert dates: %d", err);
		return NO;
    }
    
    return YES;
}

- (BOOL)writeUsingJournal:(WALStorageController*)wal {
    BOOL wroteAllOfNote = [wal writeEstablishedNote:self];
	
    if (wroteAllOfNote) {
		//update formatID to absolutely ensure we don't reload an earlier note back from disk, from text encoding menu, for example
		//currentFormatID = SingleDatabaseFormat;
	} else {
		[delegate noteDidNotWrite:self errorCode:kWriteJournalErr];
	}
    
    return wroteAllOfNote;
}

- (BOOL)writeUsingCurrentFileFormat {

    NSData *formattedData = nil;
    NSError *error = nil;
	
    int formatID = [delegate currentNoteStorageFormat];
    switch (formatID) {
		case SingleDatabaseFormat:
			//we probably shouldn't be here
			NSAssert(NO, @"Warning! Tried to write data for an individual note in single-db format!");
			
			return NO;
		case PlainTextFormat:
			
			if (!(formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:NO])) {
				
				//just make the file unicode and ram it through
				//unicode is probably better than UTF-8, as it's more easily auto-detected by other programs via the BOM
				//but we can auto-detect UTF-8, so what the heck
				[self _setFileEncoding:NSUTF8StringEncoding];
				//maybe we could rename the file file.utf8.txt here
				NSLog(@"promoting to unicode (UTF-8)");
				formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:YES];
			}
			break;
		case RTFTextFormat:
			formattedData = [contentString RTFFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			
			break;
		case HTMLFormat:
			//export to HTML document here using NSHTMLTextDocumentType;
			formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			//our links will always be to filenames, so hopefully we shouldn't have to change anything
			break;
		default:
			NSLog(@"Attempted to write using unknown format ID: %d", formatID);
			//return NO;
    }
    
    if (formattedData) {
		BOOL resetFilename = NO;
		if (!filename || currentFormatID != formatID) {
			//file will (probably) be renamed
			//NSLog(@"resetting the file name due to format change: to %d from %d", formatID, currentFormatID);
			[self setFilenameFromTitle];
			resetFilename = YES;
		}
		
		currentFormatID = formatID;
		
		//perhaps check here to see if the file was updated on disk before we had a chance to do it ourselves
		//see if the file's fileModDate (if it exists) is newer than this note's current fileModificationDate
		//could offer to merge or revert changes
		
		OSStatus err = noErr;
		if ((err = [delegate storeDataAtomicallyInNotesDirectory:formattedData withName:filename destinationRef:noteFileRefInit(self)]) != noErr) {
			NSLog(@"Unable to save note file %@", filename);
			
			[delegate noteDidNotWrite:self errorCode:err];
			return NO;
		}
		//if writing plaintext set the file encoding with setxattr
		if (PlainTextFormat == formatID) {
			(void)[self writeCurrentFileEncodingToFSRef:noteFileRefInit(self)];
		}
		NSFileManager *fileMan = [NSFileManager defaultManager];
		[fileMan setOpenMetaTags:[self orderedLabelTitles] atFSPath:[[fileMan pathWithFSRef:noteFileRefInit(self)] fileSystemRepresentation]];
		
		//always hide the file extension for all types
		LSSetExtensionHiddenForRef(noteFileRefInit(self), TRUE);
		
		if (!resetFilename) {
			//NSLog(@"resetting the file name just because.");
			[self setFilenameFromTitle];
		}
		
		(void)[self writeFileDatesAndUpdateTrackingInfo];
		
		
		//finished writing to file successfully
		shouldWriteToFile = NO;
		
		
		//tell any external editors that we've changed
		
    } else {
		[delegate noteDidNotWrite:self errorCode:kDataFormattingErr];
		NSLog(@"Unable to convert note contents into format %d", formatID);
		return NO;
    }
    
    return YES;
}

- (OSStatus)writeFileDatesAndUpdateTrackingInfo {
	if (SingleDatabaseFormat == currentFormatID) return noErr;
	
	//sync the file's creation and modification date:
	FSCatalogInfo catInfo;
	UCConvertCFAbsoluteTimeToUTCDateTime(createdDate, &catInfo.createDate);
	UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &catInfo.contentModDate);
	
	// if this method is called anywhere else, then use [delegate refreshFileRefIfNecessary:noteFileRefInit(self) withName:filename charsBuffer:chars]; instead
	// for now, it is not called in any situations where the fsref might accidentally point to a moved file
	OSStatus err = noErr;
	do {
		if (noErr != err || IsZeros(noteFileRefInit(self), sizeof(FSRef))) {
			if (![delegate notesDirectoryContainsFile:filename returningFSRef:noteFileRefInit(self)]) return fnfErr;
		}
		err = FSSetCatalogInfo(noteFileRefInit(self), kFSCatInfoCreateDate | kFSCatInfoContentMod, &catInfo);
	} while (fnfErr == err);

	if (noErr != err) {
		NSLog(@"could not set catalog info: %d", err);
		return err;
	}
	
	//regardless of whether FSSetCatalogInfo was successful, the file mod date could still have changed
	
	if ((err = [delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:NULL hasCatalogInfo:&catInfo]) != noErr) {
		NSLog(@"Unable to get new modification date of file %@: %d", filename, err);
		return err;
	}
	fileModifiedDate = catInfo.contentModDate;
	setAttrModifiedDate(self, &catInfo.attributeModDate);
	nodeID = catInfo.nodeID;
	logicalSize = (UInt32)(catInfo.dataLogicalSize & 0xFFFFFFFF);
	
	return noErr;
}

- (OSStatus)writeCurrentFileEncodingToFSRef:(FSRef*)fsRef {
	NSAssert(fsRef, @"cannot write file encoding to a NULL FSRef");
	//this is not the note's own fsRef; it could be anywhere
	
	NSMutableData *pathData = [NSMutableData dataWithLength:4 * 1024];
	OSStatus err = noErr;
	if ((err = FSRefMakePath(fsRef, [pathData mutableBytes], [pathData length])) == noErr) {
		[[NSFileManager defaultManager] setTextEncodingAttribute:fileEncoding atFSPath:[pathData bytes]];
	} else {
		NSLog(@"%s: error getting path from FSRef: %d (IsZeros: %d)", _cmd, err, IsZeros(fsRef, sizeof(fsRef)));
	}
	return err;
}

- (BOOL)upgradeToUTF8IfUsingSystemEncoding {
	if (CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding()) == fileEncoding)
		return [self upgradeEncodingToUTF8];
	return NO;
}

- (BOOL)upgradeEncodingToUTF8 {
	//"convert" the file to have a UTF-8 encoding
	BOOL didUpgrade = YES;
	
	if (NSUTF8StringEncoding != fileEncoding) {
		[self _setFileEncoding:NSUTF8StringEncoding];
		
		if (!contentsWere7Bit && PlainTextFormat == currentFormatID) {
			//this note exists on disk as a plaintext file, and its encoding is incompatible with UTF-8
			
			if ([delegate currentNoteStorageFormat] == PlainTextFormat) {
				//actual conversion is expected because notes are presently being maintained as plain text files
				
				NSLog(@"rewriting %@ as utf8 data", titleString);
				didUpgrade = [self writeUsingCurrentFileFormat];
			} else if ([delegate currentNoteStorageFormat] == SingleDatabaseFormat) {
				//update last-written-filemod time to guarantee proper encoding at next DB storage format switch, 
				//in case this note isn't otherwise modified before that happens.
				//a side effect is that if the user switches to an RTF or HTML format,
				//this note will be written immediately instead of lazily upon the next modification
				if (UCConvertCFAbsoluteTimeToUTCDateTime(CFAbsoluteTimeGetCurrent(), &fileModifiedDate) != noErr)
					NSLog(@"%s: can't set file modification date from current date", _cmd);
			}
		}
		//make note dirty to ensure these changes are saved
		[self makeNoteDirtyUpdateTime:NO updateFile:NO];
	}
	return didUpgrade;
}

- (void)_setFileEncoding:(NSStringEncoding)encoding {
	fileEncoding = encoding;
}

- (BOOL)setFileEncodingAndReinterpret:(NSStringEncoding)encoding {
	//"reinterpret" the file using this encoding, also setting the actual file's extended attributes to match
	BOOL updated = YES;
	
	if (encoding != fileEncoding) {
		[self _setFileEncoding:encoding];
		
		//write the file encoding extended attribute before updating from disk. why?
		//a) to ensure -updateFromData: finds the right encoding when re-reading the file, and
		//b) because the file is otherwise not being rewritten, and the extended attribute--if it existed--may have been different
		
		UniChar chars[256];
		if ([delegate refreshFileRefIfNecessary:noteFileRefInit(self) withName:filename charsBuffer:chars] != noErr)
			return NO;
		
		if ([self writeCurrentFileEncodingToFSRef:noteFileRefInit(self)] != noErr)
			return NO;		
		
		if ((updated = [self updateFromFile])) {
			[self makeNoteDirtyUpdateTime:NO updateFile:NO];
			//need to update modification time manually
			[self registerModificationWithOwnedServices];
			[delegate schedulePushToAllSyncServicesForNote:self];
			//[[delegate delegate] contentsUpdatedForNote:self];
		}
	}
	
	return updated;
}

- (BOOL)updateFromFile {
    NSMutableData *data = [delegate dataFromFileInNotesDirectory:noteFileRefInit(self) forFilename:filename];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk");
		return NO;
    }
	
    if ([self updateFromData:data]) {
		FSCatalogInfo info;
		if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:NULL hasCatalogInfo:&info] == noErr) {
			fileModifiedDate = info.contentModDate;
			setAttrModifiedDate(self, &info.attributeModDate);
			nodeID = info.nodeID;
			logicalSize = (UInt32)(info.dataLogicalSize & 0xFFFFFFFF);
			
			return YES;
		}
    }
    return NO;
}

- (BOOL)updateFromCatalogEntry:(NoteCatalogEntry*)catEntry {
	BOOL didRestoreLabels = NO;
	
    NSMutableData *data = [delegate dataFromFileInNotesDirectory:noteFileRefInit(self) forCatalogEntry:catEntry];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk given catalog entry");
		return NO;
    }
	    
    if (![self updateFromData:data])
		return NO;
	
	[self setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
    
    fileModifiedDate = catEntry->lastModified;
	setAttrModifiedDate(self, &(catEntry->lastAttrModified));
    nodeID = catEntry->nodeID;
	logicalSize = catEntry->logicalSize;
	
	NSMutableData *pathData = [NSMutableData dataWithLength:4 * 1024];
	if (FSRefMakePath(noteFileRefInit(self), [pathData mutableBytes], [pathData length]) == noErr) {
		
		NSArray *openMetaTags = [[NSFileManager defaultManager] getOpenMetaTagsAtFSPath:[pathData bytes]];
		if (openMetaTags) {
			//overwrite this note's labels with those from the file; merging may be the wrong thing to do here
			[self setLabelString:[openMetaTags componentsJoinedByString:@" "]];
		} else if ([labelString length]) {
			//this file has either never had tags or has had them cleared by accident (e.g., non-user intervention)
			//so if this note still has tags, then restore them now.
			
			NSLog(@"restoring lost tags for %@", titleString);
			[[NSFileManager defaultManager] setOpenMetaTags:[self orderedLabelTitles] atFSPath:[pathData bytes]];
			didRestoreLabels = YES;
		}
	}
	
	OSStatus err = noErr;
	CFAbsoluteTime aModDate, aCreateDate;
	if (noErr == (err = UCConvertUTCDateTimeToCFAbsoluteTime(&fileModifiedDate, &aModDate))) {
		[self setDateModified:aModDate];
	}
	
	if (createdDate == 0.0 || didRestoreLabels) {
		//when reading files from disk for the first time, grab their creation date
		//or if this file has just been altered, grab its newly-changed modification dates
		
		FSCatalogInfo info;
		if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:NULL hasCatalogInfo:&info] == noErr) {
			if (createdDate == 0.0 && UCConvertUTCDateTimeToCFAbsoluteTime(&info.createDate, &aCreateDate) == noErr) {
				[self setDateAdded:aCreateDate];
			}
			if (didRestoreLabels) {
				fileModifiedDate = info.contentModDate;
				setAttrModifiedDate(self, &info.attributeModDate);
			}
		}
	}
	
    return YES;
}

- (BOOL)updateFromData:(NSMutableData*)data {
    
    if (!data) {
		NSLog(@"%@: Data is nil!", NSStringFromSelector(_cmd));
		return NO;
    }
    
    NSMutableString *stringFromData = nil;
    NSMutableAttributedString *attributedStringFromData = nil;
    //interpret based on format; text, rtf, html, etc...
    switch (currentFormatID) {
	case SingleDatabaseFormat:
	    //hmmmmm
		NSAssert(NO, @"Warning! Tried to update data from a note in single-db format!");
	    
	    break;
	case PlainTextFormat:
		//try to merge/re-match attributes?
	    if ((stringFromData = [NSMutableString newShortLivedStringFromData:data ofGuessedEncoding:&fileEncoding withPath:NULL orWithFSRef:noteFileRefInit(self)])) {
			attributedStringFromData = [[NSMutableAttributedString alloc] initWithString:stringFromData 
																			  attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
			[stringFromData release];
	    } else {
			NSLog(@"String could not be initialized from data");
	    }
	    
	    break;
	case RTFTextFormat:
	    
		attributedStringFromData = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
	    break;
	case HTMLFormat:

		attributedStringFromData = [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL];
		[attributedStringFromData removeAttachments];
		
	    break;
	default:
	    NSLog(@"%@: Unknown format: %d", NSStringFromSelector(_cmd), currentFormatID);
    }
    
    if (!attributedStringFromData) {
		NSLog(@"Couldn't make string out of data for note %@ with format %d", titleString, currentFormatID);
		return NO;
    }
    
	[contentString release];
	contentString = [attributedStringFromData retain];
	[contentString santizeForeignStylesForImporting];
	//NSLog(@"%s(%@): %@", _cmd, [self noteFilePath], [contentString string]);
	
	//[contentString setAttributedString:attributedStringFromData];
	contentCacheNeedsUpdate = YES;
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];
	
	[self updateTablePreviewString];
    
	//don't update the date modified here, as this could be old data
    
    [attributedStringFromData release];
    
    return YES;
}

- (void)updateWithSyncBody:(NSString*)newBody andTitle:(NSString*)newTitle {
	
	NSMutableAttributedString *attributedBodyString = [[NSMutableAttributedString alloc] initWithString:newBody attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	[attributedBodyString addLinkAttributesForRange:NSMakeRange(0, [attributedBodyString length])];
	[attributedBodyString addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [attributedBodyString length])];
	
	//should eventually sync changes back to disk:
	[self setContentString:[attributedBodyString autorelease]];

	//actions that user-editing via AppDelegate would have handled for us:
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];

	[self setTitleString:newTitle];
}

- (void)moveFileToTrash {
	OSStatus err = noErr;
	if ((err = [delegate moveFileToTrash:noteFileRefInit(self) forFilename:filename]) != noErr) {
		NSLog(@"Couldn't move file to trash: %d", err);
	} else {
		//file's gone! don't assume it's not coming back. if the storage format was not single-db, this note better be removed
		//currentFormatID = SingleDatabaseFormat;
	}
}

- (void)removeFileFromDirectory {
#if PERMADELETE
	OSStatus err = noErr;
	if ((err = [delegate deleteFileInNotesDirectory:noteFileRefInit(self) forFilename:filename]) != noErr) {
		
		if (err != fnfErr) {
			//what happens if we wanted to undo the deletion? moveFileToTrash will now tell the note that it shouldn't look for the file
			//so it would not be rewritten on re-creation?
			NSLog(@"Unable to delete file %@ (%d); moving to trash instead", filename, err);
			[self moveFileToTrash];
		}
	}
#else
	[self moveFileToTrash];
#endif
}

- (BOOL)removeUsingJournal:(WALStorageController*)wal {
    return [wal writeRemovalForNote:self];
}

- (void)registerModificationWithOwnedServices {
	//mirror this note's current mod date to services with which it is already synced
	//there is no point calling this method unless the modification time is 
	[[SyncSessionController allServiceClasses] makeObjectsPerformSelector:@selector(registerLocalModificationForNote:) withObject:self];
}

- (void)removeAllSyncServiceMD {
	//potentially dangerous
	[syncServicesMD removeAllObjects];
}


- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile {
	
	if (updateFile)
		shouldWriteToFile = YES;
	//else we don't turn file updating off--we might be overwriting the state of a previous note-dirty message
	
	if (updateTime) {
		[self setDateModified:CFAbsoluteTimeGetCurrent()];
		
		if ([delegate currentNoteStorageFormat] == SingleDatabaseFormat) {
			//only set if we're not currently synchronizing to avoid re-reading old data
			//this will be updated again when writing to a file, but for now we have the newest version
			//we must do this to allow new notes to be written when switching formats, and for encodingmanager checks
			if (UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &fileModifiedDate) != noErr)
				NSLog(@"Unable to set file modification date from current date");
		}
	}
	if (updateFile && updateTime) {
		//if this is a change that affects the actual content of a note such that we would need to updateFile
		//and the modification time was actually updated, then dirty the note with the sync services, too
		[self registerModificationWithOwnedServices];
		[delegate schedulePushToAllSyncServicesForNote:self];
	}
	
	//queue note to be written
    [delegate scheduleWriteForNote:self];	
	
	//tell delegate that the date modified changed
	//[delegate note:self attributeChanged:NoteDateModifiedColumnString];
	//except we don't want this here, as it will cause unnecessary (potential) re-sorting and updating of list view while typing
	//so expect the delegate to know to schedule the same update itself
}

- (OSStatus)exportToDirectoryRef:(FSRef*)directoryRef withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite {
	
	NSData *formattedData = nil;
	NSError *error = nil;
	
	switch (storageFormat) {
		case SingleDatabaseFormat:
			NSAssert(NO, @"Warning! Tried to export data in single-db format!?");
		case PlainTextFormat:
			if (!(formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:NO])) {
				[self _setFileEncoding:NSUTF8StringEncoding];
				NSLog(@"promoting to unicode (UTF-8) on export--probably because internal format is singledb");
				formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:YES];
			}
			break;
		case RTFTextFormat:
			formattedData = [contentString RTFFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			break;
		case HTMLFormat:
			formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			break;
		case WordDocFormat:
			formattedData = [contentString docFormatFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			break;
		case WordXMLFormat:
			formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSWordMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			break;
		default:
			NSLog(@"Attempted to export using unknown format ID: %d", storageFormat);
    }
	if (!formattedData)
		return kDataFormattingErr;
	
	//can use our already-determined filename to write here
	//but what about file names that were the same except for their extension? e.g., .txt vs. .text
	//this will give them the same extension and cause an overwrite
	NSString *newextension = [NotationPrefs pathExtensionForFormat:storageFormat];
	NSString *newfilename = userFilename ? userFilename : [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:newextension];
	//one last replacing, though if the unique file-naming method worked this should be unnecessary
	newfilename = [newfilename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
	
	BOOL fileWasCreated = NO;
	
	FSRef fileRef;
	OSStatus err = FSCreateFileIfNotPresentInDirectory(directoryRef, &fileRef, (CFStringRef)newfilename, (Boolean*)&fileWasCreated);
	if (err != noErr) {
		NSLog(@"FSCreateFileIfNotPresentInDirectory: %d", err);
		return err;
	}
	if (!fileWasCreated && !overwrite) {
		NSLog(@"File already existed!");
		return dupFNErr;
	}
	//yes, the file is probably not on the same volume as our notes directory
	if ((err = FSRefWriteData(&fileRef, BlockSizeForNotation(delegate), [formattedData length], [formattedData bytes], 0, true)) != noErr) {
		NSLog(@"error writing to temporary file: %d", err);
		return err;
    }
	if (PlainTextFormat == storageFormat) {
		(void)[self writeCurrentFileEncodingToFSRef:&fileRef];
	}
	NSFileManager *fileMan = [NSFileManager defaultManager];
	[fileMan setOpenMetaTags:[self orderedLabelTitles] atFSPath:[[fileMan pathWithFSRef:&fileRef] fileSystemRepresentation]];
	
	//also export the note's modification and creation dates
	FSCatalogInfo catInfo;
	UCConvertCFAbsoluteTimeToUTCDateTime(createdDate, &catInfo.createDate);
	UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &catInfo.contentModDate);
	FSSetCatalogInfo(&fileRef, kFSCatInfoCreateDate | kFSCatInfoContentMod, &catInfo);
			
	return noErr;
}

- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange {
	//opts indicate forwards or backwards, inRange allows us to continue from where we left off
	//return location of NSNotFound and length 0 if none of the words could be found inRange
	
	//an optimization would be to fall back on cached cString if contentsWere7Bit is true, but then we have to handle opts ourselves
	unsigned int i;
	NSString *haystack = [contentString string];
	NSRange nextRange = NSMakeRange(NSNotFound, 0);
	for (i=0; i<[words count]; i++) {
		NSString *word = [words objectAtIndex:i];
		if ([word length] > 0) {
			nextRange = [haystack rangeOfString:word options:opts range:inRange];
			if (nextRange.location != NSNotFound && nextRange.length)
				break;
		}
	}

	return nextRange;
}

force_inline void resetFoundPtrsForNote(NoteObject *note) {
	note->cTitleFoundPtr = note->cTitle;
	note->cContentsFoundPtr = note->cContents;
	note->cLabelsFoundPtr = note->cLabels;	
}

BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context) {
	
    if (!context->useCachedPositions) {
		resetFoundPtrsForNote(note);
    }
	
	char *needle = context->needle;
    
	/* NOTE: strstr in Darwin is heinously, supernaturally optimized; it blows boyer-moore out of the water. 
	implementations on other OSes will need considerably more code in this function. */
	
    if (note->cTitleFoundPtr)
		note->cTitleFoundPtr = strstr(note->cTitleFoundPtr, needle);
    
    if (note->cContentsFoundPtr)
		note->cContentsFoundPtr = strstr(note->cContentsFoundPtr, needle);
    
    if (note->cLabelsFoundPtr)
		note->cLabelsFoundPtr = strstr(note->cLabelsFoundPtr, needle);
        
    return note->cContentsFoundPtr || note->cTitleFoundPtr || note->cLabelsFoundPtr;
}

BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen) {
	return !strncmp(note->cTitle, fullString, stringLen);
}
BOOL noteTitleIsAPrefixOfOtherNoteTitle(NoteObject *longerNote, NoteObject *shorterNote) {
	return !strncmp(longerNote->cTitle, shorterNote->cTitle, strlen(shorterNote->cTitle));
}

- (void)addPrefixParentNote:(NoteObject*)aNote {
	if (!prefixParentNotes) {
		prefixParentNotes = [[NSMutableArray alloc] init];
	}
	[prefixParentNotes addObject:aNote];
}
- (void)removeAllPrefixParentNotes {
	[prefixParentNotes removeAllObjects];
}

- (NSSet*)labelSet {
    return labelSet;
}
/*
- (CFArrayRef)rangesForWords:(NSString*)string inRange:(NSRange)rangeLimit {
	//use cstring caches if note is all 7-bit, as we [REALLY OUGHT TO] be able to assume a 1-to-1 character mapping
	
	if (contentsWere7Bit) {
		char *manglingString = strdup([string UTF8String]);
		char *token, *separators = separatorsForCString(manglingString);
		
		while ((token = strsep(&manglingString, separators))) {
			if (*token != '\0') {
				//find all occurrences of token in cContents and add cfranges to cfmutablearray
			}
		}
	}
}*/

- (NSUndoManager*)undoManager {
    if (!undoManager) {
	undoManager = [[NSUndoManager alloc] init];
	
	id center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidUndoChangeNotification
		     object:undoManager];
	
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidRedoChangeNotification
		     object:undoManager];
    }
    
    return undoManager;
}

- (void)_undoManagerDidChange:(NSNotification *)notification {
	[self makeNoteDirtyUpdateTime:YES updateFile:YES];
    //queue note to be synchronized to disk (and network if necessary)
}



@end
