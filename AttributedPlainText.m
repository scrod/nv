//
//  AttributedPlainText.m
//  Notation
//
//  Created by Zachary Schneirov on 1/16/06.

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


#import "AttributedPlainText.h"
#import "NSCollection_utils.h"
#import "GlobalPrefs.h"
#import "NSString_NV.h"
#import <math.h>

NSString *NVHiddenDoneTagAttributeName = @"NVDoneTag";
NSString *NVHiddenBulletIndentAttributeName = @"NVBulletIndentTag";
NSString *NVHiddenHeadingTagAttributeName = @"NVHeadingTag";

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

- (void)indentTextLists {
	//contributed by tewe
	@try {
		NSString *string = [self string];
		NSUInteger paraStart, paraEnd, contentsEnd;
		paraEnd = 0;
		while (paraEnd < [self length]) {
			[string getParagraphStart:&paraStart end:&paraEnd contentsEnd:&contentsEnd
							 forRange:NSMakeRange(paraEnd, 0)];
			NSParagraphStyle *style = [self attribute:NSParagraphStyleAttributeName
											  atIndex:paraStart effectiveRange:NULL];
			NSArray *textLists = [style textLists];
			if ([textLists count] > 0) {
		NSUInteger level = [textLists count] - 1;
		NSString *indent = [@"" stringByPaddingToLength:level withString: @"\t" startingAtIndex:0];
				/* Covered by restyleTextToFont
				 NSRange paraRange = NSMakeRange(paraStart, contentsEnd - paraStart);
				 [self removeAttribute:NSParagraphStyleAttributeName range:paraRange];
				 */
				[self replaceCharactersInRange:NSMakeRange(paraStart, 1) withString:@" "]; /* Leading tab to space */
				[self replaceCharactersInRange:NSMakeRange(paraStart, 0) withString:indent]; /* Changes length */
				paraEnd += level;
			}
		}
	} @catch (NSException *e) {
		NSLog(@"indentTextLists: %@", e);
	}
}

- (void)removeAttachments {
	NSUInteger loc = 0;
	NSUInteger end = [self length];
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
	[self indentTextLists];
	[self restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:nil];
	[self addLinkAttributesForRange:range];
	[self addStrikethroughNearDoneTagsForRange:range];
	[self addAttributesForMarkdownHeadingLinesInRange:range];
}

- (BOOL)restyleTextToFont:(NSFont *)currentFont usingBaseFont:(NSFont *)baseFont {
	NSAssert(currentFont != nil, @"restyleTextToFont needs a current font!");
	
	NSRange effective = NSMakeRange(0, 0);
	NSUInteger len = self.length;
	NSInteger rangesChanged = 0;
	NSFontManager *fm = [NSFontManager sharedFontManager];
	NSDictionary *defaultBodyAttributes = [[GlobalPrefs defaultPrefs] noteBodyAttributes];
	
	@try {
		while (NSMaxRange(effective) < len) {
			NSDictionary *attrs = [self attributesAtIndex:NSMaxRange(effective)
										   effectiveRange:&effective];
			NSMutableDictionary *newAttrs = [defaultBodyAttributes mutableCopyWithZone:nil];
			[newAttrs addDesiredAttributesFromDictionary:attrs];
			
			NSFont *srcFont = [attrs objectForKey:NSFontAttributeName];
			NSFont *dstFont = currentFont;
			
			// Derive desired *binary* traits from either real font traits or “fake” attributes.
			NSFontTraitMask srcTraits = srcFont ? [fm traitsOfFont:srcFont] : 0;
			
			NSNumber *oblNum    = [attrs objectForKey:NSObliquenessAttributeName];
			NSNumber *strokeNum = [attrs objectForKey:NSStrokeWidthAttributeName];
			
			CGFloat obl    = oblNum    ? [oblNum floatValue]    : 0.0f;
			CGFloat stroke = strokeNum ? [strokeNum floatValue] : 0.0f;
			
			// Treat only meaningful values as “fake” styles.
			BOOL fakeItalic = fabs(obl) > 0.001f;   // HTML sometimes sets 0.0 everywhere
			BOOL fakeBold   = stroke < -0.001f;     // negative stroke => thicker/faux-bold; 0.0 is no-op
			
			BOOL wantsItalic = ((srcTraits & NSItalicFontMask) != 0) || fakeItalic;
			BOOL wantsBold   = ((srcTraits & NSBoldFontMask)   != 0) || fakeBold;
			
			// Choose a starting face in the target family.
			if (baseFont) {
				if (srcFont && [[srcFont familyName] isEqualToString:[baseFont familyName]]) {
					// Map source face to the current family (keeps weight/width intent where possible).
					dstFont = [fm convertFont:srcFont toFamily:[currentFont familyName]];
				} else {
					dstFont = currentFont;
				}
			} else {
				// Imported text keeps only bold/italic traits, applied below.
				dstFont = currentFont;
			}
			
			// Normalize point size to the current font’s size.
			if (dstFont && fabs([dstFont pointSize] - [currentFont pointSize]) > 0.001f) {
				dstFont = [fm convertFont:dstFont toSize:[currentFont pointSize]];
			}
			
			// Apply desired binary traits.
			if (wantsItalic) dstFont = [fm convertFont:dstFont toHaveTrait:NSItalicFontMask];
			if (wantsBold)   dstFont = [fm convertFont:dstFont toHaveTrait:NSBoldFontMask];
			
			NSFontTraitMask realized = dstFont ? [fm traitsOfFont:dstFont] : 0;
			
			// Write the font first.
			[newAttrs setObject:(dstFont ?: currentFont) forKey:NSFontAttributeName];
			
			// Recreate fake styles only if the target family can’t realize the trait.
			if (wantsItalic && !(realized & NSItalicFontMask)) {
				[newAttrs setObject:@(0.20f) forKey:NSObliquenessAttributeName];
			} else {
				[newAttrs removeObjectForKey:NSObliquenessAttributeName];
			}
			
			if (wantsBold && !(realized & NSBoldFontMask)) {
				[newAttrs setObject:@(-3.5f) forKey:NSStrokeWidthAttributeName];
			} else {
				[newAttrs removeObjectForKey:NSStrokeWidthAttributeName];
			}
			
			// Ensure zero/no-op HTML artifacts don’t persist.
			if (!wantsItalic) [newAttrs removeObjectForKey:NSObliquenessAttributeName];
			if (!wantsBold)   [newAttrs removeObjectForKey:NSStrokeWidthAttributeName];
			
			[self setAttributes:newAttrs range:effective];
			[newAttrs release];
			rangesChanged++;
		}
	}
	@catch (NSException *e) {
		NSLog(@"Error trying to re-style text (%@, %@)", [e name], [e reason]);
	}
	
	return rangesChanged > 0;
}



- (void)addLinkAttributesForRange:(NSRange)changedRange {
	NSString *string = [self string];
	NSUInteger stringLength = [string length];
	if (changedRange.location > stringLength)
		return;
	changedRange.length = MIN(changedRange.length, stringLength - changedRange.location);
	
	if (!changedRange.length)
			return;

	NSError *error = nil;
	NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:&error];
	if (!detector) {
			NSLog(@"Could not create link detector: %@", error);
			return;
	}

	NSString *substring = [string substringWithRange:changedRange];
	NSArray *matches = [detector matchesInString:substring options:0 range:NSMakeRange(0, [substring length])];
	for (NSTextCheckingResult *result in matches) {
			if ([result resultType] != NSTextCheckingTypeLink)
					continue;
			NSURL *URL = [result URL];
			if (URL && !([URL isFileURL] && [[URL absoluteString] rangeOfString:@"/.file/" options:NSLiteralSearch].location != NSNotFound)) {
					NSRange linkRange = NSMakeRange(result.range.location + changedRange.location, result.range.length);
					[self addAttribute:NSLinkAttributeName value:URL range:linkRange];
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

-(void)addAttributesForMarkdownHeadingLinesInRange:(NSRange)changedRange
{
	if(![[GlobalPrefs defaultPrefs] autoFormatsMarkdownHeadings])
		return;
	
	NSCharacterSet *newlineSet = [NSCharacterSet newlineCharacterSet];
	NSRange lineEndRange, scanRange = changedRange;
	@try {
		do {
			lineEndRange = [[self string] rangeOfCharacterFromSet:newlineSet options:NSLiteralSearch range:scanRange];
			if(lineEndRange.location == NSNotFound) {
				lineEndRange = NSMakeRange(NSMaxRange(scanRange), 1);
			}
			NSRange thisLineRange = NSMakeRange(scanRange.location, lineEndRange.location - scanRange.location);
			NSString *thisLine = [[self string] substringWithRange:thisLineRange];
			if([thisLine hasPrefix:@"#"]) {
				[self addAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:NSUnderlineStyleSingle],  NSUnderlineStyleAttributeName, [NSNull null], NVHiddenHeadingTagAttributeName, nil] range:NSMakeRange(thisLineRange.location, thisLineRange.length)];
			} else if([self attribute:NVHiddenHeadingTagAttributeName existsInRange:thisLineRange]) {
				[self removeAttribute:NVHiddenHeadingTagAttributeName range:thisLineRange];
				[self removeAttribute:NSUnderlineStyleAttributeName range:thisLineRange];
			}
			scanRange = NSMakeRange(NSMaxRange(thisLineRange), changedRange.length - (NSMaxRange(thisLineRange) - changedRange.location));
			if(scanRange.length > 0) {
				scanRange = NSMakeRange(scanRange.location + 1, scanRange.length - 1);
			} else {
				break;
			}
		} while(NSMaxRange(scanRange) <= NSMaxRange(changedRange));
	} @catch (NSException *e) {
		NSLog(@"_%@(%@): %@", NSStringFromSelector(_cmd), NSStringFromRange(changedRange), e);
	}
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
		NSLog(@"_%@(%@): %@", NSStringFromSelector(_cmd), NSStringFromRange(changedRange), e);
	}
}


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
	NSUInteger startIndex = 0;
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


- (id)findNextLinkAtIndex:(NSUInteger)startIndex effectiveRange:(NSRange *)range {
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

+ (NSAttributedString*)timeDelayStringWithNumberOfSeconds:(double)seconds {
	unichar ch = 0x2245;
	static NSAttributedString *approxCharStr = nil;
	if (!approxCharStr) {
		NSMutableParagraphStyle *centerStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
		[centerStyle setAlignment:NSTextAlignmentCenter];

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
