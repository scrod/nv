//
//  FastListDataSource.m
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


#import "FastListDataSource.h"
#import "NotesTableView.h"
#import "NoteAttributeColumn.h"

@implementation FastListDataSource

- (const id *)immutableObjects {
	return (const id *)objects;
}

- (NSUInteger)count {
	return count;
}

- (NSUInteger)indexOfObjectIdenticalTo:(id)address {
	register NSUInteger i;
	
	if (address) {
		for (i=0; i<count; i++) {
			if (objects[i] == address)
				return i;
		}
	}
	
	return NSNotFound;	
}

//NSArray has objectsAtIndexes--too bad it's only in 10.4.

//figure out which notes are in the indexset
- (NSArray*)objectsAtFilteredIndexes:(NSIndexSet*)indexSet {

	NSUInteger indexBuffer[40];
	NSUInteger bufferIndex;
	NSUInteger indexCount = 1;
	NSRange range = NSMakeRange([indexSet firstIndex],
								[indexSet lastIndex]-[indexSet firstIndex]+1);
	
	NSMutableArray *objectsInIndexSet = [[NSMutableArray alloc] initWithCapacity:[indexSet count]];
	
	while ((indexCount = [indexSet getIndexes:indexBuffer maxCount:40 inIndexRange:&range])) {
		
		for (bufferIndex=0; bufferIndex < indexCount; bufferIndex++) {
			NSUInteger objIndex = indexBuffer[bufferIndex];
			if (objIndex < count)
				[objectsInIndexSet addObject:objects[objIndex]];
			else
				NSLog(@"objectsAtFilteredIndexes: index is %u ( > %u)", objIndex, count);
		}
	}
	
    return [objectsInIndexSet autorelease];
}

//as long as this class is only used for temporary display, we probably do not need to uncomment the retains and releases

- (void)fillArrayFromArray:(NSArray*)array {
	NSUInteger oldArraySize = count;
	
	//release old values
	//unsigned int i;
	if (objects) {
		//for (i=0; i<count; i++)
			//objRelease(objects[i], @selector(release));
	}
	
	count = CFArrayGetCount((CFArrayRef)array);	
	if (count > oldArraySize) {
	    objects = (id*)realloc(objects, count * sizeof(id));
	}

	CFArrayGetValues((CFArrayRef)array, CFRangeMake(0, count), (const void **)objects);
	
	//retain new ones
	//for (i=0; i<count; i++)
		//objRetain(objects[i], @selector(retain));
}

- (BOOL)filterArrayUsingFunction:(BOOL (*)(id, void*))present context:(void*)context {
	register NSUInteger j = 0, i, oldCount = count;
	
	if (!objects)
		return NO;
	
	for (i=0; i<oldCount; i++) {
		id obj = objects[i];
		
		if (present(obj, context)) {
			
			objects[j++] = obj;		
		} else {
			//objRelease(obj, @selector(release));
		}
	}
	
	count = j;
	
	return (count != oldCount);
}

- (void)sortStableUsingFunction:(NSInteger (*)(id *, id *))compare {
	
	mergesort((void *)objects, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compare);
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	
	//allow the tableview to override the selector destination for this object value
	SEL colAttributeMutator = [(NotesTableView*)aTableView attributeSetterForColumn:(NoteAttributeColumn*)aTableColumn];
	
	[objects[rowIndex] performSelector:colAttributeMutator ? colAttributeMutator : columnAttributeMutator((NoteAttributeColumn*)aTableColumn) withObject:anObject];
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	
	return columnAttributeForObject((NotesTableView*)aTableView, (NoteAttributeColumn*)aTableColumn, objects[rowIndex], rowIndex);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	return count;
}

@end

