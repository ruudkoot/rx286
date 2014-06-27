#!/bin/bash
cd src
nasm -o ../bin/boot0.com boot0.asm && nasm -o ../bin/kernel.com kernel.asm && cd .. && cat bin/boot0.com bin/kernel.com > bin/boot.dsk && bochs -f 286.bochs
