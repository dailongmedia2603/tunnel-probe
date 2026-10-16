// probehelper: runs as root (spawned by the app through TrollStore persona
// spawning). Prints line-oriented status on stdout; exits when stdin closes
// (the app quit or ended the test) or the deadline passes, always tearing
// down its routes first.
//
//   probehelper utun-test
//   probehelper wg <split|full> <seconds> <config-json>
//
// config-json: {"privateKey","peerPublicKey","endpoint":"ip:port",
//               "address":"10.77.0.x","peerAddress":"10.77.0.1"}

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "libwg.h"
#include "netutil.h"

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

static void flush_wg_log(void) {
    char *s = wgDrainLog();
    if (!s) return;
    char *save = NULL;
    for (char *line = strtok_r(s, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (strstr(line, "Receiving keepalive") || strstr(line, "Sending keepalive")) continue;
        out("LOG %s", line);
    }
    free(s);
}

// Minimal extraction of "key":"value" from a flat JSON object.
static int json_str(const char *json, const char *key, char *dst, size_t dstlen) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return -1;
    p = strchr(p + strlen(pat), ':');
    if (!p) return -1;
    p = strchr(p, '"');
    if (!p) return -1;
    p++;
    const char *e = strchr(p, '"');
    if (!e || (size_t)(e - p) >= dstlen) return -1;
    memcpy(dst, p, e - p);
    dst[e - p] = 0;
    return 0;
}

static int cmd_utun_test(void) {
    out("INFO uid=%d euid=%d gid=%d", getuid(), geteuid(), getgid());
    char ifname[IFNAMSIZ];
    char err[256] = {0};
    int fd = nu_utun_create(ifname, err, sizeof(err));
    if (fd < 0) {
        out("RESULT FAIL tao utun that bai: %s", err);
        return 1;
    }
    out("INFO created %s (fd %d)", ifname, fd);
    if (nu_set_p2p_addr(ifname, "10.99.0.2", "10.99.0.1", err, sizeof(err)) < 0) {
        out("RESULT FAIL tao duoc %s nhung gan IP that bai: %s", ifname, err);
        close(fd);
        return 1;
    }
    out("INFO %s: 10.99.0.2 -> 10.99.0.1 up", ifname);
    close(fd);
    out("RESULT PASS root tao duoc %s va gan IP", ifname);
    return 0;
}

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static int cmd_wg(const char *mode, int seconds, const char *json) {
    int full = strcmp(mode, "full") == 0;
    char address[64], peer[64], endpoint[128], endpointHost[128];
    if (json_str(json, "address", address, sizeof(address)) || json_str(json, "peerAddress", peer, sizeof(peer)) ||
        json_str(json, "endpoint", endpoint, sizeof(endpoint))) {
        out("RESULT FAIL config thieu address/peerAddress/endpoint");
        return 1;
    }
    snprintf(endpointHost, sizeof(endpointHost), "%s", endpoint);
    char *colon = strrchr(endpointHost, ':');
    if (colon) *colon = 0;

    out("INFO uid=%d mode=%s deadline=%ds", getuid(), mode, seconds);
    char ifname[IFNAMSIZ];
    char err[256] = {0};
    int fd = nu_utun_create(ifname, err, sizeof(err));
    if (fd < 0) {
        out("RESULT FAIL tao utun: %s", err);
        return 1;
    }
    if (nu_set_p2p_addr(ifname, address, peer, err, sizeof(err)) < 0) {
        out("RESULT FAIL gan IP: %s", err);
        close(fd);
        return 1;
    }
    out("INFO %s: %s -> %s", ifname, address, peer);

    int pinned = 0, def1 = 0, def2 = 0;
    if (full) {
        char desc[160] = {0};
        if (nu_pin_host_route(endpointHost, desc, sizeof(desc), err, sizeof(err)) < 0) {
            out("RESULT FAIL khong ghim duoc route toi endpoint: %s", err);
            close(fd);
            return 1;
        }
        pinned = 1;
        out("INFO pinned %s", desc);
    }

    int h = wgTurnOn((char *)json, fd, 1280);
    flush_wg_log();
    if (h < 0) {
        out("RESULT FAIL wgTurnOn=%d", h);
        if (pinned) nu_route_delete(endpointHost, 32, err, sizeof(err));
        close(fd);
        return 1;
    }

    if (full) {
        def1 = nu_route_add("0.0.0.0", 1, peer, err, sizeof(err)) == 0;
        if (!def1) out("INFO route 0/1 loi: %s", err);
        def2 = nu_route_add("128.0.0.0", 1, peer, err, sizeof(err)) == 0;
        if (!def2) out("INFO route 128/1 loi: %s", err);
        out("INFO full-tunnel routes: %s", (def1 && def2) ? "ok" : "loi");
    }
    out("READY %s %s", ifname, address);

    time_t deadline = time(NULL) + seconds;
    time_t lastStats = 0;
    while (!g_stop && time(NULL) < deadline) {
        struct pollfd p = {.fd = STDIN_FILENO, .events = POLLIN};
        int r = poll(&p, 1, 500);
        if (r > 0) {
            char buf[64];
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0) break; // app closed the pipe
        }
        if (time(NULL) - lastStats >= 2) {
            lastStats = time(NULL);
            char *st = wgGetStats(h);
            out("STATS %s", st ? st : "{}");
            free(st);
            flush_wg_log();
        }
    }

    out("INFO tearing down");
    if (def1) nu_route_delete("0.0.0.0", 1, err, sizeof(err));
    if (def2) nu_route_delete("128.0.0.0", 1, err, sizeof(err));
    wgTurnOff(h);
    close(fd);
    if (pinned) nu_route_delete(endpointHost, 32, err, sizeof(err));
    flush_wg_log();
    out("DONE");
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc >= 2 && strcmp(argv[1], "utun-test") == 0) return cmd_utun_test();
    if (argc >= 5 && strcmp(argv[1], "wg") == 0) return cmd_wg(argv[2], atoi(argv[3]), argv[4]);

    out("RESULT FAIL usage: probehelper utun-test | wg <split|full> <seconds> <json>");
    return 2;
}
