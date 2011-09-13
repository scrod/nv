//
//  TestClipView.h
//  TestTextViewApp
//
//  Created by elasticthreads on 8/15/11.
//

#import <AppKit/AppKit.h>

#define kTextMargins 50.0

@interface ETClipView : NSClipView{
}

- (void)clipWidthSettingChanged:(NSRect)frameRect;

@end
