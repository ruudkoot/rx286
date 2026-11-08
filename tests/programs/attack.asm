; ============================================================================
; rx286 - tests/programs/attack.asm
; The attack suite's program: one forbidden thing per start (roadmap M6, M8).
;
; At each start it takes the next attack from its table (its data segment
; survives the kernel's restarts), prints the attack's name, and runs it. An
; attack that faults is a call on its fault endpoint, the OS server, which
; reports it as the kernel would and whose reply starts the program again;
; one that does not prints what happened and moves on. When the table is
; done it says so and waits for a key, which ends the test.
; tests/attack/attacks.test holds what each attack must give; docs/security.md
; explains them. Bochs is not a 286: where the two differ, this file says.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "selectors.inc"
%include "program.inc"
%include "kcalls.inc"
%include "os.inc"

FLAGS_TF            equ 0x0100
FLAGS_IOPL3         equ 0x3000
FLAGS_NT            equ 0x4000
SEL_BEYOND_GDT      equ (GDT_LIMIT + 1) | RPL_USER                  ; one past the GDT
SEL_PAST_LDT        equ PROGRAM_SLOTS * 8 | SEL_TI_LDT | RPL_USER   ; one slot past its LDT
SEL_EMPTY_SLOT      equ (PROGRAM_SLOTS - 1) * 8 | SEL_TI_LDT | RPL_USER ; its last slot: empty
GDT_LAST            equ GDT_LIMIT - 7 | RPL_USER                    ; the GDT's last selector
FPU_CW_ZM           equ 0x037B          ; zero-divide unmasked

; probe which - KCALL_TEST's TEST_PROBE: the kernel changes one of the
; program's own descriptors before it returns
%macro probe 1
        mov bl, %1
        mov al, TEST_PROBE
        kcall KCALL_TEST
%endmacro

begin_udata
next_attack         dw 0
scratch             times 8 db 0
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
        call read_key
        jmp .wait

; ----------------------------------------------------------------------------
; attacks - the attacks, each a local label; the OS server's reply restarts
; the program after each one that faults. A GDT selector is loaded at RPL 3,
; the program's: a load checks RPL against CPL before DPL, so an RPL of 0
; would fault whatever the DPL (os-server.md P15)
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
.kdata: mov ax, SEL_KDATA | RPL_USER
.kdata_f: mov ds, ax
.kstack: mov ax, SEL_KSTACK | RPL_USER
.kstack_f: mov ss, ax
.video: mov ax, SEL_VIDEO | RPL_USER
.video_f: mov es, ax
.beyond: mov ax, SEL_BEYOND_GDT
.beyond_f: mov es, ax
.ldt:   mov ax, SEL_PAST_LDT
.ldt_f: mov ds, ax
.kcall: call (SEL_KCODE | RPL_USER):0
.tss:   jmp (SEL_TSS | RPL_USER):0       ; busy: refused as busy, whatever its DPL
.dftss: call (SEL_DFTSS | RPL_USER):0    ; available: refused for its DPL alone
.gdt:   mov bx, 8 | RPL_USER            ; every selector of the GDT, LAR, VERR, VERW
        jmp gdt_selectors
.int32: int 0x32                        ; beyond the IDT's limit (.reads: 018Fh)
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
        fwait                           ; Bochs raises IRQ13 here: the fault #MF
.fpu_f:                                 ;    here (os-server.md P12)
        PRINT "attack: no 287 error arrived (no 287 emulated?)", CHAR_LF
        jmp entry
.write: mov bx, 1                       ; the standard output, from bytes
        mov si, UDATA_ROOM - 2          ;    across the data's limit
        mov cx, 4
        px PX_WRITE                     ; refused: EFAULT
        call report_errno
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
.overrun: mov al, TEST_OVERRUN          ; vector 9 in ring 0, as a 287's overrun
        kcall KCALL_TEST                ; arrives after the CPU moved on, which no
        PRINT "attack: back from the overrun, not restarted", CHAR_LF
        jmp entry                       ; emulator here raises: restarted
.wrap:  mov bx, 1
        mov si, 0xFFF0                  ; bytes past FFFFh
        mov cx, 0x20
        px PX_WRITE                     ; refused: EFAULT
        call report_errno
        jmp entry
; The kernel's own buffer check (check_buffer, log.asm), which no call on
; the server reaches: KCALL_LOG of bytes across a limit, or past FFFFh
.logd:  mov si, UDATA_ROOM - 2          ; across the data's limit
        jmp log_attack
.logs:  push ds
        mov ax, SEL_USTACK              ; across the stack's limit
        mov ds, ax
        mov si, USTACK_SIZE - 2
        mov cx, 4
        kcall KCALL_LOG
        pop ds
        call report_refusal
        jmp entry
.logw:  mov si, 0xFFF0                  ; past FFFFh
        mov cx, 0x20
        kcall KCALL_LOG
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
        PRINT "attack: sidt, str, sldt, lar, lsl, verr, verw, arpl allowed; the IDT's limit "
        mov ax, [scratch]               ; vectors 0-31h: INT 32h is past it
        call print_hex16
        call print_newline
        jmp entry
.edge:  mov ah, KCALL_TICKS
        jmp edge_of_code                ; INT 31h as the code segment's last bytes
.int30: int 0x30                        ; the system call's gate until l4.md L10: DPL 0
.sgdt:  sgdt [scratch]                  ; unprivileged on the 286: allowed
        PRINT "attack: sgdt allowed; the GDT's limit "
        mov ax, [scratch]               ; 2000h: past it (.beyond)
        call print_hex16
        call print_newline
        jmp entry
.smsw:  smsw ax                         ; unprivileged on the 286: allowed
        PRINT "attack: smsw allowed", CHAR_LF
        jmp entry
; The calls on the OS server (roadmap os-server.md P14): a buffer is an
; offset in the program's data, which the server checks against its limit;
; no selector is passed, so none can be forged. The server answers a program
; the root builds four calls alone.
.rlimit: xor bx, bx                     ; a key read into bytes across the limit:
        mov di, UDATA_ROOM - 1          ;    refused before it waits, EFAULT
        mov cx, 2
        px PX_READ
        call report_errno
        jmp entry
.badfd: mov bx, 5                       ; a descriptor it has not: EBADF
        mov si, scratch
        mov cx, 1
        px PX_WRITE
        call report_errno
        jmp entry
.open:  mov si, scratch                 ; a process's call: ENOSYS
        xor bx, bx
        px PX_OPEN
        call report_errno
        jmp entry
.pxnone: px 0xFF                        ; no such call: ENOSYS
        call report_errno
        jmp entry
.empty: mov ax, SEL_EMPTY_SLOT          ; an empty slot of the LDT: all zeros
.empty_f: mov ds, ax
.slots: mov bx, SEL_UCODE               ; what ring 3 learns of every LDT slot
        jmp ldt_slots
; The probes (roadmap l4.md L1): the kernel changes one of the program's
; descriptors during a kernel call (KCALL_TEST's TEST_PROBE), as a
; revocation would. On the way back a DS it may no longer load becomes
; null, and a CS or SS is the program's fault, reported at the return
; address.
.pds:   probe PROBE_DS_ABSENT
.pds_f: mov ax, [0]                     ; DS is null now
.pdsx:  probe PROBE_DS_EXEC
.pdsx_f: mov ax, [0]
.pss:   probe PROBE_SS_ABSENT
.pss_r: PRINT "attack: back, with a stack not present", CHAR_LF
        jmp entry
.pssr:  probe PROBE_SS_READONLY
.pssr_r: PRINT "attack: back, with a read-only stack", CHAR_LF
        jmp entry
.pcs:   probe PROBE_CS_ABSENT
.pcs_r: PRINT "attack: back, with code not present", CHAR_LF
        jmp entry
.pcsd:  probe PROBE_CS_DATA
.pcsd_r: PRINT "attack: back, with data for code", CHAR_LF
        jmp entry
; The kernel's calls (roadmap l4.md L3), from a program that holds no
; capability but its three segments and its endpoint to the server: each
; refused, and its slots after them as before them (the second listing).
.kgdt:  mov dx, SEL_KDATA               ; a GDT selector: no one's slot
        jmp retype_attack
.kown:  mov dx, SEL_UDATA               ; its own data: not untyped
        jmp retype_attack
.kempty: mov dx, SEL_EMPTY_SLOT         ; an empty slot
        jmp retype_attack
.kpast: mov dx, SEL_PAST_LDT            ; past its LDT
        jmp retype_attack
.kcopy: mov dx, SEL_UCODE               ; its code, as a space to copy into
        mov si, SEL_UDATA
        mov di, SEL_EMPTY_SLOT
        mov al, COPY_COPY
        kcall KCALL_COPY
        call report_refusal
        jmp entry
.kthread: mov dx, SEL_UDATA             ; its data, as a thread to start
        mov al, THREAD_START
        mov cx, 7
        kcall KCALL_THREAD
        call report_refusal
        jmp entry
.knone: mov ah, 0x80                    ; no such call
        int KCALL_VECTOR
        call report_refusal
        jmp entry
.seal_data: mov dx, SEL_UDATA           ; its data made code, to run (os-server.md P2):
        jmp seal_attack                 ; the root keeps a copy
.seal_stack: mov dx, SEL_USTACK         ; its stack, likewise
        jmp seal_attack
.seal_code: mov dx, SEL_UCODE           ; its code: no data to seal
        jmp seal_attack
.seal_gdt: mov dx, SEL_KDATA            ; a GDT selector
        jmp seal_attack

; ----------------------------------------------------------------------------
; log_attack - KCALL_LOG of 4 bytes at SI of the data, reported
;   In:       SI = where
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
log_attack:
        mov cx, 4
        kcall KCALL_LOG
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; gdt_selectors - every selector of the GDT at RPL 3, from BX to the last:
; each that LAR, VERR or VERW does not refuse is printed (every descriptor
; of the GDT has DPL 0: none may be), then how it ended
;   In:       BX = the first selector
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
gdt_selectors:
        xor dx, dx                      ; how many were not refused
.next:
        lar ax, bx
        jz .open
        verr bx
        jz .open
        verw bx
        jnz .step
.open:
        inc dx
        PRINT "attack: GDT selector "
        mov ax, bx
        call print_hex16
        PRINT " not refused", CHAR_LF
.step:
        add bx, 8
        cmp bx, GDT_LAST
        jbe .next
        test dx, dx
        jnz .done
        PRINT "attack: every selector of the GDT refused", CHAR_LF
.done:
        jmp entry

; ----------------------------------------------------------------------------
; seal_attack - KCALL_SEAL of DX, reported
;   In:       DX = the selector given as the segment
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
seal_attack:
        kcall KCALL_SEAL
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; retype_attack - KCALL_RETYPE from DX into the empty slot, reported
;   In:       DX = the selector given as the untyped
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
retype_attack:
        mov al, CAP_ENDPOINT
        mov si, SEL_EMPTY_SLOT
        kcall KCALL_RETYPE
        call report_refusal
        jmp entry

; ----------------------------------------------------------------------------
; ldt_slots - every slot of the program's LDT as ring 3 sees it: LAR's
; access rights (FFFF if refused), LSL's limit (FFFF if refused), r if VERR
; passes, w if VERW does
;   In:       BX = the first slot's selector
;   Out:      does not return: the next attack
;   Destroys: everything
; ----------------------------------------------------------------------------
ldt_slots:
        PRINT "attack: slot "
        mov ax, bx
        call print_hex16
        PRINT " lar "
        mov ax, 0xFFFF
        lar ax, bx
        call print_hex16
        PRINT " lsl "
        mov ax, 0xFFFF
        lsl ax, bx
        call print_hex16
        mov al, ' '
        call print_char
        mov al, '-'
        verr bx
        jnz .read
        mov al, 'r'
.read:  call print_char
        mov al, '-'
        verw bx
        jnz .write
        mov al, 'w'
.write: call print_char
        call print_newline
        add bx, 8
        cmp bx, SEL_PAST_LDT
        jb ldt_slots
        jmp entry

; ----------------------------------------------------------------------------
; report_errno - "attack: refused, errno N" after a call on the OS server
;   In:       BX and CX as the call returned them
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
report_errno:
        cmp bx, -1
        jne .accepted
        PRINT "attack: refused, errno "
        mov ax, cx
        call print_dec
        call print_newline
        ret
.accepted:
        PRINT "attack: ACCEPTED", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; report_refusal - "attack: refused, error N" after a kernel call
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
        attack "a selector past the LDT", attacks.ldt
        attack "call the kernel", attacks.kcall
        attack "jump to the TSS", attacks.tss
        attack "call the double-fault TSS", attacks.dftss
        attack "every selector of the GDT", attacks.gdt
        attack "int 32h", attacks.int32
        attack "int 30h, the system call that was", attacks.int30
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
        attack "a 287 overrun in the kernel (vector 9)", attacks.overrun
        attack "write past FFFFh", attacks.wrap
        attack "log bytes across the data's limit", attacks.logd
        attack "log bytes across the stack's limit", attacks.logs
        attack "log bytes past FFFFh", attacks.logw
        attack "unprivileged reads", attacks.reads
        attack "int 31h at the end of the code", attacks.edge
        attack "sgdt", attacks.sgdt
        attack "smsw", attacks.smsw
        attack "read a key past the limit", attacks.rlimit
        attack "write to a descriptor it has not", attacks.badfd
        attack "open, a process's call", attacks.open
        attack "a call on the server that does not exist", attacks.pxnone
        attack "an empty slot of the LDT", attacks.empty
        attack "every slot of the LDT", attacks.slots
        attack "probe: data not present", attacks.pds
        attack "probe: execute-only code for data", attacks.pdsx
        attack "probe: stack not present", attacks.pss
        attack "probe: read-only stack", attacks.pssr
        attack "probe: code not present", attacks.pcs
        attack "probe: data for code", attacks.pcsd
        attack "retype from a GDT selector", attacks.kgdt
        attack "retype from its own data", attacks.kown
        attack "retype from an empty slot", attacks.kempty
        attack "retype from past its LDT", attacks.kpast
        attack "copy into its code, as a space", attacks.kcopy
        attack "start its data, as a thread", attacks.kthread
        attack "a kernel call that does not exist", attacks.knone
        attack "seal its own data, to run it", attacks.seal_data
        attack "seal its stack", attacks.seal_stack
        attack "seal its code", attacks.seal_code
        attack "seal a GDT selector", attacks.seal_gdt
        attack "every slot of the LDT, after the kernel's calls", attacks.slots
        dw 0
end_udata

%include "uprint.asm"
%include "format.asm"

; The last two bytes of the code segment: the kernel call returns to IP
; UTEXT_ROOM, past the limit, and IRET would fault in ring 0 (M10).
        times UTEXT_ROOM - 2 - ($ - $$) db 0
; ----------------------------------------------------------------------------
; edge_of_code - INT 31h as the code segment's last two bytes
;   In:       AH = a kernel call (attacks.edge)
;   Out:      does not return: the kernel finds the return IP past the limit
;   Destroys: what the call destroys
; ----------------------------------------------------------------------------
edge_of_code:
        int KCALL_VECTOR
