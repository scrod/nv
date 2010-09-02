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
	
	NSString *title = [[self string] syntheticTitleAndSeparatorWithContext:NULL bodyLoc:&bodyLoc oldTitle:nil];

	if (bodyLoc > 0 && [self length] >= bodyLoc) [self deleteCharactersInRange:NSMakeRange(0, bodyLoc)];

	return title;
}

- (void)prefixWithSourceString:(NSString*)source {
	source = [NSString stringWithFormat:@"From <%@>:\n\n", source];
	[self insertAttributedString:[[[NSAttributedString alloc] initWithString:source] autorelease] atIndex:0];
}

- (void)santizeForeignStylesForImporting {
	NSRange range = NSMakeRange(0, [self length]);
	[self removeAttribute:NSLinkAttributeName range:range];
	[self restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:nil];
	[self addLinkAttributesForRange:range];
}

- (BOOL)restyleTextToFont:(NSFont*)currentFont usingBaseFont:(NSFont*)baseFont {
	NSRange effectiveRange = NSMakeRange(0,0);
	unsigned int stringLength = [self length];
	int rangesChanged = 0;
	NSFontManager *fontMan = [NSFontManager sharedFontManager];
	NSDictionary *defaultBodyAttributes = [[GlobalPrefs defaultPrefs] noteBodyAttributes];
	
	NSAssert(currentFont != nil, @"restyleTextToFont needs a current font!");
	
	NS_DURING
			
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
		
	NS_HANDLER
		NSLog(@"Error trying to re-style text (%@, %@)", [localException name], [localException reason]);
	NS_ENDHANDLER
		
	return rangesChanged > 0;
}

- (void)addLinkAttributesForRange:(NSRange)changedRange {
	NSCharacterSet *antiURLSpace = [NSAttributedString antiURLCharacterSet];
	
	NSString *string = [self string];
	NSRange totalRange = NSMakeRange(0, [string length]);
	NSString *substring = string;
	if (!NSEqualRanges(totalRange, changedRange)) {
		substring = [string substringWithRange:changedRange];
	}
		
	if ([substring rangeOfCharacterFromSet:antiURLSpace options:NSLiteralSearch].location == NSNotFound)
		substring = [substring stringByAppendingString:@" "];
	
	
	NSScanner *wordScanner = [NSScanner scannerWithString:substring];
	
	//loop until end of string
	while (![wordScanner isAtEnd]) {
		NSRange wordRange = NSMakeRange(NSNotFound, 0);
		NSString *word = nil;
		
		while ([wordScanner scanUpToCharactersFromSet:antiURLSpace intoString:&word]) {
			if (word) {
				wordRange.length = [word length];
				wordRange.location = changedRange.location + [wordScanner scanLocation] - wordRange.length;
				
				NSAssert([word isEqualToString:[string substringWithRange:wordRange]], @"derived range is wrong!");
				
				NSURL *url = nil;
				if (wordRange.length && NSMaxRange(wordRange) <= [string length] && (url = [word linkForWord])) {
					if (url) [self addAttribute:NSLinkAttributeName value:url range:wordRange];
				}
			}
		}
		unsigned int newLocation = [wordScanner scanLocation] + 1;
		if (newLocation >= [substring length])
			break;
		[wordScanner setScanLocation:newLocation];
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

+ (NSCharacterSet*)antiURLCharacterSet {
	static NSMutableCharacterSet *antiURLSpace = nil;
	if (!antiURLSpace) {
		antiURLSpace = [[NSMutableCharacterSet alloc] init];
		[antiURLSpace formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		[antiURLSpace addCharactersInString:@"<>[]\""];
	}
	return antiURLSpace;
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
