/* KeyDerivationManager */

#import <Cocoa/Cocoa.h>

@class NotationPrefs;
@class KeyDerivationDelaySlider;

@interface KeyDerivationManager : NSObject
{
    IBOutlet NSTextField *hashDurationField;
    IBOutlet KeyDerivationDelaySlider *slider;
    IBOutlet NSView* view;
	
	int lastHashIterationCount;
	double lastHashDuration;
	
	NSData *crapData, *crapSalt;
	
	NotationPrefs *notationPrefs;
}

- (id)initWithNotationPrefs:(NotationPrefs*)prefs;
- (NSView*)view;
- (IBAction)sliderChanged:(id)sender;
- (int)hashIterationCount;
- (double)delayForHashIterations:(int)count;
- (int)estimatedIterationsForDuration:(double)duration;
- (void)mouseUpForKeyDerivationDelaySlider:(KeyDerivationDelaySlider*)aSlider;
- (void)updateToolTip;
@end
