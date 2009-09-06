/* NoteAttributeColumn */

#import <Cocoa/Cocoa.h>

@interface NoteAttributeColumn : NSTableColumn {
	
    int (*sortFunction) (id*, id*);
    int (*reverseSortFunction) (id*, id*);
    id (*objectAttribute) (id);
    SEL mutateObjectSelector;
	
	float absoluteMinimumWidth;
}

+ (NSDictionary*)standardDictionary;
SEL columnAttributeMutator(NoteAttributeColumn *col);
- (void)setMutatingSelector:(SEL)selector;
id columnAttributeForObject(NoteAttributeColumn *col, id object);
- (void)updateWidthForHighlight;
- (void)setDereferencingFunction:(id (*)(id))attributeFunction;
- (void)setSortingFunction:(int (*)(id*, id*))sortFunction;
- (int (*)(id*, id*))sortFunction;
- (void)setReverseSortingFunction:(int (*)(id*, id*))aFunction;
- (int (*)(id*, id*))reverseSortFunction;

@end
