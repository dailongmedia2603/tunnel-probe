// PacketTunnel extension for the probe.
//   mode "basic": brings up a dummy tunnel (10.99.1.0/24) — proves NE works.
//   mode "wg":    runs wireguard-go on the NE utun, split (10.77.0.0/24) or
//                 full tunnel. Self-cancels if no handshake within
//                 handshakeTimeout or after maxSeconds.
#import <NetworkExtension/NetworkExtension.h>

#include "libwg.h"
#include "netutil.h"

@interface PacketTunnelProvider : NEPacketTunnelProvider
@end

@implementation PacketTunnelProvider {
    int _handle;
    NSMutableString *_log;
    NSDictionary *_cfg;
    BOOL _stopping;
}

- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TunnelProbe] %@", s);
    @synchronized(self) {
        if (!_log) _log = [NSMutableString string];
        [_log appendFormat:@"[ext] %@\n", s];
    }
}

- (NSString *)drainLog {
    char *wl = wgDrainLog();
    NSString *wgLog = wl ? [NSString stringWithUTF8String:wl] : @"";
    free(wl);
    NSMutableString *out = [NSMutableString string];
    @synchronized(self) {
        if (_log) [out appendString:_log];
        _log = [NSMutableString string];
    }
    for (NSString *line in [wgLog componentsSeparatedByString:@"\n"]) {
        if (line.length == 0 || [line containsString:@"keepalive"]) continue;
        [out appendFormat:@"[wg] %@\n", line];
    }
    return out;
}

- (void)startTunnelWithOptions:(NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *))completionHandler {
    _handle = -1;
    _cfg = ((NETunnelProviderProtocol *)self.protocolConfiguration).providerConfiguration ?: @{};
    NSString *mode = _cfg[@"mode"] ?: @"basic";
    [self log:@"startTunnel mode=%@", mode];

    if ([mode isEqualToString:@"wg"]) {
        [self startWireGuard:completionHandler];
    } else {
        [self startBasic:completionHandler];
    }
}

- (void)startBasic:(void (^)(NSError *))completionHandler {
    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"10.99.1.1"];
    NEIPv4Settings *v4 = [[NEIPv4Settings alloc] initWithAddresses:@[ @"10.99.1.2" ]
                                                       subnetMasks:@[ @"255.255.255.0" ]];
    v4.includedRoutes = @[ [[NEIPv4Route alloc] initWithDestinationAddress:@"10.99.1.0"
                                                                subnetMask:@"255.255.255.0"] ];
    settings.IPv4Settings = v4;
    settings.MTU = @1280;
    [self setTunnelNetworkSettings:settings
                 completionHandler:^(NSError *error) {
                   if (error) {
                       [self log:@"setTunnelNetworkSettings error: %@", error];
                       completionHandler(error);
                       return;
                   }
                   int fd = nu_find_utun_fd();
                   char ifname[IFNAMSIZ] = {0};
                   if (fd >= 0) nu_utun_name(fd, ifname);
                   [self log:@"basic tunnel up, utun fd=%d name=%s", fd, ifname];
                   [self scheduleMaxLifetime];
                   completionHandler(nil);
                 }];
}

- (void)startWireGuard:(void (^)(NSError *))completionHandler {
    BOOL full = [_cfg[@"full"] boolValue];
    NSString *address = _cfg[@"address"];
    NSString *endpoint = _cfg[@"endpoint"];
    NSString *endpointHost = [endpoint componentsSeparatedByString:@":"].firstObject;
    NSString *subnet = _cfg[@"subnet"] ?: @"10.77.0.0";
    NSString *subnetMask = _cfg[@"subnetMask"] ?: @"255.255.255.0";

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:endpointHost];
    NEIPv4Settings *v4 = [[NEIPv4Settings alloc] initWithAddresses:@[ address ]
                                                       subnetMasks:@[ @"255.255.255.255" ]];
    if (full) {
        v4.includedRoutes = @[ [NEIPv4Route defaultRoute] ];
        // Route IPv6 into the tunnel too (server drops it) so nothing leaks around it.
        NEIPv6Settings *v6 = [[NEIPv6Settings alloc] initWithAddresses:@[ @"fd77::2" ] networkPrefixLengths:@[ @128 ]];
        v6.includedRoutes = @[ [NEIPv6Route defaultRoute] ];
        settings.IPv6Settings = v6;
        NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:@[ @"1.1.1.1", @"8.8.8.8" ]];
        dns.matchDomains = @[ @"" ];
        settings.DNSSettings = dns;
    } else {
        v4.includedRoutes = @[ [[NEIPv4Route alloc] initWithDestinationAddress:subnet subnetMask:subnetMask] ];
    }
    settings.IPv4Settings = v4;
    settings.MTU = @1280;

    NSDictionary *wg = @{
        @"privateKey" : _cfg[@"privateKey"] ?: @"",
        @"peerPublicKey" : _cfg[@"peerPublicKey"] ?: @"",
        @"endpoint" : endpoint ?: @"",
        @"allowedIPs" : full ? @[ @"0.0.0.0/0", @"::/0" ] : @[ [NSString stringWithFormat:@"%@/24", subnet] ],
        @"keepalive" : @25,
    };
    NSData *wgJSON = [NSJSONSerialization dataWithJSONObject:wg options:0 error:nil];
    NSString *wgStr = [[NSString alloc] initWithData:wgJSON encoding:NSUTF8StringEncoding];

    [self setTunnelNetworkSettings:settings
                 completionHandler:^(NSError *error) {
                   if (error) {
                       [self log:@"setTunnelNetworkSettings error: %@", error];
                       completionHandler(error);
                       return;
                   }
                   int fd = nu_find_utun_fd();
                   char ifname[IFNAMSIZ] = {0};
                   if (fd >= 0) nu_utun_name(fd, ifname);
                   [self log:@"settings applied (%@), utun fd=%d name=%s", full ? @"full" : @"split", fd, ifname];
                   if (fd < 0) {
                       completionHandler([NSError errorWithDomain:@"TunnelProbe"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey : @"utun fd not found"}]);
                       return;
                   }
                   self->_handle = wgTurnOn((char *)wgStr.UTF8String, fd, 0);
                   if (self->_handle < 0) {
                       [self log:@"wgTurnOn failed: %d", self->_handle];
                       completionHandler([NSError
                           errorWithDomain:@"TunnelProbe"
                                      code:2
                                  userInfo:@{
                                      NSLocalizedDescriptionKey :
                                          [NSString stringWithFormat:@"wgTurnOn=%d", self->_handle]
                                  }]);
                       return;
                   }
                   [self scheduleMaxLifetime];
                   [self scheduleHandshakeWatchdog];
                   completionHandler(nil);
                 }];
}

// Safety nets: the tunnel never outlives the test, so a stuck test can't
// leave the phone without internet.
- (void)scheduleMaxLifetime {
    int secs = [_cfg[@"maxSeconds"] intValue] ?: 120;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)secs * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [weakSelf log:@"maxSeconds=%d reached, cancelling tunnel", secs];
      [weakSelf cancelTunnelWithError:nil];
    });
}

- (void)scheduleHandshakeWatchdog {
    int secs = [_cfg[@"handshakeTimeout"] intValue] ?: 25;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)secs * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      typeof(self) s = weakSelf;
      if (!s || s->_handle < 0) return;
      char *st = wgGetStats(s->_handle);
      NSDictionary *d = st ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:st length:strlen(st)]
                                                             options:0
                                                               error:nil]
                           : nil;
      free(st);
      if ([d[@"handshake"] longLongValue] <= 0) {
          [s log:@"no handshake after %ds, cancelling tunnel", secs];
          [s cancelTunnelWithError:[NSError errorWithDomain:@"TunnelProbe"
                                                       code:3
                                                   userInfo:@{NSLocalizedDescriptionKey : @"no handshake"}]];
      }
    });
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    [self log:@"stopTunnel reason=%ld", (long)reason];
    if (_handle >= 0) {
        wgTurnOff(_handle);
        _handle = -1;
    }
    completionHandler();
}

// App <-> extension IPC: "ping" | "stats". Reply is JSON.
- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler {
    NSString *msg = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    reply[@"pong"] = msg ?: @"";
    if (_handle >= 0) {
        char *st = wgGetStats(_handle);
        if (st) {
            id stats = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:st length:strlen(st)]
                                                       options:0
                                                         error:nil];
            if (stats) reply[@"stats"] = stats;
            free(st);
        }
    }
    reply[@"log"] = [self drainLog];
    if (completionHandler) completionHandler([NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]);
}

@end
