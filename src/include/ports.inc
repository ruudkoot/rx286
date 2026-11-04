; ============================================================================
; rx286 - src/include/ports.inc
; Every I/O port of the IBM PC/AT that rx286 knows, by name, and the bits
; and commands it uses.
;
; The machine is fixed (docs/hardware.md); nothing here is detected.
; Sources: IBM, Technical Reference: Personal Computer AT (1984), 1-28 and
; 1-40 to 1-44; the device data sheets for the register details.
; ============================================================================

%ifndef RX286_PORTS_INC
%define RX286_PORTS_INC

; ---------------------------------------------------------------- 8237A DMA (never touched)
DMA1_BASE           equ 0x000       ; 000h-01Fh, channels 0-3
DMA_PAGE_BASE       equ 0x080       ; 080h-08Fh
DMA2_BASE           equ 0x0C0       ; 0C0h-0DFh, channels 4-7

; ---------------------------------------------------------------- 8259A interrupt controllers
PIC1_CMD            equ 0x020       ; master: ICW1, OCW2, OCW3
PIC1_DATA           equ 0x021       ; master: ICW2-4, OCW1 (mask)
PIC2_CMD            equ 0x0A0       ; slave
PIC2_DATA           equ 0x0A1
PIC_ICW1_ICW4       equ 0x11        ; edge triggered, cascaded, ICW4 follows
PIC1_VECTOR_BASE    equ 0x20        ; ICW2: IRQ0-7 on vectors 20h-27h
PIC2_VECTOR_BASE    equ 0x28        ; ICW2: IRQ8-15 on vectors 28h-2Fh
PIC1_ICW3_SLAVE_AT  equ 0x04        ; ICW3 master: a slave on IR2
PIC2_ICW3_ID        equ 0x02        ; ICW3 slave: cascade identity 2
PIC_ICW4_8086       equ 0x01        ; 8086 mode, normal EOI
PIC_EOI             equ 0x20        ; OCW2: non-specific end of interrupt
PIC_READ_ISR        equ 0x0B        ; OCW3: the next read of the command port gives ISR
PIC_CASCADE_IRQ     equ 2

; ---------------------------------------------------------------- 8254 timer
PIT_CH0             equ 0x040       ; the system timer, IRQ0
PIT_CH1             equ 0x041       ; DRAM refresh: never touched
PIT_CH2             equ 0x042       ; the speaker
PIT_MODE            equ 0x043
PIT_CH0_LOHI_MODE3  equ 0x36        ; channel 0, low then high byte, square wave, binary
PIT_INPUT_HZ        equ 1193182
PIT_HZ              equ 50          ; roadmap D14
PIT_DIVISOR         equ (PIT_INPUT_HZ + PIT_HZ / 2) / PIT_HZ    ; 23864

; ---------------------------------------------------------------- 8042 keyboard controller
KBC_DATA            equ 0x060       ; data in and out
KBC_STATUS          equ 0x064       ; read: status
KBC_COMMAND         equ 0x064       ; write: command
KBC_STATUS_OBF      equ 0x01        ; output buffer full: a byte waits at 60h
KBC_STATUS_IBF      equ 0x02        ; input buffer full: wait before writing
KBC_CMD_WRITE_CB    equ 0x60        ; write the command byte (next byte at 60h)
KBC_CMD_WRITE_OUT   equ 0xD2        ; PS/2 only: write the keyboard output buffer (test builds)
KBC_CMD_PULSE_RESET equ 0xFE        ; pulse output port bit 0: resets the CPU
KBC_COMMAND_BYTE    equ 0x45        ; translate to set 1 (bit 6), system flag (2), IRQ1 (0)

; ---------------------------------------------------------------- system port B
SYS_PORT_B          equ 0x061
SYS_PORT_B_PARITY   equ 0x80        ; read: parity check (NMI source)
SYS_PORT_B_IOCHK    equ 0x40        ; read: I/O channel check (NMI source)

; ---------------------------------------------------------------- MC146818 RTC and CMOS
CMOS_INDEX          equ 0x070       ; bit 7 set disables NMI
CMOS_DATA           equ 0x071
CMOS_NMI_DISABLE    equ 0x80
CMOS_SECONDS        equ 0x00
CMOS_MINUTES        equ 0x02
CMOS_HOURS          equ 0x04
CMOS_DAY            equ 0x07
CMOS_MONTH          equ 0x08
CMOS_YEAR           equ 0x09
CMOS_REG_A          equ 0x0A
CMOS_REG_B          equ 0x0B
CMOS_REG_C          equ 0x0C
CMOS_REG_D          equ 0x0D
CMOS_SHUTDOWN       equ 0x0F        ; the BIOS's shutdown status byte; 0 = soft reset
CMOS_CENTURY        equ 0x32
CMOS_REG_A_UIP      equ 0x80        ; update in progress
CMOS_REG_A_RATE_1K  equ 0x26        ; 32 kHz base, 1,024 Hz periodic rate (test probe)
CMOS_REG_B_24H_BCD  equ 0x02        ; 24-hour, BCD, no interrupts
CMOS_REG_B_PIE      equ 0x40        ; periodic interrupt enable (test probe)

; ---------------------------------------------------------------- 80287
FPU_CLEAR_BUSY      equ 0x0F0       ; write 0: clear the latched BUSY after an error
FPU_RESET           equ 0x0F1       ; write 0: reset the 287 (never used)

; ---------------------------------------------------------------- fixed disk controller
HDC_DATA            equ 0x1F0
HDC_ERROR           equ 0x1F1
HDC_SECTOR_COUNT    equ 0x1F2
HDC_SECTOR          equ 0x1F3
HDC_CYLINDER_LOW    equ 0x1F4
HDC_CYLINDER_HIGH   equ 0x1F5
HDC_DRIVE_HEAD      equ 0x1F6
HDC_STATUS          equ 0x1F7       ; read
HDC_COMMAND         equ 0x1F7       ; write
HDC_CONTROL         equ 0x3F6
HDC_STATUS_BSY      equ 0x80
HDC_CMD_RECALIBRATE equ 0x10        ; test probe: makes the controller raise IRQ14

; ---------------------------------------------------------------- game port, printers, serial
GAME_PORT           equ 0x201
LPT1_BASE           equ 0x378
LPT2_BASE           equ 0x278
COM1_BASE           equ 0x3F8
COM2_BASE           equ 0x2F8
COM3_BASE           equ 0x3E8
COM4_BASE           equ 0x2E8
UART_THR            equ 0           ; write: transmit holding
UART_RBR            equ 0           ; read: receive buffer
UART_DLL            equ 0           ; divisor latch, low (DLAB = 1)
UART_DLM            equ 1           ; divisor latch, high (DLAB = 1)
UART_IER            equ 1           ; interrupt enable
UART_LCR            equ 3           ; line control
UART_MCR            equ 4           ; modem control
UART_LSR            equ 5           ; line status
UART_LCR_DLAB       equ 0x80
UART_LCR_8N1        equ 0x03
UART_MCR_DTR_RTS    equ 0x03        ; OUT2 clear: the UART's interrupt stays off the bus
UART_LSR_THRE       equ 0x20        ; transmit holding register empty
UART_LSR_TEMT       equ 0x40        ; transmitter empty: the last byte has gone
UART_DIVISOR_115200 equ 1           ; 1.8432 MHz / 16 / 1

; ---------------------------------------------------------------- EGA
EGA_ATTR            equ 0x3C0       ; 3C0h-3CFh: attribute, sequencer, graphics, misc
CRTC_INDEX          equ 0x3D4       ; colour CRTC
CRTC_DATA           equ 0x3D5
EGA_STATUS1         equ 0x3DA
CRTC_CURSOR_HIGH    equ 0x0E
CRTC_CURSOR_LOW     equ 0x0F

; ---------------------------------------------------------------- diskette controller
FDC_DOR             equ 0x3F2       ; digital output register
FDC_MSR             equ 0x3F4       ; main status
FDC_DATA            equ 0x3F5
FDC_DIR             equ 0x3F7
FDC_DOR_MOTORS_OFF  equ 0x0C        ; controller enabled, DMA/IRQ enabled, every motor off
FDC_DOR_RESET       equ 0x00        ; controller in reset (test probe: IRQ6 on release)

; ---------------------------------------------------------------- Bochs only (test builds)
BOCHS_SHUTDOWN_PORT equ 0x8900      ; write "Shutdown" to end Bochs

%endif
