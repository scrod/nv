/*
 *  BufferUtils.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 1/15/06.
 */

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


#include <Carbon/Carbon.h>

char *replaceString(char *oldString, const char *newString);
void ResizeBuffer(void ***buffer, unsigned int objCount, unsigned int *bufSize);
int IsZeros(const void *s1, size_t n);
int ContainsUInteger(const NSUInteger *uintArray, size_t count, NSUInteger auint);
void modp_tolower_copy(char* dest, const char* str, int len);
void replace_breaks(char *str, size_t up_to_len);
int ContainsHighAscii(const void *s1, size_t n);
CFStringRef CFStringFromBase10Integer(int quantity);
unsigned DumbWordCount(const void *s1, size_t len);
NSInteger genericSortContextFirst(int (*context) (void*, void*), void* one, void* two);
NSInteger genericSortContextLast(void* one, void* two, int (*context) (void*, void*));
void QuickSortBuffer(void **buffer, unsigned int objCount, int (*compar)(const void *, const void *));
CFStringRef CreateRandomizedFileName();
OSStatus FSCreateFileIfNotPresentInDirectory(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, Boolean *created);
OSStatus FSRefMakeInDirectoryWithString(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, UniChar* charsBuffer);
OSStatus FSRefReadData(FSRef *fsRef, size_t maximumReadSize, UInt64 *bufferSize, void** newBuffer, UInt16 modeOptions);
OSStatus FSRefWriteData(FSRef *fsRef, size_t maximumWriteSize, UInt64 bufferSize, const void* buffer, UInt16 modeOptions, Boolean truncateFile);

CFStringRef CopyReasonFromFSErr(OSStatus err);
