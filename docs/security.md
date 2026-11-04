# Security

The program in ring 3 is treated as arbitrary code. No program can make the
kernel fault, panic, reset or hang; read or write outside its own three
segments; touch an I/O port; or disable interrupts. Every way out is a
reported fault, after which the program starts again.

The roadmap's *The security model* lists every attack and what stops it; M8
completes this document with the attack suite and the fuzzer that prove it.
