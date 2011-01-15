//
//  NSString-Textile.h
//  http://github.com/gjherbiet/nv/blob/0da680c487c0f7c277e35a9308ebf50535e7ee06/NSString-Textile.h
//

#import <Cocoa/Cocoa.h>

@class AppController;
@class NoteObject;
@class PreviewController;

@interface NSString (Textile)

+ (NSString*)stringWithProcessedTextile:(NSString*)inputString;
+ (NSString*)documentWithProcessedTextile:(NSString*)inputString;
+ (NSString*)xhtmlWithProcessedTextile:(NSString*)inputString;
+ (NSString*)processTextile:(NSString*)inputString;

@end
