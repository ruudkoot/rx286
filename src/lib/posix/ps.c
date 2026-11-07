/* ============================================================================
 * rx286 - src/lib/posix/ps.c
 * rx_ps (roadmap os-server.md P12; rx/ps.h): PX_PS, the processes one by
 * one, for ps.
 * ============================================================================ */

#include "rx/ps.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"
#include "posix.h"

/* rx_px - posix.c's call on the OS server */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

/* rx_ps - PX_PS (rx/ps.h) */
int rx_ps(int k, struct rx_ps *p)
{
    struct rx_kregs r;

    return rx_px(PX_PS, (rx_u16)k, 0, 0, (rx_u16)(unsigned)p, &r);
}
