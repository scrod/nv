/* NoteAttributeColumn */

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

@class NotesTableView;

@interface NoteTableHeaderCell : NSTableHeaderCell {
	
}

@end

@interface NoteAttributeColumn : NSTableColumn {
	
    NSInteger (*sortFunction) (id*, id*);
    NSInteger (*reverseSortFunction) (id*, id*);
    id (*objectAttribute) (id, id, NSInteger);
	SEL mutateObjectSelector;
	float absoluteMinimumWidth;
}

+ (NSDictionary*)standardDictionary;
SEL columnAttributeMutator(NoteAttributeColumn *col);
- (void)setMutatingSelector:(SEL)selector;
id columnAttributeForObject(NotesTableView *tv, NoteAttributeColumn *col, id object, NSInteger row);
- (void)updateWidthForHighlight;


id (*dereferencingFunction(NoteAttributeColumn *col))(id, id, NSInteger);
- (void)setDereferencingFunction:(id (*)(id, id, NSInteger))attributeFunction;
- (void)setSortingFunction:(NSInteger (*)(id*, id*))sortFunction;
- (NSInteger (*)(id*, id*))sortFunction;
- (void)setReverseSortingFunction:(NSInteger (*)(id*, id*))aFunction;
- (NSInteger (*)(id*, id*))reverseSortFunction;

- (void)setResizingMaskNumber:(NSNumber*)resizingMaskNumber;

@end
