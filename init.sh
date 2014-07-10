#!/bin/sh
mkdir bin log
dd if=/dev/zero of=bin/hd.0 bs=512 count=41820
dd if=/dev/zero of=bin/hd.1 bs=512 count=41820
dd if=/dev/zero of=bin/hd.2 bs=512 count=41820
dd if=/dev/zero of=bin/hd.3 bs=512 count=41820
dd if=/dev/zero of=bin/hd.4 bs=512 count=41820
dd if=/dev/zero of=bin/hd.5 bs=512 count=41820
dd if=/dev/zero of=bin/hd.6 bs=512 count=41820
dd if=/dev/zero of=bin/hd.7 bs=512 count=41820
