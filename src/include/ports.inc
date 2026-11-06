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

; ---------------------------------------------------------------- 8237A DMA
; Channel 2 carries the diskette's sectors; channel 4, controller 2's first,
; is the cascade from controller 1 (IBM 1-12 to 1-15). Controller 2's
; registers sit at every other port.
DMA1_BASE           equ 0x000       ; 000h-01Fh, channels 0-3
DMA1_CH2_ADDRESS    equ 0x004       ; channel 2's address bits 0-15: low byte, then high
DMA1_CH2_COUNT      equ 0x005       ; channel 2's count less one: low byte, then high
DMA1_MASK           equ 0x00A       ; single mask: bits 0-1 the channel, bit 2 set to mask
DMA1_MODE           equ 0x00B
DMA1_CLEAR_FLIPFLOP equ 0x00C       ; any write: the next byte is a low byte
DMA1_MASTER_CLEAR   equ 0x00D       ; any write: reset, every channel masked
DMA_PAGE_BASE       equ 0x080       ; 080h-08Fh
DMA_PAGE_CH2        equ 0x081       ; channel 2's address bits 16-23
DMA2_BASE           equ 0x0C0       ; 0C0h-0DFh, channels 4-7
DMA2_MASK           equ 0x0D4
DMA2_MODE           equ 0x0D6
DMA2_MASTER_CLEAR   equ 0x0DA
DMA_CHANNEL_DISKETTE equ 2
DMA_MASK_SET        equ 0x04
DMA_MODE_TO_MEMORY  equ 0x44        ; single transfer, address up, no auto-init, device to memory
DMA_MODE_FROM_MEMORY equ 0x48       ; the same, memory to device
DMA_MODE_CASCADE    equ 0xC0        ; with channel 0 of controller 2: channel 4 cascades

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
PIT_CH2_LOHI_MODE3  equ 0xB6        ; channel 2, the same
PIT_LATCH_CH0       equ 0x00        ; latch channel 0's count: the next two reads give it
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
KBC_CMD_WRITE_PORT  equ 0xD1        ; write the output port (next byte at 60h)
KBC_PORT_A20        equ 0xDF        ; the output port with A20 on, the CPU not reset (IBM 1-41)
KBC_COMMAND_BYTE    equ 0x45        ; translate to set 1 (bit 6), system flag (2), IRQ1 (0)

; ---------------------------------------------------------------- system port B
SYS_PORT_B          equ 0x061
SYS_PORT_B_PARITY   equ 0x80        ; read: parity check (NMI source)
SYS_PORT_B_IOCHK    equ 0x40        ; read: I/O channel check (NMI source)
SYS_PORT_B_OUT2     equ 0x20        ; read: timer channel 2's output
SYS_PORT_B_GATE2    equ 0x01        ; write: let timer channel 2 count
SYS_PORT_B_SPEAKER  equ 0x02        ; write: channel 2's output to the speaker

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
CMOS_EXT_LOW        equ 0x30        ; the KB of extended memory the POST found
CMOS_EXT_HIGH       equ 0x31
CMOS_REG_A_UIP      equ 0x80        ; update in progress
CMOS_REG_A_RATE_1K  equ 0x26        ; 32 kHz base, 1,024 Hz periodic rate (test probe)
CMOS_REG_B_24H_BCD  equ 0x02        ; 24-hour, BCD, no interrupts
CMOS_REG_B_PIE      equ 0x40        ; periodic interrupt enable (test probe)

; ---------------------------------------------------------------- 80287
FPU_CLEAR_BUSY      equ 0x0F0       ; write 0: clear the latched BUSY after an error
FPU_RESET           equ 0x0F1       ; write 0: reset the 287 (never used)

; ---------------------------------------------------------------- fixed disk controller
HDC_DATA            equ 0x1F0
HDC_ERROR           equ 0x1F1       ; read
HDC_PRECOMP         equ 0x1F1       ; write: the cylinder where precompensation starts, / 4
HDC_SECTOR_COUNT    equ 0x1F2
HDC_SECTOR          equ 0x1F3
HDC_CYLINDER_LOW    equ 0x1F4
HDC_CYLINDER_HIGH   equ 0x1F5
HDC_DRIVE_HEAD      equ 0x1F6
HDC_STATUS          equ 0x1F7       ; read
HDC_COMMAND         equ 0x1F7       ; write
HDC_CONTROL         equ 0x3F6
HDC_STATUS_BSY      equ 0x80        ; busy: no other bit is valid
HDC_STATUS_WRITE_FAULT equ 0x20
HDC_STATUS_DRQ      equ 0x08        ; data request: the sector buffer wants service
HDC_STATUS_ERR      equ 0x01        ; the error register says why
HDC_DRIVE_HEAD_BASE equ 0xA0        ; bits 7 and 5 always set; bit 4 the drive, 0-3 the head
HDC_DRIVE_1         equ 0x10
HDC_CONTROL_RESET   equ 0x04        ; the fixed disk register: reset the controller
HDC_CONTROL_RUN     equ 0x00        ; out of reset, at most 8 heads
HDC_CMD_RESTORE     equ 0x10        ; heads to cylinder 0; implied seeks step at 35 us
HDC_CMD_READ        equ 0x20        ; read sectors, with retries
HDC_CMD_WRITE       equ 0x30        ; write sectors, with retries
HDC_CMD_SET_PARAMETERS equ 0x91     ; heads (drive/head register) and sectors a track (count)
HDC_PRECOMP_SHIFT   equ 2           ; the precompensation register holds the cylinder / 4

; ---------------------------------------------------------------- game port, printers, serial
GAME_PORT           equ 0x201       ; write: start the axes' one-shots; read: as below
GAME_PORT_AXES      equ 0x0F        ; an axis's bit is 1 while its one-shot runs
GAME_PORT_BUTTONS   equ 0xF0        ; a button's bit is 0 while it is pressed
GAME_PORT_BUTTON_SHIFT equ 4
LPT1_BASE           equ 0x378
LPT2_BASE           equ 0x278
LPT_DATA            equ 0           ; offsets from an LPT*_BASE: the data latch
LPT_STATUS          equ 1
LPT_CONTROL         equ 2
LPT_STATUS_NOT_BUSY equ 0x80        ; -BUSY: the printer takes a byte
LPT_STATUS_PAPER_END equ 0x20
LPT_CONTROL_INIT    equ 0x08        ; select, -INIT low: the printer resets
LPT_CONTROL_READY   equ 0x0C        ; select, -INIT high; no line feed, no interrupt
LPT_CONTROL_STROBE  equ 0x0D        ; the same with +STROBE: the printer takes the byte
LPT_CONTROL_IRQ     equ 0x10        ; an interrupt when -ACK ends (test probe only)
COM1_BASE           equ 0x3F8
COM2_BASE           equ 0x2F8
COM3_BASE           equ 0x3E8
COM4_BASE           equ 0x2E8
UART_THR            equ 0           ; write: transmit holding
UART_RBR            equ 0           ; read: receive buffer
UART_DLL            equ 0           ; divisor latch, low (DLAB = 1)
UART_DLM            equ 1           ; divisor latch, high (DLAB = 1)
UART_IER            equ 1           ; interrupt enable
UART_IER_RECEIVED   equ 0x01        ; an interrupt when a byte has come
UART_FCR            equ 2           ; write: FIFO control (a 16550's; nothing on an 8250 or 16450)
UART_IIR            equ 2           ; read: interrupt identification
UART_LCR            equ 3           ; line control
UART_MCR            equ 4           ; modem control
UART_LSR            equ 5           ; line status
UART_LCR_DLAB       equ 0x80
UART_LCR_8N1        equ 0x03
UART_LCR_7N1        equ 0x02        ; 7 data bits, no parity, 1 stop bit: a serial mouse's
UART_MCR_DTR_RTS    equ 0x03        ; OUT2 clear: the UART's interrupt stays off the bus
UART_MCR_RUN        equ 0x0B        ; DTR, RTS and OUT2: interrupts reach the bus
UART_MCR_OFF        equ 0x00        ; DTR and RTS low: a serial mouse's reset
UART_LSR_DATA       equ 0x01        ; a byte waits in the receive buffer
UART_LSR_OVERRUN    equ 0x02        ; a byte came before the last was read: lost
UART_LSR_ABSENT     equ 0xFF        ; what a port with no UART reads
UART_FCR_FIFO       equ 0x07        ; FIFOs on and emptied, an interrupt for each byte
UART_IIR_FIFO       equ 0xC0        ; both set: the FIFOs are on (a 16550A)
UART_FIFO_BYTES     equ 16          ; what a 16550's transmit FIFO holds
UART_LSR_THRE       equ 0x20        ; transmit holding register empty
UART_LSR_TEMT       equ 0x40        ; transmitter empty: the last byte has gone
UART_DIVISOR_115200 equ 1           ; 1.8432 MHz / 16 / 1
UART_DIVISOR_9600   equ 12          ; the modem
UART_DIVISOR_1200   equ 96          ; a serial mouse

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
FDC_DIR             equ 0x3F7       ; read: digital input (bit 7: the diskette was changed)
FDC_CCR             equ 0x3F7       ; write: the data rate
FDC_DOR_MOTORS_OFF  equ 0x0C        ; controller enabled, DMA/IRQ enabled, every motor off
FDC_DOR_RESET       equ 0x00        ; controller in reset (IRQ6 on release)
FDC_DOR_MOTOR_A     equ 0x10        ; drive A's motor; drive B's is the next bit
FDC_DOR_MOTORS      equ 0x30        ; both motors' bits
FDC_MSR_RQM         equ 0x80        ; the data register is ready
FDC_MSR_DIO         equ 0x40        ; set: controller to processor
FDC_RATE_500K       equ 0x00        ; 1.2 MB media in a 1.2 MB drive
FDC_RATE_250K       equ 0x02        ; 360 KB media in a 360 KB drive
FDC_CMD_SPECIFY     equ 0x03
FDC_CMD_RECALIBRATE equ 0x07
FDC_CMD_SENSE_INT   equ 0x08
FDC_CMD_SEEK        equ 0x0F
FDC_CMD_READ        equ 0x46        ; read data, MFM
FDC_CMD_WRITE       equ 0x45        ; write data, MFM
FDC_SPECIFY_1       equ 0xDF        ; step rate and head unload: the BIOS's (5-170)
FDC_SPECIFY_2       equ 0x02        ; head load 2 ms, DMA
FDC_SIZE_512        equ 2           ; N: 128 << 2 bytes a sector
FDC_DTL             equ 0xFF        ; unused with N = 2
FDC_GAP_1200K       equ 0x1B        ; gap 3: 1.2 MB media in a 1.2 MB drive (BIOS)
FDC_GAP_360K        equ 0x2A        ; 360 KB media in a 360 KB drive
FDC_ST0_CODE        equ 0xC0        ; ST0's interrupt code: 0 when the command succeeded
FDC_ST0_SEEK_END    equ 0x20
FDC_ST1_NOT_WRITABLE equ 0x02       ; the diskette is write-protected

; ---------------------------------------------------------------- Bochs only (test builds)
BOCHS_SHUTDOWN_PORT equ 0x8900      ; write "Shutdown" to end Bochs

%endif
