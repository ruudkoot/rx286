; ============================================================================
; rx286 - src/os/os.asm
; The OS server (roadmap l4.md L6, D16): today's system calls, as messages,
; and the faults of the programs it serves.
;
; The root builds it in ring 2 with a thread for each program, which serves
; that program alone: the thread's stack is the n-th OS_STACK of the
; server's stack segment, n the program's module number, which is how it
; knows its program. For each program the root gives it, in slots 8n to
; 8n + 7 (OS_K_*): the endpoint the program calls on, the program's thread
; and space, its code, data, stack and transfer segment, and a files
; segment for the program's file calls (files.asm).
;
; A system call comes from the program's stub (src/userland/stub.asm) with
; the function as the label and the registers in the transfer segment's
; block (os.inc). The thread makes the call itself, on the transfer
; segment, with INT 30h, and puts the results back; but the printer's and
; the mouse's calls go to their drivers, whose endpoints the root gave it
; (drivers.inc; l4.md L7), and so does SYS_WAIT's look for the mouse's
; news, once a tick; the disks' calls go to the disk drivers, and the file
; calls are the server's own (files.asm; l4.md L9). SYS_EXIT restarts the
; program (KCALL_THREAD's THREAD_RESTART), and this thread with it, since it
; serves that program alone (START_SESSION).
; A fault of the program comes on the same endpoint, badged FAULT_BADGE: the
; thread reports it as the kernel did, puts back any of the program's
; segments and capabilities that is gone from its slot, and restarts it at
; its entry.
; ============================================================================

cpu 286
bits 16
%define RAW_SYSCALLS                    ; INT 30h itself: it makes the calls
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"
%include "os.inc"
%include "drivers.inc"
%include "disks.inc"

RING                equ 2
OS_STACK            equ 512             ; each thread's part of the stack segment
OS_STACK_SHIFT      equ 9
OS_MODULES          equ 3 * 8 + 4 + RING    ; slot 3: the module table
OS_PRINTER          equ (OS_SLOT_SERVICE + SERVICE_PRINTER) * 8 + 4 + RING
OS_MOUSE            equ (OS_SLOT_SERVICE + SERVICE_MOUSE) * 8 + 4 + RING
OS_CONSOLE          equ (OS_SLOT_SERVICE + SERVICE_CONSOLE) * 8 + 4 + RING
OS_KEYBOARD         equ (OS_SLOT_SERVICE + SERVICE_KEYBOARD) * 8 + 4 + RING
OS_DISKETTE         equ (OS_SLOT_SERVICE + SERVICE_DISKETTE) * 8 + 4 + RING
OS_FIXED_DISK       equ (OS_SLOT_SERVICE + SERVICE_FIXED_DISK) * 8 + 4 + RING
OS_CONTROL          equ 14 * 8 + 4 + RING   ; slot 14: the control notification
OS_FOREGROUND       equ 15 * 8 + 4 + RING   ; slot 15: the foreground program's thread
OS_CONTROL_N        equ 16              ; the control thread's part of the stack
OS_DATA             equ 1 * 8 + 4 + RING    ; its own data, passed to the console
WAIT_EVENTS         equ WAIT_KEY | WAIT_MOUSE | WAIT_SERIAL
OS_K_EP             equ 0               ; a program's slots: 8n + k
OS_K_THREAD         equ 1
OS_K_SPACE          equ 2
OS_K_CODE           equ 3
OS_K_DATA           equ 4
OS_K_STACK          equ 5
OS_K_XFER           equ 6
OS_K_FILES          equ 7               ; its files segment (files.asm), the server's alone
W_CODE              equ 0x04            ; the program's own slots
W_DATA              equ 0x0C
W_STACK             equ 0x14
W_EP                equ OS_SLOT_EP * 8 + 4
W_XFER              equ OS_SLOT_XFER * 8 + 4
VEC_TS              equ 10
VEC_GP              equ 13
LINE_SIZE           equ 64

begin_udata
msg_ctrl_break      db "rx286: Ctrl+Break: the program starts again", CHAR_LF
msg_ctrl_break_end:
end_udata

; ----------------------------------------------------------------------------
; entry - a thread's start: serve its program for ever; or, on the last part
; of the stack, the control thread
;   In:       SP = its program's number * OS_STACK, or OS_CONTROL_N *
;             OS_STACK; DS = ES = the data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        mov ax, sp
        shr ax, OS_STACK_SHIFT
        cmp ax, OS_CONTROL_N
        je control
        push ax                         ; (SP below its top: program_number works)
        ; falls through

; ----------------------------------------------------------------------------
; serve - receive the program's calls and faults, and answer them
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov ax, OS_K_EP
        call program_slot
        mov dx, ax
        xor bp, bp
        kcall KCALL_RECV
.message:
        jc serve
        test dx, FAULT_BADGE
        jnz .fault
        cmp al, SYS_EXIT
        je .exit
        call forward
.reply:
        push bx
        mov ax, OS_K_EP
        call program_slot
        mov dx, ax
        pop bx
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message
.exit:
        call keys_dropped
        mov ax, OS_K_THREAD             ; the program starts again, and this
        call program_slot               ; thread with it: its session
        mov dx, ax
        mov al, THREAD_RESTART
        kcall KCALL_THREAD
        jmp serve
.fault:
        test di, FAULT_COUNTED
        jnz .quiet
        call report
.quiet:
        call keys_dropped
        call restore                    ; BX = its entry
        jmp .reply

; ----------------------------------------------------------------------------
; control - the control thread: Ctrl+Break, which the keyboard driver
; signals, restarts the foreground program (and its thread here with it)
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
control:
        mov dx, OS_CONTROL
        kcall KCALL_RECV
        jc control
        test bx, CONTROL_BREAK
        jz control
        mov si, msg_ctrl_break          ; the log, through the kernel's write
        mov cx, msg_ctrl_break_end - msg_ctrl_break
        mov ah, SYS_WRITE
        int SYSCALL_VECTOR
        mov si, msg_ctrl_break          ; and the screen
        mov cx, msg_ctrl_break_end - msg_ctrl_break
        mov bx, CON_MAIN
        push bp
        mov bp, OS_DATA
        call console
        pop bp
        mov dx, OS_KEYBOARD
        mov al, DRV_KBD_CLEAR
        call driver
        mov dx, OS_FOREGROUND
        mov al, THREAD_RESTART
        kcall KCALL_THREAD
        jmp control

; ----------------------------------------------------------------------------
; keys_dropped - a program starting again: if it is the foreground's, the
; keys it did not read are dropped
;   In:       nothing (the thread's program)
;   Out:      nothing
;   Destroys: AX, DX, DI, ES
; ----------------------------------------------------------------------------
keys_dropped:
        push bx
        push cx
        call module_entry
        test byte [es:di + M_FLAGS], MF_FOREGROUND
        push ds
        pop es
        jz .done
        mov dx, OS_KEYBOARD
        mov al, DRV_KBD_CLEAR
        call driver
.done:
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; driver - a call on a driver, with no capability passed
;   In:       DX = its endpoint; AL = the label; BX CX SI DI the words
;   Out:      CF and AL as KCALL_CALL; BX CX SI DI the reply
;   Destroys: AH
; ----------------------------------------------------------------------------
driver:
        push bp
        xor bp, bp
        kcall KCALL_CALL
        pop bp
        ret

; ----------------------------------------------------------------------------
; console - bytes to the console driver
;   In:       BP:SI = the bytes (BP a segment of the server's, passed); CX =
;             how many; BX = CON_MAIN or CON_STATUS
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
console:
        push bx
        push cx
        push si
        push di
        mov dx, OS_CONSOLE
        mov al, DRV_CON_WRITE
        kcall KCALL_CALL
        pop di
        pop si
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; program_number - the program this thread serves: from where its stack is
;   In:       SP within the thread's part of the stack, below its top
;   Out:      AX = the program's module number
;   Destroys: nothing
; ----------------------------------------------------------------------------
program_number:
        mov ax, sp
        shr ax, OS_STACK_SHIFT
        inc ax
        ret

; ----------------------------------------------------------------------------
; program_slot - a slot of the server's for this thread's program
;   In:       AX = OS_K_*
;   Out:      AX = its selector: slot 8n + k
;   Destroys: nothing
; ----------------------------------------------------------------------------
program_slot:
        push cx
        mov cx, ax
        call program_number
        shl ax, 3
        add ax, cx
        shl ax, 3
        add ax, 4 + RING
        pop cx
        ret

; ----------------------------------------------------------------------------
; forward - the program's system call, made here with INT 30h: its
; registers from its transfer segment's block, its buffer there; the
; results put back in the block
;   In:       AL = the function (the label)
;   Out:      the block's registers and flags
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
forward:
        push ds
        push es
        push ax
        mov ax, OS_K_XFER
        call program_slot
        mov ds, ax
        mov es, ax
        pop ax
        cmp al, SYS_TEST_PROBE          ; the caller's own descriptors: never
        je .nosys                       ; the server's
        cmp al, SYS_PRINT
        je .print
        cmp al, SYS_MOUSE
        je .mouse
        cmp al, SYS_WAIT
        je .wait
        cmp al, SYS_READ_KEY
        je .read_key
        cmp al, SYS_WRITE
        je .write
        cmp al, SYS_DISK_READ
        je .disk
        cmp al, SYS_DISK_WRITE
        je .disk
        cmp al, SYS_FIND
        jb .kernel
        cmp al, SYS_FREE
        ja .kernel
        call files                      ; the file calls: the server's own
        jmp .done
.kernel:
        mov ah, al
        mov al, [XFER_AX]
        mov bx, [XFER_BX]
        mov cx, [XFER_CX]
        mov dx, [XFER_DX]
        mov si, [XFER_SI]
        mov di, [XFER_DI]
        int SYSCALL_VECTOR
        mov [XFER_AX], ax
        mov [XFER_BX], bx
        mov [XFER_CX], cx
        mov [XFER_DX], dx
        mov [XFER_SI], si
        mov [XFER_DI], di
        pushf
        pop word [XFER_FLAGS]
        jmp .done
.nosys:
        mov ax, E_NOSYS
.error:
        mov [XFER_AX], ax
        mov word [XFER_FLAGS], 1        ; CF
.done:
        pop es
        pop ds
        ret
.print:
        ; SYS_PRINT: the printer driver prints from the transfer segment,
        ; after the kernel's checks in the kernel's order
        mov bl, [XFER_AX]
        xor bh, bh
        mov ax, E_INVAL
        cmp bx, PRINTERS
        jae .error
        mov cx, [XFER_CX]
        cmp cx, PRINT_MAX
        ja .error
        mov word [XFER_AX], 0
        mov word [XFER_FLAGS], 0
        jcxz .done
        mov si, [XFER_SI]
        mov ax, si
        add ax, cx
        jc .fault
        cmp ax, XFER_SIZE
        ja .fault                       ; the stub's XFER_BAD
        push bp
        mov ax, OS_K_XFER
        call program_slot
        mov bp, ax                      ; the transfer segment, passed
        mov dx, OS_PRINTER
        mov al, DRV_PRINT
        kcall KCALL_CALL
        pop bp
        jc .nosys
        test bx, bx
        jnz .printed_some
        mov [XFER_AX], cx
        jmp .done
.printed_some:
        mov [XFER_CX], cx               ; the bytes printed before the error
        mov ax, bx
        jmp .error
.fault:
        mov ax, E_FAULT
        jmp .error
.mouse:
        ; SYS_MOUSE: the mouse driver's
        push bp
        mov dx, OS_MOUSE
        mov al, DRV_MOUSE_GET
        xor bp, bp
        kcall KCALL_CALL
        pop bp
        jc .nosys
        mov [XFER_AX], di
        mov [XFER_BX], bx
        mov [XFER_CX], cx
        mov [XFER_DX], si
        mov word [XFER_FLAGS], 0
        jmp .done
.write:
        ; SYS_WRITE: the kernel writes the log and checks as it did; then the
        ; console driver writes the screen: the foreground program's, or the
        ; status line for a program in the background
        mov ah, al
        mov al, [XFER_AX]
        mov cx, [XFER_CX]
        mov si, [XFER_SI]
        int SYSCALL_VECTOR
        mov [XFER_AX], ax
        pushf
        pop word [XFER_FLAGS]
        jc .done
        mov cx, ax
        test cx, cx
        jz .done
        push es
        call module_entry
        mov bl, [es:di + M_FLAGS]
        pop es
        and bx, MF_FOREGROUND
        xor bx, MF_FOREGROUND           ; CON_MAIN (0) for the foreground
        push bp
        mov bp, ds                      ; the transfer segment, passed
        call console
        pop bp
        jmp .done
.disk:
        ; SYS_DISK_READ, SYS_DISK_WRITE: a disk driver's, after the kernel's
        ; checks in the kernel's order: the drive and sector, then the buffer
        mov dl, al
        mov al, [XFER_AX]
        xor ah, ah
        mov bx, ax                      ; BX = the drive
        mov ax, E_INVAL
        cmp bx, DRIVES
        jae .error
        mov cx, [XFER_CX]
        mov si, bx
        shl si, 1
        cmp cx, [cs:drive_sectors + si]
        jae .error
        mov si, [XFER_DI]               ; the buffer: a read's, a write's
        mov al, DRV_DISK_READ
        cmp dl, SYS_DISK_READ
        je .offset
        mov si, [XFER_SI]
        mov al, DRV_DISK_WRITE
.offset:
        cmp si, XFER_SIZE - SECTOR_SIZE
        mov dx, E_FAULT
        ja .disk_fault                  ; the stub's XFER_BAD
        call disk_call                  ; BX = 0 or the error
        test bx, bx
        jz .disk_done
        mov ax, bx
        jmp .error
.disk_fault:
        mov ax, dx
        jmp .error
.disk_done:
        mov word [XFER_FLAGS], 0        ; every register kept
        jmp .done
.read_key:
        ; SYS_READ_KEY: the keyboard driver's ring; a wait asks it once a tick
        mov al, [XFER_AX]
        cmp al, KEY_POLL
        je .poll
        cmp al, KEY_WAIT
        mov ax, E_INVAL
        jne .error
.next_key:
        call key_take
        jnz .key
        mov bl, TEST_READER_FOREVER     ; test builds type now
        call reader
        call tick                       ; until the next tick
        jmp .next_key
.poll:
        call key_take                   ; AX = 0: none
.key:
        mov [XFER_AX], ax
        mov word [XFER_FLAGS], 0
        mov bl, TEST_READER_NONE
        call reader
        jmp .done
.wait:
        ; SYS_WAIT: each event's owner asked once a tick - the keyboard's
        ; and the mouse's drivers, the kernel for COM2's bytes - for CX ticks
        ; at most (0: no limit)
        mov al, [XFER_AX]
        test al, ~WAIT_EVENTS & 0xFF
        jnz .refused                    ; the kernel refuses it (E_INVAL)
        test al, al
        jnz .events_asked
        cmp word [XFER_CX], 0
        jne .events_asked
.refused:
        mov al, SYS_WAIT                ; nothing, for ever: the kernel refuses it
        jmp .kernel
.events_asked:
        mov ah, SYS_TICKS
        int SYSCALL_VECTOR
        push ax                         ; the start
.look:
        call events_there               ; AL = the events there
        test al, al
        jnz .events
        mov bl, TEST_READER_NONE
        test byte [XFER_AX], WAIT_KEY
        jz .readers
        mov bl, TEST_READER_FOREVER
        cmp word [XFER_CX], 0
        je .readers
        mov bl, TEST_READER_TIMED
.readers:
        call reader
        mov al, [XFER_AX]               ; a tick's sleep, COM2's bytes looked for
        and al, WAIT_SERIAL
        mov cx, 1
        mov ah, SYS_WAIT
        int SYSCALL_VECTOR
        test al, al
        jnz .events
        mov cx, [XFER_CX]
        jcxz .look                      ; no limit
        mov ah, SYS_TICKS
        int SYSCALL_VECTOR
        mov bx, sp
        sub ax, [ss:bx]
        cmp ax, cx
        jb .look
        xor al, al                      ; the time ran out
.events:
        pop bx
        xor ah, ah
        mov [XFER_AX], ax
        mov word [XFER_FLAGS], 0
        mov bl, TEST_READER_NONE
        call reader
        jmp .done

; ----------------------------------------------------------------------------
; disk_call - a sector to or from a segment of the server's, through the
; driver of the drive: the diskettes' for A and B, the fixed disks' for C
; and D
;   In:       AL = DRV_DISK_READ or DRV_DISK_WRITE; BX = the drive (checked);
;             CX = the sector (checked); SI = the offset; DS = the segment,
;             passed (the program's transfer segment, or the server's data)
;   Out:      BX = 0 or the error
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
disk_call:
        push bp
        mov bp, ds
        mov dx, OS_DISKETTE
        cmp bx, DRIVE_C
        jb .driver
        sub bx, DRIVE_C
        mov dx, OS_FIXED_DISK
.driver:
        kcall KCALL_CALL
        jnc .out
        mov bx, E_TIMEOUT               ; no driver answered
.out:
        pop bp
        ret

; ----------------------------------------------------------------------------
; events_there - which of SYS_WAIT's events, but COM2's, are there: a key
; waiting at the keyboard driver, the mouse's news at the mouse driver
;   In:       DS = the transfer segment (XFER_AX's AL: the events asked for)
;   Out:      AL = those there
;   Destroys: AH, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
events_there:
        xor ah, ah
        test byte [XFER_AX], WAIT_KEY
        jz .mouse
        push ax
        mov dx, OS_KEYBOARD
        mov al, DRV_KBD_PEEK
        call driver
        pop ax
        jc .mouse
        test bx, bx
        jz .mouse
        or ah, WAIT_KEY
.mouse:
        test byte [XFER_AX], WAIT_MOUSE
        jz .done
        push ax
        mov dx, OS_MOUSE
        mov al, DRV_MOUSE_NEWS
        call driver
        pop ax
        jc .done
        test bx, bx
        jz .done
        or ah, WAIT_MOUSE
.done:
        mov al, ah
        ret

; ----------------------------------------------------------------------------
; key_take - the next key from the keyboard driver's ring
;   In:       nothing
;   Out:      ZF clear and AX = the key (AL ASCII, AH scancode); or ZF set
;             and AX = 0
;   Destroys: BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
key_take:
        mov dx, OS_KEYBOARD
        mov al, DRV_KBD_GET
        call driver
        jc .none
        test bx, bx
        jz .none
        mov ax, cx
        or bx, bx                       ; ZF clear
        ret
.none:
        xor ax, ax                      ; ZF set
        ret

; ----------------------------------------------------------------------------
; tick - sleep until the next tick (the kernel's SYS_WAIT, nothing asked)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
tick:
        xor al, al
        mov cx, 1
        mov ah, SYS_WAIT
        int SYSCALL_VECTOR
        ret

; ----------------------------------------------------------------------------
; reader - test builds: tell the kernel's typing whether a key is awaited
; (KCALL_TEST's TEST_READER; nothing in other builds)
;   In:       BL = TEST_READER_*
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
reader:
%ifdef WITH_TEST_HOOKS
        mov al, TEST_READER
        kcall KCALL_TEST
%endif
        ret

; ----------------------------------------------------------------------------
; restore - after a fault: the program's segments, its endpoint and its
; transfer segment back in their slots, for any it deleted (a full slot
; refuses the copy, which is right)
;   In:       nothing
;   Out:      BX = the program's entry
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
restore:
        mov si, OS_K_CODE
        mov di, W_CODE
        call put_back
        mov si, OS_K_DATA
        mov di, W_DATA
        call put_back
        mov si, OS_K_STACK
        mov di, W_STACK
        call put_back
        mov si, OS_K_XFER
        mov di, W_XFER
        call put_back
        mov ax, OS_K_SPACE              ; its endpoint: minted afresh
        call program_slot
        mov dx, ax
        mov ax, OS_K_EP
        call program_slot
        mov si, ax
        mov di, W_EP
        call program_number
        mov bx, ax
        mov al, COPY_MINT
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        call module_entry               ; ES:DI = its entry in the module table
        mov bx, [es:di + M_ENTRY]
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; put_back - a capability of the server's copied into the program's slot, if
; the slot is empty
;   In:       SI = OS_K_* of the server's; DI = the program's slot
;   Out:      nothing
;   Destroys: AX, DX, SI
; ----------------------------------------------------------------------------
put_back:
        mov ax, OS_K_SPACE
        call program_slot
        mov dx, ax
        mov ax, si
        call program_slot
        mov si, ax
        mov al, COPY_COPY
        kcall KCALL_COPY                ; KE_SLOT: it is there
        ret

; ----------------------------------------------------------------------------
; module_entry - this thread's program's entry in the module table
;   In:       nothing
;   Out:      ES:DI = the entry
;   Destroys: AX
; ----------------------------------------------------------------------------
module_entry:
        mov ax, OS_MODULES
        mov es, ax
        call program_number
        mov di, ax
        shl di, 5                       ; MODULE_ENTRY_SIZE
        add di, MODULE_HEADER_SIZE
        ret

%if MODULE_ENTRY_SIZE != 32
  %error "os.asm: module_entry assumes entries of 32 bytes"
%endif

; ----------------------------------------------------------------------------
; report - a fault, as the kernel reported one: "rx286: NAME fault #GP(0000)
; at 0007:0123", in one SYS_WRITE from a line built on the thread's stack
;   In:       AL = the vector; BX = the error code; CX:SI = the CS:IP
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
report:
        push bp
        mov bp, sp
        sub sp, LINE_SIZE
        push si                         ; [bp - LINE_SIZE - 2] IP
        push cx                         ; CS
        push bx                         ; the error code
        push ax                         ; the vector
        push ss
        pop es
        lea di, [bp - LINE_SIZE]
        mov si, text_prefix
        call add_text
        push di                         ; the module's name
        call module_entry
        mov si, di
        pop di
        push ds
        push ss
        pop es
        mov ax, OS_MODULES
        mov ds, ax
        mov cx, M_NAME_SIZE - 1
.name:
        lodsb
        test al, al
        jz .named
        stosb
        loop .name
.named:
        pop ds
        mov si, text_fault
        call add_text
        pop ax                          ; the vector's name
        push ax
        xor ah, ah
        mov si, ax
        shl si, 2
        add si, vector_names
        mov cx, 4
.vector:
        mov al, [cs:si]
        cmp al, ' '
        je .named_vector
        stosb
        inc si
        loop .vector
.named_vector:
        pop ax
        pop bx
        cmp al, VEC_TS                  ; the vectors with an error code
        jb .at
        cmp al, VEC_GP
        ja .at
        mov al, '('
        stosb
        mov ax, bx
        call fmt_hex16
        mov al, ')'
        stosb
.at:
        mov si, text_at
        call add_text
        pop ax                          ; CS
        call fmt_hex16
        mov al, ':'
        stosb
        pop ax                          ; IP
        call fmt_hex16
        mov al, CHAR_LF
        stosb
        lea si, [bp - LINE_SIZE]
        mov cx, di
        sub cx, si
        push ds
        push ss
        pop ds
        sys SYS_WRITE                   ; the log
        pop ds
        push cx                         ; the screen: through the transfer
        mov ax, OS_K_XFER               ; segment, idle while its program waits
        call program_slot
        mov es, ax
        mov di, XFER_DATA
        push ds
        push ss
        pop ds
        rep movsb
        pop ds
        pop cx
        mov si, XFER_DATA
        mov bx, CON_MAIN
        push bp
        mov bp, es
        call console
        pop bp
        push ds
        pop es
        mov sp, bp
        pop bp
        ret

; ----------------------------------------------------------------------------
; add_text - a zero-terminated text of the server's code to the line
;   In:       CS:SI = the text; ES:DI = where in the line
;   Out:      DI past it
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
add_text:
        mov al, [cs:si]
        test al, al
        jz .done
        stosb
        inc si
        jmp add_text
.done:
        ret

drive_sectors       dw DISK_A_CYLINDERS * DISK_A_HEADS * DISK_A_SECTORS     ; each drive's
                    dw DISK_B_CYLINDERS * DISK_B_HEADS * DISK_B_SECTORS
                    dw DISK_C_CYLINDERS * DISK_C_HEADS * DISK_C_SECTORS
                    dw DISK_D_CYLINDERS * DISK_D_HEADS * DISK_D_SECTORS
text_prefix         db "rx286: ", 0
text_fault          db " fault ", 0
text_at             db " at ", 0
vector_names        db "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
                    db "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 "

%include "fat12.asm"
%include "fatname.asm"
%include "files.asm"
%include "format.asm"
