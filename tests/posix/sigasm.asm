; ============================================================================
; rx286 - tests/posix/sigasm.asm
; What the signals' tests do in assembly (roadmap os-server.md P10;
; tests/posix/signal.c, sigfpu.c): FLAGS read, an IRET of the program's
; own, and the 287 set, spoilt and checked. The C convention of cabi.inc.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global rx_test_flags, rx_test_iret, rx_test_287_set, rx_test_287_spoil, rx_test_287_check

CW_CHOP             equ 0x0F7F          ; the 287's control word: rounding toward zero
CW_INIT             equ 0x037F          ;    as FNINIT leaves it
SW_C3               equ 0x4000          ; its status word: FCOM's equal

code_section

; ----------------------------------------------------------------------------
; rx_test_flags - unsigned rx_test_flags(void): FLAGS, as they are
;   In:       nothing
;   Out:      AX = FLAGS
;   Destroys: nothing else
; ----------------------------------------------------------------------------
rx_test_flags:
        pushf
        pop ax
        ret

; ----------------------------------------------------------------------------
; rx_test_iret - void rx_test_iret(void): an IRET to the next instruction;
; with NT set, a task's return instead, through the TSS's back link
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
rx_test_iret:
        pushf
        push cs
        push word .back
        iret
.back:
        ret

; ----------------------------------------------------------------------------
; rx_test_287_set - void rx_test_287_set(void): FNINIT, then rounding
; toward zero and pi in ST0
;   In:       nothing
;   Out:      nothing
;   Destroys: BX
; ----------------------------------------------------------------------------
rx_test_287_set:
        fninit
        push word CW_CHOP
        mov bx, sp
        fldcw [ss:bx]
        add sp, 2
        fldpi
        ret

; ----------------------------------------------------------------------------
; rx_test_287_spoil - void rx_test_287_spoil(void): what a handler might do
; to the 287: FNINIT, and two ones on its stack
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
rx_test_287_spoil:
        fninit
        fld1
        fld1
        ret

; ----------------------------------------------------------------------------
; rx_test_287_check - unsigned rx_test_287_check(void): bit 0 if the control
; word is rx_test_287_set's, bit 1 if ST0 is pi (popped)
;   In:       nothing
;   Out:      AX = the bits
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
rx_test_287_check:
        sub sp, 2
        mov bx, sp
        xor cx, cx
        fstcw [ss:bx]
        fwait
        cmp word [ss:bx], CW_CHOP
        jne .stack
        or cl, 1
.stack:
        fldpi
        fcompp                          ; pi against ST0, both popped
        fstsw [ss:bx]
        fwait
        test word [ss:bx], SW_C3
        jz .done
        or cl, 2
.done:
        mov ax, cx
        add sp, 2
        ret
