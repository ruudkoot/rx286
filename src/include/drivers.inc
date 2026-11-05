; ============================================================================
; rx286 - src/include/drivers.inc
; The drivers outside the kernel (roadmap l4.md L7-L10, D10, D11): their
; slots, and what they are asked.
;
; A driver is a module of ring 1 with IOPL 1 (MF_DRIVER), which the root
; builds with an endpoint it serves, a notification bound to its thread for
; its interrupt and its timer, and the capability of its interrupt line if
; it has one (M_IRQ). The OS server holds an endpoint to each, in the slot
; its service names. A driver's faults go to the root. docs/drivers.md is
; the reference.
; ============================================================================

%ifndef RX286_DRIVERS_INC
%define RX286_DRIVERS_INC

DRV_SLOT_EP         equ 3       ; a driver's slots: the endpoint it serves
DRV_SLOT_NOTIFY     equ 4       ;    its notification, bound to its thread
DRV_SLOT_IRQ        equ 5       ;    its interrupt line, if it has one
DRV_SLOT_RECV       equ 6       ;    where a segment passed to it lands
DRV_TIMER_BIT       equ 1       ; the notification's bits: its timer (its own capability)
DRV_IRQ_BIT         equ 2       ;    its interrupt (the root binds a copy badged so)

SERVICE_PRINTER     equ 1       ; M_SERVICE: what a driver serves; the OS server
SERVICE_MOUSE       equ 2       ;    holds its endpoint in slot OS_SLOT_SERVICE + service
OS_SLOT_SERVICE     equ 3

; The printer driver: one call
DRV_PRINT           equ 1       ; BX the printer, CX bytes, SI their offset in the segment
                                ;    passed -> BX 0 or E_PAPER, E_TIMEOUT; CX bytes printed
; The mouse driver
DRV_MOUSE_GET       equ 1       ; -> BX buttons, CX x, SI y, DI MOUSE_PRESENT or 0;
                                ;    its news taken
DRV_MOUSE_NEWS      equ 2       ; -> BX 1 if the mouse moved or a button changed since

%endif
