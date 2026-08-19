"""cocotb testbench for the 'sim' test suite: loads the ROM image for
the test named by $TEST_NAME (already converted to .hex by
build_tests.py --emit hex), clocks the DUT, and polls the PASS/FAIL
mailbox word (same convention as rv32_test.h / config.yaml
memory.mailbox_addr) until the test signals a result or a timeout is
hit.

<<< ADJUST: dut.rom_inst / dut.ram_inst below, and the clk/rst signal
names, are placeholders — they must match the real VHDL hierarchy of
whatever core this testbench points at. This can't be resolved without
that core; see README.md.
"""
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

RAM_BASE = 0x00000000
MAILBOX_ADDR = 0x00003FFC
MAILBOX_WORD_OFFSET = (MAILBOX_ADDR - RAM_BASE) // 4
TIMEOUT_CYCLES = 200_000


def load_hex(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text().splitlines() if line.strip()]


@cocotb.test()
async def test_program(dut):
    words = load_hex(Path(os.environ["ROM_HEX"]))

    # <<< ADJUST: replace with the real ROM memory-array handle.
    for i, w in enumerate(words):
        dut.rom_inst.mem_array[i].value = w

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk)
        # <<< ADJUST: replace with the real RAM memory-array handle.
        mailbox = int(dut.ram_inst.mem_array[MAILBOX_WORD_OFFSET].value)
        if mailbox == 1:
            dut._log.info("PASS")
            return
        if mailbox == 2:
            assert False, "test signalled FAIL via RV32_FAIL()"

    assert False, f"timed out after {TIMEOUT_CYCLES} cycles without a PASS/FAIL signal"
