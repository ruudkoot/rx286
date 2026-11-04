# The machine

rx286 runs on one machine, written down here and never detected: an IBM PC/AT
(model 5170) with every device of the roadmap's draft. `src/include/ports.inc`
names every port below; `bochs/rx286.bochsrc.in` describes the same machine to
Bochs, and `tools/check-docs` keeps the three in step.

The sources are IBM's *Technical Reference: Personal Computer AT* (March 1984)
and Intel's *80286 and 80287 Programmer's Reference Manual* (1987); the page
numbers below are the Technical Reference's.

## The parts

| Part | What | rx286 |
|---|---|---|
| CPU | Intel 80286, 6 MHz (1-7) | protected mode, 16-bit, only 286 instructions |
| Coprocessor | Intel 80287 | available to the program; errors on IRQ13 |
| Memory | 640 KB base; extended memory unused | the base only |
| Interrupt controllers | two 8259A, the slave on the master's IR2 | vectors 20h-2Fh |
| Timer | 8254: channel 0 the system timer, 1 DRAM refresh, 2 the speaker | channel 0 only, at 50 Hz |
| Keyboard controller | 8042, AT 84-key keyboard, scan codes translated to set 1 | the keyboard driver |
| Real-time clock | MC146818 with CMOS RAM; port 70h bit 7 masks NMI | the clock (`date`), the NMI mask, the shutdown byte before a reset |
| DMA | two 8237A: channels 0-3 8-bit, 4 cascade, 5-7 16-bit | channel 2, for the diskettes |
| Diskette | controller at 3F0h-3F7h, IRQ6, DMA 2; A: 1.2 MB 5.25", B: 360 KB 5.25" | the diskette driver (and the BIOS, in the boot code) |
| Fixed disk | controller at 1F0h-1F7h, IRQ14; drive 0 type 2 (615/4/17, 20 MB), drive 1 type 1 (306/4/17, 10 MB) | the fixed disk driver |
| Serial | COM1 3F8h IRQ4, COM2 2F8h IRQ3, COM3 3E8h IRQ4, COM4 2E8h IRQ3 | COM1 output in debug and test builds |
| Parallel | LPT1 378h IRQ7, LPT2 278h IRQ5 | the printer driver, polled |
| Video | IBM EGA, colour display, 80x25 text at B8000h | the console |

## I/O ports

| Ports | Device | Names in ports.inc | rx286 touches |
|---|---|---|---|
| 000h-01Fh | DMA controller 1 | `DMA1_BASE`, `DMA1_CH2_ADDRESS`, `DMA1_CH2_COUNT`, `DMA1_MASK`, `DMA1_MODE`, `DMA1_CLEAR_FLIPFLOP`, `DMA1_MASTER_CLEAR` | reset at start; channel 2 for each diskette sector |
| 020h-021h | PIC 1 (master) | `PIC1_CMD`, `PIC1_DATA` | ICW1-4, mask, EOI, ISR |
| 040h-043h | 8254 timer | `PIT_CH0`, `PIT_CH1`, `PIT_CH2`, `PIT_MODE` | channel 0 only |
| 060h, 064h | 8042: data, status/command | `KBC_DATA`, `KBC_STATUS`, `KBC_COMMAND` | the keyboard driver; FEh to reset |
| 061h | system port B | `SYS_PORT_B` | read by the NMI handler |
| 070h-071h | RTC/CMOS index and data | `CMOS_INDEX`, `CMOS_DATA` | the clock; NMI mask; shutdown byte |
| 080h-08Fh | DMA page registers | `DMA_PAGE_BASE`, `DMA_PAGE_CH2` | channel 2's |
| 0A0h-0A1h | PIC 2 (slave) | `PIC2_CMD`, `PIC2_DATA` | as PIC 1 |
| 0C0h-0DFh | DMA controller 2 | `DMA2_BASE`, `DMA2_MASK`, `DMA2_MODE`, `DMA2_MASTER_CLEAR` | reset at start; channel 4 the cascade |
| 0F0h | clear the 287's busy latch | `FPU_CLEAR_BUSY` | the IRQ13 handler |
| 0F1h | reset the 287 | `FPU_RESET` | never |
| 1F0h-1F7h, 3F6h | fixed disk controller | `HDC_DATA`, `HDC_ERROR`, `HDC_PRECOMP`, `HDC_SECTOR_COUNT`, `HDC_SECTOR`, `HDC_CYLINDER_LOW`, `HDC_CYLINDER_HIGH`, `HDC_DRIVE_HEAD`, `HDC_STATUS`, `HDC_COMMAND`, `HDC_CONTROL` | the fixed disk driver |
| 201h | game port | `GAME_PORT` | never |
| 278h-27Ah | LPT2 | `LPT2_BASE` | the printer driver |
| 2E8h-2EFh | COM4 | `COM4_BASE` | never |
| 2F8h-2FFh | COM2 | `COM2_BASE` | never |
| 378h-37Ah | LPT1 | `LPT1_BASE` | the printer driver |
| 3C0h-3CFh | EGA attribute, sequencer, graphics, misc | `EGA_ATTR` | never (the loader's INT 10h sets the mode) |
| 3D4h-3D5h | EGA CRTC (colour) | `CRTC_INDEX`, `CRTC_DATA` | the cursor's location |
| 3DAh | EGA input status 1 | `EGA_STATUS1` | never |
| 3E8h-3EFh | COM3 | `COM3_BASE` | never |
| 3F0h-3F7h | diskette controller | `FDC_DOR`, `FDC_MSR`, `FDC_DATA`, `FDC_DIR`, `FDC_CCR` | the diskette driver; DOR: the loader stops the motor |
| 3F8h-3FFh | COM1 | `COM1_BASE` | debug and test builds |
| 8900h | Bochs' shutdown port, not AT hardware | `BOCHS_SHUTDOWN_PORT` | test builds only |

### Bits and commands

- **8259A** (`PIC_*`): `PIC_ICW1_ICW4` starts the initialisation (edge
  triggered, cascaded, ICW4 follows); `PIC1_VECTOR_BASE` and
  `PIC2_VECTOR_BASE` are ICW2; `PIC1_ICW3_SLAVE_AT` and `PIC2_ICW3_ID` wire
  the slave to IR2 (`PIC_CASCADE_IRQ`); `PIC_ICW4_8086` is ICW4; `PIC_EOI` is
  the non-specific end of interrupt; `PIC_READ_ISR` makes the next read of the
  command port return the in-service register, which tells a spurious IRQ7 or
  IRQ15 from a real one.
- **8254** (`PIT_*`): `PIT_CH0_LOHI_MODE3` programs channel 0 as a square wave,
  low byte then high byte. `PIT_INPUT_HZ` is the input clock, `PIT_HZ` the
  rate rx286 wants and `PIT_DIVISOR` the divisor that gives it (23864).
  Channel 1 refreshes the DRAM and is never touched (1-8).
- **8042** (`KBC_*`): `KBC_STATUS_OBF` (a byte waits at 60h) and
  `KBC_STATUS_IBF` (wait before writing). `KBC_CMD_WRITE_CB` writes the
  command byte, `KBC_COMMAND_BYTE` = 45h: translation to set 1 (bit 6), the
  system flag (bit 2), the keyboard interrupt (bit 0), as IBM defines them
  (1-40). `KBC_CMD_PULSE_RESET` (FEh) pulses output-port bit 0, which resets
  the CPU (1-42). `KBC_CMD_WRITE_OUT` (D2h) is not the AT's: it is the PS/2
  controller's "write keyboard output buffer", which Bochs has; test builds
  use it to type keys.
- **System port B** (`SYS_PORT_B`): `SYS_PORT_B_PARITY` and
  `SYS_PORT_B_IOCHK` say which of the AT's two causes raised an NMI.
- **MC146818** (`CMOS_*`): the clock's registers `CMOS_SECONDS`,
  `CMOS_MINUTES`, `CMOS_HOURS`, `CMOS_DAY`, `CMOS_MONTH`, `CMOS_YEAR`,
  `CMOS_CENTURY`; the control registers `CMOS_REG_A` (with
  `CMOS_REG_A_UIP`, update in progress, and `CMOS_REG_A_RATE_1K` for the
  test probe), `CMOS_REG_B` (`CMOS_REG_B_24H_BCD`, which rx286 sets;
  `CMOS_REG_B_PIE`, the probe's periodic interrupt), `CMOS_REG_C` (reading
  it acknowledges the clock's interrupt) and `CMOS_REG_D`; `CMOS_SHUTDOWN` is
  the BIOS's shutdown status byte (1-49), 0 for a soft reset (the BIOS
  listing's table of shutdown codes).
  `CMOS_NMI_DISABLE` is bit 7 of the index port: set, NMI is masked (1-28).
- **80287**: `FPU_CLEAR_BUSY` (F0h) clears the busy latch an error leaves;
  `FPU_RESET` (F1h) would reset the 287 into real mode (2-4).
- **8237A** (`DMA_*`): `DMA_CHANNEL_DISKETTE` is channel 2. A channel is
  masked by writing its number with `DMA_MASK_SET` to the single-mask
  register, unmasked by its number alone. `DMA_MODE_TO_MEMORY` (a diskette
  read) and `DMA_MODE_FROM_MEMORY` (a write) are single transfers, the
  address counting up, no auto-initialisation, with the channel's number
  added; `DMA_MODE_CASCADE` puts controller 2's channel 0, channel 4, in
  cascade mode for controller 1. After `DMA1_CLEAR_FLIPFLOP` the next byte to
  an address or count register is its low byte. The AT's DRAM refresh is
  not a DMA channel (1-12), so both controllers may be reset.
- **Diskette** (`FDC_*`, the NEC 765): `FDC_DOR_MOTORS_OFF` keeps the
  controller enabled with DMA and IRQ6 on and every motor off;
  `FDC_DOR_MOTOR_A` is drive A's motor and the next bit drive B's
  (`FDC_DOR_MOTORS` both); bit 0 selects the drive. `FDC_DOR_RESET` holds the
  controller in reset; releasing it raises IRQ6. In the main status,
  `FDC_MSR_RQM` says the data register is ready and `FDC_MSR_DIO` which way.
  `FDC_CCR` sets the data rate: `FDC_RATE_500K` for A's 1.2 MB, `FDC_RATE_250K`
  for B's 360 KB. The commands: `FDC_CMD_SPECIFY` with the BIOS's
  `FDC_SPECIFY_1` and `FDC_SPECIFY_2` (5-170); `FDC_CMD_RECALIBRATE`,
  `FDC_CMD_SEEK` and `FDC_CMD_SENSE_INT` after their interrupt;
  `FDC_CMD_READ` and `FDC_CMD_WRITE` (MFM) with `FDC_SIZE_512`, `FDC_DTL` and
  the BIOS's gap, `FDC_GAP_1200K` or `FDC_GAP_360K`. In the results,
  `FDC_ST0_CODE` is 0 for success and `FDC_ST0_SEEK_END` follows a seek;
  `FDC_ST1_NOT_WRITABLE` means write-protected.
- **Fixed disk** (`HDC_*`, the task file of IBM's adapter, 1-2 to 1-9 of its
  section): the status bits `HDC_STATUS_BSY` (no other bit is valid),
  `HDC_STATUS_WRITE_FAULT`, `HDC_STATUS_DRQ` and `HDC_STATUS_ERR`; reading the
  status clears IRQ14. The drive/head register is `HDC_DRIVE_HEAD_BASE`, with
  `HDC_DRIVE_1` for the second drive, and the head. `HDC_PRECOMP` takes the
  precompensation cylinder shifted right by `HDC_PRECOMP_SHIFT`. In the fixed
  disk register, `HDC_CONTROL_RESET` resets the controller and
  `HDC_CONTROL_RUN` lets it run. The commands: `HDC_CMD_SET_PARAMETERS`,
  `HDC_CMD_RESTORE` (whose step rate, 35 us, implied seeks then use),
  `HDC_CMD_READ`, `HDC_CMD_WRITE`.
- **Printer** (`LPT_*`, offsets `LPT_DATA`, `LPT_STATUS`, `LPT_CONTROL` from
  an `LPT*_BASE`; the Serial/Parallel Adapter's section): `LPT_STATUS_NOT_BUSY`
  set means the printer takes a byte, `LPT_STATUS_PAPER_END` that it has no
  paper. `LPT_CONTROL_INIT` holds -INIT low to reset the printer;
  `LPT_CONTROL_READY` is the resting state; `LPT_CONTROL_STROBE` pulses
  STROBE. `LPT_CONTROL_IRQ` turns on the port's interrupt, which only a test
  build's probe does.
- **UART** (8250/16450; `UART_*` are offsets from a `COM*_BASE`):
  `UART_THR`, `UART_RBR`, `UART_DLL`, `UART_DLM`, `UART_IER`, `UART_LCR`,
  `UART_MCR`, `UART_LSR`; `UART_LCR_DLAB` opens the divisor latch,
  `UART_LCR_8N1` sets 8 data bits, no parity, 1 stop bit;
  `UART_MCR_DTR_RTS` raises DTR and RTS but not OUT2, so the UART's
  interrupt never reaches the bus; `UART_LSR_THRE` (room for a byte) and
  `UART_LSR_TEMT` (the last byte has gone); `UART_DIVISOR_115200`.
- **EGA**: `CRTC_CURSOR_HIGH` and `CRTC_CURSOR_LOW` hold the cursor's
  position.

## Interrupts

The vectors are those after the kernel programs the 8259As. *docs/interrupts.md*
gives the rule for each line.

| IRQ | Vector | Device (1-10, 1-11) | rx286 |
|---|---|---|---|
| 0 | 20h | timer channel 0 | timer driver |
| 1 | 21h | keyboard (8042) | keyboard driver |
| 2 | 22h | cascade from PIC 2 | never delivered; never masked |
| 3 | 23h | COM2, COM4 | unhandled: reported once, then masked |
| 4 | 24h | COM1, COM3 | unhandled (the log is polled, its interrupt off) |
| 5 | 25h | LPT2 | unhandled: the printer driver keeps the port's interrupt off |
| 6 | 26h | diskette | diskette driver |
| 7 | 27h | LPT1; PIC 1's spurious interrupt | unhandled, after the spurious check (the printer driver keeps it off) |
| 8 | 28h | real-time clock | unhandled (rx286 reads the clock, not its interrupt) |
| 9 | 29h | the bus's IRQ2 line, redirected | unhandled |
| 10-12 | 2Ah-2Ch | free | unhandled |
| 13 | 2Dh | 80287 error | FPU driver |
| 14 | 2Eh | fixed disk | fixed disk driver |
| 15 | 2Fh | free; PIC 2's spurious interrupt | unhandled, after the spurious check |
| NMI | 02h | parity error or I/O channel check | panic |

## DMA channels

| Channel | Device |
|---|---|
| 0, 1, 3 | free (8-bit) |
| 2 | diskette: the kernel's driver (and the BIOS, in the boot code) |
| 4 | cascade |
| 5-7 | free (16-bit) |

rx286 resets both controllers at start, cascades channel 4, and programs
channel 2 for each diskette sector, into and out of `disk_buffer`
(*docs/storage.md*).

## What Bochs differs in

Bochs 2.7 has no 80286 and no EGA; *docs/emulators.md* lists what that
changes. Everything above that Bochs can be told, it is told, in
`bochs/rx286.bochsrc.in`.
