; ============================================================================
; rx286 - src/bin/crashes.asm
; What crash tries (roadmap os-server.md P12; src/bin/crash.c), each in a
; routine of its own that does not return, but crash_fpu on a machine whose
; 287 raises no error. Where it can, the fault is the routine's first
; instruction; where it cannot, the place it faults has a label of its own,
; for the tests. The C convention of cabi.inc.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global crash_gp, crash_ud, crash_de, crash_ss, crash_ss_push, crash_io, crash_cli
global crash_hlt, crash_int, crash_kernel, crash_call, crash_write, crash_fpu
global crash_fpu_after, crash_tf, crash_tf_after, crash_nt, crash_nt_iret

OWN_CODE            equ 0x07            ; a process's code: slot 0, RPL 3
BEYOND_CODE         equ 0xFFF0          ; past any process's code
GUESS_KERNEL_CODE   equ 0x08            ; the GDT's first selectors: the kernel's
GUESS_KERNEL_DATA   equ 0x10
KEYBOARD_PORT       equ 0x60
FLAGS_TF            equ 0x0100
FLAGS_NT            equ 0x4000
FPU_CW_ZERO_DIVIDE  equ 0x037B          ; FNINIT's, the zero divide unmasked

code_section

; ----------------------------------------------------------------------------
; crash_gp - void crash_gp(void): a jump past the code segment's limit
;   In:       nothing
;   Out:      does not return: #GP (MAME: at the jump's target)
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_gp:
        jmp OWN_CODE:BEYOND_CODE

; ----------------------------------------------------------------------------
; crash_ud - void crash_ud(void): an instruction that does not exist
;   In:       nothing
;   Out:      does not return: #UD
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_ud:
        db 0xFF, 0xFF

; ----------------------------------------------------------------------------
; crash_de - void crash_de(void): a divide by zero
;   In:       nothing
;   Out:      does not return: #DE
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_de:
        div word [cs:.zero]
.zero:  dw 0

; ----------------------------------------------------------------------------
; crash_ss - void crash_ss(void): SP 0, then a push, which wraps past the
; stack's limit (crash_ss_push)
;   In:       nothing
;   Out:      does not return: #SS
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_ss:
        mov sp, 0
        ; falls through

; ----------------------------------------------------------------------------
; crash_ss_push - crash_ss's push, at SP 0
;   In:       SP = 0
;   Out:      does not return: #SS
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_ss_push:
        push ax

; ----------------------------------------------------------------------------
; crash_io - void crash_io(void): the keyboard's port read
;   In:       nothing
;   Out:      does not return: #GP, IOPL being below CPL 3
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_io:
        in al, KEYBOARD_PORT

; ----------------------------------------------------------------------------
; crash_cli - void crash_cli(void): interrupts turned off
;   In:       nothing
;   Out:      does not return: #GP, the same
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_cli:
        cli

; ----------------------------------------------------------------------------
; crash_hlt - void crash_hlt(void): the CPU halted
;   In:       nothing
;   Out:      does not return: #GP at CPL 3
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_hlt:
        hlt

; ----------------------------------------------------------------------------
; crash_int - void crash_int(void): INT 32h, past the IDT's limit
;   In:       nothing
;   Out:      does not return: #GP(0192)
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_int:
        int 0x32

; ----------------------------------------------------------------------------
; crash_kernel - void crash_kernel(void): the kernel's data selector loaded
;   In:       nothing
;   Out:      does not return: #GP(0010), its DPL 0
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_kernel:
        mov ds, [cs:.selector]
.selector:
        dw GUESS_KERNEL_DATA

; ----------------------------------------------------------------------------
; crash_call - void crash_call(void): a call into the kernel's code
;   In:       nothing
;   Out:      does not return: #GP(0008), its DPL 0
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_call:
        call GUESS_KERNEL_CODE:0

; ----------------------------------------------------------------------------
; crash_write - void crash_write(void): a write over its own code
;   In:       nothing
;   Out:      does not return: #GP, code being not writable
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_write:
        mov [cs:0], al

; ----------------------------------------------------------------------------
; crash_fpu - void crash_fpu(void): a divide by zero on the 287, unmasked;
; its error arrives as IRQ13, and is the kernel's fault #MF after the
; FWAIT (crash_fpu_after)
;   In:       nothing
;   Out:      returns only if no error arrives (no 287)
;   Destroys: AX
; ----------------------------------------------------------------------------
crash_fpu:
        push bp
        mov bp, sp
        push word FPU_CW_ZERO_DIVIDE
        fninit
        fldcw [bp - 2]
        fld1
        fldz
        fdivp st1, st0
        fwait
        ; falls through

; ----------------------------------------------------------------------------
; crash_fpu_after - crash_fpu's rest, where its fault is
;   In:       BP = crash_fpu's frame
;   Out:      returns from crash_fpu
;   Destroys: nothing else
; ----------------------------------------------------------------------------
crash_fpu_after:
        fninit
        mov sp, bp
        pop bp
        ret

; ----------------------------------------------------------------------------
; crash_tf - void crash_tf(void): the trap flag set, a single step's #DB
; after the next instruction (crash_tf_after)
;   In:       nothing
;   Out:      does not return: #DB
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_tf:
        pushf
        pop ax
        or ax, FLAGS_TF
        push ax
        popf
        nop
        ; falls through

; ----------------------------------------------------------------------------
; crash_tf_after - where crash_tf's step traps
;   In:       TF set
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_tf_after:
        nop

; ----------------------------------------------------------------------------
; crash_nt - void crash_nt(void): NT set, then IRET (crash_nt_iret)
;   In:       nothing
;   Out:      does not return: #TS
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_nt:
        pushf
        pop ax
        or ax, FLAGS_NT
        push ax
        popf
        ; falls through

; ----------------------------------------------------------------------------
; crash_nt_iret - crash_nt's IRET: a task's return to back link 0
;   In:       NT set
;   Out:      does not return: #TS(0000)
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_nt_iret:
        iret
