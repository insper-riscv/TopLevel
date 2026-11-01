"""cocotb testbench for the 'sim' test suite.

Clocks rv32i3stage_core_sim_test, releases reset, and watches the
RAM write bus for a write to the low word of tohost (same
HTIF convention as rv32_test.h / config.yaml's memory.tohost_addr) until
the test signals a result or a timeout is hit. For a "memory"-kind
test (GOLDEN_PATH set — see sim_runner.run_test), also reconstructs
RAM's final byte content from every write seen on that same bus and
compares it against golden.json on a tohost PASS, the same
RAM-vs-golden check orchestrator.run_one does for real hardware from
a JTAG dump. Before this, a tohost PASS alone was reported as a sim
PASS regardless of whether the test's actual computed value was
right — e.g. a wrong sum could reach RV32_PASS() and only get caught
once the same test ran for real, sometimes much later. Correctness of
the tohost write itself still ONLY means "the program reached
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
process inside rom_simulation.vhd at elaboration — so there's no
Python-side ROM poking here at all.

The same module drives the hardware top (core_fpga_test, see
config.fpga-sim.yaml) too: its clock, reset and timeout come from the
SIM_* environment variables that profile sets (sim.env), defaulting to
the simulation top's CLK/reset. The bus watched is the same signals
either way, they have the same names in both tops.
"""

import logging
import os
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.task import Task
from cocotb.triggers import (
    ClockCycles,
    FallingEdge,
    RisingEdge,
    Timer,
    with_timeout,
)
from riscv_tools.htif import word_offset
from riscv_tools.mem_validator import compare_bytes, load_golden

LOG = logging.getLogger("cocotb.testbench")

# Must stay in sync with config.yaml's memory.tohost_addr and
# boot_rom.S's own hardcoded tohost clear (the tohost write itself still
# comes from the TEST's own RV32_PASS()/RV32_FAIL(), compiled into
# FLASH; boot_rom.S only CLEARS it on _reset). Not sourced from
# config.yaml here since ROM_simulation already takes its program image
# via a VHDL generic, not env/argv (see module docstring).  dut.ram_addr
# below is the raw top-level bus (rv32im_pipeline_core's own ram_addr
# output, i.e. exmem_alu_out), an ABSOLUTE byte address, not
# RAM-relative, unlike the real-hardware JTAG path (htif.word_offset()'s
# default). relative=False picks the bus-snoop convention instead, see
# word_offset's own docstring.
TOHOST_ADDR = 0x0002FFE8
TOHOST_WORD_OFFSET = word_offset(0, TOHOST_ADDR, relative=False)
# tohost low word: 1 is a pass, (code << 1) | 1 is a failure with that
# code.
TOHOST_PASS = 1
FULL_WORD = 0xF

# RAM_BASE/GOLDEN_PATH come from sim_runner.run_test's extra_env, not
# hardcoded like TOHOST_ADDR above: GOLDEN_PATH is inherently
# per-test (a "unit"-kind test has none — see run_suite), and
# RAM_BASE, unlike the tohost address, is exactly the kind of number
# that already caused a real, silent bug once when hand-duplicated
# instead of threaded through from config.yaml (see the RAM-addressing
# fix in core_fpga_test.vhd / Tests/docs/MEMORY_ARCHITECTURE.md) — not
# worth risking a second time here.
RAM_BASE = int(os.environ.get("RAM_BASE", "0"))
_golden_path_env = os.environ.get("GOLDEN_PATH", "")
GOLDEN_PATH = Path(_golden_path_env) if _golden_path_env else None

# What this drives, by name. Defaults are rv32i3stage_core_sim_test's:
# a base clock CLK that its clock generator divides by three, an
# active-high reset, and a timeout counted in ticks of CLK (three per
# core cycle). config.fpga-sim.yaml overrides them for core_fpga_test,
# whose clock is CLOCK_50, reset is the active-low FPGA_RESET_N, and
# whose RAM is clocked by the PLL's second output (SIM_SAMPLE_CLOCK):
# the bus is sampled on the clock the RAM captures it with.
SIM_CLOCK = os.environ.get("SIM_CLOCK", "CLK")
SIM_CLOCK_PERIOD_NS = int(os.environ.get("SIM_CLOCK_PERIOD_NS", "10"))
SIM_RESET = os.environ.get("SIM_RESET", "reset")
SIM_RESET_ACTIVE = int(os.environ.get("SIM_RESET_ACTIVE", "1"))
SIM_SAMPLE_CLOCK = os.environ.get("SIM_SAMPLE_CLOCK", SIM_CLOCK)
TIMEOUT_CYCLES = int(os.environ.get("SIM_TIMEOUT_CYCLES", "200000"))
# More clocks the top has, "PORT:period_ns" separated by commas (for
# example the SDRAM platform's CLK_MEM:7). They are driven for the whole
# test and need no reset of their own.
EXTRA_CLOCKS = [
    (name, int(period))
    for name, period in (
        item.split(":")
        for item in os.environ.get("SIM_EXTRA_CLOCKS", "").split(",")
        if item
    )
]

UART_TX_EXPECTED = b"Hello, world!\r\n"
UART_ECHO_EXPECTED = b"RX test\r\n"
UART_ERRORS_PREFIX = b"ATR"
UART_ERRORS_READY = b"OB"
UART_ERRORS_RX_INPUT = bytes((0x12, 0x34))
UART_BURST_PAYLOAD = bytes(range(32))
UART_ERRORS_FINAL = b"P"
UART_BIT_TIME_NS = round(1_000_000_000 / 115_200)


def check(condition: bool, message: str) -> None:
    """Raise AssertionError with the message when condition is false."""
    if not condition:
        raise AssertionError(message)


async def receive_uart_byte(uart_tx: Any) -> int:
    """Receive one 8N1 byte from the UART TX line."""
    # Detecta o início do quadro 8N1.
    await FallingEdge(uart_tx)

    # Confere o centro do start bit.
    await Timer(UART_BIT_TIME_NS // 2, unit="ns")
    check(int(uart_tx.value) == 0, "UART start bit inválido")

    value = 0

    # Amostra os oito bits no centro, LSB primeiro.
    for bit_index in range(8):
        await Timer(UART_BIT_TIME_NS, unit="ns")
        value |= int(uart_tx.value) << bit_index

    # Amostra o stop bit.
    await Timer(UART_BIT_TIME_NS, unit="ns")
    check(int(uart_tx.value) == 1, "UART stop bit inválido")

    return value


async def receive_uart_message(
    uart_tx: Any,
    byte_count: int = len(UART_TX_EXPECTED),
) -> bytes:
    """Receive a message of byte_count bytes from the UART TX line."""
    received = bytearray()

    for _ in range(byte_count):
        received.append(await receive_uart_byte(uart_tx))

    return bytes(received)


async def send_uart_byte(uart_rx: Any, value: int) -> None:
    """Send one 8N1 byte to the UART RX line."""
    # Start bit.
    uart_rx.value = 0
    await Timer(UART_BIT_TIME_NS, unit="ns")

    # Oito bits de dados, LSB primeiro.
    for bit_index in range(8):
        uart_rx.value = (value >> bit_index) & 1
        await Timer(UART_BIT_TIME_NS, unit="ns")

    # Stop bit.
    uart_rx.value = 1
    await Timer(UART_BIT_TIME_NS, unit="ns")


async def send_uart_message(uart_rx: Any, message: bytes) -> None:
    """Send a message to the UART RX line, byte by byte."""
    # Mantém a linha ociosa antes do primeiro start bit.
    uart_rx.value = 1
    await Timer(UART_BIT_TIME_NS, unit="ns")

    for value in message:
        await send_uart_byte(uart_rx, value)


async def exchange_uart_errors(uart_rx: Any, uart_tx: Any) -> bytes:
    """Run the coordinated protocol of uart_hardware_test.py."""
    received = bytearray()

    received.extend(
        await receive_uart_message(uart_tx, len(UART_ERRORS_PREFIX))
    )

    ready_capture = cocotb.start_soon(
        receive_uart_message(uart_tx, len(UART_ERRORS_READY))
    )
    await send_uart_message(uart_rx, UART_ERRORS_RX_INPUT)
    received.extend(await ready_capture)

    burst_capture = cocotb.start_soon(
        receive_uart_message(
            uart_tx,
            len(UART_BURST_PAYLOAD) + len(UART_ERRORS_FINAL),
        )
    )
    await send_uart_message(uart_rx, UART_BURST_PAYLOAD)
    received.extend(await burst_capture)
    return bytes(received)


def retired_now(dut: Any) -> int:
    """1 when an instruction retires on this clock edge, 0 otherwise.

    The top exposes the retirement pulse of the core (valid in EX,
    pipeline advancing, no exception).
    """
    try:
        return int(dut.core_retire.value == 1)
    except AttributeError, ValueError:
        return 0


def start_uart(
    dut: Any, test_name: str
) -> tuple[bytes | None, Task[bytes] | None]:
    """Start the UART capture that the named test needs.

    Returns
    -------
    tuple of (bytes or None, Task or None)
        The expected bytes and the capture task, both None when the
        test does not use the UART.
    """
    if test_name == "uart-tx":
        expected = UART_TX_EXPECTED
    elif test_name == "uart-echo":
        expected = UART_ECHO_EXPECTED
    elif test_name == "uart-errors":
        expected = (
            UART_ERRORS_PREFIX
            + UART_ERRORS_READY
            + UART_BURST_PAYLOAD
            + UART_ERRORS_FINAL
        )
    else:
        return None, None
    if test_name != "uart-tx":
        dut.UART_RX.value = 1
    if test_name == "uart-errors":
        capture = exchange_uart_errors(dut.UART_RX, dut.UART_TX)
    else:
        capture = receive_uart_message(dut.UART_TX, len(expected))
    return expected, cocotb.start_soon(capture)


class RamBus:
    """Rebuild the RAM content from the writes seen on its bus.

    ``ram_bytes`` maps a RAM-relative byte address to its value. It is
    updated on every RAM write seen on the bus, honoring ram_byteena
    the same way ram_simulation.vhd itself does (mask bit i gates byte
    lane i of the 32-bit word at the write's own word-aligned
    address), so it ends up an exact reconstruction of whatever
    RAM_simulation actually stored, not just a record of the
    tohost/results writes a test happens to make.
    """

    def __init__(self, dut: Any) -> None:
        """Watch the RAM bus of the given top-level."""
        self.dut = dut
        self.ram_bytes: dict[int, int] = {}

    def _record(self, addr: int, wdata: int, byteena: int) -> None:
        """Store the bytes that the write enables."""
        word_base = addr - (addr % 4)
        for i in range(4):
            if byteena & (1 << i):
                self.ram_bytes[word_base + i - RAM_BASE] = (
                    wdata >> (8 * i)
                ) & 0xFF

    def tohost_write(self) -> int | None:
        """Record the write of this edge and return a tohost write.

        Returns
        -------
        int or None
            The word written to the low word of tohost, or None when
            this edge writes anything else.
        """
        dut = self.dut
        if dut.ram_wren.value != 1 or dut.ram_en.value != 1:
            return None
        try:
            addr = int(dut.ram_addr.value)
        except ValueError:
            # Undefined ('U'/'X') address -- nothing meaningful to do
            # with this write at all, not even locate it.
            return None

        # A write whose DATA (not address) is undefined means some
        # earlier read came back 'U' and propagated through the ALU
        # into this store. Leave these bytes out of ram_bytes rather
        # than crashing the whole test on a raw int() conversion:
        # compare_bytes reports them "missing" if golden.json expects
        # a value here, a clearer diagnostic than an uncaught error.
        try:
            wdata = int(dut.ram_wdata.value)
            byteena = int(dut.ram_byteena.value)
        except ValueError:
            return None

        self._record(addr, wdata, byteena)
        is_tohost = addr // 4 == TOHOST_WORD_OFFSET
        if is_tohost and wdata & 1 and byteena == FULL_WORD:
            return wdata
        return None


async def finish_pass(
    test_name: str,
    bus: RamBus,
    uart: tuple[bytes | None, Task[bytes] | None, Task[None] | None],
    counters: tuple[int, int],
) -> None:
    """Check the UART and the RAM content after a tohost PASS.

    Parameters
    ----------
    test_name : str
        Name of the running test.
    bus : RamBus
        RAM content reconstructed from the bus.
    uart : tuple of (bytes or None, Task or None, Task or None)
        Expected bytes, capture task and drive task of the UART.
    counters : tuple of (int, int)
        Clock cycles and instructions retired until the PASS.
    """
    expected, capture, drive = uart
    if drive is not None:
        await with_timeout(drive, 1, "ms")
    if capture is not None:
        received = await with_timeout(capture, 1, "ms")
        check(
            received == expected,
            f"UART TX incorreto: esperado {expected!r}, recebido {received!r}",
        )
        LOG.info("UART TX recebido: %r", received)
    cycles_used, retired = counters
    LOG.info("PASS")
    LOG.info("CLOCK CYCLES TAKEN %d", cycles_used)
    LOG.info("CORE CYCLES %d INSTRUCTIONS RETIRED %d", cycles_used, retired)
    if GOLDEN_PATH is None:
        return
    matches = compare_bytes(
        bus.ram_bytes,
        load_golden(GOLDEN_PATH),
        actual_label=test_name,
        golden_label=GOLDEN_PATH.name,
    )
    check(
        matches,
        f"{test_name}: tohost PASS but RAM content doesn't match "
        f"{GOLDEN_PATH.name} -- see the diff above",
    )


@cocotb.test()
async def test_program(dut: Any) -> None:
    """Run the program until it writes its result to tohost."""
    test_name = os.environ.get("TEST_NAME", "?")
    LOG.info("running %s", test_name)

    clock = getattr(dut, SIM_CLOCK)
    sample_clock = getattr(dut, SIM_SAMPLE_CLOCK)
    cocotb.start_soon(Clock(clock, SIM_CLOCK_PERIOD_NS, unit="ns").start())
    for extra_name, extra_period in EXTRA_CLOCKS:
        cocotb.start_soon(
            Clock(getattr(dut, extra_name), extra_period, unit="ns").start()
        )
    uart_expected, uart_capture = start_uart(dut, test_name)
    uart_drive: Task[None] | None = None
    bus = RamBus(dut)
    cycles_used = 0
    retired = 0

    getattr(dut, SIM_RESET).value = SIM_RESET_ACTIVE
    await ClockCycles(clock, 5)
    getattr(dut, SIM_RESET).value = 1 - SIM_RESET_ACTIVE
    if test_name == "uart-echo":
        uart_drive = cocotb.start_soon(
            send_uart_message(dut.UART_RX, UART_ECHO_EXPECTED)
        )
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(sample_clock)
        cycles_used += 1
        retired += retired_now(dut)

        tohost = bus.tohost_write()
        if tohost is None:
            continue
        if tohost == TOHOST_PASS:
            await finish_pass(
                test_name,
                bus,
                (uart_expected, uart_capture, uart_drive),
                (cycles_used, retired),
            )
            return
        message = f"test signalled FAIL via RV32_FAIL(), code {tohost >> 1}"
        raise AssertionError(message)

    message = f"timed out after {TIMEOUT_CYCLES} cycles without a result"
    raise AssertionError(message)
