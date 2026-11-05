; ============================================================================
; rx286 - src/userland/counter.asm
; The counter: a second program, beside the shell (roadmap l4.md L2).
;
; It counts, for ever, in its own data segment: a program that never waits,
; which a preemptive scheduler must not let starve the shell. The root
; starts it in a thread and a space of its own, at the lowest priority
; (roadmap l4.md L5), so it counts only when nothing else runs: about once
; a second it says how fast (roadmap l4.md L11, D19), "idle 1234k/s", which
; the OS server puts in its field of the status line. It looks at the time
; (KCALL_TICKS) only every 65,536 counts, and writes with one call of the
; OS server, the stub's work done inline. Assembled on its own, with rooms
; of its own (CTEXT_ROOM, CDATA_ROOM), and put in the boot image as a
; module.
;
; Test builds with TEST_COUNTER_FPU make it a check of the 287 instead: it
; keeps 1 on the 287's stack and compares it with a fresh 1 for ever, so
; any loss of its 287 state while other threads use the 287 shows; it then
; says so on the kernel's log (KCALL_LOG) and stops counting.
; TEST_COUNTER_FAULT makes it fault once, at its first start, so that the
; root reports a fault of a module of its name (tests/root). A counter at
; or above the shell's priority (TEST_COUNTER_SAME, TEST_COUNTER_ABOVE) is
; a test of the scheduler: it never writes, so that it never waits.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"
%include "syscalls.inc"
%include "kcalls.inc"
%include "os.inc"

%ifndef TEST_COUNTER_SAME
  %ifndef TEST_COUNTER_ABOVE
    %define COUNTER_REPORTS
  %endif
%endif
REPORT_TEXT         equ 20              ; "idle 4294967k/s"

section ctext start=0 vstart=0
section cdata start=COUNTER_DATA_START vstart=0
section ctext

; ----------------------------------------------------------------------------
; entry - count for ever
;   In:       the kernel's start: DS = ES = its data, SS:SP its stack
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
%ifdef TEST_COUNTER_FAULT
        cmp byte [faulted], 0
        jne .counting
        mov byte [faulted], 1
.fault:
        db 0x0F, 0x0B                   ; UD2: #UD on a 286 too
.counting:
%endif
%ifdef TEST_COUNTER_FPU
        fld1                            ; ST0 = 1, kept for ever
.check:
        fld1
        fcomp st1                       ; still 1?
        fnstsw ax
        sahf
        jne .lost
        add word [count], 1
        adc word [count + 2], 0
        jmp .check
.lost:
        mov si, msg_lost
        mov cx, msg_lost_end - msg_lost
        kcall KCALL_LOG
.stop:
        jmp .stop
%else
.next:
        add word [count], 1
        jnc .next
        inc word [count + 2]
%ifdef COUNTER_REPORTS
        call report                     ; every 65,536 counts
%endif
        jmp .next
%endif

%ifdef COUNTER_REPORTS
; ----------------------------------------------------------------------------
; report - if a second has passed since the last report: the counts a
; second since, in thousands, to the status line
;   In:       DS = ES = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, BP
; ----------------------------------------------------------------------------
report:
        kcall KCALL_TICKS               ; AX = the ticks' low word
        mov bx, ax
        sub bx, [report_ticks]          ; BX = ticks since the last
        cmp word [report_ticks], 0
        je .first                       ; nothing to count from yet
        cmp bx, TICKS_HZ
        jb .done
        mov [report_ticks], ax
        cmp bx, 0xFFFF / (1000 / TICKS_HZ)   ; (a minute and more: as a minute)
        jbe .divisor
        mov bx, 0xFFFF / (1000 / TICKS_HZ)
.divisor:
        mov ax, 1000 / TICKS_HZ
        mul bx
        mov cx, ax                      ; CX = the ticks, as a thousandth of counts a second
        mov ax, [count]
        mov dx, [count + 2]
        sub ax, [report_count]
        sbb dx, [report_count + 2]
        push ax
        mov ax, dx
        xor dx, dx
        div cx
        mov bx, ax                      ; the quotient's high word
        pop ax
        div cx                          ; and its low
        mov dx, bx
        mov di, report_text
        push ax
        mov ax, 'id'
        stosw
        mov ax, 'le'
        stosw
        mov al, ' '
        stosb
        pop ax
        call fmt_dec32
        mov ax, 'k/'
        stosw
        mov al, 's'
        stosb
        mov cx, di
        mov si, report_text
        sub cx, si
        call os_write
        jmp .counted
.first:
        mov [report_ticks], ax
.counted:
        mov ax, [count]
        mov [report_count], ax
        mov ax, [count + 2]
        mov [report_count + 2], ax
.done:
        ret

; ----------------------------------------------------------------------------
; os_write - SYS_WRITE, as the stub would make it: the bytes into the
; transfer segment, the call on the OS server's endpoint
;   In:       DS:SI = the bytes; CX = how many (REPORT_TEXT at most)
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, BP
; ----------------------------------------------------------------------------
os_write:
        push es
        mov ax, OS_XFER
        mov es, ax
        mov [es:XFER_CX], cx
        mov word [es:XFER_SI], XFER_DATA
        mov di, XFER_DATA
        rep movsb
        pop es
        mov al, SYS_WRITE
        mov dx, OS_EP
        xor bp, bp
        kcall KCALL_CALL
        ret

%include "format.asm"
%endif

section cdata
count               dd 0
%ifdef COUNTER_REPORTS
report_ticks        dw 0                ; the ticks at the last report
report_count        dd 0                ; and the count
report_text         times REPORT_TEXT db 0
%endif
%ifdef TEST_COUNTER_FAULT
faulted             db 0
%endif
%ifdef TEST_COUNTER_FPU
msg_lost            db "counter: its 287 state was lost", 10
msg_lost_end:
%endif

section ctext
%if ($ - $$) > CTEXT_ROOM
  %error "counter.asm: the code outgrew CTEXT_ROOM"
%endif
section cdata
%if ($ - $$) > CDATA_ROOM
  %error "counter.asm: the data outgrew CDATA_ROOM"
%endif
