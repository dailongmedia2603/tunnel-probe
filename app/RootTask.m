#import "RootTask.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
typedef int (*persona_np_fn)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*persona_id_fn)(posix_spawnattr_t *, uid_t);

@implementation RootTask {
    int _in;
    int _out;
    NSMutableData *_buf;
    BOOL _exited;
    int _status;
}

- (instancetype)init {
    if ((self = [super init])) {
        _in = -1;
        _out = -1;
        _buf = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    [self closeStdin];
    if (_out >= 0) close(_out);
}

- (BOOL)launch:(NSString *)path args:(NSArray<NSString *> *)args error:(NSString **)error {
    if (path.length == 0 || ![NSFileManager.defaultManager isExecutableFileAtPath:path]) {
        if (error) *error = [NSString stringWithFormat:@"không thấy file helper: %@", path];
        return NO;
    }
    persona_np_fn set_persona = (persona_np_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    persona_id_fn set_uid = (persona_id_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    persona_id_fn set_gid = (persona_id_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!set_persona || !set_uid || !set_gid) {
        if (error) *error = @"thiếu posix_spawnattr_set_persona_* (dlsym)";
        return NO;
    }

    int inPipe[2], outPipe[2];
    if (pipe(inPipe) != 0 || pipe(outPipe) != 0) {
        if (error) *error = [NSString stringWithFormat:@"pipe: %s", strerror(errno)];
        return NO;
    }
    fcntl(inPipe[1], F_SETFD, FD_CLOEXEC);
    fcntl(outPipe[0], F_SETFD, FD_CLOEXEC);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    set_persona(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    set_uid(&attr, 0);
    set_gid(&attr, 0);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, inPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, inPipe[1]);
    posix_spawn_file_actions_addclose(&fa, outPipe[0]);

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup(all[i].UTF8String);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, &fa, &attr, argv, environ);

    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(inPipe[0]);
    close(outPipe[1]);

    if (rc != 0) {
        close(inPipe[1]);
        close(outPipe[0]);
        if (error) *error = [NSString stringWithFormat:@"posix_spawn: %s (%d)", strerror(rc), rc];
        return NO;
    }
    _pid = pid;
    _in = inPipe[1];
    _out = outPipe[0];
    return YES;
}

- (NSString *)takeLine {
    const char *bytes = _buf.bytes;
    for (NSUInteger i = 0; i < _buf.length; i++) {
        if (bytes[i] == '\n') {
            NSString *line = [[NSString alloc] initWithBytes:bytes length:i encoding:NSUTF8StringEncoding] ?: @"";
            [_buf replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
            return line;
        }
    }
    return nil;
}

- (NSString *)readLineWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        NSString *line = [self takeLine];
        if (line) return line;
        if (_eof || _out < 0) {
            if (_buf.length) {
                line = [[NSString alloc] initWithData:_buf encoding:NSUTF8StringEncoding];
                _buf.length = 0;
                return line;
            }
            return nil;
        }
        int ms = (int)([deadline timeIntervalSinceNow] * 1000);
        if (ms <= 0) return nil;
        struct pollfd p = {.fd = _out, .events = POLLIN};
        int r = poll(&p, 1, ms);
        if (r <= 0) return nil;
        char tmp[4096];
        ssize_t n = read(_out, tmp, sizeof(tmp));
        if (n <= 0) {
            _eof = YES;
        } else {
            [_buf appendBytes:tmp length:n];
        }
    }
}

- (void)closeStdin {
    if (_in >= 0) {
        close(_in);
        _in = -1;
    }
}

- (int)waitExitWithTimeout:(NSTimeInterval)timeout {
    if (_exited) return _status;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        int st = 0;
        pid_t r = waitpid(_pid, &st, WNOHANG);
        if (r == _pid) {
            _exited = YES;
            _status = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
            return _status;
        }
        if (r < 0) return -1;
        usleep(100 * 1000);
    }
    return -1;
}

@end
