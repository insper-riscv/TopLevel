"""cocotb testbench for the 'sim' test suite.

Clocks rv32i3stage_core_sim_test, releases reset, and watches the
RAM write bus for a write to the PASS/FAIL mailbox word (same
convention as rv32_test.h / config.yaml's memory.mailbox_addr) until
the test signals a result or a timeout is hit. For a "memory"-kind
test (GOLDEN_PATH set — see sim_runner.run_test), also reconstructs
RAM's final byte content from every write seen on that same bus and
compares it against golden.json on a mailbox PASS, the same
RAM-vs-golden check orchestrator.run_one does for real hardware from
a JTAG dump. Before this, a mailbox PASS alone was reported as a sim
PASS regardless of whether the test's actual computed value was
right — e.g. a wrong sum could reach RV32_PASS() and only get caught
once the same test ran for real, sometimes much later. Correctness of
the mailbox write itself still ONLY means "the program reached
RV32_PASS()/RV32_FAIL()" — it says nothing about whether the values it
computed along the way were correct, which is exactly what the golden
compare below is for.

Doesn't read RAM_simulation's internal `mem` array directly: this
GHDL install's VPI (mcode backend, confirmed empirically via
dut.ram._discover_all() / dut.rom._discover_all()) doesn't expose
array-of-vector ("memory") signals at all — neither RAM_simulation's
`mem` nor ROM_simulation's `memROM` show up as child objects, only
their scalar/vector ports and internal registers do. Watching the
already-visible top-level ram_addr/ram_wren/ram_en/ram_wdata/
ram_byteena signals (the same bus rv32im_pipeline_core drives into
RAM_simulation's port map) sidesteps that entirely — no different from
how the real hardware path only ever observes memory through a bus
(JTAG's In-System Memory Editor), never a raw internal array either.

Unlike sim_runner's own ROM_HEX/TEST_NAME convention, this project's
ROM_simulation entity loads the program image itself, via a VHDL
generic (config.yaml's sim.parameters: ROM_FILE) read by a file-open
process inside ROM_simulation.vhd at elaboration — so there's no
Python-side ROM poking here at all.
"""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from riscv_tools.mailbox import word_offset
from riscv_tools.mem_validator import compare_bytes, load_golden

# Must stay in sync with config.yaml's memory.mailbox_addr and
# boot_rom.S's own hardcoded mailbox li/sw (the mailbox write itself
# still comes from the TEST's own RV32_PASS()/RV32_FAIL(), compiled
# into FLASH — boot_rom.S only CLEARS it on _reset) — same duplication
# crt0.S used to have, not sourced from config.yaml here since
# ROM_simulation already takes its program image via a VHDL generic,
# not env/argv (see module docstring).
#
# dut.ram_addr below is the raw top-level bus (rv32im_pipeline_core's
# own ram_addr output, i.e. exmem_alu_out) — an ABSOLUTE byte address,
# not RAM-relative, unlike the real-hardware JTAG path (mailbox.
# word_offset()'s default), which addresses RAM through the In-System
# Memory Editor's own 0-based internal word index. relative=False picks
# the bus-snoop convention instead — see word_offset's own docstring.
MAILBOX_ADDR = 0x0002FFFC
MAILBOX_WORD_OFFSET = word_offset(0, MAILBOX_ADDR, relative=False)
TIMEOUT_CYCLES = 200_000
MAILBOX_PASS = 1
MAILBOX_FAIL = 2

# RAM_BASE/GOLDEN_PATH come from sim_runner.run_test's extra_env, not
# hardcoded like MAILBOX_ADDR above: GOLDEN_PATH is inherently
# per-test (a "unit"-kind test has none — see run_suite), and
# RAM_BASE, unlike the mailbox address, is exactly the kind of number
# that already caused a real, silent bug once when hand-duplicated
# instead of threaded through from config.yaml (see the RAM-addressing
# fix in core_fpga_test.vhd / Tests/docs/MEMORY_ARCHITECTURE.md) — not
# worth risking a second time here.
RAM_BASE = int(os.environ.get("RAM_BASE", "0"))
_golden_path_env = os.environ.get("GOLDEN_PATH", "")
GOLDEN_PATH = Path(_golden_path_env) if _golden_path_env else None


@cocotb.test()
async def test_program(dut) -> None:
    test_name = os.environ.get("TEST_NAME", "?")
    dut._log.info(f"running {test_name}")

    cocotb.start_soon(Clock(dut.CLK, 10, unit="ns").start())

    cycles_used = 0
    # {RAM-relative byte address: byte value} — updated on every RAM
    # write seen on the bus, honoring ram_byteena the same way
    # RAM_simulation.vhd itself does (mask bit i gates byte lane i of
    # the 32-bit word at the write's own word-aligned address), so
    # this ends up an exact reconstruction of whatever RAM_simulation
    # actually stored — not just a record of the mailbox/results
    # writes a test happens to make.
    ram_bytes: dict[int, int] = {}

    dut.reset.value = 1
    await ClockCycles(dut.CLK, 5)
    dut.reset.value = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.CLK)
        cycles_used += 1

        if dut.ram_wren.value != 1 or dut.ram_en.value != 1:
            continue

        try:
            addr = int(dut.ram_addr.value)
        except ValueError:
            # Undefined ('U'/'X') address -- nothing meaningful to do
            # with this write at all, not even locate it.
            continue

        # A write whose DATA (not address) is undefined means some
        # earlier read came back 'U' and propagated through the ALU
        # into this store -- exactly the failure mode an unwired/
        # uninitialized memory read produces (see the FLASH_MEM
        # comment in rv32im_pipeline_core.vhd for the real bug this
        # caught once already). Leave these bytes out of ram_bytes
        # rather than crashing the whole test on a raw int() conversion
        # -- compare_bytes below reports them "missing" if golden.json
        # expects a value here, a clearer diagnostic than an uncaught
        # ValueError.
        try:
            wdata = int(dut.ram_wdata.value)
            byteena = int(dut.ram_byteena.value)
        except ValueError:
            wdata = None

        word_base = addr - (addr % 4)
        if wdata is not None:
            for i in range(4):
                if byteena & (1 << i):
                    ram_bytes[word_base + i - RAM_BASE] = (wdata >> (8 * i)) & 0xFF

        word_offset = addr // 4
        if word_offset != MAILBOX_WORD_OFFSET:
            continue
        if wdata is None:
            continue

        mailbox = wdata
        if mailbox == MAILBOX_PASS:
            dut._log.info("PASS")
            dut._log.info(f"CLOCK CYCLES TAKEN {cycles_used}")
            if GOLDEN_PATH is not None:
                golden = load_golden(GOLDEN_PATH)
                if not compare_bytes(
                    ram_bytes, golden, actual_label=test_name, golden_label=GOLDEN_PATH.name
                ):
                    raise AssertionError(
                        f"{test_name}: mailbox PASS but RAM content doesn't match "
                        f"{GOLDEN_PATH.name} — see the diff above"
                    )
            return
        if mailbox == MAILBOX_FAIL:
            raise AssertionError("test signalled FAIL via RV32_FAIL()")

    raise AssertionError(
        f"timed out after {TIMEOUT_CYCLES} cycles without a PASS/FAIL signal"
    )
