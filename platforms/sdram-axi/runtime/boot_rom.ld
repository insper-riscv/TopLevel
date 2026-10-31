/* Linker script for boot_rom.S -- the fixed, generic bootloader.
 * Compiled and JTAG-written ONCE (part of the initial full Quartus
 * compile), never touched again -- see boot_rom.S's own header
 * comment and config.yaml quartus:.
 *
 * ORIGIN/LENGTH must match rv32im_pipeline_core.vhd's
 * BOOT_ROM_SIZE_BYTES and config.yaml memory.boot_rom_words.
 *
 * rv32_wait_restart is pinned to a FIXED address: the tests' images
 * reach it as an absolute symbol (--defsym=rv32_wait_restart=0x100 in
 * rv32im-fpga.specs) without linking against this file at all. The
 * ASSERT below catches _reset growing past that reservation.
 */

MEMORY
{
  boot_rom (rx) : ORIGIN = 0x00000000, LENGTH = 2K
}

RESET_RESERVED = 0x100;

OUTPUT_ARCH("riscv")
ENTRY(_reset)

SECTIONS
{
  .text.reset 0x00000000 : { *(.text.reset) } > boot_rom
  ASSERT(SIZEOF(.text.reset) <= RESET_RESERVED,
         "boot_rom.S's _reset grew past RESET_RESERVED -- move rv32_wait_restart's fixed address (here and in rv32im-fpga.specs) or grow the reservation")

  .text.wait_restart RESET_RESERVED : { *(.text.wait_restart) } > boot_rom

  . = ALIGN(4);
  ASSERT(. <= ORIGIN(boot_rom) + LENGTH(boot_rom), "boot_rom.S exceeds BOOT_ROM -- grow memory.boot_rom_words (config.yaml) and BOOT_ROM_SIZE_BYTES (rv32im_pipeline_core.vhd)")
}
