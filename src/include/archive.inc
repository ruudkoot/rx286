; ============================================================================
; rx286 - src/include/archive.inc
; /z, the archive of programs (roadmap os-server.md P6, D11): rx286
; executables (exe.inc) that travel in the boot image as one module's data
; (MF_ARCHIVE; tools/mkarchive, tools/mkimage). The root gives it to the OS
; server, read-only, which runs a program from it by its name ("/z/init").
;
; A header, then AR_ENTRY_SIZE bytes a file, then the files, each from a
; paragraph. All of it fits a module's data: 64 KB.
; ============================================================================

%ifndef RX286_ARCHIVE_INC
%define RX286_ARCHIVE_INC

AR_MAGIC            equ 'RZ'    ; ARH_MAGIC: the first two bytes, "RZ"
ARH_MAGIC           equ 0       ; word
ARH_COUNT           equ 2       ; word: the files
AR_HEADER_SIZE      equ 16
AR_NAME             equ 0       ; a file's entry: its name, zero-padded
AR_NAME_SIZE        equ 12
AR_OFFSET           equ 12      ; word: where it starts, from the archive's start
AR_SIZE             equ 14      ; word: its bytes
AR_ENTRY_SIZE       equ 16

%endif
