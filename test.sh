#!/bin/bash
cd src
nasm -o ../bin/hello.com hello.asm && nasm -o ../bin/kernel.com kernel.asm && cd .. && cat bin/hello.com bin/kernel.com > bin/boot.dsk && bochs -f hello.bochs
