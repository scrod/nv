//
//  AttributedPlainText.h
//  Notation
//
//  Created by Zachary Schneirov on 1/16/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import <Cocoa/Cocoa.h>

#define SEPARATE_ATTRS 0

extern NSString *NVHiddenDoneTagAttributeName;
extern NSString *NVHiddenBulletIndentAttributeName;

@interface NSMutableAttributedString (AttributedPlainText)

- (void)trimLeadingWhitespace;
- (void)indentTextLists;
- (void)removeAttachments;
- (NSString*)prefixWithSourceString:(NSString*)source;

- (NSString*)trimLeadingSyntheticTitle;

#if SEPARATE_ATTRS
+ (NSMutableAttributedString*)attributedStringWithString:(NSString*)text attributesByRange:(NSDictionary*)attributes font:(NSFont*)font;
#endif
- (void)santizeForeignStylesForImporting;
- (void)addLinkAttributesForRange:(NSRange)changedRange;
- (void)_addDoubleBracketedNVLinkAttributesForRange:(NSRange)changedRange;
- (void)addStrikethroughNearDoneTagsForRange:(NSRange)changedRange;
- (void)addAttributesForMarkdownHeadingLinesInRange:(NSRange)changedRange;
- (BOOL)restyleTextToFont:(NSFont*)currentFont usingBaseFont:(NSFont*)baseFont;

@end


@interface NSAttributedString (AttributedPlainText)

- (BOOL)attribute:(NSString*)anAttribute existsInRange:(NSRange)aRange;

- (NSArray*)allLinks;
- (id)findNextLinkAtIndex:(unsigned int)startIndex effectiveRange:(NSRange *)range;
#if SEPARATE_ATTRS
//extract the attributes using their ranges as keys
- (NSDictionary*)attributesByRange;
#endif

+ (NSAttributedString*)timeDelayStringWithNumberOfSeconds:(double)seconds;

@end
