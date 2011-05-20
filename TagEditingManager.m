//
//  TagEditingManager.m
//  Notation
//
//  Created by elasticthreads on 10/15/10.
//

#import "TagEditingManager.h"
#import "AppController.h"

@implementation TagEditingManager


- (id)init
{
	if ([super init]) {
		if (![NSBundle loadNibNamed:@"TagEditingManager" owner:self])  {
			NSLog(@"Failed to load TagEditer.nib");
		}
	}
	return self;
}

- (void)dealloc{
	[tagPanel release];
	[tagField release];
	[super dealloc];
}

- (void)awakeFromNib {
	[tagField setStringValue:@""];
//	[tagField setDelegate:self];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command{
	if (command == @selector(cancelOperation:)) {
		[tagPanel orderOut:self];
		NSLog(@"tagman cancaelr");
		//[self closeTP:self];
	}
	return NO;
}

- (NSString *)newMultinoteLabels{
	return [[tagField stringValue] retain];
}

- (void)setTF:(NSString *)inString{
	[tagField setStringValue:inString];	
}

- (void)popTP:(id)sender{
	[tagPanel center];
	[tagPanel makeKeyAndOrderFront:sender];
    isHappening = YES;

}

- (void)setDel:(id)sender{
	[tagPanel setDelegate:sender];
	[tagField setDelegate:sender];
   // [[tagPanel fieldEditor:YES forObject:tagField]setDelegate:sender];
}

- (void)closeTP:(id)sender{
    if (isHappening &&([tagPanel isVisible])) {
        [tagPanel orderOut:sender];
    }    
    isHappening = NO;
	[tagField setStringValue:@""];
}

- (NSPanel *)tagPanel {
	return tagPanel;
}

- (NSTextField *)tagField{
    return tagField;
}

- (BOOL)isMultitagging{
    return isHappening;
}


@end
