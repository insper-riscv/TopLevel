"""The core runs a program that lives in the SDRAM, through the real instruction cache.

The platform simulation (core, instruction cache, SDRAM controller and chip model) starts with the
program already in the chip, as if the host had loaded it through the debug port. The BOOT_ROM only
jumps to 0x40000000. The program sums in a loop, calls a function several cache lines away, and
rewrites one of its own instructions and runs FENCE.I before it runs the new one. The results are
read from the chip model.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.python.unittests.rtl import sdram_exec_image as image

TIMEOUT_CYCLES = 600000


async def read_word(dut, address):
    dut.DBG_WORD_ADDR.value = (address - image.SDRAM_BASE) // 4
    for _ in range(3):
        await RisingEdge(dut.CLK_MEM)
    await Timer(1, unit="ns")
    return int(dut.DBG_WORD_DATA.value)


@cocotb.test()
async def test_images_match_the_generator(dut):
    """The hex files that the simulation loads are the ones the generator produces."""
    boot, words, _, _ = image.build()
    data = image.Path(image.__file__).parent / "data"
    assert (data / "sdram_exec_boot.hex").read_text() == "".join(f"{w & 0xFFFFFFFF:08x}\n" for w in boot)
    assert (data / "sdram_exec.hex").read_text() == "".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words)


@cocotb.test()
async def test_program_runs_from_the_sdram(dut):
    _, _, expected, _ = image.build()
    cocotb.start_soon(Clock(dut.CLK, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.CLK_MEM, 7, unit="ns").start())
    dut.reset.value = 1
    await ClockCycles(dut.CLK, 5)
    dut.reset.value = 0

    finished = image.FINISHED
    for _ in range(TIMEOUT_CYCLES // 200):
        await ClockCycles(dut.CLK, 200)
        if await read_word(dut, finished) == 1:
            break
    else:
        raise AssertionError("the program did not finish")

    for address, want in expected.items():
        got = await read_word(dut, address)
        assert got == want, f"[{address:#x}] = {got}, expected {want}"
