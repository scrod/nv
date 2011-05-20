//
//  LabelsListController.h
//  Notation
//
//  Created by Zachary Schneirov on 1/10/06.

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
#import "FastListDataSource.h"

@class NoteObject;
@class LabelObject;

@interface LabelsListController : FastListDataSource {
	NSCountedSet *allLabels, *filteredLabels;
	NSMutableDictionary *labelImages;
	unsigned *removeIndicies;
}

- (void)unfilterLabels;
- (void)filterLabelSet:(NSSet*)labelSet;
- (void)recomputeListFromFilteredSet;

- (NSArray*)labelTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex minusWordSet:(NSSet*)antiSet;

- (void)invalidateCachedLabelImages;
- (NSImage*)cachedLabelImageForWord:(NSString*)aWord highlighted:(BOOL)isHighlighted;

- (NSSet*)notesAtFilteredIndex:(int)labelIndex;
- (NSSet*)notesAtFilteredIndexes:(NSIndexSet*)anIndexSet;

//mostly useful for updating labels of notes individually
- (void)addLabelSet:(NSSet*)labelSet toNote:(NoteObject*)note;
- (void)removeLabelSet:(NSSet*)labelSet fromNote:(NoteObject*)note;

//for changing note labels en masse
- (void)addLabelSet:(NSSet*)labelSet toNoteSet:(NSSet*)notes;
- (void)removeLabelSet:(NSSet*)labelSet fromNoteSet:(NSSet*)notes;

@end
