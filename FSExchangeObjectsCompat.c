/*
 *  FSExchangeObjectsCompat.c
 *  based on MoreFilesX
 */

#include "FSExchangeObjectsCompat.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/mount.h>

__private_extern__ u_int32_t volumeCapabilities(const char *path)
{
    struct attrlist alist;
    bzero(&alist, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.volattr = ATTR_VOL_INFO|ATTR_VOL_CAPABILITIES; // XXX: VOL_INFO must always be set

    struct {
        u_int32_t v_size;
       /* Fixed storage */
       vol_capabilities_attr_t v_caps;
    } vinfo;
    bzero(&vinfo, sizeof(vinfo));
    if (0 == getattrlist(path, &alist, &vinfo, sizeof(vinfo), 0)
        && 0 != (alist.volattr & ATTR_VOL_CAPABILITIES)) {
        return (vinfo.v_caps.capabilities[VOL_CAPABILITIES_FORMAT]);
    }
    
    return (0);
}

static OSErr GenerateUniqueHFSUniStr(long *startSeed, const FSRef *dir1, const FSRef *dir2,	HFSUniStr255 *uniqueName) {
	OSErr result;
	long i;
	FSRefParam pb;
	FSRef newRef;
	unsigned char hexStr[17] = "0123456789ABCDEF";
	
	/* set up the parameter block */
	pb.name = uniqueName->unicode;
	pb.nameLength = 8;  /* always 8 characters */
	pb.textEncodingHint = kTextEncodingUnknown;
	pb.newRef = &newRef;
	
	/* loop until we get fnfErr with a filename in both directories */
	result = noErr;
	while ( fnfErr != result )
	{
		/* convert startSeed to 8 character Unicode string */
		uniqueName->length = 8;
		for ( i = 0; i < 8; ++i )
		{
			uniqueName->unicode[i] = hexStr[((*startSeed >> ((7-i)*4)) & 0xf)];
		}
		
		/* try in dir1 */
		pb.ref = dir1;
		result = PBMakeFSRefUnicodeSync(&pb);
		if ( fnfErr == result )
		{
			/* try in dir2 */
			pb.ref = dir2;
			result = PBMakeFSRefUnicodeSync(&pb);
			if ( fnfErr != result )
			{
				/* exit if anything other than noErr or fnfErr */
				require_noerr(result, Dir2PBMakeFSRefUnicodeSyncFailed);
			}
		}
		else
		{
			/* exit if anything other than noErr or fnfErr */
			require_noerr(result, Dir1PBMakeFSRefUnicodeSyncFailed);
		}
		
		/* increment seed for next pass through loop, */
		/* or for next call to GenerateUniqueHFSUniStr */
		++(*startSeed);
	}
	
	/* we have a unique file name which doesn't exist in dir1 or dir2 */
	result = noErr;
	
Dir2PBMakeFSRefUnicodeSyncFailed:
Dir1PBMakeFSRefUnicodeSyncFailed:
		
		return ( result );
}

OSErr FSExchangeObjectsEmulate(const FSRef *sourceRef, const FSRef *destRef, FSRef *newSourceRef, FSRef *newDestRef) {
	
	enum {
		/* get all settable info except for mod dates, plus the volume refNum and parent directory ID */
		kGetCatInformationMask = (kFSCatInfoSettableInfo |
								  kFSCatInfoVolume |
								  kFSCatInfoParentDirID) &
		~(kFSCatInfoContentMod | kFSCatInfoAttrMod),
		/* set everything possible except for mod dates */
		kSetCatinformationMask = kFSCatInfoSettableInfo &
		~(kFSCatInfoContentMod | kFSCatInfoAttrMod)
	};
	
	OSErr          result;
	FSCatalogInfo      sourceCatalogInfo;  /* source file's catalog information */
	FSCatalogInfo      destCatalogInfo;  /* destination file's catalog information */
	HFSUniStr255      sourceName;      /* source file's Unicode name */
	HFSUniStr255      destName;      /* destination file's Unicode name */
	FSRef          sourceCurrentRef;  /* FSRef to current location of source file throughout this function */
	FSRef          destCurrentRef;    /* FSRef to current location of destination file throughout this function */
	FSRef          sourceParentRef;  /* FSRef to parent directory of source file */
	FSRef          destParentRef;    /* FSRef to parent directory of destination file */
	HFSUniStr255      sourceUniqueName;  /* unique name given to source file while exchanging it with destination */
	HFSUniStr255      destUniqueName;    /* unique name given to destination file while exchanging it with source */
	long          theSeed;      /* the seed for generating unique names */
	Boolean          sameParentDirs;    /* true if source and destinatin parent directory is the same */
	
	/* check parameters */
	require_action((NULL != newSourceRef) && (NULL != newDestRef), BadParameter, result = paramErr);
	
	/* output refs and current refs = input refs to start with */
	memcpy(newSourceRef, sourceRef, sizeof(FSRef));
	memcpy(&sourceCurrentRef, sourceRef, sizeof(FSRef));
	
	memcpy(newDestRef, destRef, sizeof(FSRef));
	memcpy(&destCurrentRef, destRef, sizeof(FSRef));
		
	/* Note: The compatibility case won't work for files with *Btree control blocks. */
	/* Right now the only *Btree files are created by the system. */
	
	/* get all catalog information and Unicode names for each file */
	result = FSGetCatalogInfo(&sourceCurrentRef, kGetCatInformationMask, &sourceCatalogInfo, &sourceName, NULL, &sourceParentRef);
	require_noerr(result, SourceFSGetCatalogInfoFailed);
	
	result = FSGetCatalogInfo(&destCurrentRef, kGetCatInformationMask, &destCatalogInfo, &destName, NULL, &destParentRef);
	require_noerr(result, DestFSGetCatalogInfoFailed);
	
	/* make sure source and destination are on same volume */
	require_action(sourceCatalogInfo.volume == destCatalogInfo.volume, NotSameVolume, result = diffVolErr);
	
	/* make sure both files are *really* files */
	require_action((0 == (sourceCatalogInfo.nodeFlags & kFSNodeIsDirectoryMask)) &&
				   (0 == (destCatalogInfo.nodeFlags & kFSNodeIsDirectoryMask)), NotAFile, result = notAFileErr);
	
	/* generate 2 names that are unique in both directories */
	theSeed = 0x4a696d4c;  /* a fine unlikely filename */
	
	result = GenerateUniqueHFSUniStr(&theSeed, &sourceParentRef, &destParentRef, &sourceUniqueName);
	require_noerr(result, GenerateUniqueHFSUniStr1Failed);
	
	result = GenerateUniqueHFSUniStr(&theSeed, &sourceParentRef, &destParentRef, &destUniqueName);
	require_noerr(result, GenerateUniqueHFSUniStr2Failed);
	
	/* rename sourceCurrentRef to sourceUniqueName */
	result = FSRenameUnicode(&sourceCurrentRef, sourceUniqueName.length, sourceUniqueName.unicode, kTextEncodingUnknown, newSourceRef);
	require_noerr(result, FSRenameUnicode1Failed);
	memcpy(&sourceCurrentRef, newSourceRef, sizeof(FSRef));
	
	/* rename destCurrentRef to destUniqueName */
	result = FSRenameUnicode(&destCurrentRef, destUniqueName.length, destUniqueName.unicode, kTextEncodingUnknown, newDestRef);
	require_noerr(result, FSRenameUnicode2Failed);
	memcpy(&destCurrentRef, newDestRef, sizeof(FSRef));
	
	/* are the source and destination parent directories the same? */
	sameParentDirs = ( sourceCatalogInfo.parentDirID == destCatalogInfo.parentDirID );
	if ( !sameParentDirs )
	{
		/* move source file to dest parent directory */
		result = FSMoveObject(&sourceCurrentRef, &destParentRef, newSourceRef);
		require_noerr(result, FSMoveObject1Failed);
		memcpy(&sourceCurrentRef, newSourceRef, sizeof(FSRef));
		
		/* move dest file to source parent directory */
		result = FSMoveObject(&destCurrentRef, &sourceParentRef, newDestRef);
		require_noerr(result, FSMoveObject2Failed);
		memcpy(&destCurrentRef, newDestRef, sizeof(FSRef));
	}
	
	/* At this point, the files are in their new locations (if they were moved). */
	/* The source file is named sourceUniqueName and is in the directory referred to */
	/* by destParentRef. The destination file is named destUniqueName and is in the */
	/* directory referred to by sourceParentRef. */
	
	/* give source file the dest file's catalog information except for mod dates */
	result = FSSetCatalogInfo(&sourceCurrentRef, kSetCatinformationMask, &destCatalogInfo);
	require_noerr(result, FSSetCatalogInfo1Failed);
	
	/* give dest file the source file's catalog information except for mod dates */
	result = FSSetCatalogInfo(&destCurrentRef, kSetCatinformationMask, &sourceCatalogInfo);
	require_noerr(result, FSSetCatalogInfo2Failed);
	
	/* rename source file with dest file's name */
	result = FSRenameUnicode(&sourceCurrentRef, destName.length, destName.unicode, destCatalogInfo.textEncodingHint, newSourceRef);
	require_noerr(result, FSRenameUnicode3Failed);
	memcpy(&sourceCurrentRef, newSourceRef, sizeof(FSRef));
	
	/* rename dest file with source file's name */
	result = FSRenameUnicode(&destCurrentRef, sourceName.length, sourceName.unicode, sourceCatalogInfo.textEncodingHint, newDestRef);
	require_noerr(result, FSRenameUnicode4Failed);
	
	/* we're done with no errors, so swap newSourceRef and newDestRef */
	memcpy(newSourceRef, newDestRef, sizeof(FSRef));
	memcpy(newDestRef, &sourceCurrentRef, sizeof(FSRef));
	
	return ( result );
	
	/**********************/
	
	/* If there are any failures while emulating FSExchangeObjects, attempt to reverse any steps */
	/* already taken. In any case, newSourceRef and newDestRef will refer to the files in whatever */
	/* state and location they ended up in so that both files can be found by the calling code. */
	
FSRenameUnicode4Failed:
		
		/* attempt to rename source file to sourceUniqueName */
		if ( noErr == FSRenameUnicode(&sourceCurrentRef, sourceUniqueName.length, sourceUniqueName.unicode, kTextEncodingUnknown, newSourceRef) )
		{
			memcpy(&sourceCurrentRef, newSourceRef, sizeof(FSRef));
		}
	
FSRenameUnicode3Failed:
		
		/* attempt to restore dest file's catalog information */
		verify_noerr(FSSetCatalogInfo(&destCurrentRef, kFSCatInfoSettableInfo, &destCatalogInfo));
	
FSSetCatalogInfo2Failed:
		
		/* attempt to restore source file's catalog information */
		verify_noerr(FSSetCatalogInfo(&sourceCurrentRef, kFSCatInfoSettableInfo, &sourceCatalogInfo));
	
FSSetCatalogInfo1Failed:
		
		if ( !sameParentDirs )
		{
			/* attempt to move dest file back to dest directory */
			if ( noErr == FSMoveObject(&destCurrentRef, &destParentRef, newDestRef) )
			{
				memcpy(&destCurrentRef, newDestRef, sizeof(FSRef));
			}
		}
	
FSMoveObject2Failed:
		
		if ( !sameParentDirs )
		{
			/* attempt to move source file back to source directory */
			if ( noErr == FSMoveObject(&sourceCurrentRef, &sourceParentRef, newSourceRef) )
			{
				memcpy(&sourceCurrentRef, newSourceRef, sizeof(FSRef));
			}
		}
	
FSMoveObject1Failed:
		
		/* attempt to rename dest file to original name */
		verify_noerr(FSRenameUnicode(&destCurrentRef, destName.length, destName.unicode, destCatalogInfo.textEncodingHint, newDestRef));
	
FSRenameUnicode2Failed:
		
		/* attempt to rename source file to original name */
		verify_noerr(FSRenameUnicode(&sourceCurrentRef, sourceName.length, sourceName.unicode, sourceCatalogInfo.textEncodingHint, newSourceRef));
	
FSRenameUnicode1Failed:
GenerateUniqueHFSUniStr2Failed:
GenerateUniqueHFSUniStr1Failed:
NotAFile:
NotSameVolume:
DestFSGetCatalogInfoFailed:
SourceFSGetCatalogInfoFailed:
BadParameter:
		
		return ( result );
}

