/* NoteAttributeColumn */

#import <Cocoa/Cocoa.h>

@class NotesTableView;

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
