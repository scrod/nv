//
//  NVPasswordGenerator.h
//  Notation
//
//  Created by Brian Bergstrand on 9/27/2009.
//  Copyright 2009 Brian Bergstrand. All rights reserved.
//

#include "NVPasswordGenerator.h"

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
#include <dispatch/dispatch.h>
#endif

static const char nvDecimalSet[] = "0123456789";
static const char nvLowerCaseSet[] = "abcdefghijklmnopqrstuvwxyz";
static const char nvUpperCaseSet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char nvSymbolSet[] = "!@#$%^&*()-+=?/<>";

@implementation NVPasswordGenerator

+ (NSString*)passwordWithOptions:(NVPasswordOptions)options length:(NSUInteger)len
{
    char source[1024];
    source[0] = 0;
    
    if (0 != (options & knvPasswordNumeric))
        (void)strlcat(source, nvDecimalSet, sizeof(source));
    if (0 != (options & knvPasswordAlpha))
        (void)strlcat(source, nvLowerCaseSet, sizeof(source));
    if (0 != (options & knvPasswordMixedCase))
        (void)strlcat(source, nvUpperCaseSet, sizeof(source));
    if (0 != (options & knvPasswordSymbol))
        (void)strlcat(source, nvSymbolSet, sizeof(source));
    
    // Fill the buffer
    size_t i = strlen(source);
    size_t srclen = sizeof(source)-1 - i;
    (void)strlcpy(&source[i], source, srclen);
    
    char gen[len+1];
    gen[0] = 0;
    srclen = strlen(source);
    for (i = 0; i < len; ++i) {
        char c;
        do {
            c = source[arc4random() % srclen];
        } while (0 == (options & knvPasswordDuplicates) && NULL != strchr(gen, c));
        
        gen[i] = c;
        gen[i+1] = 0;
    }

    return ([NSString stringWithCString:gen encoding:NSASCIIStringEncoding]);
}

+ (NSString*)numericPasswordWithLength:(NSUInteger)len
{
    return ([self passwordWithOptions:knvPasswordNumeric length:len]);
}

+ (NSString*)alphaNumericPasswordWithLength:(NSUInteger)len
{
    return ([self passwordWithOptions:knvPasswordNumeric|knvPasswordAlpha|knvPasswordMixedCase length:len]);
}

+ (NSString*)lightNumeric
{
    return ([self passwordWithOptions:knvPasswordNumeric length:6]);
}

+ (NSString*)light
{
    return ([self passwordWithOptions:knvPasswordNumeric|knvPasswordAlpha|knvPasswordDuplicates length:6]);
}

+ (NSString*)medium
{
    return ([self passwordWithOptions:knvPasswordNumeric|knvPasswordAlpha|knvPasswordMixedCase length:8]);
}

+ (NSString*)strong
{
    return ([self passwordWithOptions:knvPasswordNumeric|knvPasswordAlpha|knvPasswordMixedCase|knvPasswordSymbol length:10]);
}

+ (NSArray*)suggestions
{
    enum {numSuggestions = 4};
    const SEL methods[numSuggestions] = {@selector(strong), @selector(medium), @selector(light), @selector(lightNumeric)};
    
    NSString* suggest[numSuggestions];
    #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
    dispatch_apply(numSuggestions, dispatch_get_global_queue(0, 0), ^(size_t i) {
    #else
    __block size_t i;
    for (i = 0; i < numSuggestions; ++i) {
    #endif
        //   suggest[i] = [self performSelector:methods[i]];  //BUILD ISSUE
    }
    #if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_6
    );
    #endif
    
    NSArray *a = [NSArray arrayWithObjects:suggest[0], suggest[1], suggest[2], suggest[3], nil];
    return (a);
}

@end
