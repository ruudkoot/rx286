; ============================================================================
; rx286 - src/root/root.asm
; The root task (roadmap l4.md L5, L6): the first thread, in ring 2, which
; the kernel builds from the image's first module and gives everything else.
;
; For each other module of the image the root builds a space: the module's
; code, as the kernel gave it; a data segment of the module's room,
; initialised from the module's data as assembled; a stack. The OS server's
; module ("os") gets a space of OS_SLOTS and, for each program, a thread
; that serves that program alone (START_SESSION), on its own part of the
; server's stack, with the program's capabilities in its slots (os.asm).
; Every other module is a program: it gets a thread, an endpoint to the OS
; server badged with its module's number (OS_SLOT_EP) and a transfer
; segment it shares with the server (OS_SLOT_XFER; os.inc), and its faults
; go to the OS server, on the same endpoint badged FAULT_BADGE (l4.md D18).
; The root starts each at the priority the module table gives, the program
; the keys are for in the foreground; then it handles the OS server's
; faults (and a program's, if there is no OS server): it reports each as
; the kernel did ("rx286: os fault #GP(0000) at 0006:0123"), puts back any
; of the module's three segments that is gone from its slot, and restarts it
; at its entry.
;
; Ring 2 gives it nothing that ring 3 lacks (l4.md D12): its capabilities
; are its power. In TEST_CAPS builds it gives the program, in slots 10-13 of
; a space of 64, the rest of the memory for segments and of the arena, its
; own space and its own thread (tests/caps, tests/ipc). TEST_ROOT_REPORT
; builds say how each module was found: where its code is and sums of its
; code and data (tests/root).
; ============================================================================

cpu 286
bits 16
%define RAW_SYSCALLS                    ; INT 30h itself: the root is not the OS server's
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"
%include "os.inc"

RING                equ 2
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the root's, as a selector

MY_SPACE            equ SLOT(ROOT_SLOT_SPACE)
UNTYPED             equ SLOT(ROOT_SLOT_UNTYPED)
ARENA               equ SLOT(ROOT_SLOT_ARENA)
MODULES             equ SLOT(ROOT_SLOT_MODULES)
FAULT_SLOT          equ ROOT_SLOT_MODULE + 2 * (MODULE_MAX - 1)  ; past every module's two
FAULT_EP            equ SLOT(FAULT_SLOT)        ; the fault endpoint
SCRATCH             equ SLOT(FAULT_SLOT + 1)    ; a badged copy on its way
PROGRAM_SLOT        equ FAULT_SLOT + 2          ; then eight slots a module it builds:
P_SPACE             equ 0                       ; its space
P_THREAD            equ 8                       ; its thread
P_DATA              equ 16                      ; its data and stack (the root keeps a
P_STACK             equ 24                      ; copy of each, to put back)
P_EP                equ 32                      ; a program's endpoint to the OS server,
P_XFER              equ 40                      ; its transfer segment, and the OS
P_SERVER            equ 48                      ; server's thread that serves it
PROGRAMS_MAX        equ (ROOT_SLOTS - PROGRAM_SLOT) / 8

; A module's slots in its own space, as selectors (any RPL names a slot)
W_CODE              equ 0x04
W_DATA              equ 0x0C
W_STACK             equ 0x14
W_EP                equ OS_SLOT_EP * 8 + 4
W_XFER              equ OS_SLOT_XFER * 8 + 4
W_MODULES           equ 3 * 8 + 4       ; the OS server's: the module table
OS_SLOTS            equ 64              ; the OS server's space: 8n + k for program n
OS_STACK            equ 512             ; each of its threads' part of its stack
%ifdef TEST_CAPS
CAPS_SLOTS          equ 64              ; the program's, with what TEST_CAPS gives it:
CAPS_UNTYPED        equ 10 * 8 + 4      ; the memory for segments
CAPS_ARENA          equ 11 * 8 + 4      ; the arena
CAPS_SPACE          equ 12 * 8 + 4      ; its own space
CAPS_THREAD         equ 13 * 8 + 4      ; its own thread
%endif

ACC_DATA            equ 0x92            ; present, data, writable: DPL to add
ACC_XFER            equ 0xF2            ; the same, of DPL 3: a transfer segment

begin_udata
programs            dw 0                ; the modules it builds: 1 to programs
foreground          dw 0                ; the one the keys are for
server              dw 0                ; the OS server's module, or 0
server_space        dw 0                ; its space, of the root's
module              dw 0                ; build's: the module, and its entry's fields
m_data_size         dw 0
m_data_room         dw 0
m_stack             dw 0
m_entry             dw 0
m_ring              db 0
m_priority          db 0
m_flags             db 0
s_code              dw 0                ; its slots of the root's (program_slots)
s_template          dw 0
s_space             dw 0
s_thread            dw 0
s_data              dw 0
s_stack             dw 0
s_ep                dw 0
s_xfer              dw 0
s_server            dw 0
line                times 64 db 0       ; a fault's report
end_udata

; must - stop if the last kernel call failed
%macro must 0
        jc failed
%endmacro

; ----------------------------------------------------------------------------
; entry - build and start every module, then handle faults for ever
;   In:       the kernel's start: DS = ES = its data, SS:SP its stack
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        mov dx, ARENA
        mov al, CAP_ENDPOINT
        mov si, FAULT_EP
        kcall KCALL_RETYPE
        must
        mov ax, MODULES
        mov es, ax
        mov cx, [es:MH_COUNT]
        dec cx                          ; but the root itself
        cmp cx, PROGRAMS_MAX
        jbe .count
        mov cx, PROGRAMS_MAX            ; more than its slots: the rest unbuilt
.count:
        mov [programs], cx
        mov bx, 1                       ; the OS server's module: named "os"
.find:
        cmp bx, cx
        ja .found
        call module_entry
        cmp word [es:di + M_NAME], 'os'
        jne .next
        cmp byte [es:di + M_NAME + 2], 0
        jne .next
        mov [server], bx
.next:
        inc bx
        jmp .find
.found:
        push ds
        pop es
        mov bx, 1                       ; the programs' endpoints and transfer segments
.ends:
        cmp bx, [programs]
        ja .ended
        call program_ends
        inc bx
        jmp .ends
.ended:
        mov bx, 1
.build:
        cmp bx, [programs]
        ja .built
        push bx
        call build
        pop bx
        inc bx
        jmp .build
.built:
        call build_server
%ifdef TEST_ROOT_REPORT
        call module_report
%endif
%ifdef TEST_CAPS
        call give_caps
%endif
        ; falls through

; ----------------------------------------------------------------------------
; serve - the fault handler: report a fault, put back what the program
; lost, restart it at its entry; for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov dx, FAULT_EP
        xor bp, bp
        kcall KCALL_RECV
.message:
        jc serve
        push dx                         ; the badge: the module's number
        test di, FAULT_COUNTED
        jnz .quiet
        call report
.quiet:
        pop bx
        call restore                    ; BX = its entry
        mov dx, FAULT_EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; failed - a kernel call the root needs failed: say so, and stop
;   In:       AL = the status
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
failed:
        push ds
        pop es
        xor ah, ah
        push ax
        PRINT "rx286: the root could not build the system: status "
        pop ax
        call print_dec
        call print_newline
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; program_ends - a program's endpoint to the OS server and its transfer
; segment, if there is an OS server and the module is not it
;   In:       BX = the module's number
;   Out:      nothing (stops on a failure)
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
program_ends:
        cmp word [server], 0
        je .done
        cmp bx, [server]
        je .done
        push bx
        call program_slots
        mov dx, ARENA
        mov al, CAP_ENDPOINT
        mov si, [s_ep]
        kcall KCALL_RETYPE
        must
        mov dx, UNTYPED
        mov al, CAP_SEGMENT
        mov si, [s_xfer]
        mov cx, XFER_SIZE
        mov bl, ACC_XFER
        kcall KCALL_RETYPE
        must
        pop bx
.done:
        ret

; ----------------------------------------------------------------------------
; build - a module's space; and for a program, its thread, configured and
; started
;   In:       BX = the module's number (1 or more)
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
build:
        mov [module], bx
        call module_entry               ; ES:DI = its entry
        mov ax, [es:di + M_DATA_SIZE]
        mov [m_data_size], ax
        mov ax, [es:di + M_DATA_ROOM]
        mov [m_data_room], ax
        mov ax, [es:di + M_STACK]
        mov [m_stack], ax
        mov ax, [es:di + M_ENTRY]
        mov [m_entry], ax
        mov al, [es:di + M_RING]
        mov [m_ring], al
        mov al, [es:di + M_PRIORITY]
        mov [m_priority], al
        mov al, [es:di + M_FLAGS]
        mov [m_flags], al
        push ds
        pop es
        call program_slots
        ; its space; a program's thread
        mov cx, OS_SLOTS
        cmp bx, [server]
        je .slots
        mov cx, PROGRAM_SLOTS
        test byte [m_flags], MF_FOREGROUND
        jz .slots
        mov [foreground], bx
%ifdef TEST_CAPS
        mov cx, CAPS_SLOTS
%endif
.slots:
        mov dx, ARENA
        mov al, CAP_SPACE
        mov si, [s_space]
        kcall KCALL_RETYPE
        must
        cmp bx, [server]
        je .space_made
        mov dx, ARENA
        mov al, CAP_THREAD
        mov si, [s_thread]
        kcall KCALL_RETYPE
        must
.space_made:
        ; its code, as the kernel gave it
        mov si, [s_code]
        mov di, W_CODE
        call give
        ; its data: a segment of its room, initialised from the module
        mov si, [s_data]
        mov cx, [m_data_room]
        call new_segment
        mov cx, [m_data_size]
        jcxz .copied
        push ds
        mov ax, [s_data]
        mov es, ax
        mov ax, [s_template]
        mov ds, ax
        xor si, si
        xor di, di
        rep movsb
        pop ds
        push ds
        pop es
.copied:
        mov si, [s_data]
        mov di, W_DATA
        call give
        ; its stack
        mov si, [s_stack]
        mov cx, [m_stack]
        call new_segment
        mov si, [s_stack]
        mov di, W_STACK
        call give
        mov bx, [module]
        cmp bx, [server]
        je .done                        ; its threads come with build_server
        ; the OS server's endpoint and transfer segment; its faults to the
        ; OS server, or to the root if there is none
        mov si, FAULT_EP
        mov dx, bx                      ; the badge
        cmp word [server], 0
        je .faults
        mov dx, [s_space]
        mov si, [s_ep]
        mov di, W_EP
        mov al, COPY_MINT
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        must
        mov si, [s_xfer]
        mov di, W_XFER
        call give
        mov si, [s_ep]
        mov dx, [module]
        or dx, FAULT_BADGE
.faults:
        mov bx, [s_thread]
        call fault_to
        ; configured, and started
        mov dx, [s_thread]
        mov al, THREAD_CONFIGURE
        mov si, [s_space]
        mov bx, [m_entry]
        mov cx, [m_stack]
        kcall KCALL_THREAD
        must
        mov dx, [s_thread]
        mov al, THREAD_START
        mov cl, [m_priority]
        xor ch, ch
        test byte [m_flags], MF_FOREGROUND
        jz .start
        mov ch, START_FOREGROUND
.start:
        kcall KCALL_THREAD
        must
.done:
        ret

; ----------------------------------------------------------------------------
; build_server - the OS server's threads: one for each program, which
; serves it alone, on its own part of the server's stack, with the
; program's capabilities in the server's slots 8n to 8n + 6
;   In:       nothing
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
build_server:
        mov bx, [server]
        test bx, bx
        jz .done
        call program_slots
        mov ax, [s_space]
        mov [server_space], ax
        call module_entry               ; its entry, its stack and priority
        mov ax, [es:di + M_ENTRY]
        mov [m_entry], ax
        mov ax, [es:di + M_STACK]
        mov [m_stack], ax
        mov al, [es:di + M_PRIORITY]
        mov [m_priority], al
        push ds
        pop es
        mov dx, [server_space]          ; the module table
        mov si, MODULES
        mov di, W_MODULES
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov bx, 1
.program:
        cmp bx, [programs]
        ja .done
        cmp bx, [server]
        je .next
        push bx
        call serve_program
        pop bx
.next:
        inc bx
        jmp .program
.done:
        ret

; ----------------------------------------------------------------------------
; serve_program - the OS server's thread for one program, and the program's
; capabilities in the server's slots for it
;   In:       BX = the program's module number
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
serve_program:
        mov ax, bx
        shl ax, 9                       ; OS_STACK: its part's top
        cmp ax, [m_stack]
        ja .done                        ; no room on the server's stack: unserved
        push ax
        call program_slots
        mov di, bx                      ; the server's slots 8n + k, as selectors
        shl di, 6
        add di, 4
        mov si, [s_ep]
        call give_server
        mov si, [s_thread]
        call give_server
        mov si, [s_space]
        call give_server
        mov si, [s_code]
        call give_server
        mov si, [s_data]
        call give_server
        mov si, [s_stack]
        call give_server
        mov si, [s_xfer]
        call give_server
        mov dx, ARENA                   ; its thread
        mov al, CAP_THREAD
        mov si, [s_server]
        kcall KCALL_RETYPE
        must
        mov si, FAULT_EP
        mov dx, [server]
        mov bx, [s_server]
        call fault_to
        mov dx, [s_server]
        mov al, THREAD_CONFIGURE
        mov si, [server_space]
        mov bx, [m_entry]
        pop cx                          ; its stack's top
        kcall KCALL_THREAD
        must
        mov dx, [s_server]
        mov al, THREAD_START
        mov cl, [m_priority]
        mov ch, START_SESSION
        kcall KCALL_THREAD
        must
.done:
        ret

%if OS_STACK != 512
  %error "root.asm: serve_program assumes OS_STACK = 512"
%endif

; ----------------------------------------------------------------------------
; give_server - a capability of the root's copied into the OS server's next
; slot
;   In:       SI = the root's slot; DI = the server's slot
;   Out:      DI the next slot (nothing else; stops on a failure)
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
give_server:
        mov dx, [server_space]
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        add di, 8
        ret

; ----------------------------------------------------------------------------
; fault_to - a thread's faults to an endpoint of the root's, with a badge
;   In:       BX = the thread's slot; SI = the endpoint's; DX = the badge
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, DI
; ----------------------------------------------------------------------------
fault_to:
        push bx
        mov bx, dx
        mov dx, MY_SPACE
        mov di, SCRATCH
        mov al, COPY_MINT
        xor cl, cl
        kcall KCALL_COPY
        must
        pop dx
        mov al, THREAD_FAULT
        mov si, SCRATCH
        kcall KCALL_THREAD
        must
        mov dx, SCRATCH
        kcall KCALL_DELETE
        must
        ret

; ----------------------------------------------------------------------------
; new_segment - a data segment of the module's ring, from the memory for
; segments, into a slot of the root's
;   In:       SI = the slot; CX = bytes
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, DX
; ----------------------------------------------------------------------------
new_segment:
        mov dx, UNTYPED
        mov bl, [m_ring]
        shl bl, 5                       ; its DPL
        or bl, ACC_DATA
        mov al, CAP_SEGMENT
        kcall KCALL_RETYPE
        must
        ret

; ----------------------------------------------------------------------------
; give - a copy of a capability of the root's into the module's space
;   In:       SI = the root's slot; DI = the module's slot
;   Out:      nothing (stops on a failure)
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
give:
        mov dx, [s_space]
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        ret

; ----------------------------------------------------------------------------
; module_entry - a module's entry in the module table
;   In:       BX = the module's number
;   Out:      ES:DI = its entry
;   Destroys: AX
; ----------------------------------------------------------------------------
module_entry:
        mov ax, MODULES
        mov es, ax
        mov di, bx
        shl di, 5                       ; MODULE_ENTRY_SIZE
        add di, MODULE_HEADER_SIZE
        ret

%if MODULE_ENTRY_SIZE != 32
  %error "root.asm: module_entry assumes entries of 32 bytes"
%endif

; ----------------------------------------------------------------------------
; program_slots - a module's slots of the root's: its code and its data as
; assembled (the kernel's gifts), and the eight the root fills for it
;   In:       BX = the module's number (1 to PROGRAMS_MAX)
;   Out:      s_code, s_template, s_space, s_thread, s_data, s_stack, s_ep,
;             s_xfer, s_server
;   Destroys: AX
; ----------------------------------------------------------------------------
program_slots:
        mov ax, bx
        dec ax
        shl ax, 4                       ; 2 slots a module, 8 bytes a slot
        add ax, SLOT(ROOT_SLOT_MODULE)
        mov [s_code], ax
        add ax, 8
        mov [s_template], ax
        mov ax, bx
        dec ax
        shl ax, 6                       ; 8 slots a module
        add ax, SLOT(PROGRAM_SLOT)
        mov [s_space], ax
        add ax, P_THREAD
        mov [s_thread], ax
        add ax, P_DATA - P_THREAD
        mov [s_data], ax
        add ax, P_STACK - P_DATA
        mov [s_stack], ax
        add ax, P_EP - P_STACK
        mov [s_ep], ax
        add ax, P_XFER - P_EP
        mov [s_xfer], ax
        add ax, P_SERVER - P_XFER
        mov [s_server], ax
        ret

; ----------------------------------------------------------------------------
; restore - after a fault: the module's code, data and stack back in their
; slots, for any it deleted (a full slot refuses the copy, which is right)
;   In:       BX = the module's number
;   Out:      BX = its entry
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
restore:
        cmp bx, [programs]              ; the badges are the root's: never else
        ja .entry
        call program_slots
        mov si, [s_code]
        mov di, W_CODE
        call put_back
        mov si, [s_data]
        mov di, W_DATA
        call put_back
        mov si, [s_stack]
        mov di, W_STACK
        call put_back
.entry:
        call module_entry
        mov bx, [es:di + M_ENTRY]
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; put_back - a capability of the root's copied into the module's slot, if
; the slot is empty
;   In:       SI = the root's slot; DI = the module's slot
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
put_back:
        mov dx, [s_space]
        mov al, COPY_COPY
        kcall KCALL_COPY                ; KE_SLOT: it is there
        ret

%ifdef TEST_CAPS
; ----------------------------------------------------------------------------
; give_caps - TEST_CAPS: the program the keys are for gets the rest of the
; memory for segments and of the arena, its own space and its own thread
;   In:       nothing
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, DX, SI, DI
; ----------------------------------------------------------------------------
give_caps:
        mov bx, [foreground]
        test bx, bx
        jz .done
        call program_slots
        mov dx, [s_space]
        mov si, UNTYPED
        mov di, CAPS_UNTYPED
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        mov si, ARENA
        mov di, CAPS_ARENA
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        mov si, [s_space]
        mov di, CAPS_SPACE
        call give
        mov si, [s_thread]
        mov di, CAPS_THREAD
        call give
.done:
        ret
%endif

%ifdef TEST_ROOT_REPORT
; ----------------------------------------------------------------------------
; module_report - TEST_ROOT_REPORT: each module as the root found it, through
; the capabilities the kernel gave it: where its code is (KCALL_SEGMENT),
; and sums of its code and of its data as assembled (tests/root)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
module_report:
        mov bx, 1
.module:
        cmp bx, [programs]
        ja .done
        push bx
        call program_slots
        call module_entry               ; ES:DI = its entry
        push ds
        pop es
        PRINT "root: module "
        push ds
        mov ax, MODULES
        mov ds, ax
        mov si, di                      ; its name (M_NAME: zero-terminated)
        call print_str
        mov cx, [di + M_CODE_SIZE]
        mov bx, [di + M_DATA_SIZE]
        pop ds
        push bx
        push cx
        PRINT ": code at "
        mov dx, [s_code]
        kcall KCALL_SEGMENT             ; DL:AX = its base
        push ax
        mov al, dl
        add al, '0'
        call print_char
        pop ax
        call print_hex16
        PRINT "h, sum "
        pop cx
        mov dx, [s_code]
        call segment_sum
        call print_hex16
        PRINT ", data sum "
        pop cx
        mov dx, [s_template]
        call segment_sum
        call print_hex16
        call print_newline
        pop bx
        inc bx
        jmp .module
.done:
        ret

; ----------------------------------------------------------------------------
; segment_sum - a Fletcher sum of a segment's words, as the boot tests' sum
; of the image (entry.asm)
;   In:       DX = the segment's selector; CX = its bytes (an odd last one
;             left out)
;   Out:      AX = the sum
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
segment_sum:
        push ds
        push si
        mov ds, dx
        xor si, si
        xor bx, bx                      ; the plain sum
        xor ax, ax                      ; the sum of the plain sums
        shr cx, 1
        jcxz .done
.word:
        add bx, [si]
        add ax, bx
        add si, 2
        loop .word
.done:
        pop si
        pop ds
        ret
%endif

; ----------------------------------------------------------------------------
; report - a fault, as the kernel reported one: "rx286: NAME fault #GP(0000)
; at 0007:0123", in one SYS_WRITE
;   In:       AL = the vector; BX = the error code; CX:SI = the CS:IP;
;             DX = the module's number
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
report:
        push si
        push cx
        push bx
        push ax
        push ds
        pop es
        mov di, line
        mov si, text_prefix
        call add_text
        mov bx, dx                      ; the module's name
        push di
        call module_entry               ; ES:DI = its entry
        mov si, di
        pop di
        push ds
        pop es
        push ds
        mov ax, MODULES
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
        mov cx, di
        mov si, line
        sub cx, si
        sys SYS_WRITE
        ret

; ----------------------------------------------------------------------------
; add_text - a zero-terminated text of the root's code to the line
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

VEC_TS              equ 10
VEC_GP              equ 13
text_prefix         db "rx286: ", 0
text_fault          db " fault ", 0
text_at             db " at ", 0
vector_names        db "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
                    db "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 "

%include "uprint.asm"
%include "format.asm"
