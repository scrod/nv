//
//  AttributedPlainText.h
//  Notation
//
//  Created by Zachary Schneirov on 1/16/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#define SEPARATE_ATTRS 0

@interface NSMutableAttributedString (AttributedPlainText)

- (void)trimLeadingWhitespace;
- (void)removeAttachments;
- (void)prefixWithSourceString:(NSString*)source;

#if SEPARATE_ATTRS
+ (NSMutableAttributedString*)attributedStringWithString:(NSString*)text attributesByRange:(NSDictionary*)attributes font:(NSFont*)font;
#endif
- (void)santizeForeignStylesForImporting;
- (void)addLinkAttributesForRange:(NSRange)changedRange;
- (BOOL)restyleTextToFont:(NSFont*)currentFont usingBaseFont:(NSFont*)baseFont;

@end


@interface NSAttributedString (AttributedPlainText)

+ (NSCharacterSet*)antiURLCharacterSet;
- (NSArray*)allLinks;
- (id)findNextLinkAtIndex:(unsigned int)startIndex effectiveRange:(NSRange *)range;
#if SEPARATE_ATTRS
//extract the attributes using their ranges as keys
- (NSDictionary*)attributesByRange;
#endif

@end
