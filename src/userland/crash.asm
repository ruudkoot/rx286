; ============================================================================
; rx286 - src/userland/crash.asm
; `crash KIND`: the shell tries what no program may, to show the sandbox.
;
; Each kind does one forbidden thing. The kernel reports the fault and
; starts the shell again (roadmap D11), which says "started again". The
; shell knows no kernel selector but by number: what it tries are numbers
; any program could try.
; ============================================================================

FLAGS_TF            equ 0x0100
FLAGS_NT            equ 0x4000
GUESS_KERNEL_CODE   equ 0x08            ; selectors any program could try
KEYBOARD_PORT       equ 0x60            ; the 8042, as any program could know it
GUESS_KERNEL_DATA   equ 0x10
BEYOND_CODE         equ UTEXT_ROOM      ; just past the code segment's limit
FPU_CW_ZERO_DIVIDE  equ 0x037B          ; zero-divide unmasked

begin_udata
crash_fpu_cw        dw FPU_CW_ZERO_DIVIDE
end_udata

; ----------------------------------------------------------------------------
; cmd_crash - find the kind and do it
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      returns only for `crash help` or an unknown kind
;   Destroys: AX, BX, CX, DI
; ----------------------------------------------------------------------------
cmd_crash:
        mov bx, crashes_start
.next:
        mov di, [cs:bx]
        test di, di
        jz .unknown
        call parse_match
        jnc .found
        add bx, CRASH_ENTRY
        jmp .next
.found:
        push si
        mov si, [cs:bx + 4]
        call print_str
        call print_newline
        pop si
        jmp [cs:bx + 2]
.unknown:
        PRINT "crash what? The kinds:"
        mov bx, crashes_start
.list:
        mov si, [cs:bx]
        test si, si
        jz .listed
        PRINT " "
        call print_str
        add bx, CRASH_ENTRY
        jmp .list
.listed:
        jmp print_newline

; ----------------------------------------------------------------------------
; crash_kinds - the crashes themselves, as local labels
;   In:       DS = ES = the program's data
;   Out:      does not return, the kernel restarting the shell (but `fpu`
;             returns on a machine whose 287 raises no error)
;   Destroys: everything
; ----------------------------------------------------------------------------
crash_kinds:
.gp:    jmp BEYOND_CODE                 ; past the code segment's limit: #GP
.ud:    db 0xFF, 0xFF                   ; no such instruction: #UD
.de:    xor ax, ax
        xor dx, dx
.de_f:  div ax                          ; #DE
.ss:    mov sp, 0
.ss_f:  push ax                         ; SP wraps past the stack's limit: #SS
.io:    in al, KEYBOARD_PORT            ; #GP (IOPL 0)
.cli:   cli                             ; #GP (IOPL 0)
.hlt:   hlt                             ; #GP (CPL 3)
.int:   int 0x32                        ; past the IDT's limit: #GP
.kernel: mov ax, GUESS_KERNEL_DATA
.kernel_f: mov ds, ax                   ; DPL 0: #GP
.call:  call GUESS_KERNEL_CODE:0        ; DPL 0: #GP
.write: mov [cs:0], al                  ; code is not writable: #GP
.fpu:   fldcw [crash_fpu_cw]
        fld1
        fldz
        fdivp st1, st0
        fwait                           ; the 287's error: IRQ13
        fninit
        PRINT "crash: no 287 error arrived; is there a 287?", CHAR_LF
        ret
.tf:    pushf
        pop ax
        or ax, FLAGS_TF
        push ax
        popf                            ; single step: #DB after the next instruction
        nop
.tf_after:
        nop
.nt:    pushf
        pop ax
        or ax, FLAGS_NT
        push ax
        popf
.nt_f:  iret                            ; a task return to back link 0: #TS

; The kinds: the word, where it starts, what it tries.
CRASH_ENTRY         equ 6
%macro crash 3
        dw %%word, %2, %%what
    [section udata]
%%word: db %1, 0
%%what: db "crash: ", %3, 0
    __?SECT?__
%endmacro

crashes_start       equ $
        crash "gp", crash_kinds.gp, "jump past the end of my code"
        crash "ud", crash_kinds.ud, "an instruction that does not exist"
        crash "de", crash_kinds.de, "divide by zero"
        crash "ss", crash_kinds.ss, "push past the end of my stack"
        crash "io", crash_kinds.io, "read the keyboard's port myself"
        crash "cli", crash_kinds.cli, "turn interrupts off"
        crash "hlt", crash_kinds.hlt, "halt the CPU"
        crash "int", crash_kinds.int, "INT 32h, beyond the IDT"
        crash "kernel", crash_kinds.kernel, "load the kernel's data selector"
        crash "call", crash_kinds.call, "call into the kernel's code"
        crash "write", crash_kinds.write, "write over my own code"
        crash "fpu", crash_kinds.fpu, "divide by zero on the 287, unmasked"
        crash "tf", crash_kinds.tf, "set the trap flag"
        crash "nt", crash_kinds.nt, "set NT and IRET"
        dw 0
