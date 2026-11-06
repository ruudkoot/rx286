/* ============================================================================
 * rx286 - tools/ia16.ld
 * gcc-ia16's link of an rx286 C program (c.mk, CC_KIND=ia16): the code from
 * offset 0 of its own segment, the data from offset 0 of its own: crt0's
 * stack (.stackbot), the initialised data, .bss. The two address spaces
 * overlap, so ld runs with --no-check-sections; tools/mkexe reads the ELF.
 * ============================================================================ */

SECTIONS {
  .text 0 : AT(0) { *(.text*) }
  . = 0;
  .stackbot . (NOLOAD) : AT(0x100000) { *(.stackbot) }
  .data . : AT(0x100000 + SIZEOF(.stackbot)) { *(.rodata*) *(.data*) }
  .bss . : { *(.bss*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame) }
}
