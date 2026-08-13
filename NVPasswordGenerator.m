//
//  NVPasswordGenerator.h
//  Notation
//
//  Created by Brian Bergstrand on 9/27/2009.
//  Copyright 2009 Brian Bergstrand. All rights reserved.
//

#include "NVPasswordGenerator.h"

static const char nvDecimalSet[] = "0123456789";
static const char nvLowerCaseSet[] = "abcdefghijklmnopqrstuvwxyz";
static const char nvUpperCaseSet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char nvSymbolSet[] = "!@#$%^&*()-+=?/<>";

@implementation NVPasswordGenerator

+ (NSString*)passwordWithOptions:(NVPasswordOptions)options length:(NSUInteger)len
{
   char source[1024] = {0};

   if (options & knvPasswordNumeric)    strlcat(source, nvDecimalSet, sizeof(source));
   if (options & knvPasswordAlpha)      strlcat(source, nvLowerCaseSet, sizeof(source));
   if (options & knvPasswordMixedCase)  strlcat(source, nvUpperCaseSet, sizeof(source));
   if (options & knvPasswordSymbol)     strlcat(source, nvSymbolSet, sizeof(source));

   size_t srclen = strlen(source);
   if (srclen == 0 || len == 0) {
	   return @""; // nothing to choose from or zero length requested
   }
   if (!(options & knvPasswordDuplicates) && len > srclen) {
	   // cannot make more unique chars than exist in the pool
	   len = srclen; // or: return nil / raise / flip the flag, your call
   }

   char gen[len + 1];
   gen[0] = 0;

   for (size_t i = 0; i < len; ++i) {
	   char c;
	   do {
		   c = source[arc4random_uniform((uint32_t)srclen)];
	   } while ((!(options & knvPasswordDuplicates)) && strchr(gen, c) != NULL);

	   gen[i] = c;
	   gen[i + 1] = 0;
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

@end
