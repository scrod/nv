//
//  NSString_NV.h
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.
//  Copyright 2006 Zachary Schneirov. All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class NoteObject;

@interface NSString (NV)

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime);
void resetCurrentDayTime();
- (NSMutableSet*)labelSetFromWordsAndContainingNote:(NoteObject*)note;
+ (NSString*)relativeTimeStringWithDate:(CFDateRef)date relativeDay:(int)day;
+ (NSString*)relativeDateStringWithAbsoluteTime:(CFAbsoluteTime)absTime;
- (CFArrayRef)copyRangesOfWordsInString:(NSString*)findString inRange:(NSRange)limitRange;
+ (NSString*)customPasteboardTypeOfCode:(int)code;
- (NSString*)stringAsSafePathExtension;
- (NSString*)filenameExpectingAdditionalCharCount:(int)charCount;
- (NSMutableString*)stringByReplacingOccurrencesOfString:(NSString*)stringToReplace withString:(NSString*)replacementString;
+ (NSString*)pathCopiedFromAliasData:(NSData*)aliasData;
+ (NSString*)timeDelayStringWithNumberOfSeconds:(double)seconds;
- (NSString*)fourCharTypeString;
- (void)copyItemToPasteboard:(id)sender;
- (NSURL*)linkForWord;
- (NSString*)syntheticTitle;
- (NSAttributedString*)attributedPreviewFromBodyText:(NSAttributedString*)bodyText;
+ (NSString *)tabbifiedStringWithNumberOfSpaces:(unsigned)origNumSpaces tabWidth:(unsigned)tabWidth usesTabs:(BOOL)usesTabs;
- (unsigned)numberOfLeadingSpacesFromRange:(NSRange*)range tabWidth:(unsigned)tabWidth;

	BOOL IsHardLineBreakUnichar(unichar uchar, NSString *str, unsigned charIndex);

- (char*)copyLowercaseASCIIString;
- (const char*)lowercaseUTF8String;
+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err;
+ (NSString*)pathWithFSRef:(FSRef*)fsRef;

- (CFUUIDBytes)uuidBytes;
+ (NSString*)uuidStringWithBytes:(CFUUIDBytes)bytes;

//- (NSTextView*)textViewWithFrame:(NSRect*)theFrame;

@end

@interface NSMutableString (NV)
+ (NSMutableString*)newShortLivedStringFromData:(NSMutableData*)data ofGuessedEncoding:(NSStringEncoding*)encoding;
@end

@interface NSEvent (NV)
- (unichar)firstCharacter;
- (unichar)firstCharacterIgnoringModifiers;
@end
