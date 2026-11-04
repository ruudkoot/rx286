; ============================================================================
; rx286 - src/boot-loader/boot-loader.asm
; The loader: finds KERNEL.BIN on the FAT12 floppy, loads it to 1000:0000h
; and hands the machine to it.
;
; The boot sector loads this file from the reserved sectors 1-3 to
; 0000:7E00h and jumps here with the boot drive in DL. The loader reads the
; BPB the boot sector left at 7C00h, the FAT and the root directory into its
; buffers, finds KERNEL  BIN, and follows its cluster chain one sector at a
; time (an INT 13h read never crosses a 64 KB boundary: roadmap X3). Then,
; with the BIOS's help for the last time (roadmap D14), it sets text mode 3,
; stops the floppy motor (X2), disables interrupts and NMI, and jumps to
; 1000:0000h. It hands the kernel nothing else.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "layout.inc"

        org LOADER_PHYS

        jmp short start
        dw LOADER_MAGIC                 ; the boot sector checks this word

%define BPB(field) BOOT_SECTOR_PHYS + field

; ----------------------------------------------------------------------------
; start - load KERNEL.BIN and jump to it
;   In:       DL = boot drive; CS = DS = ES = SS = 0, interrupts on
;   Out:      does not return: jumps to KERNEL_SEG:0000
;   Destroys: everything
; ----------------------------------------------------------------------------
start:
        mov [drive], dl
%ifdef WITH_SERIAL
        call serial_init
%endif
        mov si, msg_trace_start
        call trace
        call geometry
        ; The FAT, then the root directory, into their buffers.
        mov ax, [BPB(BPB_RESERVED_SECTORS)]
        mov cx, [BPB(BPB_SECTORS_PER_FAT)]
        mov bx, LOADER_FAT_BUF
        call read_sectors
        mov ax, [root_lba]
        mov cx, [root_sectors]
        mov bx, LOADER_ROOT_BUF
        call read_sectors
        call find_kernel                ; SI = its directory entry
        call load_kernel
        mov si, msg_trace_loaded
        call trace
        ; The hand-over.
        mov ax, 0x0003                  ; INT 10h AX=0003h: text mode 3, 80x25 colour
        int 0x10
        mov dx, FDC_DOR
        mov al, FDC_DOR_MOTORS_OFF
        out dx, al
        cli
        mov al, CMOS_NMI_DISABLE | CMOS_REG_D
        out CMOS_INDEX, al
        jmp KERNEL_SEG:0

; ----------------------------------------------------------------------------
; geometry - check the BPB and work out where the root and data begin
;   In:       the BPB at BOOT_SECTOR_PHYS
;   Out:      root_lba, root_sectors, data_lba, max_cluster set; returns only
;             if the disk is one this loader can read
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
geometry:
        mov si, msg_bad_disk
        cmp word [BPB(BPB_BYTES_PER_SECTOR)], 512
        jne fail
        cmp byte [BPB(BPB_SECTORS_PER_CLUSTER)], 0
        je fail
        mov ax, [BPB(BPB_SECTORS_PER_FAT)]
        cmp ax, (LOADER_ROOT_BUF - LOADER_FAT_BUF) / 512
        ja fail
        mov bl, [BPB(BPB_FATS)]
        xor bh, bh
        mul bx                          ; AX = sectors of all FATs
        add ax, [BPB(BPB_RESERVED_SECTORS)]
        mov [root_lba], ax
        mov ax, [BPB(BPB_ROOT_ENTRIES)]
        add ax, 512 / DIR_ENTRY_SIZE - 1
        shr ax, 4                       ; 16 entries a sector
        cmp ax, (LOADER_BUF_END - LOADER_ROOT_BUF) / 512
        ja fail
        mov [root_sectors], ax
        add ax, [root_lba]
        mov [data_lba], ax
        mov ax, [BPB(BPB_TOTAL_SECTORS)]
        sub ax, [data_lba]
        jbe fail
        xor dx, dx
        mov bl, [BPB(BPB_SECTORS_PER_CLUSTER)]
        xor bh, bh
        div bx
        inc ax                          ; clusters 2 .. count + 1
        mov [max_cluster], ax
        ret

; ----------------------------------------------------------------------------
; find_kernel - find KERNEL.BIN in the root directory, and check its size
;   In:       the root directory at LOADER_ROOT_BUF
;   Out:      SI = its directory entry; returns only if it fits its room
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
find_kernel:
        mov si, LOADER_ROOT_BUF
        mov dx, [BPB(BPB_ROOT_ENTRIES)]
.entry:
        cmp byte [si + DIR_NAME], DIR_END
        je .missing
        test byte [si + DIR_ATTRIBUTES], DIR_ATTR_VOLUME | DIR_ATTR_DIRECTORY
        jnz .next
        mov di, kernel_name
        push si
        mov cx, 11
        repe cmpsb
        pop si
        je .found
.next:
        add si, DIR_ENTRY_SIZE
        dec dx
        jnz .entry
.missing:
        mov si, msg_no_kernel
        jmp fail
.found:
        cmp word [si + DIR_FILE_SIZE + 2], 0
        jne .too_large
        mov ax, [si + DIR_FILE_SIZE]
        test ax, ax
        jz .missing
        cmp ax, KERNEL_FILE_SIZE
        ja .too_large
        ret
.too_large:
        mov si, msg_too_large
        jmp fail

; ----------------------------------------------------------------------------
; load_kernel - read KERNEL.BIN's clusters to KERNEL_SEG:0000
;   In:       SI = its directory entry
;   Out:      the file in memory; returns only if the chain was sound
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
load_kernel:
        mov ax, [si + DIR_FILE_SIZE]
        add ax, 511
        shr ax, 9
        mov di, ax                      ; DI = sectors still to read
        mov ax, [si + DIR_FIRST_CLUSTER]
        mov [cluster], ax
        mov word [dest_seg], KERNEL_SEG
.cluster:
        mov ax, [cluster]
        cmp ax, FAT12_FIRST_CLUSTER
        jb .broken
        cmp ax, [max_cluster]
        ja .broken
        sub ax, FAT12_FIRST_CLUSTER
        mov cl, [BPB(BPB_SECTORS_PER_CLUSTER)]
        xor ch, ch
        mul cx
        add ax, [data_lba]              ; AX = the cluster's first sector
.sector:
        push ax
        push cx
        mov es, [dest_seg]
        xor bx, bx
        mov cx, 1
        call read_sectors
        add word [dest_seg], 512 / 16
        pop cx
        pop ax
        dec di
        jz .done
        inc ax
        loop .sector
        mov ax, [cluster]
        mov si, LOADER_FAT_BUF
        call fat12_next
        mov [cluster], ax
        jmp .cluster
.done:
        xor ax, ax
        mov es, ax
        ret
.broken:
        xor ax, ax
        mov es, ax
        mov si, msg_bad_chain
        jmp fail

; ----------------------------------------------------------------------------
; read_sectors - read CX sectors from AX on, to ES:BX, retrying each one
;   In:       AX = first logical sector; CX = count; ES:BX = destination
;   Out:      the sectors in memory; returns only if every read succeeded
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
read_sectors:
        push bx
        push dx
        push si
.next:
        push ax
        push cx
        mov si, BOOT_TRIES
.try:
        push ax
        push bx
        mov bl, [BPB(BPB_SECTORS_PER_TRACK)]
        mov bh, [BPB(BPB_HEADS)]
        call chs_from_lba               ; CX and DH as INT 13h wants them
        pop bx
        mov dl, [drive]
        mov ax, 0x0201                  ; INT 13h AH=02h: read 1 sector
        int 0x13
        pop ax
        jnc .read
        push ax
        xor ah, ah                      ; INT 13h AH=00h: reset the drive
        mov dl, [drive]
        int 0x13
        pop ax
        dec si
        jnz .try
        mov si, msg_read_error
        jmp fail
.read:
        pop cx
        pop ax
        inc ax
        add bx, 512
        loop .next
        pop si
        pop dx
        pop bx
        ret

; ----------------------------------------------------------------------------
; fail - print a message, wait for a key, boot again
;   In:       SI = the message (zero-terminated)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
fail:
        xor ax, ax
        mov ds, ax
        mov es, ax
        push si
        mov si, msg_prefix
        call print
        pop si
        call print
        mov si, msg_press_key
        call print
        xor ah, ah                      ; INT 16h AH=00h: wait for a key
        int 0x16
        int 0x19                        ; boot again

; ----------------------------------------------------------------------------
; trace - print a trace line (debug and test builds; nothing in release)
;   In:       SI = the line, without the "[trace] " prefix
;   Out:      nothing
;   Destroys: AX, BX, DX, SI
; ----------------------------------------------------------------------------
trace:
%ifdef WITH_SERIAL
        push si
        mov si, msg_trace_prefix
        call print
        pop si
        call print
%endif
        ret

; ----------------------------------------------------------------------------
; print - write a zero-terminated string on the screen (and COM1)
;   In:       SI = the string, DS = 0
;   Out:      nothing
;   Destroys: AX, BX, DX, SI
; ----------------------------------------------------------------------------
print:
        lodsb
        test al, al
        jz .done
        mov ah, 0x0E                    ; INT 10h AH=0Eh: teletype
        mov bx, 0x0007                  ; page 0, light grey
        int 0x10
%ifdef WITH_SERIAL
        mov ah, al
        mov dx, COM1_BASE + UART_LSR
.wait:
        in al, dx
        test al, UART_LSR_THRE
        jz .wait
        mov al, ah
        mov dx, COM1_BASE + UART_THR
        out dx, al
%endif
        jmp print
.done:
        ret

%ifdef WITH_SERIAL
; ----------------------------------------------------------------------------
; serial_init - COM1 at 115200, 8N1, no interrupt (debug and test builds)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
serial_init:
        mov dx, COM1_BASE + UART_LCR
        mov al, UART_LCR_DLAB
        out dx, al
        mov dx, COM1_BASE + UART_DLL
        mov al, UART_DIVISOR_115200
        out dx, al
        mov dx, COM1_BASE + UART_DLM
        xor al, al
        out dx, al
        mov dx, COM1_BASE + UART_LCR
        mov al, UART_LCR_8N1
        out dx, al
        mov dx, COM1_BASE + UART_IER
        xor al, al
        out dx, al
        mov dx, COM1_BASE + UART_MCR
        mov al, UART_MCR_DTR_RTS
        out dx, al
        ret
%endif

%include "fat12.asm"

kernel_name         db "KERNEL  BIN"
msg_prefix          db "rx286 loader: ", 0
msg_bad_disk        db "this disk's format is not one I can read", 13, 10, 0
msg_read_error      db "cannot read the disk", 13, 10, 0
msg_no_kernel       db "no KERNEL.BIN on this disk", 13, 10, 0
msg_too_large       db "KERNEL.BIN is larger than its room", 13, 10, 0
msg_bad_chain       db "KERNEL.BIN's cluster chain is broken", 13, 10, 0
msg_press_key       db "Press a key to try again.", 13, 10, 0
msg_trace_prefix    db "[trace] loader: ", 0
msg_trace_start     db "started", 13, 10, 0
msg_trace_loaded    db "KERNEL.BIN loaded at 1000:0000", 13, 10, 0

drive               db 0
root_lba            dw 0
root_sectors        dw 0
data_lba            dw 0
max_cluster         dw 0
cluster             dw 0
dest_seg            dw 0

%if ($ - $$) > LOADER_SECTORS * 512
  %error "boot-loader.asm: the loader does not fit in its reserved sectors"
%endif
        times LOADER_SECTORS * 512 - ($ - $$) db 0
