; ============================================================================
; rx286 - src/kernel/kernel.inc
; The kernel's own constants and macros: the interrupt frame, the MSW and
; FLAGS bits, colours, and TRACE, LOG, ASSERT and the kdata switch.
;
; Every module of src/kernel/ may use these. The frame is what isr_common
; builds on the kernel stack; BP points at it in every handler.
; ============================================================================

%ifndef RX286_KERNEL_INC
%define RX286_KERNEL_INC

; ---------------------------------------------------------------- the interrupt frame
; isr_common pushes the registers (PUSHA), DS and ES over what the stub and
; the CPU pushed. Offsets from BP:
FRAME_ES            equ 0
FRAME_DS            equ 2
FRAME_DI            equ 4
FRAME_SI            equ 6
FRAME_BP            equ 8
FRAME_SP            equ 10      ; PUSHA's copy of SP; POPA ignores it
FRAME_BX            equ 12
FRAME_DX            equ 14
FRAME_CX            equ 16
FRAME_AX            equ 18
FRAME_VECTOR        equ 20      ; pushed by the stub
FRAME_ERROR         equ 22      ; pushed by the CPU, or 0 by the stub
FRAME_IP            equ 24      ; pushed by the CPU from here on
FRAME_CS            equ 26
FRAME_FLAGS         equ 28
FRAME_USER_SP       equ 30      ; only when the interrupt came from ring 3
FRAME_USER_SS       equ 32
FRAME_SIZE_KERNEL   equ 30      ; a frame from ring 0
FRAME_SIZE_USER     equ 34      ; a frame from ring 3

; ---------------------------------------------------------------- threads
; A thread control block (thread.asm; roadmap l4.md L2, os-server.md P3),
; an object anywhere, named by its descriptor's selector. Its last bytes
; keep its frame while it does not run (T_FRAME); the running thread's is at
; the top of the kernel's one stack (KFRAME), where SP0 puts it. Nothing
; else of a thread's lies on that stack while the thread does not run: what
; it still has to do in the kernel is T_CONT, and the call's progress.
T_CONT              equ 0       ; byte: CONT_*, what it does when it runs again
T_LOG_DONE          equ 2       ; KCALL_LOG: the bytes written before a preemption
T_STATE             equ 4       ; byte: TS_*
T_PRIO              equ 5       ; byte: 0, the lowest, to PRIORITIES - 1
T_NEXT              equ 6       ; the next of its ready queue
T_LDT               equ 8       ; its LDT's selector
T_ZERO_PARAS        equ 10      ; KCALL_RETYPE: a segment's paragraphs, while it is zeroed
T_USTACK_TOP        equ 12      ; its program's SP at a start
T_RESTART           equ 14      ; byte: restart_pending, kept while another runs
T_FPU_VALID         equ 15      ; byte: T_FPU holds its 287's state
T_NAME              equ 16      ; its name (kdata)
T_SLICE             equ 18      ; byte: ticks left of its time slice
T_FLAGS             equ 19      ; byte: TF_*
T_RUN_TICKS         equ 20      ; ticks during which it was running
T_FAULT             equ 24      ; the endpoint its faults go to, or 0 (l4.md D18)
T_RUNS              equ 26      ; times it was switched to
T_SPACE             equ 28      ; its space
T_ENTRY             equ 30      ; its program's entry: the IP of a start
T_RING              equ 32      ; byte: its ring, its space's slot 0's DPL
T_IPC               equ 33      ; byte: TI_*, of the message it sends
T_BADGE             equ 34      ; the badge of the capability it sends with, while queued
T_RSLOT             equ 36      ; the slot it receives a capability into (a selector), or 0
T_REPLY             equ 38      ; the thread waiting for its reply, or 0
T_REPLY_SEQ         equ 40      ; that caller's T_CALLS when it called
T_WAIT_OBJ          equ 42      ; what it waits on: an endpoint, a notification, a thread
T_BOUND             equ 44      ; its bound notification, or 0
T_CALLS             equ 46      ; the calls it has made: a stale reply cannot answer a later one
T_FPU               equ 48      ; its 287's state (FNSAVE: 94 bytes) while not the owner
T_FAULT_BADGE       equ 142     ; the badge of the fault endpoint's capability
T_WAY_BACK          equ 144     ; byte: faults reported on this way back (isr_exit)
T_FPU_ERROR         equ 145     ; byte: its 287's error, its fault #MF on its way back
T_REVOKE_SPACE      equ 146     ; what its KCALL_REVOKE revokes, across its windows
T_REVOKE_SLOT       equ 148
T_SUSPEND_NOTIFY    equ 150     ; THREAD_SUSPEND's notification, signalled once it stopped
T_SUSPEND_BADGE     equ 152     ;    and the badge to signal with
T_REFS              equ 154     ; the capabilities to it: it dies with the last (revoke.asm)
T_SAVED_SPACE       equ 156     ; the slot of the saved reply owed to it, or 0 (ipc.asm)
T_SAVED_SLOT        equ 158
T_ZERO_DONE         equ 160     ; KCALL_RETYPE: its paragraphs zeroed so far
T_ZERO_BASE         equ 162     ;    its base, in paragraphs
T_ZERO_SLOT         equ 164     ;    its untyped's slot
T_FAULT_REGS        equ 166     ; 16 bytes: the registers its fault's message overwrote
T_ZERO_HIGH         equ 182     ; byte: KCALL_RETYPE: T_ZERO_BASE's bits 16-19
T_FRAME             equ 184     ; its frame while it does not run (FRAME_SIZE_USER bytes)
TCB_SIZE            equ T_FRAME + FRAME_SIZE_USER
%if T_FPU + 94 > T_FAULT_BADGE
  %error "kernel.inc: T_FPU's 94 bytes overlap the next field"
%endif

TI_CALLING          equ 0x01    ; T_IPC: a call, which waits for a reply
TI_GRANT            equ 0x02    ;        it passes a capability (its frame's BP)
TI_FAULT            equ 0x04    ;        its fault's call (ipc_fault)
KE_SUSPENDED        equ 0x7F    ; a fault's wait ended by THREAD_SUSPEND (the kernel's own:
                                ;    ipc_fault puts the registers back before any program sees it)

; What a thread does in the kernel when it runs again (T_CONT): the way back
; to its ring, else the first start of its program, the rest of its fault's
; call, or the rest of a kernel call that gave way to a more urgent thread
; (kpreempt) or waits for the log's turn (call_enter)
CONT_NONE           equ 0
CONT_FIRST          equ 1
CONT_KCALL          equ 2
CONT_RESUMED        equ 3       ; (while the call runs again: it finds its progress)
CONT_FAULT          equ 4       ; a fault from an exception
CONT_FAULT_WAY      equ 5       ; a fault the way back found in its frame

; A thread as an object (roadmap l4.md L3): its control block, its frame at
; its end; no kernel stack of its own since os-server.md P3
TCB_OBJECT_SIZE     equ 256
KFRAME              equ KSTACK_TOP - FRAME_SIZE_USER    ; the running thread's frame
%if TCB_SIZE > TCB_OBJECT_SIZE
  %error "kernel.inc: a thread's control block outgrew its object"
%endif

; ---------------------------------------------------------------- spaces and capabilities
; A space (l4.md L3): an object, named by its descriptor's selector (os-server.md
; P3): a header, its LDT (a descriptor a slot), then a shadow entry a slot, which
; says what the slot holds. kcalls.inc names the types.
SP_SLOTS            equ 0       ; the header: how many slots
SP_GDT_SELECTOR     equ 2       ; its LDT's descriptor, from the GDT's pool
SP_DEAD             equ 4       ; byte: 1 once its last capability went (revoke.asm)
SP_REFS             equ 6       ; the capabilities to it: it dies with the last
SP_FLUSH            equ 8       ; dead: the next slot dead_flush empties
SP_HEADER_SIZE      equ 16
SP_LDT              equ SP_HEADER_SIZE
SH_TYPE             equ 0       ; byte: CAP_*
SH_RIGHTS           equ 1       ; byte: RIGHT_*
SH_HIGH             equ 1       ; byte: memory's base paragraph's bits 16-19 (untyped, a
                                ;    segment: they have no rights; os-server.md P3)
SH_OBJECT           equ 2       ; a kernel object's offset in kdata; memory's base in
                                ; paragraphs (a segment, untyped); an IRQ line
SH_SIZE             equ 4       ; memory's size in paragraphs (a segment, untyped)
SH_BADGE            equ 4       ; an endpoint's or notification's badge
SH_WATERMARK        equ 6       ; untyped: paragraphs retyped so far
SH_HOLE             equ 12      ; untyped: the room an alignment skipped, kept for
SH_HOLE_END         equ 14      ;    smaller objects (paragraphs, as the watermark)
SH_PARENT           equ 8       ; the space it was copied from (0: made, not copied)
SH_PARENT_SLOT      equ 10      ; and the slot there
SH_CHILD            equ 16      ; its first child's space (0: none) and slot: its children
SH_CHILD_SLOT       equ 18      ;    are a list, linked by SH_NEXT (os-server.md D9)
SH_NEXT             equ 20      ; the next of its parent's children (0: the last)
SH_NEXT_SLOT        equ 22
SHADOW_SIZE         equ 24
SLOT_SIZE           equ 8 + SHADOW_SIZE ; a slot's bytes in its space: descriptor and shadow
SMALL_OBJECT_SIZE   equ 16      ; an endpoint, a notification
OBJ_REFS            equ 6       ; a small object's: the capabilities to it
; An endpoint (l4.md L4): a queue of senders or of receivers, never both
E_HEAD              equ 0
E_TAIL              equ 2
E_KIND              equ 4       ; byte: EK_*
EK_IDLE             equ 0
EK_SEND             equ 1
EK_RECV             equ 2
; A notification: a word of bits, who waits on it, whom it is bound to
N_BITS              equ 0
N_WAITER            equ 2
N_BOUND             equ 4
; A reply capability's shadow: the caller (SH_OBJECT), the server that
; saved it (SH_SERVER), the caller's T_CALLS then (SH_SEQ)
SH_SERVER           equ 4
SH_SEQ              equ 6

TS_FREE             equ 0       ; T_STATE: no thread
TS_READY            equ 1       ; in its ready queue
TS_RUNNING          equ 2
TS_WAITING          equ 3       ; inside the kernel, until the next interrupt
TS_SEND             equ 4       ; queued on an endpoint, to send
TS_RECV             equ 5       ; queued on an endpoint, to receive
TS_REPLY            equ 6       ; waiting for its call's reply
TS_NOTIFY           equ 7       ; waiting on a notification
TS_STOPPED          equ 8       ; stopped (THREAD_STOP), until started again
%if TS_READY != STATE_READY || TS_NOTIFY != STATE_NOTIFY || TS_STOPPED != STATE_STOPPED
  %error "kernel.inc: the thread states must be THREAD_INFO's (kcalls.inc)"
%endif

TF_FOREGROUND       equ 0x01    ; T_FLAGS: the keys and Ctrl+Break are its
TF_CONFIGURED       equ 0x02    ; its space, entry and stack are set
TF_IOPL             equ 0x04    ; it runs with IOPL 1 (a ring-1 thread that asked)
TF_SESSION          equ 0x08    ; it serves one client, and starts again with it
TF_DEAD             equ 0x10    ; its last capability went while it ran: it dies at its
                                ; way back (revoke.asm)
TF_ORPHAN           equ 0x20    ; its space died while it ran: at its way back it stops,
                                ; to be configured again (revoke.asm)
TF_SUSPEND          equ 0x40    ; to stop at its way back, its registers kept (THREAD_SUSPEND)
TF_SUSPENDED        equ 0x80    ; stopped so: THREAD_FRAME may move its frame, THREAD_START
                                ; resumes it
%if TFR_SIZE != FRAME_SIZE_USER || TFR_IP != FRAME_IP || TFR_SS != FRAME_USER_SS
  %error "kernel.inc: THREAD_FRAME's layout (kcalls.inc) must be the frame's"
%endif

PRIORITIES          equ 8
SLICE_TICKS         equ 5       ; a time slice: a tenth of a second
EXT_KB_MAX          equ 15360       ; the extended memory a 286 addresses: 15 MB
EXT_PROBE           equ 0x5AA5      ; ext_detect's word at 1 MB
STACK_FILL          equ 0xA5A5  ; debug builds: an unused word of a kernel stack

; ---------------------------------------------------------------- the CPU
MSW_PE              equ 0x0001  ; protection enable
MSW_MP              equ 0x0002  ; monitor processor extension: WAIT honours TS
MSW_EM              equ 0x0004  ; emulate processor extension: ESC faults
MSW_TS              equ 0x0008  ; task switched
FLAGS_CF            equ 0x0001
FLAGS_TF            equ 0x0100
FLAGS_IF            equ 0x0200
FLAGS_NT            equ 0x4000
FLAGS_USER_START    equ 0x0202  ; IF set, IOPL 0, everything else clear
FLAGS_IOPL1         equ 0x1000  ; IOPL 1: a driver's (roadmap l4.md D11)
FLAGS_USER_KEEP     equ 0x0FD5  ; the flags a program sets itself: CF PF AF ZF SF TF DF OF
                                ; (THREAD_FRAME writes these, never IF, IOPL or NT)
FLAGS_DF_TASK       equ 0x0002  ; the double-fault task: interrupts off (bit 1 reads as 1)
CPL_MASK            equ 3

; ---------------------------------------------------------------- the console
ATTR_NORMAL         equ 0x07    ; light grey on black
ATTR_KERNEL         equ 0x0E    ; yellow on black: the kernel's own messages
ATTR_PANIC          equ 0x4F    ; white on red
VECTOR_NAME_CHARS   equ 3       ; "#GP", "NMI": the longest name of an exception

; ---------------------------------------------------------------- kdata
; begin_kdata / end_kdata - put what lies between in the kernel's data
; segment, and return to the section that was current (NASM's __?SECT?__).
%macro begin_kdata 0
    [section kdata]
%endmacro
%macro end_kdata 0
    __?SECT?__
%endmacro

; kstring label, "text" - a zero-terminated string in kdata
%macro kstring 2+
    begin_kdata
%1: db %2, 0
    end_kdata
%endmacro

; STRETCH_BEGIN place / STRETCH_END - TEST_STRETCH builds: interrupts have
; just gone off, or are about to come on; the stretch between is measured
; (roadmaps/realtime.md R0; test.asm). The place: the vector in the high
; byte, a kernel call in the low; 0FFFFh the idle loop and its waits.
%macro STRETCH_BEGIN 1
%ifdef TEST_STRETCH
        push ax
        mov ax, %1
        call stretch_begin
        pop ax
%endif
%endmacro
%macro STRETCH_END 0
%ifdef TEST_STRETCH
        call stretch_end
%endif
%endmacro

; KWINDOW place - interrupts in for an instruction, and a more urgent
; thread let run: inside a long kernel call, where its state is whole
%macro KWINDOW 1
        STRETCH_END
        sti                             ; (STI acts after the next instruction)
        nop
        cli
        STRETCH_BEGIN %1
        call kpreempt
%endmacro


; ---------------------------------------------------------------- messages
; LOG "text" - a line of the kernel's own (yellow, every build), with "rx286: "
%macro LOG 1+
    begin_kdata
%%text: db %1, 0
    end_kdata
    push si
    mov si, %%text
    call klog
    pop si
%endmacro

; LOG_NUMBER "text", word - a line of the kernel's own: "rx286: text" and the
; word in hexadecimal (every build)
%macro LOG_NUMBER 2
    begin_kdata
%%text: db %1, 0
    end_kdata
    push ax
    push si
    mov ax, %2
    mov si, %%text
    call klog_number
    pop si
    pop ax
%endmacro

; TRACE "text" - a trace line in debug and test builds, nothing in release
%macro TRACE 1+
  %ifdef WITH_SERIAL
    begin_kdata
%%text: db %1, 0
    end_kdata
    push si
    mov si, %%text
    call ktrace
    pop si
  %endif
%endmacro

; ASSERT cc, "text" - in debug and test builds, panic unless condition cc
; holds (cc as in a Jcc: z, nz, c, ...); nothing in release
%macro ASSERT 2+
  %ifdef WITH_CHECKS
    j%1 %%ok
    begin_kdata
%%text: db "assertion failed: ", %2, 0
    end_kdata
    mov si, %%text
    xor bp, bp
    jmp panic
%%ok:
  %endif
%endmacro

%endif
