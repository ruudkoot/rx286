; ============================================================================
; rx286 - src/include/selectors.inc
; The selectors: the GDT's, which are the kernel's, and the program's LDT's.
;
; A selector is index * 8 + TI * 4 + RPL. The GDT holds only descriptors of
; DPL 0 (roadmap l4.md L1): the kernel's segments, its tasks, the screen,
; each space's LDT and each thread's kernel stack. A program's own segments
; are in its space's LDT (TI = 1) and carry RPL 3. docs/protected-mode.md
; describes each descriptor.
; ============================================================================

%ifndef RX286_SELECTORS_INC
%define RX286_SELECTORS_INC

%include "layout.inc"                  ; SPACE_MAX, THREAD_MAX

RPL_KERNEL          equ 0
RPL_USER            equ 3
SEL_TI_LDT          equ 0x04        ; the table indicator: an LDT selector

SEL_NULL            equ 0x00
SEL_KCODE           equ 0x08        ; kernel code
SEL_KDATA           equ 0x10        ; kernel data: tables, variables, messages
SEL_KSTACK          equ 0x18        ; the kernel's one stack (SS0): SEL_KDATA, expand-down
SEL_TSS             equ 0x20        ; the one task
SEL_DFTSS           equ 0x28        ; the double-fault task
SEL_DFSTACK         equ 0x30        ; the double-fault task's stack
SEL_VIDEO           equ 0x38        ; colour text, page 0
; The pool the kernel takes LDT descriptors from (roadmap l4.md L3), one
; for each space; a free one is all zeros. Then the kernel's two windows on
; any memory, for zeroing and copying it. (A pool of kernel stacks, one for
; each thread, was here until roadmap os-server.md P3.)
SEL_LDT_POOL        equ 0x40                                ; SPACE_MAX of them
SEL_SCRATCH         equ SEL_LDT_POOL + SPACE_MAX * 8
SEL_SCRATCH2        equ SEL_SCRATCH + 8

GDT_ENTRIES         equ SEL_SCRATCH2 / 8 + 1
GDT_LIMIT           equ GDT_ENTRIES * 8 - 1

; A program's LDT: its three segments, the fuzzer's alias in test builds
; with the fuzzer, and empty slots (all zeros: invisible to ring 3). Every
; space the root builds has these slots, so the same selectors name each
; program's own segments.
SEL_UCODE           equ 0x00 | SEL_TI_LDT | RPL_USER    ; the program's code
SEL_UDATA           equ 0x08 | SEL_TI_LDT | RPL_USER    ; its data
SEL_USTACK          equ 0x10 | SEL_TI_LDT | RPL_USER    ; its stack
SEL_UFUZZ           equ 0x18 | SEL_TI_LDT | RPL_USER    ; fuzzer builds: code over UDATA

%endif
