//
//  NSString_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.

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

#import "NSString_NV.h"
#import "NSData_transformations.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"

@implementation NSString (NV)

static int dayFromAbsoluteTime(CFAbsoluteTime absTime);

enum {NoSpecialDay = -1, ThisDay = 0, NextDay = 1, PriorDay = 2};

static const double dayInSeconds = 86400.0;
static CFTimeInterval secondsAfterGMT = 0.0;
static int currentDay = 0;
static CFMutableDictionaryRef dateStringsCache = NULL;
static CFDateFormatterRef dateAndTimeFormatter = NULL;

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime) {
	return (unsigned int)floor(absTime / 3600.0);
}

//should be called after midnight, and then all the notes should have their date-strings recomputed
void resetCurrentDayTime() {
    CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
    
    CFTimeZoneRef timeZone = CFTimeZoneCopyDefault();
    secondsAfterGMT = CFTimeZoneGetSecondsFromGMT(timeZone, current);
    
    currentDay = (int)floor((current + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
	
	if (dateStringsCache)
		CFDictionaryRemoveAllValues(dateStringsCache);
	
	if (dateAndTimeFormatter) {
		CFRelease(dateAndTimeFormatter);
		dateAndTimeFormatter = NULL;
	}
		
	CFRelease(timeZone);
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
		days[ThisDay] = [NSLocalizedString(@"Today", nil) retain];
		days[NextDay] = [NSLocalizedString(@"Tomorrow", nil) retain];
		days[PriorDay] = [NSLocalizedString(@"Yesterday", nil) retain];
    }

    CFStringRef dateString = CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, timeOnlyFormatter, date);
	
	if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
		//if today, return the time only; otherwise say "Yesterday", etc.; and this method shouldn't be called unless day != NoSpecialDay
		if (day == PriorDay || day == NextDay)
			return days[day];
		return [(id)dateString autorelease];
	}
    
    NSString *relativeTimeString = [days[day] stringByAppendingFormat:@"  %@", dateString];
	CFRelease(dateString);
	
	return relativeTimeString;
}

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
		int day = dayFromAbsoluteTime(absTime);
		
		if (!dateAndTimeFormatter) {
			BOOL horiz = [[GlobalPrefs defaultPrefs] horizontalLayout];
			dateAndTimeFormatter = CFDateFormatterCreate(kCFAllocatorDefault, CFLocaleCopyCurrent(), 
														 horiz ? kCFDateFormatterShortStyle : kCFDateFormatterMediumStyle, 
														 horiz ? kCFDateFormatterNoStyle : kCFDateFormatterShortStyle);
		}
		
		CFDateRef date = CFDateCreate(kCFAllocatorDefault, absTime);
		
		if (day == NoSpecialDay) {
			dateString = [(NSString*)CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, dateAndTimeFormatter, date) autorelease];
		} else {
			dateString = [NSString relativeTimeStringWithDate:date relativeDay:day];
		}
		
		CFRelease(date);
		
		//ints as pointers ints as pointers ints as pointers
		CFDictionarySetValue(dateStringsCache, (const void *)minutesCount, (const void *)dateString);
	}
	
    return dateString;
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
CFDateFormatterRef simplenoteDateFormatter(int lowPrecision) {
	//CFStringRef dateStr = CFSTR("2010-01-02 23:23:31.876229");
	static CFDateFormatterRef dateFormatter = NULL;
	static CFDateFormatterRef lowPrecisionDateFormatter = NULL;
	static CFLocaleRef locale = NULL;
	static CFTimeZoneRef zone = NULL;
	if (!dateFormatter) {
		locale = CFLocaleCreate(NULL,CFSTR("en"));
		zone = CFTimeZoneCreateWithTimeIntervalFromGMT(NULL, 0.0);		
		dateFormatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
		lowPrecisionDateFormatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
		CFDateFormatterSetFormat(dateFormatter, CFSTR("yyyy-MM-dd HH:mm:ss.SSSSSS"));
		CFDateFormatterSetFormat(lowPrecisionDateFormatter, CFSTR("yyyy-MM-dd HH:mm:ss"));
		CFDateFormatterSetProperty(dateFormatter, kCFDateFormatterTimeZone, zone);
		CFDateFormatterSetProperty(lowPrecisionDateFormatter, kCFDateFormatterTimeZone, zone);
	}
	return lowPrecision ? lowPrecisionDateFormatter	: dateFormatter;
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
+ (NSString*)simplenoteDateWithAbsoluteTime:(CFAbsoluteTime)absTime {
	CFStringRef str = CFDateFormatterCreateStringWithAbsoluteTime(NULL, simplenoteDateFormatter(0), absTime);
	return [(id)str autorelease];
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
- (CFAbsoluteTime)absoluteTimeFromSimplenoteDate {
	
	CFAbsoluteTime absTime = 0;
	if (!CFDateFormatterGetAbsoluteTimeFromString(simplenoteDateFormatter(0), (CFStringRef)self, NULL, &absTime)) {
		if (!CFDateFormatterGetAbsoluteTimeFromString(simplenoteDateFormatter(1), (CFStringRef)self, NULL, &absTime)) {
			NSLog(@"can't get date from %@; returning current time instead", self);
			return 0;
		}
	}
	return absTime;
}

- (NSArray*)labelCompatibleWords {
	NSArray *array = nil;
	if (IsLeopardOrLater) {
		array = [self componentsSeparatedByCharactersInSet:[NSCharacterSet labelSeparatorCharacterSet]];
	} else {
		BOOL lacksSpace = [self rangeOfString:@" " options:NSLiteralSearch].location == NSNotFound;
		array = [self componentsSeparatedByString: lacksSpace ? @"," : @" "];
	}
	NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[array count]];
	
	NSUInteger i;
	for (i=0; i<[array count]; i++) {
		NSString *aWord = [array objectAtIndex:i];
		if ([aWord length] > 0) {
			[titles addObject:aWord];
		}
	}
	return titles;
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

- (BOOL)isAMachineDirective {
	return [self hasPrefix:@"#!"] || [self hasPrefix:@"#import "] || [self hasPrefix:@"#include "] || 
	[self hasPrefix:@"<!DOCTYPE "] || [self hasPrefix:@"<?xml "] || [self hasPrefix:@"<html "] || 
	[self hasPrefix:@"@import "] || [self hasPrefix:@"<?php"] || [self hasPrefix:@"bplist0"]; 
	
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
- (NSString*)stringByReplacingOccurrencesOfString:(NSString*)stringToReplace withString:(NSString*)replacementString {
	//NSLog(@"NSString_NV: %s", _cmd);
	NSMutableString *sanitizedName = [[self mutableCopy] autorelease];
	[sanitizedName replaceOccurrencesOfString:stringToReplace withString:replacementString options:NSLiteralSearch range:NSMakeRange(0, [sanitizedName length])];

	return sanitizedName;
}
#endif

- (NSString*)fourCharTypeString {
	if ([[self dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] length] >= 4) {
		//only truncate; don't return a string containing null characters for the last few bytes
		OSType type = UTGetOSTypeFromString((CFStringRef)self);
		return [(id)UTCreateStringForOSType(type) autorelease];
	}
	return self;
}

- (BOOL)superficiallyResemblesAnHTTPURL {
	//has the right protocol and contains no whitespace or line breaks
	
	return ([self rangeOfString:@"http" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound ||
			[self rangeOfString:@"https" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) &&
	[self rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] options:NSLiteralSearch].location == NSNotFound;
}

- (void)copyItemToPasteboard:(id)sender {
	
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
	[pasteboard setString:[sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : self
				  forType:NSStringPboardType];
}


- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc maxTitleLen:(NSUInteger)maxTitleLen {
	return [self syntheticTitleAndSeparatorWithContext:sepStr bodyLoc:bodyLoc oldTitle:nil maxTitleLen:maxTitleLen];
}

- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc 
										  oldTitle:(NSString*)oldTitle maxTitleLen:(NSUInteger)maxTitleLen {
	
	//break string into pieces for turning into a note
	//find the first line, whitespace or no whitespace
	
	NSCharacterSet *titleDelimiters = [NSCharacterSet characterSetWithCharactersInString:
											  [NSString stringWithFormat:@"\n\r\t%C%C", NSLineSeparatorCharacter, NSParagraphSeparatorCharacter]];
	
	NSScanner *scanner = [NSScanner scannerWithString:self];
	[scanner setCharactersToBeSkipped:[[[NSMutableCharacterSet alloc] init] autorelease]];
	
	//skip any blank space before the title; this will not be preserved for round-tripped syncing
	BOOL didSkipInitialWS = [scanner scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:NULL];
	
	if ([oldTitle length] > maxTitleLen) {
		//break apart the string based on an existing title (if it still matches) that would have been longer than our default truncation limit
		
		NSString *contentStartStr = didSkipInitialWS && [scanner scanLocation] < [self length] ? [self substringFromIndex:[scanner scanLocation]] : self;
		if ([contentStartStr length] >= [oldTitle length] && [contentStartStr hasPrefix:oldTitle]) {
			
			[scanner setScanLocation:[oldTitle length] + (didSkipInitialWS ? [scanner scanLocation] : 0)];
			[scanner scanContextualSeparator:sepStr withPrecedingString:oldTitle];
			if (bodyLoc) *bodyLoc = [scanner scanLocation];
			return oldTitle;
		}
	}
	
	//grab the title
	NSString *firstLine = nil;
	[scanner scanUpToCharactersFromSet:titleDelimiters intoString:&firstLine];
	
	if ([firstLine length] > maxTitleLen) {
		//what if this title is too long? then we need to break it up and start the body after that
		NSRange lastSpaceInFirstLine = [firstLine rangeOfString:@" " options: NSBackwardsSearch | NSLiteralSearch
														  range:NSMakeRange(maxTitleLen - 10, 10)];
		if (lastSpaceInFirstLine.location == NSNotFound) {
			lastSpaceInFirstLine.location = maxTitleLen;
		}
		[scanner setScanLocation:[scanner scanLocation] - ([firstLine length] - lastSpaceInFirstLine.location)];
		firstLine = [firstLine substringToIndex:lastSpaceInFirstLine.location];
		
		[scanner scanContextualSeparator:sepStr withPrecedingString:firstLine];		
		if (bodyLoc) *bodyLoc = [scanner scanLocation];
		return firstLine;
	}
	
	//grab blank space between the title and the body; common case:
	[scanner scanContextualSeparator:sepStr withPrecedingString:firstLine];
	if (bodyLoc) *bodyLoc = [scanner scanLocation];
	
	return [firstLine length] ? firstLine : NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
}

- (NSString*)syntheticTitleAndTrimmedBody:(NSString**)newBody {
	NSUInteger bodyLoc = 0;
	NSString *title = [self syntheticTitleAndSeparatorWithContext:NULL bodyLoc:&bodyLoc maxTitleLen:60];
	if (newBody) *newBody = [self substringFromIndex:bodyLoc];
	return title;
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
		
		size_t length = [self length];
		char *cstringBuffer = (char*)malloc(length + 1);
		//modp will add the NULL terminator
		modp_tolower_copy(cstringBuffer, cstringPtr, length);
		
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

- (NSString *)stringByReplacingPercentEscapes {
    return [(NSString*) CFURLCreateStringByReplacingPercentEscapes(NULL, (CFStringRef) self, CFSTR("")) autorelease];
}

- (NSString*)stringWithPercentEscapes {
	return [(NSString *) CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)[[self mutableCopy] autorelease], NULL, CFSTR("=,!$&'()*+;@?\n\"<>#\t :/"),kCFStringEncodingUTF8) autorelease];
}

+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err {
	static NSDictionary *reasons = nil;
	if (!reasons) {
		NSString *path = [[NSBundle mainBundle] pathForResource:@"CarbonErrorStrings" ofType:@"plist"];
		reasons = [[NSDictionary dictionaryWithContentsOfFile:path] retain];
	}
	
	NSString *reason = [reasons objectForKey:[[NSNumber numberWithInt:(int)err] stringValue]];
	if (!reason)
		return [NSString stringWithFormat:NSLocalizedString(@"an error of type %d occurred", @"string of last resort for errors not found in CarbonErrorStrings"), (int)err];
	return reason;
}

- (BOOL)UTIOfFileConformsToType:(NSString*)type {
	
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


- (NSData *)decodeBase64 {
    return [self decodeBase64WithNewlines:YES];
}

- (NSData *)decodeBase64WithNewlines:(BOOL)encodedWithNewlines {
    // Create a memory buffer containing Base64 encoded string data
    BIO * mem = BIO_new_mem_buf((void *) [self UTF8String], strlen([self UTF8String]));
    
    // Push a Base64 filter so that reading from the buffer decodes it
    BIO * b64 = BIO_new(BIO_f_base64());
    if (!encodedWithNewlines)
        BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);
    
    // Decode into an NSMutableData
    NSMutableData * data = [NSMutableData data];
    char inbuf[512];
    int inlen;
    while ((inlen = BIO_read(mem, inbuf, sizeof(inbuf))) > 0)
        [data appendBytes: inbuf length: inlen];
    
    // Clean up and go home
    BIO_free_all(mem);
    return data;
}

@end


@implementation NSMutableString (NV)

- (void)replaceTabsWithSpacesOfWidth:(int)tabWidth {
	NSAssert(tabWidth < 50 && tabWidth > 0, @"that's a ridiculous tab width");
	
	@try {
		NSRange tabRange, nextRange = NSMakeRange(0, [self length]);
		while ((tabRange = [self rangeOfString:@"\t" options:NSLiteralSearch range:nextRange]).location != NSNotFound) {
			
			int numberOfSpacesPerTab = tabWidth;
			int locationOnLine = tabRange.location - [self lineRangeForRange:tabRange].location;
			if (numberOfSpacesPerTab != 0) {
				int numberOfSpacesLess = locationOnLine % numberOfSpacesPerTab;
				numberOfSpacesPerTab = numberOfSpacesPerTab - numberOfSpacesLess;
			}
			//NSLog(@"loc on line: %d, numberOfSpacesPerTab: %d", locationOnLine, numberOfSpacesPerTab);
			
			NSMutableString *spacesString = [[NSMutableString alloc] initWithCapacity:numberOfSpacesPerTab];
			while (numberOfSpacesPerTab-- > 0) {
				[spacesString appendString:@" "];
			}
			
			[self replaceCharactersInRange:tabRange withString:spacesString];
			[spacesString release];
			
			NSUInteger rangeLoc = MIN((tabRange.location + numberOfSpacesPerTab), [self length]);
			nextRange = NSMakeRange(rangeLoc, [self length] - rangeLoc);
		}
	} @catch (NSException *e) {
		NSLog(@"%s got an exception: %@", _cmd, [e reason]);
	}
}

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
	
	if (hasHighASCII) {
		//check the file on disk for extended attributes only if absolutely necessary
		NSStringEncoding extendedAttrsEncoding = 0;
		if (!aPath && fsRef && !IsZeros(fsRef, sizeof(FSRef))) {
			NSMutableData *pathData = [NSMutableData dataWithLength:4 * 1024];
			if (FSRefMakePath(fsRef, [pathData mutableBytes], [pathData length]) == noErr)
				extendedAttrsEncoding = [[NSFileManager defaultManager] textEncodingAttributeOfFSPath:[pathData bytes]];
		} else if (aPath) {
			extendedAttrsEncoding = [[NSFileManager defaultManager] textEncodingAttributeOfFSPath:aPath];
		}
		if (extendedAttrsEncoding) AddIfUnique(extendedAttrsEncoding);
	}
	AddIfUnique(*encoding);
	NSStringEncoding systemEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
	AddIfUnique(systemEncoding);
	AddIfUnique(NSMacOSRomanStringEncoding);
	
	encodingIndex = 0;
	do {
		stringFromData = [[NSMutableString alloc] initWithBytesNoCopy:[data mutableBytes] length:[data length] 
															 encoding:encodingsToTry[encodingIndex] freeWhenDone:NO];
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

@implementation NSScanner (NV)

//useful for -syntheticTitleAndSeparatorWithContext:bodyLoc:oldTitle:
- (void)scanContextualSeparator:(NSString**)sepStr withPrecedingString:(NSString*)firstLine {
	
	if (![firstLine length]) {
		//no initial preceding string, so context won't make sense
		if (sepStr) *sepStr = @"";
		return;
	}
	NSUInteger len = [[self string] length];
	if ([self scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:sepStr]) {
		if (sepStr && *sepStr) {
			if ([self scanLocation] >= len) goto noBody;
			//typical case
			*sepStr = [NSString stringWithFormat:@"%C%@%C", [firstLine characterAtIndex:[firstLine length] - 1], *sepStr, 
					   [[self string] characterAtIndex:[self scanLocation]]];
		}
	} else if (sepStr) {
		//is this the end of the string, or was the scanner's location previously somewhere in the middle?
		if ([self scanLocation] >= len) {
		noBody: //all one line
			*sepStr = @"";
		} else {
			//middle of the "title", probably because it is too long; grab the two surrounding characters
			*sepStr = [NSString stringWithFormat:@"%C%C", [firstLine characterAtIndex:[firstLine length] - 1], 
					   [[self string] characterAtIndex:[self scanLocation]]];
		}
	}
	
	//location of _following_ string (usually the body of a note) will now be [self scanLocation]
}


@end

@implementation NSCharacterSet (NV)

+ (NSCharacterSet*)labelSeparatorCharacterSet {
	static NSMutableCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [[NSMutableCharacterSet whitespaceCharacterSet] retain];
		[charSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@",;"]];
	}

	return charSet;
}

+ (NSCharacterSet*)listBulletsCharacterSet {
	static NSCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [[NSCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@"-+*!%C%C%C", 0x2022, 0x2014, 0x2013]] retain];
	}
	
	return charSet;
	
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
+ (id)newlineCharacterSet {
	return [NSCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@"%C%C%C",0x000A,0x000D,0x0085]];
}
#endif

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
