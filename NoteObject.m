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
#import "NVRootedDirectory_Private.h"
#import "NotationPrefs.h"
#import "AttributedPlainText.h"
#import "NSString_CustomTruncation.h"
#import "NSFileManager_NV.h"
#include "BufferUtils.h"
#import "NotationSyncServiceManager.h"
#import "SyncServiceSessionProtocol.h"
#import "SyncSessionController.h"
#import "ExternalEditorListController.h"
#import "NSData_transformations.h"
#import "NSCollection_utils.h"
#import "NotesTableView.h"
#import "UnifiedCell.h"
#import "LabelColumnCell.h"
#import "ExternalEditingSession.h"
#import "NotationDirectoryManager.h"
#import "DiffMatchPatch/DiffMatchPatch.h"
#include <errno.h>
#include <sys/stat.h>
#include <sys/xattr.h>

NSString *NVNoteStorageErrorDomain = @"NVNoteStorageErrorDomain";

NSString *NVMergedText(NSString *base, NSString *local, NSString *external) {
	if (!base || !local || !external) return nil;
	if ([local isEqualToString:external]) return local;
	if ([local isEqualToString:base]) return external;
	if ([external isEqualToString:base]) return local;

	DiffMatchPatch *dmp = [[DiffMatchPatch alloc] init];
	NSArray *result = [dmp patch_apply:[dmp patch_makeFromOldString:base andNewString:external]
		toString:local];
	[dmp release];
	if ([result count] != 2) return nil;
	for (NSNumber *applied in [result objectAtIndex:1])
		if (![applied boolValue]) return nil;
	return [result objectAtIndex:0];
}

// Needed for compatability with data created by 32bit app
typedef struct NSRange32 {
    unsigned int location;
    unsigned int length;
} NSRange32;

@interface NoteObject ()
- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(NVFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error;
- (void)captureFileMergeBaseIfNecessary;
- (void)clearFileMergeBase;
- (BOOL)preserveExternalSnapshot:(NVFileSnapshot*)snapshot format:(int)format
	movedFilename:(NSString**)movedFilename error:(NSError**)error;
@end

@implementation NoteObject

@synthesize fileMergeBaseText;
@synthesize fileMergeBaseLabels;
@synthesize fileMergeBaseData;
@synthesize externalEditingConflictNote;
@synthesize externalEditingConflictData;

static void NVSetFileObservation(NoteObject *note, NVFileObservation *observation) {
	note->fileModificationTime = [observation modificationTime];
	note->fileAttributeChangeTime = [observation attributeModificationTime];
	note->logicalSize = [observation logicalSize];
	note->sessionFileID = [observation fileID];
	note->documentID = [observation documentID];
	note->sessionFileGeneration = [observation generationCount];
	note->fileMetadataIsValid = YES;
}

static BOOL NVSnapshotMatchesNote(NVFileSnapshot *snapshot, NoteObject *note) {
	NVFileObservation *observation = [snapshot observation];
	return note->fileMetadataIsValid &&
		note->logicalSize == [observation logicalSize] &&
		(!note->sessionFileID || ![observation fileID] ||
			note->sessionFileID == [observation fileID]) &&
		(!note->sessionFileGeneration || ![observation generationCount] ||
			note->sessionFileGeneration == [observation generationCount]) &&
		NVCompareTimespecs(note->fileModificationTime,
			[observation modificationTime]) == NSOrderedSame &&
		NVCompareTimespecs(note->fileAttributeChangeTime,
			[observation attributeModificationTime]) == NSOrderedSame;
}

static NSString *NVTriviallyMergedString(NSString *base, NSString *local, NSString *external) {
	if (!base || !local || !external) return nil;
	if ([local isEqualToString:external]) return local;
	if ([local isEqualToString:base]) return external;
	if ([external isEqualToString:base]) return local;
	return nil;
}

static NSError *NVNoteStorageError(NVNoteStorageErrorCode code, NSString *description) {
	return [NSError errorWithDomain:NVNoteStorageErrorDomain code:code
		userInfo:[NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey]];
}

static NSData *NVCreateRichFileData(NSAttributedString *content, int format, NSError **error) {
	if (format == RTFTextFormat) {
		NSMutableAttributedString *withoutColor = [content mutableCopy];
		[withoutColor removeAttribute:NSForegroundColorAttributeName
			range:NSMakeRange(0, [withoutColor length])];
		NSData *data = [withoutColor RTFFromRange:NSMakeRange(0, [withoutColor length])
			documentAttributes:@{}];
		[withoutColor release];
		return data;
	}
	if (format == HTMLFormat)
		return [content dataFromRange:NSMakeRange(0, [content length])
			documentAttributes:@{ NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType }
			error:error];
	return nil;
}

static NSData *NVCreatePlainTextDataPromotingToUTF8(NSString *string,
	NSStringEncoding *encoding) {
	NSData *data = [string dataUsingEncoding:*encoding allowLossyConversion:NO];
	if (!data) {
		*encoding = NSUTF8StringEncoding;
		data = [string dataUsingEncoding:*encoding allowLossyConversion:YES];
	}
	return data;
}

static NSMutableAttributedString *NVCreateDecodedContent(NSData *data, int format,
	NSStringEncoding *encoding) {
	if (!data) return nil;
	NSMutableAttributedString *content = nil;
	switch (format) {
		case PlainTextFormat: {
			NSMutableString *string = [NSMutableString newShortLivedStringFromData:data
				ofGuessedEncoding:encoding];
			if (string) {
				content = [[NSMutableAttributedString alloc] initWithString:string
					attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
				[string release];
			}
			break;
		}
		case RTFTextFormat:
			content = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
			break;
		case HTMLFormat:
			content = [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL];
			[content removeAttachments];
			break;
		case SingleDatabaseFormat:
		default:
			break;
	}
	return content;
}

- (id)init {
    self = [super init];
    if (self) {
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
	[contentString release];
	[labelSet release];
	[undoManager release];
	[filename release];
	[dateModifiedString release];
	[dateCreatedString release];
	[prefixParentNotes release];
	[syncServicesMD release];
	self.fileMergeBaseText = nil;
	self.fileMergeBaseLabels = nil;
	self.fileMergeBaseData = nil;
	self.externalEditingConflictNote = nil;
	self.externalEditingConflictData = nil;
	
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

- (void)attachToDelegate:(id)theDelegate {
	/*
	 * Construction and file decoding intentionally leave a note detached.  This
	 * single gateway performs every controller-dependent action only when the
	 * caller is ready to make the note live.  In particular, temporary objects
	 * used while reconciling a directory cannot register labels or notify UI.
	 */
	delegate = theDelegate;
	if (!delegate) return;
	if (!filename) filename = [[delegate uniqueFilenameForTitle:titleString fromNote:self] retain];
	if (!tableTitleString) [self updateTablePreviewString];
	if (!labelSet) [self updateLabelConnectionsAfterDecoding];
}

NSInteger compareFilename(id *one, id *two) {
    
    return (NSInteger)CFStringCompare((CFStringRef)((*(NoteObject**)one)->filename), 
				(CFStringRef)((*(NoteObject**)two)->filename), kCFCompareCaseInsensitive);
}

static NSInteger NVCompareAbsoluteTimes(CFAbsoluteTime one, CFAbsoluteTime two) {
	return one < two ? NSOrderedAscending : (one > two ? NSOrderedDescending : NSOrderedSame);
}

NSInteger compareDateModified(id *a, id *b) {
	return NVCompareAbsoluteTimes((*(NoteObject**)a)->modifiedDate, (*(NoteObject**)b)->modifiedDate);
}
NSInteger compareDateCreated(id *a, id *b) {
	return NVCompareAbsoluteTimes((*(NoteObject**)a)->createdDate, (*(NoteObject**)b)->createdDate);
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
	return compareDateModified(b, a);
}
NSInteger compareDateCreatedReverse(id *a, id *b) {
	return compareDateCreated(b, a);
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

#include "SynchronizedNoteMixIns.h"

//syncing w/ server and from journal;

DefModelAttrAccessor(filenameOfNote, filename)
DefModelAttrAccessor(sessionFileIDOfNote, sessionFileID)
DefModelAttrAccessor(documentIDOfNote, documentID)
DefModelAttrAccessor(sessionFileGenerationOfNote, sessionFileGeneration)
DefModelAttrAccessor(fileModificationTimeOfNote, fileModificationTime)
DefModelAttrAccessor(fileAttributeChangeTimeOfNote, fileAttributeChangeTime)
DefModelAttrAccessor(fileMetadataIsValidForNote, fileMetadataIsValid)
DefModelAttrAccessor(titleOfNote, titleString)
DefModelAttrAccessor(labelsOfNote, labelString)
DefModelAttrAccessor(modifiedDateOfNote, modifiedDate)
DefModelAttrAccessor(createdDateOfNote, createdDate)
DefModelAttrAccessor(storageFormatOfNote, currentFormatID)
DefModelAttrAccessor(fileEncodingOfNote, fileEncoding)
DefModelAttrAccessor(prefixParentsOfNote, prefixParentNotes)

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

//NotationController attaches decoded notes and rebuilds their label connections after unarchiving.

//there is no measurable difference in speed when using decodeValuesOfObjCTypes, oddly enough
//the overhead of the _decodeObject* C functions must be significantly greater than the objc_msgSend and argument passing overhead
- (id)initWithCoder:(NSCoder*)decoder {
	self = [self init];
	if (self) {
		
		if ([decoder allowsKeyedCoding]) {
			//(hopefully?) no versioning necessary here
			
			modifiedDate = [decoder decodeDoubleForKey:VAR_STR(modifiedDate)];
			createdDate = [decoder decodeDoubleForKey:VAR_STR(createdDate)];
			selectedRange.location = [decoder decodeInt32ForKey:@"selectionRangeLocation"];
			selectedRange.length = [decoder decodeInt32ForKey:@"selectionRangeLength"];
			contentsWere7Bit = [decoder decodeBoolForKey:VAR_STR(contentsWere7Bit)];
			
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];

			currentFormatID = [decoder decodeInt32ForKey:VAR_STR(currentFormatID)];
			if ([decoder containsValueForKey:@"fileModificationSeconds"] &&
				[decoder containsValueForKey:@"fileAttributeChangeSeconds"] &&
				[decoder containsValueForKey:@"fileLogicalSize64"]) {
				fileModificationTime.tv_sec = (time_t)[decoder decodeInt64ForKey:@"fileModificationSeconds"];
				fileModificationTime.tv_nsec = [decoder decodeInt32ForKey:@"fileModificationNanoseconds"];
				fileAttributeChangeTime.tv_sec = (time_t)[decoder decodeInt64ForKey:@"fileAttributeChangeSeconds"];
				fileAttributeChangeTime.tv_nsec = [decoder decodeInt32ForKey:@"fileAttributeChangeNanoseconds"];
				logicalSize = (uint64_t)[decoder decodeInt64ForKey:@"fileLogicalSize64"];
				documentID = (uint32_t)[decoder decodeInt64ForKey:@"fileDocumentIdentifier"];
				fileMetadataIsValid = YES;
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
			unsigned int legacyNodeID = 0;
			unsigned short legacyHighSeconds = 0, legacyFraction = 0;
			unsigned int legacyLowSeconds = 0;
			float scrolledProportion = 0.0;
			unsigned long longTemp;
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
			[decoder decodeValueOfObjCType:"{_NSRange=II}" at:&range32];
			[decoder decodeValueOfObjCType:@encode(float) at:&scrolledProportion];
			
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
			
			[decoder decodeValueOfObjCType:@encode(int) at:&currentFormatID];
			[decoder decodeValueOfObjCType:"L" at:&longTemp];
            legacyNodeID = (unsigned int)longTemp;
			[decoder decodeValueOfObjCType:@encode(unsigned short) at:&legacyHighSeconds];
			[decoder decodeValueOfObjCType:"L" at:&longTemp];
            legacyLowSeconds = (unsigned int)longTemp;
			[decoder decodeValueOfObjCType:@encode(unsigned short) at:&legacyFraction];
            
            [decoder decodeValueOfObjCType:"I" at:&fileEncoding];
			
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
			
			titleString = [[decoder decodeObject] retain];
			labelString = [[decoder decodeObject] retain];
			contentString = [[decoder decodeObject] retain];
			filename = [[decoder decodeObject] retain];
			(void)legacyNodeID;
			(void)legacyHighSeconds;
			(void)legacyLowSeconds;
			(void)legacyFraction;
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
		
		if (!titleString && !contentString && !labelString) {
			[self release];
			return nil;
		}
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
		if (fileMetadataIsValid) {
			[coder encodeInt64:(int64_t)fileModificationTime.tv_sec forKey:@"fileModificationSeconds"];
			[coder encodeInt32:(int32_t)fileModificationTime.tv_nsec forKey:@"fileModificationNanoseconds"];
			[coder encodeInt64:(int64_t)fileAttributeChangeTime.tv_sec forKey:@"fileAttributeChangeSeconds"];
			[coder encodeInt32:(int32_t)fileAttributeChangeTime.tv_nsec forKey:@"fileAttributeChangeNanoseconds"];
			[coder encodeInt64:(int64_t)logicalSize forKey:@"fileLogicalSize64"];
			[coder encodeInt64:(int64_t)documentID forKey:@"fileDocumentIdentifier"];
		}
			[coder encodeInt32:(int32_t)fileEncoding forKey:VAR_STR(fileEncoding)];
		
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeObject:syncServicesMD forKey:VAR_STR(syncServicesMD)];
		
		[coder encodeObject:titleString forKey:VAR_STR(titleString)];
		[coder encodeObject:labelString forKey:VAR_STR(labelString)];
		[coder encodeObject:contentString forKey:VAR_STR(contentString)];
		[coder encodeObject:filename forKey:VAR_STR(filename)];
		
	}
}

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle format:(int)formatID labels:(NSString*)aLabelString {
    self = [self init];
    if (self) {
		
		if (!bodyText || !aNoteTitle) {
			[self release];
			return nil;
		}
		delegate = nil;

		contentString = [[NSMutableAttributedString alloc] initWithAttributedString:bodyText];
		[self initContentCacheCString];
		if (!cContents) {
			NSLog(@"couldn't get UTF8 string from contents?!?");
			[self release];
			return nil;
		}

		if (![self _setTitleString:aNoteTitle])
		    titleString = [NSLocalizedString(@"Untitled Note", @"Title of a nameless note") copy];
		
		if (![self _setLabelString:aLabelString]) {
			labelString = [@"" copy];
			cLabelsFoundPtr = cLabels = strdup("");
		}
		
		currentFormatID = formatID;
		filename = nil;
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent();
		dateCreatedString = [dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain] retain];
		fileModificationTime = NVTimespecFromAbsoluteTime(modifiedDate);
		
    }
    
    return self;
}

- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(NVFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error {
	NSStringEncoding encoding = [snapshot encoding] ? [snapshot encoding] : fallbackEncoding;
	NSMutableAttributedString *decoded = NVCreateDecodedContent([snapshot data], format, &encoding);
	if (!decoded) {
		if (error) *error = NVNoteStorageError(NVNoteStorageFormattingError,
			[NSString stringWithFormat:@"Could not decode note file '%@'.", entry->filename]);
		[self release];
		return nil;
	}
	NSString *labels = [snapshot tags] ? [[snapshot tags] componentsJoinedByString:@" "] : fallbackLabels;
	self = [self initWithNoteBody:decoded title:[(NSString*)entry->filename stringByDeletingPathExtension]
		format:format labels:(labels ? labels : @"")];
	[decoded release];
	if (!self) return nil;
	filename = [(NSString*)entry->filename copy];
	fileEncoding = encoding;
	NVFileObservation *observation = [snapshot observation];
	NVSetFileObservation(self, observation);
	[self setDateModified:NVAbsoluteTimeFromTimespec([observation modificationTime])];
	CFAbsoluteTime creationTime = NVAbsoluteTimeFromTimespec([observation creationTime]);
	[self setDateAdded:(creationTime > 0.0 ? creationTime :
		(fallbackCreatedDate > 0.0 ? fallbackCreatedDate : CFAbsoluteTimeGetCurrent()))];
	return self;
}

- (void)applyPreparedFileStateFromNote:(NoteObject*)preparedNote {
	/*
	 * The prepared note is a private staging value.  Swapping its owned objects
	 * into the live note makes commit allocation-free for the large content and
	 * cache fields; the staging object's eventual deallocation releases the old
	 * live state.  Sync identity, LSN, selection, and the live delegate stay put.
	 */
#define NV_SWAP_OBJECT(field) do { id temporary = field; field = preparedNote->field; preparedNote->field = temporary; } while (0)
#define NV_SWAP_POINTER(field) do { char *temporary = field; field = preparedNote->field; preparedNote->field = temporary; } while (0)
	NV_SWAP_OBJECT(tableTitleString);
	NV_SWAP_OBJECT(titleString);
	NV_SWAP_OBJECT(labelString);
	NV_SWAP_OBJECT(contentString);
	NV_SWAP_OBJECT(labelSet);
	NV_SWAP_OBJECT(dateModifiedString);
	NV_SWAP_OBJECT(dateCreatedString);
	NV_SWAP_OBJECT(filename);
	NV_SWAP_POINTER(cTitle);
	NV_SWAP_POINTER(cContents);
	NV_SWAP_POINTER(cLabels);
	NV_SWAP_POINTER(cTitleFoundPtr);
	NV_SWAP_POINTER(cContentsFoundPtr);
	NV_SWAP_POINTER(cLabelsFoundPtr);
#undef NV_SWAP_OBJECT
#undef NV_SWAP_POINTER
	contentsWere7Bit = preparedNote->contentsWere7Bit;
	contentCacheNeedsUpdate = preparedNote->contentCacheNeedsUpdate;
	fileModificationTime = preparedNote->fileModificationTime;
	fileAttributeChangeTime = preparedNote->fileAttributeChangeTime;
	logicalSize = preparedNote->logicalSize;
	sessionFileID = preparedNote->sessionFileID;
	documentID = preparedNote->documentID;
	sessionFileGeneration = preparedNote->sessionFileGeneration;
	fileMetadataIsValid = preparedNote->fileMetadataIsValid;
	currentFormatID = preparedNote->currentFormatID;
	fileEncoding = preparedNote->fileEncoding;
	modifiedDate = preparedNote->modifiedDate;
	createdDate = preparedNote->createdDate;
	self.fileMergeBaseText = nil;
	self.fileMergeBaseLabels = nil;
	self.fileMergeBaseData = nil;
	[undoManager removeAllActions];
}

- (void)applyCatalogEntry:(NoteCatalogEntry*)catEntry
	filename:(NSString*)newFilename title:(NSString*)newTitle {
	if (newFilename && ![newFilename isEqualToString:filename]) {
		[filename release];
		filename = [newFilename retain];
		[self _setTitleString:newTitle];
	}
	[self updateFileIdentityFromCatalogEntry:catEntry];
}

//assume any changes have been synchronized with undomanager
- (void)setContentString:(NSAttributedString*)attributedString {
	if (attributedString) {
		[self captureFileMergeBaseIfNecessary];
		[contentString setAttributedString:attributedString];
		
		[self updateTablePreviewString];
		contentCacheNeedsUpdate = YES;
		//[self updateContentCacheCStringIfNecessary];
		
		[delegate note:self attributeChanged:NotePreviewString];
	
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		// Active scratch sessions mirror this change after the current callback;
		// this call only schedules reconciliation and never performs file I/O here.
		[[ExternalEditingSession sharedExternalEditingSession] noteContentsDidChange:self];
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
	}
}

- (void)initContentCacheCString {

	if (contentsWere7Bit) {
		if (!(cContentsFoundPtr = cContents = [[contentString string] copyLowercaseASCIIString]))
			contentsWere7Bit = NO;
	}
	
	if (!contentsWere7Bit) {
		const char *cStringData = [[contentString string] lowercaseUTF8String];
		cContentsFoundPtr = cContents = cStringData ? strdup(cStringData) : NULL;
		
		contentsWere7Bit = cContents ? !ContainsHighAscii(cContents, strlen(cContents)) : NO;
	}
	
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
	
	if (aNewTitle && ![aNewTitle isEqualToString:titleString])
		[self captureFileMergeBaseIfNecessary];
	
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
			![[delegate noteDirectory] regularFileExistsNamed:filename]) {
			
			[self setFilenameFromTitle];
		}
		
		//yes, the given extension could be different from what we had before
		//but makeNoteDirty will eventually cause it to be re-written in the current format
		//and thus the format ID will be changed if that was the case
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		[self updateTablePreviewString];
		
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

- (BOOL)setFilenameFromTitle {
	NSString *newFilename = [delegate uniqueFilenameForTitle:titleString fromNote:self];
	[self setFilename:newFilename withExternalTrigger:NO];
	return [filename isEqualToString:newFilename];
}

- (void)setFilename:(NSString*)aString withExternalTrigger:(BOOL)externalTrigger {
    
    if (!filename || ![aString isEqualToString:filename]) {
		NSString *oldName = filename;
		filename = [aString copy];
		
		if (!externalTrigger) {
			NSError *renameError = nil;
			BOOL renamed = !oldName || currentFormatID == SingleDatabaseFormat ||
				[[delegate noteDirectory] renameFileNamed:oldName
				toUnusedName:filename error:&renameError];
			BOOL sourceWasMissing = !renamed &&
				[[renameError domain] isEqualToString:NSPOSIXErrorDomain] &&
				[renameError code] == ENOENT;
			if (!renamed && !sourceWasMissing) {
				NSLog(@"Couldn't rename note %@", titleString);
				[delegate noteDidNotWrite:self error:renameError];
				
				//revert name
				[filename release];
				filename = oldName;
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
	
	//Keep titles in the same canonical form used by directory enumeration.
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
		[oldLabels release];
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
	if (newLabelString && ![newLabelString isEqualToString:labelString])
		[self captureFileMergeBaseIfNecessary];
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
	
	for (NSString *aWord in words) {
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

- (NSURL*)absoluteUNIXPath {
	return [[delegate noteDirectory] transientFileReferenceURLForFileNamed:filename error:NULL];
}

- (BOOL)writeUsingCurrentFileFormatIfNecessary {
	return !shouldWriteToFile || [self writeUsingCurrentFileFormat];
}

- (void)requireFileWrite {
	shouldWriteToFile = YES;
}

- (void)captureFileMergeBaseIfNecessary {
	if (self.fileMergeBaseText || shouldWriteToFile || !delegate || !filename ||
		[delegate currentNoteStorageFormat] == SingleDatabaseFormat) return;
	[self setFileMergeBaseFromNote:self];
}

- (void)setFileMergeBaseFromNote:(NoteObject*)note {
	self.fileMergeBaseText = [[note contentString] string];
	self.fileMergeBaseLabels = labelsOfNote(note);
	self.fileMergeBaseData = nil;
	if (storageFormatOfNote(note) == RTFTextFormat || storageFormatOfNote(note) == HTMLFormat) {
		id noteDelegate = [note delegate];
		NVFileSnapshot *snapshot = [[noteDelegate noteDirectory]
			snapshotForFileNamed:filenameOfNote(note) error:NULL];
		if (snapshot && (NVSnapshotMatchesNote(snapshot, note) ||
			[[snapshot data] isEqualToData:NVCreateRichFileData([note contentString],
				storageFormatOfNote(note), NULL)]))
			self.fileMergeBaseData = [snapshot data];
	}
}

- (void)clearFileMergeBase {
	self.fileMergeBaseText = nil;
	self.fileMergeBaseLabels = nil;
	self.fileMergeBaseData = nil;
}

- (BOOL)writeUsingJournal:(WALStorageController*)wal {
	BOOL wroteAllOfNote = [wal writeEstablishedNote:self];
	if (!wroteAllOfNote) {
		[delegate noteDidNotWrite:self error:NVNoteStorageError(NVNoteStorageJournalError,
			NSLocalizedString(@"the write-ahead journal could not be updated", nil))];
	}
	return wroteAllOfNote;
}

- (BOOL)preserveExternalSnapshot:(NVFileSnapshot*)snapshot format:(int)format
	movedFilename:(NSString**)movedFilename error:(NSError**)error {
	if (movedFilename) *movedFilename = nil;
	NSString *conflictTitle = [titleString stringByAppendingString:@" (conflict)"];
	NSString *conflictFilename = [delegate uniqueFilenameForTitle:conflictTitle fromNote:nil];
	NSArray *tags = [snapshot tags] ? [snapshot tags] : [self orderedLabelTitles];
	BOOL moved = currentFormatID == SingleDatabaseFormat;
	BOOL stored = moved ? [[delegate noteDirectory] renameFileNamed:filename
		toUnusedName:conflictFilename error:error] : NO;
	if (!moved) {
		NVFileObservation *observation = [snapshot observation];
		NVFileWriteResult *result = [[delegate noteDirectory] createNoteFileNamed:conflictFilename
			withData:[snapshot data] encoding:(format == PlainTextFormat ? [snapshot encoding] : 0)
			tags:tags creationTime:NVAbsoluteTimeFromTimespec([observation creationTime])
			modificationTime:NVAbsoluteTimeFromTimespec([observation modificationTime])];
		switch ([result disposition]) {
			case NVFileWriteInstalledVerified:
				stored = YES;
				break;
			case NVFileWriteInstalledNeedsReconciliation:
				stored = YES;
				break;
			case NVFileWriteNotInstalled:
				if (error) *error = [result error];
				break;
		}
	}
	if (stored) {
		if (moved && movedFilename) *movedFilename = conflictFilename;
		else [delegate performSelector:@selector(synchronizeNotesFromDirectory)
			withObject:nil afterDelay:0.0];
	}
	return stored;
}

- (BOOL)writeUsingCurrentFileFormat {
	/*
	 * Theory of operation: first turn the note in memory into the bytes that
	 * belong in its file. Then read the existing file and its metadata together;
	 * that consistent reading is the "snapshot" used for the rest of this method.
	 * If another program edited the file while we were editing the note, plain
	 * text is combined with the saved starting text by diff-match-patch (our text
	 * merging algorithm). RTF and HTML are treated more conservatively: if their
	 * serialized bytes differ, the other program's version is saved as a conflict
	 * note instead of guessing how to merge formatting. On filesystems with swap
	 * or exchange, the final replacement is allowed only if the file still matches
	 * the snapshot. Limited filesystems such as ExFAT recheck immediately before
	 * rename but retain a narrow concurrent-writer race. File-to-file conversion
	 * is an authoritative rewrite after the source format is reconciled. A
	 * database-to-file conversion also preserves a differing file already at the
	 * destination name, but does not let that file replace the database note.
	 */

    NSData *formattedData = nil;
    NSError *error = nil;
	
	int formatID = [delegate currentNoteStorageFormat];
	BOOL convertingFromDatabase = currentFormatID == SingleDatabaseFormat;
	BOOL changingFormat = currentFormatID != formatID;
	NSStringEncoding snapshotFallbackEncoding = fileEncoding;
    switch (formatID) {
		case SingleDatabaseFormat:
			//we probably shouldn't be here
			NSAssert(NO, @"Warning! Tried to write data for an individual note in single-db format!");
			
			return NO;
		case PlainTextFormat:
			formattedData = NVCreatePlainTextDataPromotingToUTF8(
				[contentString string], &fileEncoding);
			break;
		case RTFTextFormat:
		case HTMLFormat:
			formattedData = NVCreateRichFileData(contentString, formatID, &error);
			break;
		default:
			NSLog(@"Attempted to write using unknown format ID: %d", formatID);
			//return NO;
    }
    
	if (formattedData) {
		BOOL resetFilename = NO;
		if (!filename || changingFormat) {
			//file will (probably) be renamed
			//NSLog(@"resetting the file name due to format change: to %d from %d", formatID, currentFormatID);
			if (![self setFilenameFromTitle]) return NO;
			resetFilename = YES;
		}
		
		NVFileSnapshot *snapshot = nil;
		NSError *snapshotError = nil;
		NSString *movedConflictFilename = nil;
		BOOL destinationExists = NO;
		if (!changingFormat || convertingFromDatabase) {
			snapshot = [[delegate noteDirectory] snapshotForFileNamed:filename error:&snapshotError];
			destinationExists = snapshot != nil;
			if (!destinationExists && !([[snapshotError domain] isEqualToString:NSPOSIXErrorDomain] &&
				[snapshotError code] == ENOENT)) {
				[delegate noteDidNotWrite:self error:snapshotError];
				return NO;
			}
		}

		if (destinationExists) {
			// Decide what to do before writing. We merge only when the external
			// version can be related to the version the user started editing; if
			// not, preserve that version as a separate conflict note.
			BOOL conflict = NO;
			NSString *externalLabels = [snapshot tags] ?
				[[snapshot tags] componentsJoinedByString:@" "] :
				(self.fileMergeBaseLabels ? self.fileMergeBaseLabels : labelString);
			NSString *mergedLabels = convertingFromDatabase ? labelString :
				(self.fileMergeBaseLabels ?
					NVTriviallyMergedString(self.fileMergeBaseLabels, labelString, externalLabels) :
					([externalLabels isEqualToString:labelString] ? labelString : nil));

			if (formatID == PlainTextFormat) {
				NSStringEncoding externalEncoding = [snapshot encoding] ?
					[snapshot encoding] : snapshotFallbackEncoding;
				NSMutableAttributedString *externalContent =
					NVCreateDecodedContent([snapshot data], PlainTextFormat, &externalEncoding);
				if (!externalContent) {
					[delegate noteDidNotWrite:self error:NVNoteStorageError(
						NVNoteStorageFormattingError,
						NSLocalizedString(@"the externally edited note could not be decoded", nil))];
					return NO;
				}
				NSString *localText = [contentString string];
				NSString *externalText = [externalContent string];
				NSString *mergedText = convertingFromDatabase ?
					([localText isEqualToString:externalText] ? localText : nil) :
					(self.fileMergeBaseText ?
					NVMergedText(self.fileMergeBaseText, localText, externalText) :
					([localText isEqualToString:externalText] ? localText : nil));
				conflict = !mergedText || !mergedLabels;
				if (!conflict) {
					if (![mergedText isEqualToString:localText]) {
						[contentString replaceCharactersInRange:NSMakeRange(0, [contentString length])
							withString:mergedText];
						contentCacheNeedsUpdate = YES;
						[self updateTablePreviewString];
						[delegate note:self attributeChanged:NotePreviewString];
						[[delegate delegate] contentsUpdatedForNote:self];
					}
					fileEncoding = externalEncoding;
					formattedData = NVCreatePlainTextDataPromotingToUTF8(
						[contentString string], &fileEncoding);
				}
				[externalContent release];
			} else {
				BOOL externalContentChanged = convertingFromDatabase ? YES :
					(self.fileMergeBaseData ?
					![[snapshot data] isEqualToData:self.fileMergeBaseData] :
					(!self.fileMergeBaseText || !NVSnapshotMatchesNote(snapshot, self)));
				conflict = (externalContentChanged &&
					![[snapshot data] isEqualToData:formattedData]) || !mergedLabels;
			}

			if (conflict) {
				NSError *conflictError = nil;
				if (![self preserveExternalSnapshot:snapshot format:formatID
					movedFilename:&movedConflictFilename error:&conflictError]) {
					[delegate noteDidNotWrite:self error:conflictError];
					return NO;
				}
			} else if (![mergedLabels isEqualToString:labelString]) {
				[self _setLabelString:mergedLabels];
				[delegate note:self attributeChanged:NoteLabelsColumnString];
			}
		}
		
		NSError *writeError = nil;
		// expectedData tells the file writer, "replace this only if the destination
		// is still exactly the file we just read." Swap/exchange filesystems enforce
		// that through installation; limited filesystems recheck just before rename.
		NVFileWriteResult *writeResult = (!changingFormat && destinationExists) ?
			[[delegate noteDirectory] replaceNoteFileNamed:filename withData:formattedData
				encoding:(PlainTextFormat == formatID ? fileEncoding : 0)
				tags:[self orderedLabelTitles] creationTime:createdDate
				modificationTime:modifiedDate expectedSnapshot:snapshot] :
			[[delegate noteDirectory] overwriteNoteFileNamed:filename withData:formattedData
				encoding:(PlainTextFormat == formatID ? fileEncoding : 0)
				tags:[self orderedLabelTitles] creationTime:createdDate
				modificationTime:modifiedDate];
		BOOL wroteVerified = NO;
		switch ([writeResult disposition]) {
			case NVFileWriteInstalledVerified:
				wroteVerified = YES;
				break;
			case NVFileWriteInstalledNeedsReconciliation:
				currentFormatID = formatID;
				if ([[writeResult installedSnapshot] observation])
					NVSetFileObservation(self, [[writeResult installedSnapshot] observation]);
				shouldWriteToFile = NO;
				[self clearFileMergeBase];
				[delegate performSelector:@selector(synchronizeNotesFromDirectory)
					withObject:nil afterDelay:0.0];
				return YES; // the exact obligation was installed; reconciliation owns its successor
			case NVFileWriteNotInstalled:
				writeError = [writeResult error];
				break;
		}
		if (!wroteVerified) {
			NSLog(@"Unable to save note file %@", filename);
			if (movedConflictFilename) {
				NSError *restoreError = nil;
				if (![[delegate noteDirectory] renameFileNamed:movedConflictFilename
					toUnusedName:filename error:&restoreError]) {
					writeError = restoreError;
					if ([[restoreError domain] isEqualToString:NSPOSIXErrorDomain] &&
						[restoreError code] == EEXIST)
						[delegate performSelector:@selector(synchronizeNotesFromDirectory)
							withObject:nil afterDelay:0.0];
				}
			}
			[delegate noteDidNotWrite:self error:writeError];
			return NO;
		}
		if (movedConflictFilename)
			[delegate performSelector:@selector(synchronizeNotesFromDirectory)
				withObject:nil afterDelay:0.0];
		currentFormatID = formatID;
		if (!resetFilename) {
			//NSLog(@"resetting the file name just because.");
			[self setFilenameFromTitle];
		}
		NVSetFileObservation(self, [[writeResult installedSnapshot] observation]);
		
		
		//finished writing to file successfully
		shouldWriteToFile = NO;
		// The starting text is kept only while this edit is in progress. It is
		// deliberately not archived with the NoteObject, because doing so would
		// duplicate note content and make archived notes slower to load.
		[self clearFileMergeBase];
		
		
		//tell any external editors that we've changed
		
    } else {
		[delegate noteDidNotWrite:self error:NVNoteStorageError(NVNoteStorageFormattingError,
			NSLocalizedString(@"the note could not be converted to its file format", nil))];
		NSLog(@"Unable to convert note contents into format %d", formatID);
		return NO;
    }
    
    return YES;
}

- (BOOL)writeFileDatesAndUpdateTrackingInfo {
	if (SingleDatabaseFormat == currentFormatID) return YES;

	NSError *error = nil;
	NVFileObservation *observation = [[delegate noteDirectory] setCreationTime:createdDate
		modificationTime:modifiedDate forFileNamed:filename error:&error];
	if (!observation) {
		NSLog(@"Could not set dates for %@: %@", filename, error);
		return NO;
	}
	NVSetFileObservation(self, observation);
	
	return YES;
}

- (BOOL)setFileEncodingAndReinterpret:(NSStringEncoding)encoding {
	if (encoding == fileEncoding) return YES;
	NSError *error = nil;
	NVFileSnapshot *snapshot = [[delegate noteDirectory] snapshotForFileNamed:filename error:&error];
	if (!snapshot) return NO;
	NVFileSnapshot *forcedSnapshot = [[[NVFileSnapshot alloc] initWithData:[snapshot data]
		tags:[snapshot tags] encoding:encoding observation:[snapshot observation]] autorelease];
	NVFileObservation *observation = [snapshot observation];
	NoteCatalogEntry entry = { [observation attributeModificationTime],
		[observation fileID], (CFStringRef)filename, [observation documentID],
		[observation generationCount] };
	NoteObject *prepared = [[NoteObject alloc] initWithCatalogEntry:&entry snapshot:forcedSnapshot
		format:currentFormatID fallbackLabels:labelString fallbackEncoding:encoding
		fallbackCreatedDate:createdDate error:&error];
	if (!prepared) return NO;
	NVFileSnapshot *resultingSnapshot = [[delegate noteDirectory] setTextEncoding:encoding
		forFileNamed:filename expectedSnapshot:snapshot error:&error];
	if (!resultingSnapshot) {
		[prepared release];
		return NO;
	}
	NVSetFileObservation(prepared, [resultingSnapshot observation]);
	[self disconnectLabels];
	[self applyPreparedFileStateFromNote:prepared];
	[self attachToDelegate:delegate];
	[prepared release];
	[self makeNoteDirtyUpdateTime:NO updateFile:NO];
	[self registerModificationWithOwnedServices];
	[delegate schedulePushToAllSyncServicesForNote:self];
	return YES;
}

- (void)updateFileIdentityFromCatalogEntry:(NoteCatalogEntry*)catEntry {
	fileAttributeChangeTime = catEntry->attributeChangeTime;
	sessionFileID = catEntry->fileID;
	documentID = catEntry->documentID;
	sessionFileGeneration = catEntry->generationCount;
}

- (void)invalidateFileMetadata {
	fileMetadataIsValid = NO;
	documentID = 0;
	sessionFileID = 0;
	sessionFileGeneration = 0;
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

- (BOOL)moveFileToTrash {
	NSError *error = nil;
	if (![[delegate noteDirectory] moveFileToTrashUsingWorkspaceNamed:filename
		resultingURL:NULL error:&error]) {
		if (([[error domain] isEqualToString:NSCocoaErrorDomain] &&
			[error code] == NSFileNoSuchFileError) ||
			([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ENOENT))
			return YES;
		NSLog(@"Couldn't move file to trash: %@", error);
		return NO;
	}
	return YES;
}

- (void)registerModificationWithOwnedServices {
	//mirror this note's current mod date to services with which it is already synced
	//there is no point calling this method unless the modification time is 
	[[SyncSessionController allServiceClasses] makeObjectsPerformSelector:@selector(registerLocalModificationForNote:) withObject:self];
}

- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile {
	if (updateFile) {
		[self captureFileMergeBaseIfNecessary];
		shouldWriteToFile = YES;
	}
	//else we don't turn file updating off--we might be overwriting the state of a previous note-dirty message
	
	if (updateTime) {
		[self setDateModified:CFAbsoluteTimeGetCurrent()];
		
		if ([delegate currentNoteStorageFormat] == SingleDatabaseFormat) {
			//only set if we're not currently synchronizing to avoid re-reading old data
			//this will be updated again when writing to a file, but for now we have the newest version
			//we must do this to allow new notes to be written when switching formats, and for encodingmanager checks
			fileModificationTime = NVTimespecFromAbsoluteTime(modifiedDate);
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

- (BOOL)exportToDirectoryURL:(NSURL*)directoryURL withFilename:(NSString*)userFilename
	usingFormat:(int)storageFormat overwrite:(BOOL)overwrite error:(NSError**)outError {
	
	NSData *formattedData = nil;
	NSError *formatError = nil;
	
	NSMutableAttributedString *contentMinusColor = [[contentString mutableCopy] autorelease];
	[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];

	
	switch (storageFormat) {
		case SingleDatabaseFormat:
			NSAssert(NO, @"Warning! Tried to export data in single-db format!?");
		case PlainTextFormat:
			formattedData = NVCreatePlainTextDataPromotingToUTF8(
				[contentMinusColor string], &fileEncoding);
			break;
		case RTFTextFormat:
			formattedData = [contentMinusColor RTFFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:@{}];
			break;
		case HTMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																		 forKey:NSDocumentTypeDocumentAttribute] error:&formatError];
			break;
		case WordDocFormat:
			formattedData = [contentMinusColor docFormatFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:@{}];
			break;
		case WordXMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSWordMLTextDocumentType 
																		 forKey:NSDocumentTypeDocumentAttribute] error:&formatError];
			break;
		default:
			NSLog(@"Attempted to export using unknown format ID: %d", storageFormat);
    }
	if (!formattedData) {
		if (outError) *outError = formatError ? formatError : NVNoteStorageError(NVNoteStorageFormattingError,
			NSLocalizedString(@"the note could not be converted to the selected export format", nil));
		return NO;
	}
		
	//can use our already-determined filename to write here
	//but what about file names that were the same except for their extension? e.g., .txt vs. .text
	//this will give them the same extension and cause an overwrite
	NSString *newextension = [NotationPrefs pathExtensionForFormat:storageFormat];
	NSString *newfilename = userFilename ? userFilename : [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:newextension];
	if (![directoryURL isFileReferenceURL] || ![newfilename length] ||
		[newfilename rangeOfString:@"/"].location != NSNotFound) {
		if (outError) *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
		return NO;
	}
	NSURL *outputURL = [[NSFileManager defaultManager] fileReferenceURLForFilename:newfilename
		inDirectoryURL:directoryURL error:outError];
	if (!outputURL || ![formattedData writeToURL:outputURL
		options:(overwrite ? NSDataWritingAtomic : NSDataWritingWithoutOverwriting)
		error:outError]) return NO;

	NSString *encodingValue = nil;
	if (PlainTextFormat == storageFormat)
		encodingValue = NVTextEncodingAttributeValue(fileEncoding);
	NSArray *tags = [self orderedLabelTitles];
	NSError *metadataError = nil;
	NSData *tagData = [NSPropertyListSerialization dataWithPropertyList:tags
		format:NSPropertyListBinaryFormat_v1_0 options:0 error:&metadataError];
	NSFileHandle *fileHandle = tagData ?
		[NSFileHandle fileHandleForWritingToURL:outputURL error:&metadataError] : nil;
	if (fileHandle) {
		int fileDescriptor = [fileHandle fileDescriptor];
		if (encodingValue) {
			const char *bytes = [encodingValue UTF8String];
			if (fsetxattr(fileDescriptor, "com.apple.TextEncoding", bytes, strlen(bytes), 0, 0) < 0) {
				int metadataErrno = errno;
				NSLog(@"Could not write export encoding for '%@': %s", newfilename,
					strerror(metadataErrno));
			}
		}
		if (fsetxattr(fileDescriptor, "com.apple.metadata:kMDItemOMUserTags",
			[tagData bytes], [tagData length], 0, 0) < 0) {
			int metadataErrno = errno;
			NSLog(@"Could not write export tags for '%@': %s", newfilename,
				strerror(metadataErrno));
		}
		[fileHandle closeFile];
	}
	else NSLog(@"Could not prepare export metadata for '%@': %@", newfilename, metadataError);

	NSError *tagError = nil;
	if (![outputURL setResourceValue:NVSemanticTagNames(tags)
		forKey:NSURLTagNamesKey error:&tagError])
		NSLog(@"Could not mirror OpenMeta tags to Finder tags for '%@': %@", newfilename, tagError);
	metadataError = nil;
	if (![outputURL setResourceValues:@{
		NSURLCreationDateKey: [NSDate dateWithTimeIntervalSinceReferenceDate:createdDate],
		NSURLContentModificationDateKey: [NSDate dateWithTimeIntervalSinceReferenceDate:modifiedDate]
	} error:&metadataError])
		NSLog(@"Could not set export dates for '%@': %@", newfilename, metadataError);
	return YES;
}

- (void)editExternallyUsingEditor:(ExternalEditor*)ed {
	[[ExternalEditingSession sharedExternalEditingSession] editNote:self inEditor:ed context:nil];
}

- (void)abortEditingInExternalEditor {
	[[ExternalEditingSession sharedExternalEditingSession] abortAllEditingSessionsForClient:self];
}

- (BOOL)externalEditingSession:(ExternalEditingSession*)editor didModifyFileData:(NSData*)data
	baseData:(NSData*)baseData path:(NSString*)path context:(NSDictionary*)context {
	(void)editor; (void)path; (void)context;
	if (self.externalEditingConflictNote) {
		if (![delegate makeNoteDurableForExternalEditing:self.externalEditingConflictNote]) return NO;
		BOOL sameData = [self.externalEditingConflictData isEqualToData:data];
		self.externalEditingConflictNote = nil;
		self.externalEditingConflictData = nil;
		if (sameData) return YES;
	}
	NSString *base = [[[NSString alloc] initWithData:baseData
		encoding:NSUTF8StringEncoding] autorelease];
	NSString *external = [[[NSString alloc] initWithData:data
		encoding:NSUTF8StringEncoding] autorelease];
	NSString *merged = NVMergedText(base, [contentString string], external);
	if (merged) {
		if (![merged isEqualToString:[contentString string]]) {
			NSAttributedString *value = [[[NSAttributedString alloc] initWithString:merged
				attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]] autorelease];
			[self setContentString:value];
			[[delegate delegate] contentsUpdatedForNote:self];
		}
		return YES;
	}
	if (!external) {
		/* Keep bytes that cannot be interpreted as UTF-8 inside the database before
		 * the scratch file is replaced or removed. Base64 is deliberately used so
		 * every original byte remains recoverable without writing another plaintext
		 * file outside the protected editing space. */
		NSString *encoded = [data base64EncodedStringWithOptions:
			NSDataBase64Encoding64CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed];
		NSString *recovery = [NSString stringWithFormat:NSLocalizedString(
			@"The external editor saved data that was not valid UTF-8. The exact bytes follow as Base64:\n\n%@", nil),
			encoded];
		NSAttributedString *body = [[[NSAttributedString alloc] initWithString:recovery
			attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]] autorelease];
		NoteObject *conflict = [[[NoteObject alloc] initWithNoteBody:body
			title:[titleString stringByAppendingString:@" (conflict - undecodable data)"]
			format:SingleDatabaseFormat labels:labelString] autorelease];
		[delegate addNotes:[NSArray arrayWithObject:conflict]];
		self.externalEditingConflictNote = conflict;
		self.externalEditingConflictData = data;
		if (![delegate makeNoteDurableForExternalEditing:conflict]) return NO;
		self.externalEditingConflictNote = nil;
		self.externalEditingConflictData = nil;
		NSBeep();
		return YES;
	}
	NSAttributedString *body = [[[NSAttributedString alloc] initWithString:external
		attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]] autorelease];
	NoteObject *conflict = [[[NoteObject alloc] initWithNoteBody:body
		title:[titleString stringByAppendingString:@" (conflict)"]
		format:SingleDatabaseFormat labels:labelString] autorelease];
	[delegate addNotes:[NSArray arrayWithObject:conflict]];
	self.externalEditingConflictNote = conflict;
	self.externalEditingConflictData = data;
	if (![delegate makeNoteDurableForExternalEditing:conflict]) return NO;
	self.externalEditingConflictNote = nil;
	self.externalEditingConflictData = nil;
	return YES;
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
