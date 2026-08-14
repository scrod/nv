#import "NotationController.h"

/* Internal startup policy layered above WALRecoveryController.  The category
 * owns user choices and the preserve/install/rollback transaction; WAL parsing
 * and locking remain in WALController. */
@interface NotationController (StartupRecovery)

- (NotationController*)newControllerByRecoveringStartupJournal:(OSStatus*)error;
- (NSModalResponse)_legacyDatabaseRecoveryResponse;
- (NSModalResponse)_failedWALRecoveryResponse;
- (void)_showPartialWALRecoveryWarning;
- (void)_quitAfterDecliningLegacyDatabaseRecovery;

@end
