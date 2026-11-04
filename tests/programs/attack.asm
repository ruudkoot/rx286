; ============================================================================
; rx286 - tests/programs/attack.asm
; The attack suite's program: one forbidden thing per start (roadmap M6, M8).
;
; At each start it takes the next attack from its table (its data segment
; survives the kernel's restarts), prints the attack's name, and runs it. An
; attack that faults is reported by the kernel, which starts the program
; again; one that does not prints what happened and moves on. When the table
; is done it says so and waits for a key, which ends the test.
; tests/attack/attacks.test holds what each attack must give; docs/security.md
; explains them. Bochs is not a 286: where the two differ, this file says.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "selectors.inc"
%include "program.inc"

FLAGS_TF            equ 0x0100
FLAGS_IOPL3         equ 0x3000
FLAGS_NT            equ 0x4000
SEL_BEYOND_GDT      equ 0x60 | RPL_USER
SEL_LDT_ENTRY       equ 0x08 | 0x04 | RPL_USER  ; index 1, TI = 1
FPU_CW_ZM           equ 0x037B          ; zero-divide unmasked

begin_udata
next_attack         dw 0
scratch             times 8 db 0
scratch_sector      times SECTOR_SIZE db 0
bounds              dw 0, 5
fpu_cw              dw FPU_CW_ZM
end_udata

; ----------------------------------------------------------------------------
; entry - run the next attack, or end
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        mov bx, [next_attack]
        inc word [next_attack]
        mov si, attack_table
.find:
        cmp word [si], 0
        je .done                        ; past the last attack
        test bx, bx
        jz .found
        add si, 2                       ; skip this entry: its address, its name
.skip:
        lodsb
        test al, al
        jnz .skip
        dec bx
        jmp .find
.found:
        mov bx, [si]
        add si, 2
        call print_str
        call print_newline
        jmp bx
.done:
        PRINT "attack: done", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; attacks - the attacks, each a local label; the kernel restarts the program
; after each one that faults
;   In:       DS = ES = the program's data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
attacks:
.cli:   cli
.sti:   sti
.in:    in al, KBC_DATA
.out:   out SYS_PORT_B, al
.hlt:   hlt
.lgdt:  lgdt [scratch]
.lidt:  lidt [scratch]
.lmsw:  lmsw ax
.clts:  clts
.ltr:   mov ax, SEL_TSS
.ltr_f: ltr ax
.lldt:  xor ax, ax
.lldt_f: lldt ax
.kdata: mov ax, SEL_KDATA
.kdata_f: mov ds, ax
.kstack: mov ax, SEL_KSTACK
.kstack_f: mov ss, ax
.video: mov ax, SEL_VIDEO
.video_f: mov es, ax
.beyond: mov ax, SEL_BEYOND_GDT
.beyond_f: mov es, ax
.ldt:   mov ax, SEL_LDT_ENTRY
.ldt_f: mov ds, ax
.kcall: call SEL_KCODE:0
.tss:   jmp SEL_TSS:0
.dftss: call SEL_DFTSS:0
.int31: int 0x31                        ; beyond the IDT's limit
.int21: int 0x21                        ; IRQ1's gate: DPL 0
.int3:  int3
.into:  mov al, 127
        add al, 1                       ; OF set
.into_f: into
.wcode: mov [cs:0], al                  ; code is not writable
.limit: mov ax, [UDATA_ROOM]            ; past the data segment's limit
.word:  mov ax, [UDATA_ROOM - 1]        ; a word across the limit
.stack: mov sp, 0
.stack_f: push ax                       ; SP wraps to FFFEh, past USTACK's limit
.exec:  jmp SEL_UDATA:0                 ; data is not code
.div:   xor ax, ax
        xor dx, dx
.div_f: div ax
.ud:    db 0xFF, 0xFF                   ; FF /7: no such instruction
.bound: mov ax, 9
.bound_f: bound ax, [bounds]
.tf:    pushf
        pop ax
        or ax, FLAGS_TF
        push ax
        popf
        nop                             ; the trap comes after this instruction
.tf_after:
        nop
.tfgp:  pushf
        pop ax
        or ax, FLAGS_TF
        push ax
        popf
.tfgp_f: cli                            ; faults with a single step pending: a 286
                                        ; delivers the trap after the fault, in ring 0
.nt:    pushf
        pop ax
        or ax, FLAGS_NT
        push ax
        popf
        push word SEL_UCODE
        push word 0
.nt_f:  iret                            ; a task return to back link 0
.iopl:  pushf
        pop ax
        or ax, FLAGS_IOPL3              ; ignored at CPL 3
        push ax
        popf
.iopl_f: cli
.lock:  lock add [scratch], al          ; a 286 faults (CPL > IOPL); Bochs runs it
        PRINT "attack: lock ran without a fault (not a 286)", CHAR_LF
        jmp entry
.loadall: db 0x0F, 0x05                 ; LOADALL on a 286; SYSCALL, #UD, on Bochs
.fpu:   fldcw [fpu_cw]
        fld1
        fldz
        fdivp st1, st0
        fwait                           ; Bochs raises IRQ13 here
        PRINT "attack: no 287 error arrived (no 287 emulated?)", CHAR_LF
        jmp entry
.write: mov si, UDATA_ROOM - 2
        mov cx, 4
        sys SYS_WRITE                   ; refused: past the limit
        call report_refusal
        jmp entry
.ins:   mov dx, KBC_DATA
.ins_f: insb                            ; IOPL 0
.outs:  mov dx, SYS_PORT_B
        xor si, si
.outs_f: outsb                          ; IOPL 0
.nullss: xor ax, ax
.nullss_f: mov ss, ax                   ; a null SS
.nulljmp: jmp SEL_NULL:0                ; a far jump through the null selector
.pop:   mov sp, USTACK_SIZE
.pop_f: pop ax                          ; past the stack's top
.fpuop: fld tword [UDATA_ROOM - 4]      ; a 287 operand across the limit:
        fwait                           ; #MP (vector 9) on a 286, #GP on Bochs
        PRINT "attack: the 287 read across the limit (no 287 emulated?)", CHAR_LF
        jmp entry
.nullw: push ds
        xor ax, ax
        mov ds, ax
        xor si, si
        mov cx, 1
        sys SYS_WRITE                   ; refused: a null selector
        pop ds
        call report_refusal
        jmp entry
.wrap:  mov si, 0xFFF0
        mov cx, 0x20
        sys SYS_WRITE                   ; refused: past FFFFh
        call report_refusal
        jmp entry
.reads: sidt [scratch]                  ; unprivileged on the 286: all allowed
        str ax
        sldt ax
        mov bx, cs
        lar ax, bx
        lsl ax, bx
        verr bx
        verw bx
        arpl ax, bx
        PRINT "attack: sidt, str, sldt, lar, lsl, verr, verw, arpl allowed", CHAR_LF
        jmp entry
.edge:  mov ah, SYS_TICKS
        jmp edge_of_code                ; INT 30h as the code segment's last bytes
.sgdt:  sgdt [scratch]                  ; unprivileged on the 286: allowed
        PRINT "attack: sgdt allowed", CHAR_LF
        jmp entry
.smsw:  smsw ax                         ; unprivileged on the 286: allowed
        PRINT "attack: smsw allowed", CHAR_LF
        jmp entry
.dcode: push es                         ; a sector into the code: not writable
        push cs
        pop es
        xor di, di
        jmp disk_read_attack
.dnull: push es                         ; a sector through a null ES
        xor ax, ax
        mov es, ax
        xor di, di
        jmp disk_read_attack
.dlimit: push es                        ; a sector across the data's limit
        mov di, UDATA_ROOM - SECTOR_SIZE / 2
        jmp disk_read_attack
.dwrap: push es                         ; a sector at FF00h: past the limit, and
        mov di, 0x10000 - SECTOR_SIZE / 2   ; past FFFFh (the limit refuses it first)
        jmp disk_read_attack
.dwnull: push ds                        ; a sector written from a null DS
        xor ax, ax
        mov ds, ax
        xor si, si
        mov al, DRIVE_B
        xor cx, cx
        sys SYS_DISK_WRITE
        pop ds
        call report_refusal
        jmp entry
.pnull: push ds                         ; printed from a null DS
        xor ax, ax
        mov ds, ax
        xor si, si
        mov al, PRINTER_LPT1
        mov cx, 1
        sys SYS_PRINT
        pop ds
        call report_refusal
        jmp entry
.drive: push es                         ; drive 80h: no such drive
        mov di, scratch_sector
        mov al, 0x80
        xor cx, cx
        sys SYS_DISK_READ
        pop es
        call report_refusal
        jmp entry
.sector: push es                        ; sector FFFFh: past A's end
        mov di, scratch_sector
        mov al, DRIVE_A
        mov cx, 0xFFFF
        sys SYS_DISK_READ
        pop es
        call report_refusal
        jmp entry

.scode: push es                         ; the modem's bytes into the code
        push cs
        pop es
        xor di, di
        jmp serial_read_attack
.slimit: push es                        ; across the data's limit
        mov di, UDATA_ROOM - 2
        jmp serial_read_attack
.snull: push es                         ; through a null ES
        xor ax, ax
        mov es, ax
        xor di, di
        jmp serial_read_attack
.swnull: push ds                        ; to the modem from a null DS
        xor ax, ax
        mov ds, ax
        xor si, si
        mov cx, 1
        sys SYS_SERIAL_WRITE
        pop ds
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; serial_read_attack - SYS_SERIAL_READ of 4 bytes into ES:DI, reported
;   In:       ES:DI = the buffer; the program's ES pushed by the attack
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
serial_read_attack:
        mov cx, 4
        sys SYS_SERIAL_READ
        pop es
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; disk_read_attack - SYS_DISK_READ of A's sector 0 into ES:DI, reported
;   In:       ES:DI = the buffer; the program's ES pushed by the attack
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
disk_read_attack:
        mov al, DRIVE_A
        xor cx, cx
        sys SYS_DISK_READ
        pop es
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; report_refusal - "attack: refused, error N" after a system call
;   In:       CF and AX as the call returned them
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_refusal:
        jnc .accepted
        PRINT "attack: refused, error "
        call print_dec
        call print_newline
        ret
.accepted:
        PRINT "attack: ACCEPTED", CHAR_LF
        ret

begin_udata
; Each attack: where it starts, then its name; a zero word ends the table.
%macro attack 2
        dw %2
        db "attack: ", %1, 0
%endmacro
attack_table:
        attack "cli", attacks.cli
        attack "sti", attacks.sti
        attack "in", attacks.in
        attack "out", attacks.out
        attack "hlt", attacks.hlt
        attack "lgdt", attacks.lgdt
        attack "lidt", attacks.lidt
        attack "lmsw", attacks.lmsw
        attack "clts", attacks.clts
        attack "ltr", attacks.ltr
        attack "lldt", attacks.lldt
        attack "kernel data", attacks.kdata
        attack "kernel stack", attacks.kstack
        attack "video", attacks.video
        attack "beyond the GDT", attacks.beyond
        attack "an LDT selector", attacks.ldt
        attack "call the kernel", attacks.kcall
        attack "jump to the TSS", attacks.tss
        attack "call the double-fault TSS", attacks.dftss
        attack "int 31h", attacks.int31
        attack "int 21h", attacks.int21
        attack "int 3", attacks.int3
        attack "into", attacks.into
        attack "write code", attacks.wcode
        attack "past the limit", attacks.limit
        attack "a word across the limit", attacks.word
        attack "stack overflow", attacks.stack
        attack "execute data", attacks.exec
        attack "divide by zero", attacks.div
        attack "invalid opcode", attacks.ud
        attack "bound", attacks.bound
        attack "trap flag", attacks.tf
        attack "the trap flag and a fault", attacks.tfgp
        attack "NT and iret", attacks.nt
        attack "IOPL through popf", attacks.iopl
        attack "lock", attacks.lock
        attack "loadall", attacks.loadall
        attack "287 error", attacks.fpu
        attack "write past the limit", attacks.write
        attack "insb", attacks.ins
        attack "outsb", attacks.outs
        attack "a null SS", attacks.nullss
        attack "jump through the null selector", attacks.nulljmp
        attack "pop past the stack's top", attacks.pop
        attack "a 287 operand across the limit", attacks.fpuop
        attack "write from a null selector", attacks.nullw
        attack "write past FFFFh", attacks.wrap
        attack "unprivileged reads", attacks.reads
        attack "int 30h at the end of the code", attacks.edge
        attack "sgdt", attacks.sgdt
        attack "smsw", attacks.smsw
        attack "read a sector into the code", attacks.dcode
        attack "read a sector through a null ES", attacks.dnull
        attack "read a sector across the limit", attacks.dlimit
        attack "read a sector at FF00h", attacks.dwrap
        attack "write a sector from a null selector", attacks.dwnull
        attack "print from a null selector", attacks.pnull
        attack "read drive 80h", attacks.drive
        attack "read sector FFFFh of A", attacks.sector
        attack "read the modem into the code", attacks.scode
        attack "read the modem across the limit", attacks.slimit
        attack "read the modem through a null ES", attacks.snull
        attack "write to the modem from a null selector", attacks.swnull
        dw 0
end_udata

%include "uprint.asm"
%include "format.asm"

; The last two bytes of the code segment: the system call returns to IP
; UTEXT_ROOM, past the limit, and IRET would fault in ring 0 (M10).
        times UTEXT_ROOM - 2 - ($ - $$) db 0
; ----------------------------------------------------------------------------
; edge_of_code - INT 30h as the code segment's last two bytes
;   In:       AH = a system call (attacks.edge)
;   Out:      does not return: the kernel finds the return IP past the limit
;   Destroys: what the call destroys
; ----------------------------------------------------------------------------
edge_of_code:
        int SYSCALL_VECTOR
