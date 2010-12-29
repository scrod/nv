/*
 * The AutoHyperlinks Framework is the legal property of its developers (DEVELOPERS), whose names are listed in the
 * copyright file included with this source distribution.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the AutoHyperlinks Framework nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY ITS DEVELOPERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL ITS DEVELOPERS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "AHLinkLexer.h"

typedef void* yyscan_t;

extern long AHlex( yyscan_t yyscanner );
extern long AHlex_init( yyscan_t * ptr_yy_globals );
extern long AHlex_destroy ( yyscan_t yyscanner );
extern long AHget_leng ( yyscan_t scanner );
extern void AHset_in ( FILE * in_str , yyscan_t scanner );

typedef struct AH_buffer_state *AH_BUFFER_STATE;
extern void AH_switch_to_buffer(AH_BUFFER_STATE, yyscan_t scanner);
extern AH_BUFFER_STATE AH_scan_string (const char *, yyscan_t scanner);
extern void AH_delete_buffer(AH_BUFFER_STATE, yyscan_t scanner);

@class AHMarkedHyperlink;

@interface AHHyperlinkScanner : NSObject
{
	NSDictionary				*m_urlSchemes;
	NSString					*m_scanString;
	NSAttributedString			*m_scanAttrString;
	BOOL						 m_strictChecking;
	NSUInteger				 m_scanLocation;
	NSUInteger				 m_scanStringLength;
}


/*!
 * @brief Allocs and inits a new lax AHHyperlinkScanner with the given NSString
 *
 * @param inString the scanner's string
 * @return a new AHHyperlinkScanner
 */
+ (id)hyperlinkScannerWithString:(NSString *)inString;

/*!
 * @brief Allocs and inits a new strict AHHyperlinkScanner with the given NSString
 *
 * @param inString the scanner's string
 * @return a new AHHyperlinkScanner
 */
+ (id)strictHyperlinkScannerWithString:(NSString *)inString;

/*!
 * @brief Allocs and inits a new lax AHHyperlinkScanner with the given attributed string
 *
 * @param inString the scanner's string
 * @return a new AHHyperlinkScanner
 */
+ (id)hyperlinkScannerWithAttributedString:(NSAttributedString *)inString;

/*!
 * @brief Allocs and inits a new strict AHHyperlinkScanner with the given attributed string
 *
 * @param inString the scanner's string
 * @return a new AHHyperlinkScanner
 */
+ (id)strictHyperlinkScannerWithAttributedString:(NSAttributedString *)inString;

/*!
 * @brief Determine the validity of a given string with a custom strictness
 *
 * @param inString The string to be verified
 * @param useStrictChecking Use strict rules or not
 * @param index a pointer to the index the string starts at, for easy incrementing.
 * @return Boolean
 */
+ (BOOL)isStringValidURI:(NSString *)inString usingStrict:(BOOL)useStrictChecking fromIndex:(NSUInteger *)index withStatus:(AH_URI_VERIFICATION_STATUS *)validStatus;

/*!
 * @brief Init
 *
 * Inits a new AHHyperlinkScanner object for a NSString with the set strict checking option.
 *
 * @param inString the NSString to be scanned.
 * @param flag Sets strict checking preference.
 * @return A new AHHyperlinkScanner.
 */
- (id)initWithString:(NSString *)inString usingStrictChecking:(BOOL)flag;

/*!
 * @brief Init
 *
 * Inits a new AHHyperlinkScanner object for a NSAttributedString with the set strict checking option.
 *
 * param inString the NSString to be scanned.
 * @param flag Sets strict checking preference.
 * @return A new AHHyperlinkScanner.
 */
 - (id)initWithAttributedString:(NSAttributedString *)inString usingStrictChecking:(BOOL)flag;


/*!
 * @brief Determine the validity of the scanner's string using the set strictness
 *
 * @return Boolean
 */
- (BOOL)isValidURI;

/*!
 * @brief Returns a AHMarkedHyperlink representing the next URI in the scanner's string
 *
 * @return A new AHMarkedHyperlink.
 */
- (AHMarkedHyperlink *)nextURI;

/*!
 * @brief Fetches all the URIs from the scanner's string
 *
 * @return An array of AHMarkedHyperlinks representing each matched URL in the string or nil if no matches.
 */
- (NSArray *)allURIs;

/*!
 * @brief Scans an attributed string for URIs then adds the link attribs and objects.
 * @param inString The NSAttributedString to be linkified
 * @return An autoreleased NSAttributedString.
 */
- (NSAttributedString *)linkifiedString;

- (NSUInteger)scanLocation;
- (void)setScanLocation:(NSUInteger)location;

@end
