#import "LabelEditor.h"

@implementation LabelEditor

//provides auto-completion of labels and validation, maybe more

- (void)awakeFromNib {

	NSMutableCharacterSet *legalCharacters = [[NSMutableCharacterSet alloc] init];
	[legalCharacters formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
	[legalCharacters addCharactersInString:@" -&$%#@+"];
	illegalTagCharacters = [[legalCharacters invertedSet] retain];

	//[self setDrawsBackground:YES];
	//[self setBackgroundColor:[NSColor colorWithCalibratedRed:1.0f green:(252.0f/255.0f) blue:(223.0f/255.0f) alpha:1.0]];
	
	NSDictionary *defaultTypingAttributes = [[NSDictionary dictionaryWithObject:[NSColor colorWithCalibratedRed:0.3f green:0.3f blue:0.3f alpha:1.0]
																		 forKey:NSForegroundColorAttributeName] retain];
	[self setTypingAttributes:defaultTypingAttributes];
	[self setUsesFontPanel:NO];
	
	[self setTextContainerInset:NSMakeSize(37, 0)];

	NSRect textFrame = [self frame];
	[self addSubview:labelsLabel positioned:NSWindowBelow relativeTo:[self enclosingScrollView]];
	[labelsLabel setFrame:NSMakeRect(textFrame.origin.x + 3, textFrame.origin.y - 1, 37, 23)];
}

- (BOOL)acceptsFirstResponder {
	return ([[controlField stringValue] length] > 0);
}

- (void)insertNewline:(id)sender {
	[[self window] selectNextKeyView:self];
}

- (void)insertTab:(id)sender {
	//no one should be entering tabs into their tags, anyway
	[[self window] selectNextKeyView:self];
}

- (void)insertBacktab:(id)sender {
	[[self window] makeFirstResponder:controlField];
}


- (void)insertText:(id)aString {
    
    [super insertText:[aString stringByTrimmingCharactersInSet:illegalTagCharacters]];
}

@end
