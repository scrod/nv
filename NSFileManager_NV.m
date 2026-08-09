//
//  NSFileManager_NV.m
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


#import "NSFileManager_NV.h"
#import <CoreFoundation/CFURLEnumerator.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>


@implementation NSFileManager (NV)

static NSError *NVFileReferenceError(NSInteger code, NSString *description) {
	return [NSError errorWithDomain:@"NVFileReferenceErrorDomain" code:code
						 userInfo:[NSDictionary dictionaryWithObject:description
															 forKey:NSLocalizedDescriptionKey]];
}

static BOOL NVErrorContainsPOSIXCode(NSError *error, NSInteger code) {
	if (!error) return NO;
	if ([[error domain] isEqualToString:NSPOSIXErrorDomain] && [error code] == code) return YES;
	return NVErrorContainsPOSIXCode([[error userInfo] objectForKey:NSUnderlyingErrorKey], code);
}

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
	NSError *plistError = nil;
	id outObject = [NSPropertyListSerialization propertyListWithData:nsData options:NSPropertyListImmutable format:&formatFound error:&plistError];
	if (plistError) {
			NSLog(@"%@: error deserializing labels: %@", NSStringFromSelector(_cmd), plistError);
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
		NSError *serializationError = nil;
		dataToSendNS = [NSPropertyListSerialization dataWithPropertyList:plistObject format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
		if (serializationError) {
				NSLog(@"%@: error serializing labels: %@", NSStringFromSelector(_cmd), serializationError);
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
            if (errno != ENOATTR) NSLog(@"%@: couldn't set/remove attribute: %d (value '%@')", NSStringFromSelector(_cmd), errno, dataToSendNS);
		return NO;
	}

	return YES;
}

//for +setTextEncodingAttribute:atFSPath: and +textEncodingAttributeOfFSPath: (test against VOL_CAP_INT_EXTENDED_ATTR)

- (BOOL)setTextEncodingAttribute:(NSStringEncoding)encoding atFSPath:(const char*)path {
	if (!path) return NO;
	
	CFStringEncoding cfStringEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
        if (cfStringEncoding == kCFStringEncodingInvalidId) {
            NSLog(@"%@: encoding %lu is invalid!", NSStringFromSelector(_cmd), (unsigned long)encoding);
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

- (NSURL*)fileReferenceURLForURL:(NSURL*)url error:(NSError**)error {
	if (!url || ![url isFileURL]) {
		if (error) *error = NVFileReferenceError(EINVAL, @"The selected item is not a file URL.");
		return nil;
	}

	CFErrorRef conversionError = NULL;
	NSURL *referenceURL = (NSURL*)CFURLCreateFileReferenceURL(kCFAllocatorDefault,
													(CFURLRef)url, &conversionError);
	if (!referenceURL || ![referenceURL isFileReferenceURL]) {
		[referenceURL release];
		if (error) *error = conversionError ? [(NSError*)conversionError autorelease] :
			NVFileReferenceError(ENOTSUP, @"This location does not support file-reference URLs.");
		else if (conversionError) CFRelease(conversionError);
		return nil;
	}
	if (conversionError) CFRelease(conversionError);

	return [referenceURL autorelease];
}

- (NSURL*)fileReferenceURLForFilename:(NSString*)filename
				 inDirectoryURL:(NSURL*)directoryURL
						error:(NSError**)error {
	if (![directoryURL isFileReferenceURL] || ![filename length] ||
		[filename isEqualToString:@"."] || [filename isEqualToString:@".."] ||
		[filename rangeOfString:@"/"].location != NSNotFound) {
		if (error) *error = NVFileReferenceError(EINVAL, @"The filename is not a single valid path component.");
		return nil;
	}

	NSUInteger bufferSize = [filename maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
	char *fileSystemName = malloc(bufferSize);
	if (!fileSystemName) {
		if (error) *error = NVFileReferenceError(ENOMEM, @"Unable to allocate storage for the filename.");
		return nil;
	}
	if (![filename getFileSystemRepresentation:fileSystemName maxLength:bufferSize]) {
		free(fileSystemName);
		if (error) *error = NVFileReferenceError(ENAMETOOLONG, @"The filename cannot be represented by this file system.");
		return nil;
	}

	CFURLRef relativeURL = CFURLCreateFromFileSystemRepresentationRelativeToBase(kCFAllocatorDefault,
		(const UInt8*)fileSystemName, (CFIndex)strlen(fileSystemName), false, (CFURLRef)directoryURL);
	free(fileSystemName);
	if (!relativeURL) {
		if (error) *error = NVFileReferenceError(EINVAL, @"Unable to create a reference-relative file URL.");
		return nil;
	}

	CFErrorRef conversionError = NULL;
	NSURL *referenceURL = (NSURL*)CFURLCreateFileReferenceURL(kCFAllocatorDefault, relativeURL,
													&conversionError);
	if (referenceURL && [referenceURL isFileReferenceURL]) {
		CFRelease(relativeURL);
		if (conversionError) CFRelease(conversionError);
		return [referenceURL autorelease];
	}
	[referenceURL release];

	// CFURL's direct conversion resolves the complete path and can fail beyond PATH_MAX.
	// A directory enumerator rooted at a file-reference URL returns file-reference children.
	CFURLEnumeratorRef enumerator = CFURLEnumeratorCreateForDirectoryURL(kCFAllocatorDefault,
		(CFURLRef)directoryURL, kCFURLEnumeratorDefaultBehavior,
		(CFArrayRef)[NSArray arrayWithObject:NSURLNameKey]);
	CFErrorRef enumerationError = NULL;
	if (enumerator) {
		for (;;) {
			CFURLRef childURL = NULL;
			CFURLEnumeratorResult result = CFURLEnumeratorGetNextURL(enumerator, &childURL,
				&enumerationError);
			if (result == kCFURLEnumeratorEnd) break;
			if (result == kCFURLEnumeratorError) break;
			if (result == kCFURLEnumeratorSuccess) {
				NSString *childName = nil;
				if ([(NSURL*)childURL getResourceValue:&childName forKey:NSURLNameKey error:NULL] &&
					[childName isEqualToString:filename]) {
					referenceURL = [(NSURL*)childURL retain];
					break;
				}
			}
		}
		CFRelease(enumerator);
	}
	if (referenceURL) {
		CFRelease(relativeURL);
		if (conversionError) CFRelease(conversionError);
		if (enumerationError) CFRelease(enumerationError);
		return [referenceURL autorelease];
	}
	BOOL exceededPathLimit = NVErrorContainsPOSIXCode((NSError*)conversionError, ENAMETOOLONG) ||
		NVErrorContainsPOSIXCode((NSError*)enumerationError, ENAMETOOLONG);
	if (conversionError) CFRelease(conversionError);
	if (exceededPathLimit) {
		if (enumerationError) CFRelease(enumerationError);
		return [(NSURL*)relativeURL autorelease];
	}
	CFRelease(relativeURL);
	if (error) *error = enumerationError ? [(NSError*)enumerationError autorelease] :
		NVFileReferenceError(ENOENT, @"The file does not exist or cannot be represented by reference.");
	else if (enumerationError) CFRelease(enumerationError);
	return nil;
}

- (int)openFileDescriptorForDirectoryReferenceURL:(NSURL*)directoryURL error:(NSError**)error {
	if (![directoryURL isFileReferenceURL]) {
		if (error) *error = NVFileReferenceError(EINVAL, @"The directory is not a file-reference URL.");
		return -1;
	}

	NSMutableArray *components = [NSMutableArray array];
	NSURL *currentURL = directoryURL;
	int directoryFD = -1;
	for (;;) {
		const char *fileSystemPath = [currentURL fileSystemRepresentation];
		directoryFD = fileSystemPath ? open(fileSystemPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
		if (directoryFD >= 0) break;
		int openError = fileSystemPath ? errno : ENAMETOOLONG;
		if (openError != ENAMETOOLONG && openError != ENOENT) {
			if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:openError userInfo:nil];
			return -1;
		}
		if (openError == ENOENT) [currentURL removeAllCachedResourceValues];

		NSString *name = nil;
		NSURL *parentURL = nil;
		id identifier = nil;
		id parentIdentifier = nil;
		NSError *resourceError = nil;
		if (![currentURL getResourceValue:&name forKey:NSURLNameKey error:&resourceError] ||
			![currentURL getResourceValue:&parentURL forKey:NSURLParentDirectoryURLKey error:&resourceError] ||
			![currentURL getResourceValue:&identifier forKey:NSURLFileResourceIdentifierKey error:&resourceError] ||
			![parentURL getResourceValue:&parentIdentifier forKey:NSURLFileResourceIdentifierKey error:&resourceError] ||
			![name length] || ![parentURL isFileReferenceURL] || [identifier isEqual:parentIdentifier]) {
			if (error) *error = resourceError ? resourceError :
				NVFileReferenceError(ENAMETOOLONG, @"Unable to open the deeply nested directory by reference.");
			return -1;
		}
		[components addObject:name];
		currentURL = parentURL;
	}

	for (NSString *name in [components reverseObjectEnumerator]) {
		const char *fileSystemName = [name fileSystemRepresentation];
		int childFD = fileSystemName ? openat(directoryFD, fileSystemName,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC) : -1;
		if (childFD < 0) {
			int openError = fileSystemName ? errno : EINVAL;
			close(directoryFD);
			if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:openError
				userInfo:[NSDictionary dictionaryWithObject:
					[NSString stringWithFormat:@"Unable to open reference component '%@'.", name]
					forKey:NSLocalizedDescriptionKey]];
			return -1;
		}
		close(directoryFD);
		directoryFD = childFD;
	}
	return directoryFD;
}

- (NSData*)bookmarkDataForFileReferenceURL:(NSURL*)url error:(NSError**)error {
	if (![url isFileReferenceURL]) {
		if (error) *error = NVFileReferenceError(EINVAL, @"Bookmarks may only be created from file-reference URLs.");
		return nil;
	}
	return [url bookmarkDataWithOptions:NSURLBookmarkCreationWithoutImplicitSecurityScope
		includingResourceValuesForKeys:nil relativeToURL:nil error:error];
}

- (NSURL*)fileReferenceURLFromBookmarkData:(NSData*)bookmarkData
								 stale:(BOOL*)stale
								 error:(NSError**)error {
	if (![bookmarkData length]) {
		if (error) *error = NVFileReferenceError(EINVAL, @"The bookmark data is empty.");
		return nil;
	}
	BOOL localStale = NO;
	NSURL *resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
		options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil
		bookmarkDataIsStale:&localStale error:error];
	if (!resolvedURL) return nil;
	NSURL *referenceURL = [self fileReferenceURLForURL:resolvedURL error:error];
	if (referenceURL && stale) *stale = localStale;
	return referenceURL;
}


@end
