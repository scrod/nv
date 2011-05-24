//
//  NSString_MultiMarkdown.h
//  Notation
//
//  Created by Christian Tietze on 2010-10-10.
//

#import <Cocoa/Cocoa.h>

@class AppController;
@class NoteObject;
@class PreviewController;

@interface NSString (MultiMarkdown)

+ (NSString*)stringWithProcessedMultiMarkdown:(NSString*)inputString;
+ (NSString*)documentWithProcessedMultiMarkdown:(NSString*)inputString;
+ (NSString*)xhtmlWithProcessedMultiMarkdown:(NSString*)inputString;
+ (NSString*)processMultiMarkdown:(NSString*)inputString;
+ (NSString*)processTaskPaper:(NSString*)inputString;

@end
