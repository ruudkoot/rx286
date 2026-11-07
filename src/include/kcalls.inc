; ============================================================================
; rx286 - src/include/kcalls.inc
; The kernel's calls: INT 31h, on capabilities (roadmap l4.md L3-L5, D20).
;
; A capability is named by its selector: slot n of the caller's LDT is
; n * 8 + 4 + its ring. A segment capability is the descriptor itself; any
; other capability is an all-zero descriptor, invisible to the program, and
; the kernel's shadow entry of the slot says what it is. AH is the call; the
; status comes back in AL (KE_OK, or an error with CF set). Call
; KCALL_SEGMENT returns data in AX, so its status is CF alone.
; docs/kernel-calls.md is the reference.
; ============================================================================

%ifndef RX286_KCALLS_INC
%define RX286_KCALLS_INC

KCALL_VECTOR        equ 0x31

KCALL_CALL          equ 1   ; DX endpoint; AL label; BX CX SI DI; BP a capability to pass
                            ;    -> AL status, BX CX SI DI the reply
KCALL_REPLY_RECV    equ 2   ; BX CX SI DI the reply; DX endpoint; BP the receive slot
                            ;    -> AL label, DX badge, BX CX SI DI, BP the capability received
KCALL_RECV          equ 3   ; DX endpoint or notification; BP the receive slot -> as 2;
                            ;    a notification: BX its bits
KCALL_SEND          equ 4   ; as KCALL_CALL, without waiting for a reply; on a reply
                            ;    capability, the reply (BX CX SI DI)
KCALL_SIGNAL        equ 5   ; DX notification: its badge ORed into its bits
KCALL_POLL          equ 6   ; as KCALL_RECV, but KE_EMPTY at once if nothing is there
KCALL_RETYPE        equ 7   ; DX untyped; AL type; SI destination slot; a segment: CX bytes,
                            ;    BL its access byte; a space: CX slots; untyped: CX
                            ;    paragraphs (l4.md L12)
KCALL_COPY          equ 8   ; DX the destination's space; SI the caller's slot; DI the
                            ;    destination slot; AL COPY_*; a mint: BX the badge, CL
                            ;    the rights it keeps (0: all). Untyped and a saved reply:
                            ;    moved only (KE_ARG)
KCALL_THREAD        equ 9   ; DX thread; AL THREAD_*; configure: SI space, BX IP, CX SP;
                            ;    start: CL priority, CH START_*
KCALL_IRQ           equ 10  ; DX an interrupt line; AL IRQ_* (l4.md L7, D10)
KCALL_TIMER         equ 11  ; DX notification; CX ticks (1-7FFFh): signalled once, CX
                            ;    ticks from now
KCALL_SEGMENT       equ 12  ; DX segment -> DL:AX its physical base, CX its limit
KCALL_DELETE        equ 13  ; DX a slot of the caller's: emptied
KCALL_SAVE_REPLY    equ 14  ; SI an empty slot: the reply owed, as a capability to send on
KCALL_REVOKE        equ 15  ; DX a slot: every capability derived from it deleted, in every
                            ;    space (an untyped's memory free again: l4.md L12)
KCALL_TEST          equ 16  ; debug and test builds: AL TEST_*, the hooks of debugging and
                            ;    tests (KE_NOSYS in release builds)
KCALL_LOG           equ 17  ; DS:SI bytes, CX how many (LOG_MAX at most): to the kernel's
                            ;    log (l4.md L10, D15) -> AX the bytes written (fewer if
                            ;    the thread is to restart); CF and AX KE_ARG or KE_CAP
KCALL_TICKS         equ 18  ; -> DX:AX the ticks since the start (TICKS_HZ a second)
KCALL_SEAL          equ 19  ; DX a data segment of DPL 3 that no copy of remains, retyped
                            ;    from untyped: it becomes readable code of DPL 3
                            ;    (os-server.md P2, E5)
KCALL_RESIZE        equ 20  ; DX a data segment retyped from an untyped of the caller's,
                            ;    the last carved there; CX bytes (1 to 65,535): it and
                            ;    every copy so long, in place, new bytes zeroed (P15)
KCALL_COUNT         equ 21
LOG_MAX             equ 4096
TICKS_HZ            equ 50

IRQ_BIND            equ 0   ; KCALL_IRQ: SI a notification, which the line's interrupts
                            ;    signal (its badge, or 1); the line unmasked
IRQ_ACK             equ 1   ;    the driver has served an interrupt: the line unmasked
TEST_MOUSE_BYTE     equ 0   ; KCALL_TEST: -> BL the next byte a key script gave the
                            ;    mouse (its IRQ4 signalled), or KE_EMPTY
TEST_KEY_BYTE       equ 1   ;    -> BL the next key a script typed, where it cannot go
                            ;    through the 8042 (MAME; IRQ1 signalled), or KE_EMPTY
TEST_READER         equ 2   ;    BL TEST_READER_*: whether the OS server waits for a key,
                            ;    having found none (the test hooks type then)
TEST_DUMP           equ 3   ;    every thread, on the log (Sys Req; debug builds too)
TEST_KEYS_READY     equ 4   ;    the keyboard driver has started: the script may begin
TEST_SOUND_PROBE    equ 5   ;    TEST_SOUND builds: BX the frequency the speaker sounds:
                            ;    measured over a tick, a probe line on the log
TEST_SILENCE_PROBE  equ 6   ;    TEST_SOUND builds: the speaker silent over a tick?
TEST_PROBE          equ 7   ;    TEST_ATTACK builds: BL PROBE_*: change one of the caller's
                            ;    own descriptors as a revocation would, so the way back
                            ;    to its ring can be tested (l4.md L1); its next start
                            ;    undoes it
TEST_GIVE_WAY       equ 8   ;    CX: the next CX interrupt windows of any kernel call give
                            ;    way, a more urgent thread ready or not, so that the
                            ;    calls resume (os-server.md P3) -> CX the windows that
                            ;    were still to
PROBE_DS_ABSENT     equ 1   ; the data segment's descriptor not present
PROBE_DS_EXEC       equ 2   ; the data segment's slot refilled with execute-only code
PROBE_SS_ABSENT     equ 3   ; the stack's descriptor not present
PROBE_SS_READONLY   equ 4   ; the stack's slot refilled with read-only data
PROBE_CS_ABSENT     equ 5   ; the code's descriptor not present
PROBE_CS_DATA       equ 6   ; the code's slot refilled with data
PROBE_COUNT         equ 7
TEST_READER_NONE    equ 0
TEST_READER_TIMED   equ 1   ; a wait with a limit
TEST_READER_FOREVER equ 2

; Capability types (a slot's shadow entry)
CAP_EMPTY           equ 0
CAP_SEGMENT         equ 1
CAP_UNTYPED         equ 2
CAP_THREAD          equ 3
CAP_SPACE           equ 4
CAP_ENDPOINT        equ 5
CAP_NOTIFY          equ 6
CAP_IRQ             equ 7
CAP_REPLY           equ 8   ; a reply owed, saved (KCALL_SAVE_REPLY): sent on once

RIGHT_SEND          equ 1   ; an endpoint's or notification's rights (SH_RIGHTS)
RIGHT_RECV          equ 2
RIGHT_GRANT         equ 4   ; an endpoint's: messages through it may pass a capability
RIGHTS_ALL          equ 7
NOTIFY_LABEL        equ 0xFF ; a receive's label when its thread's bound notification fired

COPY_COPY           equ 0   ; KCALL_COPY: a second capability to the same thing
COPY_MOVE           equ 1   ;    the capability itself, the source slot emptied
COPY_MINT           equ 2   ;    a copy with a badge (an unbadged endpoint or notification),
                            ;    and its rights ANDed with CL (0: kept)

THREAD_CONFIGURE    equ 0   ; KCALL_THREAD: its space, entry and stack, before it starts
THREAD_START        equ 1   ;    into the scheduler at a priority
THREAD_BIND         equ 2   ;    SI a notification: bound to it, so a receive on an
                            ;    endpoint also returns its bits
THREAD_FAULT        equ 3   ;    SI an endpoint: its faults go there, as calls (l4.md D18)
THREAD_RESTART      equ 4   ;    its program starts again at its entry (l4.md L6)
THREAD_STOP         equ 5   ;    it stops: off every queue, its wait given up; THREAD_START
                            ;    starts it again, at its entry (l4.md L11)
THREAD_INFO         equ 6   ;    -> BL its state (STATE_*), BH its priority, CX the times it
                            ;    was switched to
THREAD_SUSPEND      equ 7   ;    SI a notification, or 0: it stops, its registers kept, on its
                            ;    way back to its ring, and the notification is signalled;
                            ;    THREAD_START resumes it where it was (os-server.md P2)
THREAD_FRAME        equ 8   ;    of a suspended thread: BL FRAME_READ or FRAME_WRITE, SI a
                            ;    segment of the caller's, DI an offset: TFR_SIZE bytes
THREAD_FPU          equ 9   ;    SI a thread: its 287's state copied into this one, which has
                            ;    not started or is stopped (a fork's child: os-server.md P15)
FRAME_READ          equ 0   ; THREAD_FRAME's BL: the thread's frame into the caller's bytes
FRAME_WRITE         equ 1   ;    the caller's bytes into the frame (not TFR_VECTOR, TFR_ERROR;
                            ;    FLAGS: IF set, NT clear, IOPL the thread's)
; A thread's frame, as THREAD_FRAME moves it: its registers when it stopped
TFR_ES              equ 0
TFR_DS              equ 2
TFR_DI              equ 4
TFR_SI              equ 6
TFR_BP              equ 8
TFR_SP_POPA         equ 10      ; PUSHA's copy of SP, which POPA skips
TFR_BX              equ 12
TFR_DX              equ 14
TFR_CX              equ 16
TFR_AX              equ 18
TFR_VECTOR          equ 20      ; the kernel's: not written
TFR_ERROR           equ 22
TFR_IP              equ 24
TFR_CS              equ 26
TFR_FLAGS           equ 28
TFR_SP              equ 30
TFR_SS              equ 32
TFR_SIZE            equ 34
STATE_FREE          equ 0   ; THREAD_INFO's states: not started
STATE_READY         equ 1
STATE_RUNNING       equ 2
STATE_WAITING       equ 3   ;    inside the kernel, for its turn at the log
STATE_SENDING       equ 4
STATE_RECEIVING     equ 5
STATE_REPLY         equ 6   ;    awaiting its call's reply
STATE_NOTIFY        equ 7   ;    awaiting a notification
STATE_STOPPED       equ 8
START_IOPL          equ 1   ; THREAD_START's CH: IOPL 1, for a ring-1 thread
START_FOREGROUND    equ 2   ;    the program the keys are for, which the test hooks follow
                            ;    (the keys are the OS server's since l4.md L8); from
                            ;    rings 1-2 only
START_SESSION       equ 4   ;    a server's thread that serves one client: restarted
                            ;    with it (l4.md L6); from rings 1-2 only

; A fault, as the call its thread makes on its fault endpoint: the label is
; the vector, BX the error code (0 if none), CX:SI the CS:IP, DI FAULT_*,
; DX the badge. A reply restarts the thread at the IP in BX; until one
; comes, it waits.
FAULT_COUNTED       equ 1   ; DI: a test build counted it (the fuzzer): say nothing

PRIORITY_MAX        equ 7
SPACE_SLOTS_MIN     equ 8   ; a space's slots: a power of two between these
SPACE_SLOTS_MAX     equ 256

; The root's slots at its start (roadmap l4.md L5): slots 0, 1 and 2 its
; code, data and stack, as every program's; then the kernel's gifts.
ROOT_SLOT_UNTYPED   equ 3   ; the memory for segments, as untyped: what is left (with
                            ;    extended memory, most of that: os-server.md P3)
ROOT_SLOT_ARENA     equ 4   ; the arena, as untyped: what is left (with extended memory,
                            ;    the rest of that)
ROOT_SLOT_MODULES   equ 5   ; the module table (layout.inc), read-only
ROOT_SLOT_SPACE     equ 6   ; its own space
ROOT_SLOT_THREAD    equ 7   ; its own thread
ROOT_SLOT_MODULE    equ 8   ; module n's code (n from 1) at ROOT_SLOT_MODULE + 2 (n - 1),
                            ;    and its data as assembled, read-only, in the next
ROOT_SLOT_LOW_UNTYPED equ 100 ; with extended memory: the memory for segments below 1 MB,
ROOT_SLOT_LOW_ARENA equ 101 ;    and the arena (slots 3 and 4 then hold extended memory)
ROOT_SLOT_VIDEO     equ 111 ; the screen's text page, a segment of DPL 1 (l4.md L8)
ROOT_SLOT_IRQ       equ 112 ; interrupt line n at ROOT_SLOT_IRQ + n: every line the kernel
                            ;    does not keep (its own are left empty)
ROOT_SLOTS          equ 512 ; its space's slots: past the kernel's gifts, its own (l4.md
                            ;    L10); 256 on, those it makes and gives back (os-server.md P4)
ROOT_SLOT_DYNAMIC   equ 256

KE_OK               equ 0
KE_CAP              equ 1   ; not a capability of the type the call needs
KE_ARG              equ 2   ; an argument out of range
KE_MEM              equ 3   ; the untyped memory has no room left
KE_SLOT             equ 4   ; the destination slot is not empty
KE_POOL             equ 5   ; no descriptor left in the kernel's pool (spaces, threads)
KE_STATE            equ 6   ; not in that state: a thread started twice, say
KE_NOSYS            equ 7   ; no such call
KE_EMPTY            equ 8   ; KCALL_POLL: nothing there

; kcall function - load AH and trap into the kernel
%macro kcall 1
    mov ah, (%1)
    int KCALL_VECTOR
%endmacro

%endif
