; ============================================================================
; rx286 - src/kernel/interrupt.asm
; Every interrupt's way in and out: a stub per vector, the common entry that
; builds the frame, dispatch by vector, and the common exit.
;
; A stub pushes a zero where the CPU pushes no error code, then the vector,
; and jumps to isr_common. isr_common saves the registers (the frame of
; kernel.inc), loads the kernel's data segment, and calls the vector's
; handler with BP at the frame. A handler may change the frame: that is how
; system calls return values and how a faulting program is restarted. On the
; way back to ring 3, a restart that was asked for during a system call is
; done (D15). Then every segment register the IRET and the POPs will load is
; checked for its use, since a descriptor may have changed under it (l4.md
; X3): a DS or ES that may not be loaded becomes null, a CS or SS that may
; not is the program's fault, and so is a return IP past its limit.
; ============================================================================

; The stubs, one per vector of the IDT but the double fault's (a task gate).
%assign vector 0
%rep IDT_ENTRIES
  %if vector != VEC_DF
isr_stub_ %+ vector:
    %if vector != VEC_TS && vector != VEC_NP && vector != VEC_SS && vector != VEC_GP
        push byte 0                     ; no error code from the CPU
    %endif
        push byte vector
        jmp isr_common
  %endif
  %assign vector vector + 1
%endrep

; ----------------------------------------------------------------------------
; isr_common - the frame, the handler, the way back
;   In:       the stub's and the CPU's pushes on the current stack (ring 0)
;   Out:      returns to the interrupted code with IRET
;   Destroys: nothing of the interrupted code's but what the handler changed
;             in the frame
; ----------------------------------------------------------------------------
isr_common:
        pusha
        push ds
        push es
        mov bp, sp
        mov ax, SEL_KDATA
        mov ds, ax
        mov es, ax
        cld
%ifdef TEST_STRETCH
        mov ah, [bp + FRAME_VECTOR]     ; the place: the vector, and a kernel call
        xor al, al
        cmp ah, VEC_KCALL
        jne .place
        mov al, [bp + FRAME_AX + 1]
.place:
        STRETCH_BEGIN ax
%endif
        mov bx, [bp + FRAME_VECTOR]
        shl bx, 1
        call [isr_handlers + bx]
        ; falls through

; ----------------------------------------------------------------------------
; isr_exit - the way back: to the kernel, or to ring 3 through a switch to a
; more urgent thread, a pending restart and the checks of the frame
;   In:       BP = the frame; DS = SEL_KDATA; interrupts off
;   Out:      IRET to the frame
;   Destroys: everything but what the frame restores
; ----------------------------------------------------------------------------
isr_exit:
        test byte [bp + FRAME_CS], CPL_MASK
        jz .restore
        mov bx, [cur_thread]            ; its last capability gone (l4.md L12):
        test byte [bx + T_FLAGS], TF_DEAD   ; it never goes back
        jz .alive
        call thread_die
.alive:
        test byte [bx + T_FLAGS], TF_ORPHAN ; its space gone: it stops
        jz .whole
        call thread_orphan
.whole:
        ; A thread more urgent is ready, or the time slice is over: give way
        ; here, at the edge of ring 3, where nothing of the kernel's is half done.
        cmp byte [resched], 0
        je .restart
        call preempt
.restart:
        ; Back to ring 3 with a restart pending (Ctrl+Break or a 287 error
        ; during a system call): restart the program instead.
        cmp byte [restart_pending], 0
        je .checks
        call restart_program
.checks:
        mov bx, [cur_thread]
        mov byte [bx + T_WAY_BACK], 0
.check_segments:
        call way_back_check             ; may report a fault: the frame restarts,
        jnc .check_ip                   ; and its segments are checked in turn
        call way_back_again
        jmp .check_segments
.check_ip:
        ; IRET checks the return IP against CS's limit (Intel B-51) and would
        ; fault here, in ring 0: a program whose INT 31h is its segment's last
        ; two bytes, or one interrupted at an IP past its limit (a 286 checks
        ; the limit when it fetches). That is the program's #GP.
        mov ax, [bp + FRAME_CS]
        lsl dx, ax
        cmp [bp + FRAME_IP], dx
        jbe .restore
        mov word [bp + FRAME_VECTOR], VEC_GP
        mov word [bp + FRAME_ERROR], 0
        call fault_program
        call way_back_again
        jmp .check_segments
.restore:
        STRETCH_END
        pop es
        pop ds
        popa
        add sp, 4                       ; the vector and the error code
        iret

; ----------------------------------------------------------------------------
; way_back_again - a fault reported on the way back, and the frame restarted:
; once too often, and the restart cannot mend it (its slot 0 or 2 empty or
; wrong, its entry past its code, and no handler to put them back), the
; thread stops, said once, instead of the kernel trying for ever with
; interrupts off (l4.md L13); THREAD_START tries again
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing (perhaps after a stop)
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
way_back_again:
        mov bx, [cur_thread]
        inc byte [bx + T_WAY_BACK]
        cmp byte [bx + T_WAY_BACK], WAY_BACK_TRIES
        jb .done
        mov byte [bx + T_WAY_BACK], 0
        mov si, msg_way_back
        call klog
        mov byte [bx + T_STATE], TS_STOPPED
        call schedule                   ; back here only once started again
.done:
        ret

WAY_BACK_TRIES      equ 3

begin_kdata
msg_way_back        db "a thread cannot go back to its ring: stopped", 0
end_kdata

; ----------------------------------------------------------------------------
; way_back_check - may the frame's segments be loaded on the way back to
; ring 3? Each is checked for its own use (l4.md X3, E10): DS and ES must be
; null, or present and readable; SS present, writable data of the program's
; privilege; CS present, non-conforming code of that privilege. A check of
; presence alone is not enough: a slot refilled with execute-only code
; under DS faults the POP DS all the same.
;   In:       BP = a frame from ring 3; DS = SEL_KDATA
;   Out:      the frame changed: a DS or ES that may not be loaded is null;
;             a CS or SS that may not has been reported as the program's
;             fault, and the frame restarts it (CF set); else CF clear
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
way_back_check:
        mov cx, [bp + FRAME_CS]         ; its RPL is the program's privilege
        mov ax, [bp + FRAME_DS]
        call check_data_selector
        mov [bp + FRAME_DS], ax
        mov ax, [bp + FRAME_ES]
        call check_data_selector
        mov [bp + FRAME_ES], ax
        ; SS: present, data, writable, DPL = the program's privilege
        mov bx, [bp + FRAME_USER_SS]
        mov si, VEC_SS                  ; a stack not present: #SS, as a 286 says (E3)
        mov ah, ACC_SEGMENT | ACC_RW
        mov al, ACC_SEGMENT | ACC_CODE | ACC_RW
        call check_frame_selector
        jc .fault
        ; CS: present, code, non-conforming, DPL = the program's privilege
        mov bx, cx
        mov si, VEC_NP
        mov ah, ACC_SEGMENT | ACC_CODE
        mov al, ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN   ; (code: the conforming bit)
        call check_frame_selector
        jc .fault
        ret
.fault:
        mov [bp + FRAME_VECTOR], si
        and bx, ~CPL_MASK               ; the error code: the selector, as the CPU gives it
        mov [bp + FRAME_ERROR], bx
        call fault_program
        stc
        ret

; ----------------------------------------------------------------------------
; check_data_selector - may the program's DS or ES be reloaded?
;   In:       AX = the selector; CX = the program's CS
;   Out:      AX = the selector if null, or present and readable at the
;             program's privilege; else 0
;   Destroys: BX, DX
; ----------------------------------------------------------------------------
check_data_selector:
        test ax, ~CPL_MASK              ; null, whatever its RPL: it loads
        jz .ok
        mov bx, ax
        arpl bx, cx                     ; no more privilege than the program's
        lar dx, bx
        jnz .null
        test dh, ACC_PRESENT            ; VERR passes a segment not present (E2)
        jz .null
        verr bx                         ; data, or readable code, at that privilege
        jnz .null
.ok:
        ret
.null:
        xor ax, ax
        ret

; ----------------------------------------------------------------------------
; check_frame_selector - may the IRET load this CS or SS?
;   In:       BX = the selector; CX = the program's CS; AL = the access bits
;             to look at, AH = the value they must have; SI = the vector to
;             give for a descriptor that is not present
;   Out:      CF clear if so; else CF set and SI = the vector: VEC_GP for a
;             wrong type, a wrong privilege, or a selector past the table
;   Destroys: DX
; ----------------------------------------------------------------------------
check_frame_selector:
        push cx
        and cx, CPL_MASK                ; CX = the program's ring
        mov dx, bx
        and dx, CPL_MASK
        cmp dx, cx                      ; the selector's RPL is that ring
        jne .gp
        lar dx, bx
        jnz .gp
        mov dl, dh
        and dl, al
        cmp dl, ah                      ; the type
        jne .gp
        mov dl, dh
        and dl, ACC_DPL_MASK
        shl cl, ACC_DPL_SHIFT
        cmp dl, cl                      ; DPL = the ring
        jne .gp
        test dh, ACC_PRESENT
        jz .absent
        pop cx
        clc
        ret
.gp:
        mov si, VEC_GP
.absent:
        pop cx
        stc
        ret

begin_kdata
; The handler of each vector, called with BP at the frame and DS = ES =
; SEL_KDATA. The double fault's entry is never used: its gate is a task gate.
isr_handlers:
%assign vector 0
%rep IDT_ENTRIES
  %if vector <= VEC_CPU_LAST
        dw exception
  %elif vector <= VEC_IRQ_LAST
        dw irq
  %elif vector == VEC_KCALL
        dw kcall_handler
  %else
        dw exception                    ; 30h: only from ring 0, which never does
  %endif
  %assign vector vector + 1
%endrep
end_kdata
