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

typedef NS_ENUM(NSInteger, NVBulkCatalogParseResult) {
	NVBulkCatalogRecordMalformed = -3,
	NVBulkCatalogRecordUnsupported = -2,
	NVBulkCatalogRecordTransient = -1,
	NVBulkCatalogRecordSkipped = 0,
	NVBulkCatalogRecordFile = 1
};

NVBulkCatalogParseResult NVParseBulkCatalogRecord(const void *bytes, size_t availableLength,
	size_t *recordLength, const char **name, size_t *nameLength, struct timespec *changeTime,
	uint32_t *documentID, uint64_t *fileID, uint32_t *generationCount);

@interface NotationController (NotationDirectoryManager)

- (NSSet*)notesWithFilenames:(NSArray*)filenames unknownFiles:(NSArray**)unknownFiles;

- (BOOL)_readFilesInDirectory;
- (BOOL)_catalogContainsCaseInsensitiveCollision;
- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry;
- (BOOL)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount;
- (BOOL)processNotesAddedByIdentity:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (BOOL)processNotesAddedByContent:(NSMutableArray*)addedEntries removed:(NSMutableArray*)removedEntries;
- (BOOL)synchronizeNotesFromDirectory;
- (NoteObject*)prepareNoteAdditionFromCatalogEntry:(NoteCatalogEntry*)catEntry error:(NSError**)error;
- (void)_destroyDirEventStream;
- (BOOL)_configureDirEventStream;
- (void)startFileNotifications;
- (void)stopFileNotifications;
- (void)_cancelDirectoryRetry;
- (void)_scheduleFilesystemRetryTimer;

@end
