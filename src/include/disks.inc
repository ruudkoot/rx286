; ============================================================================
; rx286 - src/include/disks.inc
; The four drives of rx286's AT, as the kernel addresses them: their
; geometry, never detected (docs/disks.md).
;
; Drive A is the 1.2 MB diskette drive with 1.2 MB media, B the 360 KB drive
; with 360 KB media (roadmap D2). C and D are the AT's fixed-disk types 2
; and 1 (IBM, Technical Reference, the BIOS's table FD_TBL), with the
; cylinder from which writes are precompensated. The drive numbers
; (DRIVE_A ...) are in syscalls.inc.
; ============================================================================

%ifndef RX286_DISKS_INC
%define RX286_DISKS_INC

DISK_A_CYLINDERS    equ 80
DISK_A_HEADS        equ 2
DISK_A_SECTORS      equ 15          ; a track
DISK_B_CYLINDERS    equ 40
DISK_B_HEADS        equ 2
DISK_B_SECTORS      equ 9
DISK_C_CYLINDERS    equ 615         ; type 2
DISK_C_HEADS        equ 4
DISK_C_SECTORS      equ 17
DISK_C_PRECOMP      equ 300
DISK_D_CYLINDERS    equ 306         ; type 1
DISK_D_HEADS        equ 4
DISK_D_SECTORS      equ 17
DISK_D_PRECOMP      equ 128

%endif
