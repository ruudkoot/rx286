; ============================================================================
; rx286 - src/lib/fatname.asm
; FAT names and time stamps as text, for the shell's FAT12 library.
;
; Pure routines (tests/unit/test_fatname.py runs them on the host): they
; read DS:SI, write ES:DI and touch nothing else; fmt_fat_date needs
; format.asm. A directory entry keeps its name as DIR_NAME_LENGTH bytes in
; upper case: the name padded to FAT_BASE_LENGTH with spaces, the extension
; to FAT_EXT_LENGTH, no dot; "." and ".." are themselves, padded. A date
; counts years from FAT_YEAR_BASE in bits 15-9, months in 8-5, days in 4-0;
; a time hours in 15-11, minutes in 10-5, seconds / 2 in 4-0.
; ============================================================================

FAT_BASE_LENGTH     equ 8
FAT_EXT_LENGTH      equ 3
FAT_YEAR_BASE       equ 1980
CHAR_PATH_SEPARATOR equ '\'
CHAR_PATH_OTHER     equ '/'             ; taken for a separator too

; ----------------------------------------------------------------------------
; fat_name_parse - a path's next component as a directory entry's name
;   In:       DS:SI = the component; ES:DI = DIR_NAME_LENGTH bytes for it
;   Out:      CF clear and SI at what ended it (zero, a space or a
;             separator); or CF set: not a name DOS allows (empty, more than
;             8.3, a second dot, a character it forbids); the bytes at ES:DI
;             written either way
;   Destroys: AX
; ----------------------------------------------------------------------------
fat_name_parse:
        push cx
        push di
        mov al, ' '
        mov cx, DIR_NAME_LENGTH
        rep stosb
        pop di
        push di
        cmp byte [si], '.'
        jne .base
        mov byte [es:di], '.'           ; "." or ".."
        inc si
        cmp byte [si], '.'
        jne .dots
        mov byte [es:di + 1], '.'
        inc si
.dots:
        call fat_name_ends
        jne .bad
        jmp .good
.base:
        mov cx, FAT_BASE_LENGTH + 1
.base_char:
        call fat_name_ends
        je .base_end
        lodsb
        cmp al, '.'
        je .extension
        call fat_name_char
        jc .bad
        dec cx
        jz .bad                         ; more than eight
        stosb
        jmp .base_char
.base_end:
        cmp cx, FAT_BASE_LENGTH + 1
        je .bad                         ; nothing at all
        jmp .good
.extension:
        pop di
        push di
        add di, FAT_BASE_LENGTH
        mov cx, FAT_EXT_LENGTH + 1
.ext_char:
        call fat_name_ends
        je .good
        lodsb
        call fat_name_char              ; a second dot is refused here
        jc .bad
        dec cx
        jz .bad                         ; more than three
        stosb
        jmp .ext_char
.good:
        pop di
        pop cx
        clc
        ret
.bad:
        pop di
        pop cx
        stc
        ret

; ----------------------------------------------------------------------------
; fat_name_ends - does a path component end at DS:SI?
;   In:       DS:SI = the text
;   Out:      ZF set if it is zero, a space or a separator
;   Destroys: nothing
; ----------------------------------------------------------------------------
fat_name_ends:
        push ax
        mov al, [si]
        test al, al
        jz .done
        cmp al, ' '
        je .done
        cmp al, CHAR_PATH_SEPARATOR
        je .done
        cmp al, CHAR_PATH_OTHER
.done:
        pop ax
        ret

; ----------------------------------------------------------------------------
; fat_name_char - a character of a name, in upper case
;   In:       AL = the character
;   Out:      CF clear and AL in upper case; or CF set: DOS forbids it
;   Destroys: nothing
; ----------------------------------------------------------------------------
fat_name_char:
        cmp al, 'a'
        jb .not_lower
        cmp al, 'z'
        ja .not_lower
        sub al, 'a' - 'A'
        clc
        ret
.not_lower:
        cmp al, 'A'
        jb .not_upper
        cmp al, 'Z'
        jbe .allowed
.not_upper:
        cmp al, '0'
        jb .punctuation
        cmp al, '9'
        jbe .allowed
.punctuation:
        push cx
        push si
        mov si, fat_name_punctuation
        mov cx, fat_name_punctuation_end - fat_name_punctuation
.next:
        cmp al, [cs:si]
        je .found
        inc si
        loop .next
        pop si
        pop cx
        stc
        ret
.found:
        pop si
        pop cx
.allowed:
        clc
        ret

; ----------------------------------------------------------------------------
; fat_name_text - a directory entry's name as text: NAME.EXT, no spaces
;   In:       DS:SI = the DIR_NAME_LENGTH bytes; ES:DI = where to write
;   Out:      DI past the text (not terminated)
;   Destroys: nothing
; ----------------------------------------------------------------------------
fat_name_text:
        push ax
        push cx
        push si
        push si
        mov cx, FAT_BASE_LENGTH
.base:
        lodsb
        cmp al, ' '
        je .extension
        stosb
        loop .base
.extension:
        pop si
        add si, FAT_BASE_LENGTH
        cmp byte [si], ' '
        je .done
        mov al, '.'
        stosb
        mov cx, FAT_EXT_LENGTH
.ext_char:
        lodsb
        cmp al, ' '
        je .done
        stosb
        loop .ext_char
.done:
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; fmt_fat_date - a directory entry's date as YYYY-MM-DD
;   In:       AX = the date; ES:DI = where to write
;   Out:      DI past the ten characters
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_fat_date:
        push ax
        push bx
        mov bx, ax
        shr ax, 9
        add ax, FAT_YEAR_BASE
        call fmt_dec16
        mov al, '-'
        stosb
        mov ax, bx
        shr ax, 5
        and al, 0x0F
        call fmt_two_digits
        mov al, '-'
        stosb
        mov al, bl
        and al, 0x1F
        call fmt_two_digits
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; fmt_fat_time - a directory entry's time as HH:MM
;   In:       AX = the time; ES:DI = where to write
;   Out:      DI past the five characters
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_fat_time:
        push ax
        push ax
        shr ax, 11
        call fmt_two_digits
        mov al, ':'
        stosb
        pop ax
        shr ax, 5
        and al, 0x3F
        call fmt_two_digits
        pop ax
        ret

; ----------------------------------------------------------------------------
; fmt_two_digits - AL (0-99) as two decimal digits
;   In:       AL = the number; ES:DI = where to write
;   Out:      DI past the two digits
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_two_digits:
        push ax
        aam                             ; AH = tens, AL = units
        add ax, '00'
        xchg al, ah
        stosw
        pop ax
        ret

; The punctuation DOS allows in a name, besides letters and digits.
fat_name_punctuation    db "!#$%&'()-@^_`{}~"
fat_name_punctuation_end:
