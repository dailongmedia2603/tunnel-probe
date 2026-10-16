#import <Foundation/Foundation.h>

// Spawns a binary from the app bundle as root via TrollStore persona
// spawning, with stdin/stdout pipes. All methods are blocking; call them
// from a background queue.
@interface RootTask : NSObject
@property(nonatomic, readonly) pid_t pid;
@property(nonatomic, readonly) BOOL eof;

- (BOOL)launch:(NSString *)path args:(NSArray<NSString *> *)args error:(NSString **)error;
// Next stdout line, or nil on timeout / EOF.
- (NSString *)readLineWithTimeout:(NSTimeInterval)timeout;
// Closing stdin tells the helper to tear down and exit.
- (void)closeStdin;
// Exit status, or -1 if still running after timeout.
- (int)waitExitWithTimeout:(NSTimeInterval)timeout;
@end
