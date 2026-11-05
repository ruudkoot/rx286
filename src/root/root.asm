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
; segment it shares with the server (OS_SLOT_XFER; os.inc); the server
; alone gets the program's files segment (FILES_SIZE); and its faults go to
; the OS server, on the same endpoint badged FAULT_BADGE (l4.md D18).
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
%define KERNEL_LOG                      ; its lines: the kernel's log, not the OS server's
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"
%include "os.inc"
%include "drivers.inc"

RING                equ 2
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the root's, as a selector

MY_SPACE            equ SLOT(ROOT_SLOT_SPACE)
UNTYPED             equ SLOT(ROOT_SLOT_UNTYPED)
ARENA               equ SLOT(ROOT_SLOT_ARENA)
MODULES             equ SLOT(ROOT_SLOT_MODULES)
FAULT_SLOT          equ ROOT_SLOT_MODULE + 2 * (MODULE_MAX - 1)  ; past every module's two
FAULT_EP            equ SLOT(FAULT_SLOT)        ; the fault endpoint
SCRATCH             equ SLOT(FAULT_SLOT + 1)    ; a badged copy on its way
CHILD_SLOT          equ FAULT_SLOT + 2      ; a background program's own untyped: two a
                                                ; module, the arena's and the memory's
CHILD_ARENA_PARAS   equ 2560 >> 4               ; its space, thread, endpoint, OS thread,
                                                ; notification, each aligned to its size
PROGRAM_SLOT        equ ROOT_SLOT_IRQ + 16      ; past the kernel's gifts (the 16 lines), eight
                                                ; slots a module it builds:
P_SPACE             equ 0                       ; its space
P_THREAD            equ 8                       ; its thread
P_DATA              equ 16                      ; its data and stack (the root keeps a
P_STACK             equ 24                      ; copy of each, to put back)
P_EP                equ 32                      ; a program's endpoint to the OS server,
P_XFER              equ 40                      ; its transfer segment, and the OS
P_SERVER            equ 48                      ; server's thread that serves it,
P_FILES             equ 56                      ; and its files segment, the server's
CONTROL             equ SLOT(ROOT_SLOT_VIDEO - 1)  ; the OS server's control notification
PROGRAMS_MAX        equ MODULE_MAX - 1          ; every module but the root
%if PROGRAM_SLOT + 8 * PROGRAMS_MAX > ROOT_SLOTS
  %error "root.asm: its space has no room for every module's slots"
%endif
%if CHILD_SLOT + 2 * PROGRAMS_MAX > ROOT_SLOT_VIDEO - 1
  %error "root.asm: its space has no room for every module's untyped"
%endif

; A module's slots in its own space, as selectors (any RPL names a slot)
W_CODE              equ 0x04
W_DATA              equ 0x0C
W_STACK             equ 0x14
W_EP                equ OS_SLOT_EP * 8 + 4
W_XFER              equ OS_SLOT_XFER * 8 + 4
W_MODULES           equ 3 * 8 + 4       ; the OS server's: the module table
W_DRV_EP            equ DRV_SLOT_EP * 8 + 4     ; a driver's
W_DRV_NOTIFY        equ DRV_SLOT_NOTIFY * 8 + 4
W_DRV_IRQ           equ DRV_SLOT_IRQ * 8 + 4
W_DRV_DEVICE        equ DRV_SLOT_DEVICE * 8 + 4
W_SOUND_STOP        equ 13 * 8 + 4      ; the OS server's: the sound driver's notification,
W_CONTROL           equ 14 * 8 + 4      ;    its control notification,
W_FOREGROUND        equ 15 * 8 + 4      ;    the foreground program's thread
OS_CONTROL_N        equ 16              ; its control thread's part of its stack
OS_SLOTS            equ 256             ; the OS server's space: 8n + k for program n,
OS_SLOT_SLEEP       equ 128             ;    and n's thread's notification at 128 + n
DRIVER_SLOTS        equ DRV_SLOTS       ; a driver's space (drivers.inc)
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
ACC_FILES           equ 0xD2            ; of DPL 2: the OS server's files segment

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
m_irq               db 0
m_service           db 0
s_code              dw 0                ; its slots of the root's (program_slots)
s_template          dw 0
s_space             dw 0
s_thread            dw 0
s_data              dw 0
s_stack             dw 0
s_ep                dw 0
s_xfer              dw 0
s_server            dw 0
s_files             dw 0
ut_arena            dw ARENA            ; the untyped a module's objects come from: the
ut_memory           dw UNTYPED          ; root's, or a background program's own
info_state          dw 0                ; request's: THREAD_INFO's BX and CX
info_runs           dw 0
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
        mov dx, ARENA                   ; the OS server's control notification,
        mov al, CAP_NOTIFY              ; which the keyboard driver signals
        mov si, CONTROL
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
        call children_make              ; a background program's own untyped
        call use_untyped
        call program_ends
        inc bx
        jmp .ends
.ended:
        mov bx, 1
.build:
        cmp bx, [programs]
        ja .built
        push bx
        call use_untyped
        call build
        pop bx
        inc bx
        jmp .build
.built:
        mov word [ut_arena], ARENA
        mov word [ut_memory], UNTYPED
        call build_server
        mov word [ut_arena], ARENA
        mov word [ut_memory], UNTYPED
%ifdef TEST_ROOT_REPORT
        call module_report
%endif
%ifdef TEST_CAPS
        call give_caps
%endif
        ; falls through

; ----------------------------------------------------------------------------
; serve - the fault handler: report a fault, put back what the program
; lost, restart it at its entry; and the OS server's requests for its
; programs (l4.md L11), on the same endpoint; for ever
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
        cmp dx, ROOT_BADGE_OS
        jne .fault
        call request                    ; BX CX SI DI the reply
        mov dx, FAULT_EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message
.fault:
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
; request - the OS server's request about a module (os.inc): what runs it,
; or a background program stopped or started again
;   In:       AL = ROOT_INFO, ROOT_KILL or ROOT_START; BX = the module
;   Out:      BX = 0 or the error; ROOT_INFO: CL the kind, CH the state, SI
;             the priority, DI the times it ran
;   Destroys: AX, DX, ES
; ----------------------------------------------------------------------------
request:
        push ax
        call module_kind                ; AL = the kind; DX = its thread
        mov cl, al
        pop ax
        jc .invalid
        push ax
        push bx
        push cx
        push dx
        mov al, THREAD_INFO
        kcall KCALL_THREAD              ; BL the state, BH the priority, CX the runs
        mov [info_state], bx
        mov [info_runs], cx
        pop dx
        pop cx
        pop bx
        pop ax                          ; CF: no thread (a program killed)
        mov ch, 1
        jnc .alive
        xor ch, ch
.alive:
        cmp al, ROOT_INFO
        je .info
        cmp cl, PS_BACKGROUND
        jne .invalid                    ; only a background program
        cmp al, ROOT_KILL
        je .kill
        cmp al, ROOT_START
        jne .invalid
        test ch, ch
        jnz .busy                       ; running already
        call program_build              ; built again, from its own untyped
        xor bx, bx
        ret
.kill:
        test ch, ch
        jz .busy                        ; killed already
        call program_kill
        xor bx, bx
        ret
.busy:
        mov bx, E_BUSY
        ret
.info:
        test ch, ch
        jnz .thread
        call module_entry               ; killed: stopped, at its priority
        mov al, [es:di + M_PRIORITY]
        push ds
        pop es
        mov ah, al
        mov al, STATE_STOPPED
        mov [info_state], ax
        mov word [info_runs], 0
.thread:
        mov ax, [info_state]
        mov di, [info_runs]
        mov ch, al                      ; the state (CL the kind)
        mov al, ah
        xor ah, ah
        mov si, ax                      ; the priority
        xor bx, bx
        ret
.invalid:
        mov bx, E_INVAL
        ret

; ----------------------------------------------------------------------------
; program_kill - a background program killed (roadmap l4.md L12): its own
; untyped revoked, so that everything made for it dies - its space, thread,
; endpoint, segments, the OS server's thread for it and every copy of them -
; and its memory is free again; and every copy of its code
;   In:       BX = the module; its s_* (program_slots)
;   Out:      nothing
;   Destroys: AX, DX, SI, DI
; ----------------------------------------------------------------------------
program_kill:
        call children_slots             ; SI, DI = its untyped
        mov dx, si
        kcall KCALL_REVOKE
        mov dx, di
        kcall KCALL_REVOKE
        mov dx, [s_code]
        kcall KCALL_REVOKE
        ret

; ----------------------------------------------------------------------------
; program_build - a background program killed, built again from its own
; untyped as at the start: its endpoint, transfer and files segments, space,
; data, stack and thread, and the OS server's thread for it
;   In:       BX = the module
;   Out:      nothing (stops on a failure)
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
program_build:
        push bx
        call use_untyped
        call program_ends
        pop bx
        push bx
        call build
        pop bx
        push bx
        call server_params
        call serve_program
        pop bx
        mov word [ut_arena], ARENA
        mov word [ut_memory], UNTYPED
        ret

; ----------------------------------------------------------------------------
; server_params - the OS server's entry, stack and priority, for its threads
;   In:       [server]
;   Out:      m_entry, m_stack, m_priority
;   Destroys: AX, DI, ES
; ----------------------------------------------------------------------------
server_params:
        push bx
        mov bx, [server]
        call module_entry
        mov ax, [es:di + M_ENTRY]
        mov [m_entry], ax
        mov ax, [es:di + M_STACK]
        mov [m_stack], ax
        mov al, [es:di + M_PRIORITY]
        mov [m_priority], al
        push ds
        pop es
        pop bx
        ret

; ----------------------------------------------------------------------------
; children_slots - a background program's own untyped, in the root's slots
;   In:       BX = the module
;   Out:      SI = the arena's untyped, DI = the memory's (selectors)
;   Destroys: nothing
; ----------------------------------------------------------------------------
children_slots:
        mov si, bx
        dec si
        shl si, 4                       ; two slots of eight bytes a module
        add si, SLOT(CHILD_SLOT)
        lea di, [si + 8]
        ret

; ----------------------------------------------------------------------------
; children_make - a background program's own untyped, at the start: from
; the arena's, room for its kernel objects; from the memory's, for its data,
; stack, transfer and files segments; so that killing it gives them back
;   In:       BX = the module
;   Out:      nothing (stops on a failure)
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
children_make:
        call module_kind
        jc .done
        cmp al, PS_BACKGROUND
        jne .done
        call children_slots
        push di
        mov dx, ARENA
        mov al, CAP_UNTYPED
        mov cx, CHILD_ARENA_PARAS
        kcall KCALL_RETYPE
        must
        call module_entry
        mov ax, [es:di + M_DATA_ROOM]
        call paragraphs
        mov cx, ax
        mov ax, [es:di + M_STACK]
        call paragraphs
        add cx, ax
        add cx, (XFER_SIZE + 15) >> 4
        add cx, (FILES_SIZE + 15) >> 4
        push ds
        pop es
        pop si
        mov dx, UNTYPED
        mov al, CAP_UNTYPED
        kcall KCALL_RETYPE
        must
.done:
        ret

; ----------------------------------------------------------------------------
; paragraphs - bytes as paragraphs, rounded up (0 bytes: 64 KB)
;   In:       AX = bytes
;   Out:      AX = paragraphs
;   Destroys: nothing
; ----------------------------------------------------------------------------
paragraphs:
        add ax, 15
        rcr ax, 1                       ; (a carry is bit 16)
        shr ax, 3
        ret

; ----------------------------------------------------------------------------
; use_untyped - where a module's objects come from: a background program's
; own untyped, else the root's
;   In:       BX = the module
;   Out:      ut_arena, ut_memory
;   Destroys: nothing
; ----------------------------------------------------------------------------
use_untyped:
        push ax
        push dx
        push si
        push di
        push es
        mov word [ut_arena], ARENA
        mov word [ut_memory], UNTYPED
        call module_kind
        jc .done
        cmp al, PS_BACKGROUND
        jne .done
        call children_slots
        mov [ut_arena], si
        mov [ut_memory], di
.done:
        pop es
        pop di
        pop si
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; module_kind - what a module is, and its main thread
;   In:       BX = the module's number
;   Out:      CF clear, AL = PS_*, DX = its thread's slot of the root's; or
;             CF set: no such module (or not built)
;   Destroys: AH, ES
; ----------------------------------------------------------------------------
module_kind:
        test bx, bx
        jnz .other
        mov al, PS_ROOT
        mov dx, SLOT(ROOT_SLOT_THREAD)
        clc
        ret
.other:
        cmp bx, [programs]
        ja .none
        push di
        call program_slots
        mov dx, [s_thread]
        call module_entry
        mov ah, [es:di + M_FLAGS]
        push ds
        pop es
        pop di
        mov al, PS_OS
        cmp bx, [server]
        je .kind
        mov al, PS_DRIVER
        test ah, MF_DRIVER
        jnz .kind
        mov al, PS_FOREGROUND
        test ah, MF_FOREGROUND
        jnz .kind
        mov al, PS_BACKGROUND
.kind:
        clc
        ret
.none:
        stc
        ret

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
        mov dx, FAULT_EP                ; a receive that is never answered: the
        xor bp, bp                      ; faults of what it built wait with it
        kcall KCALL_RECV
        jmp .wait

; ----------------------------------------------------------------------------
; program_ends - a program's endpoint to the OS server, its transfer
; segment and its files segment, if there is an OS server and the module is
; neither it nor a driver
;   In:       BX = the module's number
;   Out:      nothing (stops on a failure)
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
program_ends:
        cmp word [server], 0
        je .done
        cmp bx, [server]
        je .done
        call module_entry
        test byte [es:di + M_FLAGS], MF_DRIVER
        push ds
        pop es
        jnz .done                       ; a driver: its endpoint comes with build
        push bx
        call program_slots
        mov dx, [ut_arena]
        mov al, CAP_ENDPOINT
        mov si, [s_ep]
        kcall KCALL_RETYPE
        must
        mov dx, [ut_memory]
        mov al, CAP_SEGMENT
        mov si, [s_xfer]
        mov cx, XFER_SIZE
        mov bl, ACC_XFER
        kcall KCALL_RETYPE
        must
        mov dx, [ut_memory]
        mov al, CAP_SEGMENT
        mov si, [s_files]
        mov cx, FILES_SIZE
        mov bl, ACC_FILES
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
        mov al, [es:di + M_IRQ]
        mov [m_irq], al
        mov al, [es:di + M_SERVICE]
        mov [m_service], al
        push ds
        pop es
        call program_slots
        ; its space; a program's thread
        mov cx, OS_SLOTS
        cmp bx, [server]
        je .slots
        mov cx, DRIVER_SLOTS
        test byte [m_flags], MF_DRIVER
        jnz .slots
        mov cx, PROGRAM_SLOTS
        test byte [m_flags], MF_FOREGROUND
        jz .slots
        mov [foreground], bx
%ifdef TEST_CAPS
        mov cx, CAPS_SLOTS
%endif
.slots:
        mov dx, [ut_arena]
        mov al, CAP_SPACE
        mov si, [s_space]
        kcall KCALL_RETYPE
        must
        cmp bx, [server]
        je .space_made
        mov dx, [ut_arena]
        mov al, CAP_THREAD
        mov si, [s_thread]
        kcall KCALL_RETYPE
        must
.space_made:
        ; its code, as the kernel gave it
        mov si, [s_code]
        mov di, W_CODE
        call give
        ; its data: a segment of its room, initialised from the module; of
        ; the root's ring at the most, so that the root can fill it
        mov al, [m_ring]
        cmp al, RING
        jae .data_ring
        mov al, RING
.data_ring:
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
        ; its stack, of its ring
        mov al, [m_ring]
        mov si, [s_stack]
        mov cx, [m_stack]
        call new_segment
        mov si, [s_stack]
        mov di, W_STACK
        call give
        mov bx, [module]
        cmp bx, [server]
        je .done                        ; its threads come with build_server
        test byte [m_flags], MF_DRIVER
        jz .program
        call build_driver
        mov si, FAULT_EP                ; a driver's faults: the root's
        mov dx, [module]
        jmp .faults
.program:
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
        jz .iopl
        or ch, START_FOREGROUND
.iopl:
        test byte [m_flags], MF_DRIVER | MF_IOPL
        jz .start
        or ch, START_IOPL               ; the kernel grants it to ring 1 only
.start:
        kcall KCALL_THREAD
        must
.done:
        ret

; ----------------------------------------------------------------------------
; build_driver - a driver's endpoint, which it serves; its notification,
; bound to its thread, which its timer signals and its interrupt line (if it
; has one) too, with DRV_IRQ_BIT (drivers.inc; l4.md L7)
;   In:       the module's s_* and m_*
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
build_driver:
        mov dx, ARENA
        mov al, CAP_ENDPOINT
        mov si, [s_ep]
        kcall KCALL_RETYPE
        must
        mov si, [s_ep]
        mov di, W_DRV_EP
        call give
        mov dx, ARENA                   ; (in its transfer segment's slot: it has none)
        mov al, CAP_NOTIFY
        mov si, [s_xfer]
        kcall KCALL_RETYPE
        must
        mov si, [s_xfer]
        mov di, W_DRV_NOTIFY
        call give
        mov dx, [s_thread]
        mov al, THREAD_BIND
        mov si, [s_xfer]
        kcall KCALL_THREAD
        must
        call driver_device
        mov bl, [m_irq]
        test bl, bl
        jz .done
        dec bl                          ; the line
        xor bh, bh
        shl bx, 3
        add bx, SLOT(ROOT_SLOT_IRQ)
        push bx
        mov si, bx
        mov di, W_DRV_IRQ
        call give
        mov dx, MY_SPACE                ; bound with a copy badged DRV_IRQ_BIT
        mov si, [s_xfer]
        mov di, SCRATCH
        mov al, COPY_MINT
        mov bx, DRV_IRQ_BIT
        xor cl, cl
        kcall KCALL_COPY
        must
        pop dx
        mov al, IRQ_BIND
        mov si, SCRATCH
        kcall KCALL_IRQ
        must
        mov dx, SCRATCH
        kcall KCALL_DELETE
        must
.done:
        ret

; ----------------------------------------------------------------------------
; driver_device - what a driver's service needs besides (DRV_SLOT_DEVICE):
; the console's, the screen's text page; the keyboard's, the OS server's
; control notification to signal Ctrl+Break with; the diskette's, a DMA
; buffer of a sector that does not cross 64 KB
;   In:       the module's s_* and m_*
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
driver_device:
        cmp byte [m_service], SERVICE_CONSOLE
        jne .keyboard
        mov si, SLOT(ROOT_SLOT_VIDEO)
        mov di, W_DRV_DEVICE
        jmp give
.keyboard:
        cmp byte [m_service], SERVICE_KEYBOARD
        jne .diskette
        mov dx, [s_space]
        mov si, CONTROL
        mov di, W_DRV_DEVICE
        mov al, COPY_MINT
        mov bx, CONTROL_BREAK
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        must
        ret
.diskette:
        cmp byte [m_service], SERVICE_DISKETTE
        jne .done
.dma:
        mov si, [s_server]              ; (a driver has no OS thread: the slot is free)
        mov cx, SECTOR_SIZE
        mov al, 1                       ; DPL 1: the driver's
        call new_segment
        mov dx, [s_server]
        kcall KCALL_SEGMENT             ; DL:AX = its physical address
        cmp ax, 0x10000 - SECTOR_SIZE
        jbe .within                     ; the 8237 does not carry past 64 KB
        mov dx, [s_server]
        kcall KCALL_DELETE              ; (its memory stays: the next is past it)
        jmp .dma
.within:
        mov si, [s_server]
        mov di, W_DRV_DEVICE
        jmp give
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
        call server_control
        mov dx, [server_space]          ; its requests about the programs, on the
        mov si, FAULT_EP                ; fault endpoint, badged so
        mov di, OS_SLOT_ROOT * 8 + 4
        mov al, COPY_MINT
        mov bx, ROOT_BADGE_OS
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        must
        mov bx, 1
.program:
        cmp bx, [programs]
        ja .done
        cmp bx, [server]
        je .next
        push bx
        call module_entry
        mov al, [es:di + M_FLAGS]
        mov cl, [es:di + M_SERVICE]
        push ds
        pop es
        test al, MF_DRIVER
        jz .serve
        call give_service
        jmp .served
.serve:
        push bx
        call use_untyped
        call serve_program
        pop bx
.served:
        pop bx
.next:
        inc bx
        jmp .program
.done:
        ret

; ----------------------------------------------------------------------------
; server_control - the OS server's control thread, on the last part of its
; stack, with the control notification and the foreground program's thread
;   In:       m_entry, m_stack, m_priority the server's; server_space
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
server_control:
        mov dx, [server_space]
        mov si, CONTROL
        mov di, W_CONTROL
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov bx, [foreground]
        test bx, bx
        jz .thread
        call program_slots
        mov dx, [server_space]
        mov si, [s_thread]
        mov di, W_FOREGROUND
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
.thread:
        mov ax, OS_CONTROL_N * OS_STACK
        cmp ax, [m_stack]
        ja .done                        ; no room on its stack
        mov bx, [server]
        call program_slots              ; its thread: the server module's slot
        mov dx, ARENA
        mov al, CAP_THREAD
        mov si, [s_thread]
        kcall KCALL_RETYPE
        must
        mov si, FAULT_EP
        mov dx, [server]
        mov bx, [s_thread]
        call fault_to
        mov dx, [s_thread]
        mov al, THREAD_CONFIGURE
        mov si, [server_space]
        mov bx, [m_entry]
        mov cx, OS_CONTROL_N * OS_STACK
        kcall KCALL_THREAD
        must
        mov dx, [s_thread]
        mov al, THREAD_START
        mov cl, [m_priority]
        xor ch, ch
        kcall KCALL_THREAD
        must
.done:
        ret

; ----------------------------------------------------------------------------
; give_service - a driver's endpoint to the OS server, in the slot its
; service names (OS_SLOT_SERVICE + service; drivers.inc); and the sound
; driver's notification, badged DRV_STOP_BIT, for Ctrl+Break
;   In:       BX = the driver's module number; CL = its service (0: none)
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
give_service:
        test cl, cl
        jz .done
        call program_slots
        mov di, OS_SLOT_SERVICE
        add di, cx
        and di, 0xFF
        shl di, 3
        add di, 4
        mov si, [s_ep]
        mov dx, [server_space]
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        cmp cl, SERVICE_SOUND
        jne .done
        mov dx, [server_space]          ; the sound driver's notification, for
        mov si, [s_xfer]                ; Ctrl+Break to end a sound with
        mov di, W_SOUND_STOP
        mov al, COPY_MINT
        mov bx, DRV_STOP_BIT
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        must
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
        mov si, [s_files]
        call give_server
        mov dx, [ut_arena]              ; its thread's notification, to sleep on:
        mov al, CAP_NOTIFY              ; made in the scratch slot, moved to the
        mov si, SCRATCH                 ; server's OS_SLOT_SLEEP + n
        kcall KCALL_RETYPE
        must
        mov di, bx
        add di, OS_SLOT_SLEEP
        shl di, 3
        add di, 4
        mov dx, [server_space]
        mov si, SCRATCH
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        mov dx, [ut_arena]              ; its thread
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
; new_segment - a data segment, from the memory for segments, into a slot
; of the root's
;   In:       SI = the slot; CX = bytes; AL = its DPL
;   Out:      nothing (stops on a failure)
;   Destroys: AX, BX, DX
; ----------------------------------------------------------------------------
new_segment:
        mov dx, [ut_memory]
        mov bl, al
        shl bl, 5
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
;             s_xfer, s_server, s_files
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
        add ax, P_FILES - P_SERVER
        mov [s_files], ax
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
        verr dx                         ; a ring-1 module's code: not the root's
        jnz .unread                     ; to read
        call segment_sum
        call print_hex16
        jmp .data
.unread:
        PRINT "----"
.data:
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
