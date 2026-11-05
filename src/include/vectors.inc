; ============================================================================
; rx286 - src/include/vectors.inc
; The IDT's vectors (roadmap D10). The table itself is src/kernel/idt.asm.
;
; Vectors 00h-1Fh are the CPU's, 20h-2Fh the IRQs after the kernel's
; programming of the 8259As, 30h the system call's until l4.md L10 (a gate
; of DPL 0 now), 31h the kernel's calls on capabilities (roadmap l4.md D20).
; The IDT ends at 31h: any higher vector is beyond its limit, a general
; protection fault.
; ============================================================================

%ifndef RX286_VECTORS_INC
%define RX286_VECTORS_INC

VEC_DE              equ 0x00        ; divide error
VEC_DB              equ 0x01        ; single step
VEC_NMI             equ 0x02
VEC_BP              equ 0x03        ; INT 3
VEC_OF              equ 0x04        ; INTO
VEC_BR              equ 0x05        ; BOUND
VEC_UD              equ 0x06        ; invalid opcode
VEC_NM              equ 0x07        ; processor extension not available
VEC_DF              equ 0x08        ; double fault (task gate)
VEC_MP              equ 0x09        ; processor extension segment overrun
VEC_TS              equ 0x0A        ; invalid TSS
VEC_NP              equ 0x0B        ; segment not present
VEC_SS              equ 0x0C        ; stack fault
VEC_GP              equ 0x0D        ; general protection
VEC_MF              equ 0x10        ; processor extension error: never on the AT
VEC_CPU_LAST        equ 0x1F

VEC_IRQ0            equ 0x20        ; IRQn is VEC_IRQ0 + n
VEC_IRQ8            equ 0x28
VEC_IRQ_LAST        equ 0x2F

VEC_RETIRED         equ 0x30        ; INT 30h, the system call until l4.md L10: now a gate of
                                    ; DPL 0, #GP from rings 1-3 like the kernel's others
VEC_KCALL           equ 0x31        ; the kernel's calls (kcalls.inc)

IDT_ENTRIES         equ VEC_KCALL + 1
IDT_LIMIT           equ IDT_ENTRIES * 8 - 1     ; 18Fh

IRQ_LINES           equ 16          ; two 8259As

; The IRQ lines with a driver.
IRQ_TIMER           equ 0
IRQ_KEYBOARD        equ 1
IRQ_CASCADE         equ 2           ; never masked
IRQ_MOUSE           equ 4           ; COM1: the mouse driver's (l4.md L7)
IRQ_RTC             equ 8
IRQ_FPU             equ 13

%endif
