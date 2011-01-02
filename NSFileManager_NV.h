//
//  NSFileManager_NV.h
//  Notation
//
//  Created by Zachary Schneirov on 12/31/10.
//  Copyright 2010 Northwestern University. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface NSFileManager (NV)


- (id)getXAttr:(NSString*)inKeyName atPath:(NSString*)path;
- (BOOL)setXAttr:(id)plistObject forKey:(NSString*)inKeyName atPath:(NSString*)path;

- (NSString*)pathCopiedFromAliasData:(NSData*)aliasData;
- (BOOL)setTextEncodingAttribute:(NSStringEncoding)encoding atFSPath:(const char*)path;
- (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path;
- (NSString*)pathWithFSRef:(FSRef*)fsRef;

@end
