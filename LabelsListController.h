//
//  LabelsListController.h
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


#import <Cocoa/Cocoa.h>
#import "FastListDataSource.h"

@class NoteObject;
@class LabelObject;

@interface LabelsListController : FastListDataSource {
	NSCountedSet *allLabels, *filteredLabels;
	unsigned *removeIndicies;
}

- (void)unfilterLabels;
- (void)filterLabelSet:(NSSet*)labelSet;
- (void)recomputeListFromFilteredSet;

- (NSSet*)notesAtFilteredIndex:(int)labelIndex;
- (NSSet*)notesAtFilteredIndexes:(NSIndexSet*)anIndexSet;

//mostly useful for updating labels of notes individually
- (void)addLabelSet:(NSSet*)labelSet toNote:(NoteObject*)note;
- (void)removeLabelSet:(NSSet*)labelSet fromNote:(NoteObject*)note;

//for changing note labels en masse
- (void)addLabelSet:(NSSet*)labelSet toNoteSet:(NSSet*)notes;
- (void)removeLabelSet:(NSSet*)labelSet fromNoteSet:(NSSet*)notes;

@end
