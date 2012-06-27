/*
 Copyright (c) 2012 Curtis Hard - GeekyGoodness
*/
#import <Foundation/Foundation.h>

typedef void (^GGReadabilityParserCompletionHandler)( NSString * content );
typedef void (^GGReadabilityParserErrorHandler)( NSError * error );

enum {
    GGReadabilityParserOptionNone = -1,
    GGReadabilityParserOptionRemoveHeader = 1 << 2,
    GGReadabilityParserOptionRemoveHeaders = 1 << 3,
    GGReadabilityParserOptionRemoveEmbeds = 1 << 4,
    GGReadabilityParserOptionRemoveIFrames = 1 << 5,
    GGReadabilityParserOptionRemoveDivs = 1 << 6,
    GGReadabilityParserOptionRemoveImages = 1 << 7,
    GGReadabilityParserOptionFixImages = 1 << 8,
    GGReadabilityParserOptionFixLinks = 1 << 9,
    GGReadabilityParserOptionClearStyles = 1 << 10,
    GGReadabilityParserOptionClearLinkLists = 1 << 11
}; 
typedef NSInteger GGReadabilityParserOptions;

@interface GGReadabilityParser : NSObject {
    
    float loadProgress;

@private
    GGReadabilityParserErrorHandler errorHandler;
    GGReadabilityParserCompletionHandler completionHandler;
    GGReadabilityParserOptions options;
    NSURL * URL;
    long long dataLength;
    NSMutableData * responseData;
    NSURLConnection * URLConnection;
    NSURLResponse * URLResponse;
    
}

@property ( nonatomic, assign ) float loadProgress;

- (id)initWithURL:(NSURL *)aURL
          options:(GGReadabilityParserOptions)parserOptions
completionHandler:(GGReadabilityParserCompletionHandler)cHandler
     errorHandler:(GGReadabilityParserErrorHandler)eHandler;

- (void)cancel;
- (void)render;
- (void)renderWithString:(NSString *)string;

@end
