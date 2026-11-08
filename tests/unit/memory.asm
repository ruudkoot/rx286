; ============================================================================
; rx286 - tests/unit/memory.asm
; The crt's memcpy, memmove, memset and memcmp (src/lib/crt/memory.asm), or
; with FAR_DATA their versions for C's compact model (memory-far.asm),
; assembled flat for tests/unit/test_memory.py (roadmap memory.md M5).
; ============================================================================

cpu 286
bits 16
%define ELF                             ; plain sections, as -f bin wants
%ifdef FAR_DATA
%include "crt/memory-far.asm"
%else
%include "crt/memory.asm"
%endif
