//
//  BSJSONAdditions
//
//  Created by Blake Seely on 2/1/06.
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
//
//
//  Version 1.2: Includes modifications by Bill Garrison: http://www.standardorbit.com , which included
//    Unit Tests adapted from Jonathan Wight's CocoaJSON code: http://www.toxicsoftware.com 
//    I have included those adapted unit tests in this package.

#import "NSScanner+BSJSONAdditions.h"

NSString *jsonObjectStartString = @"{";
NSString *jsonObjectEndString = @"}";
NSString *jsonArrayStartString = @"[";
NSString *jsonArrayEndString = @"]";
NSString *jsonKeyValueSeparatorString = @":";
NSString *jsonValueSeparatorString = @",";
NSString *jsonStringDelimiterString = @"\"";
NSString *jsonStringEscapedDoubleQuoteString = @"\\\"";
NSString *jsonStringEscapedSlashString = @"\\\\";
NSString *jsonTrueString = @"true";
NSString *jsonFalseString = @"false";
NSString *jsonNullString = @"null";

NSString *jsonIndentString = @"\t"; // Modify this string to change how the output formats.
const NSInteger jsonDoNotIndent = -1;

@implementation NSScanner (PrivateBSJSONAdditions)

- (BOOL)scanJSONObject:(NSDictionary **)dictionary
{
	//[self setCharactersToBeSkipped:nil];
	
	BOOL result = NO;
	
    // Bypass irrelevant characters at the beginning of a JSON string
    NSString *ignoredString;
    [self scanUpToString:jsonObjectStartString intoString:&ignoredString];

	if (![self scanJSONObjectStartString]) {
		// TODO: Error condition. For now, return false result, do nothing with the dictionary handle
	} else {
		NSMutableDictionary *jsonKeyValues = [[[NSMutableDictionary alloc] init] autorelease];
		NSString *key = nil;
		id value;
		[self scanJSONWhiteSpace];
		while (([self scanJSONString:&key]) && ([self scanJSONKeyValueSeparator]) && ([self scanJSONValue:&value])) {
			[jsonKeyValues setObject:value forKey:key];
			[self scanJSONWhiteSpace];
			// check to see if the character at scan location is a value separator. If it is, do nothing.
			if ([[[self string] substringWithRange:NSMakeRange([self scanLocation], 1)] isEqualToString:jsonValueSeparatorString]) {
				[self scanJSONValueSeparator];
			}
		}
		if ([self scanJSONObjectEndString]) {
			// whether or not we found a key-val pair, we found open and close brackets - completing an object
			result = YES;
			*dictionary = jsonKeyValues;
		}
	}
	return result;
}

- (BOOL)scanJSONArray:(NSArray **)array
{
	BOOL result = NO;
	NSMutableArray *values = [[[NSMutableArray alloc] init] autorelease];
	[self scanJSONArrayStartString];
	id value = nil;
	
	while ([self scanJSONValue:&value]) {
		[values addObject:value];
		[self scanJSONWhiteSpace];
		if ([[[self string] substringWithRange:NSMakeRange([self scanLocation], 1)] isEqualToString:jsonValueSeparatorString]) {
			[self scanJSONValueSeparator];
		}
	}
	if ([self scanJSONArrayEndString]) {
		result = YES;
		*array = values;
	}
	
	return result;
}

- (BOOL)scanJSONString:(NSString **)string
{
	BOOL result = NO;
	if ([self scanJSONStringDelimiterString]) {
		NSMutableString *chars = [[[NSMutableString alloc] init] autorelease];
		
		// process character by character until we finish the string or reach another double-quote
		while ((![self isAtEnd]) && ([[self string] characterAtIndex:[self scanLocation]] != '\"')) {
			unichar currentChar = [[self string] characterAtIndex:[self scanLocation]];
			unichar nextChar;
			if (currentChar != '\\') {
				[chars appendFormat:@"%C", currentChar];
				[self setScanLocation:([self scanLocation] + 1)];
			} else {
				nextChar = [[self string] characterAtIndex:([self scanLocation] + 1)];
				switch (nextChar) {
				case '\"':
					[chars appendString:@"\""];
					break;
				case '\\':
					[chars appendString:@"\\"];
					break;
				case '/':
					[chars appendString:@"/"];
					break;
				case 'b':
					[chars appendString:@"\b"];
					break;
				case 'f':
					[chars appendString:@"\f"];
					break;
				case 'n':
					[chars appendString:@"\n"];
					break;
				case 'r':
					[chars appendString:@"\r"];
					break;
				case 't':
					[chars appendString:@"\t"];
					break;
				case 'u': // unicode sequence - get string of hex chars, convert to int, convert to unichar, append
					[self setScanLocation:([self scanLocation] + 2)]; // advance past '\u'
          if (![self scanUnicodeCharacterIntoString: chars]) return NO;
					[self setScanLocation:([self scanLocation] + 2)];
					break;
				default:
					[chars appendFormat:@"\\%C", nextChar];
					break;
				}
				[self setScanLocation:([self scanLocation] + 2)];
			}
		}
		
		if (![self isAtEnd]) {
			result = [self scanJSONStringDelimiterString];
			*string = chars;
		}
		
		return result;
	
		/* this code is more appropriate if you have a separate method to unescape the found string
			for example, between inputting json and outputting it, it may make more sense to have a category on NSString to perform
			escaping and unescaping. Keeping this code and looking into this for a future update.
		NSUInteger searchLength = [[self string] length] - [self scanLocation];
		NSUInteger quoteLocation = [[self string] rangeOfString:jsonStringDelimiterString options:0 range:NSMakeRange([self scanLocation], searchLength)].location;
		searchLength = [[self string] length] - quoteLocation;
		while (([[[self string] substringWithRange:NSMakeRange((quoteLocation - 1), 2)] isEqualToString:jsonStringEscapedDoubleQuoteString]) &&
			   (quoteLocation != NSNotFound) &&
			   (![[[self string] substringWithRange:NSMakeRange((quoteLocation -2), 2)] isEqualToString:jsonStringEscapedSlashString])){
			searchLength = [[self string] length] - (quoteLocation + 1);
			quoteLocation = [[self string] rangeOfString:jsonStringDelimiterString options:0 range:NSMakeRange((quoteLocation + 1), searchLength)].location;
		}
		
		*string = [[self string] substringWithRange:NSMakeRange([self scanLocation], (quoteLocation - [self scanLocation]))];
		// TODO: process escape sequences out of the string - replacing with their actual characters. a function that does just this belongs
		// in another class. So it may make more sense to change this whole implementation to just go character by character instead.
		[self setScanLocation:(quoteLocation + 1)];
		*/
		result = YES;
		
	}
	
	return result;
}

- (BOOL)scanUnicodeCharacterIntoString:(NSMutableString *)string
{
  NSString *digits = [[self string] substringWithRange:NSMakeRange([self scanLocation], 4)];
  /* START Updated code modified from code fix submitted by Bill Garrison
           - March 28, 2006 - http://www.standardorbit.net */
  NSScanner *hexScanner = [NSScanner scannerWithString:digits];
  NSString *verifiedHexDigits;
  NSCharacterSet *hexDigitSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
  if (NO == [hexScanner scanCharactersFromSet:hexDigitSet intoString:&verifiedHexDigits]) {
    return NO;
  }
  if (4 != [verifiedHexDigits length]) {
    return NO;
  }
  
  // Read in the hex value
  [hexScanner setScanLocation:0];
  unsigned unicodeHexValue;
  if (NO == [hexScanner scanHexInt:&unicodeHexValue]) {
    return NO;
  }
  [string appendFormat:@"%C", unicodeHexValue];
  /* END update - March 28, 2006 */
  return YES;
}

- (NSUInteger)locationOfString:(NSString *)searchedString
{
	// Since we have already scanned white space, we know that we're at the start of some value, and each of the strings
	// is at most four characters, so just look ahead that many spaces. (In previous versions of the code, I was scanning
	// ahead through the entire string, but this was incredibly expensive for long strings - adding massive amounts of
	// time to scan way past the string we might care about)

  NSUInteger scanLength = [[self string] length] - [self scanLocation];
  scanLength = MIN(scanLength, searchedString.length);
  NSRange searchRange = NSMakeRange([self scanLocation], scanLength);
	return [[self string] rangeOfString:searchedString options:0 range:searchRange].location;
}

- (BOOL)scanJSONValue:(id *)value
{
	BOOL result = NO;
	
	[self scanJSONWhiteSpace];
	
  NSUInteger scanLocation = [self scanLocation];
  NSUInteger trueLocation = [self locationOfString:jsonTrueString];
  NSUInteger falseLocation = [self locationOfString:jsonFalseString];
  NSUInteger nullLocation = [self locationOfString:jsonNullString];
  unichar currentCharacter = [[self string] characterAtIndex:scanLocation];
  NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
  NSString *substring = [NSString stringWithFormat: @"%c", currentCharacter];

	if ([substring isEqualToString:jsonStringDelimiterString]) {
		result = [self scanJSONString:value];
	} else if ([substring isEqualToString:jsonObjectStartString]) {
		result = [self scanJSONObject:value];
	} else if ([substring isEqualToString:jsonArrayStartString]) {
		result = [self scanJSONArray:value];
	} else if (scanLocation == trueLocation) {
		result = YES;
		*value = [NSNumber numberWithBool:YES];
		[self setScanLocation:(scanLocation + jsonTrueString.length)];
	} else if (scanLocation == falseLocation) {
		result = YES;
		*value = [NSNumber numberWithBool:NO];
		[self setScanLocation:(scanLocation + jsonFalseString.length)];
	} else if (scanLocation == nullLocation) {
		result = YES;
		*value = [NSNull null];
		[self setScanLocation:(scanLocation + jsonNullString.length)];
	} else if (([digits characterIsMember:currentCharacter]) || (currentCharacter == '-')) {
		result = [self scanJSONNumber:value];
	}
	return result;
}

- (BOOL)scanJSONNumber:(NSNumber **)number
{
	NSDecimal aDecimal;
	BOOL isDecimal = [self scanDecimal:&aDecimal];
	if ( isDecimal ) {
		*number = [NSDecimalNumber decimalNumberWithDecimal:aDecimal];
	}
	return isDecimal;
}

- (BOOL)scanJSONWhiteSpace
{
	//NSLog(@"Scanning white space - here are the next ten chars ---%@---", [[self string] substringWithRange:NSMakeRange([self scanLocation], 10)]);
	BOOL result = NO;
	NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	while ([space characterIsMember:[[self string] characterAtIndex:[self scanLocation]]]) {
		[self setScanLocation:([self scanLocation] + 1)];
		result = YES;
	}
	//NSLog(@"Done Scanning white space - here are the next ten chars ---%@---", [[self string] substringWithRange:NSMakeRange([self scanLocation], 10)]);
	return result;
}

- (BOOL)scanJSONKeyValueSeparator
{
	return [self scanString:jsonKeyValueSeparatorString intoString:nil];
}

- (BOOL)scanJSONValueSeparator
{
	return [self scanString:jsonValueSeparatorString intoString:nil];
}

- (BOOL)scanJSONObjectStartString
{
	return [self scanString:jsonObjectStartString intoString:nil];
}

- (BOOL)scanJSONObjectEndString
{
	return [self scanString:jsonObjectEndString intoString:nil];
}

- (BOOL)scanJSONArrayStartString
{
	return [self scanString:jsonArrayStartString intoString:nil];
}

- (BOOL)scanJSONArrayEndString
{
	return [self scanString:jsonArrayEndString intoString:nil];
}

- (BOOL)scanJSONStringDelimiterString;
{
	return [self scanString:jsonStringDelimiterString intoString:nil];
}

@end
