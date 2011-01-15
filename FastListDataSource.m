//
//  FastListDataSource.m
//  Notation
//
//  Created by Zachary Schneirov on 1/8/06.

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
	
	[objects[rowIndex] performSelector:columnAttributeMutator((NoteAttributeColumn*)aTableColumn) withObject:anObject];
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	
	return columnAttributeForObject((NotesTableView*)aTableView, (NoteAttributeColumn*)aTableColumn, objects[rowIndex]);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	return count;
}

@end

