//
//  BSJSONEncoder.m
//  BSJSONAdditions
//

#import "BSJSONEncoder.h"
#import "NSArray+BSJSONAdditions.h"
#import "NSDictionary+BSJSONAdditions.h"
#import "NSScanner+BSJSONAdditions.h"
#import "NSString+BSJSONAdditions.h"

@implementation BSJSONEncoder

+ (NSString *)jsonStringForValue:(id)value withIndentLevel:(NSInteger)level
{	
	NSString *jsonString;
	if ([value respondsToSelector:@selector(characterAtIndex:)]) { // String
		jsonString = [(NSString *)value jsonStringValue];
	} else if ([value respondsToSelector:@selector(keyEnumerator)]) { // Dictionary
		jsonString = [(NSDictionary *)value jsonStringValueWithIndentLevel:(level + 1)];
	} else if ([value respondsToSelector:@selector(objectAtIndex:)]) { // Array
		jsonString = [(NSArray *)value jsonStringValueWithIndentLevel:level];
	} else if (value == [NSNull null]) { // null
		jsonString = jsonNullString;
	} else if ([value respondsToSelector:@selector(objCType)]) { // NSNumber - representing true, false, and any form of numeric
		NSNumber *number = (NSNumber *)value;
		if (((*[number objCType]) == 'c') && ([number boolValue] == YES)) { // true
			jsonString = jsonTrueString;
		} else if (((*[number objCType]) == 'c') && ([number boolValue] == NO)) { // false
			jsonString = jsonFalseString;
		} else { // attempt to handle as a decimal number - int, fractional, exponential
			// TODO: values converted from exponential json to dict and back to json do not format as exponential again
			jsonString = [[NSDecimalNumber decimalNumberWithDecimal:[number decimalValue]] stringValue];
		}
	} else {
		// TODO: error condition - it's not any of the types that I know about.
		return nil;
	}
	
	return jsonString;
}

@end
