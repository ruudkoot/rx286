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
RPL_MASK            equ 3           ; a selector's RPL bits (os-server.md P15)
SEL_TI_LDT          equ 0x04        ; the table indicator: an LDT selector

SEL_NULL            equ 0x00
SEL_KCODE           equ 0x08        ; kernel code
SEL_KDATA           equ 0x10        ; kernel data: tables, variables, messages
SEL_KSTACK          equ 0x18        ; the kernel's one stack (SS0): SEL_KDATA, expand-down
SEL_TSS             equ 0x20        ; the one task
SEL_DFTSS           equ 0x28        ; the double-fault task
SEL_DFSTACK         equ 0x30        ; the double-fault task's stack
SEL_VIDEO           equ 0x38        ; colour text, page 0
; The kernel's two windows on any memory, for zeroing and copying it; the
; idle loop's control block; then the pool of descriptors each kernel object
; and each space's LDT takes one of (roadmap os-server.md P3): an object's
; selector is its name. A free one is not present, and holds the next free
; one in its limit (cap.asm). The image holds the GDT up to the pool; the
; kernel builds the whole at GDT_PHYS when it starts (gdt_init).
SEL_SCRATCH         equ 0x40
SEL_SCRATCH2        equ 0x48
SEL_IDLE            equ 0x50        ; the idle loop's thread (thread.asm)
SEL_OBJ_POOL        equ 0x58
OBJ_MAX             equ GDT_ENTRIES - SEL_OBJ_POOL / 8
GDT_LIMIT           equ GDT_ENTRIES * 8 - 1
GDT_BOOT_LIMIT      equ SEL_OBJ_POOL - 1

; A program's LDT: its three segments, the fuzzer's alias in test builds
; with the fuzzer, and empty slots (all zeros: invisible to ring 3). Every
; space the root builds has these slots, so the same selectors name each
; program's own segments.
SEL_UCODE           equ 0x00 | SEL_TI_LDT | RPL_USER    ; the program's code
SEL_UDATA           equ 0x08 | SEL_TI_LDT | RPL_USER    ; its data
SEL_USTACK          equ 0x10 | SEL_TI_LDT | RPL_USER    ; its stack
SEL_UFUZZ           equ 0x18 | SEL_TI_LDT | RPL_USER    ; fuzzer builds: code over UDATA

%endif
