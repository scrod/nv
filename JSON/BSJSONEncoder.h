//
//  BSJSONEncoder.h
//  BSJSONAdditions
//

#import <Foundation/Foundation.h>

@interface BSJSONEncoder : NSObject
+ (NSString *)jsonStringForValue:(id)value withIndentLevel:(NSInteger)level;
@end
