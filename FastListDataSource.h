//
//  FastListDataSource.h
//  Notation
//
//  Created by Zachary Schneirov on 1/8/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface FastListDataSource : NSObject {
	id *objects;
    unsigned int count;
	IMP objRetain, objRelease;
}

- (id)initWithClass:(Class)aClass;
- (const id *)immutableObjects;
- (unsigned int)count;

- (unsigned)indexOfObjectIdenticalTo:(id)address;
- (NSArray*)objectsAtFilteredIndexes:(NSIndexSet*)indexSet;

- (void)fillArrayFromArray:(NSArray*)array;
- (BOOL)filterArrayUsingFunction:(BOOL (*)(id, void*))present context:(void*)context;

- (void)sortStableUsingFunction:(int (*)(id *, id *))compare;

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex;
- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex;
- (int)numberOfRowsInTableView:(NSTableView *)aTableView;

@end
