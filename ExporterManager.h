/* ExporterManager */

#import <Cocoa/Cocoa.h>

@interface ExporterManager : NSObject {
	IBOutlet NSView *accessoryView;
	IBOutlet NSPopUpButton *formatSelectorPopup;
	
}

+ (ExporterManager *)sharedManager;
- (IBAction)formatSelectorChanged:(id)sender;
- (void)exportNotes:(NSArray*)notes forWindow:(NSWindow*)window;

@end
