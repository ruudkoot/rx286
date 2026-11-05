; ============================================================================
; rx286 - tests/programs/caps.asm
; The kernel's calls on capabilities (roadmap l4.md L3), from ring 3.
;
; In a TEST_CAPS build the root gives this program, in slots 10-13, the
; rest of the memory for segments and of the arena as untyped, its own space
; and its own thread (src/root). It retypes every kind of object, is refused every way
; it can think of, builds a space for a new thread from what it made -
; code copied from its own, data and stack moved in, an endpoint minted
; with a badge - and starts that thread. Last, it loads a capability that is
; not a segment, which faults; restarted, it says it is done. Each line is
; a call's status (KE_*: 0 ok, 1 not such a capability, 2 an argument,
; 4 a full slot, 6 a thread's state).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

; Its slots, as selectors (slot n: n * 8 + 4 + 3)
MY_CODE             equ 0x07            ; slot 0: its code
MY_SLOT3            equ 0x1F            ; slots 3-7: empty at the start
MY_SLOT4            equ 0x27
MY_SLOT5            equ 0x2F
MY_SLOT6            equ 0x37
MY_SLOT7            equ 0x3F
UT_MEMORY           equ 0x57            ; slot 10: memory for segments
UT_ARENA            equ 0x5F            ; slot 11: the rest of the arena
MY_SPACE            equ 0x67            ; slot 12: its own space
MY_THREAD           equ 0x6F            ; slot 13: its own thread
MY_EMPTY            equ 0x77            ; slot 14: empty
PAST_MY_SPACE       equ 0x207           ; slot 64: past its 64 slots
; (slots 8 and 9: its endpoint to the OS server, its transfer segment)
GDT_SELECTOR        equ 0x10            ; the kernel's data: no slot of anyone's
ACC_DATA3           equ 0xF2            ; present, DPL 3, data, writable
ACC_CODE3           equ 0xFA            ; present, DPL 3, code, readable
ACC_DATA0           equ 0x92            ; present, DPL 0, data
NEW_SIZE            equ 256             ; the new thread's data, and its stack

; the new thread's space, at slot 4: its slots as selectors there
NEW_CODE            equ 0x07
NEW_DATA            equ 0x0F
NEW_STACK           equ 0x17
NEW_ENDPOINT        equ 0x1F

begin_udata
started             db 0
end_udata

; report "what" - "caps: what: " and AX, the status, in decimal
%macro report 1
        push ds
        pop es
        PRINT "caps: ", %1, ": "
        call print_dec
        call print_newline
%endmacro

; ----------------------------------------------------------------------------
; entry - the calls, once; after the fault at the end, "done"
;   In:       the kernel's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cmp byte [started], 0
        jne .done
        mov byte [started], 1
        ; ---- retype every kind of object
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, MY_SLOT3
        mov cx, NEW_SIZE
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "retype a segment"
        mov ax, MY_SLOT3
        mov es, ax
        mov ax, [es:2]                  ; zeroed by the kernel
        mov word [es:0], 0x1234
        mov bx, [es:0]
        add ax, bx
        report "the segment, zeroed, reads back (4660)"
        mov dx, MY_SLOT3
        kcall KCALL_SEGMENT
        mov bx, ax
        mov ax, dx
        report "its base, high byte (4)"
        mov ax, bx                      ; past the others' segments, and its own
        report "its base, low word (12304)"
        mov ax, cx
        report "its limit (255)"
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, MY_SLOT4
        mov cx, 16
        kcall KCALL_RETYPE
        report "retype a space"
        mov dx, UT_ARENA
        mov al, CAP_THREAD
        mov si, MY_SLOT5
        kcall KCALL_RETYPE
        report "retype a thread"
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, MY_SLOT6
        kcall KCALL_RETYPE
        report "retype an endpoint"
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, MY_SLOT7
        kcall KCALL_RETYPE
        report "retype a notification"
        ; ---- refused
        mov dx, MY_SLOT3
        mov al, CAP_SEGMENT
        mov si, MY_EMPTY
        mov cx, 16
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "retype from a segment (1)"
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, MY_SLOT3
        mov cx, 16
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "retype into a full slot (4)"
        mov dx, UT_ARENA
        mov al, CAP_SEGMENT
        mov si, MY_EMPTY
        mov cx, 16
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "a segment from the arena (1)"
        mov dx, UT_MEMORY
        mov al, CAP_THREAD
        mov si, MY_EMPTY
        kcall KCALL_RETYPE
        report "a thread from the memory for segments (1)"
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, MY_EMPTY
        mov cx, 16
        mov bl, ACC_CODE3
        kcall KCALL_RETYPE
        report "a code segment (2)"
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, MY_EMPTY
        mov cx, 16
        mov bl, ACC_DATA0
        kcall KCALL_RETYPE
        report "a segment of DPL 0 (2)"
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, MY_EMPTY
        mov cx, 12
        kcall KCALL_RETYPE
        report "a space of 12 slots (2)"
        mov dx, GDT_SELECTOR
        mov al, CAP_SEGMENT
        mov si, MY_EMPTY
        mov cx, 16
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "a GDT selector as the untyped (1)"
        mov dx, PAST_MY_SPACE
        mov al, CAP_ENDPOINT
        mov si, MY_EMPTY
        kcall KCALL_RETYPE
        report "a selector past the space (1)"
        mov dx, MY_EMPTY
        mov al, CAP_ENDPOINT
        mov si, MY_EMPTY
        kcall KCALL_RETYPE
        report "an empty slot as the untyped (1)"
        mov dx, MY_SLOT6
        kcall KCALL_SEGMENT
        report "the base of an endpoint (1)"
        mov ah, 0
        int KCALL_VECTOR
        report "a call that does not exist (7)"
        ; ---- a space for a new thread: code copied, data and stack moved in
        mov dx, MY_SLOT4
        mov si, MY_CODE
        mov di, NEW_CODE
        mov al, COPY_COPY
        kcall KCALL_COPY
        report "copy its code into the new space"
        mov ax, MY_SLOT3
        mov es, ax                      ; held across the move: X2's case
        mov dx, MY_SLOT4
        mov si, MY_SLOT3
        mov di, NEW_DATA
        mov al, COPY_MOVE
        kcall KCALL_COPY
        mov bx, es                      ; before report reloads it
        report "move the segment in, as its data"
        mov ax, bx
        report "ES after the move: nulled on the way back (0)"
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, MY_SLOT3
        mov cx, NEW_SIZE
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        report "retype its stack"
        mov dx, MY_SLOT4
        mov si, MY_SLOT3
        mov di, NEW_STACK
        mov al, COPY_MOVE
        kcall KCALL_COPY
        report "move the stack in"
        mov dx, MY_SLOT4
        mov si, MY_SLOT6
        mov di, NEW_ENDPOINT
        mov al, COPY_MINT
        mov bx, 0xB0B0
        kcall KCALL_COPY
        report "mint the endpoint into it, badged"
        ; ---- copies refused
        mov dx, MY_SLOT4
        mov si, MY_CODE
        mov di, 0x27
        mov al, COPY_MINT
        mov bx, 0xB0B0
        kcall KCALL_COPY
        report "mint a segment (2)"
        mov dx, MY_SLOT4
        mov si, MY_SLOT7
        mov di, 0x27
        mov al, COPY_MINT
        xor bx, bx
        kcall KCALL_COPY
        report "mint with no badge (2)"
        mov dx, MY_SLOT4
        mov si, UT_MEMORY
        mov di, 0x27
        mov al, COPY_COPY
        kcall KCALL_COPY
        report "copy untyped (2)"
        mov dx, MY_SLOT4
        mov si, MY_CODE
        mov di, NEW_CODE
        mov al, COPY_COPY
        kcall KCALL_COPY
        report "copy into a full slot (4)"
        mov dx, MY_SLOT4
        mov si, MY_EMPTY
        mov di, 0x27
        mov al, COPY_COPY
        kcall KCALL_COPY
        report "copy from an empty slot (1)"
        mov dx, MY_SLOT6
        mov si, MY_CODE
        mov di, 0x27
        mov al, COPY_COPY
        kcall KCALL_COPY
        report "copy into an endpoint, as a space (1)"
        ; ---- the new thread: configured, started, refused a second start
        mov dx, MY_SLOT5
        mov al, THREAD_CONFIGURE
        mov si, MY_SLOT4
        mov bx, new_thread
        mov cx, NEW_SIZE
        kcall KCALL_THREAD
        report "configure the new thread"
        mov dx, MY_SPACE
        mov al, THREAD_START
        mov cx, 2
        kcall KCALL_THREAD
        report "start a space, as a thread (1)"
        mov dx, MY_SLOT5
        mov al, THREAD_START
        mov cx, 9
        kcall KCALL_THREAD
        report "start at priority 9 (2)"
        mov dx, MY_SLOT5
        mov al, THREAD_START
        mov cx, 2                       ; below this program's 3: it runs when we wait
        kcall KCALL_THREAD
        report "start it"
        mov dx, MY_SLOT5
        mov al, THREAD_START
        mov cx, 2
        kcall KCALL_THREAD
        report "start it again (6)"
        mov dx, MY_THREAD
        mov al, THREAD_CONFIGURE
        mov si, MY_SLOT4
        xor bx, bx
        mov cx, NEW_SIZE
        kcall KCALL_THREAD
        report "configure a running thread: itself (6)"
        ; ---- a capability that is not a segment, loaded: a fault
        PRINT "caps: load the endpoint into ES", CHAR_LF
        mov ax, MY_SLOT6
.load_f:
        mov es, ax
.done:
        PRINT "caps: done", CHAR_LF
        mov al, WAIT_MOUSE              ; a few ticks for the new thread, below
        mov cx, 5                       ; this program, before the test ends
        sys SYS_WAIT
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; new_thread - the thread this program made, in a space of its making: the
; same code, its own data (the segment moved in) and stack. It writes a line
; from its own data, and spins below this program's priority.
;   In:       its start: DS = ES = its data, SS:SP its stack
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
new_thread:
        mov word [0], 'ne'
        mov word [2], 'w '
        mov word [4], 'th'
        mov word [6], 're'
        mov word [8], 'ad'
        mov word [10], ': '
        mov word [12], 'ru'
        mov word [14], 'ns'
        mov byte [16], CHAR_LF
        xor si, si
        mov cx, 17
        mov ah, SYS_WRITE               ; the kernel's own call: this thread has
        int SYSCALL_VECTOR              ; no endpoint to the OS server
.spin:
        jmp .spin

%include "uprint.asm"
%include "format.asm"
