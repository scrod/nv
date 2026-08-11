//
//  WALController.h
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.

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
#import "SynchronizedNoteProtocol.h"
#include <sys/types.h>
#include <zlib.h>

@interface WALController : NSObject {
	int logFD;
	int directoryFD;
	NSData *logSessionKey;
	
	z_stream compressionStream;
}

- (BOOL)logFileStillExists;
- (BOOL)destroyLogFile;

@end

@interface WALStorageController : WALController {
    NSMutableData *unwrittenData;
}
- (id)initWithDirectoryFileDescriptor:(int)fileDescriptor encryptionKey:(NSData*)key;
- (BOOL)writeEstablishedNote:(id<SynchronizedNote>)aNoteObject;
- (BOOL)writeRemovalForNote:(id<SynchronizedNote>)aNoteObject;
- (void)writeNoteObjects:(NSArray*)notes;
- (BOOL)synchronize;

@end



@interface WALRecoveryController : WALController {
    off_t fileLength, totalBytesRead;
    //to ensure we don't mistakenly allocate more memory
    //than there exists data in what we have yet to read
}

- (id)initWithDirectoryFileDescriptor:(int)fileDescriptor encryptionKey:(NSData*)key;
- (NSDictionary*)recoveredNotes;

@end
