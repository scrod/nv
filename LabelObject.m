//
//  LabelObject.m
//  Notation
//
//  Created by Zachary Schneirov on 12/30/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

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
