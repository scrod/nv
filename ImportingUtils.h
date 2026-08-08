#import <Cocoa/Cocoa.h>

extern NSPasteboardType const NVLegacyFilenamesPasteboardType;
extern NSPasteboardType const NVWebArchivePasteboardType;

NSArray *NVFilePathsFromPasteboard(NSPasteboard *pasteboard);
BOOL NVPathIsImportableNote(NSString *path, NSDictionary *attributes);
NSDragOperation NVDragOperationForContext(NSDraggingContext context);
NSPasteboardType NVPreferredNotePasteboardType(NSArray *types, NSPasteboardType poorTextType, BOOL usePlainTextFallback);
