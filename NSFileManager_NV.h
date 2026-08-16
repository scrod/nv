//
//  NSFileManager_NV.h
//  Notation
//
//  Created by Zachary Schneirov on 12/31/10.

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

BOOL NVURLsReferToSameItem(NSURL *one, NSURL *two);
BOOL NVURLIsInTrash(NSURL *URL);
int NVCopyFileSystemNameForLeaf(NSString *filename, char **name);
NSArray *NVOpenMetaTagsFromData(NSData *data, NSError **error);
NSStringEncoding NVTextEncodingFromAttributeData(NSData *data, NSError **error);


@interface NSFileManager (NV)


- (NSArray*)getOpenMetaTagsAtFSPath:(const char*)path;

- (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path;

- (NSURL*)fileReferenceURLForURL:(NSURL*)url error:(NSError**)error;
- (NSURL*)fileReferenceURLForFilename:(NSString*)filename
				 inDirectoryURL:(NSURL*)directoryURL
						error:(NSError**)error;
- (NSData*)bookmarkDataForFileReferenceURL:(NSURL*)url error:(NSError**)error;
- (NSURL*)fileReferenceURLFromBookmarkData:(NSData*)bookmarkData
								 stale:(BOOL*)stale
								 error:(NSError**)error;

@end
