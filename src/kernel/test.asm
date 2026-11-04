; ============================================================================
; rx286 - src/kernel/test.asm
; What only test builds have (roadmap D16): the end of a test through
; Bochs' shutdown port, and the kernel faults the panic tests ask for.
;
; A test image defines what it wants with -d (tools/run-test):
;   TEST_PANIC_DIVIDE   a divide error in the kernel
;   TEST_PANIC_ASSERT   a failed ASSERT
;   TEST_PANIC_GP       a general protection fault in the kernel
;   TEST_PANIC_STACK    a kernel stack overflow, which must reach the
;                       double-fault task
; Release and debug builds assemble none of this.
; ============================================================================

%ifdef WITH_TEST_HOOKS

begin_kdata
msg_test_end        db "TEST END", CHAR_LF, 0
msg_shutdown        db "Shutdown", 0
end_kdata

; ----------------------------------------------------------------------------
; test_start - what the test image asked for, before anything else runs
;   In:       DS = ES = SEL_KDATA
;   Out:      nothing (or never, for the panic tests)
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
test_start:
%ifdef TEST_PANIC_DIVIDE
        xor ax, ax
        xor dx, dx
.divide:
        div ax
%endif
%ifdef TEST_PANIC_ASSERT
        xor ax, ax
        test ax, ax
        ASSERT nz, "AX is not zero"
%endif
%ifdef TEST_PANIC_GP
        mov ax, SEL_NULL
        mov es, ax
.gp:
        mov ax, [es:0]                  ; a null selector: #GP(0)
%endif
%ifdef TEST_PANIC_STACK
        call test_recurse
%endif
        ret

%ifdef TEST_PANIC_STACK
; ----------------------------------------------------------------------------
; test_recurse - call itself until the kernel stack runs out
;   In:       nothing
;   Out:      does not return: the stack fault becomes a double fault
;   Destroys: the stack
; ----------------------------------------------------------------------------
test_recurse:
        push ax
        call test_recurse
%endif

; ----------------------------------------------------------------------------
; test_end - "TEST END" on COM1, then end Bochs
;   In:       DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
test_end:
        cli
        mov si, msg_test_end
        call com_puts
        call com_drain
        mov dx, BOCHS_SHUTDOWN_PORT
        mov si, msg_shutdown
.next:
        lodsb
        test al, al
        jz .halt
        out dx, al
        jmp .next
.halt:
        hlt
        jmp .halt

%endif
