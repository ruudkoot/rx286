; ============================================================================
; rx286 - src/include/build.inc
; The three build flavours, from one source (roadmap D16).
;
; The Makefile passes one of -dRELEASE, -dDEBUG or -dTEST. This file turns
; the flavour into the features the code tests with %ifdef:
;   WITH_SERIAL       the console mirrored to LOG_PORT, and the trace log there
;   WITH_SCREEN_TRACE trace lines on the screen too (debug only)
;   WITH_REGISTERS    registers in fault reports
;   WITH_CHECKS       ASSERT, and magic breakpoints for Bochs
;   WITH_TEST_HOOKS   typed keys, device probes, the end through Bochs
; LOG_PORT is the UART of the log: COM2, which every emulator has. COM1 is
; the mouse's and COM4 the modem's (devices roadmap D1, D2), in every build.
; ============================================================================

%ifndef RX286_BUILD_INC
%define RX286_BUILD_INC

%ifdef TEST
  %define FLAVOUR_NAME "test"
  %define WITH_SERIAL
  %define WITH_REGISTERS
  %define WITH_CHECKS
  %define WITH_TEST_HOOKS
%elifdef DEBUG
  %define FLAVOUR_NAME "debug"
  %define WITH_SERIAL
  %define WITH_SCREEN_TRACE
  %define WITH_REGISTERS
  %define WITH_CHECKS
%elifdef RELEASE
  %define FLAVOUR_NAME "release"
%else
  %error "build.inc: pass -dRELEASE, -dDEBUG or -dTEST"
%endif

%define LOG_PORT COM2_BASE

; The Makefile names the map file of every binary with -dMAPFILE=...
%ifdef MAPFILE
[map all MAPFILE]
%endif

; BREAK - a Bochs magic breakpoint (xchg bx, bx) in debug and test builds.
%macro BREAK 0
  %ifdef WITH_CHECKS
    xchg bx, bx
  %endif
%endmacro

%endif
