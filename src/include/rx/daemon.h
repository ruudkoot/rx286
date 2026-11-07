/* ============================================================================
 * rx286 - src/include/rx/daemon.h
 * rx_daemon (roadmap os-server.md P12): a program made a daemon, as BSD's
 * daemon(3) makes one; POSIX has no such call.
 * ============================================================================ */

#ifndef RX_DAEMON_H
#define RX_DAEMON_H

/* rx_daemon - the caller forked, and the parent gone (exit 0); the child,
 * which returns 0, leads a session of its own, without a terminal, in /,
 * its descriptors 0 to 2 /dev/null: -1 if the fork failed */
int rx_daemon(void);

#endif
