// Tunnel Probe: checks which way a TrollStore app can run WireGuard on this
// iPhone. Tests run sequentially on a background queue (blocking style).
//
//   1  root helper creates a utun            (path B prerequisite)
//   2  PacketTunnel extension comes up        (path A prerequisite)
//   3A WireGuard via PacketTunnel, split      4A ... full tunnel
//   3B WireGuard via root utun, split         4B ... full tunnel
#import "ProbeViewController.h"

#import <NetworkExtension/NetworkExtension.h>

#import "RootTask.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/utsname.h>

#include "libwg.h"

static NSString *const kGreeting = @"TUNNELPROBE";
static const int kListenPort = 8099;
static const int kProbePort = 51821;

@implementation ProbeViewController {
    UITextField *_serverField;
    UITextField *_tokenField;
    UITextView *_logView;
    UILabel *_summaryLabel;
    NSMutableArray<UIButton *> *_buttons;

    dispatch_queue_t _q;
    NSMutableString *_logText;
    NSMutableDictionary<NSString *, NSDictionary *> *_results;
    NSMutableArray<NSString *> *_resultOrder;
    NSDictionary *_enroll;
    NSString *_server;
    NSString *_token;
    NSString *_deviceName;
    NSString *_iosVersion;
    BOOL _busy;
}

#pragma mark - UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tunnel Probe";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _q = dispatch_queue_create("tunnelprobe.tests", DISPATCH_QUEUE_SERIAL);
    _logText = [NSMutableString string];
    _results = [NSMutableDictionary dictionary];
    _resultOrder = [NSMutableArray array];
    _buttons = [NSMutableArray array];
    _deviceName = UIDevice.currentDevice.name;
    _iosVersion = UIDevice.currentDevice.systemVersion;

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    _serverField = [self fieldWithPlaceholder:@"IP VPS, ví dụ 103.1.2.3" text:[ud stringForKey:@"server"]];
    _serverField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _tokenField = [self fieldWithPlaceholder:@"Mã token (script VPS in ra)" text:[ud stringForKey:@"token"]];

    UIButton *runAll = [self buttonWithTitle:@"▶︎  Chạy tất cả test" action:@selector(runAllTapped) prominent:YES];

    NSMutableArray *singles = [NSMutableArray array];
    NSArray *names = @[ @"1", @"2", @"3A", @"4A", @"3B", @"4B" ];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *b = [self buttonWithTitle:names[i] action:@selector(singleTapped:) prominent:NO];
        b.tag = (NSInteger)i + 1;
        [singles addObject:b];
    }
    UIStackView *row1 = [self rowWithViews:singles];
    UIStackView *row2 = [self rowWithViews:@[
        [self buttonWithTitle:@"Gửi kết quả" action:@selector(sendTapped) prominent:NO],
        [self buttonWithTitle:@"Copy log" action:@selector(copyTapped) prominent:NO],
        [self buttonWithTitle:@"Gỡ VPN test" action:@selector(removeVPNTapped) prominent:NO],
    ]];

    _summaryLabel = [[UILabel alloc] init];
    _summaryLabel.numberOfLines = 0;
    _summaryLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _summaryLabel.text = @"Nhập IP VPS + token rồi bấm “Chạy tất cả test”. Giữ app mở trong lúc test.";

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    _logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _logView.layer.cornerRadius = 8;
    [_logView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [_logView setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[ _serverField, _tokenField, runAll, row1, row2, _summaryLabel, _logView ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view
                                                                          action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];

    [self startListener];
    [self log:@"Tunnel Probe sẵn sàng — %@, iOS %@", [self machine], _iosVersion];
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder text:(NSString *)text {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.text = text;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [f.heightAnchor constraintEqualToConstant:38].active = YES;
    return f;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action prominent:(BOOL)prominent {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:prominent ? 17 : 14 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 8;
    if (prominent) {
        b.backgroundColor = UIColor.systemBlueColor;
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b.heightAnchor constraintEqualToConstant:46].active = YES;
    } else {
        b.backgroundColor = UIColor.tertiarySystemFillColor;
        [b.heightAnchor constraintEqualToConstant:36].active = YES;
    }
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_buttons addObject:b];
    return b;
}

- (UIStackView *)rowWithViews:(NSArray<UIView *> *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 6;
    return row;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    for (UIButton *b in _buttons) {
        b.enabled = !busy;
        b.alpha = busy ? 0.5 : 1;
    }
    UIApplication.sharedApplication.idleTimerDisabled = busy;
}

#pragma mark - Logging & results

- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      df = [[NSDateFormatter alloc] init];
      df.dateFormat = @"HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];
    NSString *snapshot;
    @synchronized(_logText) {
        [_logText appendString:line];
        snapshot = [_logText copy];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_logView.text = snapshot;
      if (snapshot.length) [self->_logView scrollRangeToVisible:NSMakeRange(snapshot.length - 1, 1)];
    });
}

- (void)setResult:(NSString *)key pass:(BOOL)pass detail:(NSString *)detail {
    @synchronized(_results) {
        _results[key] = @{@"pass" : @(pass), @"detail" : detail ?: @""};
        if (![_resultOrder containsObject:key]) [_resultOrder addObject:key];
    }
    [self log:@"%@ %@ — %@", pass ? @"✅" : @"❌", [self titleForKey:key], detail ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateSummary];
    });
}

- (BOOL)passed:(NSString *)key {
    @synchronized(_results) {
        return [_results[key][@"pass"] boolValue];
    }
}

- (NSString *)titleForKey:(NSString *)key {
    NSDictionary *t = @{
        @"1" : @"Test 1 · root tạo utun",
        @"2" : @"Test 2 · PacketTunnel",
        @"enroll" : @"Đăng ký với VPS",
        @"3A" : @"Test 3A · WireGuard qua PacketTunnel (nội bộ)",
        @"4A" : @"Test 4A · WireGuard qua PacketTunnel (toàn bộ traffic)",
        @"3B" : @"Test 3B · WireGuard qua root utun (nội bộ)",
        @"4B" : @"Test 4B · WireGuard qua root utun (toàn bộ traffic)",
    };
    return t[key] ?: key;
}

- (NSString *)conclusion {
    BOOL a = [self passed:@"2"] && [self passed:@"3A"] && [self passed:@"4A"];
    BOOL b = [self passed:@"1"] && [self passed:@"3B"] && [self passed:@"4B"];
    if (a && b) return @"✅ KẾT LUẬN: cả Cách A (PacketTunnel) và Cách B (root utun) đều chạy được → chọn Cách A.";
    if (a) return @"✅ KẾT LUẬN: Cách A (PacketTunnel + WireGuard) chạy được.";
    if (b) return @"✅ KẾT LUẬN: Cách B (root utun + WireGuard) chạy được.";
    NSUInteger count;
    @synchronized(_results) {
        count = _results.count;
    }
    if (count == 0) return @"Chưa chạy test.";
    if ([self passed:@"1"] || [self passed:@"2"])
        return @"⚠️ KẾT LUẬN TẠM: iPhone tạo được tunnel nhưng WireGuard tới VPS chưa thông — kiểm tra VPS/firewall rồi chạy lại.";
    return @"❌ KẾT LUẬN: không tạo được tunnel trên máy này → dùng phương án frp.";
}

- (void)updateSummary {
    NSMutableString *s = [NSMutableString string];
    @synchronized(_results) {
        for (NSString *k in _resultOrder) {
            [s appendFormat:@"%@ %@\n", [_results[k][@"pass"] boolValue] ? @"✅" : @"❌", [self titleForKey:k]];
        }
    }
    [s appendString:[self conclusion]];
    _summaryLabel.text = s;
}

#pragma mark - Actions

- (void)runOnQueue:(void (^)(void))block {
    if (_busy) return;
    [self.view endEditing:YES];
    _server = [_serverField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _token = [_tokenField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSUserDefaults.standardUserDefaults setObject:_server forKey:@"server"];
    [NSUserDefaults.standardUserDefaults setObject:_token forKey:@"token"];
    [self setBusy:YES];
    dispatch_async(_q, ^{
      @try {
          block();
      } @catch (NSException *e) {
          [self log:@"Exception: %@", e];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        [self setBusy:NO];
        [self updateSummary];
      });
    });
}

- (BOOL)hasServer {
    return _server.length > 0 && _token.length > 0;
}

- (void)runAllTapped {
    [self runOnQueue:^{
      @synchronized(self->_results) {
          [self->_results removeAllObjects];
          [self->_resultOrder removeAllObjects];
      }
      self->_enroll = nil;
      [self log:@"===== BẮT ĐẦU ====="];
      [self test1];
      [self test2];
      if (![self hasServer]) {
          [self log:@"⚠️ Chưa nhập IP VPS / token → bỏ qua test 3A, 4A, 3B, 4B"];
      } else if ([self enrollIfNeeded]) {
          if ([self passed:@"2"]) {
              [self testNEWireGuard:NO];
              [self testNEWireGuard:YES];
          } else {
              [self log:@"Bỏ qua 3A/4A vì Test 2 lỗi"];
          }
          if ([self passed:@"1"]) {
              [self testRootWireGuard:NO];
              [self testRootWireGuard:YES];
          } else {
              [self log:@"Bỏ qua 3B/4B vì Test 1 lỗi"];
          }
      }
      [self log:@"===== XONG ====="];
      [self log:@"%@", [self conclusion]];
      if ([self hasServer]) [self sendReport];
    }];
}

- (void)singleTapped:(UIButton *)b {
    NSInteger tag = b.tag;
    [self runOnQueue:^{
      switch (tag) {
      case 1: [self test1]; break;
      case 2: [self test2]; break;
      case 3: [self testNEWireGuard:NO]; break;
      case 4: [self testNEWireGuard:YES]; break;
      case 5: [self testRootWireGuard:NO]; break;
      case 6: [self testRootWireGuard:YES]; break;
      }
    }];
}

- (void)sendTapped {
    [self runOnQueue:^{
      if (![self hasServer]) {
          [self log:@"Chưa nhập IP VPS / token"];
          return;
      }
      [self sendReport];
    }];
}

- (void)copyTapped {
    NSString *text;
    @synchronized(_logText) {
        text = [_logText copy];
    }
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@\n\n%@", _summaryLabel.text, text];
    [self log:@"Đã copy log vào clipboard"];
}

- (void)removeVPNTapped {
    [self runOnQueue:^{
      NSString *err = nil;
      NSArray *managers = [self loadManagers:&err];
      int removed = 0;
      for (NETunnelProviderManager *m in managers) {
          if (![self isOurManager:m]) continue;
          [m.connection stopVPNTunnel];
          dispatch_semaphore_t s = dispatch_semaphore_create(0);
          [m removeFromPreferencesWithCompletionHandler:^(NSError *e) {
            dispatch_semaphore_signal(s);
          }];
          dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
          removed++;
      }
      [self log:@"Đã gỡ %d cấu hình VPN test%@", removed, err ? [@" — " stringByAppendingString:err] : @""];
    }];
}

#pragma mark - Helpers

- (NSString *)machine {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

- (NSString *)extensionBundleId {
    return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".PacketTunnel"];
}

- (NSString *)publicURL:(NSString *)path {
    NSString *host = [_server containsString:@":"] ? _server : [NSString stringWithFormat:@"%@:%d", _server, kProbePort];
    return [NSString stringWithFormat:@"http://%@%@", host, path];
}

- (NSData *)httpRaw:(NSString *)method
                url:(NSString *)url
               body:(NSDictionary *)body
            timeout:(NSTimeInterval)timeout
              error:(NSString **)error {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) {
        if (error) *error = [NSString stringWithFormat:@"URL không hợp lệ: %@", url];
        return nil;
    }
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = timeout;
    c.timeoutIntervalForResource = timeout;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:c];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = method;
    if (body) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    __block NSData *data = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                  data = d;
                  err = e;
                  dispatch_semaphore_signal(s);
                }] resume];
    long waited = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    if (waited != 0) {
        if (error) *error = @"timeout";
        return nil;
    }
    if (err) {
        if (error) *error = err.localizedDescription;
        return nil;
    }
    return data ?: [NSData data];
}

- (NSDictionary *)httpJSON:(NSString *)method
                       url:(NSString *)url
                      body:(NSDictionary *)body
                   timeout:(NSTimeInterval)timeout
                     error:(NSString **)error {
    NSData *d = [self httpRaw:method url:url body:body timeout:timeout error:error];
    if (!d) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"phản hồi không phải JSON";
        return nil;
    }
    return j;
}

// Tiny TCP server: the VPS connects here through the tunnel to prove it can
// reach the phone (same direction as dashboard → VNC/API).
- (void)startListener {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      int s = socket(AF_INET, SOCK_STREAM, 0);
      int one = 1;
      setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
      struct sockaddr_in a;
      memset(&a, 0, sizeof(a));
      a.sin_len = sizeof(a);
      a.sin_family = AF_INET;
      a.sin_port = htons(kListenPort);
      a.sin_addr.s_addr = htonl(INADDR_ANY);
      if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(s, 8) < 0) {
          [self log:@"⚠️ Không mở được cổng %d: %s", kListenPort, strerror(errno)];
          close(s);
          return;
      }
      NSString *greeting = [NSString stringWithFormat:@"%@ %@\n", kGreeting, [self machine]];
      while (1) {
          struct sockaddr_in peer;
          socklen_t len = sizeof(peer);
          int c = accept(s, (struct sockaddr *)&peer, &len);
          if (c < 0) {
              usleep(200 * 1000);
              continue;
          }
          setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
          char ip[INET_ADDRSTRLEN] = {0};
          inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
          write(c, greeting.UTF8String, strlen(greeting.UTF8String));
          close(c);
          [self log:@"  ← server đã kết nối vào điện thoại (từ %s)", ip];
      }
    });
}

#pragma mark - Test 1: root utun

- (NSString *)helperPath {
    return [NSBundle.mainBundle pathForResource:@"probehelper" ofType:nil];
}

- (void)test1 {
    [self log:@"--- Test 1: root helper tạo utun ---"];
    RootTask *t = [[RootTask alloc] init];
    NSString *err = nil;
    if (![t launch:[self helperPath] args:@[ @"utun-test" ] error:&err]) {
        [self setResult:@"1" pass:NO detail:[@"không chạy được root helper: " stringByAppendingString:err ?: @"?"]];
        return;
    }
    NSString *line, *result = nil;
    while ((line = [t readLineWithTimeout:15])) {
        [self log:@"  %@", line];
        if ([line hasPrefix:@"RESULT "]) result = line;
    }
    int st = [t waitExitWithTimeout:5];
    if (!result) {
        [self setResult:@"1" pass:NO detail:[NSString stringWithFormat:@"helper không trả kết quả (exit %d)", st]];
        return;
    }
    [self setResult:@"1" pass:[result hasPrefix:@"RESULT PASS"] detail:[result substringFromIndex:12]];
}

#pragma mark - Network Extension plumbing

- (BOOL)isOurManager:(NETunnelProviderManager *)m {
    NETunnelProviderProtocol *p = (NETunnelProviderProtocol *)m.protocolConfiguration;
    return [p isKindOfClass:NETunnelProviderProtocol.class] &&
           [p.providerBundleIdentifier isEqualToString:[self extensionBundleId]];
}

- (NSArray<NETunnelProviderManager *> *)loadManagers:(NSString **)error {
    __block NSArray *managers = nil;
    __block NSError *e = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray *m, NSError *er) {
      managers = m;
      e = er;
      dispatch_semaphore_signal(s);
    }];
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
        if (error) *error = @"loadAllFromPreferences: timeout";
        return nil;
    }
    if (e) {
        if (error) *error = [NSString stringWithFormat:@"loadAllFromPreferences: %@", e.localizedDescription];
        return nil;
    }
    return managers ?: @[];
}

- (NETunnelProviderManager *)prepareManagerWithConfig:(NSDictionary *)cfg
                                               server:(NSString *)server
                                                error:(NSString **)error {
    NSArray *managers = [self loadManagers:error];
    if (!managers) return nil;
    NETunnelProviderManager *m = nil;
    for (NETunnelProviderManager *x in managers) {
        if ([self isOurManager:x]) {
            m = x;
            break;
        }
    }
    if (!m) m = [[NETunnelProviderManager alloc] init];

    NETunnelProviderProtocol *p = [[NETunnelProviderProtocol alloc] init];
    p.providerBundleIdentifier = [self extensionBundleId];
    p.serverAddress = server;
    p.providerConfiguration = cfg;
    m.protocolConfiguration = p;
    m.localizedDescription = @"Tunnel Probe (test)";
    m.enabled = YES;
    m.onDemandEnabled = NO;

    [self log:@"  Lưu cấu hình VPN (lần đầu iOS hỏi \"Cho phép thêm cấu hình VPN\" → bấm Cho phép)"];
    __block NSError *e = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [m saveToPreferencesWithCompletionHandler:^(NSError *er) {
      e = er;
      dispatch_semaphore_signal(s);
    }];
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
        if (error) *error = @"saveToPreferences: timeout (chưa bấm Cho phép?)";
        return nil;
    }
    if (e) {
        if (error) *error = [NSString stringWithFormat:@"saveToPreferences: %@", e.localizedDescription];
        return nil;
    }
    [m loadFromPreferencesWithCompletionHandler:^(NSError *er) {
      e = er;
      dispatch_semaphore_signal(s);
    }];
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) || e) {
        if (error) *error = [NSString stringWithFormat:@"loadFromPreferences: %@", e.localizedDescription ?: @"timeout"];
        return nil;
    }
    return m;
}

- (NSString *)statusName:(NEVPNStatus)st {
    switch (st) {
    case NEVPNStatusInvalid: return @"Invalid";
    case NEVPNStatusDisconnected: return @"Disconnected";
    case NEVPNStatusConnecting: return @"Connecting";
    case NEVPNStatusConnected: return @"Connected";
    case NEVPNStatusReasserting: return @"Reasserting";
    case NEVPNStatusDisconnecting: return @"Disconnecting";
    }
    return [NSString stringWithFormat:@"%ld", (long)st];
}

- (BOOL)startManager:(NETunnelProviderManager *)m timeout:(NSTimeInterval)timeout error:(NSString **)error {
    NETunnelProviderSession *session = (NETunnelProviderSession *)m.connection;
    if (session.status != NEVPNStatusDisconnected && session.status != NEVPNStatusInvalid) {
        [self stopManager:m]; // never reuse a tunnel started with an older config
    }
    NSError *e = nil;
    if (![session startVPNTunnelAndReturnError:&e]) {
        if (error) *error = [NSString stringWithFormat:@"startVPNTunnel: %@", e.localizedDescription];
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL sawConnecting = NO;
    NEVPNStatus st = session.status;
    while ([deadline timeIntervalSinceNow] > 0) {
        st = session.status;
        if (st == NEVPNStatusConnected) {
            [self log:@"  VPN: Connected"];
            return YES;
        }
        if (st == NEVPNStatusConnecting) sawConnecting = YES;
        if (sawConnecting && (st == NEVPNStatusDisconnected || st == NEVPNStatusInvalid)) {
            if (error) *error = @"VPN tự ngắt ngay khi đang kết nối (extension lỗi/crash hoặc bị iOS từ chối)";
            return NO;
        }
        usleep(250 * 1000);
    }
    if (error) *error = [NSString stringWithFormat:@"timeout %.0fs, trạng thái cuối: %@", timeout, [self statusName:st]];
    return NO;
}

- (void)stopManager:(NETunnelProviderManager *)m {
    [m.connection stopVPNTunnel];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ([deadline timeIntervalSinceNow] > 0 && m.connection.status != NEVPNStatusDisconnected &&
           m.connection.status != NEVPNStatusInvalid) {
        usleep(250 * 1000);
    }
    [self log:@"  VPN: đã tắt (%@)", [self statusName:m.connection.status]];
}

- (NSDictionary *)message:(NSString *)msg to:(NETunnelProviderManager *)m {
    NETunnelProviderSession *session = (NETunnelProviderSession *)m.connection;
    __block NSData *resp = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    NSError *e = nil;
    BOOL ok = [session sendProviderMessage:[msg dataUsingEncoding:NSUTF8StringEncoding]
                               returnError:&e
                           responseHandler:^(NSData *r) {
                             resp = r;
                             dispatch_semaphore_signal(s);
                           }];
    if (!ok) {
        [self log:@"  sendProviderMessage lỗi: %@", e.localizedDescription];
        return nil;
    }
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) || !resp) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
    return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

- (void)logExtReply:(NSDictionary *)reply {
    for (NSString *line in [reply[@"log"] componentsSeparatedByString:@"\n"]) {
        if (line.length) [self log:@"  %@", line];
    }
}

#pragma mark - Test 2: PacketTunnel basic

- (void)test2 {
    [self log:@"--- Test 2: PacketTunnel (Network Extension) ---"];
    NSString *err = nil;
    NETunnelProviderManager *m = [self prepareManagerWithConfig:@{@"mode" : @"basic", @"maxSeconds" : @60}
                                                         server:@"10.99.1.1"
                                                          error:&err];
    if (!m) {
        [self setResult:@"2" pass:NO detail:err];
        return;
    }
    if (![self startManager:m timeout:20 error:&err]) {
        [self stopManager:m];
        [self setResult:@"2" pass:NO detail:err];
        return;
    }
    NSDictionary *reply = [self message:@"ping" to:m];
    [self logExtReply:reply];
    [self stopManager:m];
    [self setResult:@"2"
               pass:YES
             detail:reply ? @"VPN bật được, extension phản hồi" : @"VPN bật được (extension không phản hồi IPC)"];
}

#pragma mark - Enrollment with the VPS probe server

- (BOOL)enrollIfNeeded {
    if (_enroll) return YES;
    if (![self hasServer]) {
        [self setResult:@"enroll" pass:NO detail:@"chưa nhập IP VPS / token"];
        return NO;
    }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *priv = [ud stringForKey:@"wgPriv"];
    NSString *pub = [ud stringForKey:@"wgPub"];
    if (!priv || !pub) {
        char *kp = wgGenerateKeyPair();
        NSArray *parts = [[NSString stringWithUTF8String:kp ?: ""] componentsSeparatedByString:@" "];
        free(kp);
        if (parts.count != 2) {
            [self setResult:@"enroll" pass:NO detail:@"không tạo được khóa WireGuard"];
            return NO;
        }
        priv = parts[0];
        pub = parts[1];
        [ud setObject:priv forKey:@"wgPriv"];
        [ud setObject:pub forKey:@"wgPub"];
    }
    NSString *err = nil;
    NSDictionary *r = [self httpJSON:@"POST"
                                 url:[self publicURL:@"/enroll"]
                                body:@{@"token" : _token, @"publicKey" : pub, @"name" : _deviceName ?: [self machine]}
                             timeout:15
                               error:&err];
    if (![r[@"ok"] boolValue]) {
        NSString *why = r[@"error"] ?: err ?: @"?";
        [self setResult:@"enroll"
                   pass:NO
                 detail:[NSString stringWithFormat:@"%@ (kiểm tra IP VPS, token, cổng TCP %d đã mở chưa)", why,
                                                   kProbePort]];
        return NO;
    }
    NSMutableDictionary *d = [r mutableCopy];
    d[@"privateKey"] = priv;
    _enroll = d;
    [self setResult:@"enroll"
               pass:YES
             detail:[NSString stringWithFormat:@"IP tunnel %@, endpoint %@", r[@"address"], r[@"endpoint"]]];
    return YES;
}

- (NSString *)endpointHost {
    return [_enroll[@"endpoint"] componentsSeparatedByString:@":"].firstObject;
}

#pragma mark - Checks run once a tunnel is up

- (BOOL)runTunnelChecks:(NSString *)key full:(BOOL)full stats:(NSDictionary * (^)(void))stats {
    long long hs = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while ([deadline timeIntervalSinceNow] > 0) {
        hs = [stats()[@"handshake"] longLongValue];
        if (hs > 0) break;
        sleep(1);
    }
    if (hs <= 0) {
        [self setResult:key
                   pass:NO
                 detail:@"không handshake được với VPS (UDP 51820 bị chặn hoặc firewall VPS chưa mở)"];
        return NO;
    }
    [self log:@"  ✓ handshake WireGuard OK"];

    BOOL ok = YES;
    NSMutableArray *parts = [NSMutableArray array];
    NSString *err = nil;

    // phone -> server through the tunnel (heartbeat / API direction)
    NSString *peer = _enroll[@"peerAddress"];
    NSString *pingURL = [NSString stringWithFormat:@"http://%@:%d/ping", peer, kProbePort];
    double total = 0;
    int okCount = 0;
    NSString *remote = nil;
    for (int i = 0; i < 5; i++) {
        NSDate *t0 = [NSDate date];
        NSDictionary *r = [self httpJSON:@"GET" url:pingURL body:nil timeout:5 error:&err];
        if (r) {
            total += -[t0 timeIntervalSinceNow] * 1000;
            okCount++;
            remote = r[@"remote"];
        } else {
            [self log:@"  ping qua tunnel lỗi: %@", err];
        }
    }
    if (okCount > 0) {
        [parts addObject:[NSString stringWithFormat:@"điện thoại→server OK (%.0f ms)", total / okCount]];
        [self log:@"  ✓ điện thoại→server qua tunnel: %.0f ms, server thấy nguồn %@", total / okCount, remote];
    } else {
        [parts addObject:@"điện thoại→server LỖI"];
        ok = NO;
    }

    // server -> phone through the tunnel (dashboard -> VNC/API direction)
    NSDictionary *cb = [self httpJSON:@"POST"
                                  url:[self publicURL:@"/callback"]
                                 body:@{@"token" : _token, @"ip" : _enroll[@"address"], @"port" : @(kListenPort)}
                              timeout:15
                                error:&err];
    if ([cb[@"ok"] boolValue] && [cb[@"got"] hasPrefix:kGreeting]) {
        [parts addObject:@"server→điện thoại OK"];
    } else {
        [parts addObject:[NSString stringWithFormat:@"server→điện thoại LỖI (%@)", cb[@"error"] ?: err ?: @"?"]];
        ok = NO;
    }

    // throughput, informational
    if (okCount > 0) {
        NSString *speedURL = [NSString stringWithFormat:@"http://%@:%d/speed?mb=5", peer, kProbePort];
        NSDate *t0 = [NSDate date];
        NSData *d = [self httpRaw:@"GET" url:speedURL body:nil timeout:40 error:&err];
        double secs = -[t0 timeIntervalSinceNow];
        if (d.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"tải %.1f Mbps", d.length * 8.0 / secs / 1e6]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"đo tốc độ lỗi (%@)", err]];
        }
    }

    // full tunnel: internet must exit from the VPS. Checked by IP literal so a
    // DNS problem can't mask the routing result; DNS is reported separately.
    if (full) {
        NSString *vpsIP = _enroll[@"publicIP"];
        NSData *trace = [self httpRaw:@"GET" url:@"https://1.1.1.1/cdn-cgi/trace" body:nil timeout:10 error:&err];
        NSString *ip = nil;
        for (NSString *l in [[[NSString alloc] initWithData:trace ?: [NSData data] encoding:NSUTF8StringEncoding]
                 componentsSeparatedByString:@"\n"]) {
            if ([l hasPrefix:@"ip="]) ip = [l substringFromIndex:3];
        }
        if (ip && [ip isEqualToString:vpsIP]) {
            [parts addObject:[NSString stringWithFormat:@"IP ra internet = %@ (đúng IP VPS)", ip]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"IP ra internet = %@ (VPS là %@)", ip ?: err, vpsIP]];
            ok = NO;
        }
        NSDictionary *ipr = [self httpJSON:@"GET" url:@"https://api.ipify.org?format=json" body:nil timeout:10 error:&err];
        [parts addObject:ipr[@"ip"] ? @"DNS OK" : [NSString stringWithFormat:@"DNS lỗi (%@)", err]];
    }

    [self setResult:key pass:ok detail:[parts componentsJoinedByString:@"; "]];
    return ok;
}

#pragma mark - Test 3A / 4A: WireGuard in the PacketTunnel extension

- (void)testNEWireGuard:(BOOL)full {
    NSString *key = full ? @"4A" : @"3A";
    [self log:@"--- %@ ---", [self titleForKey:key]];
    if (![self enrollIfNeeded]) {
        [self setResult:key pass:NO detail:@"chưa đăng ký được với VPS"];
        return;
    }
    NSDictionary *cfg = @{
        @"mode" : @"wg",
        @"full" : @(full),
        @"address" : _enroll[@"address"],
        @"privateKey" : _enroll[@"privateKey"],
        @"peerPublicKey" : _enroll[@"serverPublicKey"],
        @"endpoint" : _enroll[@"endpoint"],
        @"subnet" : _enroll[@"subnet"] ?: @"10.77.0.0",
        @"subnetMask" : _enroll[@"subnetMask"] ?: @"255.255.255.0",
        @"maxSeconds" : full ? @90 : @150,
        @"handshakeTimeout" : @25,
    };
    NSString *err = nil;
    NETunnelProviderManager *m = [self prepareManagerWithConfig:cfg server:[self endpointHost] error:&err];
    if (!m) {
        [self setResult:key pass:NO detail:err];
        return;
    }
    if (![self startManager:m timeout:20 error:&err]) {
        [self stopManager:m];
        [self setResult:key pass:NO detail:err];
        return;
    }
    [self runTunnelChecks:key
                     full:full
                    stats:^NSDictionary * {
                      NSDictionary *r = [self message:@"stats" to:m];
                      [self logExtReply:r];
                      return r[@"stats"];
                    }];
    [self logExtReply:[self message:@"stats" to:m]];
    [self stopManager:m];
}

#pragma mark - Test 3B / 4B: WireGuard on a root-created utun

- (void)testRootWireGuard:(BOOL)full {
    NSString *key = full ? @"4B" : @"3B";
    [self log:@"--- %@ ---", [self titleForKey:key]];
    if (![self enrollIfNeeded]) {
        [self setResult:key pass:NO detail:@"chưa đăng ký được với VPS"];
        return;
    }
    NSString *subnet = _enroll[@"subnet"] ?: @"10.77.0.0";
    NSDictionary *cfg = @{
        @"privateKey" : _enroll[@"privateKey"],
        @"peerPublicKey" : _enroll[@"serverPublicKey"],
        @"endpoint" : _enroll[@"endpoint"],
        @"address" : _enroll[@"address"],
        @"peerAddress" : _enroll[@"peerAddress"],
        @"allowedIPs" : full ? @[ @"0.0.0.0/0" ] : @[ [subnet stringByAppendingString:@"/24"] ],
        @"keepalive" : @25,
    };
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil]
                                           encoding:NSUTF8StringEncoding];

    RootTask *t = [[RootTask alloc] init];
    NSString *err = nil;
    if (![t launch:[self helperPath] args:@[ @"wg", full ? @"full" : @"split", full ? @"90" : @"150", json ]
             error:&err]) {
        [self setResult:key pass:NO detail:[@"không chạy được root helper: " stringByAppendingString:err ?: @"?"]];
        return;
    }

    BOOL ready = NO;
    NSString *failLine = nil;
    NSString *line;
    while ((line = [t readLineWithTimeout:15])) {
        if (![line hasPrefix:@"STATS "]) [self log:@"  %@", line];
        if ([line hasPrefix:@"READY "]) {
            ready = YES;
            break;
        }
        if ([line hasPrefix:@"RESULT FAIL"]) failLine = line;
    }
    if (!ready) {
        [t closeStdin];
        [t waitExitWithTimeout:10];
        [self setResult:key pass:NO detail:failLine ? [failLine substringFromIndex:12] : @"helper không báo READY"];
        return;
    }

    [self runTunnelChecks:key
                     full:full
                    stats:^NSDictionary * {
                      NSString *l;
                      while ((l = [t readLineWithTimeout:3])) {
                          if ([l hasPrefix:@"STATS "]) {
                              NSData *d = [[l substringFromIndex:6] dataUsingEncoding:NSUTF8StringEncoding];
                              return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                          }
                          [self log:@"  %@", l];
                      }
                      return nil;
                    }];

    [t closeStdin];
    while ((line = [t readLineWithTimeout:10])) {
        if (![line hasPrefix:@"STATS "]) [self log:@"  %@", line];
    }
    [t waitExitWithTimeout:5];
}

#pragma mark - Report

- (void)sendReport {
    NSString *logCopy;
    NSDictionary *results;
    NSArray *order;
    @synchronized(_logText) {
        logCopy = [_logText copy];
    }
    @synchronized(_results) {
        results = [_results copy];
        order = [_resultOrder copy];
    }
    NSDictionary *report = @{
        @"device" : @{@"model" : [self machine], @"ios" : _iosVersion ?: @"", @"name" : _deviceName ?: @""},
        @"order" : order,
        @"results" : results,
        @"conclusion" : [self conclusion],
        @"log" : logCopy,
    };
    NSString *err = nil;
    NSDictionary *r = [self httpJSON:@"POST"
                                 url:[self publicURL:@"/report"]
                                body:@{@"token" : _token, @"report" : report}
                             timeout:15
                               error:&err];
    if ([r[@"ok"] boolValue]) {
        [self log:@"📤 Đã gửi kết quả lên VPS: %@", r[@"file"]];
    } else {
        [self log:@"📤 Gửi kết quả lỗi: %@ — dùng nút Copy log rồi gửi tay", r[@"error"] ?: err];
    }
}

@end
