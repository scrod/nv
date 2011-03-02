/*
 *  BufferUtils.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 1/15/06.
 */

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


#include <Carbon/Carbon.h>

#define ResizeArray(__DirectBuffer, __objCount, __bufObjCount)	_ResizeBuffer((void***)(__DirectBuffer), (__objCount), (__bufObjCount), sizeof(typeof(**(__DirectBuffer))))

#define UTCDateTimeIsEmpty(__UTCDT) (*(int64_t*)&((__UTCDT)) == 0LL)

typedef struct _PerDiskInfo {
	
	//index in a table of disk UUIDs; should be the disk from which this time was gathered
	//the disk UUIDs table is tracked separately in NotationPrefs; it should only ever be appended-to
	UInt32 diskIDIndex;
	
	//catalog node ID of a file
	UInt32 nodeID;
	
	//the attribute modification time of a file
	UTCDateTime attrTime;
	
} PerDiskInfo;

char *replaceString(char *oldString, const char *newString);
void _ResizeBuffer(void ***buffer, unsigned int objCount, unsigned int *bufSize, unsigned int elemSize);
int IsZeros(const void *s1, size_t n);
int ContainsUInteger(const NSUInteger *uintArray, size_t count, NSUInteger auint);
void modp_tolower_copy(char* dest, const char* str, int len);
void replace_breaks_utf8(char *s, size_t up_to_len);
void replace_breaks(char *str, size_t up_to_len);
int ContainsHighAscii(const void *s1, size_t n);
CFStringRef CFStringFromBase10Integer(int quantity);
unsigned DumbWordCount(const void *s1, size_t len);
NSInteger genericSortContextFirst(int (*context) (void*, void*), void* one, void* two);
NSInteger genericSortContextLast(void* one, void* two, int (*context) (void*, void*));
void QuickSortBuffer(void **buffer, unsigned int objCount, int (*compar)(const void *, const void *));

void RemovePerDiskInfoWithTableIndex(UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount);
unsigned int SetPerDiskInfoWithTableIndex(UTCDateTime *dateTime, UInt32 *nodeID, UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount);
void CopyPerDiskInfoGroupsToOrder(PerDiskInfo **flippedGroups, unsigned int *existingCount, PerDiskInfo *perDiskGroups, size_t bufferSize, int toHostOrder);

CFStringRef CreateRandomizedFileName();
OSStatus FSCreateFileIfNotPresentInDirectory(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, Boolean *created);
OSStatus FSRefMakeInDirectoryWithString(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, UniChar* charsBuffer);
OSStatus FSRefReadData(FSRef *fsRef, size_t maximumReadSize, UInt64 *bufferSize, void** newBuffer, UInt16 modeOptions);
OSStatus FSRefWriteData(FSRef *fsRef, size_t maximumWriteSize, UInt64 bufferSize, const void* buffer, UInt16 modeOptions, Boolean truncateFile);

CFStringRef CopyReasonFromFSErr(OSStatus err);
