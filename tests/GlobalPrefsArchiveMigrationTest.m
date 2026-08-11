#import <Cocoa/Cocoa.h>
#import "../GlobalPrefs.h"

static NSString * const TestSuiteName = @"net.notational.velocity.tests.global-prefs-archive-migration";
static NSString * const LegacyFontKey = @"NoteBodyFont";
static NSString * const LegacyForegroundKey = @"ForegroundTextColor";
static NSString * const LegacyBackgroundKey = @"BackgroundTextColor";
static NSString * const LegacyHighlightKey = @"SearchTermHighlightColor";
static NSString * const ModernFontKey = @"NoteBodyFontKeyedArchive";
static NSString * const ModernForegroundKey = @"ForegroundTextColorKeyedArchive";
static NSString * const ModernBackgroundKey = @"BackgroundTextColorKeyedArchive";
static NSString * const ModernHighlightKey = @"SearchTermHighlightColorKeyedArchive";

static int failures = 0;

#define CHECK(__condition, __message) do { \
	if (!(__condition)) { \
		fprintf(stderr, "FAIL: %s\n", (__message)); \
		failures++; \
	} \
} while (0)

@interface TestGlobalPrefs : GlobalPrefs
- (id)initWithUserDefaults:(NSUserDefaults *)testDefaults;
@end

@implementation TestGlobalPrefs
- (id)initWithUserDefaults:(NSUserDefaults *)testDefaults {
	self = [super init];
	if (self) defaults = [testDefaults retain];
	return self;
}

- (void)dealloc {
	[defaults release];
	defaults = nil;
	[super dealloc];
}
@end

static NSData *LegacyArchive(id object) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return [NSArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
}

static NSData *ModernArchive(id object) {
	NSError *error = nil;
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
	CHECK(data != nil && error == nil, "test fixture can create a secure keyed archive");
	return data;
}

static id ModernObject(NSUserDefaults *defaults, NSString *key, Class expectedClass) {
	NSData *data = [defaults dataForKey:key];
	if (!data) return nil;
	return [NSKeyedUnarchiver unarchivedObjectOfClass:expectedClass fromData:data error:nil];
}

static BOOL FontsEqual(NSFont *first, NSFont *second) {
	return first && second && [[first fontName] isEqualToString:[second fontName]] && [first pointSize] == [second pointSize];
}

static BOOL ColorsMatch(NSColor *first, NSColor *second) {
	return first && second && ColorsEqualWith8BitChannels(first, second);
}

static GlobalPrefs *PrefsUsingDefaults(NSUserDefaults *defaults) {
	return [[[TestGlobalPrefs alloc] initWithUserDefaults:defaults] autorelease];
}

static void ClearDefaults(NSUserDefaults *defaults) {
	[defaults removePersistentDomainForName:TestSuiteName];
}

static void TestSettersWriteOnlyModernKeys(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	NSFont *legacyFont = [NSFont fontWithName:@"Helvetica" size:11.0];
	NSColor *legacyForeground = [NSColor colorWithCalibratedRed:0.1 green:0.2 blue:0.3 alpha:1.0];
	NSColor *legacyBackground = [NSColor colorWithCalibratedRed:0.8 green:0.7 blue:0.6 alpha:1.0];
	NSColor *legacyHighlight = [NSColor colorWithCalibratedRed:0.9 green:0.3 blue:0.2 alpha:0.5];
	NSDictionary *legacyData = @{
		LegacyFontKey: LegacyArchive(legacyFont),
		LegacyForegroundKey: LegacyArchive(legacyForeground),
		LegacyBackgroundKey: LegacyArchive(legacyBackground),
		LegacyHighlightKey: LegacyArchive(legacyHighlight)
	};
	[legacyData enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSData *data, BOOL *stop) {
		[defaults setObject:data forKey:key];
	}];

	NSFont *modernFont = [NSFont fontWithName:@"Menlo" size:15.0];
	NSColor *modernForeground = [NSColor colorWithCalibratedRed:0.6 green:0.2 blue:0.4 alpha:1.0];
	NSColor *modernBackground = [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.6 alpha:1.0];
	NSColor *modernHighlight = [NSColor colorWithCalibratedRed:0.3 green:0.8 blue:0.4 alpha:0.65];
	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	[prefs setNoteBodyFont:modernFont sender:prefs];
	[prefs setForegroundTextColor:modernForeground sender:prefs];
	[prefs setBackgroundTextColor:modernBackground sender:prefs];
	[prefs setSearchTermHighlightColor:modernHighlight sender:prefs];

	CHECK(FontsEqual(ModernObject(defaults, ModernFontKey, [NSFont class]), modernFont), "font setter writes the new keyed-archive key");
	CHECK(ColorsMatch(ModernObject(defaults, ModernForegroundKey, [NSColor class]), modernForeground), "foreground setter writes the new keyed-archive key");
	CHECK(ColorsMatch(ModernObject(defaults, ModernBackgroundKey, [NSColor class]), modernBackground), "background setter writes the new keyed-archive key");
	CHECK(ColorsMatch(ModernObject(defaults, ModernHighlightKey, [NSColor class]), modernHighlight), "highlight setter writes the new keyed-archive key");
	[legacyData enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSData *data, BOOL *stop) {
		CHECK([[defaults dataForKey:key] isEqualToData:data], "setters leave legacy preference data unchanged");
	}];
}

static void TestLegacyValuesAreReadAndMigrated(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	NSFont *font = [NSFont fontWithName:@"Courier" size:13.0];
	NSColor *foreground = [NSColor colorWithCalibratedRed:0.2 green:0.3 blue:0.4 alpha:1.0];
	NSColor *background = [NSColor colorWithCalibratedRed:0.7 green:0.8 blue:0.9 alpha:1.0];
	NSColor *highlight = [NSColor colorWithCalibratedRed:0.8 green:0.4 blue:0.1 alpha:0.55];
	NSData *legacyFontData = LegacyArchive(font);
	NSData *legacyForegroundData = LegacyArchive(foreground);
	NSData *legacyBackgroundData = LegacyArchive(background);
	NSData *legacyHighlightData = LegacyArchive(highlight);
	[defaults setObject:legacyFontData forKey:LegacyFontKey];
	[defaults setObject:legacyForegroundData forKey:LegacyForegroundKey];
	[defaults setObject:legacyBackgroundData forKey:LegacyBackgroundKey];
	[defaults setObject:legacyHighlightData forKey:LegacyHighlightKey];

	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK([defaults objectForKey:ModernFontKey] == nil, "legacy font is not migrated before it is read");
	CHECK(FontsEqual([prefs noteBodyFont], font), "legacy font remains readable");
	CHECK(FontsEqual(ModernObject(defaults, ModernFontKey, [NSFont class]), font), "legacy font is lazily copied to the new key");
	CHECK([defaults objectForKey:ModernForegroundKey] == nil, "legacy foreground is not migrated before it is read");
	CHECK(ColorsMatch([prefs foregroundTextColor], foreground), "legacy foreground color remains readable");
	CHECK(ColorsMatch(ModernObject(defaults, ModernForegroundKey, [NSColor class]), foreground), "legacy foreground is lazily copied to the new key");
	CHECK([defaults objectForKey:ModernBackgroundKey] == nil, "legacy background is not migrated before it is read");
	CHECK(ColorsMatch([prefs backgroundTextColor], background), "legacy background color remains readable");
	CHECK(ColorsMatch(ModernObject(defaults, ModernBackgroundKey, [NSColor class]), background), "legacy background is lazily copied to the new key");
	CHECK([defaults objectForKey:ModernHighlightKey] == nil, "legacy highlight is not migrated before it is read");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], highlight), "legacy highlight color remains readable");
	CHECK(ColorsMatch(ModernObject(defaults, ModernHighlightKey, [NSColor class]), highlight), "legacy highlight is lazily copied to the new key");
	CHECK([[defaults dataForKey:LegacyFontKey] isEqualToData:legacyFontData], "font migration leaves legacy data unchanged");
	CHECK([[defaults dataForKey:LegacyForegroundKey] isEqualToData:legacyForegroundData], "foreground migration leaves legacy data unchanged");
	CHECK([[defaults dataForKey:LegacyBackgroundKey] isEqualToData:legacyBackgroundData], "background migration leaves legacy data unchanged");
	CHECK([[defaults dataForKey:LegacyHighlightKey] isEqualToData:legacyHighlightData], "highlight migration leaves legacy data unchanged");
}

static void TestModernValuesTakePrecedence(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	NSFont *legacyFont = [NSFont fontWithName:@"Helvetica" size:10.0];
	NSFont *modernFont = [NSFont fontWithName:@"Menlo" size:16.0];
	NSColor *legacyColor = [NSColor blackColor];
	NSColor *modernForeground = [NSColor colorWithCalibratedRed:0.25 green:0.5 blue:0.75 alpha:1.0];
	NSColor *modernBackground = [NSColor colorWithCalibratedRed:0.75 green:0.5 blue:0.25 alpha:1.0];
	NSColor *modernHighlight = [NSColor colorWithCalibratedRed:0.6 green:0.3 blue:0.7 alpha:0.5];
	[defaults setObject:LegacyArchive(legacyFont) forKey:LegacyFontKey];
	[defaults setObject:ModernArchive(modernFont) forKey:ModernFontKey];
	[defaults setObject:LegacyArchive(legacyColor) forKey:LegacyForegroundKey];
	[defaults setObject:ModernArchive(modernForeground) forKey:ModernForegroundKey];
	[defaults setObject:LegacyArchive(legacyColor) forKey:LegacyBackgroundKey];
	[defaults setObject:ModernArchive(modernBackground) forKey:ModernBackgroundKey];
	[defaults setObject:LegacyArchive(legacyColor) forKey:LegacyHighlightKey];
	[defaults setObject:ModernArchive(modernHighlight) forKey:ModernHighlightKey];

	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK(FontsEqual([prefs noteBodyFont], modernFont), "new font takes precedence over the legacy font");
	CHECK(ColorsMatch([prefs foregroundTextColor], modernForeground), "new foreground takes precedence over the legacy foreground");
	CHECK(ColorsMatch([prefs backgroundTextColor], modernBackground), "new background takes precedence over the legacy background");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], modernHighlight), "new highlight takes precedence over the legacy highlight");
}

static void TestCorruptModernValuesFallBackToLegacy(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	NSData *corruptData = [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding];
	NSFont *font = [NSFont fontWithName:@"Courier" size:14.0];
	NSColor *foreground = [NSColor colorWithCalibratedRed:0.4 green:0.3 blue:0.2 alpha:1.0];
	NSColor *background = [NSColor colorWithCalibratedRed:0.2 green:0.3 blue:0.4 alpha:1.0];
	NSColor *highlight = [NSColor colorWithCalibratedRed:0.7 green:0.3 blue:0.5 alpha:0.6];
	[defaults setObject:corruptData forKey:ModernFontKey];
	[defaults setObject:LegacyArchive(font) forKey:LegacyFontKey];
	[defaults setObject:corruptData forKey:ModernForegroundKey];
	[defaults setObject:LegacyArchive(foreground) forKey:LegacyForegroundKey];
	[defaults setObject:corruptData forKey:ModernBackgroundKey];
	[defaults setObject:LegacyArchive(background) forKey:LegacyBackgroundKey];
	[defaults setObject:corruptData forKey:ModernHighlightKey];
	[defaults setObject:LegacyArchive(highlight) forKey:LegacyHighlightKey];

	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK(FontsEqual([prefs noteBodyFont], font), "corrupt new font data falls back to the legacy font");
	CHECK(ColorsMatch([prefs foregroundTextColor], foreground), "corrupt new foreground data falls back to the legacy foreground");
	CHECK(ColorsMatch([prefs backgroundTextColor], background), "corrupt new background data falls back to the legacy background");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], highlight), "corrupt new highlight data falls back to the legacy highlight");
	CHECK(FontsEqual(ModernObject(defaults, ModernFontKey, [NSFont class]), font), "legacy fallback repairs corrupt new font data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernForegroundKey, [NSColor class]), foreground), "legacy fallback repairs corrupt new foreground data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernBackgroundKey, [NSColor class]), background), "legacy fallback repairs corrupt new background data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernHighlightKey, [NSColor class]), highlight), "legacy fallback repairs corrupt new highlight data");
}

static void TestCorruptModernValuesFallBackToDefaults(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	NSData *corruptData = [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding];
	[defaults setObject:corruptData forKey:ModernFontKey];
	[defaults setObject:corruptData forKey:ModernForegroundKey];
	[defaults setObject:corruptData forKey:ModernBackgroundKey];
	[defaults setObject:corruptData forKey:ModernHighlightKey];
	NSFont *font = [NSFont fontWithName:@"Helvetica" size:12.0];
	NSColor *foreground = [NSColor textColor];
	NSColor *background = [NSColor textBackgroundColor];
	NSColor *highlight = [NSColor colorWithCalibratedRed:0.945 green:0.702 blue:0.702 alpha:1.0];

	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK(FontsEqual([prefs noteBodyFont], font), "corrupt font without legacy data uses the existing default");
	CHECK(ColorsMatch([prefs foregroundTextColor], foreground), "corrupt foreground without legacy data uses the existing default");
	CHECK(ColorsMatch([prefs backgroundTextColor], background), "corrupt background without legacy data uses the existing default");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], highlight), "corrupt highlight without legacy data uses the existing default");
	CHECK(FontsEqual(ModernObject(defaults, ModernFontKey, [NSFont class]), font), "default repairs corrupt new font data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernForegroundKey, [NSColor class]), foreground), "default repairs corrupt new foreground data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernBackgroundKey, [NSColor class]), background), "default repairs corrupt new background data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernHighlightKey, [NSColor class]), highlight), "default repairs corrupt new highlight data");
}

static void TestWrongTypeModernValuesFallBackToDefaults(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	[defaults setObject:@"not data" forKey:ModernFontKey];
	[defaults setObject:@1 forKey:ModernForegroundKey];
	[defaults setObject:@[] forKey:ModernBackgroundKey];
	[defaults setObject:@{} forKey:ModernHighlightKey];
	NSFont *font = [NSFont fontWithName:@"Helvetica" size:12.0];
	NSColor *foreground = [NSColor textColor];
	NSColor *background = [NSColor textBackgroundColor];
	NSColor *highlight = [NSColor colorWithCalibratedRed:0.945 green:0.702 blue:0.702 alpha:1.0];

	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK(FontsEqual([prefs noteBodyFont], font), "wrong-type font value uses the existing default");
	CHECK(ColorsMatch([prefs foregroundTextColor], foreground), "wrong-type foreground value uses the existing default");
	CHECK(ColorsMatch([prefs backgroundTextColor], background), "wrong-type background value uses the existing default");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], highlight), "wrong-type highlight value uses the existing default");
	CHECK(FontsEqual(ModernObject(defaults, ModernFontKey, [NSFont class]), font), "default repairs wrong-type new font data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernForegroundKey, [NSColor class]), foreground), "default repairs wrong-type new foreground data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernBackgroundKey, [NSColor class]), background), "default repairs wrong-type new background data");
	CHECK(ColorsMatch(ModernObject(defaults, ModernHighlightKey, [NSColor class]), highlight), "default repairs wrong-type new highlight data");
}

static void TestMissingValuesUseExistingDefaults(NSUserDefaults *defaults) {
	ClearDefaults(defaults);
	GlobalPrefs *prefs = PrefsUsingDefaults(defaults);
	CHECK(FontsEqual([prefs noteBodyFont], [NSFont fontWithName:@"Helvetica" size:12.0]), "missing font uses the existing Helvetica 12 default");
	CHECK(ColorsMatch([prefs foregroundTextColor], [NSColor textColor]), "missing foreground uses the existing text color default");
	CHECK(ColorsMatch([prefs backgroundTextColor], [NSColor textBackgroundColor]), "missing background uses the existing text background default");
	CHECK(ColorsMatch([prefs searchTermHighlightColorRaw:YES], [NSColor colorWithCalibratedRed:0.945 green:0.702 blue:0.702 alpha:1.0]), "missing highlight uses the existing highlight default");
}

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSUserDefaults *defaults = [[[NSUserDefaults alloc] initWithSuiteName:TestSuiteName] autorelease];

	TestSettersWriteOnlyModernKeys(defaults);
	TestLegacyValuesAreReadAndMigrated(defaults);
	TestModernValuesTakePrecedence(defaults);
	TestCorruptModernValuesFallBackToLegacy(defaults);
	TestCorruptModernValuesFallBackToDefaults(defaults);
	TestWrongTypeModernValuesFallBackToDefaults(defaults);
	TestMissingValuesUseExistingDefaults(defaults);
	ClearDefaults(defaults);

	[pool drain];
	return failures == 0 ? 0 : 1;
}
