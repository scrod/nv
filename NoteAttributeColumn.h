/* NoteAttributeColumn */

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

@class NotesTableView;

@interface NoteTableHeaderCell : NSTableHeaderCell {
	
}

@end

@interface NoteAttributeColumn : NSTableColumn {
	
    NSInteger (*sortFunction) (id*, id*);
    NSInteger (*reverseSortFunction) (id*, id*);
    id (*objectAttribute) (id, id);
    SEL mutateObjectSelector;
	
	float absoluteMinimumWidth;
}

+ (NSDictionary*)standardDictionary;
SEL columnAttributeMutator(NoteAttributeColumn *col);
- (void)setMutatingSelector:(SEL)selector;
id columnAttributeForObject(NotesTableView *tv, NoteAttributeColumn *col, id object);
- (void)updateWidthForHighlight;

id (*dereferencingFunction(NoteAttributeColumn *col))(id, id);
- (void)setDereferencingFunction:(id (*)(id, id))attributeFunction;

- (void)setSortingFunction:(NSInteger (*)(id*, id*))sortFunction;
- (NSInteger (*)(id*, id*))sortFunction;
- (void)setReverseSortingFunction:(NSInteger (*)(id*, id*))aFunction;
- (NSInteger (*)(id*, id*))reverseSortFunction;

- (void)setResizingMaskNumber:(NSNumber*)resizingMaskNumber;

@end
