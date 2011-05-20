//
//  KeyDerivationDelaySlider.h
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
