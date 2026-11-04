; ============================================================================
; rx286 - src/kernel/dma.asm
; The two 8237A DMA controllers: reset at start, and channel 2 pointed at
; the disk buffer for each diskette transfer (storage roadmap D3).
;
; On the AT, controller 1 (channels 0-3, a byte at a time) cascades into
; channel 4 of controller 2, and the DRAM's refresh is not a DMA channel
; (IBM 1-12), so the kernel may reset both controllers (roadmap D14). Only
; channel 2 is ever unmasked on controller 1, and only for a transfer. Its
; address is the disk buffer's, fixed at assembly; the buffer may not cross
; a 64 KB boundary, since the 8237's address counter has 16 bits and the
; page register does not count (disk.asm checks).
; ============================================================================

DISK_BUFFER_PHYS    equ KDATA_PHYS + (disk_buffer - kdata_start)

; ----------------------------------------------------------------------------
; dma_init - both controllers reset; channel 4 cascades controller 1
;   In:       interrupts off
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
dma_init:
        out DMA1_MASTER_CLEAR, al       ; any value: every channel masked
        out DMA2_MASTER_CLEAR, al
        mov al, DMA_MODE_CASCADE        ; channel 0 of controller 2: channel 4
        out DMA2_MODE, al
        xor al, al                      ; and unmask it
        out DMA2_MASK, al
        ret

; ----------------------------------------------------------------------------
; dma_diskette - channel 2 ready for one sector between the diskette
; controller and the disk buffer
;   In:       AL = DMA_MODE_TO_MEMORY (a read) or DMA_MODE_FROM_MEMORY (a write)
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
dma_diskette:
        push ax
        mov al, DMA_MASK_SET | DMA_CHANNEL_DISKETTE
        out DMA1_MASK, al
        out DMA1_CLEAR_FLIPFLOP, al     ; any value
        pop ax
        or al, DMA_CHANNEL_DISKETTE
        out DMA1_MODE, al
        mov al, DISK_BUFFER_PHYS & 0xFF
        out DMA1_CH2_ADDRESS, al
        mov al, (DISK_BUFFER_PHYS >> 8) & 0xFF
        out DMA1_CH2_ADDRESS, al
        mov al, DISK_BUFFER_PHYS >> 16
        out DMA_PAGE_CH2, al
        mov al, (SECTOR_SIZE - 1) & 0xFF
        out DMA1_CH2_COUNT, al
        mov al, (SECTOR_SIZE - 1) >> 8
        out DMA1_CH2_COUNT, al
        mov al, DMA_CHANNEL_DISKETTE    ; unmasked
        out DMA1_MASK, al
        ret
