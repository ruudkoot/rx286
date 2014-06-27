#!/bin/sh
mkdir bin
dd if=/dev/zero of=bin/hd.0 bs=512 count=41820
dd if=/dev/zero of=bin/hd.1 bs=512 count=41820
