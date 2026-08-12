//
//  TemporaryFileCachePreparer.m
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


#import "TemporaryFileCachePreparer.h"
#import "NotationPrefs.h"
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

//used to mount a RAM disk for temporary file editing
//instances of this class are probably not useful for more than one preparation
//(which probably wouldn't be necessary anyway as RAM disks can't be unmounted)

@implementation TemporaryFileCachePreparer

static NSInteger RAMDiskMountState(const char *expectedMountPath);
static NSString *RAMDiskMountPath(void);
static NSString *TempDirectoryPathForEditing(void);
static BOOL DeviceIsRAMBacked(const char *devicePath);

/* Time Machine recognizes this binary plist on a directory and excludes that
 * directory and its contents. Set it once on the editing root (including the
 * RAM-backed NVProtectedEditingSpace volume) before any scratch file exists. */
static const unsigned char NVBackupExclusionBplist[] = {
	0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30,
	0x5f, 0x10, 0x11, 0x63, 0x6f, 0x6d, 0x2e, 0x61,
	0x70, 0x70, 0x6c, 0x65, 0x2e, 0x62, 0x61, 0x63,
	0x6b, 0x75, 0x70, 0x64, 0x08, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x1c
};

- (id)init {
	self = [super init];
	if (self) {
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskTerminated:) 
													 name:NSTaskDidTerminateNotification object:nil];
	}
	
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachePath release];
	[notationPrefs release];
	[attachTask release];
	[newfsTask release];
	[mountTask release];
	[deviceName release];
	[preparedCachePath release];
	[super dealloc];
}

static BOOL DeviceIsRAMBacked(const char *devicePath) {
	NSTask *task = [[[NSTask alloc] init] autorelease];
	NSPipe *output = [NSPipe pipe];
	[task setLaunchPath:@"/usr/bin/hdiutil"];
	[task setArguments:@[ @"info", @"-plist" ]];
	[task setStandardOutput:output];
	[task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
	@try {
		[task launch];
	} @catch (NSException *exception) {
		NSLog(@"Could not verify RAM disk backing: %@", exception);
		return NO;
	}
	NSData *data = [[[output fileHandleForReading] readDataToEndOfFile] retain];
	[task waitUntilExit];
	if ([task terminationStatus] != 0) {
		[data release];
		return NO;
	}
	NSDictionary *info = [NSPropertyListSerialization propertyListWithData:data
		options:NSPropertyListImmutable format:NULL error:NULL];
	[data release];
	NSString *device = [NSString stringWithUTF8String:devicePath];
	for (NSDictionary *image in [info objectForKey:@"images"]) {
		NSString *imagePath = [image objectForKey:@"image-path"];
		NSNumber *owner = [image objectForKey:@"owner-uid"];
		if (![imagePath hasPrefix:@"ram://"] || (owner && [owner unsignedIntValue] != getuid()))
			continue;
		for (NSDictionary *entity in [image objectForKey:@"system-entities"])
			if ([[entity objectForKey:@"dev-entry"] isEqualToString:device]) return YES;
	}
	return NO;
}

static NSInteger RAMDiskMountState(const char *expectedMountPath) {
	struct statfs *buf;
	struct stat pathStatus;
	if (lstat(expectedMountPath, &pathStatus) < 0) return errno == ENOENT ? 0 : -1;
	
	int i, numMounts = getmntinfo(&buf, MNT_NOWAIT);
	if (!numMounts) return 0;
	
	char absExpectedMountPath[PATH_MAX];	
	if (!realpath(expectedMountPath, absExpectedMountPath)) {
		NSLog(@"error getting realpath from path '%s': %d", expectedMountPath, errno);
		return 0;
	}
	
	for (i=0; i<numMounts; ++i) {
		if (!strcmp(absExpectedMountPath, buf[i].f_mntonname)) {
			return !strcmp(buf[i].f_fstypename, "hfs") &&
				DeviceIsRAMBacked(buf[i].f_mntfromname) ? 1 : -1;
		}
	}
	
	return 0;
}

static NSString *RAMDiskMountPath(void) {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:@"NVProtectedEditingSpace"];
}

static NSString *TempDirectoryPathForEditing(void) {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:@"NVPlainTextEditingSpace"];
}

- (void)prepEditingSpaceIfNecessaryForNotationPrefs:(NotationPrefs*)prefs {
	
	NSAssert(prefs != nil, @"prefs are nil");
	
	if ([self isPreparing]) {
		NSLog(@"prepEditingSpaceIfNecessary: already preparing");
		return;
	}
	
	[notationPrefs release];
	notationPrefs = [prefs retain];
	
	/*
		single-DB with encryption: use a mounted RAM disk
		single-DB without encryption: use temp directory
		plain text files: just use files directly
		rich text files: use temp directory
		HTML files: use temp directory
	
		ExternalEditingSession will decide based on each specific file whether to open it directly
		e.g., if it's a plain text file in plain-text-mode, or if the editor supports RTF/HTML
	*/
	
	if ([prefs notesStorageFormat] != SingleDatabaseFormat || ![prefs doesEncryption]) {
		if ([self _createFolderAtPath:TempDirectoryPathForEditing()]) {
			[self _finishPreparationWithPath:TempDirectoryPathForEditing()];
		} else {
			[self _stopPreparation];
		}
		return;
	}
	
	NSInteger mountState = RAMDiskMountState([RAMDiskMountPath() fileSystemRepresentation]);
	if (mountState > 0) {
		//NSLog(@"mount point already exists; giving path directly");
		[self _finishPreparationWithPath:RAMDiskMountPath()];
		return;
	}
	if (mountState < 0) {
		NSLog(@"Refusing unrecognized mount at private external-editing path");
		[self _stopPreparation];
		return;
	}
		
	NSAssert(preparedCachePath == nil, @"preparedCachePath was already set");
	
	startedPreparing = YES;
	
	//now do a callback-chained hdiutil attach, newfs_hfs, and mount -t at RAMDiskMountPath()
	
	[self _attachRAMDiskOfCapacity:2];
}

- (void)_attachRAMDiskOfCapacity:(NSUInteger)numberOfMegabytes {
	NSAssert(attachTask == nil, @"attachTask was already used!");
	NSAssert(numberOfMegabytes > 0 && numberOfMegabytes < 100, @"unreasonable capacity requested");

	[self retain];
	[(attachTask = [NSTask new]) setLaunchPath:@"/usr/bin/hdiutil"];
	[attachTask setArguments:[NSArray arrayWithObjects:@"attach", @"-nomount", @"-nobrowse", [NSString stringWithFormat:@"ram://%lu", (unsigned long)(2 * 1024 * numberOfMegabytes)], nil]];
	[attachTask setStandardOutput:[NSPipe pipe]];
	[attachTask launch];
}

- (void)_buildHFSFileSystemOnDevice:(NSString*)aDeviceName {
	NSAssert(newfsTask == nil, @"newfsTask was already used!");
	NSAssert(aDeviceName != nil, @"no device name passed");
	
	[self retain];
	[(newfsTask = [NSTask new]) setLaunchPath:@"/sbin/newfs_hfs"];
	[newfsTask setArguments:[NSArray arrayWithObjects:@"-v", [RAMDiskMountPath() lastPathComponent], aDeviceName, nil]];
	[newfsTask launch];
}

- (void)_mountHFSFileSystemOnDevice:(NSString*)aDeviceName {
	NSAssert(mountTask == nil, @"mountTask was already used!");
	NSAssert(aDeviceName != nil, @"no device name passed");
	
	[self retain];
	[(mountTask = [NSTask new]) setLaunchPath:@"/sbin/mount"];
	[mountTask setArguments:[NSArray arrayWithObjects:@"-t", @"hfs", @"-o", @"nobrowse", aDeviceName, RAMDiskMountPath(), nil]];
	[mountTask launch];
}

- (BOOL)isPreparing {
	return startedPreparing;
}

- (NSString*)preparedCachePath {
	return preparedCachePath;
}

- (void)_finishPreparationWithPath:(NSString*)aPath {
	//funnel for the success delegate method
	if (preparedCachePath) {
		if (![preparedCachePath isEqualToString:aPath]) {
			NSLog(@"External-editing storage was already prepared at a different path");
			[self _stopPreparation];
		}
		return;
	}
	struct stat status = { 0 };
	if (lstat([aPath fileSystemRepresentation], &status) < 0 ||
		!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode) ||
		chmod([aPath fileSystemRepresentation], 0700) < 0) {
		NSLog(@"External-editing storage is not a private directory: %@", aPath);
		[self _stopPreparation];
		return;
	}
	/* Best effort: an unsupported directory xattr must not prevent editing. */
	(void)setxattr([aPath fileSystemRepresentation],
		"com.apple.metadata:com_apple_backup_excludeItem",
		NVBackupExclusionBplist, sizeof(NVBackupExclusionBplist), 0, 0);
	preparedCachePath = [aPath retain];
	
	startedPreparing = NO;
	
	[delegate temporaryFileCachePreparerFinished:self];
}

- (void)_stopPreparation {

	startedPreparing = NO;

	[delegate temporaryFileCachePreparerDidNotFinish:self];
}

- (void)setDelegate:(id)aDelegate {
	if (aDelegate) {
		NSAssert([aDelegate respondsToSelector:@selector(temporaryFileCachePreparerDidNotFinish:)], @"delegate is bad (1)");
		NSAssert([aDelegate respondsToSelector:@selector(temporaryFileCachePreparerFinished:)], @"delegate is bad (2)");
	}
	delegate = aDelegate;
}
- (id)delegate {
	return delegate;
}

- (BOOL)_createFolderAtPath:(NSString*)path {
	NSError *err = nil;
	NSFileManager *fileMan = [NSFileManager defaultManager];
	BOOL isDirectory = NO, didCreate = ([fileMan fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) ? YES : 
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
	[fileMan createDirectoryAtPath:path withIntermediateDirectories:NO attributes:
	 [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions] error:&err];
#else
	[fileMan createDirectoryAtPath:path attributes:
	 [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700] forKey:NSFilePosixPermissions]];
#endif
	if (!didCreate) NSLog(@"couldn't create directory '%@': %@", path, (err ? [err localizedDescription] : @"(unknown error)"));
	return didCreate;
}

- (void)taskTerminated:(NSNotification *)aNotification {

	if (startedPreparing) {
		NSTask *task = [aNotification object];
		
		if (task == attachTask || task == newfsTask || task == mountTask) {
			//each launched task retains self, so as long as each task triggers this method, then each retain should be balanced with an autorelease
			[self autorelease];
			
			if ([task terminationStatus]) {
				//assume an exit status of 0 means success
				[self _stopPreparation];
				return;
			}
		}
		
		if (task == attachTask) {
			//read deviceName and store in ivar
			//start newfs task
			
			NSData	*outData = [[[attachTask standardOutput] fileHandleForReading] readDataToEndOfFile];
			if (outData) {
				NSString *outString = [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease];
				
					NSString *scannedDeviceName = nil;
					[[NSScanner scannerWithString:outString] scanUpToCharactersFromSet:
					 [NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&scannedDeviceName];
					deviceName = [(scannedDeviceName ? scannedDeviceName : outString) retain];
			}
			if (![deviceName length]) {
				NSLog(@"couldn't get device name from hdiutil attach");
				[self _stopPreparation];
			} else {
//				NSLog(@"device name is '%@'", deviceName);
				[self _buildHFSFileSystemOnDevice:deviceName];
			}
		}
		
		if (task == newfsTask) {
			//make directory and set permissions
			if (![self _createFolderAtPath:RAMDiskMountPath()]) {
				[self _stopPreparation];
			} else {
				//start mount task
				[self _mountHFSFileSystemOnDevice:deviceName];
			}
		}
		
		if (task == mountTask) {
			//return newly initialized path to delegate, after verifying
			
			NSString *path = RAMDiskMountPath();
			if (RAMDiskMountState([path fileSystemRepresentation]) > 0) {
				[self _finishPreparationWithPath:path];
			} else {
				NSLog(@"the RAM disk somehow does not exist!");
				[self _stopPreparation];
			}
		}
		
	} else {
		//don't bother doing anything unless we're actually expecting one of this instance's tasks to complete
	}
}



@end
