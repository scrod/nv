//
//  NSString_MultiMarkdown.h
//  Notation
//
//  Created by Christian Tietze on 2010-10-10.
//

#import <Cocoa/Cocoa.h>


@interface NSString (MultiMarkdown)

+ (NSString*)stringWithProcessedMultiMarkdown:(NSString*)inputString;
+ (NSString*)documentWithProcessedMultiMarkdown:(NSString*)inputString;
+ (NSString*)processMultiMarkdown:(NSString*)inputString;

@end
