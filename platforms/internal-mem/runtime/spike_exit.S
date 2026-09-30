/* What the boot ROM does at the end of a test, for the ELF Spike runs.
 *
 * On the hardware rv32_wait_restart is boot ROM code at a fixed address
 * (rv32im-fpga.specs) and a test's own image has nothing there. Spike runs
 * the test's image alone, so this file, linked into that ELF only (built
 * with -DRV32_SPIKE, which leaves the fixed address out of the link, see
 * emulator.sources in config.yaml), provides the routine: the mailbox
 * translated to HTIF (1 = pass, 3 = fail) in tohost, where Spike stops.
 *
 * tohost and fromhost, which Spike looks up by name, are the words the boot
 * ROM reserves at the top of RAM (see boot_rom.S), as absolute symbols:
 * this file takes no space in the ELF, so every address in it, and so in a
 * golden, is the one the image the hardware loads has.
 */
    .equ tohost, 0x0002FFE8
    .equ fromhost, 0x0002FFF0
    .global tohost
    .global fromhost

    .section .text
    .global rv32_wait_restart
rv32_wait_restart:
    li   t0, 0x00030000
    lw   t1, -4(t0)              // mailbox = 0x0002FFFC
    li   t2, 1
    li   t3, 1
    beq  t1, t2, 1f
    li   t3, 3
1:
    sw   t3, -24(t0)             // tohost  = 0x0002FFE8
2:  j    2b
