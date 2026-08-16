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
#include <string.h>
#include <sys/xattr.h>

static BOOL NVGetFileResourceIdentifier(NSURL *URL, id *identifier) {
	if (!URL || !identifier) return NO;
	*identifier = nil;
	return [URL getResourceValue:identifier forKey:NSURLFileResourceIdentifierKey error:NULL];
}

BOOL NVURLsReferToSameItem(NSURL *one, NSURL *two) {
	if (!one || !two) return NO;
	id oneIdentifier = nil;
	id twoIdentifier = nil;
	return NVGetFileResourceIdentifier(one, &oneIdentifier) &&
		NVGetFileResourceIdentifier(two, &twoIdentifier) &&
		[oneIdentifier isEqual:twoIdentifier];
}

BOOL NVURLIsInTrash(NSURL *URL) {
	NSURLRelationship relationship;
	return URL && [[NSFileManager defaultManager] getRelationship:&relationship
		ofDirectory:NSTrashDirectory inDomain:0 toItemAtURL:URL error:NULL] &&
		(relationship == NSURLRelationshipSame || relationship == NSURLRelationshipContains);
}

int NVCopyFileSystemNameForLeaf(NSString *filename, char **name) {
	if (!name) return EINVAL;
	*name = NULL;
	if (![filename length] || [filename isEqualToString:@"."] || [filename isEqualToString:@".."] ||
		[filename rangeOfString:@"/"].location != NSNotFound ||
		[filename rangeOfString:@"\0"].location != NSNotFound) return EINVAL;
	const char *representation = [filename fileSystemRepresentation];
	if (!representation || strchr(representation, '/')) return ENAMETOOLONG;
	*name = strdup(representation);
	return *name ? 0 : ENOMEM;
}

static NSError *NVInvalidMetadataError(void) {
	return [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
}

NSArray *NVOpenMetaTagsFromData(NSData *data, NSError **error) {
	if (!data) {
		if (error) *error = NVInvalidMetadataError();
		return nil;
	}
	NSError *parseError = nil;
	id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
		format:NULL error:&parseError];
	if (![value isKindOfClass:[NSArray class]]) {
		if (error) *error = parseError ?: NVInvalidMetadataError();
		return nil;
	}
	for (id tag in value) {
		if (![tag isKindOfClass:[NSString class]]) {
			if (error) *error = NVInvalidMetadataError();
			return nil;
		}
	}
	return value;
}

NSStringEncoding NVTextEncodingFromAttributeData(NSData *data, NSError **error) {
	NSString *value = [[[NSString alloc] initWithData:data
		encoding:NSUTF8StringEncoding] autorelease];
	NSArray *parts = [value componentsSeparatedByString:@";"];
	CFStringEncoding encoding = kCFStringEncodingInvalidId;
	if ([parts count] > 1) {
		NSScanner *scanner = [NSScanner scannerWithString:[parts objectAtIndex:1]];
		long long number = 0;
		if ([scanner scanLongLong:&number] && [scanner isAtEnd] && number >= 0 && number <= UINT32_MAX)
			encoding = (CFStringEncoding)number;
	} else if ([parts count] == 1) {
		encoding = CFStringConvertIANACharSetNameToEncoding((CFStringRef)[parts objectAtIndex:0]);
	}
	if (!value || encoding == kCFStringEncodingInvalidId || !CFStringIsEncodingAvailable(encoding)) {
		if (error) *error = NVInvalidMetadataError();
		return 0;
	}
	return CFStringConvertEncodingToNSStringEncoding(encoding);
}


@implementation NSFileManager (NV)

static NSError *NVFileReferenceError(NSInteger code, NSString *description) {
	return [NSError errorWithDomain:@"NVFileReferenceErrorDomain" code:code
						 userInfo:[NSDictionary dictionaryWithObject:description
														 forKey:NSLocalizedDescriptionKey]];
}

- (NSArray*)getOpenMetaTagsAtFSPath:(const char*)path {
	if (!path) return nil;
	char data[4096];
	ssize_t length = getxattr(path, "com.apple.metadata:kMDItemOMUserTags",
		data, sizeof(data), 0, 0);
	if (length <= 0) return nil;
	NSError *decodeError = nil;
	NSArray *tags = NVOpenMetaTagsFromData(
		[NSData dataWithBytes:data length:(NSUInteger)length], &decodeError);
	if (!tags) NSLog(@"%@: error deserializing labels: %@", NSStringFromSelector(_cmd), decodeError);
	return tags;
}


- (NSStringEncoding)textEncodingAttributeOfFSPath:(const char*)path {
	if (!path) return 0;
	char xattrValueBytes[128];
	ssize_t length = getxattr(path, "com.apple.TextEncoding",
		xattrValueBytes, sizeof(xattrValueBytes), 0, 0);
	if (length < 0) {
		if (ENOATTR != errno) NSLog(@"couldn't get text encoding attribute of %s: %d", path, errno);
		return 0;
	}
	return NVTextEncodingFromAttributeData(
		[NSData dataWithBytes:xattrValueBytes length:(NSUInteger)length], NULL);
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
	if (![directoryURL isFileReferenceURL]) {
		if (error) *error = NVFileReferenceError(EINVAL, @"The directory is not a file-reference URL.");
		return nil;
	}

	char *fileSystemName = NULL;
	int nameError = NVCopyFileSystemNameForLeaf(filename, &fileSystemName);
	if (nameError) {
		if (error) *error = NVFileReferenceError(nameError,
			@"The filename is not a single valid path component.");
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
