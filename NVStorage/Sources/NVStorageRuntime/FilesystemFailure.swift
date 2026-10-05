import Foundation

/// Preserves native filesystem failure categories at Foundation/POSIX adapter boundaries.
func filesystemFailure(_ error: Error) -> StorageError {
    if let storage = error as? StorageError { return storage }
    let native = error as NSError
    if native.domain == NSPOSIXErrorDomain { return .ownership(Int32(clamping: native.code)) }
    if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return .ownership(Int32(clamping: underlying.code))
    }
    if native.domain == NSCocoaErrorDomain {
        switch native.code {
        case CocoaError.fileWriteOutOfSpace.rawValue: return .ownership(ENOSPC)
        case CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue: return .ownership(EACCES)
        case CocoaError.fileNoSuchFile.rawValue: return .ownership(ENOENT)
        default: return .ownership(EIO)
        }
    }
    return classify(error)
}
