"""Operações de cocotb compartilhadas pelos testes da SDRAM."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.python.unittests.rtl.sdram_exec_image import SDRAM_BASE

CLOCK_PERIOD_NS = 10
MEMORY_CLOCK_PERIOD_NS = 7
RESET_CYCLES = 5
READ_CYCLES = 3


async def start_platform(dut: Any) -> None:
    """Start the two clocks and release the reset after a few cycles.

    Parameters
    ----------
    dut : Any
        Top level of the platform; cocotb gives its ports as attributes.
    """
    cocotb.start_soon(Clock(dut.CLK, CLOCK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(
        Clock(dut.CLK_MEM, MEMORY_CLOCK_PERIOD_NS, unit="ns").start()
    )
    dut.reset.value = 1
    await ClockCycles(dut.CLK, RESET_CYCLES)
    dut.reset.value = 0


async def read_word(dut: Any, address: int) -> int:
    """Read one word of the SDRAM chip model through the debug port.

    Parameters
    ----------
    dut : Any
        Top level of the platform; cocotb gives its ports as attributes.
    address : int
        Byte address of the word, inside the SDRAM.

    Returns
    -------
    int
        The word held by the chip model.
    """
    dut.DBG_WORD_ADDR.value = (address - SDRAM_BASE) // 4
    for _ in range(READ_CYCLES):
        await RisingEdge(dut.CLK_MEM)
    await Timer(1, unit="ns")
    return int(dut.DBG_WORD_DATA.value)
