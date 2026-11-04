; ============================================================================
; rx286 - src/include/selectors.inc
; The selectors: the GDT's, which are the kernel's, and the program's LDT's.
;
; A selector is index * 8 + TI * 4 + RPL. The GDT holds only descriptors of
; DPL 0 (roadmap l4.md L1): the kernel's segments, its tasks, the screen and
; the program's LDT. The program's own segments are in that LDT (TI = 1) and
; carry RPL 3. docs/protected-mode.md describes each descriptor.
; ============================================================================

%ifndef RX286_SELECTORS_INC
%define RX286_SELECTORS_INC

RPL_KERNEL          equ 0
RPL_USER            equ 3
SEL_TI_LDT          equ 0x04        ; the table indicator: an LDT selector

SEL_NULL            equ 0x00
SEL_KCODE           equ 0x08        ; kernel code
SEL_KDATA           equ 0x10        ; kernel data: tables, variables, messages
SEL_KSTACK          equ 0x18        ; kernel stack (SS0)
SEL_TSS             equ 0x20        ; the one task
SEL_DFTSS           equ 0x28        ; the double-fault task
SEL_DFSTACK         equ 0x30        ; the double-fault task's stack
SEL_VIDEO           equ 0x38        ; colour text, page 0
SEL_LDT             equ 0x40        ; the program's LDT

GDT_ENTRIES         equ 9
GDT_LIMIT           equ GDT_ENTRIES * 8 - 1

; The program's LDT: its three segments, the fuzzer's alias in test builds
; with the fuzzer, and empty slots (all zeros: invisible to ring 3).
SEL_UCODE           equ 0x00 | SEL_TI_LDT | RPL_USER    ; the program's code
SEL_UDATA           equ 0x08 | SEL_TI_LDT | RPL_USER    ; its data
SEL_USTACK          equ 0x10 | SEL_TI_LDT | RPL_USER    ; its stack
SEL_UFUZZ           equ 0x18 | SEL_TI_LDT | RPL_USER    ; fuzzer builds: code over UDATA
LDT_ENTRIES         equ 8
LDT_LIMIT           equ LDT_ENTRIES * 8 - 1

%endif
