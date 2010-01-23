//  BSJSONAdditions
//
//  Created by Blake Seely on 2009/03/24.
//  Copyright 2006 Blake Seely - http://www.blakeseely.com  All rights reserved.
//  Permission to use this code:
//
//  Feel free to use this code in your software, either as-is or 
//  in a modified form. Either way, please include a credit in 
//  your software's "About" box or similar, mentioning at least 
//  my name (Blake Seely).
//
//  Permission to redistribute this code:
//
//  You can redistribute this code, as long as you keep these 
//  comments. You can also redistribute modified versions of the 
//  code, as long as you add comments to say that you've made 
//  modifications (keeping these original comments too).
//
//  If you do use or redistribute this code, an email would be 
//  appreciated, just to let me know that people are finding my 
//  code useful. You can reach me at blakeseely@mac.com

#import "NSArray+BSJSONAdditions.h"
#import "NSScanner+BSJSONAdditions.h"
#import "BSJSONEncoder.h"

@implementation NSArray (BSJSONAdditions)

+ (NSArray *)arrayWithJSONString:(NSString *)jsonString
{
	NSScanner *scanner = [[NSScanner alloc] initWithString:jsonString];
	NSArray *array = nil;
	[scanner scanJSONArray:&array];
	[scanner release];
	
	return array;
}

- (NSString *)jsonStringValue
{
	return [self jsonStringValueWithIndentLevel:0];
}

- (NSString *)jsonStringValueWithIndentLevel:(NSInteger)level
{
	NSMutableString *jsonString = [[NSMutableString alloc] init];
	[jsonString appendString:jsonArrayStartString];
	
	if ([self count] > 0) {
		[jsonString appendString:[BSJSONEncoder jsonStringForValue:[self objectAtIndex:0] withIndentLevel:level]];
	}
	
	NSUInteger i;
  NSString *encoded;
	for (i = 1; i < [self count]; i++) {
    encoded = [BSJSONEncoder jsonStringForValue:[self objectAtIndex:i] withIndentLevel:level];
		[jsonString appendFormat:@"%@ %@", jsonValueSeparatorString, encoded];
	}
	
	[jsonString appendString:jsonArrayEndString];
	return [jsonString autorelease];
}

@end
