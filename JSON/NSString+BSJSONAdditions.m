//
//  NSString+BSJSONAdditions.m
//  BSJSONAdditions
//
//  Created by Blake Seely (Air) on 3/24/09.
//  Copyright 2009 Apple Inc.. All rights reserved.
//

#import "NSScanner+BSJSONAdditions.h"
#import "NSString+BSJSONAdditions.h"

@implementation NSString (BSJSONAdditions)

+ (NSString *)jsonIndentStringForLevel:(NSInteger)level
{
  if (level != jsonDoNotIndent) {
    return [@"\n" stringByPaddingToLength:(level + 1) withString:jsonIndentString startingAtIndex:0];
  } else {
    return [NSString stringWithString: @""];
  }
}

- (NSString *)jsonStringValue
{
	NSMutableString *jsonString = [[NSMutableString alloc] init];
	[jsonString appendString:jsonStringDelimiterString];
	
	// Build the result one character at a time, inserting escaped characters as necessary
	NSUInteger i;
	unichar nextChar;
	for (i = 0; i < [self length]; i++) {
		nextChar = [self characterAtIndex:i];
		switch (nextChar) {
			case '\"':
				[jsonString appendString:@"\\\""];
				break;
			case '\\':
				[jsonString appendString:@"\\\\"];
				break;
			case '/':
				[jsonString appendString:@"\\/"];
				break;
			case '\b':
				[jsonString appendString:@"\\b"];
				break;
			case '\f':
				[jsonString appendString:@"\\f"];
				break;
			case '\n':
				[jsonString appendString:@"\\n"];
				break;
			case '\r':
				[jsonString appendString:@"\\r"];
				break;
			case '\t':
				[jsonString appendString:@"\\t"];
				break;
      /* TODO: Find and encode unicode characters here?
      case '\u':
        [jsonString appendString:@"\\n"];
        break;
        */
			default:
				[jsonString appendFormat:@"%C", nextChar];
				break;
		}
	}
	[jsonString appendString:jsonStringDelimiterString];
	
	return [jsonString autorelease];
}

@end
