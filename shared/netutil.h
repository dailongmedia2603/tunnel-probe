// Low-level iOS networking helpers: utun, interface address, routing socket.
// The iOS SDK lacks sys/kern_control.h and net/route.h, so the needed
// kernel structs are declared here (layouts copied from xnu).
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <net/if.h>

#ifdef __cplusplus
extern "C" {
#endif

// Creates a new utun interface (requires root). Returns fd or -1; writes the
// interface name (e.g. "utun3") into ifname.
int nu_utun_create(char ifname[IFNAMSIZ], char *err, size_t errlen);

// Returns the interface name of a utun fd, or 0 on success / -1 on failure.
int nu_utun_name(int fd, char ifname[IFNAMSIZ]);

// Scans open fds for the utun control socket owned by this process
// (used inside NEPacketTunnelProvider, like WireGuardKit). Returns fd or -1.
int nu_find_utun_fd(void);

// Assigns a point-to-point IPv4 address (local -> peer, /32) and brings the
// interface up.
int nu_set_p2p_addr(const char *ifname, const char *local, const char *peer, char *err, size_t errlen);

// Looks up the current route to dst and installs a static host route for dst
// via the same gateway/interface, so it keeps bypassing the tunnel once
// default routes point into it.
int nu_pin_host_route(const char *dst, char *desc, size_t desclen, char *err, size_t errlen);

// Adds / deletes an IPv4 route "net/prefix via gateway".
int nu_route_add(const char *net, int prefix, const char *gateway, char *err, size_t errlen);
int nu_route_delete(const char *net, int prefix, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
