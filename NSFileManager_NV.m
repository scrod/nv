//
//  NSFileManager_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 12/31/10.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
     conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "NSFileManager_NV.h"


@implementation NSFileManager (NV)

#define kMaxDataSize 4096

- (id)getOpenMetaTagsAtFSPath:(const char*)path {
	//return convention: empty tags should be an empty array; 
	//for files that have never been tagged, or that have had their tags removed, return 
	//files might lose their metadata if edited externally or synced without being first encoded
	
	if (!path) return nil;
	
	const char* inKeyNameC = "com.apple.metadata:kMDItemOMUserTags";
	// retrieve data from store. 
	char* data[kMaxDataSize];
	ssize_t dataSize = kMaxDataSize; // ssize_t means SIGNED size_t as getXattr returns - 1 for no attribute found
	NSData* nsData = nil;
	if ((dataSize = getxattr(path, inKeyNameC, data, dataSize, 0, 0)) > 0) {
		nsData = [NSData dataWithBytes:data	length:dataSize];
	} else {
		// I get EINVAL sometimes when setting/getting xattrs on afp servers running 10.5. When I get this error, I find that everything is working correctly... so it seems to make sense to ignore them
		// EINVAL means invalid argument. I know that the args are fine. 
		//if ((errno != ENOATTR) && (errno != EINVAL) && error) // it is not an error to have no attribute set 
		//	*error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:[NSDictionary dictionaryWithObject:[self errnoString:errno] forKey:@"info"]];
		return nil;
	}
	
	// ok, we have some data 
	NSPropertyListFormat formatFound;
	NSString* errorString = nil;
	id outObject = [NSPropertyListSerialization propertyListFromData:nsData mutabilityOption:kCFPropertyListImmutable format:&formatFound errorDescription:&errorString];
	if (errorString) {
		NSLog(@"%s: error deserializing labels: %@", _cmd, errorString);
		[errorString autorelease];
		return nil;
	}
	
	return outObject;

}


- (BOOL)setOpenMetaTags:(id)plistObject atFSPath:(const char*)path {
	if (!path) return NO;
	
	// If the object passed in has no data - is a string of length 0 or an array or dict with 0 objects, then we remove the data at the key.
	
	const char* inKeyNameC = "com.apple.metadata:kMDItemOMUserTags";
	
	long returnVal = 0;
	
	// always set data as binary plist.
	NSData* dataToSendNS = nil;
	if (plistObject) {
		NSString *errorString = nil;
		dataToSendNS = [NSPropertyListSerialization dataFromPropertyList:plistObject format:kCFPropertyListBinaryFormat_v1_0 errorDescription:&errorString];
		if (errorString) {
			NSLog(@"%s: error serializing labels: %@", _cmd, errorString);
			[errorString autorelease];
			return NO;
		}
	}
	
	if (dataToSendNS) {
		// also reject for tags over the maximum size:
		if ([dataToSendNS length] > kMaxDataSize)
			return NO;
		returnVal = setxattr(path, inKeyNameC, [dataToSendNS bytes], [dataToSendNS length], 0, 0);
	} else {
		returnVal = removexattr(path, inKeyNameC, 0);
	}
	
	if (returnVal < 0) {
		if (errno != ENOATTR) NSLog(@"%s: couldn't set/remove attribute: %d (value '%@')", _cmd, errno, dataToSendNS);
		return NO;
	}

	return YES;
}

//TODO: use volumeCapabilities in FSExchangeObjectsCompat.c to skip some work on volumes for which we know we would receive ENOTSUP
//for +setTextEncodingAttribute:atFSPath: and +textEncodingAttributeOfFSPath: (test against VOL_CAP_INT_EXTENDED_ATTR)

- (BOOL)setTextEncodingAttribute:(NSStringEncoding)encoding atFSPath:(const char*)path {
	if (!path) return NO;
	
	CFStringEncoding cfStringEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
	if (cfStringEncoding == kCFStringEncodingInvalidId) {
		NSLog(@"%s: encoding %lu is invalid!", _cmd, encoding);
		return NO;
	}
	NSString *textEncStr = [(NSString *)CFStringConvertEncodingToIANACharSetName(cfStringEncoding) stringByAppendingFormat:@";%@", 
							[[NSNumber numberWithInt:cfStringEncoding] stringValue]];
	const char *textEncUTF8Str = [textEncStr UTF8String];
	
	if (setxattr(path, "com.apple.TextEncoding", textEncUTF8Str, strlen(textEncUTF8Str), 0, 0) < 0) {
		NSLog(@"couldn't set text encoding attribute of %s to '%s': %d", path, textEncUTF8Str, errno);
		return NO;
	}
	return YES;
}

- (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path {
	if (!path) goto errorReturn;
	
	//We could query the size of the attribute, but that would require a second system call
	//and the value for this key shouldn't need to be anywhere near this large, anyway.
	//It could be, but it probably won't. If it is, then we won't get the encoding. Too bad.
	char xattrValueBytes[128] = { 0 };
	if (getxattr(path, "com.apple.TextEncoding", xattrValueBytes, sizeof(xattrValueBytes), 0, 0) < 0) {
		if (ENOATTR != errno) NSLog(@"couldn't get text encoding attribute of %s: %d", path, errno);
		goto errorReturn;
	}
	NSString *encodingStr = [NSString stringWithUTF8String:xattrValueBytes];
	if (!encodingStr) {
		NSLog(@"couldn't make attribute data from %s into a string", path);
		goto errorReturn;
	}
	NSArray *segs = [encodingStr componentsSeparatedByString:@";"];
	
	if ([segs count] >= 2 && [(NSString*)[segs objectAtIndex:1] length] > 1) {
		return CFStringConvertEncodingToNSStringEncoding([[segs objectAtIndex:1] intValue]);
	} else if ([(NSString*)[segs objectAtIndex:0] length] > 1) {
		CFStringEncoding theCFEncoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)[segs objectAtIndex:0]);
		if (theCFEncoding == kCFStringEncodingInvalidId) {
			NSLog(@"couldn't convert IANA charset");
			goto errorReturn;
		}
		return CFStringConvertEncodingToNSStringEncoding(theCFEncoding);
	}
	
errorReturn:
	return 0;
}

- (NSString*)pathCopiedFromAliasData:(NSData*)aliasData {
    AliasHandle inAlias;
    CFStringRef path = NULL;
	FSAliasInfoBitmap whichInfo = kFSAliasInfoNone;
	FSAliasInfo info;
    if (aliasData && PtrToHand([aliasData bytes], (Handle*)&inAlias, [aliasData length]) == noErr && 
		FSCopyAliasInfo(inAlias, NULL, NULL, &path, &whichInfo, &info) == noErr) {
		//this method doesn't always seem to work	
		return [(NSString*)path autorelease];
    }
    
    return nil;
}

- (NSString*)pathFromFSPath:(char*)path {
	DebugPath(path);
	return [self stringWithFileSystemRepresentation:path length:strlen(path)];
}

- (NSString*)pathWithFSRef:(FSRef*)fsRef {
	NSString *path = nil;
	
	const UInt32 maxPathSize = 4 * 1024;
	UInt8 *convertedPath = (UInt8*)malloc(maxPathSize * sizeof(UInt8));
	if (FSRefMakePath(fsRef, convertedPath, maxPathSize) == noErr) {
		path = [self stringWithFileSystemRepresentation:(char*)convertedPath length:strlen((char*)convertedPath)];
	}
	free(convertedPath);
	
	return path;
}


@end
