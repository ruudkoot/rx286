; ============================================================================
; rx286 - src/userland/parse.asm
; The shell's parsing of a command line: words separated by spaces. A
; command's word matches in any case, as in DOS (its table's are lower case).
;
; Pure routines (tests/unit/test_parse.py runs them on the host): they read
; DS:SI and ES:DI and touch nothing else.
; ============================================================================

; ----------------------------------------------------------------------------
; parse_skip_spaces - move past spaces
;   In:       DS:SI = text (zero-terminated)
;   Out:      SI at the first character that is not a space
;   Destroys: nothing
; ----------------------------------------------------------------------------
parse_skip_spaces:
        cmp byte [si], ' '
        jne .done
        inc si
        jmp parse_skip_spaces
.done:
        ret

; ----------------------------------------------------------------------------
; parse_match - is the next word of the text this word?
;   In:       DS:SI = text (zero-terminated); ES:DI = the word (zero-terminated,
;             lower case)
;   Out:      CF clear and SI past the word and the spaces after it, if the
;             text's next word is the word, in any case; else CF set, SI as
;             it was
;   Destroys: nothing
; ----------------------------------------------------------------------------
parse_match:
        push ax
        push si
        push di
        call parse_skip_spaces
.next:
        mov al, [si]
        cmp al, 'A'
        jb .compare
        cmp al, 'Z'
        ja .compare
        or al, 'a' - 'A'                ; the text's letter in lower case
.compare:
        cmp byte [es:di], 0
        je .word_end
        cmp al, [es:di]
        jne .no
        inc si
        inc di
        jmp .next
.word_end:
        mov al, [si]                    ; the text's word must end here too
        test al, al
        jz .yes
        cmp al, ' '
        jne .no
.yes:
        call parse_skip_spaces
        pop di
        add sp, 2                       ; drop the saved SI: keep the new one
        pop ax
        clc
        ret
.no:
        pop di
        pop si
        pop ax
        stc
        ret

; ----------------------------------------------------------------------------
; parse_word_length - the length of the text's next word
;   In:       DS:SI = text, at the word's first character
;   Out:      CX = its length (0 at the end or a space)
;   Destroys: nothing
; ----------------------------------------------------------------------------
parse_word_length:
        push ax
        push si
        xor cx, cx
.next:
        mov al, [si]
        test al, al
        jz .done
        cmp al, ' '
        je .done
        inc cx
        inc si
        jmp .next
.done:
        pop si
        pop ax
        ret
