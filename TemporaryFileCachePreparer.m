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
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

@interface TemporaryFileCachePreparer ()
@property (nonatomic, retain, readwrite) NSString *preparedCachePath;
@end

//used to mount a RAM disk for temporary file editing
//instances of this class are probably not useful for more than one preparation
//(which probably wouldn't be necessary anyway as RAM disks can't be unmounted)

@implementation TemporaryFileCachePreparer

@synthesize preparing = startedPreparing, preparedCachePath;

static NSInteger RAMDiskMountState(const char *expectedMountPath);
static NSString *RAMDiskMountPath(void);
static NSString *TempDirectoryPathForEditing(void);
static BOOL DeviceIsRAMBacked(const char *devicePath);
static void NVCleanStaleEditingFiles(int rootFD, NSString *rootPath);

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
		cacheLockFD = -1;
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskTerminated:) 
													 name:NSTaskDidTerminateNotification object:nil];
	}
	
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[attachTask release];
	[newfsTask release];
	[mountTask release];
	[deviceName release];
	[preparedCachePath release];
	if (cacheLockFD >= 0) close(cacheLockFD);
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
	NSData *data = [[output fileHandleForReading] readDataToEndOfFile];
	[task waitUntilExit];
	if ([task terminationStatus] != 0) return NO;
	NSDictionary *info = [NSPropertyListSerialization propertyListWithData:data
		options:NSPropertyListImmutable format:NULL error:NULL];
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

static void NVCleanStaleEditingFiles(int rootFD, NSString *rootPath) {
	for (NSString *name in [[NSFileManager defaultManager]
		contentsOfDirectoryAtPath:rootPath error:NULL]) {
		struct stat entry = { 0 };
		const char *fileName = [name fileSystemRepresentation];
		if (fstatat(rootFD, fileName, &entry, AT_SYMLINK_NOFOLLOW) < 0) continue;
		if (!S_ISDIR(entry.st_mode) || ![name hasPrefix:@"NVEditing-"]) continue;

		int directoryFD = openat(rootFD, fileName,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
		int lockFD = directoryFD >= 0 ? openat(directoryFD,
			".NVExternalEditing.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
		if (lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) < 0) {
			if (lockFD >= 0) close(lockFD);
			if (directoryFD >= 0) close(directoryFD);
			continue;
		}
		NSString *directoryPath = [rootPath stringByAppendingPathComponent:name];
		for (NSString *child in [[NSFileManager defaultManager]
			contentsOfDirectoryAtPath:directoryPath error:NULL]) {
			struct stat childEntry = { 0 };
			const char *childName = [child fileSystemRepresentation];
			if (fstatat(directoryFD, childName, &childEntry, AT_SYMLINK_NOFOLLOW) == 0 &&
				S_ISREG(childEntry.st_mode))
				(void)unlinkat(directoryFD, childName, 0);
		}
		close(directoryFD);
		(void)unlinkat(rootFD, fileName, AT_REMOVEDIR);
		close(lockFD);
	}
}

- (void)prepEditingSpaceIfNecessaryForNotationPrefs:(NotationPrefs*)prefs {
	
	NSAssert(prefs != nil, @"prefs are nil");
	
	if ([self isPreparing]) {
		NSLog(@"prepEditingSpaceIfNecessary: already preparing");
		return;
	}
	
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
		NSString *path = TempDirectoryPathForEditing();
		if ([self _createFolderAtPath:path]) {
			[self _finishPreparationWithPath:path];
		} else {
			[self _stopPreparation];
		}
		return;
	}
	
	NSString *path = RAMDiskMountPath();
	NSInteger mountState = RAMDiskMountState([path fileSystemRepresentation]);
	if (mountState > 0) {
		[self _finishPreparationWithPath:path];
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
	[attachTask setArguments:@[ @"attach", @"-nomount", @"-nobrowse", [NSString stringWithFormat:@"ram://%lu", (unsigned long)(2 * 1024 * numberOfMegabytes)] ]];
	[attachTask setStandardOutput:[NSPipe pipe]];
	[attachTask launch];
}

- (void)_buildHFSFileSystemOnDevice:(NSString*)aDeviceName {
	NSAssert(newfsTask == nil, @"newfsTask was already used!");
	NSAssert(aDeviceName != nil, @"no device name passed");
	
	[self retain];
	[(newfsTask = [NSTask new]) setLaunchPath:@"/sbin/newfs_hfs"];
	[newfsTask setArguments:@[ @"-v", [RAMDiskMountPath() lastPathComponent], aDeviceName ]];
	[newfsTask launch];
}

- (void)_mountHFSFileSystemOnDevice:(NSString*)aDeviceName {
	NSAssert(mountTask == nil, @"mountTask was already used!");
	NSAssert(aDeviceName != nil, @"no device name passed");
	
	[self retain];
	[(mountTask = [NSTask new]) setLaunchPath:@"/sbin/mount"];
	[mountTask setArguments:@[ @"-t", @"hfs", @"-o", @"nobrowse", aDeviceName, RAMDiskMountPath() ]];
	[mountTask launch];
}

- (void)_finishPreparationWithPath:(NSString*)aPath {
	//funnel for the success delegate method
	if (preparedCachePath) {
		if (![[preparedCachePath stringByDeletingLastPathComponent] isEqualToString:aPath]) {
			NSLog(@"External-editing storage was already prepared at a different path");
			[self _stopPreparation];
		}
		return;
	}
	struct stat status = { 0 };
	if (lstat([aPath fileSystemRepresentation], &status) < 0 ||
		!S_ISDIR(status.st_mode) ||
		chmod([aPath fileSystemRepresentation], 0700) < 0) {
		NSLog(@"External-editing storage is not a private directory: %@", aPath);
		[self _stopPreparation];
		return;
	}
	/* Hold the root lock only while collecting abandoned workspaces and creating
	 * ours. Each live preparer then owns a separately locked directory, allowing
	 * NV processes using unrelated databases to edit concurrently. */
	int rootFD = open([aPath fileSystemRepresentation],
		O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	int rootLockFD = rootFD >= 0 ? openat(rootFD, ".NVExternalEditing.lock",
		O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
	if (rootLockFD < 0 || flock(rootLockFD, LOCK_EX | LOCK_NB) < 0) {
		if (rootLockFD >= 0) close(rootLockFD);
		if (rootFD >= 0) close(rootFD);
		NSLog(@"Could not coordinate external-editing storage cleanup");
		[self _stopPreparation];
		return;
	}
	NVCleanStaleEditingFiles(rootFD, aPath);

	NSString *workspaceName = nil;
	int workspaceFD = -1;
	for (NSUInteger attempt = 0; attempt < 10 && workspaceFD < 0; attempt++) {
		workspaceName = [@"NVEditing-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
		if (mkdirat(rootFD, [workspaceName fileSystemRepresentation], 0700) == 0)
			workspaceFD = openat(rootFD, [workspaceName fileSystemRepresentation],
				O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
	}
	int lockFD = workspaceFD >= 0 ? openat(workspaceFD, ".NVExternalEditing.lock",
		O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
	if (lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) < 0) {
		if (lockFD >= 0) close(lockFD);
		if (workspaceFD >= 0) close(workspaceFD);
		if (workspaceName) (void)unlinkat(rootFD,
			[workspaceName fileSystemRepresentation], AT_REMOVEDIR);
		close(rootLockFD);
		close(rootFD);
		NSLog(@"Could not create private external-editing workspace");
		[self _stopPreparation];
		return;
	}
	close(workspaceFD);
	close(rootLockFD);
	close(rootFD);
	cacheLockFD = lockFD;
	/* Best effort: an unsupported directory xattr must not prevent editing. */
	(void)setxattr([aPath fileSystemRepresentation],
		"com.apple.metadata:com_apple_backup_excludeItem",
		NVBackupExclusionBplist, sizeof(NVBackupExclusionBplist), 0, 0);
	NSString *workspacePath = [aPath stringByAppendingPathComponent:workspaceName];
	(void)setxattr([workspacePath fileSystemRepresentation],
		"com.apple.metadata:com_apple_backup_excludeItem",
		NVBackupExclusionBplist, sizeof(NVBackupExclusionBplist), 0, 0);
	self.preparedCachePath = workspacePath;
	
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
	BOOL isDirectory = NO;
	BOOL didCreate = [fileMan fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
	if (!didCreate)
		didCreate = [fileMan createDirectoryAtPath:path withIntermediateDirectories:NO
			attributes:@{ NSFilePosixPermissions: @((unsigned long)0700) } error:&err];
	if (!didCreate) NSLog(@"couldn't create directory '%@': %@", path, (err ? [err localizedDescription] : @"(unknown error)"));
	return didCreate;
}

- (void)taskTerminated:(NSNotification *)aNotification {
	if (!startedPreparing) return;

	NSTask *task = [aNotification object];
	if (task != attachTask && task != newfsTask && task != mountTask) return;

	// Each launched task retains self; its termination balances that ownership.
	[self autorelease];
	if ([task terminationStatus]) {
		[self _stopPreparation];
		return;
	}

	if (task == attachTask) {
		NSData *outData = [[[attachTask standardOutput] fileHandleForReading] readDataToEndOfFile];
		if (outData) {
			NSString *outString = [[[NSString alloc] initWithData:outData
				encoding:NSUTF8StringEncoding] autorelease];
			NSString *scannedDeviceName = nil;
			[[NSScanner scannerWithString:outString] scanUpToCharactersFromSet:
				[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&scannedDeviceName];
			deviceName = [(scannedDeviceName ? scannedDeviceName : outString) retain];
		}
		if (![deviceName length]) {
			NSLog(@"couldn't get device name from hdiutil attach");
			[self _stopPreparation];
		} else {
			[self _buildHFSFileSystemOnDevice:deviceName];
		}
		return;
	}

	if (task == newfsTask) {
		if ([self _createFolderAtPath:RAMDiskMountPath()])
			[self _mountHFSFileSystemOnDevice:deviceName];
		else
			[self _stopPreparation];
		return;
	}

	NSString *path = RAMDiskMountPath();
	if (RAMDiskMountState([path fileSystemRepresentation]) > 0) {
		[self _finishPreparationWithPath:path];
	} else {
		NSLog(@"the RAM disk somehow does not exist!");
		[self _stopPreparation];
	}
}



@end
