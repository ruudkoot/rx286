#!/bin/bash
nasm -o hello.com hello.asm && nasm -o kernel.com kernel.asm && cat hello.com kernel.com > boot.dsk && bochs -f hello.bochs
