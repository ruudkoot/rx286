; ============================================================================
; rx286 - src/kernel/log.asm
; The kernel's log, as a call (KCALL_LOG; roadmap l4.md L10, D15), and the
; ticks (KCALL_TICKS): what the kernel still offers once the devices have
; left it.
;
; In debug and test builds the log is COM2 (COM3 when COM2 is the modem),
; which every test reads; until the threads start, the screen too
; (console.asm). The OS server writes a program's SYS_WRITE there, and the
; root and the drivers their own lines. The caller's buffer is checked with
; the 286's own instructions before the kernel reads it: ARPL against the
; caller's CS, VERR, LAR's present bit, LSL and bounds (docs/kernel-calls.md);
; and checked again after every interrupt window, since a descriptor may
; change while interrupts are in (l4.md X2). Interrupts come in after every
; byte, so a long line keeps neither the clock nor a more urgent thread
; waiting: a call that gives way resumes after the bytes it wrote
; (T_LOG_DONE), keeping the log's turn meanwhile; one thread's line at a
; time (call_enter), so lines never mix.
; ============================================================================

; ----------------------------------------------------------------------------
; kc_log - KCALL_LOG: the caller's DS:SI, CX bytes, to the log
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's AX = bytes written, CF clear; or CF and AX =
;             KE_ARG (more than LOG_MAX) or KE_CAP (a buffer it may not read)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_log:
        call call_enter                 ; one thread's bytes at a time
        mov di, [cur_thread]
        xor bx, bx                      ; BX = bytes written
        cmp byte [di + T_CONT], CONT_RESUMED
        jne .fresh
        mov bx, [di + T_LOG_DONE]       ; it gave way after these
.fresh:
        mov cx, [bp + FRAME_CX]
        cmp cx, LOG_MAX
        ja .arg
        sub cx, bx                      ; CX = bytes left
        jcxz .written
        mov si, [bp + FRAME_SI]
        add si, bx
        mov ax, [bp + FRAME_DS]
        call check_buffer               ; ES = the caller's segment, or CF
        jc .cap
.next:
        call recheck_buffer             ; after a window, the descriptor may differ
        jc .cap
        mov al, [es:si]
        call con_emit
        inc si
        inc bx
        ; Let interrupts in after every byte, and a more urgent thread run;
        ; not with the caller's segment in ES, which a switch would reload
        ; in ring 0 after its slot may have gone (l4.md X2): recheck_buffer
        ; loads it again. Stop early if the thread is to restart.
        push ds
        pop es
        mov di, [cur_thread]
        mov [di + T_LOG_DONE], bx       ; where it resumes, if it gives way
        KWINDOW (VEC_KCALL << 8) | KCALL_LOG
        cmp byte [restart_pending], 0
        jne .written
        loop .next
.written:
        mov di, [cur_thread]
        mov word [di + T_LOG_DONE], 0
        call con_cursor
        mov [bp + FRAME_AX], bx
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        jmp call_leave
.arg:
        mov al, KE_ARG
        jmp .failed
.cap:
        call con_cursor
        mov al, KE_CAP
.failed:
        call kc_done
        jmp call_leave

%if LOG_MAX != WRITE_MAX
  %error "log.asm: SYS_WRITE's limit is the log's"
%endif

; ----------------------------------------------------------------------------
; kc_ticks - KCALL_TICKS: the ticks since the kernel started
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's DX:AX, CF clear
;   Destroys: AX
; ----------------------------------------------------------------------------
kc_ticks:
        mov ax, [ticks]
        mov [bp + FRAME_AX], ax
        mov ax, [ticks + 2]
        mov [bp + FRAME_DX], ax
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        ret

%if TICKS_HZ != PIT_HZ
  %error "log.asm: TICKS_HZ must be the timer's rate"
%endif

; ----------------------------------------------------------------------------
; recheck_buffer - may the caller still read CX bytes at its DS:SI? Its
; segment's descriptor may have changed during an interrupt window (l4.md X2)
;   In:       BP = the frame (FRAME_DS the caller's selector); SI = offset;
;             CX = bytes left (> 0)
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
recheck_buffer:
        mov ax, [bp + FRAME_DS]
        ; falls through

; ----------------------------------------------------------------------------
; check_buffer - may the caller read CX bytes at AX:SI?
;   In:       AX = the caller's selector; SI = offset; CX = length (> 0);
;             BP = the frame (its CS is the caller's privilege)
;   Out:      CF clear and ES = the selector if so; CF set if not (also for a
;             buffer ending at FFFFh exactly: no program segment is that big)
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_buffer:
        mov dx, [bp + FRAME_CS]
        arpl ax, dx                     ; no more privilege than the caller's
        verr ax                         ; readable at that privilege?
        jnz check_refuse
        jmp check_bounds

; ----------------------------------------------------------------------------
; check_buffer_writable - may the caller write CX bytes at AX:SI?
;   In:       as check_buffer
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_buffer_writable:
        mov dx, [bp + FRAME_CS]
        arpl ax, dx
        verw ax                         ; writable at that privilege? (never code)
        jnz check_refuse
        ; falls through

; ----------------------------------------------------------------------------
; check_bounds - the rest of check_buffer: AX:SI, CX bytes, within the
; segment's limit (not expand-down)
;   In:       AX = the selector, already verified; SI, CX as check_buffer
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_bounds:
        lsl dx, ax                      ; DX = the segment's limit
        jnz check_refuse
        push dx
        lar dx, ax                      ; DH = the access byte
        test dh, ACC_PRESENT            ; VERR and VERW pass a segment that is
        jz .absent                      ; not present (l4.md E2, X4)
        test dh, ACC_EXPAND_DOWN        ; expand-down data (or conforming code):
        pop dx                          ; 0..limit is not its range; refuse it
        jnz check_refuse
        push si
        add si, cx                      ; CF: the buffer runs past FFFFh
        dec si                          ; SI = the last byte (DEC keeps CF)
        jc .wraps
        cmp si, dx
        ja .wraps                       ; past the limit
        pop si
        mov es, ax
        clc
        ret
.absent:
        pop dx
        stc
        ret
.wraps:
        pop si
        ; falls through

; ----------------------------------------------------------------------------
; check_refuse - the end of a refused check
;   In:       nothing
;   Out:      CF set
;   Destroys: nothing
; ----------------------------------------------------------------------------
check_refuse:
        stc
        ret

