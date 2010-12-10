//
//  AttributedPlainText.h
//  Notation
//
//  Created by Zachary Schneirov on 1/16/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import <Cocoa/Cocoa.h>

#define SEPARATE_ATTRS 0

@interface NSMutableAttributedString (AttributedPlainText)

- (void)trimLeadingWhitespace;
- (void)removeAttachments;
- (void)prefixWithSourceString:(NSString*)source;

- (NSString*)trimLeadingSyntheticTitle;

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

+ (NSAttributedString*)timeDelayStringWithNumberOfSeconds:(double)seconds;

@end
