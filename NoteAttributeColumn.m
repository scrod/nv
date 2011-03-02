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


#import "NoteAttributeColumn.h"
#import "NotesTableView.h"


@implementation NoteTableHeaderCell

- (NSRect)drawingRectForBounds:(NSRect)theRect {
	return NSInsetRect(theRect, 6.0f, 0.0);
}

@end

@implementation NoteAttributeColumn

- (id)initWithIdentifier:(id)anObject {
	
	if ([super initWithIdentifier:anObject]) {

		absoluteMinimumWidth = [anObject sizeWithAttributes:[NoteAttributeColumn standardDictionary]].width + 5;
		[self setMinWidth:absoluteMinimumWidth];
	}
	
	return self;
}

+ (NSDictionary*)standardDictionary {
	static NSDictionary *standardDictionary = nil;
	if (!standardDictionary)
		standardDictionary = [[NSDictionary dictionaryWithObjectsAndKeys:
			[NSFont systemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, nil] retain];	

	return standardDictionary;
}

- (void)updateWidthForHighlight {
	[self setMinWidth:absoluteMinimumWidth + ([[self tableView] highlightedTableColumn] == self ? 10 : 0)];
}

SEL columnAttributeMutator(NoteAttributeColumn *col) {
	return col->mutateObjectSelector;
}

- (void)setMutatingSelector:(SEL)selector {
	mutateObjectSelector = selector;
}

id columnAttributeForObject(NotesTableView *tv, NoteAttributeColumn *col, id object, NSInteger row) {
	return col->objectAttribute(tv, object, row);
}

- (void)setDereferencingFunction:(id (*)(id, id, NSInteger))attributeFunction {
    objectAttribute = attributeFunction;
}

- (void)setSortingFunction:(NSInteger (*)(id *, id *))aFunction {
    sortFunction = aFunction;
}

- (NSInteger (*)(id *, id *))sortFunction {
    return sortFunction;
}

- (void)setReverseSortingFunction:(NSInteger (*)(id*, id*))aFunction {
    reverseSortFunction = aFunction;
}

- (NSInteger (*)(id*, id*))reverseSortFunction {
    return reverseSortFunction;
}
id (*dereferencingFunction(NoteAttributeColumn *col))(id, id, NSInteger) {
	return col->objectAttribute;
}

- (void)setResizingMaskNumber:(NSNumber*)resizingMaskNumber {
	[self setResizingMask:[resizingMaskNumber unsignedIntValue]];
}

@end
