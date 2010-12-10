//
//  NVPasswordGenerator.h
//  Notation
//
//  Created by Brian Bergstrand on 9/27/2009.
//  Copyright 2009 Brian Bergstrand. All rights reserved.
//

#include <Foundation/Foundation.h>

enum {
    knvPasswordNumeric = 0x00000001UL,
    knvPasswordAlpha = 0x00000002UL,
    knvPasswordSymbol = 0x00000004UL,
    knvPasswordMixedCase = 0x00000008UL,
    knvPasswordDuplicates = 0x00000010UL,
};
typedef NSUInteger NVPasswordOptions;

@interface NVPasswordGenerator : NSObject {

}

+ (NSString*)passwordWithOptions:(NVPasswordOptions)options length:(NSUInteger)len;
+ (NSString*)numericPasswordWithLength:(NSUInteger)len;
+ (NSString*)alphaNumericPasswordWithLength:(NSUInteger)len;

+ (NSString*)light;
+ (NSString*)medium;
+ (NSString*)strong;

// ordered from strong to light
+ (NSArray*)suggestions;

@end
