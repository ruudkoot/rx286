; ============================================================================
; rx286 - src/include/exe.inc
; rx286's executable format (roadmap os-server.md D12): a header of
; RX_HEADER_SIZE bytes, then the code, then the initialised data.
;
; tools/mkexe makes such a file from a linker's output; tools/mkimage takes
; one as a module of the boot image; later the OS server loads one from a
; file (P8). Every selector is fixed by its slot, so there are no
; relocations: the code is slot 0, the data segment slot 1. The data
; segment holds the stack at its bottom (RXH_STACK bytes), then the
; initialised data (RXH_DATA bytes, which the file holds), then .bss
; (RXH_BSS bytes, zeros). docs/c.md describes it.
; ============================================================================

%ifndef RX286_EXE_INC
%define RX286_EXE_INC

RX_MAGIC            equ 'RX'    ; RXH_MAGIC: the first two bytes, "RX"
RX_VERSION          equ 1
RX_HEADER_SIZE      equ 32
RXH_MAGIC           equ 0       ; word: RX_MAGIC
RXH_VERSION         equ 2       ; word: RX_VERSION
RXH_FLAGS           equ 4       ; word: RXF_*
RXH_CODE            equ 6       ; word: the code's bytes, after the header
RXH_DATA            equ 8       ; word: the initialised data's bytes, after the code
RXH_BSS             equ 10      ; word: .bss's bytes
RXH_STACK           equ 12      ; word: the stack's bytes, where the data begins
RXH_DGROUP_MAX      equ 14      ; word: the data segment's most bytes, for brk (0: 64 KB)
RXH_ENTRY           equ 16      ; word: the IP of the start
RXF_287             equ 1       ; it needs a 287
RXF_MEDIUM          equ 2       ; more code segments follow (later: D2 B)

%endif
