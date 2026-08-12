//
//  ExternalEditingSession.h
//  Notation
//
//  Created by Zachary Schneirov on 8/12/26.

/*Copyright (c) 2026, Zachary Schneirov. All rights reserved.
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
#import <CoreServices/CoreServices.h>

@class TemporaryFileCachePreparer;
@class ExternalEditor;
@class NotationPrefs;
@class NoteObject;

@interface ExternalEditingSession : NSObject
{
	NSMutableDictionary		*_filePathsBeingEdited;
	NSMutableArray *_finishRequests;
	NSUInteger _scratchEditingSuspensionCount;
	TemporaryFileCachePreparer *editingSpacePreparer;
	FSEventStreamRef scratchEventStream;
}
+ (id)sharedExternalEditingSession;

- (void)abortEditingFile:(NSString *)path;
- (void)abortAllEditingSessionsForClient:(id)client;
- (NSUInteger)activeScratchEditingSessionCount;
- (BOOL)hasActiveScratchEditingSessionForClient:(id)client;
- (void)finishScratchEditingSessionsForClients:(NSArray*)clients
	completionHandler:(void (^)(BOOL success))completionHandler;
- (void)finishAllScratchEditingSessionsWithCompletionHandler:
	(void (^)(BOOL success))completionHandler;
- (void)beginScratchEditingSuspension;
- (void)endScratchEditingSuspension;

- (void)initializeDatabase:(NotationPrefs*)prefs;

- (BOOL)editNote:(NoteObject*)aNote inEditor:(ExternalEditor*)ed context:(NSDictionary *)context;
- (void)noteContentsDidChange:(NoteObject*)note;

@end

@interface NSObject(ExternalEditingSessionClient)

- (BOOL)externalEditingSession:(ExternalEditingSession*)editor didModifyFileData:(NSData*)data
	baseData:(NSData*)baseData path:(NSString*)path context:(NSDictionary*)context;

@end
