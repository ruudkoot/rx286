; ============================================================================
; rx286 - src/root/root.asm
; The root task (roadmap l4.md L5): the first thread, in ring 2, which the
; kernel builds from the image's first module and gives everything else.
;
; For each other module of the image the root builds a space and a thread:
; the module's code, as the kernel gave it; a data segment of the module's
; room, initialised from the module's data as assembled; a stack; and
; itself as their fault handler (l4.md D18), through its fault endpoint
; minted with the module's number as the badge. It starts each at the
; priority the module table gives, the program the keys are for in the
; foreground. Then it waits for faults: it reports each as the kernel did
; ("rx286: program fault #GP(0000) at 0007:0123", the module's name for
; "program"), puts back any of the program's three segments that is gone
; from its slot, and restarts it at its entry.
;
; Ring 2 gives it nothing that ring 3 lacks (l4.md D12): its capabilities
; are its power. In TEST_CAPS builds it gives the program, in slots 8-11 of
; a space of 32, the rest of the memory for segments and of the arena, its
; own space and its own thread (tests/caps, tests/ipc). TEST_ROOT_REPORT
; builds say how each module was found: where its code is and sums of its
; code and data (tests/root).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

RING                equ 2
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the root's, as a selector

MY_SPACE            equ SLOT(ROOT_SLOT_SPACE)
UNTYPED             equ SLOT(ROOT_SLOT_UNTYPED)
ARENA               equ SLOT(ROOT_SLOT_ARENA)
MODULES             equ SLOT(ROOT_SLOT_MODULES)
FAULT_SLOT          equ ROOT_SLOT_MODULE + 2 * (MODULE_MAX - 1)  ; past every module's two
FAULT_EP            equ SLOT(FAULT_SLOT)        ; the fault endpoint
SCRATCH             equ SLOT(FAULT_SLOT + 1)    ; a badged copy on its way
PROGRAM_SLOT        equ FAULT_SLOT + 2          ; then four slots a program it builds:
P_SPACE             equ 0                       ; its space
P_THREAD            equ 8                       ; its thread
P_DATA              equ 16                      ; its data and stack (the root keeps a
P_STACK             equ 24                      ; copy of each, to put back)
PROGRAMS_MAX        equ (ROOT_SLOTS - PROGRAM_SLOT) / 4

; A program's slots in its own space, as selectors (any RPL names a slot)
W_CODE              equ 0x04
W_DATA              equ 0x0C
W_STACK             equ 0x14
PROGRAM_SLOTS       equ SPACE_SLOTS_MIN
%ifdef TEST_CAPS
CAPS_SLOTS          equ 32              ; the program's, with what TEST_CAPS gives it:
CAPS_UNTYPED        equ 0x44            ; slot 8: the memory for segments
CAPS_ARENA          equ 0x4C            ; slot 9: the arena
CAPS_SPACE          equ 0x54            ; slot 10: its own space
CAPS_THREAD         equ 0x5C            ; slot 11: its own thread
%endif

ACC_DATA            equ 0x92            ; present, data, writable: DPL to add

begin_udata
programs            dw 0                ; the modules it builds: 1 to programs
foreground          dw 0                ; the one the keys are for
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
line                times 64 db 0       ; a fault's report
end_udata

; must - stop if the last kernel call failed
%macro must 0
        jc failed
%endmacro

; ----------------------------------------------------------------------------
; entry - build and start every module, then handle their faults for ever
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
        push ds
        pop es
        dec cx                          ; but the root itself
        cmp cx, PROGRAMS_MAX
        jbe .count
        mov cx, PROGRAMS_MAX            ; more than its slots: the rest unbuilt
.count:
        mov [programs], cx
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
; build - a module's space and thread, configured and started
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
        ; its space and thread
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
        mov dx, ARENA
        mov al, CAP_THREAD
        mov si, [s_thread]
        kcall KCALL_RETYPE
        must
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
        ; its faults: to the root, badged with its number
        mov dx, MY_SPACE
        mov si, FAULT_EP
        mov di, SCRATCH
        mov al, COPY_MINT
        mov bx, [module]
        xor cl, cl
        kcall KCALL_COPY
        must
        mov dx, [s_thread]
        mov al, THREAD_FAULT
        mov si, SCRATCH
        kcall KCALL_THREAD
        must
        mov dx, SCRATCH
        kcall KCALL_DELETE
        must
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
; give - a copy of a capability of the root's into the program's space
;   In:       SI = the root's slot; DI = the program's slot
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
; assembled (the kernel's gifts), and the four the root fills for it
;   In:       BX = the module's number (1 to PROGRAMS_MAX)
;   Out:      s_code, s_template, s_space, s_thread, s_data, s_stack
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
        shl ax, 5                       ; 4 slots a program
        add ax, SLOT(PROGRAM_SLOT)
        mov [s_space], ax
        add ax, P_THREAD
        mov [s_thread], ax
        add ax, P_DATA - P_THREAD
        mov [s_data], ax
        add ax, P_STACK - P_DATA
        mov [s_stack], ax
        ret

; ----------------------------------------------------------------------------
; restore - after a fault: the program's code, data and stack back in their
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
; put_back - a capability of the root's copied into the program's slot, if
; the slot is empty
;   In:       SI = the root's slot; DI = the program's slot
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
