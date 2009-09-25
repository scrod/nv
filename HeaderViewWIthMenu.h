/* HeaderViewWIthMenu */

#import <Cocoa/Cocoa.h>

@interface HeaderViewWithMenu : NSTableHeaderView
{
	BOOL isReloading;
}

- (void)setIsReloading:(BOOL)reloading;
@end
