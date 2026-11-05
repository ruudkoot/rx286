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
; segment's end, so that the kernel's own checks refuse it in their own
; order. docs/syscalls.md describes it.
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

%endif
