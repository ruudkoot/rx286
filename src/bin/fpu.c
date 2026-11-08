/* ============================================================================
 * rx286 - src/bin/fpu.c
 * fpu: the square root of 2 and pi to 18 digits, by the 287 (roadmap
 * os-server.md P12; fpu287.asm), whose state the OS server keeps for a
 * process that says it uses it (mkexe --287).
 * ============================================================================ */

#include <stdio.h>

void fpu_digits(unsigned char *bcd, int which);

/* say - a name, then FBSTP's 18 digits as d.ddddddddddddddddd */
static void say(const char *name, int which)
{
    unsigned char bcd[10];
    char text[20];
    int k, at = 0;

    fpu_digits(bcd, which);
    for (k = 8; k >= 0; k--) {
        text[at++] = (char)('0' + (bcd[k] >> 4));
        if (k == 8)
            text[at++] = '.';
        text[at++] = (char)('0' + (bcd[k] & 15));
    }
    text[at] = 0;
    printf("%s = %s\n", name, text);
}

/* main - the two numbers */
int main(void)
{
    say("sqrt(2)", 0);
    say("pi     ", 1);
    return 0;
}
