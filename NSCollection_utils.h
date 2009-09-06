//
//  NSCollection_utils.h
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class NoteObject;

@interface NSDictionary (FontTraits)
- (BOOL)attributesHaveFontTrait:(NSFontTraitMask)desiredTrait orAttribute:(NSString*)attrName;
@end

@interface NSMutableDictionary (FontTraits)
- (void)addDesiredAttributesFromDictionary:(NSDictionary*)dict;
- (void)applyStyleInverted:(BOOL)opposite trait:(NSFontTraitMask)trait forFont:(NSFont*)font 
  alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value;
@end

@interface NSSet (Utilities)

- (NSMutableSet*)setIntersectedWithSet:(NSSet*)set;

@end

@interface NSSet (Private)
//in Foundation
- (void)getObjects:(id *)aBuffer;
@end

@interface NSArray (NoteUtilities)
//- (NSRange)nextRangeForString:(NSString*)string activeNote:(NoteObject*)startNote options:(unsigned)opts range:(NSRange)inRange;
- (void)addMenuItemsForURLsInNotes:(NSMenu*)urlsMenu;
- (unsigned int)indexOfNoteWithUUIDBytes:(CFUUIDBytes*)bytes;
@end

@interface NSMutableArray (Sorting)

- (void)sortUnstableUsingFunction:(int (*)(id *, id *))compare;
- (void)sortStableUsingFunction:(int (*)(id *, id *))compare usingBuffer:(id **)buffer ofSize:(unsigned int*)bufSize;
@end