; ============================================================================
; rx286 - src/kernel/kernel.inc
; The kernel's own constants and macros: the interrupt frame, the MSW and
; FLAGS bits, colours, and TRACE, LOG, ASSERT and the kdata switch.
;
; Every module of src/kernel/ may use these. The frame is what isr_common
; builds on the kernel stack; BP points at it in every handler.
; ============================================================================

%ifndef RX286_KERNEL_INC
%define RX286_KERNEL_INC

; ---------------------------------------------------------------- the interrupt frame
; isr_common pushes the registers (PUSHA), DS and ES over what the stub and
; the CPU pushed. Offsets from BP:
FRAME_ES            equ 0
FRAME_DS            equ 2
FRAME_DI            equ 4
FRAME_SI            equ 6
FRAME_BP            equ 8
FRAME_SP            equ 10      ; PUSHA's copy of SP; POPA ignores it
FRAME_BX            equ 12
FRAME_DX            equ 14
FRAME_CX            equ 16
FRAME_AX            equ 18
FRAME_VECTOR        equ 20      ; pushed by the stub
FRAME_ERROR         equ 22      ; pushed by the CPU, or 0 by the stub
FRAME_IP            equ 24      ; pushed by the CPU from here on
FRAME_CS            equ 26
FRAME_FLAGS         equ 28
FRAME_USER_SP       equ 30      ; only when the interrupt came from ring 3
FRAME_USER_SS       equ 32
FRAME_SIZE_KERNEL   equ 30      ; a frame from ring 0
FRAME_SIZE_USER     equ 34      ; a frame from ring 3

; ---------------------------------------------------------------- the CPU
MSW_PE              equ 0x0001  ; protection enable
MSW_MP              equ 0x0002  ; monitor processor extension: WAIT honours TS
MSW_EM              equ 0x0004  ; emulate processor extension: ESC faults
MSW_TS              equ 0x0008  ; task switched
FLAGS_CF            equ 0x0001
FLAGS_TF            equ 0x0100
FLAGS_IF            equ 0x0200
FLAGS_NT            equ 0x4000
FLAGS_USER_START    equ 0x0202  ; IF set, IOPL 0, everything else clear
FLAGS_DF_TASK       equ 0x0002  ; the double-fault task: interrupts off (bit 1 reads as 1)
CPL_MASK            equ 3

; ---------------------------------------------------------------- the console
ATTR_NORMAL         equ 0x07    ; light grey on black
ATTR_KERNEL         equ 0x0E    ; yellow on black: the kernel's own messages
ATTR_PANIC          equ 0x4F    ; white on red
VECTOR_NAME_CHARS   equ 3       ; "#GP", "NMI": the longest name of an exception

; ---------------------------------------------------------------- kdata
; begin_kdata / end_kdata - put what lies between in the kernel's data
; segment, and return to the section that was current (NASM's __?SECT?__).
%macro begin_kdata 0
    [section kdata]
%endmacro
%macro end_kdata 0
    __?SECT?__
%endmacro

; kstring label, "text" - a zero-terminated string in kdata
%macro kstring 2+
    begin_kdata
%1: db %2, 0
    end_kdata
%endmacro

; ---------------------------------------------------------------- messages
; LOG "text" - a line of the kernel's own (yellow, every build), with "rx286: "
%macro LOG 1+
    begin_kdata
%%text: db %1, 0
    end_kdata
    push si
    mov si, %%text
    call klog
    pop si
%endmacro

; LOG_NUMBER "text", word - a line of the kernel's own: "rx286: text" and the
; word in hexadecimal (every build)
%macro LOG_NUMBER 2
    begin_kdata
%%text: db %1, 0
    end_kdata
    push ax
    push si
    mov ax, %2
    mov si, %%text
    call klog_number
    pop si
    pop ax
%endmacro

; TRACE "text" - a trace line in debug and test builds, nothing in release
%macro TRACE 1+
  %ifdef WITH_SERIAL
    begin_kdata
%%text: db %1, 0
    end_kdata
    push si
    mov si, %%text
    call ktrace
    pop si
  %endif
%endmacro

; ASSERT cc, "text" - in debug and test builds, panic unless condition cc
; holds (cc as in a Jcc: z, nz, c, ...); nothing in release
%macro ASSERT 2+
  %ifdef WITH_CHECKS
    j%1 %%ok
    begin_kdata
%%text: db "assertion failed: ", %2, 0
    end_kdata
    mov si, %%text
    xor bp, bp
    jmp panic
%%ok:
  %endif
%endmacro

%endif
