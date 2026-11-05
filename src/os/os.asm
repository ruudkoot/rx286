; ============================================================================
; rx286 - src/os/os.asm
; The OS server (roadmap l4.md L6, D16): today's system calls, as messages,
; and the faults of the programs it serves.
;
; The root builds it in ring 2 with a thread for each program, which serves
; that program alone: the thread's stack is the n-th OS_STACK of the
; server's stack segment, n the program's module number, which is how it
; knows its program. For each program the root gives it, in slots 8n to
; 8n + 6 (OS_K_*): the endpoint the program calls on, the program's thread
; and space, and its code, data, stack and transfer segment.
;
; A system call comes from the program's stub (src/userland/stub.asm) with
; the function as the label and the registers in the transfer segment's
; block (os.inc). The thread makes the call itself, on the transfer
; segment, with INT 30h, and puts the results back: so far only the path
; has moved. SYS_EXIT restarts the program (KCALL_THREAD's THREAD_RESTART),
; and this thread with it, since it serves that program alone (START_SESSION).
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

RING                equ 2
OS_STACK            equ 512             ; each thread's part of the stack segment
OS_STACK_SHIFT      equ 9
OS_MODULES          equ 3 * 8 + 4 + RING    ; slot 3: the module table
OS_K_EP             equ 0               ; a program's slots: 8n + k
OS_K_THREAD         equ 1
OS_K_SPACE          equ 2
OS_K_CODE           equ 3
OS_K_DATA           equ 4
OS_K_STACK          equ 5
OS_K_XFER           equ 6
W_CODE              equ 0x04            ; the program's own slots
W_DATA              equ 0x0C
W_STACK             equ 0x14
W_EP                equ OS_SLOT_EP * 8 + 4
W_XFER              equ OS_SLOT_XFER * 8 + 4
VEC_TS              equ 10
VEC_GP              equ 13
LINE_SIZE           equ 64

begin_udata
end_udata

; ----------------------------------------------------------------------------
; entry - a thread's start: serve its program for ever
;   In:       SP = its program's number * OS_STACK; DS = ES = the data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
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
        call restore                    ; BX = its entry
        jmp .reply

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
        mov word [XFER_AX], E_NOSYS
        mov word [XFER_FLAGS], 1        ; CF
.done:
        pop es
        pop ds
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
        sys SYS_WRITE
        pop ds
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

text_prefix         db "rx286: ", 0
text_fault          db " fault ", 0
text_at             db " at ", 0
vector_names        db "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
                    db "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 "

%include "format.asm"
