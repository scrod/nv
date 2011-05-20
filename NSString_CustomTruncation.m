//
//  NSString_CustomTruncation.m
//  Notation
//
//  Created by Zachary Schneirov on 1/12/11.

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


#import "NSString_CustomTruncation.h"
#import "GlobalPrefs.h"

@implementation NSString (CustomTruncation)

static NSMutableParagraphStyle *LineBreakingStyle();
static NSDictionary *GrayTextAttributes();
static NSDictionary *LineTruncAttributes();
static size_t EstimatedCharCountForWidth(float upToWidth);



- (NSString*)truncatedPreviewStringOfLength:(NSUInteger)bodyCharCount {
	
	//try to get the underlying C-string buffer and copy only part of it
	//this won't be exact because chars != bytes, but that's alright because it is expected to be further truncated by an NSTextFieldCell
	CFStringEncoding bodyPreviewEncoding = CFStringGetFastestEncoding((CFStringRef)self);
	const char * cStrPtr = CFStringGetCStringPtr((CFStringRef)self, bodyPreviewEncoding);
	char *bodyPreviewBuffer = calloc(bodyCharCount + 1, sizeof(char));
	CFIndex usedBufLen = bodyCharCount;
	
	if (bodyCharCount > 1) {
		if (cStrPtr && kCFStringEncodingUTF8 != bodyPreviewEncoding && kCFStringEncodingUnicode != bodyPreviewEncoding) {
			//only attempt to copy the buffer directly if the fastest encoding is not a unicode variant
			memcpy(bodyPreviewBuffer, cStrPtr, bodyCharCount);
		} else {
			bodyPreviewEncoding = kCFStringEncodingUTF8;
			if ([self length] == bodyCharCount) {
				//if this is supposed to be the entire string, don't waffle around
				const char *fullUTF8String = [self UTF8String];
				if (fullUTF8String) {
					usedBufLen = bodyCharCount = strlen(fullUTF8String);
					bodyPreviewBuffer = realloc(bodyPreviewBuffer, bodyCharCount + 1);
					memcpy(bodyPreviewBuffer, fullUTF8String, bodyCharCount + 1);
					goto replace;
				}
			}
			if (!CFStringGetBytes((CFStringRef)self, CFRangeMake(0, bodyCharCount), bodyPreviewEncoding, ' ', FALSE, 
								  (UInt8 *)bodyPreviewBuffer, bodyCharCount + 1, &usedBufLen)) {
				NSLog(@"can't get utf8 string from '%@' (charcount: %u)", self, bodyCharCount);
				free(bodyPreviewBuffer);
				return nil;
			}
		}
	}
replace:
	//if bodyPreviewBuffer is a UTF-8 encoded string, then examine the string one UTF-8 sequence at a time to catch multi-byte breaks
	if (bodyPreviewEncoding == kCFStringEncodingUTF8) {
		replace_breaks_utf8(bodyPreviewBuffer, bodyCharCount);
	} else {
		replace_breaks(bodyPreviewBuffer, bodyCharCount);
	}
	
	NSString* truncatedBodyString = [[NSString alloc] initWithBytesNoCopy:bodyPreviewBuffer length:usedBufLen 
																 encoding:CFStringConvertEncodingToNSStringEncoding(bodyPreviewEncoding) freeWhenDone:YES];
	if (!truncatedBodyString) {
		free(bodyPreviewBuffer);
		NSLog(@"can't create cfstring from '%@' (cstr lens: %u/%d) with encoding %u (fastest = %u)", self, bodyCharCount, usedBufLen, bodyPreviewEncoding, CFStringGetFastestEncoding((CFStringRef)self)); 
		return nil;
	}
	return [truncatedBodyString autorelease];
}

static NSMutableDictionary *titleTruncAttrs = nil;

void ResetFontRelatedTableAttributes() {
	[titleTruncAttrs release];
	titleTruncAttrs = nil;
}

static NSMutableParagraphStyle *LineBreakingStyle() {
	static NSMutableParagraphStyle *lineBreaksStyle = nil;
	if (!lineBreaksStyle) {
		lineBreaksStyle = [[NSMutableParagraphStyle alloc] init];
		[lineBreaksStyle setLineBreakMode:NSLineBreakByTruncatingTail];
		[lineBreaksStyle setTighteningFactorForTruncation:0.0];
	}
	return lineBreaksStyle;
}

static NSDictionary *GrayTextAttributes() {
	static NSDictionary *grayTextAttributes = nil;
	if (!grayTextAttributes) grayTextAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:[NSColor grayColor], NSForegroundColorAttributeName, nil] retain];
	return grayTextAttributes;
}

static NSDictionary *LineTruncAttributes() {
	static NSDictionary *lineTruncAttributes = nil;
	if (!lineTruncAttributes) lineTruncAttributes = [[NSDictionary dictionaryWithObjectsAndKeys:LineBreakingStyle(), NSParagraphStyleAttributeName, nil] retain];
	return lineTruncAttributes;
}

NSDictionary *LineTruncAttributesForTitle() {
	if (!titleTruncAttrs) {
		GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
		unsigned int bitmap = [prefs tableColumnsBitmap];
		float fontSize = [prefs tableFontSize];
		BOOL usesBold = ColumnIsSet(NoteLabelsColumn, bitmap) || ColumnIsSet(NoteDateCreatedColumn, bitmap) ||
		ColumnIsSet(NoteDateModifiedColumn, bitmap) || [prefs tableColumnsShowPreview];
		
		titleTruncAttrs = [[NSDictionary dictionaryWithObjectsAndKeys:[[LineBreakingStyle() mutableCopy] autorelease], NSParagraphStyleAttributeName, 
							(usesBold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize]), NSFontAttributeName, nil] retain];
		
		if (ColumnIsSet(NoteDateCreatedColumn, bitmap) || ColumnIsSet(NoteDateModifiedColumn, bitmap)) {
			//account for right-"aligned" date string, which will be relatively constant, so this can be cached
			[[titleTruncAttrs objectForKey:NSParagraphStyleAttributeName] setTailIndent: fontSize * -4.6]; //avg of -55 for ~11-12 font size
		}
	}
	return titleTruncAttrs;
}

static size_t EstimatedCharCountForWidth(float upToWidth) {
	return (size_t)(upToWidth / ([[GlobalPrefs defaultPrefs] tableFontSize] / 2.5f));
}

//LineTruncAttributesForTags would be variable, depending on the note; each preview string will have its own copy of the nsdictionary

- (NSAttributedString*)attributedMultiLinePreviewFromBodyText:(NSAttributedString*)bodyText upToWidth:(float)upToWidth intrusionWidth:(float)intWidth {
	//first line is title, truncated to a shorter width to account for date/time, using a negative -[NSMutableParagraphStyle setTailIndent:] value
	//next "two" lines are wrapped body text, with a character-count estimation of essentially double that of a single-line preview
	//also with an independent tailindent to account for a separately-drawn tags-string, if tags exist
	//upToWidth will be used to manually truncate note-bodies only, and should be the full column width available
	//intWidth will typically be the width of the tags string or other representation
	
	size_t bodyCharCount = (EstimatedCharCountForWidth(upToWidth) * 2) - EstimatedCharCountForWidth(intWidth);
	bodyCharCount = MIN(bodyCharCount, [bodyText length]);
	
	NSMutableString *unattributedPreview = [[NSMutableString alloc] initWithCapacity:bodyCharCount + [self length] + 2];
	
	NSString *truncatedBodyString = [[bodyText string] truncatedPreviewStringOfLength:bodyCharCount];
	if (!truncatedBodyString) return nil;
	
	[unattributedPreview appendString:self];
	[unattributedPreview appendString:@"\n"];
	[unattributedPreview appendString:truncatedBodyString];
	
	NSMutableAttributedString *attributedStringPreview = [[NSMutableAttributedString alloc] initWithString:unattributedPreview];
	
	//title is black (no added colors) and truncated with LineTruncAttributesForTitle()
	//body is gray and truncated with a variable tail indent, depending on intruding tags
	
	NSDictionary *bodyTruncDict = [NSDictionary dictionaryWithObjectsAndKeys:[[LineBreakingStyle() mutableCopy] autorelease], 
								   NSParagraphStyleAttributeName, [NSColor grayColor], NSForegroundColorAttributeName, nil];
	//set word-wrapping to let -[NSCell setTruncatesLastVisibleLine:] work
	[[bodyTruncDict objectForKey:NSParagraphStyleAttributeName] setLineBreakMode:NSLineBreakByWordWrapping];
	
	if (intWidth > 0.0) {
		//there are tags; add an appropriately-sized tail indent to the body
		[[bodyTruncDict objectForKey:NSParagraphStyleAttributeName] setTailIndent:-intWidth];
	}
	
	[attributedStringPreview addAttributes:LineTruncAttributesForTitle() range:NSMakeRange(0, [self length])];
	[attributedStringPreview addAttributes:bodyTruncDict range:NSMakeRange([self length] + 1, [unattributedPreview length] - ([self length] + 1))];
	
	[unattributedPreview release];
	
	return [attributedStringPreview autorelease];
}

- (NSAttributedString*)attributedSingleLineTitle {
	//show only a single line, with a tail indent large enough for both the date and tags (if there are any)
	//because this method displays the title only, manual truncation isn't really necessary
	//the highlighted version of this string should be bolded
	
	NSMutableAttributedString *titleStr = [[NSMutableAttributedString alloc] initWithString:self attributes:LineTruncAttributesForTitle()];

	return [titleStr autorelease];
}


- (NSAttributedString*)attributedSingleLinePreviewFromBodyText:(NSAttributedString*)bodyText upToWidth:(float)upToWidth {
	
	//compute the char count for this note based on the width of the title column and the length of the receiver
	size_t bodyCharCount = EstimatedCharCountForWidth(upToWidth) - [self length];
	bodyCharCount = MIN(bodyCharCount, [bodyText length]);
	
	NSString *truncatedBodyString = [[bodyText string] truncatedPreviewStringOfLength:bodyCharCount];
	if (!truncatedBodyString) return nil;
	
	NSMutableString *unattributedPreview = [self mutableCopy];
	NSString *delimiter = NSLocalizedString(@" option-shift-dash ", @"title/description delimiter");
	[unattributedPreview appendString:delimiter];
	[unattributedPreview appendString:truncatedBodyString];
	
	NSMutableAttributedString *attributedStringPreview = [[NSMutableAttributedString alloc] initWithString:unattributedPreview attributes:LineTruncAttributes()];
	[attributedStringPreview addAttributes:GrayTextAttributes() range:NSMakeRange([self length], [unattributedPreview length] - [self length])];
	
	[unattributedPreview release];
	
	return [attributedStringPreview autorelease];
}


@end
