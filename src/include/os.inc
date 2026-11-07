; ============================================================================
; rx286 - src/include/os.inc
; The OS server's interface (roadmap l4.md L6, D16; os-server.md P14): how
; the programs the root builds reach it, and its requests to the root.
;
; Every program the root builds has, besides its code, data and stack, an
; endpoint to the OS server, badged with its module's number. It calls it
; with a PX_* call's number as the label (posix.inc; the px macro of
; src/userland/program.inc); its buffers are offsets in its data segment,
; which the server holds. A process's endpoint is in the same slot
; (ROOT_SPAWN). docs/os-server.md describes it, docs/syscalls.md the calls.
; ============================================================================

%ifndef RX286_OS_INC
%define RX286_OS_INC

OS_SLOT_EP          equ 8       ; a program's slot: its endpoint to the OS server
OS_EP               equ OS_SLOT_EP * 8 + 4 + 3      ; as the program's selector
PROGRAM_SLOTS       equ 16      ; a program's space: room for them

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
; The root's services for processes (os-server.md P4; 1 to 3 were the
; programs' ps, kill and start until P14): BX 0 or E_INVAL, E_NOMEM, E_IO,
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
ROOT_BRK            equ 10      ; BX a process; CX bytes; DI a slot -> its data so many
                                ;    bytes, the bytes kept: in place, every copy with it, if
                                ;    its block has room (KCALL_RESIZE, P15); else replaced
                                ;    by a new segment in its slots 1 and 2 and the server's
                                ;    DI, every copy of the old revoked
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
