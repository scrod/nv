#import "NoteAttributeColumn.h"

@implementation NoteAttributeColumn



- (id)initWithIdentifier:(id)anObject {
	
	if ([super initWithIdentifier:anObject]) {

		absoluteMinimumWidth = [anObject sizeWithAttributes:[NoteAttributeColumn standardDictionary]].width + 2;
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

id columnAttributeForObject(NoteAttributeColumn *col, id object) {
	return col->objectAttribute(object);
}

- (void)setDereferencingFunction:(id (*)(id))attributeFunction {
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
id (*dereferencingFunction(NoteAttributeColumn *col))(id) {
	return col->objectAttribute;
}

- (void)setResizingMaskNumber:(NSNumber*)resizingMaskNumber {
	[self setResizingMask:[resizingMaskNumber unsignedIntValue]];
}

@end
