; ============================================================================
; rx286 - src/include/cabi.inc
; The C calling convention, for NASM routines that C calls or that call C
; (roadmap os-server.md E2, D22).
;
; cdecl, the small model: arguments on the stack, right to left, the caller
; pops them; a result in AX, or DX:AX; SI, DI, BP and DS kept; AX, BX, CX,
; DX and ES free. ES is free for both compilers (gcc-ia16 by
; -fcall-used-es): a call may delete the segment it names, and the kernel
; then leaves it null (os-server.md P4). Names are C's: the Makefile
; assembles for Watcom with --gprefix _ (its cdecl names begin with an
; underscore), and for gcc-ia16 (ELF, -dELF) without. code_section
; and the data sections name the segments each compiler's linker expects:
; Watcom's _TEXT and DGROUP, or ELF's .text and .data.
; ============================================================================

%ifndef RX286_CABI_INC
%define RX286_CABI_INC

%ifdef ELF
  %macro code_section 0
    [section .text]
  %endmacro
  %macro data_section 0
    [section .data]
  %endmacro
  %macro bss_section 0
    [section .bss]
  %endmacro
%else
  %macro code_section 0
    [segment _TEXT public class=CODE use16 align=1]
  %endmacro
  %macro data_section 0
    [segment _DATA public class=DATA use16 align=2]
    [group DGROUP _DATA]
  %endmacro
  %macro bss_section 0
    [segment _BSS public class=BSS use16 align=2]
    [group DGROUP _BSS]
  %endmacro
%endif

; DGROUP_OFFSET(x) - x's offset in the data segment: for Watcom, from
; DGROUP's start, since x's own segment may begin past it
%ifdef ELF
  %define DGROUP_OFFSET(x) x
%else
  %define DGROUP_OFFSET(x) x wrt DGROUP
%endif

; ARG n - the n-th argument's word, from BP after `push bp / mov bp, sp`
%define ARG(n) [bp + 4 + 2 * (n)]

%endif
