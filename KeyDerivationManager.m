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
