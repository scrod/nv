//
//  TemporaryFileCachePreparer.h
//  Notation
//

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

@class NotationPrefs;

@interface TemporaryFileCachePreparer : NSObject {
	NSString *cachePath;
	
	id delegate;

	NotationPrefs *notationPrefs;	
	BOOL startedPreparing;
	NSTask *mountTask, *newfsTask, *attachTask;
	NSString *deviceName, *preparedCachePath;
}

- (void)prepEditingSpaceIfNecessaryForNotationPrefs:(NotationPrefs*)prefs;
- (void)_attachRAMDiskOfCapacity:(NSUInteger)numberOfMegabytes;
- (void)_buildHFSFileSystemOnDevice:(NSString*)aDeviceName;
- (void)_mountHFSFileSystemOnDevice:(NSString*)aDeviceName;

- (BOOL)_createFolderAtPath:(NSString*)path;

- (BOOL)isPreparing;
- (void)_finishPreparationWithPath:(NSString*)aPath;
- (void)_stopPreparation;
- (NSString*)preparedCachePath;
- (void)setDelegate:(id)aDelegate;
- (id)delegate;

@end


@interface NSObject (TemporaryFileCachePreparerDelegate)

- (void)temporaryFileCachePreparerDidNotFinish:(TemporaryFileCachePreparer*)preparer;
- (void)temporaryFileCachePreparerFinished:(TemporaryFileCachePreparer*)preparer;

@end
