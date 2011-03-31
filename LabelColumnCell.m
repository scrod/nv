//
//  LabelColumnCell.m
//  Notation
//
//  Created by Zachary Schneirov on 1/18/11.

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

#import "LabelColumnCell.h"
#import "NotesTableView.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"

@implementation LabelColumnCell

- (id)init {
	if ([super init]) {
		[self setEditable:YES];

		[self setFocusRingType:	NSFocusRingTypeExterior];
	}
	return self;
}

- (BOOL)isScrollable {
	return YES;
}


- (NoteObject*)noteObject {
	return noteObject;
}

- (void)setNoteObject:(NoteObject*)obj {
	[noteObject autorelease];
	noteObject = [obj retain];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {	
	NotesTableView *tv = (NotesTableView *)controlView;
	
	NSInteger col = [tv editedColumn];
	BOOL isEditing = [self isHighlighted] && [tv currentEditor] &&
	(col > -1 && [[[[tv tableColumns] objectAtIndex:col] identifier] isEqualToString:NoteLabelsColumnString]);
	
	if (isEditing) {
		[super drawWithFrame:cellFrame inView:controlView];	
	}
	
	if (!isEditing && [labelsOfNote(noteObject) length]) {

		[[NSGraphicsContext currentContext] saveGraphicsState];
		NSRectClip(cellFrame);
		NSRect blocksRect = cellFrame;
		blocksRect.origin = NSMakePoint(NSMinX(cellFrame), NSMaxY(cellFrame) - ceilf(((cellFrame.size.height + 1.0) - 
																					  ([[GlobalPrefs defaultPrefs] tableFontSize] * 1.3 + 1.5))/2.0));
		[noteObject drawLabelBlocksInRect:blocksRect rightAlign:NO highlighted:([self isHighlighted] && [tv isActiveStyle])];
		
		[[NSGraphicsContext currentContext] restoreGraphicsState];
	}
	
}

@end
