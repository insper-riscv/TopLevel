"""cocotb testbench for the 'sim' test suite.

Clocks rv32i3stage_core_sim_test, releases reset, and watches the
RAM write bus for a write to the PASS/FAIL mailbox word (same
convention as rv32_test.h / config.yaml's memory.mailbox_addr) until
the test signals a result or a timeout is hit.

Doesn't read RAM_simulation's internal `mem` array directly: this
GHDL install's VPI (mcode backend, confirmed empirically via
dut.ram._discover_all() / dut.rom._discover_all()) doesn't expose
array-of-vector ("memory") signals at all — neither RAM_simulation's
`mem` nor ROM_simulation's `memROM` show up as child objects, only
their scalar/vector ports and internal registers do. Watching the
already-visible top-level ram_addr/ram_wren/ram_en/ram_wdata signals
(the same bus rv32im_pipeline_core drives into RAM_simulation's
port map) sidesteps that entirely — no different from how the real
hardware path only ever observes memory through a bus (JTAG's
In-System Memory Editor), never a raw internal array either.

Unlike sim_runner's own ROM_HEX/TEST_NAME convention, this project's
ROM_simulation entity loads the program image itself, via a VHDL
generic (config.yaml's sim.parameters: ROM_FILE) read by a file-open
process inside ROM_simulation.vhd at elaboration — so there's no
Python-side ROM poking here at all.
"""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

RAM_BASE = 0x00000000
MAILBOX_ADDR = 0x00003FFC
MAILBOX_WORD_OFFSET = (MAILBOX_ADDR - RAM_BASE) // 4
TIMEOUT_CYCLES = 200_000
MAILBOX_PASS = 1
MAILBOX_FAIL = 2


@cocotb.test()
async def test_program(dut) -> None:
    test_name = os.environ.get("TEST_NAME", "?")
    dut._log.info(f"running {test_name}")

    cocotb.start_soon(Clock(dut.CLK, 10, unit="ns").start())

    cycles_used = 0

    dut.reset.value = 1
    await ClockCycles(dut.CLK, 5)
    dut.reset.value = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.CLK)
        cycles_used += 1

        if dut.ram_wren.value != 1 or dut.ram_en.value != 1:
            continue

        word_offset = int(dut.ram_addr.value) // 4
        if word_offset != MAILBOX_WORD_OFFSET:
            continue

        mailbox = int(dut.ram_wdata.value)
        if mailbox == MAILBOX_PASS:
            dut._log.info("PASS")
            dut._log.info(f"CLOCK CYCLES TAKEN {cycles_used}")
            return
        if mailbox == MAILBOX_FAIL:
            raise AssertionError("test signalled FAIL via RV32_FAIL()")

    raise AssertionError(
        f"timed out after {TIMEOUT_CYCLES} cycles without a PASS/FAIL signal"
    )
