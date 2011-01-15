//
//  LabelsListController.m
//  Notation
//
//  Created by Zachary Schneirov on 1/10/06.

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


#import "LabelsListController.h"
#import "LabelObject.h"
#import "NoteObject.h"
#import "NSCollection_utils.h"


@implementation LabelsListController

- (id)init {
	if ([super init]) {
	    
	    allLabels = [[NSCountedSet alloc] init]; //authoritative
	    //for faster(?) filtering during search
	    filteredLabels = [[NSCountedSet alloc] init];
		
	    removeIndicies = NULL;
	}
	
	return self;
}

- (void)unfilterLabels {
    [filteredLabels setSet:allLabels];
    
    if ([filteredLabels count] > count) {
		count = [filteredLabels count];
		objects = (id*)realloc(objects, count * sizeof(id));
    }
    [filteredLabels getObjects:objects];
    
}

- (void)filterLabelSet:(NSSet*)labelSet {
	[filteredLabels minusSet:labelSet];
}

- (void)recomputeListFromFilteredSet {
    //we can ignore our objectsArray here as we never use it and just sort directly on our C-array
	[filteredLabels getObjects:objects];
	count = [filteredLabels count];
	
	//cfstringcompare here; strings always sorted alphabetically
	mergesort((void *)objects, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compareLabel);
}


//NotationController will probably want to filter these further if there is already a search in progress
- (NSSet*)notesAtFilteredIndex:(int)labelIndex {
    return [objects[labelIndex] noteSet];
}

//figure out which notes to display given some selected labels
- (NSSet*)notesAtFilteredIndexes:(NSIndexSet*)anIndexSet {
    NSUInteger i, numLabels = [anIndexSet count];
    NSUInteger *labelsBuffer = malloc(numLabels * sizeof(NSUInteger));
    
    NSRange range = NSMakeRange([anIndexSet firstIndex], ([anIndexSet lastIndex]-[anIndexSet firstIndex]) + 1);
    [anIndexSet getIndexes:labelsBuffer maxCount:numLabels inIndexRange:&range];
    
    NSMutableSet *notesOfLabels = [[NSMutableSet alloc] init];

    for (i=0; i<numLabels; i++) {
	int labelIndex = labelsBuffer[i];
	[notesOfLabels unionSet:[objects[labelIndex] noteSet]];
    }
    
    return [notesOfLabels autorelease];
}


/* these next two methods do NOT sync. object counts with the corresponding LabelObject(s) in allLabels;
   it's up to the sender to ensure that any given note is not added or removed from a label unnecessarily */

//called when deleting labels in a note
- (void)removeLabelSet:(NSSet*)labelSet fromNote:(NoteObject*)note {
    
    //labelSet in this case is probably not the prototype labelSet, so all that may be necessary is to call removeNote: on it
    //HOWEVER, don't know this for sure, assuming this API is to remain non-permeable
    
    [allLabels minusSet:labelSet];
    
    //we narrow down the set to make sure that we operate on the actual objects within it, and note the objects used as prototypes
    //these will be any labels that were shared by notes other than this one
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(removeNote:) withObject:note];
}

//called for labels added to a note
- (void)addLabelSet:(NSSet*)labelSet toNote:(NoteObject*)note {
    
    [allLabels unionSet:labelSet];
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(addNote:) withObject:note];
    [note replaceMatchingLabelSet:existingLabels]; //link back for the existing note, so that it knows about the other notes in this label
}


//useful for moving groups of notes from one label to another
- (void)removeLabelSet:(NSSet*)labelSet fromNoteSet:(NSSet*)notes {    
    [allLabels minusSet:labelSet];
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(removeNoteSet:) withObject:notes];
}

- (void)addLabelSet:(NSSet*)labelSet toNoteSet:(NSSet*)notes {
    [allLabels unionSet:labelSet];
    
    NSMutableSet *existingLabels = [allLabels setIntersectedWithSet:labelSet];
    [existingLabels makeObjectsPerformSelector:@selector(addNoteSet:) withObject:notes];
    [notes makeObjectsPerformSelector:@selector(replaceMatchingLabelSet:) withObject:existingLabels];
}


@end
