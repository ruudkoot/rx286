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
%include "kcalls.inc"

FLAGS_TF            equ 0x0100
FLAGS_IOPL3         equ 0x3000
FLAGS_NT            equ 0x4000
SEL_BEYOND_GDT      equ 0x60 | RPL_USER
SEL_PAST_LDT        equ LDT_ENTRIES * 8 | SEL_TI_LDT | RPL_USER    ; one slot past the LDT
SEL_EMPTY_SLOT      equ (LDT_ENTRIES - 1) * 8 | SEL_TI_LDT | RPL_USER  ; its last slot: empty
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
scratch_sector      times SECTOR_SIZE db 0
bounds              dw 0, 5
path_root           db '\', 0
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
.ldt:   mov ax, SEL_PAST_LDT
.ldt_f: mov ds, ax
.kcall: call SEL_KCODE:0
.tss:   jmp SEL_TSS:0
.dftss: call SEL_DFTSS:0
.int32: int 0x32                        ; beyond the IDT's limit
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
.edge:  mov ah, KCALL_TICKS
        jmp edge_of_code                ; INT 31h as the code segment's last bytes
.int30: int 0x30                        ; the system call's gate until l4.md L10: DPL 0
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
; The file calls (roadmap l4.md L9): the OS server's, refused as the
; sectors' are: a buffer the stub checks, then the OS server's own checks
.fnull: push ds                         ; a path through a null DS
        xor ax, ax
        mov ds, ax
        xor si, si
        mov di, scratch_sector
        mov al, DRIVE_A
        sys SYS_FIND
        pop ds
        call report_refusal
        jmp entry
.fcode: push es                         ; a record into the code: not writable
        push cs
        pop es
        xor di, di
        mov si, path_root
        mov al, DRIVE_A
        sys SYS_FIND
        pop es
        call report_refusal
        jmp entry
.flimit: mov di, UDATA_ROOM - PATH_MAX / 2  ; a directory's path across the limit
        mov al, DRIVE_A
        sys SYS_GETCWD
        call report_refusal
        jmp entry
.fdrive: mov si, path_root              ; drive 80h: no such drive
        mov di, scratch_sector
        mov al, 0x80
        sys SYS_FIND
        call report_refusal
        jmp entry
.flong: mov di, scratch_sector          ; a path with no end in the bytes passed
        mov cx, PATH_IN_MAX + 8
        mov al, 'A'
        rep stosb
        mov si, scratch_sector
        mov al, DRIVE_A
        sys SYS_CHDIR
        call report_refusal
        jmp entry
.fnone: mov di, scratch_sector          ; a file's sector, nothing found
        sys SYS_FILE_NEXT
        call report_refusal
        jmp entry
.fsect: push es                         ; a file's sector into the code
        push cs
        pop es
        xor di, di
        sys SYS_FILE_NEXT
        pop es
        call report_refusal
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
; capability but its three segments: each refused, nothing changed.
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
        attack "a selector past the LDT", attacks.ldt
        attack "call the kernel", attacks.kcall
        attack "jump to the TSS", attacks.tss
        attack "call the double-fault TSS", attacks.dftss
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
        attack "write from a null selector", attacks.nullw
        attack "write past FFFFh", attacks.wrap
        attack "unprivileged reads", attacks.reads
        attack "int 31h at the end of the code", attacks.edge
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
        attack "find a path through a null DS", attacks.fnull
        attack "find into the code", attacks.fcode
        attack "a directory's path across the limit", attacks.flimit
        attack "find on drive 80h", attacks.fdrive
        attack "a path with no end", attacks.flong
        attack "a file's sector, nothing found", attacks.fnone
        attack "a file's sector into the code", attacks.fsect
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
