/* The _exit the toolchain's crt0 ends in: main() returning (or exit())
 * lands here, and picolibc does not provide it.
 *
 * Reports the result the way RV32_PASS()/RV32_FAIL() (rv32_test.h) do, in
 * tohost: code 0 is PASS (1), anything else FAIL ((code << 1) | 1). Then it
 * hands over to the boot ROM's rv32_wait_restart, which waits for the host
 * to load the next test, a fixed address the specs file gives it
 * (rv32im-fpga.specs); Spike's image gets platform/spike_exit.S's instead.
 */
extern void rv32_wait_restart(void) __attribute__((noreturn));

void _exit(int code)
{
    volatile unsigned int *tohost = (volatile unsigned int *)0x0002FFE8u;
    tohost[0] = code == 0 ? 1u : (((unsigned int)code << 1) | 1u);
    tohost[1] = 0u;
    rv32_wait_restart();
}
