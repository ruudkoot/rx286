                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
loadall_msw:        dw      0000h       ; machine status word
                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
                    dw      0000h       ; not used
loadall_tr:         dw      0000h       ; task register
loadall_flags       dw      0000h       ; flags
loadall_ip          dw      0000h       ; instruction pointer
loadall_ldtr        dw      0000h       ; local descriptor table register
loadall_ds          dw      0000h       ; data segment
loadall_ss          dw      0000h       ; stack segment
loadall_cs          dw      0000h       ; code segment
loadall_es          dw      0000h       ; extra segment
loadall_di          dw      0000h       ; destination index
loadall_si          dw      0000h       ; source index
loadall_bp          dw      0000h       ; base pointer
loadall_sp          dw      0000h       ; stack pointer
loadall_bx          dw      0000h
loadall_dx          dw      0000h
loadall_cx          dw      0000h
loadall_ax          dw      0000h
loadall_es_limit    dw      0000h
loadall_es_base     dd      00000000h
loadall_cs_limit    dw      0000h
loadall_cs_base     dd      00000000h
loadall_ss_limit    dw      0000h
loadall_ss_base     dd      00000000h
loadall_ds_limit    dw      0000h
loadall_ds_base     dd      00000000h
loadall_gdt_limit   dw      0000h
loadall_gdt_base    dd      00000000h
loadall_ldt_limit   dw      0000h
loadall_ldt_base    dd      00000000h
loadall_idt_limit   dw      0000h
loadall_idt_base    dd      00000000h
loadall_tss_limit   dw      0000h
loadall_tss_base    dd      00000000h
