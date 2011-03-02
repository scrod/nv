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


@interface NSFileManager (NV)


- (id)getOpenMetaTagsAtFSPath:(const char*)path;
- (BOOL)setOpenMetaTags:(id)plistObject atFSPath:(const char*)path;

- (NSString*)pathCopiedFromAliasData:(NSData*)aliasData;
- (BOOL)setTextEncodingAttribute:(NSStringEncoding)encoding atFSPath:(const char*)path;
- (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path;
- (NSString*)pathFromFSPath:(char*)path;
- (NSString*)pathWithFSRef:(FSRef*)fsRef;

@end
