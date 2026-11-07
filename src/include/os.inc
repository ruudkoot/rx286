; ============================================================================
; rx286 - src/include/os.inc
; The OS server's interface (roadmap l4.md L6, D16): how a program's system
; calls reach it.
;
; Every program the root starts has, besides its code, data and stack, an
; endpoint to the OS server (badged with its module's number) and a
; transfer segment it shares with the OS server. The sys macro calls a stub
; (src/userland/stub.asm), which puts the registers in the transfer
; segment's block and a buffer in its data, and calls the endpoint; the OS
; server (src/os/os.asm) makes the call and puts the results back. A buffer
; the program may not use so is passed on as XFER_BAD, past the transfer
; segment's end, so that the OS server refuses it after its other checks,
; in the order the kernel's own checks had. docs/syscalls.md describes it.
; ============================================================================

%ifndef RX286_OS_INC
%define RX286_OS_INC

OS_SLOT_EP          equ 8       ; a program's slots: its endpoint to the OS server
OS_SLOT_XFER        equ 9       ;    its transfer segment
OS_EP               equ OS_SLOT_EP * 8 + 4 + 3      ; as the program's selectors
OS_XFER             equ OS_SLOT_XFER * 8 + 4 + 3
PROGRAM_SLOTS       equ 16      ; a program's space: room for them

; The transfer segment: the registers of a call, then its buffer
XFER_AX             equ 0       ; the registers in, and out
XFER_BX             equ 2
XFER_CX             equ 4
XFER_DX             equ 6
XFER_SI             equ 8
XFER_DI             equ 10
XFER_FLAGS          equ 12      ; out: the flags, CF an error
XFER_DATA           equ 16      ; the buffer
XFER_DATA_SIZE      equ 4096    ; as much as a write, a print or a serial transfer takes
XFER_SIZE           equ XFER_DATA + XFER_DATA_SIZE
XFER_BAD            equ XFER_SIZE   ; a buffer refused: at the segment's end

PATH_IN_MAX         equ 128     ; a path's bytes the stub passes (SYS_FIND, SYS_CHDIR),
                                ;    its end among them
FILES_SIZE          equ 2560    ; a program's files segment: the OS server's alone,
                                ;    its file calls' state (src/os/files.asm; l4.md L9)

FAULT_BADGE         equ 0x8000  ; a program's fault endpoint: its endpoint, badged so

; The OS server's requests to the root (l4.md L11): calls on the root's
; fault endpoint, badged ROOT_BADGE_OS, from slot OS_SLOT_ROOT of the server's
ROOT_BADGE_OS       equ 0x4000
ROOT_BADGE_TEST     equ 0x4001  ; TEST_SERVICES: the test program's, whose copies go to it
OS_SLOT_ROOT        equ 160
OS_SLOT_ARCHIVE     equ 161     ; the server's: /z, the archive module's bytes (os-server.md P6)
OS_SLOT_KEYS        equ 162     ;    a notification the keyboard driver signals, when no
                                ;    program the root builds has the keys: the processes'
                                ;    (os-server.md P9)
OS_SLOT_TIMER       equ 163     ;    the control notification, badged CONTROL_TIMER: the
                                ;    processes' timers on it (os-server.md P10)
ROOT_INFO           equ 1       ; BX a module's number -> BX 0 or E_INVAL (no such module);
                                ;    CL its kind (PS_*), CH its main thread's state
                                ;    (STATE_*), SI its priority, DI the times it ran
ROOT_KILL           equ 2       ; BX a module: killed, if a background program, its untyped
                                ;    revoked -> BX 0, or E_INVAL (not one), E_BUSY (killed
                                ;    already)
ROOT_START          equ 3       ; BX a module: built again from its untyped, if a killed
                                ;    background program -> BX 0, E_INVAL, E_BUSY (running)
                                ;    or E_IO (a kernel call failed: nothing left built)
; The root's services for processes (os-server.md P4): BX 0 or E_INVAL, E_NOMEM, E_IO,
; and CX a number. The root copies what the server gets into the server's space, at the
; slots DI names (selectors); a file's key is three words, CX SI DI.
ROOT_LOAD           equ 4       ; BX bytes; DI a slot -> CX a load: a segment of DPL 3 of so
                                ;    many bytes, the server's copy at DI to read code into
ROOT_SEAL           equ 5       ; BX a load; CX SI DI its file's key -> CX a code: the
                                ;    server's copy revoked, the segment sealed (KCALL_SEAL)
                                ;    and in the code table, used by no process yet
ROOT_FIND           equ 6       ; CX SI DI a file's key -> CX the code of that file, or
                                ;    E_NOT_FOUND
ROOT_SPAWN          equ 7       ; BX a code; CX the data's bytes; SI a badge; DI four slots ->
                                ;    CX a process: a space of PROC_SLOTS with the code, the
                                ;    data, the data again as the stack (SS = DS) and an
                                ;    endpoint badged SI (OS_SLOT_EP), a thread there not yet
                                ;    configured, its faults on that endpoint badged SI or
                                ;    FAULT_BADGE; the server's copies of the endpoint, the
                                ;    thread, the space and the data at DI, DI + 8, + 16, + 24
ROOT_FORK           equ 8       ; BX a process; SI a badge; DI four slots -> CX the child:
                                ;    as ROOT_SPAWN, with its code and a copy of its data
ROOT_THREAD         equ 9       ; BX a process; SI a badge; DI two slots -> CX its thread n:
                                ;    another thread in its space and an endpoint badged SI
                                ;    (its slot OS_SLOT_EP + n); the server's copies of the
                                ;    endpoint and the thread at DI, DI + 8
ROOT_BRK            equ 10      ; BX a process; CX bytes; DI a slot -> its data replaced by
                                ;    a segment of so many bytes, the bytes kept, in its slots
                                ;    1 and 2 and the server's DI; every copy of the old
                                ;    revoked
ROOT_EXIT           equ 11      ; BX a process: everything of it revoked, its memory free,
                                ;    its code's count lowered (the code gone at 0; with CX
                                ;    1, kept, sealed, for an exec of the same file: P12)
ROOT_UNLOAD         equ 12      ; BX a load, or a code no process runs: gone, its memory free
ROOT_SERVE          equ 13      ; CX an SP; DI two slots -> a thread of the server's own, at
                                ;    its entry with that SP and its priority, started, its
                                ;    faults the root's; a notification; the server's copies
                                ;    of the thread and the notification at DI, DI + 8 (P6)
ROOT_UNTHREAD       equ 14      ; BX a process, CX a thread of ROOT_THREAD's: it and its
                                ;    endpoint gone, every copy with them (os-server.md P13)
PROC_SLOTS          equ 16      ; a process's space
PROC_THREADS        equ 7       ; the threads ROOT_THREAD adds to a process at most

%endif
