/* KeyDerivationManager */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


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
