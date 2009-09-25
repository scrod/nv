//
//  KeyDerivationDelaySlider.m
//  Notation
//
//  Created by Zachary Schneirov on 11/11/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

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
