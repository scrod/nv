//
//  NotesTableHeaderCell.h
//  Notation
//
//  Created by elasticthreads on 10/19/10.
//

#import <Cocoa/Cocoa.h>


@interface NotesTableHeaderCell : NSTableHeaderCell {
	NSMutableDictionary *attrs;
}

- (void)drawSortIndicatorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView ascending:(BOOL)ascending priority:(NSInteger)priority;
//- (void)drawInteriorWithFrame:(NSRect)inFrame inView:(NSView *)controlView;
- (void)highlight:(BOOL)hBool withFrame:(NSRect)inFrame inView:(NSView *)controlView;
+ (void)setBackgroundColor:(NSColor *)inColor;
+ (void)setForegroundColor:(NSColor *)inColor;

@end
