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
; A thread control block (thread.asm; roadmap l4.md L2). Its kernel stack is
; a segment of its own (SEL_TSTACK + 8n), at whose top the CPU puts the frame
; of every interrupt from ring 3 (SP0); while it does not run, its kernel
; SS:SP rest here, at what switch_to pushed.
T_SS                equ 0       ; its kernel stack's SS:SP while another runs
T_SP                equ 2
T_STATE             equ 4       ; byte: TS_*
T_PRIO              equ 5       ; byte: 0, the lowest, to PRIORITIES - 1
T_NEXT              equ 6       ; the next of its ready queue
T_LDT               equ 8       ; its LDT's selector
T_STACK             equ 10      ; its kernel stack's selector
T_USTACK_TOP        equ 12      ; its program's SP at a start
T_RESTART           equ 14      ; byte: restart_pending, kept while another runs
T_FPU_VALID         equ 15      ; byte: T_FPU holds its 287's state
T_NAME              equ 16      ; its name (kdata)
T_SLICE             equ 18      ; byte: ticks left of its time slice
T_FLAGS             equ 19      ; byte: TF_*
T_RUN_TICKS         equ 20      ; ticks during which it was running
T_LDT_LIVE          equ 22      ; its LDT (kdata)
T_FAULT             equ 24      ; the endpoint its faults go to, or 0 (l4.md D18)
T_RUNS              equ 26      ; times it was switched to
T_SPACE             equ 28      ; its space (kdata)
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
TCB_SIZE            equ 160
%if T_FPU + 94 > T_FAULT_BADGE
  %error "kernel.inc: T_FPU's 94 bytes overlap the next field"
%endif

TI_CALLING          equ 0x01    ; T_IPC: a call, which waits for a reply
TI_GRANT            equ 0x02    ;        it passes a capability (its frame's BP)

; A thread as an object of the arena (roadmap l4.md L3): its control block,
; then its kernel stack, a segment of its own from the GDT's pool. The
; stack's 352 bytes are more than three times the deepest the watermark
; found in any test once the disks left the kernel (102: l4.md D3, L9).
TCB_OBJECT_SIZE     equ 512
TCB_STACK_OFF       equ TCB_SIZE
TCB_STACK_SIZE      equ TCB_OBJECT_SIZE - TCB_SIZE

; ---------------------------------------------------------------- spaces and capabilities
; A space (l4.md L3): a header, its LDT (a descriptor a slot), then a shadow
; entry a slot, which says what the slot holds. kcalls.inc names the types.
SP_SLOTS            equ 0       ; the header: how many slots
SP_GDT_SELECTOR     equ 2       ; its LDT's descriptor, from the GDT's pool
SP_DEAD             equ 4       ; byte: 1 once its last capability went (revoke.asm)
SP_HEADER_SIZE      equ 16
SP_LDT              equ SP_HEADER_SIZE
SH_TYPE             equ 0       ; byte: CAP_*
SH_RIGHTS           equ 1       ; byte
SH_OBJECT           equ 2       ; a kernel object's offset in kdata; memory's base in
                                ; paragraphs (a segment, untyped); an IRQ line
SH_SIZE             equ 4       ; memory's size in paragraphs (a segment, untyped)
SH_BADGE            equ 4       ; an endpoint's or notification's badge
SH_WATERMARK        equ 6       ; untyped: paragraphs retyped so far
SH_HOLE             equ 12      ; untyped: the room an alignment skipped, kept for
SH_HOLE_END         equ 14      ;    smaller objects (paragraphs, as the watermark)
SH_PARENT           equ 8       ; the space it was copied from (0: made, not copied)
SH_PARENT_SLOT      equ 10      ; and the slot there
SHADOW_SIZE         equ 16
SMALL_OBJECT_SIZE   equ 16      ; an endpoint, a notification
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

PRIORITIES          equ 8
SLICE_TICKS         equ 5       ; a time slice: a tenth of a second
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
