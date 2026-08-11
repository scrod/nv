#import <Cocoa/Cocoa.h>
#import <WebKit/WebArchive.h>
#import <WebKit/WebResource.h>
#import "../AlienNoteImporter.h"
#import "../GlobalPrefs.h"
#import "../NoteObject.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <math.h>

static BOOL StyleIsPresent(NSAttributedString *string, NSString *text, NSFontTraitMask trait, NSString *fallbackAttribute) {
	NSRange range = [[string string] rangeOfString:text];
	assert(range.location != NSNotFound);
	NSDictionary *attributes = [string attributesAtIndex:range.location effectiveRange:NULL];
	NSFont *font = [attributes objectForKey:NSFontAttributeName];
	if (([[NSFontManager sharedFontManager] traitsOfFont:font] & trait) != 0)
		return YES;
	NSNumber *fallback = [attributes objectForKey:fallbackAttribute];
	return trait == NSBoldFontMask ? [fallback doubleValue] < -0.001 : fabs([fallback doubleValue]) > 0.001;
}

int main(int argc, const char *argv[]) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFont *configuredFont = [NSFont fontWithName:@"HelveticaNeue-Light" size:17.0];
	assert(configuredFont != nil);
	GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
	[prefs setValue:configuredFont forKey:@"noteBodyFont"];
	[prefs setValue:nil forKey:@"noteBodyAttributes"];
	NSString *html = @"<!doctype html><html><body>"
		"<span style='font-family: Courier New; font-size: 31px'>Web archive title</span><br>"
		"<span style='font-family: -apple-system; font-size: 23px'>normal text</span> "
		"<b style='font-family: Georgia; font-size: 37px'>bold text</b> "
		"<i style='font-family: Times New Roman; font-size: 19px'>italic text</i> "
		"<s style='font-family: Courier New; font-size: 29px'>struck text</s>"
		"</body></html>";
	NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
	NSURL *sourceURL = [NSURL URLWithString:@"https://example.com/imported-note"];

	#pragma clang diagnostic push
	#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	WebResource *resource = [[[WebResource alloc] initWithData:htmlData URL:sourceURL MIMEType:@"text/html" textEncodingName:@"utf-8" frameName:nil] autorelease];
	WebArchive *archive = [[[WebArchive alloc] initWithMainResource:resource subresources:nil subframeArchives:nil] autorelease];
	NSData *archiveData = [archive data];
	#pragma clang diagnostic pop
	assert([archiveData length] > 0);

	NSFont *bodyFont = [prefs noteBodyFont];
	assert(bodyFont != nil);
	NSAttributedString *unimported = [[[NSAttributedString alloc] initWithData:archiveData options:@{} documentAttributes:NULL error:NULL] autorelease];
	assert([unimported length] > 0);
	NSRange normalRange = [[unimported string] rangeOfString:@"normal text"];
	assert(normalRange.location != NSNotFound);
	NSFont *foreignFont = [unimported attribute:NSFontAttributeName atIndex:normalRange.location effectiveRange:NULL];
	assert(foreignFont != nil);
	assert(fabs([foreignFont pointSize] - [bodyFont pointSize]) > 0.001);
	assert(StyleIsPresent(unimported, @"bold text", NSBoldFontMask, NSStrokeWidthAttributeName));
	assert(StyleIsPresent(unimported, @"italic text", NSItalicFontMask, NSObliquenessAttributeName));

	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	NSString *archivePath = [testDirectory stringByAppendingPathComponent:@"Styled.webarchive"];
	NSError *error = nil;
	assert([fileManager createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:&error]);
	assert([archiveData writeToFile:archivePath options:NSDataWritingAtomic error:&error]);
	BOOL usesExternalArchive = argc > 1;
	if (usesExternalArchive)
		archivePath = [NSString stringWithUTF8String:argv[1]];

	AlienNoteImporter *importer = [[[AlienNoteImporter alloc] initWithStoragePaths:@[archivePath]] autorelease];
	NSArray *notes = [importer importedNotes];
	assert([notes count] == 1);
	NSAttributedString *content = [[notes objectAtIndex:0] contentString];
	assert([[content string] hasPrefix:@"From <"]);
	if (!usesExternalArchive) {
		NSRange normalTextRange = [[content string] rangeOfString:@"normal text"];
		assert(normalTextRange.location != NSNotFound);
		NSFont *normalTextFont = [content attribute:NSFontAttributeName atIndex:normalTextRange.location effectiveRange:NULL];
		assert([[normalTextFont fontName] isEqualToString:[bodyFont fontName]]);
	}
	NSUInteger location = 0;
	while (location < [content length]) {
		NSRange range;
		NSFont *font = [content attribute:NSFontAttributeName atIndex:location effectiveRange:&range];
		if (![[font familyName] isEqualToString:[bodyFont familyName]] || fabs([font pointSize] - [bodyFont pointSize]) >= 0.001)
			NSLog(@"Unnormalized run %@: %@ %.2f", NSStringFromRange(range), [font fontName], [font pointSize]);
		assert([[font familyName] isEqualToString:[bodyFont familyName]]);
		assert(fabs([font pointSize] - [bodyFont pointSize]) < 0.001);
		location = NSMaxRange(range);
	}
	if (!usesExternalArchive) {
		assert(StyleIsPresent(content, @"bold text", NSBoldFontMask, NSStrokeWidthAttributeName));
		assert(StyleIsPresent(content, @"italic text", NSItalicFontMask, NSObliquenessAttributeName));
		NSRange struckRange = [[content string] rangeOfString:@"struck text"];
		assert(struckRange.location != NSNotFound);
		assert([[content attribute:NSStrikethroughStyleAttributeName atIndex:struckRange.location effectiveRange:NULL] integerValue] != NSUnderlineStyleNone);
	}

	assert([fileManager removeItemAtPath:testDirectory error:&error]);
	[pool drain];
	return 0;
}
