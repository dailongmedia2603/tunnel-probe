#include "netutil.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <unistd.h>

// ---- sys/kern_control.h, net/if_utun.h ----
#define NU_SYSPROTO_CONTROL 2
#define NU_AF_SYS_CONTROL 2
#define NU_UTUN_OPT_IFNAME 2
#define NU_UTUN_CONTROL_NAME "com.apple.net.utun_control"
#define NU_MAX_KCTL_NAME 96

struct nu_ctl_info {
    uint32_t ctl_id;
    char ctl_name[NU_MAX_KCTL_NAME];
};
#define NU_CTLIOCGINFO _IOWR('N', 3, struct nu_ctl_info)

struct nu_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

// ---- net/route.h ----
struct nu_rt_metrics {
    uint32_t rmx_locks, rmx_mtu, rmx_hopcount;
    int32_t rmx_expire;
    uint32_t rmx_recvpipe, rmx_sendpipe, rmx_ssthresh, rmx_rtt, rmx_rttvar, rmx_pksent, rmx_state;
    uint32_t rmx_filler[3];
};
struct nu_rt_msghdr {
    unsigned short rtm_msglen;
    unsigned char rtm_version;
    unsigned char rtm_type;
    unsigned short rtm_index;
    int rtm_flags;
    int rtm_addrs;
    pid_t rtm_pid;
    int rtm_seq;
    int rtm_errno;
    int rtm_use;
    uint32_t rtm_inits;
    struct nu_rt_metrics rtm_rmx;
};
#define NU_RTM_VERSION 5
#define NU_RTM_ADD 0x1
#define NU_RTM_DELETE 0x2
#define NU_RTM_GET 0x4
#define NU_RTF_UP 0x1
#define NU_RTF_GATEWAY 0x2
#define NU_RTF_HOST 0x4
#define NU_RTF_STATIC 0x800
#define NU_RTA_DST 0x1
#define NU_RTA_GATEWAY 0x2
#define NU_RTA_NETMASK 0x4
#define NU_RTA_IFP 0x10
#define NU_RTAX_MAX 8
#define NU_ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

static void seterr(char *err, size_t errlen, const char *fmt, ...) {
    if (!err || !errlen) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

int nu_utun_name(int fd, char ifname[IFNAMSIZ]) {
    socklen_t len = IFNAMSIZ;
    memset(ifname, 0, IFNAMSIZ);
    return getsockopt(fd, NU_SYSPROTO_CONTROL, NU_UTUN_OPT_IFNAME, ifname, &len) == 0 ? 0 : -1;
}

int nu_utun_create(char ifname[IFNAMSIZ], char *err, size_t errlen) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, NU_SYSPROTO_CONTROL);
    if (fd < 0) {
        seterr(err, errlen, "socket(PF_SYSTEM): %s", strerror(errno));
        return -1;
    }
    struct nu_ctl_info info;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, NU_UTUN_CONTROL_NAME, sizeof(info.ctl_name) - 1);
    if (ioctl(fd, NU_CTLIOCGINFO, &info) < 0) {
        seterr(err, errlen, "ioctl(CTLIOCGINFO): %s", strerror(errno));
        close(fd);
        return -1;
    }
    struct nu_sockaddr_ctl sc;
    memset(&sc, 0, sizeof(sc));
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = NU_AF_SYS_CONTROL;
    sc.sc_id = info.ctl_id;
    sc.sc_unit = 0; // let the kernel pick utunN
    if (connect(fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        seterr(err, errlen, "connect(utun_control): %s", strerror(errno));
        close(fd);
        return -1;
    }
    if (nu_utun_name(fd, ifname) < 0) {
        seterr(err, errlen, "getsockopt(UTUN_OPT_IFNAME): %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

int nu_find_utun_fd(void) {
    struct nu_ctl_info info;
    memset(&info, 0, sizeof(info));
    for (int fd = 0; fd <= 1024; fd++) {
        struct nu_sockaddr_ctl addr;
        socklen_t len = sizeof(addr);
        memset(&addr, 0, sizeof(addr));
        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != AF_SYSTEM) continue;
        if (info.ctl_id == 0) {
            strncpy(info.ctl_name, NU_UTUN_CONTROL_NAME, sizeof(info.ctl_name) - 1);
            if (ioctl(fd, NU_CTLIOCGINFO, &info) != 0) continue;
        }
        if (addr.sc_id == info.ctl_id) return fd;
    }
    return -1;
}

static void fill_sin(struct sockaddr_in *sin, in_addr_t a) {
    memset(sin, 0, sizeof(*sin));
    sin->sin_len = sizeof(*sin);
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = a;
}

int nu_set_p2p_addr(const char *ifname, const char *local, const char *peer, char *err, size_t errlen) {
    struct in_addr l, p;
    if (inet_pton(AF_INET, local, &l) != 1 || inet_pton(AF_INET, peer, &p) != 1) {
        seterr(err, errlen, "bad address %s / %s", local, peer);
        return -1;
    }
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) {
        seterr(err, errlen, "socket: %s", strerror(errno));
        return -1;
    }
    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof(ifra));
    strncpy(ifra.ifra_name, ifname, IFNAMSIZ - 1);
    fill_sin((struct sockaddr_in *)&ifra.ifra_addr, l.s_addr);
    fill_sin((struct sockaddr_in *)&ifra.ifra_broadaddr, p.s_addr);
    fill_sin((struct sockaddr_in *)&ifra.ifra_mask, htonl(0xffffffff));
    if (ioctl(s, SIOCAIFADDR, &ifra) < 0) {
        seterr(err, errlen, "ioctl(SIOCAIFADDR): %s", strerror(errno));
        close(s);
        return -1;
    }
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0 && !(ifr.ifr_flags & IFF_UP)) {
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(s, SIOCSIFFLAGS, &ifr) < 0) {
            seterr(err, errlen, "ioctl(SIOCSIFFLAGS): %s", strerror(errno));
            close(s);
            return -1;
        }
    }
    close(s);
    return 0;
}

// ---- routing socket ----

static int g_seq = 1000;

static size_t put_sa(char *cp, const struct sockaddr *sa) {
    size_t n = NU_ROUNDUP(sa->sa_len);
    memcpy(cp, sa, sa->sa_len);
    return n;
}

// Sends one routing message and, for RTM_GET, reads the reply into reply.
static int rt_send(int type, int flags, int addrs, const struct sockaddr *dst, const struct sockaddr *gw,
                   const struct sockaddr *mask, char *reply, size_t replylen, char *err, size_t errlen) {
    int s = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (s < 0) {
        seterr(err, errlen, "socket(PF_ROUTE): %s", strerror(errno));
        return -1;
    }
    char buf[512];
    memset(buf, 0, sizeof(buf));
    struct nu_rt_msghdr *rtm = (struct nu_rt_msghdr *)buf;
    char *cp = buf + sizeof(*rtm);
    if (addrs & NU_RTA_DST) cp += put_sa(cp, dst);
    if (addrs & NU_RTA_GATEWAY) cp += put_sa(cp, gw);
    if (addrs & NU_RTA_NETMASK) cp += put_sa(cp, mask);
    if (addrs & NU_RTA_IFP) {
        struct sockaddr_dl sdl;
        memset(&sdl, 0, sizeof(sdl));
        sdl.sdl_len = sizeof(sdl);
        sdl.sdl_family = AF_LINK;
        cp += put_sa(cp, (struct sockaddr *)&sdl);
    }
    rtm->rtm_msglen = (unsigned short)(cp - buf);
    rtm->rtm_version = NU_RTM_VERSION;
    rtm->rtm_type = (unsigned char)type;
    rtm->rtm_flags = flags;
    rtm->rtm_addrs = addrs;
    rtm->rtm_seq = ++g_seq;
    rtm->rtm_pid = getpid();
    int seq = rtm->rtm_seq;

    if (write(s, buf, rtm->rtm_msglen) < 0) {
        int e = errno;
        close(s);
        if (type == NU_RTM_ADD && e == EEXIST) return 0; // left over from an earlier run
        seterr(err, errlen, "route write: %s", strerror(e));
        return -1;
    }
    if (type == NU_RTM_GET && reply) {
        struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        for (int i = 0; i < 50; i++) {
            ssize_t n = read(s, reply, replylen);
            if (n <= 0) break;
            struct nu_rt_msghdr *r = (struct nu_rt_msghdr *)reply;
            if (r->rtm_seq == seq && r->rtm_pid == getpid()) {
                close(s);
                if (r->rtm_errno) {
                    seterr(err, errlen, "RTM_GET: %s", strerror(r->rtm_errno));
                    return -1;
                }
                return 0;
            }
        }
        seterr(err, errlen, "RTM_GET: no reply");
        close(s);
        return -1;
    }
    close(s);
    return 0;
}

static int prefix_mask(int prefix, struct sockaddr_in *mask) {
    uint32_t m = prefix <= 0 ? 0 : (prefix >= 32 ? 0xffffffffu : ~((1u << (32 - prefix)) - 1));
    fill_sin(mask, htonl(m));
    return 0;
}

int nu_route_add(const char *net, int prefix, const char *gateway, char *err, size_t errlen) {
    struct in_addr n, g;
    if (inet_pton(AF_INET, net, &n) != 1 || inet_pton(AF_INET, gateway, &g) != 1) {
        seterr(err, errlen, "bad route %s via %s", net, gateway);
        return -1;
    }
    struct sockaddr_in dst, gw, mask;
    fill_sin(&dst, n.s_addr);
    fill_sin(&gw, g.s_addr);
    prefix_mask(prefix, &mask);
    return rt_send(NU_RTM_ADD, NU_RTF_UP | NU_RTF_GATEWAY | NU_RTF_STATIC, NU_RTA_DST | NU_RTA_GATEWAY | NU_RTA_NETMASK,
                   (struct sockaddr *)&dst, (struct sockaddr *)&gw, (struct sockaddr *)&mask, NULL, 0, err, errlen);
}

int nu_route_delete(const char *net, int prefix, char *err, size_t errlen) {
    struct in_addr n;
    if (inet_pton(AF_INET, net, &n) != 1) {
        seterr(err, errlen, "bad route %s", net);
        return -1;
    }
    struct sockaddr_in dst, mask;
    fill_sin(&dst, n.s_addr);
    if (prefix >= 32) {
        return rt_send(NU_RTM_DELETE, NU_RTF_HOST, NU_RTA_DST, (struct sockaddr *)&dst, NULL, NULL, NULL, 0, err,
                       errlen);
    }
    prefix_mask(prefix, &mask);
    return rt_send(NU_RTM_DELETE, 0, NU_RTA_DST | NU_RTA_NETMASK, (struct sockaddr *)&dst, NULL,
                   (struct sockaddr *)&mask, NULL, 0, err, errlen);
}

int nu_pin_host_route(const char *dst, char *desc, size_t desclen, char *err, size_t errlen) {
    struct in_addr d;
    if (inet_pton(AF_INET, dst, &d) != 1) {
        seterr(err, errlen, "bad address %s", dst);
        return -1;
    }
    struct sockaddr_in sdst;
    fill_sin(&sdst, d.s_addr);

    char reply[1024];
    memset(reply, 0, sizeof(reply));
    if (rt_send(NU_RTM_GET, NU_RTF_UP | NU_RTF_HOST, NU_RTA_DST | NU_RTA_IFP, (struct sockaddr *)&sdst, NULL, NULL,
                reply, sizeof(reply), err, errlen) < 0)
        return -1;

    struct nu_rt_msghdr *r = (struct nu_rt_msghdr *)reply;
    struct sockaddr *sas[NU_RTAX_MAX] = {0};
    char *cp = reply + sizeof(*r);
    char *end = reply + r->rtm_msglen;
    for (int i = 0; i < NU_RTAX_MAX && cp < end; i++) {
        if (!(r->rtm_addrs & (1 << i))) continue;
        struct sockaddr *sa = (struct sockaddr *)cp;
        sas[i] = sa;
        cp += NU_ROUNDUP(sa->sa_len);
    }
    struct sockaddr *gw = sas[1]; // RTAX_GATEWAY
    if (!gw) {
        seterr(err, errlen, "no gateway in route reply (flags 0x%x)", r->rtm_flags);
        return -1;
    }

    char gwdesc[64] = "?";
    if (gw->sa_family == AF_INET) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)gw)->sin_addr, gwdesc, sizeof(gwdesc));
    } else if (gw->sa_family == AF_LINK) {
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)gw;
        char ifn[IFNAMSIZ] = {0};
        if_indextoname(sdl->sdl_index, ifn);
        snprintf(gwdesc, sizeof(gwdesc), "link#%d(%s)", sdl->sdl_index, ifn);
    }
    char ifname[IFNAMSIZ] = {0};
    if_indextoname(r->rtm_index, ifname);
    if (desc) snprintf(desc, desclen, "%s via %s dev %s", dst, gwdesc, ifname);

    int flags = NU_RTF_UP | NU_RTF_HOST | NU_RTF_STATIC | (r->rtm_flags & NU_RTF_GATEWAY);
    return rt_send(NU_RTM_ADD, flags, NU_RTA_DST | NU_RTA_GATEWAY, (struct sockaddr *)&sdst, gw, NULL, NULL, 0, err,
                   errlen);
}
