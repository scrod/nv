//
//  NoteObject.m
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
#import "ExternalEditorListController.h"
#import "NSData_transformations.h"
#import "NSCollection_utils.h"
#import "NotesTableView.h"
#import "UnifiedCell.h"
#import "LabelColumnCell.h"
#import "ODBEditor.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

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

static void setAttrModifiedDate(NoteObject *note, UTCDateTime *dateTime);
static void setCatalogNodeID(NoteObject *note, UInt32 cnid);

static CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec value) {
	return (CFAbsoluteTime)value.tv_sec + ((CFAbsoluteTime)value.tv_nsec / NSEC_PER_SEC) - kCFAbsoluteTimeIntervalSince1970;
}

static UTCDateTime NVUTCDateTimeFromTimespec(struct timespec value) {
	UTCDateTime date = { 0 };
	UCConvertCFAbsoluteTimeToUTCDateTime(NVAbsoluteTimeFromTimespec(value), &date);
	return date;
}

- (id)init {
    self = [super init];
    if (self) {
	
		perDiskInfoGroups = calloc(1, sizeof(PerDiskInfo));
		perDiskInfoGroups[0].diskIDIndex = -1;
		perDiskInfoGroupCount = 1;
		
		currentFormatID = SingleDatabaseFormat;
		fileEncoding = NSUTF8StringEncoding;
		selectedRange = NSMakeRange(NSNotFound, 0);
		
		//other instance variables initialized on demand
    }
	
    return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[tableTitleString release];
	[titleString release];
	[labelString release];
	[labelSet release];
	[undoManager release];
	[filename release];
	[dateModifiedString release];
	[dateCreatedString release];
	[prefixParentNotes release];
	
	if (perDiskInfoGroups)
		free(perDiskInfoGroups);
		
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
		if (!labelSet && !didUnarchive) [self updateLabelConnectionsAfterDecoding];
	}
}

static void setAttrModifiedDate(NoteObject *note, UTCDateTime *dateTime) {
	unsigned int idx = SetPerDiskInfoWithTableIndex(dateTime, NULL, diskUUIDIndexForNotation(note->delegate), 
													&(note->perDiskInfoGroups), &(note->perDiskInfoGroupCount));
	note->attrsModifiedDate = &(note->perDiskInfoGroups[idx].attrTime);
}
static void setCatalogNodeID(NoteObject *note, UInt32 cnid) {
	SetPerDiskInfoWithTableIndex(NULL, &cnid, diskUUIDIndexForNotation(note->delegate), 
								 &(note->perDiskInfoGroups), &(note->perDiskInfoGroupCount));
	note->nodeID = cnid;
}

UTCDateTime *attrsModifiedDateOfNote(NoteObject *note) {
	//once unarchived, the disk UUID index won't change, so this pointer will always reflect the current attr mod time
	if (!note->attrsModifiedDate) {
		//init from delegate based on disk table index
		unsigned int i, tableIndex = diskUUIDIndexForNotation(note->delegate);
		
		for (i=0; i<note->perDiskInfoGroupCount; i++) {
			//check if this date has actually been initialized; this entry could be here only because setCatalogNodeID was called
			if (note->perDiskInfoGroups[i].diskIDIndex == tableIndex && !UTCDateTimeIsEmpty(note->perDiskInfoGroups[i].attrTime)) {
				note->attrsModifiedDate = &(note->perDiskInfoGroups[i].attrTime);
				goto giveDate;
			}
		}
		//this note doesn't have a file-modified date, so initialize a fairly reasonable one here
		setAttrModifiedDate(note, &(note->fileModifiedDate));
	}
giveDate:	
	return note->attrsModifiedDate;
}

UInt32 fileNodeIDOfNote(NoteObject *note) {
	if (!note->nodeID) {
		unsigned int i, tableIndex = diskUUIDIndexForNotation(note->delegate);
		
		for (i=0; i<note->perDiskInfoGroupCount; i++) {
			//check if this nodeID has actually been initialized; this entry could be here only because setAttrModifiedDate was called
			if (note->perDiskInfoGroups[i].diskIDIndex == tableIndex && note->perDiskInfoGroups[i].nodeID != 0U) {
				note->nodeID = note->perDiskInfoGroups[i].nodeID;
				goto giveID;
			}
		}
		//this note doesn't have a file-modified date, so initialize something that at least won't repeat this lookup
		setCatalogNodeID(note, 1);
	}
giveID:	
	return note->nodeID;
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
	//add kCFCompareNumerically to options for natural order sort
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
    return fileNodeIDOfNote(*(NoteObject**)a) - fileNodeIDOfNote(*(NoteObject**)b);
}
NSInteger compareFileSize(id *a, id *b) {
    return (*(NoteObject**)a)->logicalSize - (*(NoteObject**)b)->logicalSize;
}


#include "SynchronizedNoteMixIns.h"

//syncing w/ server and from journal;

DefModelAttrAccessor(filenameOfNote, filename)
DefModelAttrAccessor(fileSizeOfNote, logicalSize)
DefModelAttrAccessor(titleOfNote, titleString)
DefModelAttrAccessor(labelsOfNote, labelString)
DefModelAttrAccessor(fileModifiedDateOfNote, fileModifiedDate)
DefModelAttrAccessor(modifiedDateOfNote, modifiedDate)
DefModelAttrAccessor(createdDateOfNote, createdDate)
DefModelAttrAccessor(storageFormatOfNote, currentFormatID)
DefModelAttrAccessor(fileEncodingOfNote, fileEncoding)
DefModelAttrAccessor(prefixParentsOfNote, prefixParentNotes)

//DefColAttrAccessor(wordCountOfNote, wordCountString)
DefColAttrAccessor(titleOfNote2, titleString)
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
	
	LabelColumnCell *cell = [[tv tableColumnWithIdentifier:NoteLabelsColumnString] dataCellForRow:row];
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
//AppKit can drop highlight shadows when custom attributes are present, so add it explicitly.
	
	UnifiedCell *cell = [[[tv tableColumns] objectAtIndex:0] dataCellForRow:row];
	[cell setNoteObject:note];
	[cell setPreviewIsHidden:NO];

	BOOL rowSelected = [tv isRowSelected:row];
	BOOL drawShadow = YES;
	
	id obj = note->tableTitleString ? (rowSelected ? (id)AttributedStringForSelection(note->tableTitleString, drawShadow) : 
									   (id)note->tableTitleString) : (id)titleOfNote(note);
	
	
	return obj;
}

//make notationcontroller should send setDelegate: and setLabelString: (if necessary) to each note when unarchiving this way

//there is no measurable difference in speed when using decodeValuesOfObjCTypes, oddly enough
//the overhead of the _decodeObject* C functions must be significantly greater than the objc_msgSend and argument passing overhead
#define DECODE_INDIVIDUALLY 1

- (id)initWithCoder:(NSCoder*)decoder {
	self = [self init];
	if (self) {
		
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
			logicalSize = [decoder decodeInt32ForKey:VAR_STR(logicalSize)];
			
			int64_t fileModifiedDate64 = [decoder decodeInt64ForKey:VAR_STR(fileModifiedDate)];
			memcpy(&fileModifiedDate, &fileModifiedDate64, sizeof(int64_t));
						
			NSUInteger decodedPerDiskByteCount = 0;
			const uint8_t *decodedPerDiskBytes = [decoder decodeBytesForKey:VAR_STR(perDiskInfoGroups) returnedLength:&decodedPerDiskByteCount];
			if (decodedPerDiskBytes && decodedPerDiskByteCount) {
				CopyPerDiskInfoGroupsToOrder(&perDiskInfoGroups, &perDiskInfoGroupCount, (PerDiskInfo *)decodedPerDiskBytes, decodedPerDiskByteCount, 1);
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
		[coder encodeInt32:logicalSize forKey:VAR_STR(logicalSize)];

		uint8_t *flippedPerDiskInfoGroups = calloc(perDiskInfoGroupCount, sizeof(PerDiskInfo));
		CopyPerDiskInfoGroupsToOrder((PerDiskInfo**)&flippedPerDiskInfoGroups, &perDiskInfoGroupCount, perDiskInfoGroups, perDiskInfoGroupCount * sizeof(PerDiskInfo), 0);
		
		[coder encodeBytes:flippedPerDiskInfoGroups length:perDiskInfoGroupCount * sizeof(PerDiskInfo) forKey:VAR_STR(perDiskInfoGroups)];
		free(flippedPerDiskInfoGroups);
		
		[coder encodeInt64:*(int64_t*)&fileModifiedDate forKey:VAR_STR(fileModifiedDate)];
			[coder encodeInt32:(int32_t)fileEncoding forKey:VAR_STR(fileEncoding)];
		
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

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle delegate:(id)aDelegate format:(int)formatID labels:(NSString*)aLabelString {
	//delegate optional here
    self = [self init];
    if (self) {
		
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
		
		if (![self _setLabelString:aLabelString]) {
			labelString = @"";
			cLabelsFoundPtr = cLabels = strdup("");
		}
		
		currentFormatID = formatID;
		filename = [[delegate uniqueFilenameForTitle:titleString fromNote:nil] retain];
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent();
		dateCreatedString = [dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain] retain];
		UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &fileModifiedDate);
		
		if (delegate)
			[self updateTablePreviewString];
    }
    
    return self;
}

//only get the fsrefs until we absolutely need them

- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry delegate:(id)aDelegate {
	NSAssert(aDelegate != nil, @"must supply a delegate");
    self = [self init];
    if (self) {
		delegate = aDelegate;
		filename = [(NSString*)entry->filename copy];
		currentFormatID = [delegate currentNoteStorageFormat];
		fileModifiedDate = entry->lastModified;
		setAttrModifiedDate(self, &(entry->lastAttrModified));
		setCatalogNodeID(self, entry->nodeID);
		logicalSize = entry->logicalSize;
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		if (![self _setTitleString:[filename stringByDeletingPathExtension]])
			titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		labelString = @""; //set by updateFromCatalogEntry if there are openmeta extended attributes 
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
		
			size_t len = strlen(cContents);
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
			//is called for visible notes at launch and resize only, generation of images for invisible notes is delayed until after launch
			
			NSSize labelBlockSize = ColumnIsSet(NoteLabelsColumn, [prefs tableColumnsBitmap]) ? [self sizeOfLabelBlocks] : NSZeroSize;
			tableTitleString = [[titleString attributedMultiLinePreviewFromBodyText:contentString upToWidth:[delegate titleColumnWidth] 
																	 intrusionWidth:labelBlockSize.width] retain];
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
			![delegate noteExistsWithName:filename]) {
			
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
			NSError *renameError = nil;
			if (oldName && [delegate noteExistsWithName:oldName] &&
				![delegate renameNoteFromName:oldName toName:filename error:&renameError]) {
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

- (void)setForegroundTextColorOnly:(NSColor*)aColor {
	//called when notationPrefs font doesn't match globalprefs font, or user changes the font
	[contentString removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentString length])];
	if (aColor) {
		[contentString addAttribute:NSForegroundColorAttributeName value:aColor range:NSMakeRange(0, [contentString length])];
	}
}

- (void)_resanitizeContent {
	[contentString santizeForeignStylesForImporting];
	
	//renormalize the title, in case it is still somehow derived from decomposed HFS+ filenames
	CFMutableStringRef normalizedString = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)titleString);
	CFStringNormalize(normalizedString, kCFStringNormalizationFormC);
	
	[self _setTitleString:(NSString*)normalizedString];
	CFRelease(normalizedString);
	
	if ([delegate currentNoteStorageFormat] == RTFTextFormat)
		[self makeNoteDirtyUpdateTime:NO updateFile:YES];
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
	//find differences between previous labels and new ones	
	if (delegate) {
		NSMutableSet *oldLabelSet = labelSet;
		NSMutableSet *newLabelSet = [self labelSetFromCurrentString];
		
		if (!oldLabelSet) {
			oldLabelSet = labelSet = [[NSMutableSet alloc] initWithCapacity:[newLabelSet count]];
		}
		
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
}

- (void)disconnectLabels {
	//when removing this note from NotationController, other LabelObjects as well as LabelsListController should know not to list it
	if (delegate) {
		[delegate note:self didRemoveLabelSet:labelSet];
		[labelSet autorelease];
		labelSet = nil;
	} else {
		NSLog(@"not disconnecting labels because no delegate exists");
	}
}

- (BOOL)_setLabelString:(NSString*)newLabelString {
	if (newLabelString && ![newLabelString isEqualToString:labelString]) {
		
		[labelString release];
		labelString = [newLabelString copy];
		
		cLabelsFoundPtr = cLabels = replaceString(cLabels, [labelString lowercaseUTF8String]);
		
		[self updateLabelConnections];
		return YES;
	}
	return NO;
}

- (void)setLabelString:(NSString*)newLabelString {
	
	if ([self _setLabelString:newLabelString]) {
	
		if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
			[self updateTablePreviewString];
		}
		
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		//[self registerModificationWithOwnedServices];
		
		[delegate note:self attributeChanged:NoteLabelsColumnString];
	}
}

- (NSMutableSet*)labelSetFromCurrentString {
	
	NSArray *words = [self orderedLabelTitles];
	NSMutableSet *newLabelSet = [NSMutableSet setWithCapacity:[words count]];
	
	unsigned int i;
	for (i=0; i<[words count]; i++) {
		NSString *aWord = [words objectAtIndex:i];
		
		if ([aWord length] > 0) {
			LabelObject *aLabel = [[LabelObject alloc] initWithTitle:aWord];
			[aLabel addNote:self];
			
			[newLabelSet addObject:aLabel];
			[aLabel autorelease];
		}
	}
	
	return newLabelSet; 
}


- (NSArray*)orderedLabelTitles {
	return [labelString labelCompatibleWords];
}

- (NSSize)sizeOfLabelBlocks {
	NSSize size = NSZeroSize;
	[self _drawLabelBlocksInRect:NSZeroRect rightAlign:NO highlighted:NO getSizeOnly:&size];
	return size;
}

- (void)drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted {
	return [self _drawLabelBlocksInRect:aRect rightAlign:onRight highlighted:isHighlighted getSizeOnly:NULL];
}

- (void)_drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted getSizeOnly:(NSSize*)reqSize {
	//used primarily by UnifiedCell, but also by LabelColumnCell, as well as to determine the width of all label-block-images for this note
	//iterate over words in orderedLabelTitles, retrieving images via -[LabelsListController cachedLabelImageForWord:highlighted:]
	//if right-align is enabled, then the label-images are queued on the first pass and drawn in reverse on the second
	
	float totalWidth = 0.0, height = 0.0;
	
	if (![labelString length]) goto returnSizeIfNecessary;
	
	NSArray *words = [self orderedLabelTitles];
	if (![words count]) goto returnSizeIfNecessary;
	
	NSPoint nextBoxPoint = onRight ? NSMakePoint(NSMaxX(aRect), aRect.origin.y) : aRect.origin;
	NSView *focusView = [NSView focusView];
	BOOL focusIsFlipped = focusView ? [focusView isFlipped] : NO;
	NSMutableArray *images = reqSize || !onRight ? nil : [NSMutableArray arrayWithCapacity:[words count]];
	NSInteger i;

	for (i=0; i<(NSInteger)[words count]; i++) {
		NSString *word = [words objectAtIndex:i];
		if ([word length]) {
			NSImage *img = [[delegate labelsListDataSource] cachedLabelImageForWord:word highlighted:isHighlighted];
			
				if (!reqSize) {
					if (onRight) {
						[images addObject:img];
					} else {
						NSRect drawRect = NSMakeRect(nextBoxPoint.x, nextBoxPoint.y, [img size].width, [img size].height);
						if (focusIsFlipped) {
							drawRect.origin.y -= [img size].height;
						}
						[img drawInRect:drawRect
							fromRect:NSZeroRect
							operation:NSCompositingOperationSourceOver
							fraction:1.0
							respectFlipped:YES
							hints:nil];
						nextBoxPoint.x += [img size].width + 4.0;
					}
			} else {
				totalWidth += [img size].width + 4.0;
				height = MAX(height, [img size].height);
			}
		}
	}
	
		if (!reqSize) {
			if (onRight) {
				//draw images in reverse instead
				for (i = [images count] - 1; i>=0; i--) {
					NSImage *img = [images objectAtIndex:i];
					nextBoxPoint.x -= [img size].width + 4.0;
					NSRect drawRect = NSMakeRect(nextBoxPoint.x, nextBoxPoint.y, [img size].width, [img size].height);
					if (focusIsFlipped) {
						drawRect.origin.y -= [img size].height;
					}
					[img drawInRect:drawRect
						fromRect:NSZeroRect
						operation:NSCompositingOperationSourceOver
						fraction:1.0
						respectFlipped:YES
						hints:nil];
				}
		}
	} else {
	returnSizeIfNecessary:
		if (reqSize) *reqSize = NSMakeSize(totalWidth, height);
	}
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
	[idsDict setObject:[[NSData dataWithBytes:&uniqueNoteIDBytes length:16] encodeBase64WithoutNewlines] forKey:@"NV"];
	
	return [NSURL URLWithString:[@"nv://find/" stringByAppendingFormat:@"%@/?%@", [titleString stringWithPercentEscapes], 
								 [idsDict URLEncodedString]]];
}

- (NSURL*)noteFileURL {
	return [delegate fileReferenceURLForNoteNamed:filename error:NULL];
}

- (BOOL)writeUsingCurrentFileFormatIfNecessary {
	//if note had been updated via makeNoteDirty and needed file to be rewritten
	if (shouldWriteToFile) {
		return [self writeUsingCurrentFileFormat];
	}
	return NO;
}

- (BOOL)writeUsingCurrentFileFormatIfNonExistingOrChanged {
	if (![delegate noteExistsWithName:filename]) {
		NSLog(@"writing note %@, because it didn't exist", titleString);
		return [self writeUsingCurrentFileFormat];
	}

	NVFileInfo info;
	if (![delegate getFileInfo:&info forNoteNamed:filename error:NULL])
		return NO;

	CFAbsoluteTime lastTime;
	OSStatus err = UCConvertUTCDateTimeToCFAbsoluteTime(&fileModifiedDate, &lastTime);
	if (err == noErr) {
		CFAbsoluteTime timeOnDisk = (CFAbsoluteTime)info.modificationTime.tv_sec - kCFAbsoluteTimeIntervalSince1970 +
			(CFAbsoluteTime)info.modificationTime.tv_nsec / NSEC_PER_SEC;
		
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
	NSMutableAttributedString *contentMinusColor = nil;
	
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
			contentMinusColor = [contentString mutableCopy];
			[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];
			formattedData = [contentMinusColor RTFFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:@{}];
			[contentMinusColor release];
			
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
		
		NSError *writeError = nil;
		if (![delegate storeDataAtomicallyInNotesDirectory:formattedData withName:filename
			verificationBlock:NULL error:&writeError]) {
			NSLog(@"Unable to save note file %@", filename);
			
			[delegate noteDidNotWrite:self errorCode:ioErr];
			return NO;
		}
		//if writing plaintext set the file encoding with setxattr
		if (PlainTextFormat == formatID) {
			(void)[self writeCurrentFileEncoding];
		}
		[delegate setOpenMetaTags:[self orderedLabelTitles] forNoteNamed:filename error:NULL];
		
		//always hide the file extension for all types
		[delegate setExtensionHiddenForNoteNamed:filename error:NULL];
		
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

	NSError *error = nil;
	if (![delegate setCreationTime:createdDate modificationTime:modifiedDate forNoteNamed:filename error:&error]) {
		NSLog(@"Could not set dates for %@: %@", filename, error);
		return ioErr;
	}
	NVFileInfo info;
	if (![delegate getFileInfo:&info forNoteNamed:filename error:&error]) {
		NSLog(@"Unable to inspect newly written file %@: %@", filename, error);
		return ioErr;
	}
	fileModifiedDate = NVUTCDateTimeFromTimespec(info.modificationTime);
	UTCDateTime attributeModifiedDate = NVUTCDateTimeFromTimespec(info.attributeModificationTime);
	setAttrModifiedDate(self, &attributeModifiedDate);
	setCatalogNodeID(self, (UInt32)(info.fileID & 0xFFFFFFFF));
	logicalSize = (UInt32)(info.logicalSize & 0xFFFFFFFF);
	
	return noErr;
}

- (BOOL)writeCurrentFileEncoding {
	return [delegate setTextEncoding:fileEncoding forNoteNamed:filename error:NULL];
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
					NSLog(@"%@: can't set file modification date from current date", NSStringFromSelector(_cmd));
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
		
		if (![delegate noteExistsWithName:filename] || ![self writeCurrentFileEncoding])
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
	NSError *error = nil;
	NSData *data = [delegate dataFromNoteNamed:filename error:&error];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk: %@", error);
		return NO;
    }
	
	NSStringEncoding diskEncoding = [delegate textEncodingForNoteNamed:filename];
	if (diskEncoding) fileEncoding = diskEncoding;

	    if ([self updateFromData:data inFormat:currentFormatID]) {
		NVFileInfo info;
		if ([delegate getFileInfo:&info forNoteNamed:filename error:&error]) {
			fileModifiedDate = NVUTCDateTimeFromTimespec(info.modificationTime);
			UTCDateTime attributeModifiedDate = NVUTCDateTimeFromTimespec(info.attributeModificationTime);
			setAttrModifiedDate(self, &attributeModifiedDate);
			setCatalogNodeID(self, (UInt32)(info.fileID & 0xFFFFFFFF));
			logicalSize = (UInt32)(info.logicalSize & 0xFFFFFFFF);
			
			return YES;
		}
    }
    return NO;
}

- (BOOL)updateFromCatalogEntry:(NoteCatalogEntry*)catEntry {
	BOOL didRestoreLabels = NO;
	
	NSData *data = [delegate dataFromNoteNamed:(NSString*)catEntry->filename error:NULL];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk given catalog entry");
		return NO;
    }
	    
	NSStringEncoding diskEncoding = [delegate textEncodingForNoteNamed:(NSString*)catEntry->filename];
	if (diskEncoding) fileEncoding = diskEncoding;
	    if (![self updateFromData:data inFormat:currentFormatID])
		return NO;
	
	[self setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
    
    fileModifiedDate = catEntry->lastModified;
	setAttrModifiedDate(self, &(catEntry->lastAttrModified));
    setCatalogNodeID(self, catEntry->nodeID);
	logicalSize = catEntry->logicalSize;
	
	NSArray *openMetaTags = [delegate openMetaTagsForNoteNamed:filename];
		if (openMetaTags) {
			//overwrite this note's labels with those from the file; merging may be the wrong thing to do here
			if ([self _setLabelString:[openMetaTags componentsJoinedByString:@" "]])
				[self updateTablePreviewString];
		} else if ([labelString length]) {
			//this file has either never had tags or has had them cleared by accident (e.g., non-user intervention)
			//so if this note still has tags, then restore them now.
			
			NSLog(@"restoring lost tags for %@", titleString);
			[delegate setOpenMetaTags:[self orderedLabelTitles] forNoteNamed:filename error:NULL];
			didRestoreLabels = YES;
		}
	
	OSStatus err = noErr;
	CFAbsoluteTime aModDate;
	if (noErr == (err = UCConvertUTCDateTimeToCFAbsoluteTime(&fileModifiedDate, &aModDate))) {
		[self setDateModified:aModDate];
	}
	
	if (createdDate == 0.0 || didRestoreLabels) {
		//when reading files from disk for the first time, grab their creation date
		//or if this file has just been altered, grab its newly-changed modification dates
		
		NVFileInfo info;
		if ([delegate getFileInfo:&info forNoteNamed:filename error:NULL]) {
			if (createdDate == 0.0) [self setDateAdded:NVAbsoluteTimeFromTimespec(info.creationTime)];
			if (didRestoreLabels) {
				fileModifiedDate = NVUTCDateTimeFromTimespec(info.modificationTime);
				UTCDateTime attributeModifiedDate = NVUTCDateTimeFromTimespec(info.attributeModificationTime);
				setAttrModifiedDate(self, &attributeModifiedDate);
			}
		}
	}
	
    return YES;
}

- (BOOL)updateFromData:(NSData*)data inFormat:(int)fmt {
    
    if (!data) {
		NSLog(@"%@: Data is nil!", NSStringFromSelector(_cmd));
		return NO;
    }
    
    NSMutableString *stringFromData = nil;
    NSMutableAttributedString *attributedStringFromData = nil;
    //interpret based on format; text, rtf, html, etc...
    switch (fmt) {
	case SingleDatabaseFormat:
	    //hmmmmm
		NSAssert(NO, @"Warning! Tried to update data from a note in single-db format!");
	    
	    break;
	case PlainTextFormat:
		//try to merge/re-match attributes?
	    if ((stringFromData = [NSMutableString newShortLivedStringFromData:data ofGuessedEncoding:&fileEncoding])) {
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
	    NSLog(@"%@: Unknown format: %d", NSStringFromSelector(_cmd), fmt);
    }
    
    if (!attributedStringFromData) {
		NSLog(@"Couldn't make string out of data for note %@ with format %d", titleString, fmt);
		return NO;
    }
    
	[contentString release];
	contentString = [attributedStringFromData retain];
	[contentString santizeForeignStylesForImporting];
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
	[attributedBodyString addAttributesForMarkdownHeadingLinesInRange:NSMakeRange(0, [attributedBodyString length])];
	
	//should eventually sync changes back to disk:
	[self setContentString:[attributedBodyString autorelease]];

	//actions that user-editing via AppDelegate would have handled for us:
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];

	[self setTitleString:newTitle];
}

- (void)moveFileToTrash {
	NSError *error = nil;
	if (![delegate moveNoteToTrashNamed:filename resultingURL:NULL error:&error]) {
		NSLog(@"Couldn't move file to trash: %@", error);
	} else {
		//file's gone! don't assume it's not coming back. if the storage format was not single-db, this note better be removed
		//currentFormatID = SingleDatabaseFormat;
	}
}

- (void)removeFileFromDirectory {
#if PERMADELETE
	NSError *error = nil;
	if (![delegate deleteNoteNamed:filename error:&error]) {
		if ([error code] != ENOENT) {
			//what happens if we wanted to undo the deletion? moveFileToTrash will now tell the note that it shouldn't look for the file
			//so it would not be rewritten on re-creation?
			NSLog(@"Unable to delete file %@ (%@); moving to trash instead", filename, error);
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

- (OSStatus)exportToDirectoryURL:(NSURL*)directoryURL withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite {
	
	NSData *formattedData = nil;
	NSError *error = nil;
	
	NSMutableAttributedString *contentMinusColor = [[contentString mutableCopy] autorelease];
	[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];

	
	switch (storageFormat) {
		case SingleDatabaseFormat:
			NSAssert(NO, @"Warning! Tried to export data in single-db format!?");
		case PlainTextFormat:
			if (!(formattedData = [[contentMinusColor string] dataUsingEncoding:fileEncoding allowLossyConversion:NO])) {
				[self _setFileEncoding:NSUTF8StringEncoding];
				NSLog(@"promoting to unicode (UTF-8) on export--probably because internal format is singledb");
				formattedData = [[contentMinusColor string] dataUsingEncoding:fileEncoding allowLossyConversion:YES];
			}
			break;
		case RTFTextFormat:
			formattedData = [contentMinusColor RTFFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:@{}];
			break;
		case HTMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			break;
		case WordDocFormat:
			formattedData = [contentMinusColor docFormatFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:@{}];
			break;
		case WordXMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length]) 
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
	
	if (![directoryURL isFileReferenceURL] || ![newfilename length] ||
		[newfilename rangeOfString:@"/"].location != NSNotFound) return paramErr;
	NSUInteger nameSize = [newfilename maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
	char *destinationName = malloc(nameSize);
	if (!destinationName || ![newfilename getFileSystemRepresentation:destinationName maxLength:nameSize]) {
		free(destinationName);
		return bdNamErr;
	}
	int directoryFD = [[NSFileManager defaultManager]
		openFileDescriptorForDirectoryReferenceURL:directoryURL error:&error];
	if (directoryFD < 0) {
		free(destinationName);
		return ioErr;
	}
	struct stat existingInfo;
	if (!overwrite && fstatat(directoryFD, destinationName, &existingInfo, AT_SYMLINK_NOFOLLOW) == 0) {
		close(directoryFD);
		free(destinationName);
		return dupFNErr;
	}
	NSString *temporaryFilename = [@".nv-export-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	const char *temporaryName = [temporaryFilename fileSystemRepresentation];
	int fileFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fileFD < 0) {
		close(directoryFD);
		free(destinationName);
		return ioErr;
	}
	const uint8_t *bytes = [formattedData bytes];
	size_t remaining = [formattedData length];
	BOOL wroteData = YES;
	while (remaining) {
		ssize_t amount = write(fileFD, bytes, remaining);
		if (amount < 0 && errno == EINTR) continue;
		if (amount <= 0) { wroteData = NO; break; }
		bytes += amount;
		remaining -= (size_t)amount;
	}
	if (wroteData && PlainTextFormat == storageFormat) {
		CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(fileEncoding);
		NSString *encodingName = (NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding);
		NSString *encodingValue = [encodingName stringByAppendingFormat:@";%u", (unsigned int)cfEncoding];
		const char *encodingBytes = [encodingValue UTF8String];
		(void)fsetxattr(fileFD, "com.apple.TextEncoding", encodingBytes, strlen(encodingBytes), 0, 0);
	}
	NSData *tagData = [NSPropertyListSerialization dataWithPropertyList:[self orderedLabelTitles]
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
	if (wroteData && tagData)
		(void)fsetxattr(fileFD, "com.apple.metadata:kMDItemOMUserTags", [tagData bytes], [tagData length], 0, 0);
	if (wroteData) wroteData = fsync(fileFD) == 0;
	close(fileFD);

	struct attrlist dateAttributes;
	bzero(&dateAttributes, sizeof(dateAttributes));
	dateAttributes.bitmapcount = ATTR_BIT_MAP_COUNT;
	dateAttributes.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
	struct timespec dates[2];
	dates[0].tv_sec = (time_t)floor(createdDate + kCFAbsoluteTimeIntervalSince1970);
	dates[0].tv_nsec = 0;
	dates[1].tv_sec = (time_t)floor(modifiedDate + kCFAbsoluteTimeIntervalSince1970);
	dates[1].tv_nsec = 0;
	if (wroteData) (void)setattrlistat(directoryFD, temporaryName, &dateAttributes, dates, sizeof(dates), 0);

	BOOL installed = NO;
	if (wroteData && overwrite)
		installed = renameat(directoryFD, temporaryName, directoryFD, destinationName) == 0;
	else if (wroteData) {
		installed = renameatx_np(directoryFD, temporaryName, directoryFD, destinationName, RENAME_EXCL) == 0;
		if (!installed && (errno == ENOTSUP || errno == EINVAL) &&
			linkat(directoryFD, temporaryName, directoryFD, destinationName, 0) == 0) {
			installed = unlinkat(directoryFD, temporaryName, 0) == 0;
		}
	}
	int installError = errno;
	if (!installed) (void)unlinkat(directoryFD, temporaryName, 0);
	if (installed) (void)fsync(directoryFD);
	close(directoryFD);
	free(destinationName);
	if (!installed && !overwrite && installError == EEXIST) return dupFNErr;
	return installed ? noErr : ioErr;
}

- (void)editExternallyUsingEditor:(ExternalEditor*)ed {
	[[ODBEditor sharedODBEditor] editNote:self inEditor:ed context:nil];
}

- (void)abortEditingInExternalEditor {
	[[ODBEditor sharedODBEditor] abortAllEditingSessionsForClient:self];
}

-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath  context:(NSDictionary *)context {

	//read path/newPath into NSData and update note contents
	
	//can't use updateFromCatalogEntry because it would assign ownership via various metadata
	
	if ([self updateFromData:[NSMutableData dataWithContentsOfFile:path options:NSUncachedRead error:NULL] inFormat:PlainTextFormat]) {
		//reflect the temp file's changes directly back to the backing-store-file, database, and sync services
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		[delegate note:self attributeChanged:NotePreviewString];
		[[delegate delegate] contentsUpdatedForNote:self];
	} else {
		NSBeep();
		NSLog(@"odbEditor:didModifyFile: unable to get data from %@", path);
	}	
}
-(void)odbEditor:(ODBEditor *)editor didClosefile:(NSString *)path context:(NSDictionary *)context {
	//remove the temp file	
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
#else
	[[NSFileManager defaultManager] removeFileAtPath:path handler:nil];
#endif
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
		prefixParentNotes = [[NSMutableArray alloc] initWithObjects:&aNote count:1];
	} else {
		[prefixParentNotes addObject:aNote];
	}
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
