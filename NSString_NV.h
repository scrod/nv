//
//  NSString_NV.h
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.

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
@class NoteObject;

@interface NSString (NV)

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime);
void resetCurrentDayTime();
+ (NSString*)relativeTimeStringWithDate:(CFDateRef)date relativeDay:(int)day;
+ (NSString*)relativeDateStringWithAbsoluteTime:(CFAbsoluteTime)absTime;
CFDateFormatterRef simplenoteDateFormatter(int lowPrecision);
+ (NSString*)simplenoteDateWithAbsoluteTime:(CFAbsoluteTime)absTime;
- (CFAbsoluteTime)absoluteTimeFromSimplenoteDate;
- (CFArrayRef)copyRangesOfWordsInString:(NSString*)findString inRange:(NSRange)limitRange;
+ (NSString*)customPasteboardTypeOfCode:(int)code;
- (NSString*)stringAsSafePathExtension;
- (NSString*)filenameExpectingAdditionalCharCount:(int)charCount;
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
- (NSString*)stringByReplacingOccurrencesOfString:(NSString*)stringToReplace withString:(NSString*)replacementString;
#endif
- (NSString*)fourCharTypeString;
- (BOOL)isAMachineDirective;
- (void)copyItemToPasteboard:(id)sender;
- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc maxTitleLen:(NSUInteger)maxTitleLen;
- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc 
										  oldTitle:(NSString*)oldTitle maxTitleLen:(NSUInteger)maxTitleLen;
- (NSString*)syntheticTitleAndTrimmedBody:(NSString**)newBody;
+ (NSString *)tabbifiedStringWithNumberOfSpaces:(unsigned)origNumSpaces tabWidth:(unsigned)tabWidth usesTabs:(BOOL)usesTabs;
- (unsigned)numberOfLeadingSpacesFromRange:(NSRange*)range tabWidth:(unsigned)tabWidth;

	BOOL IsHardLineBreakUnichar(unichar uchar, NSString *str, unsigned charIndex);

- (char*)copyLowercaseASCIIString;
- (const char*)lowercaseUTF8String;
- (NSString*)stringWithPercentEscapes;
- (NSString *)stringByReplacingPercentEscapes;
- (BOOL)superficiallyResemblesAnHTTPURL;
+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err;

- (NSArray*)labelCompatibleWords;

- (BOOL)UTIOfFileConformsToType:(NSString*)type;

- (CFUUIDBytes)uuidBytes;
+ (NSString*)uuidStringWithBytes:(CFUUIDBytes)bytes;

- (NSData *)decodeBase64;
- (NSData *)decodeBase64WithNewlines:(BOOL)encodedWithNewlines;

//- (NSTextView*)textViewWithFrame:(NSRect*)theFrame;

@end

@interface NSMutableString (NV)
- (void)replaceTabsWithSpacesOfWidth:(int)tabWidth;
+ (NSMutableString*)newShortLivedStringFromFile:(NSString*)filename;
+ (NSMutableString*)newShortLivedStringFromData:(NSMutableData*)data ofGuessedEncoding:(NSStringEncoding*)encoding 
									   withPath:(const char*)aPath orWithFSRef:(const FSRef*)fsRef;
@end

@interface NSScanner (NV)
- (void)scanContextualSeparator:(NSString**)sepStr withPrecedingString:(NSString*)firstLine;
@end

@interface NSCharacterSet (NV)

+ (NSCharacterSet*)labelSeparatorCharacterSet;
+ (NSCharacterSet*)listBulletsCharacterSet;

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
+ (id)newlineCharacterSet;
#endif

@end


@interface NSEvent (NV)
- (unichar)firstCharacter;
- (unichar)firstCharacterIgnoringModifiers;
@end
