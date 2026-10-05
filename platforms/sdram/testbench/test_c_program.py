"""cocotb testbench of the SDRAM platform's 'sim' test suite.

Clocks rv32im_sdram_sim_test (the core clock and the SDRAM clock), releases reset and watches the
core's data port to the SDRAM for a write to the PASS/FAIL mailbox word (the convention of
rv32_test.h and of memory.mailbox_addr in config.yaml) until the test signals a result or the
timeout is hit.

For a "memory"-kind test (GOLDEN_PATH set, see sim_runner.run_test) a mailbox PASS also compares
the golden's bytes with the content the SDRAM chip model holds. The golden is read out of the
model itself (its word debug port), not rebuilt from the writes seen on the bus, so a word that
never reached the chip, or reached the wrong address, is caught. The SDRAM is the RAM of this
platform, so the golden's addresses are relative to memory.ram_base, the base of the SDRAM.

A write is complete when the memory stage is released (sdram_ready and mem_advance high on the
sampling clock, the clock of the core).

The JTAG UART at 0xC0000000 is read while the program runs, the way a host console does: a
coroutine scans its 48-bit register back to back (instruction 1) and collects the bytes. At PASS
what it collected must be what the program wrote to the stdout buffer in the SDRAM: the buffer
holds at most 1024 bytes, so the UART stream must start with all of them, and be equal when the
buffer did not overflow.
"""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from riscv_tools.mem_validator import compare_bytes, load_golden

STDOUT_ADDR = 0x43FFFBE0
STDOUT_SIZE = 1024
MAILBOX_ADDR = 0x43FFFFFC
MAILBOX_PASS = 1
MAILBOX_FAIL = 2

SDRAM_BASE = 0x40000000
RAM_BASE = int(os.environ.get("RAM_BASE", str(SDRAM_BASE)))
_golden_path_env = os.environ.get("GOLDEN_PATH", "")
GOLDEN_PATH = Path(_golden_path_env) if _golden_path_env else None

SIM_CLOCK = os.environ.get("SIM_CLOCK", "CLK")
SIM_CLOCK_PERIOD_NS = int(os.environ.get("SIM_CLOCK_PERIOD_NS", "10"))
SIM_RESET = os.environ.get("SIM_RESET", "reset")
SIM_RESET_ACTIVE = int(os.environ.get("SIM_RESET_ACTIVE", "1"))
SIM_SAMPLE_CLOCK = os.environ.get("SIM_SAMPLE_CLOCK", "pll_clk_idexmem")
TIMEOUT_CYCLES = int(os.environ.get("SIM_TIMEOUT_CYCLES", "200000"))
# More clocks the top has, "PORT:period_ns" separated by commas (CLK_MEM:7 for the SDRAM clock)
EXTRA_CLOCKS = [
    (name, int(period))
    for name, period in (
        item.split(":") for item in os.environ.get("SIM_EXTRA_CLOCKS", "").split(",") if item
    )
]


async def read_model_word(dut, word_address: int) -> int:
    """The 32-bit word at a word address of the SDRAM chip model."""
    dut.DBG_WORD_ADDR.value = word_address
    mem_clock = getattr(dut, EXTRA_CLOCKS[0][0])
    for _ in range(3):
        await RisingEdge(mem_clock)
    await Timer(1, unit="ns")
    return int(dut.DBG_WORD_DATA.value)


async def model_bytes(dut, golden: dict[int, int]) -> dict[int, int]:
    """The bytes of the chip model at the golden's addresses, {RAM-relative byte address: value}."""
    actual: dict[int, int] = {}
    first_word = (RAM_BASE - SDRAM_BASE) // 4
    for word in sorted({address // 4 for address in golden}):
        value = await read_model_word(dut, first_word + word)
        for i in range(4):
            actual[word * 4 + i] = (value >> (8 * i)) & 0xFF
    return actual


HALF_TCK_NS = 40


async def uart_tck(dut, **states) -> None:
    """One clock of the UART's Virtual JTAG instance with the given state flags high."""
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"UART_STATE_{name.upper()}").value = 1 if states.get(name) else 0
    dut.UART_TCK.value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    dut.UART_TCK.value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    dut.UART_TCK.value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"UART_STATE_{name.upper()}").value = 0


async def uart_scan(dut, push: int | None = None) -> list[int]:
    """One scan of the UART register: sends a command, returns the bytes the core sent."""
    value = 0 if push is None else (1 << 8) | push
    await uart_tck(dut, cdr=True)
    out = 0
    for i in range(48):
        dut.UART_TDI.value = (value >> i) & 1
        await Timer(1, unit="ns")
        out |= int(dut.UART_TDO.value) << i
        await uart_tck(dut, sdr=True)
    await uart_tck(dut, udr=True)
    count = (out >> 32) & 7
    return [(out >> (8 * i)) & 0xFF for i in range(count)]


async def uart_console(dut, received: list[int], stop: list[bool]) -> None:
    """Scans until told to stop, always finishing a scan: the bytes of an interrupted scan are lost."""
    dut.UART_IR_IN.value = 1
    await uart_tck(dut, uir=True)
    while not stop[0]:
        received.extend(await uart_scan(dut))


async def check_uart_stream(dut, received: list[int]) -> None:
    """At the end of a program: what the console read is what the program put in its stdout."""
    for _ in range(12):               # the answers reach the console two scans late
        received.extend(await uart_scan(dut))
    first_word = (STDOUT_ADDR - SDRAM_BASE) // 4
    length = await read_model_word(dut, first_word)
    truncated = await read_model_word(dut, first_word + 1)
    kept = min(length, STDOUT_SIZE)
    data = bytearray()
    for word in range((kept + 3) // 4):
        data += (await read_model_word(dut, first_word + 2 + word)).to_bytes(4, "little")
    expected = list(data[:kept])
    got = received[:kept]
    assert got == expected, f"UART stream {bytes(got)!r} differs from the stdout buffer {bytes(expected)!r}"
    if not truncated:
        assert len(received) == kept, f"UART stream has {len(received)} bytes, the buffer {kept}"


@cocotb.test()
async def test_program(dut) -> None:
    test_name = os.environ.get("TEST_NAME", "?")
    dut._log.info(f"running {test_name}")

    clock = getattr(dut, SIM_CLOCK)
    reset = getattr(dut, SIM_RESET)
    sample_clock = getattr(dut, SIM_SAMPLE_CLOCK)
    cocotb.start_soon(Clock(clock, SIM_CLOCK_PERIOD_NS, unit="ns").start())
    for extra_name, extra_period in EXTRA_CLOCKS:
        cocotb.start_soon(Clock(getattr(dut, extra_name), extra_period, unit="ns").start())

    reset.value = SIM_RESET_ACTIVE
    await ClockCycles(clock, 5)
    reset.value = 1 - SIM_RESET_ACTIVE

    # the program's time is counted in ticks of the base clock, three per core cycle, the same unit
    # internal-mem's testbench reports, so the two platforms' cycles can be compared
    ticks = [0]

    async def count_ticks() -> None:
        while True:
            await RisingEdge(clock)
            ticks[0] += 1

    cocotb.start_soon(count_ticks())
    uart_bytes: list[int] = []
    console_stop = [False]
    console = cocotb.start_soon(uart_console(dut, uart_bytes, console_stop))
    while ticks[0] < TIMEOUT_CYCLES:
        await RisingEdge(sample_clock)
        cycles_used = ticks[0]

        # a write of the data port that completes on this edge
        if (
            dut.sdram_wren.value != 1
            or dut.sdram_ready.value != 1
            or dut.mem_advance.value != 1
        ):
            continue
        try:
            address = int(dut.sdram_addr.value)
            wdata = int(dut.sdram_wdata.value)
            byteena = int(dut.sdram_byteena.value)
        except ValueError:
            # an undefined address or data: nothing meaningful to look at
            continue

        if address // 4 != MAILBOX_ADDR // 4 or not byteena & 1:
            continue

        if wdata == MAILBOX_PASS:
            dut._log.info("PASS")
            dut._log.info(f"CLOCK CYCLES TAKEN {cycles_used}")
            console_stop[0] = True
            await console
            await check_uart_stream(dut, uart_bytes)
            if GOLDEN_PATH is not None:
                golden = load_golden(GOLDEN_PATH)
                actual = await model_bytes(dut, golden)
                if not compare_bytes(
                    actual, golden, actual_label=test_name, golden_label=GOLDEN_PATH.name
                ):
                    raise AssertionError(
                        f"{test_name}: mailbox PASS but the SDRAM content doesn't match "
                        f"{GOLDEN_PATH.name}: see the diff above"
                    )
            return
        if wdata == MAILBOX_FAIL:
            raise AssertionError("test signalled FAIL via RV32_FAIL()")

    raise AssertionError(
        f"timed out after {TIMEOUT_CYCLES} cycles without a PASS/FAIL signal"
    )
