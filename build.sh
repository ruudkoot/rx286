#!/bin/bash
cd src && cd boot && nasm -o ../../bin/boot0.com boot0.asm && cd .. && cd kernel && nasm -o ../../bin/kernel.com kernel.asm && cd .. && cd .. && cat bin/boot0.com bin/kernel.com > bin/boot.dsk && bochs -f 286.bochs
