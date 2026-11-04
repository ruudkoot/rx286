; ============================================================================
; rx286 - src/include/kcalls.inc
; The kernel's calls: INT 31h, on capabilities (roadmap l4.md L3-L4, D20).
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
                            ;    BL its access byte; a space: CX slots
KCALL_COPY          equ 8   ; DX the destination's space; SI the caller's slot; DI the
                            ;    destination slot; AL COPY_*; BX a badge (mint)
KCALL_THREAD        equ 9   ; DX thread; AL THREAD_*; configure: SI space, BX IP, CX SP;
                            ;    start: CL priority, CH 1 to ask for IOPL
KCALL_TIMER         equ 11  ; DX notification; CX ticks: signalled once, CX ticks from now
KCALL_SEGMENT       equ 12  ; DX segment -> DL:AX its physical base, CX its limit
KCALL_DELETE        equ 13  ; DX a slot of the caller's: emptied
KCALL_SAVE_REPLY    equ 14  ; SI an empty slot: the reply owed, as a capability to send on
KCALL_COUNT         equ 17

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

PRIORITY_MAX        equ 7
SPACE_SLOTS_MIN     equ 8   ; a space's slots: a power of two between these
SPACE_SLOTS_MAX     equ 32

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
