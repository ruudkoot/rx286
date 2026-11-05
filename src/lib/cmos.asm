; ============================================================================
; rx286 - src/lib/cmos.asm
; The MC146818 real-time clock, read for the `time` call (roadmap D20 B):
; the kernel sets it up at its start, and the RTC driver reads it (l4.md
; L10); the kernel's test hooks read it too.
;
; rtc_init sets register B to 24-hour BCD with every interrupt off, so the
; clock never raises IRQ8 and its format is known, not detected. The clock
; is read by polling: wait until no update is in progress, read every field,
; and read again if the seconds moved meanwhile. Every write to the index
; port keeps bit 7 clear, which keeps NMI enabled. Only one reader at a
; time: the index port and the data port are a pair.
; ============================================================================

RTC_UIP_LIMIT       equ 2000            ; polls of UIP before reading anyway

; ----------------------------------------------------------------------------
; rtc_init - 24-hour BCD, no interrupts, no flag left pending
;   In:       nothing
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
rtc_init:
        mov al, CMOS_REG_B
        out CMOS_INDEX, al
        mov al, CMOS_REG_B_24H_BCD
        out CMOS_DATA, al
        mov al, CMOS_REG_C              ; reading C clears its flags
        out CMOS_INDEX, al
        in al, CMOS_DATA
        ret

; ----------------------------------------------------------------------------
; rtc_read - the date and time, in BCD
;   In:       nothing
;   Out:      CH = century, CL = year, DH = month, DL = day, BH = hours,
;             BL = minutes, AL = seconds; all BCD
;   Destroys: AH
; ----------------------------------------------------------------------------
rtc_read:
.again:
        push cx
        mov cx, RTC_UIP_LIMIT
.uip:
        mov al, CMOS_REG_A
        out CMOS_INDEX, al
        in al, CMOS_DATA
        test al, CMOS_REG_A_UIP
        loopnz .uip
        pop cx
        mov al, CMOS_CENTURY
        call rtc_get
        mov ch, al
        mov al, CMOS_YEAR
        call rtc_get
        mov cl, al
        mov al, CMOS_MONTH
        call rtc_get
        mov dh, al
        mov al, CMOS_DAY
        call rtc_get
        mov dl, al
        mov al, CMOS_HOURS
        call rtc_get
        mov bh, al
        mov al, CMOS_MINUTES
        call rtc_get
        mov bl, al
        mov al, CMOS_SECONDS
        call rtc_get
        mov ah, al
        mov al, CMOS_SECONDS            ; an update in between: read it all again
        call rtc_get
        cmp al, ah
        jne .again
        ret

; ----------------------------------------------------------------------------
; rtc_get - one CMOS byte
;   In:       AL = its index (bit 7 clear: NMI stays enabled)
;   Out:      AL = its value
;   Destroys: nothing
; ----------------------------------------------------------------------------
rtc_get:
        out CMOS_INDEX, al
        in al, CMOS_DATA
        ret
