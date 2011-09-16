//
//  ETScrollView.m
//  Notation
//
//  Created by elasticthreads on 3/14/11.
//

#import <Foundation/Foundation.h>



@interface ETScrollView : NSScrollView {
    Class scrollerClass;
    BOOL needsOverlayTiling;
}

//- (void)setNeedsOverlayTiling:(BOOL)overlay;
//- (void)setScrollerClassWithString:(NSString *)scrollerClassName;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
- (void)changeUseETScrollbarsOnLion;
- (void)settingChangedForSelectorString:(NSString*)selectorString;
#endif

@end
