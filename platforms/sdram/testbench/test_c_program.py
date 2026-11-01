"""cocotb testbench of the SDRAM platform's 'sim' test suite.

Clocks rv32im_sdram_sim_test (the core clock and the SDRAM clock),
releases reset and watches the core's data port to the SDRAM for a write
to the low word of tohost (the HTIF convention of rv32_test.h and of
memory.tohost_addr in config.yaml) until the test signals a result or
the timeout is hit.

For a "memory"-kind test (GOLDEN_PATH set, see sim_runner.run_test) a
tohost PASS also compares the golden's bytes with the content the SDRAM
chip model holds. The golden is read out of the model itself (its word
debug port), not rebuilt from the writes seen on the bus, so a word that
never reached the chip, or reached the wrong address, is caught. The
SDRAM is the RAM of this platform, so the golden's addresses are
relative to memory.ram_base, the base of the SDRAM.

A write is complete when the memory stage is released (sdram_ready and
mem_advance high on the sampling clock, the clock of the core).

The JTAG UART at 0xC0000000 is read while the program runs, the way a
host console does: a coroutine scans its 48-bit register back to back
(instruction 1) and collects the bytes. At PASS what it collected must
be what the program wrote to the stdout buffer in the SDRAM: the buffer
holds at most 1024 bytes, so the UART stream must start with all of
them, and be equal when the buffer did not overflow.

A program that reads the UART (the monitor) has a script of its own:
when c-sdram/<test>/uart_input.txt exists, the console sends its bytes
to the program, one every few scans, and at PASS everything the console
read must be equal to c-sdram/<test>/uart_expected.txt. Both paths can
be set by UART_INPUT_PATH and UART_EXPECTED_PATH.
"""

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from riscv_tools.mem_validator import compare_bytes, load_golden


def check(condition: bool, message: str) -> None:
    """Raise AssertionError with the message when condition is false."""
    if not condition:
        raise AssertionError(message)


STDOUT_ADDR = 0x43FFFBE0
STDOUT_SIZE = 1024
TOHOST_ADDR = 0x43FFFFE8
# tohost low word: 1 is a pass, (code << 1) | 1 is a failure with that
# code.
TOHOST_PASS = 1
FULL_WORD = 0xF

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
# More clocks the top has, "PORT:period_ns" separated by commas
# (CLK_MEM:7 for the SDRAM clock)
EXTRA_CLOCKS = [
    (name, int(period))
    for name, period in (
        item.split(":")
        for item in os.environ.get("SIM_EXTRA_CLOCKS", "").split(",")
        if item
    )
]


def retired_now(dut) -> int:
    """1 when an instruction retires on this clock edge, 0 otherwise.

    The top exposes the retirement pulse of the core (valid in EX,
    pipeline advancing, no exception).
    """
    try:
        return int(dut.core_retire.value == 1)
    except AttributeError, ValueError:
        return 0


async def read_model_word(dut, word_address: int) -> int:
    """Read the 32-bit word at a word address of the chip model."""
    dut.DBG_WORD_ADDR.value = word_address
    mem_clock = getattr(dut, EXTRA_CLOCKS[0][0])
    for _ in range(3):
        await RisingEdge(mem_clock)
    await Timer(1, unit="ns")
    return int(dut.DBG_WORD_DATA.value)


async def model_bytes(dut, golden: dict[int, int]) -> dict[int, int]:
    """Read the chip model at the golden's addresses.

    Returns
    -------
    dict[int, int]
        Byte value by RAM-relative byte address.
    """
    actual: dict[int, int] = {}
    first_word = (RAM_BASE - SDRAM_BASE) // 4
    for word in sorted({address // 4 for address in golden}):
        value = await read_model_word(dut, first_word + word)
        for i in range(4):
            actual[word * 4 + i] = (value >> (8 * i)) & 0xFF
    return actual


HALF_TCK_NS = 40
# the console sends a byte every few scans: the program reads and echoes
# one in about that time, and a byte that finds the 64-place receive
# queue full is lost (the answer to the scan says so)
SCANS_PER_INPUT_BYTE = 12


def script_path(variable: str, name: str) -> Path | None:
    """Find the input or expected-output file of the running program.

    Returns None when the program has none.

    The file sits in the program's own directory, next to src.c: the
    project root is three levels above the program's image
    (<root>/<build dir>/<kind>/<test>.hex).
    """
    given = os.environ.get(variable, "")
    if given:
        return Path(given) if Path(given).is_file() else None
    image = os.environ.get("ROM_HEX", "")
    if not image:
        return None
    root = Path(image).resolve().parents[2]
    found = sorted(root.glob(f"*/{os.environ.get('TEST_NAME', '?')}/{name}"))
    return found[0] if found else None


async def uart_tck(dut, **states) -> None:
    """Clock the UART's Virtual JTAG with the given flags high."""
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"UART_STATE_{name.upper()}").value = (
            1 if states.get(name) else 0
        )
    dut.UART_TCK.value = 0
    await Timer(HALF_TCK_NS, unit="ns")
    dut.UART_TCK.value = 1
    await Timer(HALF_TCK_NS, unit="ns")
    dut.UART_TCK.value = 0
    for name in ("cdr", "sdr", "udr", "uir"):
        getattr(dut, f"UART_STATE_{name.upper()}").value = 0


async def uart_scan(dut, push: int | None = None) -> list[int]:
    """Scan the UART register, sending a command.

    Returns the bytes the core sent.
    """
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
    """Scan until told to stop, always finishing a scan.

    The bytes of an interrupted scan are lost.
    """
    dut.UART_IR_IN.value = 1
    await uart_tck(dut, uir=True)
    source = script_path("UART_INPUT_PATH", "uart_input.txt")
    pending = list(source.read_bytes()) if source else []
    scans = 0
    while not stop[0]:
        push = None
        if pending and scans % SCANS_PER_INPUT_BYTE == 0:
            push = pending.pop(0)
        received.extend(await uart_scan(dut, push))
        scans += 1


async def check_uart_stream(dut, received: list[int]) -> None:
    """Check that the console read what the program put in stdout."""
    for _ in range(12):  # the answers reach the console two scans late
        received.extend(await uart_scan(dut))
    first_word = (STDOUT_ADDR - SDRAM_BASE) // 4
    length = await read_model_word(dut, first_word)
    truncated = await read_model_word(dut, first_word + 1)
    kept = min(length, STDOUT_SIZE)
    data = bytearray()
    for word in range((kept + 3) // 4):
        data += (await read_model_word(dut, first_word + 2 + word)).to_bytes(
            4, "little"
        )
    script = script_path("UART_EXPECTED_PATH", "uart_expected.txt")
    if script:
        check(
            bytes(received) == script.read_bytes(),
            f"UART stream {bytes(received)!r} differs from {script.name} "
            f"{script.read_bytes()!r}",
        )
    expected = list(data[:kept])
    got = received[:kept]
    check(
        got == expected,
        f"UART stream {bytes(got)!r} differs from the stdout buffer "
        f"{bytes(expected)!r}",
    )
    if not truncated:
        check(
            len(received) == kept,
            f"UART stream has {len(received)} bytes, the buffer {kept}",
        )


class Run:
    """State of a simulated program: UART console and counters."""

    def __init__(self, dut, clock) -> None:
        """Start the tick counter and the UART console of the program.

        Parameters
        ----------
        dut : object
            Top-level of the simulation.
        clock : object
            Base clock, whose rising edges are the ticks of the run.
        """
        self.dut = dut
        self.test_name = os.environ.get("TEST_NAME", "?")
        self.ticks = 0
        self.core_cycles = 0
        self.retired = 0
        self.uart_bytes: list[int] = []
        self.console_stop = [False]
        cocotb.start_soon(self._count_ticks(clock))
        self.console = cocotb.start_soon(
            uart_console(dut, self.uart_bytes, self.console_stop)
        )

    async def _count_ticks(self, clock) -> None:
        """Count the ticks of the base clock, three per core cycle."""
        while True:
            await RisingEdge(clock)
            self.ticks += 1

    async def stop_console(self) -> None:
        """Stop the UART console and log what it read."""
        self.console_stop[0] = True
        await self.console
        self.dut._log.info(f"the console read {bytes(self.uart_bytes)!r}")

    async def finish_pass(self, cycles_used: int) -> None:
        """Log the result and check the UART stream and the golden."""
        dut = self.dut
        dut._log.info("PASS")
        dut._log.info(f"CLOCK CYCLES TAKEN {cycles_used}")
        dut._log.info(
            f"CORE CYCLES {self.core_cycles} "
            f"INSTRUCTIONS RETIRED {self.retired}"
        )
        await self.stop_console()
        await check_uart_stream(dut, self.uart_bytes)
        if GOLDEN_PATH is None:
            return
        golden = load_golden(GOLDEN_PATH)
        actual = await model_bytes(dut, golden)
        matches = compare_bytes(
            actual,
            golden,
            actual_label=self.test_name,
            golden_label=GOLDEN_PATH.name,
        )
        if not matches:
            message = (
                f"{self.test_name}: tohost PASS but the SDRAM content "
                f"doesn't match {GOLDEN_PATH.name}: see the diff above"
            )
            raise AssertionError(message)


def tohost_write(dut) -> int | None:
    """Return the data of a tohost write that completes on this edge.

    Returns
    -------
    int or None
        The written word, or None when this edge completes no write of
        the low word of tohost with the low bit set.
    """
    if (
        dut.sdram_wren.value != 1
        or dut.sdram_ready.value != 1
        or dut.mem_advance.value != 1
    ):
        return None
    try:
        address = int(dut.sdram_addr.value)
        wdata = int(dut.sdram_wdata.value)
        byteena = int(dut.sdram_byteena.value)
    except ValueError:
        # an undefined address or data: nothing meaningful to look at
        return None
    is_tohost = address // 4 == TOHOST_ADDR // 4
    if is_tohost and byteena == FULL_WORD and wdata & 1:
        return wdata
    return None


def start_clocks(dut):
    """Start the base and the extra clocks and return the base clock."""
    clock = getattr(dut, SIM_CLOCK)
    cocotb.start_soon(Clock(clock, SIM_CLOCK_PERIOD_NS, unit="ns").start())
    for extra_name, extra_period in EXTRA_CLOCKS:
        cocotb.start_soon(
            Clock(getattr(dut, extra_name), extra_period, unit="ns").start()
        )
    return clock


@cocotb.test()
async def test_program(dut) -> None:
    """Run the program until it writes its result to tohost."""
    test_name = os.environ.get("TEST_NAME", "?")
    dut._log.info(f"running {test_name}")

    clock = start_clocks(dut)
    reset = getattr(dut, SIM_RESET)
    sample_clock = getattr(dut, SIM_SAMPLE_CLOCK)
    reset.value = SIM_RESET_ACTIVE
    await ClockCycles(clock, 5)
    reset.value = 1 - SIM_RESET_ACTIVE

    # the program's time is counted in ticks of the base clock, three
    # per core cycle, the same unit internal-mem's testbench reports,
    # so the two platforms' cycles can be compared
    run = Run(dut, clock)
    while run.ticks < TIMEOUT_CYCLES:
        await RisingEdge(sample_clock)
        cycles_used = run.ticks
        run.core_cycles += 1
        run.retired += retired_now(dut)

        wdata = tohost_write(dut)
        if wdata is None:
            continue
        if wdata == TOHOST_PASS:
            await run.finish_pass(cycles_used)
            return
        message = f"test signalled FAIL via RV32_FAIL(), code {wdata >> 1}"
        raise AssertionError(message)

    await run.stop_console()
    message = f"timed out after {TIMEOUT_CYCLES} cycles without a result"
    raise AssertionError(message)
