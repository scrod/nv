//
//  FastListDataSource.m
//  Notation
//
//  Created by Zachary Schneirov on 1/8/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import "FastListDataSource.h"
#import "NoteAttributeColumn.h"

@implementation FastListDataSource

- (id)initWithClass:(Class)aClass {
    if ([super init]) {
		objects = NULL;
		count = 0;
		
		if (![aClass instancesRespondToSelector:@selector(retain)] || 
			![aClass instancesRespondToSelector:@selector(release)])
			return nil;
		
		objRetain = [aClass instanceMethodForSelector:@selector(retain)];
		objRelease = [aClass instanceMethodForSelector:@selector(release)];
    }
    
    return self;
}

- (const id *)immutableObjects {
	return (const id *)objects;
}

- (unsigned int)count {
	return count;
}

- (unsigned)indexOfObjectIdenticalTo:(id)address {
	register unsigned i;
	
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

	unsigned int indexBuffer[40];
	unsigned int bufferIndex;
	unsigned int indexCount = 1;
	NSRange range = NSMakeRange([indexSet firstIndex],
								[indexSet lastIndex]-[indexSet firstIndex]+1);
	
	NSMutableArray *objectsInIndexSet = [[NSMutableArray alloc] init];
	
	while ((indexCount = [indexSet getIndexes:indexBuffer maxCount:40 inIndexRange:&range])) {
		
		for (bufferIndex=0; bufferIndex < indexCount; bufferIndex++) {
			unsigned int objIndex = indexBuffer[bufferIndex];
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
	unsigned int oldArraySize = count;
	
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
	register unsigned int j = 0, i, oldCount = count;
	
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

- (void)sortStableUsingFunction:(int (*)(id *, id *))compare {
	
	mergesort((void *)objects, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compare);
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex {
	
	[objects[rowIndex] performSelector:columnAttributeMutator((NoteAttributeColumn*)aTableColumn) withObject:anObject];
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex {
	return columnAttributeForObject((NoteAttributeColumn*)aTableColumn, objects[rowIndex]);
}

- (int)numberOfRowsInTableView:(NSTableView *)aTableView {
	return count;
}

#if 0
- (BOOL)tableView:(NSTableView *)tableView writeRows:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard {
	
	
	NSEvent *event = [[tableView window] currentEvent];
	if ([event modifierFlags] & NSAlternateKeyMask) {
		[pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
		if (![pboard setString:@"burritos" forType:@"HI"]) {
			NSLog(@"Couldn't set data to pasteboard!");
			NSBeep();
			return NO;
		}
		
		return YES;
	}

	NSLog(@"fall-through");
	return NO;
}
#endif

@end
