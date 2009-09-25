/*
 *  CarbonFSErrorStrings.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 4/22/06.
 *  Copyright 2006 __MyCompanyName__. All rights reserved.
 *
 */

#include <Carbon/Carbon.h>

static OSStatus errorCodes[] = { dirFulErr, dskFulErr, nsvErr, ioErr, bdNamErr, fnOpnErr, eofErr, posErr, mFulErr, tmfoErr, fnfErr, wPrErr, 
    fLckdErr, vLckdErr, fBsyErr, dupFNErr, opWrErr, paramErr, rfNumErr, gfpErr, volOffLinErr, permErr, volOnLinErr, nsDrvErr, 
    noMacDskErr, extFSErr, fsRnErr, badMDBErr, wrPermErr, noDriveErr, dirNFErr, tmwdoErr, badMovErr, wrgVolTypErr, volGoneErr, 
    fsDSIntErr, userCanceledErr, kCoderErr, kJournalingError, kWriteJournalErr, kNoAuthErr, kCompressionErr, kPassCanceledErr, 
	fidNotFound, fidExists, notAFileErr, diffVolErr, catChangedErr, sameFileErr, 
	badFidErr, notARemountErr, fileBoundsErr, fsDataTooBigErr, volVMBusyErr, badFCBErr, errFSUnknownCall, errFSBadFSRef, errFSBadForkName, 
	errFSBadBuffer, errFSBadForkRef, errFSBadInfoBitmap, errFSMissingCatInfo, errFSNotAFolder, errFSForkNotFound, errFSNameTooLong, 
    errFSMissingName, errFSBadPosMode, errFSBadAllocFlags, errFSNoMoreItems, errFSBadItemCount, errFSBadSearchParams, errFSRefsDifferent, 
	errFSForkExists, errFSBadIteratorFlags, errFSIteratorNotFound, errFSIteratorNotSupported, errFSQuotaExceeded, afpAccessDenied };

//implied "because"
//this is about 1 VM page of data
static char *errorStrings[] = { "the directory is full", "the disk is full", "the volume does not exist", "there was a problem accessing the disk media", 
    "the name was bad", "the file is not open", "the end of the file was reached", "a negative file position offset was specified", 
    "the file won't fit in memory", "there are too many open files", "the file wasn't found", "the media is write-protected", "the file is locked", 
    "the volume is locked", "the file is still in use", "a file with the same name already exists", "the file is already open for writing", 
    "a parameter was invalid", "the file reference number is invalid", "the file position offset couldn't be obtained", 
    "the volume is no longer present", "the file is locked", "the disk is already mounted", "a non-existent drive was referenced", 
    "the disk is not mac-formatted", "the volume's file system type is not handled", "there was a problem in the middle of renaming", 
    "the master directory block is bad", "the file's permissions prevent you from writing", "the drive is not installed", 
    "the directory was not found", "there are too many open working directories", "folders cannot be moved into folders that they contain", 
    "the volume is of the wrong type", "the server volume disconnected", "there was a problem with the file system driver software", "the operation was cancelled",
    "the data could not be unserialized", "the write-ahead log file could not be initialized", "the write-ahead log couldn't be appended-to", 
	"authentication failed", "the data couldn't be decompressed", "you did not enter a passphrase", "the specified file ID was not found on the file system", 
	"the file ID already exists on the file system", "a file was in fact a folder", "the files are on different volumes", "the catalog changed unexpectedly", 
	"the file's contents were attempted to be exchanged with itself", "the file doesn't match the file ID number", "the volume was improperly remounted", 
	"the file was accessed outside of its bounds", "the file or volume is too large", "the volume is in use by the virtual memory subsystem", 
	"the file control block table was improperly accessed", "the file system call is unknown", "the file system reference is no longer valid", 
	"an invalid fork name was specified", "a buffer was uninitialized", "an invalid fork number was specified", "invalid file catalog information was requested", 
	"the catalog information buffer was uninitialized", "a folder was in fact a file", "the file's requested fork doesn't exist", 
	"the requested name is too long to be valid", "the file doesn't have a name", "an invalid positioning mode was specified for accessing the file", 
	"the file was improperly allocated", "the were no more items to find", "no items were requested to be read from the directory", 
	"the search parameters are invalid", "the file system references are different", "the file already has a fork", 
	"invalid parameters were passed when iterating over the directory", "the specified directory iterator is invalid", "the directory iterator was used improperly",
	"you have exceeded your disk quota", "your account lacks permission to access the directory" };