/*
 *  BufferUtils.c
 *  Notation
 *
 *  Created by Zachary Schneirov on 1/15/06.
 *  Copyright 2006 Zachary Schneirov. All rights reserved.
 *
 */

#include "BufferUtils.h"
#include <string.h>
//#include "CarbonFSErrorStrings.h"

#define MIN(a, b)  (((a)<(b))?(a):(b))

char *replaceString(char *oldString, const char *newString) {
    size_t newLen = strlen(newString) + 1;

    //realloc is smart enough to do better memory management than we can do right here
    char *resizedString = (char*)realloc(oldString, newLen);
    memmove(resizedString, newString, newLen);
    
    return resizedString;
}

void ResizeBuffer(void ***buffer, unsigned int objCount, unsigned int *bufSize) {
	assert(buffer && bufSize);
	
	if (*bufSize < objCount || !*buffer) {
		*buffer = (void **)realloc(*buffer, sizeof(void*) * objCount);
		*bufSize = objCount;
	}
	
}

int IsZeros(const void *s1, size_t n) {
	if (n != 0) {
		const unsigned char *p1 = s1;
		
		do {
			if (*p1++ != 0)
				return (0);
		} while (--n != 0);
	}
	return (1);
}

void MakeLowercase(char *text) {
    while (*text!='\0') {
        if (isupper(*text))
            *text=tolower(*text);
        ++text;
    }
}


int ContainsHighAscii(const void *s1, size_t n) {
	
	register unsigned int *intBuffer = (unsigned int*)s1;
	register unsigned int i, pattern = 0x80808080;
	register unsigned int integerCount = n/sizeof(unsigned int);	
	
	//could be further parallelized with 64-bit integers and altivec
	for (i=0; i<integerCount; i++ ) {
		if (pattern & intBuffer[i]) {
			return 1;
		}
	}
	
	unsigned char *charBuffer = (unsigned char*)s1;
	unsigned int leftOverCharCount = n % sizeof(unsigned int);
	
	for (i = n - leftOverCharCount; i<n; i++) {
		if (charBuffer[i] > 127) {
			return 1;
		}
	}
	
	return 0;
}

CFStringRef CFStringFromBase10Integer(int quantity) {
	char *buffer = NULL;
	if (asprintf(&buffer, "%d", quantity) < 0 || !buffer)
		return nil;
	
	//try to get on the fast path of __CFStringCreateImmutableFunnel3; most overhead will be in cfruntime allocation, anyway, though, so whatever.
	CFStringEncoding encoding = CFStringGetSystemEncoding() == kCFStringEncodingMacRoman ? kCFStringEncodingMacRoman : kCFStringEncodingASCII;
	return CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, buffer, encoding, kCFAllocatorDefault);	
}

unsigned DumbWordCount(const void *s1, size_t len) {

	unsigned count = len > 0;
	//we could do a lot more here, but we don't.
	const void *ptr = s1;
	while ((ptr = memchr(ptr + 1, 0x20, len))) {
		count++;
	}
//	printf("bacon: %u\n", count);

	return count;
}

int genericSortContextFirst(int (*context) (void*, void*), void* one, void* two) {
	
	return context(one, two);
}

int genericSortContextLast(void* one, void* two, int (*context) (void*, void*)) {
	
	return context(&one, &two);
}

void QuickSortBuffer(void **buffer, unsigned int objCount, int (*compar)(const void *, const void *)) {
	qsort_r((void *)buffer, (size_t)objCount, sizeof(void*), compar, (int (*)(void *, const void *, const void *))genericSortContextFirst);
}

/*
CFStringRef CopyReasonFromFSErr(OSStatus err) {
    
    size_t codeCount = sizeof(errorCodes) / sizeof(OSStatus);
    size_t stringCount = sizeof(errorStrings) / sizeof(char*);
    assert(stringCount == codeCount);
    
    unsigned int i;
    
    if (err < 0) {
	
	for (i=0; i<codeCount; i++) {
	    if (errorCodes[i] == err)
		return CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, errorStrings[i], kCFStringEncodingUTF8, kCFAllocatorNull);
	}
	return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("an error of type %d occurred"), err);
    }
    
    return CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, strerror((int)err), kCFStringEncodingUTF8, kCFAllocatorNull);
}*/

#if 0
//this does not use the user's defined date styles
const double dayInSeconds = 86400.0;
enum {ThisDay = 0, NextDay, PriorDay};
CFStringRef GetRelativeDateStringFromTimeAndLocaleInfo(CFAbsoluteTime time, CFStringRef *designations, char **months) {
    static CFAbsoluteTime currentDay = 0.0;
    if (currentDay == 0.0)
	currentDay = ceil(CFAbsoluteTimeGetCurrent() / dayInSeconds) * dayInSeconds;

    CFGregorianDate unitsDate = CFAbsoluteTimeGetGregorianDate(time, NULL);
    
    CFAbsoluteTime timeDay = ceil(time / dayInSeconds) * dayInSeconds;
    if (timeDay == currentDay) {
	return designations[ThisDay];
    } else if (timeDay == currentDay + dayInSeconds) {
	return designations[NextDay];
    } else if (timeDay == currentDay - dayInSeconds) {
	return designations[PriorDay];
    }
    
    return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%s %u, %u  %u:%u %s"), 
				    months[unitsDate.month], unitsDate.day, unitsDate.year, unitsDate.hour, unitsDate.minute, amppmStr);
}
#endif

CFStringRef GetRandomizedFileName() {
    static int sequence = 0;
    
    sequence++;
    
    ProcessSerialNumber psn;
    OSStatus err = noErr;
    if ((err = GetCurrentProcess(&psn)) != noErr) {
	printf("error getting process serial number: %ld\n", err);
	
	//just use the location of our memory
	psn.lowLongOfPSN = (unsigned long)&psn;
    }
    
    CFStringRef name = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR(".%lu%lu-%d-%d"), 
						psn.highLongOfPSN, psn.lowLongOfPSN, (int)CFAbsoluteTimeGetCurrent(), sequence);
    
    return name;
}

OSStatus FSCreateFileIfNotPresentInDirectory(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, Boolean *created) {
	UniChar chars[256];
    
    OSStatus result;
    CFStringRef filenameCFStr = (CFStringRef)filename;
    
    if (created) *created = false;
    
    if ((result = FSRefMakeInDirectoryWithString(directoryRef, childRef, filenameCFStr, chars))) {
		if (result == fnfErr) {
			if (created) *created = true;
			
			result = FSCreateFileUnicode(directoryRef, CFStringGetLength(filenameCFStr), chars, kFSCatInfoNone, NULL, childRef, NULL);
		}
		return result;
    }
    
    return noErr;	
}

OSStatus FSRefMakeInDirectoryWithString(FSRef *directoryRef, FSRef *childRef, CFStringRef filename, UniChar* charsBuffer) {
    CFRange range;
    range.location = 0;
    range.length = CFStringGetLength(filename);
	
	if (range.length > 255)	return errFSNameTooLong;
	
    CFStringGetCharacters(filename, range, charsBuffer);

    return FSMakeFSRefUnicode(directoryRef, range.length, charsBuffer, kTextEncodingDefaultFormat, childRef);
}

//use BlockSizeForNotation((NotationController *)delegate) for maximum read size
//use noCacheMask for options if not expecting to read again
OSStatus FSRefReadData(FSRef *fsRef, size_t maximumReadSize, UInt64 *bufferSize, void** newBuffer, UInt16 modeOptions) {
    OSStatus err = noErr;
	HFSUniStr255 dfName; //this is just NULL / 0, anyway
    SInt16 refNum;
    SInt64 forkSize;
    ByteCount readActualCount = 0, totalReadBytes = 0;
	
	if (!bufferSize || !newBuffer || !fsRef) {
		printf("FSRefReadData: NULL buffers or fsRef\n");
		return paramErr;
	}
    
    if ((err = FSGetDataForkName(&dfName)) != noErr) {
		printf("FSGetDataForkName: error %ld\n", err);
		return err;
    }
    
	//FSOpenFork
    //get vrefnum or whatever
    //get fork size
	//read data
    if ((err = FSOpenFork(fsRef, dfName.length, dfName.unicode, fsRdPerm, &refNum)) != noErr) {
		printf("FSOpenFork: error %ld\n", err);
		return err;
    }
    if ((forkSize = *bufferSize) < 1) {
		if ((err = FSGetForkSize(refNum, &forkSize)) != noErr) {
			printf("FSGetForkSize: error %ld\n", err);
			return err;
		}
    }
    
	long copyBufferSize = MIN(maximumReadSize, forkSize);
    void *fullSizeBuffer = (void*)malloc(forkSize);
    
    while (noErr == err && totalReadBytes < forkSize) {
		err = FSReadFork(refNum, fsAtMark + modeOptions, 0, copyBufferSize, fullSizeBuffer + totalReadBytes, &readActualCount);
		totalReadBytes += readActualCount;
    }
    OSErr lastReadErr = err;
	
	if ((err = FSCloseFork(refNum)) != noErr)
		printf("FSCloseFork: error %ld\n", err);
    
    *newBuffer = fullSizeBuffer;
	//in case we read less than the expected size or the size was not initially known
	*bufferSize = totalReadBytes;
    
    return (eofErr == lastReadErr ? noErr : lastReadErr);
}

OSStatus FSRefWriteData(FSRef *fsRef, size_t maximumWriteSize, UInt64 bufferSize, const void* buffer, UInt16 modeOptions, Boolean truncateFile) {
	OSStatus err = noErr;
	HFSUniStr255 dfName; //this is just NULL / 0, anyway
    SInt16 refNum;
    ByteCount writeActualCount = 0, totalWrittenBytes = 0;
	
	if (!buffer || !fsRef) {
		printf("FSRefWriteData: NULL buffers or fsRef\n");
		return paramErr;
	}
    
    if ((err = FSGetDataForkName(&dfName)) != noErr) {
		printf("FSGetDataForkName: error %ld\n", err);
		return err;
    }
    
	//FSOpenFork
    //get vrefnum or whatever
    if ((err = FSOpenFork(fsRef, dfName.length, dfName.unicode, fsWrPerm, &refNum)) != noErr) {
		printf("FSOpenFork: error %ld\n", err);
		return err;
    }
    
	ByteCount writeBufferSize = MIN(maximumWriteSize, bufferSize);
    
    while (noErr == err && totalWrittenBytes < bufferSize) {

	err = FSWriteFork(refNum, fsAtMark + modeOptions, 0, 
			  MIN(writeBufferSize, bufferSize - totalWrittenBytes),
			  buffer + totalWrittenBytes, &writeActualCount);
	totalWrittenBytes += writeActualCount;
    }
    OSErr writeError = err;
	
	if (truncateFile && (err = FSSetForkSize(refNum, fsFromStart, bufferSize))) {
		printf("FSOpenFork: FSSetForkSize %ld\n", err);
		return err;
	}
    
	if ((err = FSCloseFork(refNum)) != noErr)
		printf("FSCloseFork: error %ld\n", err);
	
    return writeError;
}
