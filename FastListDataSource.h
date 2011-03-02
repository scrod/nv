//
//  FastListDataSource.h
//  Notation
//
//  Created by Zachary Schneirov on 1/8/06.

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

@class NoteAttributeColumn;

@interface FastListDataSource : NSObject {
	id *objects;
    NSUInteger count;
}

- (const id *)immutableObjects;
- (NSUInteger)count;

- (NSUInteger)indexOfObjectIdenticalTo:(id)address;
- (NSArray*)objectsAtFilteredIndexes:(NSIndexSet*)indexSet;

- (void)fillArrayFromArray:(NSArray*)array;
- (BOOL)filterArrayUsingFunction:(BOOL (*)(id, void*))present context:(void*)context;

- (void)sortStableUsingFunction:(NSInteger (*)(id *, id *))compare;

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex;
- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex;
- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView;

@end

@interface NSObject (FastListDataSourceColumnEditing)

- (SEL)attributeSetterForColumn:(NoteAttributeColumn*)col;

@end

