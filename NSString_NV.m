//
//  NSString_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "NSString_NV.h"
#import "NSData_transformations.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"

@implementation NSString (NV)

static int dayFromAbsoluteTime(CFAbsoluteTime absTime);

- (NSMutableSet*)labelSetFromWordsAndContainingNote:(NoteObject*)note {
	
	NSArray *words = [self componentsSeparatedByString:@","];
	NSMutableSet *labelSet = [NSMutableSet setWithCapacity:[words count]];
	
	unsigned int i;
	for (i=0; i<[words count]; i++) {
		NSString *aWord = [words objectAtIndex:i];
		
		if ([aWord length] > 0) {
			LabelObject *aLabel = [[LabelObject alloc] initWithTitle:aWord];
			[aLabel addNote:note];
			
			[labelSet addObject:aLabel];
			[aLabel autorelease];
		}
	}
	
	return labelSet; 
}

enum {NoSpecialDay = -1, ThisDay = 0, NextDay = 1, PriorDay = 2};

static const double dayInSeconds = 86400.0;
static CFTimeInterval secondsAfterGMT = 0.0;
static int currentDay = 0;
static CFMutableDictionaryRef dateStringsCache = NULL;

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime) {
	return (unsigned int)floor(absTime / 3600.0);
}

//should be called after midnight, and then all the notes should have their date-strings recomputed
void resetCurrentDayTime() {
    CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
    secondsAfterGMT = CFTimeZoneGetSecondsFromGMT(CFTimeZoneCopyDefault(), current);
    currentDay = (int)floor((current + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
	
	if (dateStringsCache)
		CFDictionaryRemoveAllValues(dateStringsCache);
}
//the epoch is defined at midnight GMT, so we have to convert from GMT to find the days

static int dayFromAbsoluteTime(CFAbsoluteTime absTime) {
    if (currentDay == 0)
	resetCurrentDayTime();
    
    int timeDay = (int)floor((absTime + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
    if (timeDay == currentDay) {
	return ThisDay;
    } else if (timeDay == currentDay + 1 /*dayInSeconds*/) {
	return NextDay;
    } else if (timeDay == currentDay - 1 /*dayInSeconds*/) {
	return PriorDay;
    }
    
    return NoSpecialDay;
}

+ (NSString*)relativeTimeStringWithDate:(CFDateRef)date relativeDay:(int)day {
    static CFDateFormatterRef timeOnlyFormatter = nil;
    static NSString *days[3] = { NULL };
    
    if (!timeOnlyFormatter) {
	timeOnlyFormatter = CFDateFormatterCreate(kCFAllocatorDefault, CFLocaleCopyCurrent(), kCFDateFormatterNoStyle, kCFDateFormatterShortStyle);
    }
    
    if (!days[ThisDay]) {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	days[ThisDay] = [[[[defaults stringArrayForKey:@"NSThisDayDesignations"] objectAtIndex:0] capitalizedString] retain];
	days[NextDay] = [[[[defaults stringArrayForKey:@"NSNextDayDesignations"] objectAtIndex:0] capitalizedString] retain];
	days[PriorDay] = [[[[defaults stringArrayForKey:@"NSPriorDayDesignations"] objectAtIndex:0] capitalizedString] retain];
    }

    CFStringRef dateString = CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, timeOnlyFormatter, date);
    
    NSString *relativeTimeString = [days[day] stringByAppendingFormat:@"  %@", dateString];
	CFRelease(dateString);
	
	return relativeTimeString;
}

int uncachedDateCount = 0;

//take into account yesterday/today thing
//this method _will_ affect application launch time
+ (NSString*)relativeDateStringWithAbsoluteTime:(CFAbsoluteTime)absTime {
	if (!dateStringsCache) {
		CFDictionaryKeyCallBacks keyCallbacks = { kCFTypeDictionaryKeyCallBacks.version, (CFDictionaryRetainCallBack)NULL, (CFDictionaryReleaseCallBack)NULL, 
			(CFDictionaryCopyDescriptionCallBack)NULL, (CFDictionaryEqualCallBack)NULL, (CFDictionaryHashCallBack)NULL };
		dateStringsCache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
	}
	NSInteger minutesCount = (NSInteger)((NSInteger)absTime / 60);
	
	NSString *dateString = (NSString*)CFDictionaryGetValue(dateStringsCache, (const void *)minutesCount);
	
	if (!dateString) {
		static CFDateFormatterRef formatter = nil;
		if (!formatter) {
			formatter = CFDateFormatterCreate(kCFAllocatorDefault, CFLocaleCopyCurrent(), kCFDateFormatterMediumStyle, kCFDateFormatterShortStyle);
		}
		
		CFDateRef date = CFDateCreate(kCFAllocatorDefault, absTime);
		
		
		int day = dayFromAbsoluteTime(absTime);
		if (day == NoSpecialDay) {
			dateString = [(NSString*)CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, formatter, date) autorelease];
		} else {
			dateString = [NSString relativeTimeStringWithDate:date relativeDay:day];
		}
		
		CFRelease(date);

		uncachedDateCount++;
		
		//ints as pointers ints as pointers ints as pointers
		CFDictionarySetValue(dateStringsCache, (const void *)minutesCount, (const void *)dateString);
	}
	
    return dateString;
}

+ (NSString*)pathCopiedFromAliasData:(NSData*)aliasData {
    AliasHandle inAlias;
    CFStringRef path = NULL;
	FSAliasInfoBitmap whichInfo = kFSAliasInfoNone;
	FSAliasInfo info;
    if (aliasData && PtrToHand([aliasData bytes], (Handle*)&inAlias, [aliasData length]) == noErr && 
	FSCopyAliasInfo(inAlias, NULL, NULL, &path, &whichInfo, &info) == noErr) {
		//this method doesn't always seem to work	
	return [(NSString*)path autorelease];
    }
    
    return nil;
}

- (CFArrayRef)copyRangesOfWordsInString:(NSString*)findString inRange:(NSRange)limitRange {
	CFStringRef quoteStr = CFSTR("\"");
	CFRange quoteRange = CFStringFind((CFStringRef)findString, quoteStr, 0);
	CFArrayRef terms = CFStringCreateArrayBySeparatingStrings(NULL, (CFStringRef)findString, 
															  quoteRange.location == kCFNotFound ? CFSTR(" ") : quoteStr);
	if (terms) {
		CFIndex termIndex;
		CFMutableArrayRef allRanges = NULL;
		
		for (termIndex = 0; termIndex < CFArrayGetCount(terms); termIndex++) {
			CFStringRef term = CFArrayGetValueAtIndex(terms, termIndex);
			if (CFStringGetLength(term) > 0) {
				CFArrayRef ranges = CFStringCreateArrayWithFindResults(NULL, (CFStringRef)self, term, CFRangeMake(limitRange.location,limitRange.length), kCFCompareCaseInsensitive);
				
				if (ranges) {
					if (!allRanges) {
						//to make sure we get the right cfrange callbacks
						allRanges = CFArrayCreateMutableCopy(NULL, 0, ranges);
					} else {
						CFArrayAppendArray(allRanges, ranges, CFRangeMake(0, CFArrayGetCount(ranges)));
					}
					CFRelease(ranges);
				}
			}
		}
		//should sort them all now by location
		//CFArraySortValues(allRanges, CFRangeMake(0, CFArrayGetCount(allRanges)), <#CFComparatorFunction comparator#>,<#void * context#>);
		CFRelease(terms);
		return allRanges;
	}
	
	return NULL;
}

+ (NSString*)customPasteboardTypeOfCode:(int)code {
	//returns something like CorePasteboardFlavorType 0x4D5A0003
	return [NSString stringWithFormat:@"CorePasteboardFlavorType 0x%X", code];
}

- (NSString*)stringAsSafePathExtension {
	return [self stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"./*: \t\n\r"]];
}

- (NSString*)filenameExpectingAdditionalCharCount:(int)charCount {
	NSString *newfilename = self;
	if ([self length] + charCount > 255)
		newfilename = [self substringToIndex: 255 - charCount];

	return newfilename;
}

- (NSMutableString*)stringByReplacingOccurrencesOfString:(NSString*)stringToReplace withString:(NSString*)replacementString {
	NSMutableString *sanitizedName = [NSMutableString stringWithString:self];
	[sanitizedName replaceOccurrencesOfString:stringToReplace withString:replacementString options:NSLiteralSearch range:NSMakeRange(0, [sanitizedName length])];

	return sanitizedName;
}

- (NSString*)fourCharTypeString {
	if ([[self dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] length] >= 4) {
		//only truncate; don't return a string containing null characters for the last few bytes
		OSType type = UTGetOSTypeFromString((CFStringRef)self);
		return [(id)UTCreateStringForOSType(type) autorelease];
	}
	return self;
}

- (void)copyItemToPasteboard:(id)sender {
	
	if ([sender isKindOfClass:[NSMenuItem class]]) {
		NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
		[pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
		[pasteboard setString:[sender representedObject] forType:NSStringPboardType];
	}
}


- (NSURL*)linkForWord {
	//full of annoying little hacks to catch (hopefully) the most common non-links
	NSUInteger length = [self length];
	
	NSUInteger protocolSpecLoc = [self rangeOfString:@"://" options:NSLiteralSearch].location;
	if (length >= 5 && protocolSpecLoc != NSNotFound && protocolSpecLoc > 0) {
		NSURL *anurl = [NSURL URLWithString:self];
		//File Reference URLs cannot be safely archived!
		if ([anurl isFileURL] && [self rangeOfString:@"/.file/" options:NSLiteralSearch].location != NSNotFound) return nil;
		return anurl;
	}
	
	if (length >= 12 && [self rangeOfString:@"mailto:" options:NSAnchoredSearch | NSLiteralSearch].location != NSNotFound)
		return [NSURL URLWithString:self];
	
	if (length >= 5 && [self rangeOfString:@"www." options:NSAnchoredSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, length)].location != NSNotFound) {
		//if string starts with www., and is long enough to contain one other character, prefix URL with http://
		return [NSURL URLWithString:[@"http://" stringByAppendingString:self]];
	}
	
	if (length >= 5) {
		NSUInteger atSignLoc = [self rangeOfString:@"@" options:NSLiteralSearch].location;
		if (atSignLoc != NSNotFound && atSignLoc > 0) {
			//if we contain an @, but do not start with one, and have a period somewhere after the @ but not at the end, then make it an email address
			
			NSUInteger periodLoc = [self rangeOfString:@"." options:NSLiteralSearch range:NSMakeRange(atSignLoc, length - atSignLoc)].location;
			if (periodLoc != NSNotFound && periodLoc > atSignLoc + 1 && periodLoc != length - 1) {
				
				//make sure it's not some kind of SCP or CVS path
				if ([self rangeOfString:@":/" options:NSLiteralSearch].location == NSNotFound)
					return [NSURL URLWithString:[@"mailto:" stringByAppendingString:self]];	
			}
		}
	}
	
	return nil;
}

- (NSString*)syntheticTitle {
	//grab first five words of first line of receiver

    NSMutableString *titleText = [NSMutableString stringWithString:[self stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
	
	//handle mac linefeeds
	[titleText replaceOccurrencesOfString:@"\r" withString:@"\n" options:NSLiteralSearch range:NSMakeRange(0, [titleText length])];
	NSArray *lines = [titleText componentsSeparatedByString:@"\n"];
	
    if (![titleText length] || ![lines count]) {
		//note contains no useful information
		return NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
	}
	
	NSArray *words = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
	return [[words subarrayWithRange:NSMakeRange(0U, MIN(5U, [words count]))] componentsJoinedByString:@" "];
}

- (NSAttributedString*)attributedPreviewFromBodyText:(NSAttributedString*)bodyText {
	//first line? first x words? first x characters?
	
	//NSLog(@"gen prev for %@", [[bodyText string] substringToIndex:MIN([bodyText length], 10U)]);
#if 0
	static NSDictionary *blackTextAttributes = nil;
	if (!blackTextAttributes) {
		NSMutableParagraphStyle *lineBreaksStyle = [[NSMutableParagraphStyle alloc] init];
		[lineBreaksStyle setLineBreakMode:NSLineBreakByClipping];

		blackTextAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:
			/*[NSColor blackColor], NSForegroundColorAttributeName,*/
			lineBreaksStyle, NSParagraphStyleAttributeName, nil] retain];
		
		[lineBreaksStyle release];
	}
#endif
	
	static NSDictionary *grayTextAttributes = nil;
	if (!grayTextAttributes) {
		NSMutableParagraphStyle *lineBreaksStyle = [[NSMutableParagraphStyle alloc] init];
		[lineBreaksStyle setLineBreakMode:NSLineBreakByCharWrapping];

		grayTextAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:
			[NSColor grayColor], NSForegroundColorAttributeName,
			lineBreaksStyle, NSParagraphStyleAttributeName, nil] retain];
		
		[lineBreaksStyle release];
	}
	
	NSString *bodyString = [bodyText string];
	//attempt to get at underlying string, copy up to N characters, skipping tabs and spaces
	
	NSScanner *scanner = [NSScanner scannerWithString:bodyString];
	static NSCharacterSet *lineFeedSet = nil;
	if (!lineFeedSet) lineFeedSet = [[NSCharacterSet characterSetWithCharactersInString:@"\n\r"] retain];
	
	NSString *firstLine = nil;
	[scanner scanCharactersFromSet:lineFeedSet intoString:&firstLine];

	NSString *delimiter = NSLocalizedString(@" option-shift-dash ", @"title/description delimiter");
	NSString *syntheticTitle = [delimiter stringByAppendingString:firstLine ? firstLine : bodyString];
	syntheticTitle = [syntheticTitle substringToIndex:MIN([syntheticTitle length], 100U)];
	NSAttributedString *bodySummary = [[NSAttributedString alloc] initWithString:syntheticTitle attributes:grayTextAttributes];
	
	NSMutableAttributedString *attributedStringPreview = [[NSMutableAttributedString alloc] initWithString:self];
	[attributedStringPreview appendAttributedString:bodySummary];
	
	[bodySummary release];
	
	return [attributedStringPreview autorelease];
}

//the following three methods + function come courtesy of Mike Ferris' TextExtras
+ (NSString *)tabbifiedStringWithNumberOfSpaces:(unsigned)origNumSpaces tabWidth:(unsigned)tabWidth usesTabs:(BOOL)usesTabs {
	static NSMutableString *sharedString = nil;
	static unsigned numTabs = 0;
    static unsigned numSpaces = 0;
	
    int diffInTabs;
    int diffInSpaces;
	
    // TabWidth of 0 means don't use tabs!
    if (!usesTabs || (tabWidth == 0)) {
        diffInTabs = 0 - numTabs;
        diffInSpaces = origNumSpaces - numSpaces;
    } else {
        diffInTabs = (origNumSpaces / tabWidth) - numTabs;
        diffInSpaces = (origNumSpaces % tabWidth) - numSpaces;
    }
    
    if (!sharedString) {
        sharedString = [[NSMutableString alloc] init];
    }
    
    if (diffInTabs < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(0, -diffInTabs)];
    } else {
        unsigned numToInsert = diffInTabs;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(0, 0) withString:@"\t"];
            numToInsert--;
        }
    }
    numTabs += diffInTabs;
	
    if (diffInSpaces < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(numTabs, -diffInSpaces)];
    } else {
        unsigned numToInsert = diffInSpaces;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(numTabs, 0) withString:@" "];
            numToInsert--;
        }
    }
    numSpaces += diffInSpaces;
	
    return sharedString;
}

- (unsigned)numberOfLeadingSpacesFromRange:(NSRange*)range tabWidth:(unsigned)tabWidth {
    // Returns number of spaces, accounting for expanding tabs.
    NSRange searchRange = (range ? *range : NSMakeRange(0, [self length]));
    unichar buff[100];
    unsigned i = 0;
    unsigned spaceCount = 0;
    BOOL done = NO;
    unsigned tabW = tabWidth;
    NSUInteger endOfWhiteSpaceIndex = NSNotFound;
	
    if (!range || range->length == 0) {
        return 0;
    }
    
    while ((searchRange.length > 0) && !done) {
        [self getCharacters:buff range:NSMakeRange(searchRange.location, ((searchRange.length > 100) ? 100 : searchRange.length))];
        for (i=0; i < ((searchRange.length > 100) ? 100 : searchRange.length); i++) {
            if (buff[i] == (unichar)' ') {
                spaceCount++;
            } else if (buff[i] == (unichar)'\t') {
                // MF:!!! Perhaps this should account for the case of 2 spaces follwed by a tab really being visually equivalent to 8 spaces (for 8 space tabs) and not 10 spaces.
                spaceCount += tabW;
            } else {
                done = YES;
                endOfWhiteSpaceIndex = searchRange.location + i;
                break;
            }
        }
        searchRange.location += ((searchRange.length > 100) ? 100 : searchRange.length);
        searchRange.length -= ((searchRange.length > 100) ? 100 : searchRange.length);
    }
    if (range && (endOfWhiteSpaceIndex != NSNotFound)) {
        range->length = endOfWhiteSpaceIndex - range->location;
    }
    return spaceCount;
}

BOOL IsHardLineBreakUnichar(unichar uchar, NSString *str, unsigned charIndex) {
    // This function redundantly takes both the character and the string and index.  This is because often we only have to look at that one character and usually we already have it when this is called (usually from a source cheaper than characterAtIndex: too.)
    // Returns yes if the unichar given is a hard line break, that is it will always cause a new line fragment to begin.
    // MF:??? Is this test complete?
    if ((uchar == (unichar)'\n') || (uchar == NSParagraphSeparatorCharacter) || (uchar == NSLineSeparatorCharacter)) {
        return YES;
    } else if ((uchar == (unichar)'\r') && ((charIndex + 1 >= [str length]) || ([str characterAtIndex:charIndex + 1] != (unichar)'\n'))) {
        return YES;
    }
    return NO;
}

- (char*)copyLowercaseASCIIString {
	
	const char *cstringPtr = NULL;
	
	//here we are making assumptions (based on observations and CFString.c) about the implementation of CFStringGetCStringPtr:
	//with a non-western language preference, kCFStringEncodingASCII or another Latin variant must be used instead of kCFStringEncodingMacRoman
	if ((cstringPtr = CFStringGetCStringPtr((CFStringRef)self, kCFStringEncodingMacRoman)) ||
		(cstringPtr = CFStringGetCStringPtr((CFStringRef)self, kCFStringEncodingASCII))) {
		
		size_t length = [self length] + 1;
		char *cstringBuffer = (char*)malloc(length);
		//should include NULL terminator
		memcpy(cstringBuffer, cstringPtr, length);
		MakeLowercase(cstringBuffer);
		
		return cstringBuffer;
	} else {
		//will be true on Snow Leopard for empty strings
		//NSLog(@"found string that should have been 7 bit, but (apparently) is not.");
	}
	
	return NULL;
}

- (const char*)lowercaseUTF8String {
	
	CFMutableStringRef str2 = CFStringCreateMutableCopy(NULL, 0, (CFStringRef)self);
	CFStringLowercase(str2, NULL);
	
	const char *utf8String = [(NSString*)str2 UTF8String];
	
	CFRelease(str2);
	return utf8String;
}

+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err {
	static NSDictionary *reasons = nil;
	if (!reasons) {
		NSString *path = [[NSBundle mainBundle] pathForResource:@"CarbonErrorStrings" ofType:@"plist"];
		reasons = [[NSDictionary dictionaryWithContentsOfFile:path] retain];
	}
	
	return [reasons objectForKey:[[NSNumber numberWithInt:(int)err] stringValue]];
}

+ (NSString*)pathWithFSRef:(FSRef*)fsRef {
	NSString *path = nil;
	
	const UInt32 maxPathSize = 8 * 1024;
	UInt8 *convertedPath = (UInt8*)malloc(maxPathSize * sizeof(UInt8));
	if (FSRefMakePath(fsRef, convertedPath, maxPathSize) == noErr) {
		path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:(char*)convertedPath length:strlen((char*)convertedPath)];
	}
	free(convertedPath);
	
	return path;
}


- (BOOL)UTIOfFileConformsToType:(NSString*)type {
	if (!RunningTigerAppKitOrHigher) return NO;
	
	CFStringRef fileUTI = NULL;
	FSRef fileRef;
	if (FSPathMakeRef((const UInt8 *)[self fileSystemRepresentation], &fileRef, NULL) == noErr) {
		if (LSCopyItemAttribute(&fileRef, kLSRolesAll, kLSItemContentType, (CFTypeRef*)&fileUTI) == noErr) {
			if (fileUTI) {
				BOOL conforms = UTTypeConformsTo(fileUTI, (CFStringRef)type);
				CFRelease(fileUTI);
				return conforms;
			}
		}
	}
	return NO;
}

//TODO: use volumeCapabilities in FSExchangeObjectsCompat.c to skip some work on volumes for which we know we would receive ENOTSUP
//for +setTextEncodingAttribute:atFSPath: and +textEncodingAttributeOfFSPath: (test against VOL_CAP_INT_EXTENDED_ATTR)

+ (BOOL)setTextEncodingAttribute:(NSStringEncoding)encoding atFSPath:(const char*)path {
	if (!path) return NO;
	
	CFStringEncoding cfStringEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
	if (cfStringEncoding == kCFStringEncodingInvalidId) {
		NSLog(@"%s: encoding %lu is invalid!", _cmd, encoding);
		return NO;
	}
	NSString *textEncStr = [(NSString *)CFStringConvertEncodingToIANACharSetName(cfStringEncoding) stringByAppendingFormat:@";%@", 
							[[NSNumber numberWithInt:cfStringEncoding] stringValue]];
	const char *textEncUTF8Str = [textEncStr UTF8String];
	
	if (setxattr(path, "com.apple.TextEncoding", textEncUTF8Str, strlen(textEncUTF8Str), 0, 0) < 0) {
		NSLog(@"couldn't set text encoding attribute of %s to '%s': %d", path, textEncUTF8Str, errno);
		return NO;
	}
	return YES;
}

+ (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path {
	if (!path) goto errorReturn;
	
	//We could query the size of the attribute, but that would require a second system call
	//and the value for this key shouldn't need to be anywhere near this large, anyway.
	//It could be, but it probably won't. If it is, then we won't get the encoding. Too bad.
	char xattrValueBytes[128] = { 0 };
	if (getxattr(path, "com.apple.TextEncoding", xattrValueBytes, sizeof(xattrValueBytes), 0, 0) < 0) {
		if (ENOATTR != errno) NSLog(@"couldn't get text encoding attribute of %s: %d", path, errno);
		goto errorReturn;
	}
	NSString *encodingStr = [NSString stringWithUTF8String:xattrValueBytes];
	if (!encodingStr) {
		NSLog(@"couldn't make attribute data from %s into a string", path);
		goto errorReturn;
	}
	NSArray *segs = [encodingStr componentsSeparatedByString:@";"];
	
	if ([segs count] >= 2 && [[segs objectAtIndex:1] length] > 1) {
		return CFStringConvertEncodingToNSStringEncoding([[segs objectAtIndex:1] intValue]);
	} else if ([[segs objectAtIndex:0] length] > 1) {
		CFStringEncoding theCFEncoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)[segs objectAtIndex:0]);
		if (theCFEncoding == kCFStringEncodingInvalidId) {
			NSLog(@"couldn't convert IANA charset");
			goto errorReturn;
		}
		return CFStringConvertEncodingToNSStringEncoding(theCFEncoding);
	}
	
errorReturn:
	return 0;
}


- (CFUUIDBytes)uuidBytes {
	CFUUIDBytes bytes = {0};
	CFUUIDRef uuidRef = CFUUIDCreateFromString(NULL, (CFStringRef)self);
	if (uuidRef) {
		bytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
	}

	return bytes;
}

+ (NSString*)uuidStringWithBytes:(CFUUIDBytes)bytes {
	CFUUIDRef uuidRef = CFUUIDCreateFromUUIDBytes(NULL, bytes);
	CFStringRef uuidString = NULL;
	
	if (uuidRef) {
		uuidString = CFUUIDCreateString(NULL, uuidRef);
		CFRelease(uuidRef);
	}
	
	return [(NSString*)uuidString autorelease];	
}

/*
- (NSTextView*)getTextViewWithFrame:(NSRect*)theFrame {
    NSTextContainer *textContainer;
    NSAttributedString *attribtedString = [[NSMutableAttributedString alloc] initWithString:self];
    NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:attribtedString];
    
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    [textStorage addLayoutManager:layoutManager];
    [layoutManager release];
    
    textContainer = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(theFrame->size.width, FLT_MAX)];
    [layoutManager addTextContainer:textContainer];
    [textContainer release];
    
    (void)[layoutManager glyphRangeForTextContainer:textContainer]; //force layout
    
    //[textContainer setContainerSize:NSMakeSize([textContainer containerSize].width,[layoutManager usedRectForTextContainer:textContainer].size.height)];
  
    NSScrollView *scrollview = [[NSScrollView alloc] initWithFrame:*theFrame];
    NSSize contentSize = [scrollview contentSize];
    
    [scrollview setBorderType:NSNoBorder];
    [scrollview setHasVerticalScroller:YES];
    [scrollview setHasHorizontalScroller:NO];
    [scrollview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    //NSTextView *textView = [[NSTextView alloc] initWithFrame:theFrame textContainer:textContainer];
    theTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height) textContainer:textContainer];
    [theTextView setMinSize:NSMakeSize(0.0, contentSize.height)];
    [theTextView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [theTextView setVerticallyResizable:YES];
    [theTextView setHorizontallyResizable:NO];
    
    [theTextView setAutoresizingMask:NSViewWidthSizable];
    [textContainer setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
    [textContainer setWidthTracksTextView:YES];
    
    return textView;
}
*/
@end


@implementation NSMutableString (NV)

+ (NSMutableString*)newShortLivedStringFromFile:(NSString*)filename {
	NSStringEncoding anEncoding = NSMacOSRomanStringEncoding; //won't use this, doesn't matter
	
	return [self newShortLivedStringFromData:[NSMutableData dataWithContentsOfFile:filename options:NSUncachedRead error:NULL] 
						   ofGuessedEncoding:&anEncoding withPath:[filename fileSystemRepresentation] orWithFSRef:NULL];
}

+ (NSMutableString*)newShortLivedStringFromData:(NSMutableData*)data ofGuessedEncoding:(NSStringEncoding*)encoding withPath:(const char*)aPath orWithFSRef:(const FSRef*)fsRef{
	//this will fail if data lacks a BOM, but try it first as it's the fastest check
	NSMutableString* stringFromData = [data newStringUsingBOMReturningEncoding:encoding];
	if (stringFromData) {
		return stringFromData;
	}
	
	//TODO: there are some false positives for UTF-8 detection; e.g., the MacOSRoman-encoded copyright symbol
	
	//if it's just 7-bit ASCII, jump straight to the fastest encoding; don't even try UTF-8 (but report UTF-8, anyway)
	BOOL hasHighASCII = ContainsHighAscii([data bytes], [data length]);
	CFStringEncoding cfasciiEncoding = CFStringGetSystemEncoding() == kCFStringEncodingMacRoman ? kCFStringEncodingMacRoman : kCFStringEncodingASCII;
	NSStringEncoding firstEncodingToTry = hasHighASCII ? NSUTF8StringEncoding : CFStringConvertEncodingToNSStringEncoding(cfasciiEncoding);
	
#define AddIfUnique(enc) if (!ContainsUInteger(encodingsToTry, encodingIndex, (enc))) encodingsToTry[encodingIndex++] = (enc)
	
	NSStringEncoding encodingsToTry[5];
	NSUInteger encodingIndex = 0;
	
	AddIfUnique(firstEncodingToTry);
	
	if (hasHighASCII && RunningTigerAppKitOrHigher) {
		//check the file on disk for extended attributes only if absolutely necessary
		NSStringEncoding extendedAttrsEncoding = 0;
		if (!aPath && fsRef && !IsZeros(fsRef, sizeof(FSRef))) {
			NSMutableData *pathData = [NSMutableData dataWithLength:4 * 1024];
			if (FSRefMakePath(fsRef, [pathData mutableBytes], [pathData length]) == noErr)
				extendedAttrsEncoding = [NSString textEncodingAttributeOfFSPath:[pathData bytes]];
		} else if (aPath) {
			extendedAttrsEncoding = [NSString textEncodingAttributeOfFSPath:aPath];
		}
		if (extendedAttrsEncoding) AddIfUnique(extendedAttrsEncoding);
	}
	AddIfUnique(*encoding);
	NSStringEncoding systemEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
	AddIfUnique(systemEncoding);
	AddIfUnique(NSMacOSRomanStringEncoding);
	
	encodingIndex = 0;
	do {
		if (RunningTigerAppKitOrHigher) {
			stringFromData = [[NSMutableString alloc] initWithBytesNoCopy:[data mutableBytes] length:[data length] 
																 encoding:encodingsToTry[encodingIndex] freeWhenDone:NO];
		} else {
			stringFromData = [[NSMutableString alloc] initWithData:data encoding:encodingsToTry[encodingIndex]];
		}
	} while (!stringFromData && ++encodingIndex < 5);
		
	if (stringFromData) {
		NSAssert(encodingIndex < 5, @"got valid string from data, but encodingIndex is too high!");
		//report ASCII files as UTF-8 data in case this encoding will be used for future writes of a note
		*encoding = hasHighASCII ? encodingsToTry[encodingIndex] : NSUTF8StringEncoding;
		return stringFromData;
	}
		
	return nil;
}

@end


@implementation NSEvent (NV)

- (unichar)firstCharacter {
	NSString *chars = [self characters];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

- (unichar)firstCharacterIgnoringModifiers {
	NSString *chars = [self charactersIgnoringModifiers];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

@end
