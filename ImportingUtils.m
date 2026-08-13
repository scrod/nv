#import "ImportingUtils.h"
#import "NotationFileManager.h"

NSPasteboardType const NVLegacyFilenamesPasteboardType = @"NSFilenamesPboardType";
NSPasteboardType const NVWebArchivePasteboardType = @"Apple Web Archive pasteboard type";

NSArray *NVFilePathsFromPasteboard(NSPasteboard *pasteboard) {
	NSDictionary *options = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
														 forKey:NSPasteboardURLReadingFileURLsOnlyKey];
	NSArray *fileURLs = [pasteboard readObjectsForClasses:[NSArray arrayWithObject:[NSURL class]] options:options];
	if ([fileURLs count]) {
		NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[fileURLs count]];
		for (NSURL *URL in fileURLs) {
			if ([URL isFileURL] && [URL path]) [paths addObject:[URL path]];
		}
		if ([paths count]) return paths;
	}

	id legacyPaths = [pasteboard propertyListForType:NVLegacyFilenamesPasteboardType];
	return [legacyPaths isKindOfClass:[NSArray class]] ? legacyPaths : nil;
}

NSString *NVNotationalVelocityDataDirectoryPath(NSArray *paths) {
	if ([paths count] != 1) return nil;
	NSString *path = [paths objectAtIndex:0];
	NSFileManager *manager = [NSFileManager defaultManager];
	NSDictionary *directoryAttributes = [manager attributesOfItemAtPath:path error:NULL];
	if (![[directoryAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeDirectory]) return nil;
	NSDictionary *databaseAttributes = [manager attributesOfItemAtPath:
		[path stringByAppendingPathComponent:NotesDatabaseFileName] error:NULL];
	return [[databaseAttributes objectForKey:NSFileType] isEqualToString:NSFileTypeRegular] ? path : nil;
}

BOOL NVPathIsImportableNote(NSString *path, NSDictionary *attributes) {
	NSString *fileType = [attributes objectForKey:NSFileType];
	return [fileType isEqualToString:NSFileTypeRegular] ||
		([fileType isEqualToString:NSFileTypeDirectory] && [[path pathExtension] caseInsensitiveCompare:@"rtfd"] == NSOrderedSame);
}

NSDragOperation NVDragOperationForContext(NSDraggingContext context) {
	return context == NSDraggingContextWithinApplication ? NSDragOperationNone : NSDragOperationCopy;
}

NSPasteboardType NVPreferredNotePasteboardType(NSArray *types, NSPasteboardType poorTextType, BOOL usePlainTextFallback) {
	if ([types containsObject:poorTextType]) return poorTextType;
	if (!usePlainTextFallback) {
		if ([types containsObject:NSPasteboardTypeRTF]) return NSPasteboardTypeRTF;
		if ([types containsObject:NSPasteboardTypeRTFD]) return NSPasteboardTypeRTFD;
		if ([types containsObject:NVWebArchivePasteboardType]) return NVWebArchivePasteboardType;
		if ([types containsObject:NSPasteboardTypeHTML]) return NSPasteboardTypeHTML;
	}
	return [types containsObject:NSPasteboardTypeString] ? NSPasteboardTypeString : nil;
}
