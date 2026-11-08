; ============================================================================
; rx286 - src/drivers/dfits.asm
; A buffer passed to a driver, checked against its segment's limit (roadmap
; os-server.md P15). VERR and VERW say only that the segment may be read or
; written; the bytes a call moves must lie within its limit too, or the
; driver would fault in ring 1 where it is to answer E_FAULT. A driver
; checks again after each wait, as it checks the segment (dw_readable).
; ============================================================================

; ----------------------------------------------------------------------------
; dw_fits - do CX bytes at SI lie within the segment's limit, and below
; 10000h?
;   In:       BP = the segment, verified (VERR or VERW); SI = the offset; CX
;             = the bytes (0: none, which fit)
;   Out:      CF clear if so; CF set if they pass its limit or FFFFh
;   Destroys: nothing
; ----------------------------------------------------------------------------
dw_fits:
        jcxz .fits
        push ax
        push si
        lsl ax, bp                      ; AX = its limit
        jnz .past
        add si, cx                      ; (a carry and 0: its last byte FFFFh)
        jnc .last
        test si, si
        jnz .past
.last:
        dec si                          ; SI = its last byte
        cmp si, ax
        ja .past
        pop si
        pop ax
.fits:
        clc
        ret
.past:
        pop si
        pop ax
        stc
        ret
