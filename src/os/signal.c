/* ============================================================================
 * rx286 - src/os/signal.c
 * The processes' signals (roadmap os-server.md P10, D7 A): each process's
 * dispositions, mask and pending set, and the delivery of a signal to a
 * handler.
 *
 * A signal sent (sig_send) is ignored, or its default action ends the
 * process at once, or it waits, pending, for the process's server thread
 * (proc.c), which sig_step drives: at every turn, after a call and when
 * its notification fires, the thread looks for a signal that is pending
 * and not blocked. For a handler it marks the process's thread to stop
 * (THREAD_SUSPEND), which takes effect on the thread's way back to ring 3,
 * after any call it is in has had its reply; the stop signals the server
 * thread's notification, which is bound to it (THREAD_BIND), so that it
 * wakes even while it waits for a call. Then sig_step reads the stopped
 * thread's frame (THREAD_FRAME), writes the signal's frame (SF_*, posix.inc)
 * below its SP through the server's copy of its data segment, points it at
 * libc's trampoline, and starts it again (THREAD_START). The trampoline
 * calls the handler and returns through PX_SIGRETURN, which puts the mask
 * back, and the frame's POPA and IRET.
 *
 * A call that waits (a pipe, the terminal, waitpid, sigsuspend) wakes for a
 * signal and ends with EINTR, or ERESTART if the handler has SA_RESTART,
 * which libc takes as the call to make again (sig_interrupt).
 *
 * A stop (P11: SIGSTOP, and SIGTSTP, SIGTTIN and SIGTTOU's default action)
 * marks the thread to stop as for a handler, and then holds it stopped; a
 * wait it was in ends with ERESTART, so that the call is made again once it
 * continues. SIGCONT continues it, a handler first if it has one. init
 * takes no default action.
 * ============================================================================ */

#include <string.h>
#include "sys/types.h"
#include "rx/rx286.h"
#include "server.h"
#include "fs.h"
#include "posix.h"

/* What a signal does in a process: its handler (PX_SIG_DFL, PX_SIG_IGN, or
 * an address), SA_* and the signals blocked while the handler runs */
struct action {
    rx_u16 handler, flags;
    rx_u32 mask;
};

/* A process's signals: pending, blocked; sigsuspend's mask for after the
 * handler; its alarm's and its sleep's ends, in ticks (0: none); whether
 * its thread is to stop, whether the process is stopped, and its thread
 * held so; libc's trampoline; 287 or not */
struct sigs {
    rx_u32 pending, blocked, restore, alarm_at, sleep_at;
    rx_u8 restoring, suspending, stopped, held, fpu;
    rx_u16 tramp;
    struct action act[SIG_MAX + 1];
};

static struct sigs sigs[PROCS];

/* bit - a signal's bit in a set (a shift by one at a time: gcc-ia16 has no
 * helper for a 32-bit shift by a variable) */
static rx_u32 bit(int sig)
{
    rx_u32 b = 1;

    while (--sig > 0)
        b <<= 1;
    return b;
}

#define UNBLOCKABLE (bit(SIGKILL) | bit(SIGSTOP))
#define STOPS (bit(SIGSTOP) | bit(SIGTSTP) | bit(SIGTTIN) | bit(SIGTTOU))

/* ignores - does the signal's default action ignore it? (SIGCONT's
 * continues the process as the signal is sent) */
static int ignores(int sig)
{
    return sig == SIGCHLD || sig == SIGCONT;
}

/* stops - does the signal's default action stop the process? */
static int stops(int sig)
{
    return sig == SIGSTOP || sig == SIGTSTP || sig == SIGTTIN || sig == SIGTTOU;
}

/* thread_call - KCALL_THREAD on process i's thread: its status, r back */
static int thread_call(int i, int op, rx_u16 bx, rx_u16 si, rx_u16 di, struct rx_kregs *r)
{
    r->ax = (rx_u16)((KCALL_THREAD << 8) | op);
    r->bx = bx;
    r->cx = PROC_PRIORITY;
    r->dx = P_SLOT(i, PK_THREAD);
    r->si = si;
    r->di = di;
    r->bp = 0;
    return rx_kcall(r);
}

/* sig_start - process i's signals as it starts (server.h) */
void sig_start(int i, int from, int how)
{
    struct sigs *s = &sigs[i];
    int k;

    if (how == SIG_FROM_FORK) {
        *s = sigs[from];
        s->pending = 0;
        s->alarm_at = 0;                /* not the parent's alarm (XSH fork) */
    } else if (how == SIG_FROM_EXEC) {
        for (k = 1; k <= SIG_MAX; k++)  /* the handlers are gone with the image */
            if (s->act[k].handler != PX_SIG_IGN)
                memset(&s->act[k], 0, sizeof s->act[k]);
    } else {
        memset(s, 0, sizeof *s);
        if (from >= 0) {                /* posix_spawn: ignored stays ignored */
            s->blocked = sigs[from].blocked;
            for (k = 1; k <= SIG_MAX; k++)
                if (sigs[from].act[k].handler == PX_SIG_IGN)
                    s->act[k].handler = PX_SIG_IGN;
        }
    }
    s->suspending = 0;
    s->restoring = 0;
    s->stopped = s->held = 0;
    s->sleep_at = 0;
    if (how != SIG_FROM_FORK)
        s->tramp = 0;
}

/* stop - process i stopped by a signal: its thread to stop and be held so,
 * its waits ended, its parent told (lock held) */
static void stop(int i, int sig)
{
    struct sigs *s = &sigs[i];
    struct rx_kregs r;

    if (s->stopped)
        return;
    s->stopped = 1;
    proc_stopped(i, sig);
    if (!s->suspending && !s->held
            && thread_call(i, THREAD_SUSPEND, 0, PROC_NOTIFY(i), 0, &r) == 0)
        s->suspending = 1;
    proc_wake(i);
}

/* cont - process i continued: its thread started again by its server
 * thread, a handler first if one is due; its parent told (lock held) */
static void cont(int i)
{
    struct sigs *s = &sigs[i];

    if (!s->stopped)
        return;
    s->stopped = 0;
    proc_continued(i);
    if (s->held) {
        s->held = 0;
        s->suspending = 1;              /* (its thread stopped: sig_step takes it on) */
    }
    proc_wake(i);
}

/* sig_stopped - is process i stopped? (server.h) */
int sig_stopped(int i)
{
    return sigs[i].stopped;
}

/* sig_takes - would process i take a signal now, neither ignored nor
 * blocked? (server.h) */
int sig_takes(int i, int sig)
{
    return !(sigs[i].blocked & bit(sig)) && sigs[i].act[sig].handler != PX_SIG_IGN;
}

/* sig_caught - has process i a handler for a signal? (server.h) */
int sig_caught(int i, int sig)
{
    return sigs[i].act[sig].handler > PX_SIG_IGN;
}

/* sig_nocldstop - does process i want no SIGCHLD for its children's stops?
 * (server.h) */
int sig_nocldstop(int i)
{
    return (sigs[i].act[SIGCHLD].flags & SA_NOCLDSTOP) != 0;
}

/* sig_287 - whether process i's executable uses the 287 (server.h) */
void sig_287(int i, int uses)
{
    sigs[i].fpu = (rx_u8)(uses != 0);
}

/* timers_arm - the control notification's timer (OS_TIMER), for the
 * earliest end of an alarm or a sleep (lock held) */
static void timers_arm(void)
{
    rx_u32 now = rx_ticks(), next = 0, at;
    struct rx_kregs r;
    int i;

    for (i = 0; i < PROCS; i++) {
        if (!proc_alive(i))
            continue;
        at = sigs[i].alarm_at;
        if (at && (!next || at < next))
            next = at;
        at = sigs[i].sleep_at;
        if (at && (!next || at < next))
            next = at;
    }
    if (!next)
        return;                         /* (a timer left armed rings for nothing) */
    r.ax = KCALL_TIMER << 8;
    r.cx = next <= now ? 1 : next - now > 0x7FFF ? 0x7FFF : (rx_u16)(next - now);
    r.dx = OS_TIMER;
    r.bp = 0;
    rx_kcall(&r);
}

/* sig_timers - the alarms that have come, SIGALRM; the sleeps that have,
 * their server threads woken; the timer armed again (server.h; the control
 * thread, lock held) */
void sig_timers(void)
{
    rx_u32 now = rx_ticks();
    int i;

    for (i = 0; i < PROCS; i++) {
        if (!proc_alive(i))
            continue;
        if (sigs[i].alarm_at && now >= sigs[i].alarm_at) {
            sigs[i].alarm_at = 0;
            sig_send(i, SIGALRM);
        }
        if (sigs[i].sleep_at && now >= sigs[i].sleep_at)
            proc_wake(i);
    }
    timers_arm();
}

/* sig_send - a signal for process t (server.h; lock held) */
void sig_send(int t, int sig)
{
    struct sigs *s = &sigs[t];
    struct action *a;
    rx_u32 b;

    if (!proc_alive(t) || sig <= 0 || sig > SIG_MAX)
        return;
    a = &s->act[sig];
    b = bit(sig);
    if (sig == SIGKILL) {
        proc_end(t, sig);
        return;
    }
    if (proc_is_init(t) && a->handler <= PX_SIG_IGN)
        return;                         /* init takes no default action */
    if (sig == SIGCONT) {               /* (XSH 2.4.1: as it is sent) */
        s->pending &= ~STOPS;
        cont(t);
    } else if (stops(sig)) {
        s->pending &= ~bit(SIGCONT);
    }
    if (sig == SIGSTOP) {
        stop(t, sig);
        return;
    }
    if (a->handler == PX_SIG_IGN || (a->handler == PX_SIG_DFL && ignores(sig)))
        return;
    if (a->handler == PX_SIG_DFL && !(s->blocked & b)) {
        if (stops(sig))                 /* the default action, at once */
            stop(t, sig);
        else
            proc_end(t, sig);
        return;
    }
    s->pending |= b;
    proc_wake(t);                       /* its server thread, waiting or receiving */
}

/* sig_fault - process i's fault as a signal (server.h; lock held) */
int sig_fault(int i, int sig)
{
    struct sigs *s = &sigs[i];
    struct rx_kregs r;

    if (s->act[sig].handler <= PX_SIG_IGN || (s->blocked & bit(sig)))
        return 0;                       /* blocked or ignored: the default action */
    s->pending |= bit(sig);
    if (s->suspending)                  /* marked, it faulted first: stopped now */
        thread_call(i, THREAD_SUSPEND, 0, PROC_NOTIFY(i), 0, &r);
    return 1;
}

/* sig_ready - process i's lowest signal pending and not blocked, or 0
 * (server.h) */
int sig_ready(int i)
{
    rx_u32 ready = sigs[i].pending & ~sigs[i].blocked;
    int sig;

    for (sig = 1; ready; sig++, ready >>= 1)
        if (ready & 1)
            return sig;
    return 0;
}

/* sig_interrupt - why a call that waited ends for a signal: 0 if none is
 * ready, ERESTART if its handler restarts calls and this one may be, else
 * EINTR (server.h) */
int sig_interrupt(int i, int restartable)
{
    int sig = sig_ready(i);

    if (sigs[i].stopped)
        return ERESTART;                /* made again once it continues */
    if (sig == 0)
        return 0;
    return restartable && (sigs[i].act[sig].flags & SA_RESTART) ? ERESTART : EINTR;
}

/* deliver - process i's stopped thread to its next handler, a frame below
 * its SP: 1 if it runs on, 0 if it ended (lock held) */
static int deliver(int i)
{
    struct sigs *s = &sigs[i];
    struct action *a;
    struct rx_kregs r;
    rx_u16 kf[TFR_SIZE / 2], f[SF_SIZE / 2], sp, k;
    rx_u16 RX_FAR *to;
    rx_u32 b;
    int sig;

    s->suspending = 0;
    for (;;) {
        if ((sig = sig_ready(i)) == 0) {
            thread_call(i, THREAD_START, 0, 0, 0, &r);
            return 1;
        }
        a = &s->act[sig];
        b = bit(sig);
        if (a->handler > PX_SIG_IGN)
            break;
        s->pending &= ~b;
        if (a->handler == PX_SIG_DFL && stops(sig)) {
            s->stopped = s->held = 1;   /* unblocked, a stop: its thread stopped already */
            proc_stopped(i, sig);
            return 0;
        }
        if (a->handler == PX_SIG_DFL && !ignores(sig)) {
            proc_end(i, sig);           /* unblocked, its default action */
            return 0;
        }
    }
    if (thread_call(i, THREAD_FRAME, FRAME_READ, OS_DATA, (rx_u16)(unsigned)kf, &r)) {
        proc_end(i, SIGKILL);
        return 0;
    }
    sp = kf[TFR_SP / 2];
    if ((kf[TFR_SS / 2] != PROC_SS && kf[TFR_SS / 2] != PROC_DS) || sp < SF_SIZE + 2
            || (rx_u32)sp - 1 > proc_data_limit(i)) {
        proc_end(i, SIGSEGV);           /* no room for the frame: X4 */
        return 0;
    }
    f[SF_SIG / 2] = (rx_u16)sig;
    f[SF_HANDLER / 2] = a->handler;
    f[SF_MASK / 2] = (rx_u16)(s->restoring ? s->restore : s->blocked);
    f[SF_MASK / 2 + 1] = (rx_u16)((s->restoring ? s->restore : s->blocked) >> 16);
    f[SF_287 / 2] = s->fpu;
    for (k = 0; k < (TFR_AX - TFR_ES) / 2 + 1; k++)    /* ES, DS, PUSHA's eight */
        f[SF_ES / 2 + k] = kf[TFR_ES / 2 + k];
    f[SF_IP / 2] = kf[TFR_IP / 2];
    f[SF_CS / 2] = kf[TFR_CS / 2];
    f[SF_FLAGS / 2] = kf[TFR_FLAGS / 2];
    sp = (rx_u16)(sp - SF_SIZE);
    to = (rx_u16 RX_FAR *)RX_MK_FP(P_SLOT(i, PK_DATA), sp);
    for (k = 0; k < SF_SIZE / 2; k++)
        to[k] = f[k];
    kf[TFR_IP / 2] = s->tramp;
    kf[TFR_SP / 2] = sp;
    kf[TFR_DS / 2] = PROC_DS;
    kf[TFR_ES / 2] = PROC_DS;
    kf[TFR_FLAGS / 2] &= (rx_u16)~(FLAG_DF | FLAG_TF);      /* C's: DF clear */
    if (thread_call(i, THREAD_FRAME, FRAME_WRITE, OS_DATA, (rx_u16)(unsigned)kf, &r)) {
        proc_end(i, SIGSEGV);
        return 0;
    }
    s->pending &= ~b;
    s->restoring = 0;
    s->blocked |= a->mask | (a->flags & SA_NODEFER ? 0 : b);
    s->blocked &= ~UNBLOCKABLE;
    if (a->flags & SA_RESETHAND)
        memset(a, 0, sizeof *a);
    thread_call(i, THREAD_START, 0, 0, 0, &r);
    return 1;
}

/* sig_step - process i's signals at a turn of its server thread (server.h;
 * lock held) */
void sig_step(int i)
{
    struct sigs *s = &sigs[i];
    struct rx_kregs r;
    int sig;

    while (proc_alive(i)) {
        if (s->held)
            return;                     /* stopped: until SIGCONT */
        if (s->suspending) {
            thread_call(i, THREAD_INFO, 0, 0, 0, &r);
            if ((r.bx & 0xFF) != STATE_STOPPED)
                return;                 /* not yet stopped */
            if (s->stopped) {
                s->suspending = 0;      /* a stop's: held so */
                s->held = 1;
                return;
            }
            if (!deliver(i))
                return;                 /* it ended, or stopped */
            continue;                   /* another handler may be due: nested */
        }
        if (s->stopped) {               /* stopped, its thread not yet */
            thread_call(i, THREAD_INFO, 0, 0, 0, &r);
            if ((r.bx & 0xFF) == STATE_STOPPED)
                s->held = 1;
            else if (thread_call(i, THREAD_SUSPEND, 0, PROC_NOTIFY(i), 0, &r) == 0)
                s->suspending = 1;
            return;
        }
        if ((sig = sig_ready(i)) == 0)
            return;
        if (s->act[sig].handler <= PX_SIG_IGN) {
            s->pending &= ~bit(sig);
            if (s->act[sig].handler == PX_SIG_DFL && stops(sig))
                stop(i, sig);
            else if (s->act[sig].handler == PX_SIG_DFL && !ignores(sig))
                proc_end(i, sig);
            continue;
        }
        if (thread_call(i, THREAD_SUSPEND, 0, PROC_NOTIFY(i), 0, &r) == 0)
            s->suspending = 1;
        return;
    }
}

/* action_in - an action from a process's data segment: 0, or EFAULT past
 * the segment */
static int action_in(int i, rx_u16 at, struct action *a)
{
    const rx_u8 RX_FAR *p = (const rx_u8 RX_FAR *)RX_MK_FP(P_SLOT(i, PK_DATA), at);

    if ((rx_u32)at + SAC_SIZE - 1 > proc_data_limit(i))
        return EFAULT;
    a->handler = (rx_u16)(p[SAC_HANDLER] | (p[SAC_HANDLER + 1] << 8));
    a->mask = (rx_u32)(p[SAC_MASK] | (p[SAC_MASK + 1] << 8))
              | (rx_u32)(p[SAC_MASK + 2] | (p[SAC_MASK + 3] << 8)) << 16;
    a->flags = (rx_u16)(p[SAC_FLAGS] | (p[SAC_FLAGS + 1] << 8));
    return 0;
}

/* action_out - an action into a process's data segment: 0, or EFAULT */
static int action_out(int i, rx_u16 at, const struct action *a)
{
    rx_u16 RX_FAR *p = (rx_u16 RX_FAR *)RX_MK_FP(P_SLOT(i, PK_DATA), at);

    if ((rx_u32)at + SAC_SIZE - 1 > proc_data_limit(i))
        return EFAULT;
    p[SAC_HANDLER / 2] = a->handler;
    p[SAC_MASK / 2] = (rx_u16)a->mask;
    p[SAC_MASK / 2 + 1] = (rx_u16)(a->mask >> 16);
    p[SAC_FLAGS / 2] = a->flags;
    return 0;
}

/* sig_call - PX_SIGACTION to PX_NANOSLEEP (server.h; lock held, given up
 * while sigsuspend and nanosleep wait) */
int sig_call(int i, struct rx_kregs *r, int *error)
{
    struct sigs *s = &sigs[i];
    struct action a, old;
    rx_u32 set = (rx_u32)r->cx | (rx_u32)r->si << 16, now, left;
    int sig = (int)r->bx;

    switch (r->ax & 0xFF) {
    case PX_SIGACTION:
        if (sig <= 0 || sig > SIG_MAX || (r->si && (sig == SIGKILL || sig == SIGSTOP))) {
            *error = EINVAL;
            return -1;
        }
        old = s->act[sig];
        if ((r->si && (*error = action_in(i, r->si, &a)) != 0)
                || (r->di && (*error = action_out(i, r->di, &old)) != 0))
            return -1;
        if (r->si) {
            a.mask &= ~UNBLOCKABLE;
            s->act[sig] = a;
            s->tramp = r->cx;
            if (a.handler == PX_SIG_IGN || (a.handler == PX_SIG_DFL && ignores(sig)))
                s->pending &= ~bit(sig);        /* discarded (XSH 2.4.1) */
        }
        return 0;
    case PX_SIGPROCMASK:
        r->si = (rx_u16)s->blocked;
        r->di = (rx_u16)(s->blocked >> 16);
        if (sig == SIG_BLOCK)
            s->blocked |= set;
        else if (sig == SIG_UNBLOCK)
            s->blocked &= ~set;
        else if (sig == SIG_SETMASK)
            s->blocked = set;
        else {
            *error = EINVAL;
            return -1;
        }
        s->blocked &= ~UNBLOCKABLE;
        return 0;
    case PX_SIGPENDING:
        r->si = (rx_u16)s->pending;
        r->di = (rx_u16)(s->pending >> 16);
        return 0;
    case PX_SIGSUSPEND:
        s->restore = s->blocked;
        s->restoring = 1;
        s->blocked = set & ~UNBLOCKABLE;
        while (!sig_ready(i)) {
            lock_give();
            proc_sleep(i);
            lock_take(PROC_NOTIFY(i));
            if (!proc_still(i))
                return SIG_GONE;
        }
        *error = EINTR;
        return -1;
    case PX_SIGRETURN:
        s->blocked = set & ~UNBLOCKABLE;
        return 0;
    case PX_ALARM:
        now = rx_ticks();
        left = s->alarm_at > now ? (s->alarm_at - now + TICKS_HZ - 1) / TICKS_HZ : 0;
        s->alarm_at = r->bx ? now + (rx_u32)r->bx * TICKS_HZ : 0;
        timers_arm();
        return (int)left;
    case PX_NANOSLEEP:
        if (set == 0)
            return 0;
        s->sleep_at = rx_ticks() + set;
        timers_arm();
        for (;;) {
            now = rx_ticks();
            if (now >= s->sleep_at) {
                s->sleep_at = 0;
                return 0;
            }
            if (sig_ready(i)) {         /* EINTR, never restarted (XSH nanosleep) */
                left = s->sleep_at - now;
                s->sleep_at = 0;
                r->si = (rx_u16)left;
                r->di = (rx_u16)(left >> 16);
                *error = EINTR;
                return -1;
            }
            lock_give();
            proc_sleep(i);
            lock_take(PROC_NOTIFY(i));
            if (!proc_still(i))
                return SIG_GONE;
        }
    }
    *error = ENOSYS;
    return -1;
}
