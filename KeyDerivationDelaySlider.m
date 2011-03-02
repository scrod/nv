//
//  KeyDerivationDelaySlider.m
//  Notation
//
//  Created by Zachary Schneirov on 11/11/06.

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
