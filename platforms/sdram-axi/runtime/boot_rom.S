/* boot_rom.S -- the fixed, generic bootloader of the SDRAM platform with the data cache (it is the one of the
 * sdram platform plus the invalidate in rv32_wait_restart).
 *
 * The fixed, generic bootloader. Programmed into BOOT_ROM
 * once (initial full Quartus compile), never JTAG-rewritten again: only
 * FLASH gets reprogrammed per test (see config.yaml quartus:). It plays
 * the role a real SOC's boot ROM plays: it does not know what firmware
 * (FLASH content) it is booting.
 *
 * It does two things:
 *
 *  - _reset (address 0): clears the words the host and the test share
 *    (see below) and jumps to FLASH_BASE (0x800), where the toolchain's
 *    crt0 (_start, from rv32im-fpga.specs) is. The crt0 sets sp and gp,
 *    copies .data from FLASH to RAM, clears .bss, sets up TLS, runs the
 *    constructors and calls main; main returning lands in _exit
 *    (platform/_exit.c).
 *
 *  - rv32_wait_restart (fixed at 0x100, see boot_rom.ld): where every test
 *    ends. It parks the core until the host has written a new FLASH image
 *    and set the go flag, then starts over at _reset. It lives here, and
 *    not in FLASH, because FLASH is rewritten while the core waits.
 *
 * The words it clears, all at the top of RAM:
 *
 *   0x43FFFBE0  stdout length    platform/stdio.c
 *   0x43FFFBE4  stdout truncated
 *   0x43FFFFE8  tohost           HTIF, 8 bytes
 *   0x43FFFFF0  fromhost         HTIF, 8 bytes
 *   0x43FFFFF8  go flag          the host sets it to restart
 *   0x43FFFFFC  mailbox          1 = PASS, 2 = FAIL
 *
 * They must be clean on every entry, cold boot or restart: a stale nonzero
 * mailbox or go flag reads as "already done", and the previous test's
 * output must not leak into the next one. They must match
 * config.yaml's memory.mailbox_addr/go_flag_addr, rv32_test.h,
 * platform/_exit.c, platform/stdio.c and the RAM size in rv32im-fpga.specs.
 */

    .section .text.reset
    .global _reset
_reset:
    li   t0, 0x44000000
    sw   x0, -4(t0)              // mailbox   = 0x43FFFFFC
    sw   x0, -8(t0)              // go flag   = 0x43FFFFF8
    sw   x0, -16(t0)             // fromhost  = 0x43FFFFF0
    sw   x0, -12(t0)
    sw   x0, -24(t0)             // tohost    = 0x43FFFFE8
    sw   x0, -20(t0)
    li   t0, 0x43FFFBE0          // stdout header
    sw   x0, 0(t0)               // length
    sw   x0, 4(t0)               // truncated
    li   t0, 0x00000800          // FLASH_BASE: the crt0's _start
    jr   t0

    /* Same HTIF convention as the original: tohost = 1 for pass, 3 for
     * fail. Harmless on the hardware, nothing there reads it; kept so the
     * boot ROM's end of a test matches what Spike's stand-in does
     * (platform/spike_exit.S). */
    .section .text.wait_restart
    .global rv32_wait_restart
rv32_wait_restart:
    li   t0, 0x44000000
    lw   t1, -4(t0)              // mailbox
    li   t2, 1
    li   t3, 1                   // HTIF pass
    beq  t1, t2, 1f
    li   t3, 3                   // HTIF fail
1:
    sw   t3, -24(t0)             // tohost

    /* The data cache holds lines of the test that ended, and the host is about to load the next one
     * behind the cache's back (through the debug port of the SDRAM): a write to the cache's control
     * (0xF0000000) with bit 1 set drops every line. The cache writes every store through, so nothing
     * is lost. The accesses that follow (the go flag is outside the cache) wait for it to end. */
    li   t4, 0xF0000000
    li   t5, 2
    sw   t5, 0(t4)               // cache control: flush and invalidate

rv32_wait_restart_poll:
    lw   t1, -8(t0)              // go flag
    beqz t1, rv32_wait_restart_poll
    j    _reset
