/* HeaderViewWIthMenu */

#import <Cocoa/Cocoa.h>

@interface NSTableHeaderView (Private)
- (void)_resizeColumn:(NSInteger)resizedColIdx withEvent:(id)event;
@end

@interface HeaderViewWithMenu : NSTableHeaderView
{
	BOOL isReloading;
}

- (void)_resizeColumn:(NSInteger)resizedColIdx withEvent:(id)event;

- (void)setIsReloading:(BOOL)reloading;
@end
