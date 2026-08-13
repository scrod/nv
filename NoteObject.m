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
- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(const NVNoteFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error;
- (void)captureFileMergeBaseIfNecessary;
- (void)clearFileMergeBase;
- (BOOL)preserveExternalSnapshot:(const NVNoteFileSnapshot*)snapshot format:(int)format
	error:(NSError**)error;
@end

@implementation NoteObject

@synthesize fileMergeBaseText;
@synthesize fileMergeBaseLabels;
@synthesize fileMergeBaseData;
@synthesize externalEditingConflictNote;
@synthesize externalEditingConflictData;

static CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec value) {
	return (CFAbsoluteTime)value.tv_sec + ((CFAbsoluteTime)value.tv_nsec / NSEC_PER_SEC) - kCFAbsoluteTimeIntervalSince1970;
}

static struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime value) {
	NSTimeInterval unixTime = value + kCFAbsoluteTimeIntervalSince1970;
	struct timespec result = { (time_t)floor(unixTime), 0 };
	result.tv_nsec = (long)((unixTime - floor(unixTime)) * NSEC_PER_SEC);
	return result;
}

static void NVSetFileInfo(NoteObject *note, const NVFileInfo *info) {
	note->fileModificationTime = info->modificationTime;
	note->fileAttributeChangeTime = info->attributeModificationTime;
	note->logicalSize = info->logicalSize;
	note->sessionFileID = info->fileID;
	note->documentID = info->documentID;
	note->sessionFileGeneration = info->generationCount;
	note->fileMetadataIsValid = YES;
}

static BOOL NVTimespecsEqual(struct timespec one, struct timespec two) {
	return one.tv_sec == two.tv_sec && one.tv_nsec == two.tv_nsec;
}

static BOOL NVSnapshotMatchesNote(const NVNoteFileSnapshot *snapshot, NoteObject *note) {
	return note->fileMetadataIsValid &&
		note->logicalSize == snapshot->info.logicalSize &&
		(!note->sessionFileID || !snapshot->info.fileID ||
			note->sessionFileID == snapshot->info.fileID) &&
		(!note->sessionFileGeneration || !snapshot->info.generationCount ||
			note->sessionFileGeneration == snapshot->info.generationCount) &&
		NVTimespecsEqual(note->fileModificationTime, snapshot->info.modificationTime) &&
		NVTimespecsEqual(note->fileAttributeChangeTime,
			snapshot->info.attributeModificationTime);
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

- (void)setDelegate:(id)theDelegate {
	delegate = theDelegate;
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

#include "SynchronizedNoteMixIns.h"

//syncing w/ server and from journal;

DefModelAttrAccessor(filenameOfNote, filename)
DefModelAttrAccessor(fileSizeOfNote, logicalSize)
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
#if DECODE_INDIVIDUALLY
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
		
	} else {
		// Modern builds only write keyed archives; non-keyed archives remain decode-only compatibility.
	}
}

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle delegate:(id)aDelegate format:(int)formatID labels:(NSString*)aLabelString {
	/* aDelegate is retained in the legacy signature for source compatibility;
	 * attachment is now explicit and side-effect-free construction ignores it. */
	(void)aDelegate;
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

- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry snapshot:(const NVNoteFileSnapshot*)snapshot
	format:(int)format fallbackLabels:(NSString*)fallbackLabels
	fallbackEncoding:(NSStringEncoding)fallbackEncoding
	fallbackCreatedDate:(CFAbsoluteTime)fallbackCreatedDate error:(NSError**)error {
	NSStringEncoding encoding = snapshot->encoding ? snapshot->encoding : fallbackEncoding;
	NSMutableAttributedString *decoded = NVCreateDecodedContent(snapshot->data, format, &encoding);
	if (!decoded) {
		if (error) *error = NVNoteStorageError(NVNoteStorageFormattingError,
			[NSString stringWithFormat:@"Could not decode note file '%@'.", entry->filename]);
		[self release];
		return nil;
	}
	NSString *labels = snapshot->tags ? [snapshot->tags componentsJoinedByString:@" "] : fallbackLabels;
	self = [self initWithNoteBody:decoded title:[(NSString*)entry->filename stringByDeletingPathExtension]
		delegate:nil format:format labels:(labels ? labels : @"")];
	[decoded release];
	if (!self) return nil;
	filename = [(NSString*)entry->filename copy];
	fileEncoding = encoding;
	NVSetFileInfo(self, &snapshot->info);
	[self setDateModified:NVAbsoluteTimeFromTimespec(snapshot->info.modificationTime)];
	CFAbsoluteTime creationTime = NVAbsoluteTimeFromTimespec(snapshot->info.creationTime);
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
		[delegate note:self attributeChanged:NoteTitleColumnString];
    }
	[oldTitle release];
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
			BOOL renamed = !oldName || [delegate renameNoteFromName:oldName
				toName:filename error:&renameError];
			BOOL sourceWasMissing = !renamed &&
				[[renameError domain] isEqualToString:NSPOSIXErrorDomain] &&
				[renameError code] == ENOENT;
			if (!renamed && !sourceWasMissing) {
				NSLog(@"Couldn't rename note %@", titleString);
				
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

- (NSURL*)noteFileURL {
	return [delegate fileReferenceURLForNoteNamed:filename error:NULL];
}

- (BOOL)writeUsingCurrentFileFormatIfNecessary {
	//if note had been updated via makeNoteDirty and needed file to be rewritten
	if (shouldWriteToFile) {
		return [self writeUsingCurrentFileFormat];
	}
	return YES;
}

- (void)requireFileWrite {
	shouldWriteToFile = YES;
}

- (void)captureFileMergeBaseIfNecessary {
	if (self.fileMergeBaseText || shouldWriteToFile || !delegate || !filename ||
		[delegate currentNoteStorageFormat] == SingleDatabaseFormat) return;
	self.fileMergeBaseText = [contentString string];
	self.fileMergeBaseLabels = labelString;
	if (currentFormatID == RTFTextFormat || currentFormatID == HTMLFormat) {
		NVNoteFileSnapshot snapshot = { 0 };
		if ([delegate readNoteFileSnapshot:&snapshot forNoteNamed:filename error:NULL] &&
			(NVSnapshotMatchesNote(&snapshot, self) ||
			 [snapshot.data isEqualToData:NVCreateRichFileData(contentString, currentFormatID, NULL)]))
			self.fileMergeBaseData = snapshot.data;
	}
}

- (void)setFileMergeBaseFromNote:(NoteObject*)note {
	self.fileMergeBaseText = [[note contentString] string];
	self.fileMergeBaseLabels = labelsOfNote(note);
	self.fileMergeBaseData = nil;
	if (storageFormatOfNote(note) == RTFTextFormat || storageFormatOfNote(note) == HTMLFormat) {
		NVNoteFileSnapshot snapshot = { 0 };
		id noteDelegate = [note delegate];
		if ([noteDelegate readNoteFileSnapshot:&snapshot
			forNoteNamed:filenameOfNote(note) error:NULL] &&
			(NVSnapshotMatchesNote(&snapshot, note) ||
			 [snapshot.data isEqualToData:NVCreateRichFileData([note contentString],
				storageFormatOfNote(note), NULL)]))
			self.fileMergeBaseData = snapshot.data;
	}
}

- (void)clearFileMergeBase {
	self.fileMergeBaseText = nil;
	self.fileMergeBaseLabels = nil;
	self.fileMergeBaseData = nil;
}

- (BOOL)writeUsingJournal:(WALStorageController*)wal {
    BOOL wroteAllOfNote = [wal writeEstablishedNote:self];
	
    if (wroteAllOfNote) {
		//update formatID to absolutely ensure we don't reload an earlier note back from disk, from text encoding menu, for example
		//currentFormatID = SingleDatabaseFormat;
	} else {
		[delegate noteDidNotWrite:self error:NVNoteStorageError(NVNoteStorageJournalError,
			NSLocalizedString(@"the write-ahead journal could not be updated", nil))];
	}
    
    return wroteAllOfNote;
}

- (BOOL)preserveExternalSnapshot:(const NVNoteFileSnapshot*)snapshot format:(int)format
	error:(NSError**)error {
	NSString *conflictTitle = [titleString stringByAppendingString:@" (conflict)"];
	NSString *conflictFilename = [delegate uniqueFilenameForTitle:conflictTitle fromNote:nil];
	NSArray *tags = snapshot->tags ? snapshot->tags : [self orderedLabelTitles];
	NVFileInfo ignoredInfo = { 0 };
	BOOL stored = [delegate storeNoteDataAtomically:snapshot->data withName:conflictFilename
		encoding:(format == PlainTextFormat ? snapshot->encoding : 0)
		tags:tags creationTime:NVAbsoluteTimeFromTimespec(snapshot->info.creationTime)
		modificationTime:NVAbsoluteTimeFromTimespec(snapshot->info.modificationTime)
		expectedData:nil resultingFileInfo:&ignoredInfo error:error];
	if (stored)
		[delegate performSelector:@selector(synchronizeNotesFromDirectory)
			withObject:nil afterDelay:0.0];
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
	 * note instead of guessing how to merge formatting. The final replacement is
	 * allowed only if the file still matches the snapshot, so a later save cannot
	 * be silently overwritten.
	 */

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
		case HTMLFormat:
			formattedData = NVCreateRichFileData(contentString, formatID, &error);
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

		NVNoteFileSnapshot snapshot = { 0 };
		NSError *snapshotError = nil;
		BOOL destinationExists = [delegate readNoteFileSnapshot:&snapshot
			forNoteNamed:filename error:&snapshotError];
		if (!destinationExists && !([[snapshotError domain] isEqualToString:NSPOSIXErrorDomain] &&
			[snapshotError code] == ENOENT)) {
			[delegate noteDidNotWrite:self error:snapshotError];
			return NO;
		}

		if (destinationExists) {
			// Decide what to do before writing. We merge only when the external
			// version can be related to the version the user started editing; if
			// not, preserve that version as a separate conflict note.
			BOOL conflict = NO;
			NSString *externalLabels = snapshot.tags ?
				[snapshot.tags componentsJoinedByString:@" "] :
				(self.fileMergeBaseLabels ? self.fileMergeBaseLabels : labelString);
			NSString *mergedLabels = self.fileMergeBaseLabels ?
				NVTriviallyMergedString(self.fileMergeBaseLabels, labelString, externalLabels) :
				([externalLabels isEqualToString:labelString] ? labelString : nil);

			if (formatID == PlainTextFormat) {
				NSStringEncoding externalEncoding = snapshot.encoding ? snapshot.encoding : fileEncoding;
				NSMutableAttributedString *externalContent =
					NVCreateDecodedContent(snapshot.data, PlainTextFormat, &externalEncoding);
				if (!externalContent) {
					[delegate noteDidNotWrite:self error:NVNoteStorageError(
						NVNoteStorageFormattingError,
						NSLocalizedString(@"the externally edited note could not be decoded", nil))];
					return NO;
				}
				NSString *localText = [contentString string];
				NSString *externalText = [externalContent string];
				NSString *mergedText = self.fileMergeBaseText ?
					NVMergedText(self.fileMergeBaseText, localText, externalText) :
					([localText isEqualToString:externalText] ? localText : nil);
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
					formattedData = [[contentString string] dataUsingEncoding:fileEncoding
						allowLossyConversion:NO];
				}
				[externalContent release];
			} else {
				BOOL externalContentChanged = self.fileMergeBaseData ?
					![snapshot.data isEqualToData:self.fileMergeBaseData] :
					(!self.fileMergeBaseText || !NVSnapshotMatchesNote(&snapshot, self));
				conflict = (externalContentChanged &&
					![snapshot.data isEqualToData:formattedData]) || !mergedLabels;
			}

			if (conflict) {
				NSError *conflictError = nil;
				if (![self preserveExternalSnapshot:&snapshot format:formatID error:&conflictError]) {
					[delegate noteDidNotWrite:self error:conflictError];
					return NO;
				}
			} else if (![mergedLabels isEqualToString:labelString]) {
				[self _setLabelString:mergedLabels];
				[delegate note:self attributeChanged:NoteLabelsColumnString];
			}
		}
		
		NSError *writeError = nil;
		NVFileInfo info = { 0 };
		// expectedData tells the file writer, "replace this only if the destination
		// is still exactly the file we just read." This closes the small race
		// between checking for a conflict and installing our replacement.
		if (![delegate storeNoteDataAtomically:formattedData withName:filename
			encoding:(PlainTextFormat == formatID ? fileEncoding : 0)
			tags:[self orderedLabelTitles] creationTime:createdDate
			modificationTime:modifiedDate
			expectedData:(destinationExists ? snapshot.data : nil)
			resultingFileInfo:&info error:&writeError]) {
			NSLog(@"Unable to save note file %@", filename);
			
			[delegate noteDidNotWrite:self error:writeError];
			return NO;
		}
		if (!resetFilename) {
			//NSLog(@"resetting the file name just because.");
			[self setFilenameFromTitle];
		}
		NVSetFileInfo(self, &info);
		
		
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
	if (![delegate setCreationTime:createdDate modificationTime:modifiedDate forNoteNamed:filename error:&error]) {
		NSLog(@"Could not set dates for %@: %@", filename, error);
		return NO;
	}
	NVFileInfo info;
	if (![delegate getFileInfo:&info forNoteNamed:filename error:&error]) {
		NSLog(@"Unable to inspect newly written file %@: %@", filename, error);
		return NO;
	}
	NVSetFileInfo(self, &info);
	
	return YES;
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
				fileModificationTime = NVTimespecFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
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
	if (encoding == fileEncoding) return YES;
	NVNoteFileSnapshot snapshot;
	NSError *error = nil;
	if (![delegate readNoteFileSnapshot:&snapshot forNoteNamed:filename error:&error]) return NO;
	NVNoteFileSnapshot forcedSnapshot = snapshot;
	forcedSnapshot.encoding = encoding;
	NoteCatalogEntry entry = { snapshot.info.attributeModificationTime,
		snapshot.info.fileID, (CFStringRef)filename, snapshot.info.documentID,
		snapshot.info.generationCount };
	NoteObject *prepared = [[NoteObject alloc] initWithCatalogEntry:&entry snapshot:&forcedSnapshot
		format:currentFormatID fallbackLabels:labelString fallbackEncoding:encoding
		fallbackCreatedDate:createdDate error:&error];
	if (!prepared) return NO;
	NVFileInfo resultingInfo;
	if (![delegate setTextEncoding:encoding forNoteNamed:filename matchingFileInfo:&snapshot.info
		expectedData:snapshot.data resultingFileInfo:&resultingInfo error:&error]) {
		[prepared release];
		return NO;
	}
	NVSetFileInfo(prepared, &resultingInfo);
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

- (BOOL)_updateFromData:(NSData*)data inFormat:(int)fmt
	preferredEncoding:(NSStringEncoding)preferredEncoding {
    
    if (!data) {
		NSLog(@"%@: Data is nil!", NSStringFromSelector(_cmd));
		return NO;
    }
	NSAssert(fmt != SingleDatabaseFormat,
		@"Warning! Tried to update data from a note in single-db format!");
    
	NSStringEncoding decodedEncoding = preferredEncoding;
	NSMutableAttributedString *attributedStringFromData =
		NVCreateDecodedContent(data, fmt, &decodedEncoding);
    
    if (!attributedStringFromData) {
		NSLog(@"Couldn't make string out of data for note %@ with format %d", titleString, fmt);
		return NO;
    }
    
	[contentString release];
	contentString = attributedStringFromData;
	fileEncoding = decodedEncoding;
	[contentString santizeForeignStylesForImporting];
	//[contentString setAttributedString:attributedStringFromData];
	contentCacheNeedsUpdate = YES;
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];
	
	[self updateTablePreviewString];
    
	//don't update the date modified here, as this could be old data
    
    return YES;
}

- (BOOL)updateFromData:(NSData*)data inFormat:(int)fmt {
	return [self _updateFromData:data inFormat:fmt preferredEncoding:fileEncoding];
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
	if (![delegate moveNoteToTrashNamed:filename resultingURL:NULL error:&error]) {
		if (([[error domain] isEqualToString:NSCocoaErrorDomain] &&
			[error code] == NSFileNoSuchFileError) ||
			([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == ENOENT))
			return YES;
		NSLog(@"Couldn't move file to trash: %@", error);
		return NO;
	}
	return YES;
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
	if (PlainTextFormat == storageFormat) {
		CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(fileEncoding);
		NSString *encodingName = (NSString*)CFStringConvertEncodingToIANACharSetName(cfEncoding);
		if (encodingName)
			encodingValue = [encodingName stringByAppendingFormat:@";%u", (unsigned int)cfEncoding];
	}
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

	NSMutableArray *cocoaTags = [NSMutableArray arrayWithCapacity:[tags count]];
	for (NSString *tag in tags) {
		NSUInteger length = [tag length];
		if (length >= 2 && [tag characterAtIndex:length - 2] == '\n' &&
			[tag characterAtIndex:length - 1] >= '0' && [tag characterAtIndex:length - 1] <= '7')
			[cocoaTags addObject:[tag substringToIndex:length - 2]];
		else [cocoaTags addObject:tag];
	}
	NSError *tagError = nil;
	if (![outputURL setResourceValue:cocoaTags forKey:NSURLTagNamesKey error:&tagError])
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
			[delegate note:self attributeChanged:NotePreviewString];
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
			delegate:nil format:SingleDatabaseFormat labels:labelString] autorelease];
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
		title:[titleString stringByAppendingString:@" (conflict)"] delegate:nil
		format:SingleDatabaseFormat labels:labelString] autorelease];
	[delegate addNotes:[NSArray arrayWithObject:conflict]];
	self.externalEditingConflictNote = conflict;
	self.externalEditingConflictData = data;
	if (![delegate makeNoteDurableForExternalEditing:conflict]) return NO;
	self.externalEditingConflictNote = nil;
	self.externalEditingConflictData = nil;
	return YES;
}

- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange {
	//opts indicate forwards or backwards, inRange allows us to continue from where we left off
	//return location of NSNotFound and length 0 if none of the words could be found inRange
	
	//an optimization would be to fall back on cached cString if contentsWere7Bit is true, but then we have to handle opts ourselves
	NSString *haystack = [contentString string];
	NSRange nextRange = NSMakeRange(NSNotFound, 0);
	for (NSString *word in words) {
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
