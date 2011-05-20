//
//  AttributedPlainText.m
//  Notation
//
//  Created by Zachary Schneirov on 1/16/06.

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


#import "AttributedPlainText.h"
#import "NSCollection_utils.h"
#import "GlobalPrefs.h"
#import "NSString_NV.h"
#import <AutoHyperlinks/AutoHyperlinks.h>


NSString *NVHiddenDoneTagAttributeName = @"NVDoneTag";
NSString *NVHiddenBulletIndentAttributeName = @"NVBulletIndentTag";

static BOOL _StringWithRangeIsProbablyObjC(NSString *string, NSRange blockRange);

@implementation NSMutableAttributedString (AttributedPlainText)

- (void)trimLeadingWhitespace {
	NSMutableCharacterSet *whiteSet = [[[NSMutableCharacterSet alloc] init] autorelease];
	[whiteSet formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	//include attachment characters and non-breaking spaces. anything else?
	unichar badChars[2] = { NSAttachmentCharacter, 0x00A0 };
	[whiteSet addCharactersInString:[NSString stringWithCharacters:badChars length:2]];
	
	NSScanner *scanner = [NSScanner scannerWithString:[self string]];
	
	if ([scanner scanCharactersFromSet:whiteSet intoString:NULL]) {
		if ([scanner scanLocation] > 0) {
			[self deleteCharactersInRange:NSMakeRange(0, [scanner scanLocation])];
			//NSLog(@"deleting %d chars", [scanner scanLocation]);
		}
	}
}

- (void)removeAttachments {
	unsigned loc = 0;
	unsigned end = [self length];
	while (loc < end) {
		/* Run through the string in terms of attachment runs */
		NSRange attachmentRange;	/* Attachment attribute run */
		NSTextAttachment *attachment = [self attribute:NSAttachmentAttributeName atIndex:loc longestEffectiveRange:&attachmentRange inRange:NSMakeRange(loc, end-loc)];
		if (attachment != nil) {	/* If there is an attachment, make sure it is valid */
			unichar ch = [[self string] characterAtIndex:loc];
			if (ch == NSAttachmentCharacter) {
				[self replaceCharactersInRange:NSMakeRange(loc, 1) withString:@""];
				end = [self length];	/* New length */
			} else {
				loc++;	/* Just skip over the current character... */
			}
		} else {
			loc = NSMaxRange(attachmentRange);
		}
	}
}

- (NSString*)trimLeadingSyntheticTitle {
	NSUInteger bodyLoc = 0;
	
	NSString *title = [[self string] syntheticTitleAndSeparatorWithContext:NULL bodyLoc:&bodyLoc maxTitleLen:60];

	if (bodyLoc > 0 && [self length] >= bodyLoc) [self deleteCharactersInRange:NSMakeRange(0, bodyLoc)];

	return title;
}

- (NSString*)prefixWithSourceString:(NSString*)source {
	NSString *sourceWContext = [NSString stringWithFormat:@"%@ <%@>:\n\n", NSLocalizedString(@"From", @"prefix for source-URLs inserted into imported notes; e.g., 'From <http://www.apple.com>: ...'"), source];
	[self insertAttributedString:[[[NSAttributedString alloc] initWithString:sourceWContext] autorelease] atIndex:0];
	return sourceWContext;
}

- (void)santizeForeignStylesForImporting {
	NSRange range = NSMakeRange(0, [self length]);
	[self removeAttribute:NSLinkAttributeName range:range];
	[self restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:nil];
	[self addLinkAttributesForRange:range];
	[self addStrikethroughNearDoneTagsForRange:range];
}

- (BOOL)restyleTextToFont:(NSFont*)currentFont usingBaseFont:(NSFont*)baseFont {
	NSRange effectiveRange = NSMakeRange(0,0);
	unsigned int stringLength = [self length];
	int rangesChanged = 0;
	NSFontManager *fontMan = [NSFontManager sharedFontManager];
	NSDictionary *defaultBodyAttributes = [[GlobalPrefs defaultPrefs] noteBodyAttributes];
	
	NSAssert(currentFont != nil, @"restyleTextToFont needs a current font!");
	
	@try {
			
		while (NSMaxRange(effectiveRange) < stringLength) {
			// Get the attributes for the current range
			NSDictionary *attributes = [self attributesAtIndex:NSMaxRange(effectiveRange) effectiveRange:&effectiveRange];
			
			NSMutableDictionary *newAttributes = [defaultBodyAttributes mutableCopyWithZone:nil];
			[newAttributes addDesiredAttributesFromDictionary:attributes];
			
			NSFont *aFont = [attributes objectForKey:NSFontAttributeName];
			NSFont *newFont = currentFont;
			BOOL needToMatchAttributes = NO;
			NSFontTraitMask traits = 0;
			
			if (!baseFont) {
				if (aFont) {
					//we have a font--try to match its traits, if there are any
					traits = [fontMan traitsOfFont:aFont];
					if (traits & NSBoldFontMask || traits & NSItalicFontMask)
						//do we need to check stroke width & obliqueness? the base font should only be nonexistent when we have new foreign text
						needToMatchAttributes = YES;
				}
			} else if (!aFont || [[aFont fontName] isEqualToString:[baseFont fontName]]) {
				//just change the font to currentFont
				newFont = currentFont;
			} else if ([[aFont familyName] isEqualToString:[baseFont familyName]]) {
				traits = [fontMan traitsOfFont:aFont];
				needToMatchAttributes = YES;
			}
			
			BOOL hasFakeItalic = [attributes objectForKey:NSObliquenessAttributeName] != nil;
			BOOL hasFakeBold = [attributes objectForKey:NSStrokeWidthAttributeName] != nil;
			
			if (needToMatchAttributes || hasFakeItalic || hasFakeBold) {
				newFont = [fontMan convertFont:aFont toFamily:[currentFont familyName]];
				
				if (hasFakeItalic) newFont = [fontMan convertFont:newFont toHaveTrait:NSItalicFontMask];	
				if (hasFakeBold) newFont = [fontMan convertFont:newFont toHaveTrait:NSBoldFontMask];
				
				NSFontTraitMask newTraits = [fontMan traitsOfFont:newFont];
				
				if (!(newTraits & NSItalicFontMask) && (traits & NSItalicFontMask)) {
					[newAttributes setObject:[NSNumber numberWithFloat:0.20] forKey:NSObliquenessAttributeName];
				} else if (newTraits & NSItalicFontMask) {
					[newAttributes removeObjectForKey:NSObliquenessAttributeName];
				}
				if (!(newTraits & NSBoldFontMask) && (traits & NSBoldFontMask)) {
					[newAttributes setObject:[NSNumber numberWithFloat:-3.50] forKey:NSStrokeWidthAttributeName];
				} else if (newTraits & NSBoldFontMask) {
					[newAttributes removeObjectForKey:NSStrokeWidthAttributeName];
				}
			}
			if (newFont && [newFont pointSize] != [currentFont pointSize]) {
				//also make the font have the same size
				newFont = [fontMan convertFont:newFont toSize:[currentFont pointSize]];
			}
			
			[newAttributes setObject:newFont ? newFont : currentFont forKey:NSFontAttributeName];
			[self setAttributes:newAttributes range:effectiveRange];
			[newAttributes release];
			
			rangesChanged++;
		}
	}	
	@catch (NSException *e) {
		NSLog(@"Error trying to re-style text (%@, %@)", [e name], [e reason]);
	}
		
	return rangesChanged > 0;
}

- (void)addLinkAttributesForRange:(NSRange)changedRange {
	
	if (!changedRange.length)
		return;
	
	//lazily loads Adium's BSD-licensed Auto-Hyperlinks:
	//http://trac.adium.im/wiki/AutoHyperlinksFramework
	
	static Class AHHyperlinkScanner = Nil;
	static Class AHMarkedHyperlink = Nil;
	if (!AHHyperlinkScanner || !AHMarkedHyperlink) {
		if (![[NSBundle bundleWithPath:[[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"AutoHyperlinks.framework"]] load]) {
			NSLog(@"Could not load AutoHyperlinks framework");
			return;
		}
		AHHyperlinkScanner = NSClassFromString(@"AHHyperlinkScanner");
		AHMarkedHyperlink = NSClassFromString(@"AHMarkedHyperlink");
	}
	
	id scanner = [AHHyperlinkScanner hyperlinkScannerWithString:[[self string] substringWithRange:changedRange]];
	id markedLink = nil;
	while ((markedLink = [scanner nextURI])) {
		NSURL *markedLinkURL = nil;
		if ((markedLinkURL = [markedLink URL]) && !([markedLinkURL isFileURL] && [[markedLinkURL absoluteString] 
																				  rangeOfString:@"/.file/" options:NSLiteralSearch].location != NSNotFound)) {
			[self addAttribute:NSLinkAttributeName value:markedLinkURL 
						 range:NSMakeRange([markedLink range].location + changedRange.location, [markedLink range].length)];
		}
	}

	//also detect double-bracketed URLs here
	[self _addDoubleBracketedNVLinkAttributesForRange:changedRange];
}

- (void)_addDoubleBracketedNVLinkAttributesForRange:(NSRange)changedRange {
	//add link attributes for [[wiki-style links to other notes or search terms]] 
	
	static NSMutableCharacterSet *antiInteriorSet = nil;
	if (!antiInteriorSet) {
		antiInteriorSet = [[NSMutableCharacterSet characterSetWithCharactersInString:@"[]"] retain];
		[antiInteriorSet formUnionWithCharacterSet:[NSCharacterSet whitespaceCharacterSet]];
		[antiInteriorSet formUnionWithCharacterSet:[NSCharacterSet illegalCharacterSet]];
		[antiInteriorSet formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
	}
	
	NSString *string = [self string];
	NSUInteger nextScanLoc = 0;
	NSRange scanRange = changedRange;
	
	while (NSMaxRange(scanRange) <= NSMaxRange(changedRange)) {
		
		NSUInteger begin = [string rangeOfString:@"[[" options:NSLiteralSearch range:scanRange].location;
		if (begin == NSNotFound) break;
		begin += 2;
		NSUInteger end = [string rangeOfString:@"]]" options:NSLiteralSearch 
										 range:NSMakeRange(begin, changedRange.length - (begin - changedRange.location))].location;
		if (end == NSNotFound) break;

		NSRange blockRange = NSMakeRange(begin, (end - begin));

		//double-braces must directly abut the search terms
		//capture inner invalid "[["s, but not inner invalid "]]"s;
		//because scanning, which is left to right, could be cancelled prematurely otherwise
		if ([antiInteriorSet characterIsMember:[string characterAtIndex:begin]]) {
			nextScanLoc = begin;
			goto nextBlock;
		}
		//when encountering a newline in the midst of opposing double-brackets, 
		//continue scanning after the newline instead of after the end-brackets; avoid certain traps that change the behavior of multi- vs single-line scans
		NSRange newlineRange = [string rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet] options:NSLiteralSearch range:blockRange];
		if (newlineRange.location != NSNotFound) {
			nextScanLoc = newlineRange.location + 1;
			goto nextBlock;
		}

		if (![antiInteriorSet characterIsMember:[string characterAtIndex:NSMaxRange(blockRange) - 1]] && !_StringWithRangeIsProbablyObjC(string, blockRange)) {
			
			[self addAttribute:NSLinkAttributeName value:
			 [NSURL URLWithString:[@"nv://find/" stringByAppendingString:[[string substringWithRange:blockRange] stringWithPercentEscapes]]] range:blockRange];
		}
		//continue the scan starting at the end of the current block
		nextScanLoc = NSMaxRange(blockRange) + 2;

	nextBlock:
		scanRange = NSMakeRange(nextScanLoc, changedRange.length - (nextScanLoc - changedRange.location));
	}
}

static BOOL _StringWithRangeIsProbablyObjC(NSString *string, NSRange blockRange) {
	//assuming this range is bookended with matching double-brackets,
	//does the block contain unbalanced inner square brackets?
	
	NSUInteger rightBracketLoc = [string rangeOfString:@"]" options:NSLiteralSearch range:blockRange].location;
	NSUInteger leftBracketLoc = [string rangeOfString:@"[" options:NSLiteralSearch range:blockRange].location; 
	
	//no brackets of either variety
	if (rightBracketLoc == NSNotFound && leftBracketLoc == NSNotFound) return NO;
	
	//has balanced inner brackets; right bracket exists and is actually to the right of the left bracket
	if (rightBracketLoc != NSNotFound && rightBracketLoc > leftBracketLoc) return NO;
	
	//no right bracket or no left bracket
	return YES;
	
	//this still doesn't catch something like "[[content prefixWithSourceString:[[getter url] absoluteString]] length];"
	//an improvement would be to use rangeOfCharacterFromSet:@"[]" to count all the left and right brackets from left to right;
	//a leftbracket would increment a count, a right bracket would decrement it; at the end of blockRange, the count should be 0
	//this is left as an exercise to the anal-retentive reader
}

- (void)addStrikethroughNearDoneTagsForRange:(NSRange)changedRange {
	//scan line by line
	//if the line ends in " @done", then strikethrough everything prior and add NVHiddenDoneTagAttributeName
	//if the line doesn't end in " @done", and it has NVHiddenDoneTagAttributeName + NSStrikethroughStyleAttributeName,
	//  then remove both attributes
	//all other NSStrikethroughStyleAttributeName by itself will be ignored
	
	if (![[GlobalPrefs defaultPrefs] autoFormatsDoneTag])
		return;
		
	NSString *doneTag = @" @done";
	NSCharacterSet *newlineSet = [NSCharacterSet newlineCharacterSet];
	
	NSRange lineEndRange, scanRange = changedRange;
	
	@try {
		do {
			if ((lineEndRange = [[self string] rangeOfCharacterFromSet:newlineSet options:NSLiteralSearch range:scanRange]).location == NSNotFound) {
				//no newline; this is the end of the range, so set line-end to an imaginary position there
				lineEndRange = NSMakeRange(NSMaxRange(scanRange), 1);
			}
			
			NSRange thisLineRange = NSMakeRange(scanRange.location, lineEndRange.location - scanRange.location);
			
			//this detection is not good enough; it can't handle the case of @done(date)
			if ([[[self string] substringWithRange:thisLineRange] hasSuffix:doneTag]) {
				
				//add strikethrough and NVHiddenDoneTagAttributeName attributes, because this line ends in @done
				[self addAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:NSUnderlineStyleSingle], 
									 NSStrikethroughStyleAttributeName, [NSNull null], NVHiddenDoneTagAttributeName, nil] 
							  range:NSMakeRange(thisLineRange.location, thisLineRange.length - [doneTag length])];
				//and the done tag itself should never be struck-through; remove that just in case typing attributes had carried over from elsewhere
				[self removeAttribute:NSStrikethroughStyleAttributeName range:NSMakeRange(NSMaxRange(thisLineRange) - [doneTag length], [doneTag length])];
				
			} else if ([self attribute:NVHiddenDoneTagAttributeName existsInRange:thisLineRange]) {
				
				//assume that this line was previously struck-through by NV due to the presence of a @done tag; remove those attrs now
				[self removeAttribute:NVHiddenDoneTagAttributeName range:thisLineRange];
				[self removeAttribute:NSStrikethroughStyleAttributeName range:thisLineRange];
			}
			//if scanRange has a non-zero length, then advance it further
			if ((scanRange = NSMakeRange(NSMaxRange(thisLineRange), changedRange.length - (NSMaxRange(thisLineRange) - changedRange.location))).length)
				scanRange = NSMakeRange(scanRange.location + 1, scanRange.length - 1);
			else {
				break;
			}
		} while (NSMaxRange(scanRange) <= NSMaxRange(changedRange));
	}
	@catch (NSException *e) {
		NSLog(@"_%s(%@): %@", _cmd, NSStringFromRange(changedRange), e);
	}
}


#if SEPARATE_ATTRS
#define VLISTBUFCOUNT 32

//string after apply an array of attributes
+ (NSMutableAttributedString*)attributedStringWithString:(NSString*)text attributesByRange:(NSDictionary*)attributes font:(NSFont*)font {
	id *keys, *values;
	id keysBuffer[VLISTBUFCOUNT], valuesBuffer[VLISTBUFCOUNT];
	int i, discreteRangeCount = [attributes count];
	
	NSMutableAttributedString *attributedString = [[NSAttributedString alloc] initWithString:text];
	
	keys = (discreteRangeCount <= VLISTBUFCOUNT) ? keysBuffer : (id*)malloc(sizeof(id) * discreteRangeCount);
	values = (discreteRangeCount <= VLISTBUFCOUNT) ? valuesBuffer : (id*)malloc(sizeof(id) * discreteRangeCount);
	
	if (keys && values && attributes) {
		CFDictionaryGetKeysAndValues((CFDictionaryRef)attributes, (void*)keys, (void*)values);
		
		NS_DURING	
		for (i=0; i<discreteRangeCount; i++) {
			
			NSValue *rangeValue = keys[i];
			NSDictionary *theseAttributes = values[i];
			if (rangeValue && theseAttributes) {
				//we ought to do font substitution here, too -- convertFont:(NSFont *)aFont toFace:, for those matching default font
				[attributedString setAttributes:theseAttributes range:[rangeValue rangeValue]];
			}
		}
		NS_HANDLER
			NSLog(@"Error setting attributes for string. %@: %@", [localException name], [localException reason]);
		NS_ENDHANDLER
		
		if (keys != keysBuffer)
			free(keys);
		if (values != valuesBuffer)
			free(values);
	} else {
		NSLog(@"Could not get values or keys! Not applying any attributes.");
	}
	
	return [attributedString autorelease];
}
#endif

@end

@implementation NSAttributedString (AttributedPlainText)


- (BOOL)attribute:(NSString*)anAttribute existsInRange:(NSRange)aRange {
	NSRange effectiveRange = NSMakeRange(aRange.location, 0);
	
	while (NSMaxRange(effectiveRange) < NSMaxRange(aRange)) {
		if ([self attribute:anAttribute atIndex:NSMaxRange(effectiveRange) effectiveRange:&effectiveRange]) {
			return YES;
		}
	}

	return NO;
}

- (NSArray*)allLinks {
	NSRange range;
	unsigned int startIndex = 0;
	NSMutableArray *array = [NSMutableArray arrayWithCapacity:1];
	while (startIndex < [self length]) {
		id alink = [self findNextLinkAtIndex:startIndex effectiveRange:&range];
		if ([alink isKindOfClass:[NSURL class]]) {
			[array addObject:alink];
		}
		startIndex = range.location+range.length;
	}
	
	return array;
}


- (id)findNextLinkAtIndex:(unsigned int)startIndex effectiveRange:(NSRange *)range {
	NSRange linkRange;
	id alink = nil;
	while (!alink && startIndex < [self length]) {
		alink = [self attribute:NSLinkAttributeName atIndex:startIndex effectiveRange:&linkRange];
		startIndex++;
	}
	if (alink) {
		range->location = linkRange.location;
		range->length = linkRange.length;
	} else {
		range->location = NSNotFound;
		range->length = 0;
	}
	return alink;
}

#if SEPARATE_ATTRS
//extract the attributes using their ranges as keys
- (NSDictionary*)attributesByRange {
    NSMutableDictionary *allAttributes = [NSMutableDictionary dictionaryWithCapacity:1];
	NSDictionary *attributes;
    NSRange effectiveRange = NSMakeRange(0,0);
	NSUInteger stringLength = [self length];
	
	NS_DURING
		while (NSMaxRange(effectiveRange) < stringLength) {
			// Get the attributes for the current range
			attributes = [self attributesAtIndex:NSMaxRange(effectiveRange) effectiveRange:&effectiveRange];
			
			[allAttributes setObject:attributes forKey:[NSValue valueWithRange:effectiveRange]];
		}
		NS_HANDLER
			NSLog(@"Error getting attributes: %@", [localException reason]);
		NS_ENDHANDLER
		
		return allAttributes;
}
#endif

+ (NSAttributedString*)timeDelayStringWithNumberOfSeconds:(double)seconds {
	unichar ch = 0x2245;
	static NSAttributedString *approxCharStr = nil;
	if (!approxCharStr) {
		NSMutableParagraphStyle *centerStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
		[centerStyle setAlignment:NSCenterTextAlignment];

		approxCharStr = [[NSAttributedString alloc] initWithString:[NSString stringWithCharacters:&ch length:1] attributes:
						 [NSDictionary dictionaryWithObjectsAndKeys:[NSFont fontWithName:@"Symbol" size:16.0f], NSFontAttributeName, centerStyle, NSParagraphStyleAttributeName, nil]];
	}
	NSMutableAttributedString *mutableStr = [approxCharStr mutableCopy];
	
	NSString *timeStr = seconds < 1.0 ? [NSString stringWithFormat:@" %0.0f ms", seconds*1000] : [NSString stringWithFormat:@" %0.2f secs", seconds];
	
	[mutableStr appendAttributedString:[[[NSAttributedString alloc] initWithString:timeStr attributes:
										 [NSDictionary dictionaryWithObject:[NSFont systemFontOfSize:13.0f] forKey:NSFontAttributeName]] autorelease]];
	return [mutableStr autorelease];
}



@end
