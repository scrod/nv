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
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/param.h>
#include <unistd.h>


@implementation NSFileManager (NV)

static NSError *NVFileReferenceError(NSInteger code, NSString *description) {
	return [NSError errorWithDomain:@"NVFileReferenceErrorDomain" code:code
						 userInfo:[NSDictionary dictionaryWithObject:description
														 forKey:NSLocalizedDescriptionKey]];
}

#define NVDirectoryOpenFlags (O_RDONLY | O_DIRECTORY | O_CLOEXEC)

static int NVOpenDirectory(const char *path) {
	return path ? open(path, NVDirectoryOpenFlags) : -1;
}

static int NVFileDescriptorError(NSError **error, NSError *value) {
	if (error) *error = value;
	return -1;
}

static int NVOpenDeepDirectory(NSURL *URL, NSError **error) {
	NSNumber *isDirectory = nil;
	NSError *resolutionError = nil;
	if (![URL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resolutionError] ||
		![isDirectory boolValue])
		return NVFileDescriptorError(error, resolutionError ?: NVFileReferenceError(ENOTDIR,
			@"The referenced item is not a reachable directory."));

	CFIndex capacity = PATH_MAX;
	UInt8 *path = NULL;
	for (; capacity <= LONG_MAX / 2; capacity *= 2) {
		path = reallocf(path, (size_t)capacity);
		if (!path) return NVFileDescriptorError(error, NVFileReferenceError(ENOMEM,
			@"Unable to allocate the resolved directory path."));
		if (CFURLGetFileSystemRepresentation((CFURLRef)URL, true, path, capacity)) break;
	}
	if (capacity > LONG_MAX / 2 || path[0] != '/') {
		free(path);
		return NVFileDescriptorError(error, NVFileReferenceError(ENAMETOOLONG,
			@"Unable to resolve the deeply nested directory reference."));
	}

	int directoryFD = NVOpenDirectory("/");
	int openError = errno;
	for (char *component = (char *)path + 1; directoryFD >= 0 && *component;) {
		char *end = component + MIN(strlen(component), PATH_MAX - 1);
		while (end > component && *end && *end != '/') end--;
		if (end == component) {
			close(directoryFD);
			directoryFD = -1;
			openError = ENAMETOOLONG;
			break;
		}
		char separator = *end;
		*end = '\0';
		int childFD = openat(directoryFD, component, NVDirectoryOpenFlags);
		openError = errno;
		*end = separator;
		close(directoryFD);
		directoryFD = childFD;
		component = end;
		while (*component == '/') component++;
	}
	free(path);
	return directoryFD >= 0 ? directoryFD : NVFileDescriptorError(error,
		[NSError errorWithDomain:NSPOSIXErrorDomain code:openError userInfo:nil]);
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
	return [(NSURL*)relativeURL autorelease];
}

/*
 * Open a directory while preserving file-reference semantics.  The resolved
 * path normally costs one open; ENOENT clears a possibly stale NSURL cache and
 * retries once.  If the absolute path exceeds PATH_MAX, resolve it into a
 * dynamically sized buffer and open the path in the fewest PATH_MAX-sized,
 * directory-relative chunks so renames remain harmless after the FD is open.
 */
- (int)openFileDescriptorForDirectoryReferenceURL:(NSURL*)directoryURL error:(NSError**)error {
	if (![directoryURL isFileReferenceURL])
		return NVFileDescriptorError(error, NVFileReferenceError(EINVAL,
			@"The directory is not a file-reference URL."));

	const char *fileSystemPath = [directoryURL fileSystemRepresentation];
	int directoryFD = NVOpenDirectory(fileSystemPath);
	if (directoryFD >= 0) return directoryFD;
	int openError = fileSystemPath ? errno : ENAMETOOLONG;
	if (openError == ENOENT) {
		[directoryURL removeAllCachedResourceValues];
		fileSystemPath = [directoryURL fileSystemRepresentation];
		directoryFD = NVOpenDirectory(fileSystemPath);
		if (directoryFD >= 0) return directoryFD;
		openError = fileSystemPath ? errno : ENAMETOOLONG;
	}
	return openError == ENAMETOOLONG ? NVOpenDeepDirectory(directoryURL, error) :
		NVFileDescriptorError(error,
			[NSError errorWithDomain:NSPOSIXErrorDomain code:openError userInfo:nil]);
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
	NSURL *referenceURL = [resolvedURL isFileReferenceURL] ? resolvedURL :
		[self fileReferenceURLForURL:resolvedURL error:error];
	if (referenceURL && stale) *stale = localStale;
	return referenceURL;
}


@end
