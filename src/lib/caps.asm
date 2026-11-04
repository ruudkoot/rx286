; ============================================================================
; rx286 - src/lib/caps.asm
; Pure arithmetic of capabilities: where retype places an object, and which
; slot a selector names (roadmap l4.md L3).
;
; Neither touches memory or a port; the kernel assembles them (cap.asm) and
; the host tests run them (tests/unit/test_caps.py).
; ============================================================================

; ----------------------------------------------------------------------------
; retype_place - where an object goes in an untyped: at the first multiple of
; its alignment at or above the watermark, if it fits before the end
;   In:       AX = the watermark (paragraphs used); BX = the untyped's size
;             (paragraphs); CX = the object's size (paragraphs, > 0); DX =
;             its alignment (paragraphs, a power of two)
;   Out:      CF clear, AX = the object's place and DX = the new watermark
;             (paragraphs from the untyped's base); CF set if it does not fit
;   Destroys: nothing
; ----------------------------------------------------------------------------
retype_place:
        dec dx                          ; the alignment's mask
        add ax, dx
        jc .full
        not dx
        and ax, dx
        mov dx, ax
        add dx, cx
        jc .full
        cmp dx, bx
        ja .full
        clc
        ret
.full:
        stc
        ret

; ----------------------------------------------------------------------------
; selector_slot - the slot an LDT selector names, if within a table of so
; many slots; any RPL
;   In:       AX = the selector; CX = the slots
;   Out:      CF clear and AX = the slot; CF set if the selector is the
;             GDT's (TI clear) or past the table
;   Destroys: nothing
; ----------------------------------------------------------------------------
selector_slot:
        test al, 4                      ; the table indicator: the GDT's never names a slot
        jz .refuse
        shr ax, 3
        cmp ax, cx
        jae .refuse
        clc
        ret
.refuse:
        stc
        ret
