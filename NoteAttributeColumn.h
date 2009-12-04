/* NoteAttributeColumn */

#import <Cocoa/Cocoa.h>

@interface NoteAttributeColumn : NSTableColumn {
	
    NSInteger (*sortFunction) (id*, id*);
    NSInteger (*reverseSortFunction) (id*, id*);
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
- (void)setSortingFunction:(NSInteger (*)(id*, id*))sortFunction;
- (NSInteger (*)(id*, id*))sortFunction;
- (void)setReverseSortingFunction:(NSInteger (*)(id*, id*))aFunction;
- (NSInteger (*)(id*, id*))reverseSortFunction;
- (id (*) (id))objectAttribute;

- (void)setResizingMaskNumber:(NSNumber*)resizingMaskNumber;

@end
