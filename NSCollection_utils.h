//
//  NSCollection_utils.h
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.

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

@interface NSDictionary (HTTP)

+ (NSDictionary*)optionsDictionaryWithTimeout:(float)timeout;
- (NSString*)URLEncodedString;
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
- (NSUInteger)indexOfNoteWithUUIDBytes:(CFUUIDBytes*)bytes;
- (NSArray*)objectsFromDictionariesForKey:(id)aKey;

@end

@interface NSMutableArray (Sorting)

- (void)sortUnstableUsingFunction:(NSInteger (*)(id *, id *))compare;
- (void)sortStableUsingFunction:(NSInteger (*)(id *, id *))compare usingBuffer:(id **)buffer ofSize:(unsigned int*)bufSize;
@end