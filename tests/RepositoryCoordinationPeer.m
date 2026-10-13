#import <Foundation/Foundation.h>

/* Performs external coordinated filesystem stimuli from an independent process. */
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) return 2;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSURL *source = [NSURL fileURLWithPath:@(argv[2])];
        NSError *error = nil;
        __block NSError *effectError = nil;
        __block BOOL entered = NO;
        if (!strcmp(argv[1], "write") && argc == 4) {
            NSData *body = [@(argv[3]) dataUsingEncoding:NSUTF8StringEncoding];
            [coordinator coordinateWritingItemAtURL:source options:0 error:&error byAccessor:^(NSURL *actual) {
                entered = YES;
                [body writeToURL:actual options:NSDataWritingAtomic error:&effectError];
            }];
        } else if (!strcmp(argv[1], "move") && argc == 4) {
            NSURL *destination = [NSURL fileURLWithPath:@(argv[3])];
            [coordinator coordinateWritingItemAtURL:source options:NSFileCoordinatorWritingForMoving
                writingItemAtURL:destination options:0 error:&error byAccessor:^(NSURL *actual, NSURL *target) {
                    entered = YES;
                    [coordinator itemAtURL:actual willMoveToURL:target];
                    if ([[NSFileManager defaultManager] moveItemAtURL:actual toURL:target error:&effectError]) {
                        [coordinator itemAtURL:actual didMoveToURL:target];
                    }
                }];
        } else return 2;
        if (!entered || error || effectError) return 3;
        puts("{\"entered\":true,\"completed\":true}");
        return 0;
    }
}
