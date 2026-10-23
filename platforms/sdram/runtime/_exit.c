/* The _exit the toolchain's crt0 ends in: main() returning (or exit())
 * lands here, and picolibc does not provide it.
 *
 * Reports the result the way RV32_PASS()/RV32_FAIL() (rv32_test.h) do:
 * code 0 is PASS (mailbox 1), anything else FAIL (mailbox 2). Then it
 * hands over to the boot ROM's rv32_wait_restart, which waits for the host
 * to load the next test, a fixed address the specs file gives it
 * (rv32im-fpga.specs); Spike's image gets platform/spike_exit.S's instead.
 */
extern void rv32_wait_restart(void) __attribute__((noreturn));

void _exit(int code)
{
    *(volatile unsigned int *)0x43FFFFFCu = code == 0 ? 1u : 2u;
    rv32_wait_restart();
}
