#import <Cocoa/Cocoa.h>
#import "../AlienNoteImporter.h"
#import "../ImportingUtils.h"
#import "../NoteObject.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>

int main(void) {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	NSString *packagePath = [testDirectory stringByAppendingPathComponent:@"Modern Sticky.rtfd"];
	NSString *unrelatedDirectory = [testDirectory stringByAppendingPathComponent:@"Not a note"];
	NSError *error = nil;
	assert([fileManager createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:&error]);
	assert([fileManager createDirectoryAtPath:unrelatedDirectory withIntermediateDirectories:NO attributes:nil error:&error]);

	NSAttributedString *original = [[[NSAttributedString alloc] initWithString:@"Modern sticky title\nModern sticky body"] autorelease];
	NSFileWrapper *writtenWrapper = [original RTFDFileWrapperFromRange:NSMakeRange(0, [original length]) documentAttributes:@{}];
	assert([writtenWrapper writeToURL:[NSURL fileURLWithPath:packagePath] options:NSFileWrapperWritingAtomic originalContentsURL:nil error:&error]);

	NSDictionary *packageAttributes = [fileManager attributesOfItemAtPath:packagePath error:&error];
	NSDictionary *directoryAttributes = [fileManager attributesOfItemAtPath:unrelatedDirectory error:&error];
	assert(NVPathIsImportableNote(packagePath, packageAttributes));
	assert(!NVPathIsImportableNote(unrelatedDirectory, directoryAttributes));

	AlienNoteImporter *importer = [[[AlienNoteImporter alloc] initWithStoragePath:testDirectory] autorelease];
	NSArray *notes = [importer importedNotes];
	assert([notes count] == 1);
	NoteObject *note = [notes objectAtIndex:0];
	assert([titleOfNote(note) rangeOfString:@"Modern sticky title"].location != NSNotFound);
	assert([[[note contentString] string] rangeOfString:@"Modern sticky body"].location != NSNotFound);

	NSString *regularFile = [testDirectory stringByAppendingPathComponent:@"regular.txt"];
	assert([@"regular note" writeToFile:regularFile atomically:YES encoding:NSUTF8StringEncoding error:&error]);
	assert(NVPathIsImportableNote(regularFile, [fileManager attributesOfItemAtPath:regularFile error:&error]));

	assert([fileManager removeItemAtPath:testDirectory error:&error]);
	[pool drain];
	return 0;
}
