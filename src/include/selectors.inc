; ============================================================================
; rx286 - src/include/selectors.inc
; The GDT's selectors. The table itself is src/kernel/gdt.asm.
;
; A selector is index * 8 + TI * 4 + RPL. Every selector here is in the GDT
; (TI = 0). The program's selectors carry RPL 3. docs/protected-mode.md
; describes each descriptor.
; ============================================================================

%ifndef RX286_SELECTORS_INC
%define RX286_SELECTORS_INC

RPL_KERNEL          equ 0
RPL_USER            equ 3

SEL_NULL            equ 0x00
SEL_KCODE           equ 0x08        ; kernel code
SEL_KDATA           equ 0x10        ; kernel data: tables, variables, messages
SEL_KSTACK          equ 0x18        ; kernel stack (SS0)
SEL_TSS             equ 0x20        ; the one task
SEL_DFTSS           equ 0x28        ; the double-fault task
SEL_DFSTACK         equ 0x30        ; the double-fault task's stack
SEL_VIDEO           equ 0x38        ; colour text, page 0
SEL_UCODE           equ 0x40 | RPL_USER     ; the program's code
SEL_UDATA           equ 0x48 | RPL_USER     ; the program's data
SEL_USTACK          equ 0x50 | RPL_USER     ; the program's stack
SEL_UFUZZ           equ 0x58 | RPL_USER     ; test builds with the fuzzer only: code over UDATA

%ifdef TEST_FUZZ
GDT_ENTRIES         equ 12
%else
GDT_ENTRIES         equ 11
%endif
GDT_LIMIT           equ GDT_ENTRIES * 8 - 1

%endif
