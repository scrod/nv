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


#import "KeyDerivationManager.h"
#import "AttributedPlainText.h"
#import "NotationPrefs.h"
#import "KeyDerivationDelaySlider.h"
#import "NSData_transformations.h"

@implementation KeyDerivationManager

- (id)initWithNotationPrefs:(NotationPrefs*)prefs {
	notationPrefs = [prefs retain];
	
	//compute initial test duration for the current iteration number
	crapData = [[@"random crap" dataUsingEncoding:NSASCIIStringEncoding] retain];
	crapSalt = [[NSData randomDataOfLength:256] retain];
	
	lastHashIterationCount = [notationPrefs hashIterationCount];
	lastHashDuration = [self delayForHashIterations:lastHashIterationCount];
	
	if (![self init]) {
		[self release];
		return nil;
	}
		
	return self;
}

- (void)awakeFromNib {
	//let the user choose a delay between 25 ms and 3 1/2 secs
	[slider setMinValue:0.025];
	[slider setMaxValue:3.5];
	
	[slider setDelegate:self];
	[slider setDoubleValue:lastHashDuration];
	[self sliderChanged:slider];
	
	[self updateToolTip];
}

- (id)init {
	if ([super init]) {
		if (!view) {
			if (![NSBundle loadNibNamed:@"KeyDerivationManager" owner:self])  {
				NSLog(@"Failed to load KeyDerivationManager.nib");
				NSBeep();
				return nil;
			}
		}
	}
		
	return self;
}

- (void)dealloc {
	[notationPrefs release];
	[crapData release];
	[crapSalt release];
	
	[super dealloc];
}

- (NSView*)view {
	return view;
}

- (int)hashIterationCount {
	return lastHashIterationCount;
}

- (void)updateToolTip {
	[slider setToolTip:[NSString stringWithFormat:NSLocalizedString(@"PBKDF2 iterations: %d", nil), lastHashIterationCount]];
}

- (void)mouseUpForKeyDerivationDelaySlider:(KeyDerivationDelaySlider*)aSlider {
	double duration = [aSlider doubleValue];
	lastHashIterationCount = [self estimatedIterationsForDuration:duration];
	
	if (duration > 0.7) [iterationEstimatorProgress startAnimation:nil];
	lastHashDuration = [self delayForHashIterations:lastHashIterationCount];
	if (duration > 0.7) [iterationEstimatorProgress stopAnimation:nil];
	
	//update slider for correction
	[slider setDoubleValue:lastHashDuration];
	
	[self updateToolTip];
}

- (IBAction)sliderChanged:(id)sender {
	[hashDurationField setAttributedStringValue:[NSAttributedString timeDelayStringWithNumberOfSeconds:[sender doubleValue]]];
}

- (double)delayForHashIterations:(int)count {
	NSDate *before = [NSDate date];
	[crapData derivedKeyOfLength:[notationPrefs keyLengthInBits]/8 salt:crapSalt iterations:count];
	return [[NSDate date] timeIntervalSinceDate:before];
}

- (int)estimatedIterationsForDuration:(double)duration {
	//we could compute several hash durations at varying counts and use polynomial interpolation, but that may be overkill
	
	int count = (int)((duration * (double)lastHashIterationCount) / (double)lastHashDuration);
	
	int minCount = MAX(2000, count);
	//on a 1GHz machine, don't make them wait more than a minute
	return MIN(minCount, 9000000);
}

@end
