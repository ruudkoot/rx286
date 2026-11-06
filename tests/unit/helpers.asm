; ============================================================================
; rx286 - tests/unit/helpers.asm
; The crt's 32-bit arithmetic (src/lib/crt/helpers.asm), both compilers'
; sets, assembled flat for tests/unit/test_helpers.py.
; ============================================================================

cpu 286
bits 16
%define ELF                             ; plain sections, as -f bin wants
%define HELPERS_BOTH
%include "crt/helpers.asm"
