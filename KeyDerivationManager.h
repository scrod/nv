/* KeyDerivationManager */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import <Cocoa/Cocoa.h>

@class NotationPrefs;
@class KeyDerivationDelaySlider;

@interface KeyDerivationManager : NSObject
{
    IBOutlet NSTextField *hashDurationField;
    IBOutlet KeyDerivationDelaySlider *slider;
    IBOutlet NSView* view;
	IBOutlet NSProgressIndicator *iterationEstimatorProgress;
	
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
