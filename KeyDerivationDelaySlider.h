//
//  KeyDerivationDelaySlider.h
//  Notation
//
//  Created by Zachary Schneirov on 11/11/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

//mostly to catch mouse-up from a continuous slider

@interface KeyDerivationDelaySliderCell : NSSliderCell {
	
}

@end

@interface KeyDerivationDelaySlider : NSSlider {
	id delegate;
}

- (void)mouseUp;
- (id)delegate;
- (void)setDelegate:(id)aDelegate;

@end

@interface KeyDerivationDelaySlider (KeyDerivationDelaySliderDelegate)

- (void)mouseUpForKeyDerivationDelaySlider:(KeyDerivationDelaySlider*)aSlider;

@end