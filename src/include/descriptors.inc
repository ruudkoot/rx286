; ============================================================================
; rx286 - src/include/descriptors.inc
; Macros that write 80286 descriptors, gates and a TSS.
;
; Every descriptor ends with the word the 286 reserves, written as zero: a
; 386 or later reads it as zeros too and so behaves as a 286 (Intel,
; 80286 and 80287 Programmer's Reference Manual, figures 6-3, 6-4, 8-3).
; ============================================================================

%ifndef RX286_DESCRIPTORS_INC
%define RX286_DESCRIPTORS_INC

; Access bytes. The accessed bit of segment descriptors is preset, so the
; CPU never writes the GDT except for a TSS's busy bit.
ACC_PRESENT         equ 0x80
ACC_DPL3            equ 0x60
ACC_KCODE           equ 0x9B        ; present, DPL 0, code, readable, accessed
ACC_KDATA           equ 0x93        ; present, DPL 0, data, writable, accessed
ACC_UCODE           equ 0xFB        ; present, DPL 3, code, readable, accessed
ACC_UDATA           equ 0xF3        ; present, DPL 3, data, writable, accessed
ACC_TSS             equ 0x81        ; present, DPL 0, available 286 TSS
ACC_TSS_BUSY_BIT    equ 0x02        ; set by LTR and task switches
ACC_EXPAND_DOWN     equ 0x04        ; data: expand-down (code: conforming)
ACC_TASK_GATE       equ 0x85        ; present, DPL 0, task gate
ACC_INT_GATE        equ 0x86        ; present, DPL 0, 286 interrupt gate
ACC_INT_GATE_USER   equ 0xE6        ; present, DPL 3, 286 interrupt gate

TSS286_SIZE         equ 44          ; Intel 8.2.1: the limit must be at least 43
TSS286_LIMIT        equ TSS286_SIZE - 1
; The fields of a 286 TSS (Intel figure 8-1), by offset.
TSS286_BACK_LINK    equ 0
TSS286_SP0          equ 2
TSS286_SS0          equ 4
TSS286_IP           equ 14
TSS286_FLAGS        equ 16
TSS286_AX           equ 18
TSS286_CX           equ 20
TSS286_DX           equ 22
TSS286_BX           equ 24
TSS286_SP           equ 26
TSS286_BP           equ 28
TSS286_SI           equ 30
TSS286_DI           equ 32
TSS286_ES           equ 34
TSS286_CS           equ 36
TSS286_SS           equ 38
TSS286_DS           equ 40
TSS286_LDT          equ 42

; segment_descriptor base, limit, access
%macro segment_descriptor 3
    dw (%2)                         ; limit 15:0
    dw (%1) & 0xFFFF                ; base 15:0
    db ((%1) >> 16) & 0xFF          ; base 23:16
    db (%3)                         ; access byte
    dw 0                            ; reserved: zero
%endmacro

; interrupt_gate offset, access   (the selector is always the kernel's code)
%macro interrupt_gate 2
    dw (%1)                         ; offset in KCODE
    dw SEL_KCODE
    db 0                            ; word count: unused by interrupt gates
    db (%2)
    dw 0                            ; reserved: zero
%endmacro

; task_gate tss_selector
%macro task_gate 1
    dw 0                            ; unused
    dw (%1)
    db 0
    db ACC_TASK_GATE
    dw 0                            ; reserved: zero
%endmacro

; tss286 back_link, sp0, ss0, ip, flags, sp, ss, ds, es
; A 286 TSS (Intel figure 8-1); the rings 1 and 2 stacks are unused.
%macro tss286 9
    dw (%1)                         ; back link
    dw (%2), (%3)                   ; SP0, SS0
    dw 0, 0                         ; SP1, SS1
    dw 0, 0                         ; SP2, SS2
    dw (%4)                         ; IP
    dw (%5)                         ; FLAGS
    dw 0, 0, 0, 0                   ; AX, CX, DX, BX
    dw (%6)                         ; SP
    dw 0, 0, 0                      ; BP, SI, DI
    dw (%9)                         ; ES
    dw SEL_KCODE                    ; CS
    dw (%7)                         ; SS
    dw (%8)                         ; DS
    dw 0                            ; LDT: none
%endmacro

%endif
