//
//  LabelObject.m
//  Notation
//
//  Created by Zachary Schneirov on 12/30/05.

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


//this class performs record-keeping of label-note relationships

#import "LabelObject.h"
#import "NoteObject.h"

@implementation LabelObject

- (id)initWithTitle:(NSString*)name {
    if ([super init]) {
		labelName = [name retain];
		lowercaseName = [[name lowercaseString] retain];
	
		lowercaseHash = [lowercaseName hash];
		
		notes = [[NSMutableSet alloc] init];
    }
    
    return self;
}

force_inline NSString* titleOfLabel(LabelObject *label) {
    return label->labelName;
}

int compareLabel(const void *one, const void *two) {
	
    return (int)CFStringCompare((CFStringRef)titleOfLabel(*(LabelObject**)one), 
								(CFStringRef)titleOfLabel(*(LabelObject**)two), kCFCompareCaseInsensitive);
}

- (NSString*)title {
    return labelName;
}

- (NSString*)associativeIdentifier {
    return lowercaseName;
}

- (void)dealloc {
 
    [notes release];
    [labelName release];
    [lowercaseName release];
    [super dealloc];
}

- (void)setTitle:(NSString*)title {
    [labelName release];
    labelName = [title retain];
    
    [lowercaseName release];
    lowercaseName = [[title lowercaseString] retain];
    
    lowercaseHash = [lowercaseName hash];
}

- (void)addNote:(NoteObject*)note {
    [notes addObject:note];
}
- (void)removeNote:(NoteObject*)note {
    [notes removeObject:note];
}

- (void)addNoteSet:(NSSet*)noteSet {
	[notes unionSet:noteSet];
}

- (void)removeNoteSet:(NSSet*)noteSet {
	[notes minusSet:noteSet];
}

- (NSSet*)noteSet {
    return notes;
}

- (NSString*)description {
	return [labelName stringByAppendingFormat:@" (used by %@)", notes];
}

/*- (NSArray*)notesSharedWithSet:(NSSet*)filteredSet {
    NSMutableSet *intersectedSet = [NSMutableSet setWithSet:notes]; 

    [intersectedSet intersectSet:filteredSet];
    
    return [intersectedSet allObjects];
}*/

- (BOOL)isEqual:(id)anObject {
    return [lowercaseName isEqualToString:[anObject associativeIdentifier]];
}
- (unsigned)hash {
    return lowercaseHash;
}


@end
