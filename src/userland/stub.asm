; ============================================================================
; rx286 - src/userland/stub.asm
; The system call stub (roadmap l4.md L6, D16): the program's way to the OS
; server, with the registers of INT 30h in and out.
;
; The sys macro calls it (program.inc). It puts the registers in its
; transfer segment's block, and a buffer the call reads in its data; it
; calls the OS server's endpoint with the function as the label, and takes
; the results back from the block, a buffer the call filled from its data.
; It checks a buffer as the kernel's check_buffer does, with the 286's own
; instructions at the program's privilege; one the program may not use so
; is passed on as XFER_BAD, past the transfer segment's end, so that the
; kernel refuses it after its other checks, as it did (E_FAULT). (The test
; probe, about the caller's own descriptors, never comes here: the sys
; macro traps into the kernel for it.) os.inc has the constants.
; ============================================================================

%ifndef RX286_STUB_ASM
%define RX286_STUB_ASM

%include "kcalls.inc"
%include "os.inc"

; The saved registers, from BP (os_call's frame)
STUB_AX             equ 0
STUB_BX             equ 2
STUB_CX             equ 4
STUB_DX             equ 6
STUB_SI             equ 8
STUB_DI             equ 10
STUB_DS             equ 12
STUB_ES             equ 14
STUB_SOURCE         equ -2              ; the offsets to pass for a buffer the call
STUB_DEST           equ -4              ; reads and one it fills: XFER_DATA or XFER_BAD
STUB_FUNCTION       equ -6              ; the function (AH in)
STUB_CARRY          equ 1               ; FLAGS: CF

; ----------------------------------------------------------------------------
; os_call - a system call, through the OS server
;   In:       AH = the function; the registers INT 30h takes
;   Out:      the registers INT 30h returns; CF and AX an error
;   Destroys: what INT 30h does
; ----------------------------------------------------------------------------
os_call:
        push bp
        push es
        push ds
        push di
        push si
        push dx
        push cx
        push bx
        push ax
        mov bp, sp
        push word XFER_DATA             ; [bp + STUB_SOURCE]
        push word XFER_DATA             ; [bp + STUB_DEST]
        mov al, ah
        push ax                         ; [bp + STUB_FUNCTION]
        cld
        call stub_in
        ; the registers into the block, a buffer's offset as the OS server
        ; is to pass it
        mov ax, OS_XFER
        mov es, ax
        push ss
        pop ds
        mov si, bp
        mov di, XFER_AX
        mov cx, 6
        rep movsw
        call stub_source_call
        jnc .dest
        mov ax, [bp + STUB_SOURCE]
        mov [es:XFER_SI], ax
.dest:
        call stub_dest_call
        jnc .registers
        mov ax, [bp + STUB_DEST]
        mov [es:XFER_DI], ax
.registers:
        mov al, [bp + STUB_FUNCTION]    ; the label
        mov dx, OS_EP
        push bp
        xor bp, bp
        kcall KCALL_CALL
        pop bp
        jc .gone
        ; the results: AX, BX, CX, DX; SI and DI too, but where they named
        ; a buffer
        mov ax, OS_XFER
        mov ds, ax
        push ss
        pop es
        mov si, XFER_AX
        mov di, bp
        mov cx, 4
        rep movsw
        call stub_source_call
        jc .kept
        call stub_dest_call
        jc .kept
        movsw
        movsw
.kept:
        call stub_out
        mov ax, [XFER_FLAGS]
        jmp .return
.gone:
        mov word [bp + STUB_AX], E_NOSYS    ; no OS server to answer
        mov ax, STUB_CARRY
.return:
        add sp, 6
        shr ax, 1                       ; CF: the result's
        pop ax
        pop bx
        pop cx
        pop dx
        pop si
        pop di
        pop ds
        pop es
        pop bp
        ret

; ----------------------------------------------------------------------------
; stub_source_call - does the function read a buffer at DS:SI?
;   In:       BP = os_call's frame
;   Out:      CF set if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
stub_source_call:
        push ax
        mov al, [bp + STUB_FUNCTION]
        cmp al, SYS_WRITE
        je .yes
        cmp al, SYS_DISK_WRITE
        je .yes
        cmp al, SYS_PRINT
        je .yes
        cmp al, SYS_SERIAL_WRITE
        je .yes
        cmp al, SYS_FIND
        je .yes
        cmp al, SYS_CHDIR
        je .yes
        pop ax
        clc
        ret
.yes:
        pop ax
        stc
        ret

; ----------------------------------------------------------------------------
; stub_dest_call - does the function fill a buffer at ES:DI?
;   In:       BP = os_call's frame
;   Out:      CF set if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
stub_dest_call:
        push ax
        push cx
        mov al, [bp + STUB_FUNCTION]
        call stub_room
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; stub_room - the room a function fills at ES:DI
;   In:       AL = the function; BP = os_call's frame
;   Out:      CF set and CX = the bytes, if it fills one; else CF clear
;   Destroys: nothing else
; ----------------------------------------------------------------------------
stub_room:
        mov cx, SECTOR_SIZE
        cmp al, SYS_DISK_READ
        je .yes
        cmp al, SYS_FILE_NEXT
        je .yes
        mov cx, FIND_SIZE
        cmp al, SYS_FIND
        je .yes
        mov cx, PATH_MAX + 1
        cmp al, SYS_GETCWD
        je .yes
        mov cx, FIND_ENTRY_SIZE
        cmp al, SYS_DIR_NEXT
        je .yes
        mov cx, PS_SIZE
        cmp al, SYS_PS
        je .yes
        mov cx, [bp + STUB_CX]
        cmp al, SYS_SERIAL_READ
        je .yes
        clc
        ret
.yes:
        stc
        ret

; ----------------------------------------------------------------------------
; stub_in - a buffer the call reads, copied into the transfer segment; one it
; fills, checked; one the program may not use so, marked XFER_BAD
;   In:       BP = os_call's frame
;   Out:      [BP + STUB_SOURCE], [BP + STUB_DEST] = XFER_DATA or XFER_BAD
;   Destroys: AX, BX, CX, DX, SI, DI, DS, ES
; ----------------------------------------------------------------------------
stub_in:
        mov al, [bp + STUB_FUNCTION]
        cmp al, SYS_FIND
        je .path
        cmp al, SYS_CHDIR
        je .path
        mov cx, SECTOR_SIZE
        cmp al, SYS_DISK_WRITE
        je .source
        mov cx, [bp + STUB_CX]
        cmp al, SYS_WRITE
        je .source
        cmp al, SYS_PRINT
        je .source
        cmp al, SYS_SERIAL_WRITE
        je .source
        jmp .room
.path:
        call stub_path
        jnc .room
        mov word [bp + STUB_SOURCE], XFER_BAD
        jmp .room
.source:
        jcxz .room                      ; the kernel's own checks decide
        cmp cx, XFER_DATA_SIZE
        ja .room
        mov ax, [bp + STUB_DS]
        mov si, [bp + STUB_SI]
        mov dx, 0                       ; read
        call stub_check
        jc .bad_source
        mov ds, ax
        mov ax, OS_XFER
        mov es, ax
        mov di, XFER_DATA
        rep movsb
        jmp .room
.bad_source:
        mov word [bp + STUB_SOURCE], XFER_BAD
.room:
        mov al, [bp + STUB_FUNCTION]
        call stub_room
        jnc .done
        jcxz .done
        cmp cx, XFER_DATA_SIZE
        ja .done
        mov ax, [bp + STUB_ES]
        mov si, [bp + STUB_DI]
        mov dx, 1                       ; written
        call stub_check
        jnc .done
        mov word [bp + STUB_DEST], XFER_BAD
.done:
        ret

; ----------------------------------------------------------------------------
; stub_path - a path, at the program's DS:SI, into the transfer segment:
; PATH_IN_MAX bytes, or as many as its segment holds, and a zero after them
; (the OS server looks for its end among them)
;   In:       BP = os_call's frame
;   Out:      CF set if the program may not read there
;   Destroys: AX, BX, CX, DX, SI, DI, DS, ES
; ----------------------------------------------------------------------------
stub_path:
        mov ax, [bp + STUB_DS]
        mov si, [bp + STUB_SI]
        mov cx, 1
        mov dx, 0                       ; read
        call stub_check                 ; BX = the segment's limit
        jc .out
        mov cx, bx
        sub cx, si                      ; the bytes after the first, to the limit
        cmp cx, PATH_IN_MAX - 1
        jb .fewer
        mov cx, PATH_IN_MAX - 1
.fewer:
        inc cx
        mov ds, ax
        mov ax, OS_XFER
        mov es, ax
        mov di, XFER_DATA
        rep movsb
        mov byte [es:di], 0
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; stub_check - may the program use CX bytes at AX:SI so? As check_buffer: the
; segment readable (written: writable) at the program's privilege, present,
; not expand-down, and the bytes within its limit without passing FFFFh
;   In:       AX = the selector; SI = the offset; CX = bytes (1 or more);
;             DX = 0 to read, 1 to write
;   Out:      CF set if not
;   Destroys: BX
; ----------------------------------------------------------------------------
stub_check:
        test dx, dx
        jnz .write
        verr ax
        jnz .refuse
        jmp .bounds
.write:
        verw ax
        jnz .refuse
.bounds:
        lar bx, ax
        jnz .refuse
        test bh, ACC_PRESENT_BIT        ; VERR and VERW pass a segment not present
        jz .refuse
        test bh, ACC_EXPAND_DOWN_BIT
        jnz .refuse
        lsl bx, ax                      ; BX = the limit
        jnz .refuse
        push si
        add si, cx
        dec si                          ; the last byte (DEC keeps CF)
        jc .wraps
        cmp si, bx
        pop si
        ja .refuse
        clc
        ret
.wraps:
        pop si
.refuse:
        stc
        ret

ACC_PRESENT_BIT     equ 0x80
ACC_EXPAND_DOWN_BIT equ 0x04            ; with data: expand-down; with code: conforming

; ----------------------------------------------------------------------------
; stub_out - what a call filled in the transfer segment, into the program's
; buffer: a sector read, the bytes a serial read returns, a file call's
; record, entry, path or sector
;   In:       BP = os_call's frame, its saved registers the results; DS =
;             the transfer segment
;   Out:      nothing
;   Destroys: AX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
stub_out:
        cmp word [bp + STUB_DEST], XFER_DATA
        jne .done                       ; nothing filled
        test word [XFER_FLAGS], STUB_CARRY
        jnz .done                       ; an error: nothing filled
        mov al, [bp + STUB_FUNCTION]
        call stub_room                  ; CX = the room
        jnc .done
        cmp al, SYS_SERIAL_READ
        jne .file
        mov cx, [bp + STUB_AX]          ; the bytes read
.file:
        cmp al, SYS_FILE_NEXT
        jne .entry
        mov cx, [bp + STUB_CX]          ; the file's bytes in the sector
.entry:
        cmp al, SYS_DIR_NEXT
        jne .copy
        cmp word [bp + STUB_AX], 0
        jne .copy
        xor cx, cx                      ; the directory's end: no entry
.copy:
        jcxz .done
        mov es, [bp + STUB_ES]
        mov di, [bp + STUB_DI]
        mov si, XFER_DATA
        rep movsb
.done:
        ret

%endif
