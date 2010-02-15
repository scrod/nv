//
//  KeyDerivationDelaySlider.m
//  Notation
//
//  Created by Zachary Schneirov on 11/11/06.

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

#import "KeyDerivationDelaySlider.h"

@implementation KeyDerivationDelaySliderCell 


- (id)init {
	if ([super init]) {
		[self setNumberOfTickMarks:10];
		[self setMinValue:0.05];
		[self setMaxValue:4.0];
		[self setSliderType:NSLinearSlider];
		[self setTickMarkPosition:NSTickMarkBelow];
		[self setAllowsTickMarkValuesOnly:NO];
		[self setContinuous:YES];

	}
	return self;
}
- (void)stopTracking:(NSPoint)lastPoint at:(NSPoint)stopPoint inView:(NSView *)controlView mouseIsUp:(BOOL)flag {
	if (flag == YES)
		[(KeyDerivationDelaySlider*)[self controlView] mouseUp];
}

@end

@implementation KeyDerivationDelaySlider

- (double)maxValue {
	return exp([super maxValue]);
}
- (double)minValue {
	return exp([super minValue]);
}
- (void)setMinValue:(double)minValue {
	[super setMinValue:log(minValue)];
}
- (void)setMaxValue:(double)maxValue {
	[super setMaxValue:log(maxValue)];
}
- (double)doubleValue {
	return exp([super doubleValue]);
}
- (void)setDoubleValue:(double)aDouble {
	[super setDoubleValue:log(aDouble)];
}

- (id)initWithCoder:(NSCoder *)decoder {
	if ([super initWithCoder:decoder]) {
		[KeyDerivationDelaySlider setCellClass:[KeyDerivationDelaySliderCell class]];
		NSCell *myCell = [[[KeyDerivationDelaySliderCell alloc] init] autorelease];
		[myCell setAction:[[self cell] action]];
		[myCell setTarget:[[self cell] target]];
		[self setCell:myCell];
		
		if ([self cell] != myCell)
			NSLog(@"cellular disintegration!");
	}
	return self;
}

+ (Class)cellClass {
	
	return [KeyDerivationDelaySliderCell class];
}

- (id)delegate {
	return delegate;
}
- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

- (void)mouseUp {
	//send a message to our delegate
	if ([delegate respondsToSelector:@selector(mouseUpForKeyDerivationDelaySlider:)]) {
		[delegate mouseUpForKeyDerivationDelaySlider:self];
	}
}

@end
