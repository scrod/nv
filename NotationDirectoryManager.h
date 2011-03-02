//
//  NotationDirectoryManager.h
//  Notation
//
//  Created by Zachary Schneirov on 11/29/09.

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

#import "NotationController.h"

@interface NotationController (NotationDirectoryManager)

NSInteger compareCatalogEntryName(const void *one, const void *two);
NSInteger compareCatalogValueNodeID(id *a, id *b);
NSInteger compareCatalogValueFileSize(id *a, id *b);
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_5
void NotesDirFNSubscriptionProc(FNMessage message, OptionBits flags, void * refcon, FNSubscriptionRef subscription);
#endif

- (NSSet*)notesWithFilenames:(NSArray*)filenames unknownFiles:(NSArray**)unknownFiles;

- (BOOL)_readFilesInDirectory;
- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry;
- (void)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount;
- (void)processNotesAddedByCNID:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (void)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (BOOL)synchronizeNotesFromDirectory;
- (void)_destroyDirEventStream;
- (void)_configureDirEventStream;
- (void)startFileNotifications;
- (void)stopFileNotifications;

@end
