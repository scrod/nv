
#import <Cocoa/Cocoa.h>

// http://gusmueller.com/odb/

extern NSString * const ODBEditorCustomPathKey;

@class TemporaryFileCachePreparer;
@class ExternalEditor;
@class NotationPrefs;
@class NoteObject;

@interface ODBEditor : NSObject
{
	UInt32					_signature;
	NSMutableDictionary		*_filePathsBeingEdited;
	
	TemporaryFileCachePreparer *editingSpacePreparer;
}
+ (id)sharedODBEditor;

- (void)abortEditingFile:(NSString *)path;
- (void)abortAllEditingSessionsForClient:(id)client;

- (void)initializeDatabase:(NotationPrefs*)prefs;

// NOTE that client is never retained - it is your reponsibility to
// make sure the client sticks around and abort editing for that client
// before it is dealloc'd
//
// Also note that while it is possible to start several editString
// sessions for a single client it is the client's responsibility to
// distinguish between the sessions (possibly using the original
// context that you supplied.) It is also the clients responsibility to
// do the same for file editing sessions, but this should be easier
// since the file path will remain static (except in the save as case)
// whereas the string returned is obviously going to change as the user
// edits it.

- (BOOL)editFile:(NSString *)path inEditor:(ExternalEditor*)ed options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context;
- (BOOL)editNote:(NoteObject*)aNote inEditor:(ExternalEditor*)ed context:(NSDictionary *)context;

- (BOOL)editString:(NSString *)string inEditor:(ExternalEditor*)ed options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context;

@end

@interface NSObject(ODBEditorClient)

// see the ODB Editor documentation for when newFileLocation is sent
// if the file wasn't subject to a save as newpath will be nil

-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath  context:(NSDictionary *)context;
-(void)odbEditor:(ODBEditor *)editor didClosefile:(NSString *)path context:(NSDictionary *)context;

-(void)odbEditor:(ODBEditor *)editor didModifyFileForString:(NSString *)newString context:(NSDictionary *)context;
-(void)odbEditor:(ODBEditor *)editor didCloseFileForString:(NSString *)newString context:(NSDictionary *)context;

@end
