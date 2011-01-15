//
//  NSCollection_utils.m
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


#import "NSCollection_utils.h"
#import "AttributedPlainText.h"
#import "NSString_NV.h"
#import "NoteObject.h"
#import "BufferUtils.h"

@implementation NSDictionary (FontTraits)

- (BOOL)attributesHaveFontTrait:(NSFontTraitMask)desiredTrait orAttribute:(NSString*)attrName {
	if ([self objectForKey:attrName])
		return YES;
	NSFont *font = [self objectForKey:NSFontAttributeName];
	if (font) {
		NSFontTraitMask traits = [[NSFontManager sharedFontManager] traitsOfFont:font];
		return traits & desiredTrait;
	}
	
	return NO;
	
}

@end

@implementation NSMutableDictionary (FontTraits)

- (void)addDesiredAttributesFromDictionary:(NSDictionary*)dict {
	id underlineStyle = [dict objectForKey:NSUnderlineStyleAttributeName];
	id strokeWidthStyle = [dict objectForKey:NSStrokeWidthAttributeName];
	id obliquenessStyle = [dict objectForKey:NSObliquenessAttributeName];
	id linkStyle = [dict objectForKey:NSLinkAttributeName];
	
	if (linkStyle)
		[self setObject:linkStyle forKey:NSLinkAttributeName];
	if (underlineStyle)
		[self setObject:underlineStyle forKey:NSUnderlineStyleAttributeName];
	if (strokeWidthStyle)
		[self setObject:strokeWidthStyle forKey:NSStrokeWidthAttributeName];
	if (obliquenessStyle)
		[self setObject:obliquenessStyle forKey:NSObliquenessAttributeName];
}

- (void)applyStyleInverted:(BOOL)opposite trait:(NSFontTraitMask)trait forFont:(NSFont*)font 
	alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value {
	
	NSFontManager *fontMan = [NSFontManager sharedFontManager];
	
	if (opposite) {
		font = [fontMan convertFont:font toNotHaveTrait:trait];	
		[self removeObjectForKey:attrName];
	} else {
		font = [fontMan convertFont:font toHaveTrait:trait];
		NSFontTraitMask newTraits = [fontMan traitsOfFont:font];
		
		if (!(newTraits & trait)) {
			[self setObject:value forKey:attrName];
		} else {
			[self removeObjectForKey:attrName];
		}
	}
	[self setObject:font forKey:NSFontAttributeName];
}

@end

@implementation NSDictionary (URLEncoding)

- (NSString*)URLEncodedString {
	
	NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:[self count]];
	
	NSEnumerator *enumerator = [self keyEnumerator];
	NSString *aKey = nil;
	while ((aKey = [enumerator nextObject])) {
		[pairs addObject:[NSString stringWithFormat: @"%@=%@", 
						  [aKey stringWithPercentEscapes], [[self objectForKey:aKey] stringWithPercentEscapes]]];
		
	}
	return [pairs componentsJoinedByString:@"&"];
}


@end



@implementation NSSet (Utilities)

- (NSMutableSet*)setIntersectedWithSet:(NSSet*)set {
    NSMutableSet *existingItems = [NSMutableSet setWithSet:self];
    [existingItems intersectSet:set];
   
    return existingItems;
}

@end

@implementation NSArray (NoteUtilities)

- (NSArray*)objectsFromDictionariesForKey:(id)aKey {
	NSUInteger i = 0;
	NSMutableArray *objects = [NSMutableArray arrayWithCapacity:[self count]];
	for (i=0; i<[self count]; i++) {
		id obj = [[self objectAtIndex:i] objectForKey:aKey];
		if (obj) [objects addObject:obj];
	}
	return objects;
}

- (NSUInteger)indexOfNoteWithUUIDBytes:(CFUUIDBytes*)bytes {
	NSUInteger i;
    for (i=0; i<[self count]; i++) {
		NoteObject *note = [self objectAtIndex:i];
		CFUUIDBytes *noteBytes = [note uniqueNoteIDBytes];
		if (!memcmp(noteBytes, bytes, sizeof(CFUUIDBytes)))
			return i;
    }
    
    return NSNotFound;
}

#if 0
- (NSRange)nextRangeForString:(NSString*)string activeNote:(NoteObject*)startNote options:(unsigned)opts range:(NSRange)inRange {
	unsigned noteCount = [self count];
	NSRange range = NSMakeRange(NSNotFound, 0);
	
	if (count > 0) {
		unsigned noteIndex, startIndex = [self indexOfObjectIdenticalTo:startNote];
		BOOL reversed = opts | NSBackwardsSearch;
		if (startIndex == NSNotFound) startIndex = reversed ? count - 1 : 0;
		noteIndex = startIndex;
		
		unsigned quoteIndex = [string rangeOfString:@"\"" options:NSLiteralSearch].location;
		NSArray *words = [string componentsSeparatedByString:quoteIndex == NSNotFound ? @" " : @"\""];
		
		do {
			NSRange range = [[self objectAtIndex:noteIndex] nextRangeForWords:words options:opts range:inRange];
			noteIndex = noteIndex + reversed ? -1 : 1;
		} while (range.location == NSNotFound && (reversed ? noteIndex > 0 : noteIndex < count - 1));
	}
	
	return range;
}
#endif

- (void)addMenuItemsForURLsInNotes:(NSMenu*)urlsMenu {
	//iterate over notes in array
	//accumulate links as NSMenuItems, with separators between them and disabled items being names of notes
	unsigned int i;
	
	//while ([urlsMenu numberOfItems]) {
	//	[urlsMenu removeItemAtIndex:0];
	//}
	
//	NSMenu *urlsMenu = [[NSMenu alloc] initWithTitle:@"URLs Menu"];
	NSDictionary *blackAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont menuFontOfSize:13.0f], NSFontAttributeName, nil];
	NSDictionary *grayAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor grayColor], NSForegroundColorAttributeName, 
		[NSFont menuFontOfSize:13.0f], NSFontAttributeName, nil];

	BOOL didAddInitialSeparator = NO;
	
	for (i = 0; i<[self count]; i++) {
		NoteObject *aNote = [self objectAtIndex:i];
		NSArray *urls = [[aNote contentString] allLinks];
		if ([urls count] > 0) {
			if (!didAddInitialSeparator) {
				[urlsMenu addItem:[NSMenuItem separatorItem]];
				didAddInitialSeparator = YES;
			}
			
			unsigned int j;
			for (j=0; j<[urls count]; j++) {
				NSURL *url = [urls objectAtIndex:j];
				NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy URL",@"contextual menu item title to copy urls")
															  action:@selector(copyItemToPasteboard:) keyEquivalent:@""];
				//_other_ people would use "_web_userVisibleString" here, but resourceSpecifier looks like it's good enough
				NSString *urlString = [[url scheme] isEqualToString:@"mailto"] ? [url resourceSpecifier] : [url absoluteString];
				NSString *truncatedURLString = [urlString length] > 60 ? [[urlString substringToIndex: 60] stringByAppendingString:NSLocalizedString(@"...", @"ellipsis character")] : urlString;
				NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] initWithString:[NSLocalizedString(@"Copy ",@"menu item prefix to copy a URL") stringByAppendingString:truncatedURLString] attributes:blackAttrs];
				
				NSAttributedString *titleDesc = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" (%@)", titleOfNote(aNote)] attributes:grayAttrs];
				[titleString appendAttributedString:titleDesc];
				[item setAttributedTitle:titleString];
				[titleDesc release];
				[titleString release];
				[item setRepresentedObject:urlString];
				[item setTarget:[item representedObject]];
				[urlsMenu addItem:item];
				[item release];
			}
		}
	}
//	if (![urlsMenu numberOfItems])
//		[urlsMenu addItemWithTitle:@"No URLs Found" action:NULL keyEquivalent:@""];
	
//	return [urlsMenu autorelease];
}

@end

@implementation NSMutableArray (Sorting)

- (void)sortUnstableUsingFunction:(NSInteger (*)(id *, id *))compare {
	[self sortUsingFunction:(NSInteger (*)(id, id, void *))genericSortContextLast context:compare];
}

- (void)sortStableUsingFunction:(NSInteger (*)(id *, id *))compare usingBuffer:(id **)buffer ofSize:(unsigned int*)bufSize {
	CFIndex count = CFArrayGetCount((CFArrayRef)self);
	
	ResizeBuffer((void***)buffer, count, bufSize);
	
	CFArrayGetValues((CFArrayRef)self, CFRangeMake(0, [self count]), (const void **)*buffer);
	
	mergesort((void *)*buffer, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compare);
	
	CFArrayReplaceValues((CFMutableArrayRef)self, CFRangeMake(0, count), (const void **)*buffer, count);
}

@end