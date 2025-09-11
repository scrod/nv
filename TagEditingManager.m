//
//  TagEditingManager.m
//  Notation
//
//  Created by elasticthreads on 10/15/10.
//

#import "TagEditingManager.h"

@implementation TagEditingManager

@synthesize commonTags;
@synthesize tagFieldString;

- (id)initWithDelegate:(id)del commonTags:(NSArray *)cTags atPoint:(NSPoint)centerpoint {
    if ((self = [super init])) {
        if (![NSBundle loadNibNamed:@"TagEditingManager" owner:self])  {
            NSLog(@"Failed to load TagEditingManager.nib");
        } else {
            isHappening = YES;
            NSRect zRect = [tagPanel frame];
            centerpoint.x -= (zRect.size.width/2.0);
            centerpoint.y -= (zRect.size.height+70.0);
            [tagPanel setDelegate:self];
            [tagField setDelegate:del];
            self.commonTags = cTags;
            [tagPanel setFrameOrigin:centerpoint];
            [tagPanel makeKeyAndOrderFront:del];
        }
    }
    return self;
}

- (void)dealloc {
    [tagFieldString release];
    [commonTags release];
    [tagPanel release];
    [tagField release];
    [super dealloc];
}

- (void)setCommonTags:(NSArray *)newTags {
    if (commonTags) {
        [commonTags release];
        commonTags = nil;
    }
    commonTags = [newTags retain];
    if (isHappening) {
        NSString *newTagString = @"";
        if (commonTags && ([commonTags count] > 0)) {
            newTagString = [commonTags componentsJoinedByString:@","];
        }
        self.tagFieldString = newTagString;
    } else {
        self.tagFieldString = @"";
    }
}

- (void)cancelOperation:(id)sender {
    [tagPanel orderOut:nil];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if ([tagPanel isVisible]) {
        [tagPanel orderOut:nil];
    }
    isHappening = NO;
    self.commonTags = [NSArray array];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TagEditorShouldRelease" object:nil];
}

- (void)setTF:(NSString *)inString {
    [tagField setStringValue:inString];
}

- (void)closeTP:(id)sender {
    [tagPanel orderOut:nil];
}

- (NSTextView *)tagFieldEditor {
    return (NSTextView *)[tagPanel fieldEditor:YES forObject:tagField];
}

- (NSTextField *)tagField {
    return tagField;
}

- (BOOL)isMultitagging {
    return isHappening;
}

@end

