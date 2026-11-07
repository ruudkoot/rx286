/* ============================================================================
 * rx286 - src/bin/crash.c
 * crash KIND: what no process may do, tried (roadmap os-server.md P12;
 * crashes.asm): the kernel stops it, and the OS server ends it by the
 * signal of its fault and says so on its terminal; the shell goes on.
 * crash, or an unknown kind, lists the kinds.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>

void crash_gp(void), crash_ud(void), crash_de(void), crash_ss(void), crash_io(void);
void crash_cli(void), crash_hlt(void), crash_int(void), crash_kernel(void);
void crash_call(void), crash_write(void), crash_fpu(void), crash_tf(void), crash_nt(void);

/* The kinds: the word, the routine, what it tries */
static const struct {
    const char *word;
    void (*crash)(void);
    const char *what;
} kinds[] = {
    { "gp", crash_gp, "jump past the end of my code" },
    { "ud", crash_ud, "an instruction that does not exist" },
    { "de", crash_de, "divide by zero" },
    { "ss", crash_ss, "push past the end of my stack" },
    { "io", crash_io, "read the keyboard's port myself" },
    { "cli", crash_cli, "turn interrupts off" },
    { "hlt", crash_hlt, "halt the CPU" },
    { "int", crash_int, "INT 32h, beyond the IDT" },
    { "kernel", crash_kernel, "load the kernel's data selector" },
    { "call", crash_call, "call into the kernel's code" },
    { "write", crash_write, "write over my own code" },
    { "fpu", crash_fpu, "divide by zero on the 287, unmasked" },
    { "tf", crash_tf, "set the trap flag" },
    { "nt", crash_nt, "set NT and IRET" }
};
#define KINDS ((int)(sizeof kinds / sizeof kinds[0]))

/* main - the kind tried, or the kinds listed */
int main(int argc, char **argv)
{
    int k;

    for (k = 0; argc == 2 && k < KINDS; k++)
        if (strcmp(argv[1], kinds[k].word) == 0) {
            printf("crash: %s\n", kinds[k].what);
            kinds[k].crash();
            printf("crash: no 287 error arrived; is there a 287?\n");
            return 1;
        }
    printf("crash what? The kinds:");
    for (k = 0; k < KINDS; k++)
        printf(" %s", kinds[k].word);
    printf("\n");
    return 1;
}
