"""The core runs a program that lives in the SDRAM.

The platform simulation (core, instruction cache, SDRAM controller and
chip model) starts with the program already in the chip, as if the host
had loaded it through the debug port. The BOOT_ROM only jumps to
0x40000000. The program sums in a loop, calls a function several cache
lines away, and rewrites one of its own instructions and runs FENCE.I
before it runs the new one. The results are read from the chip model.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles

from tests.python.unittests.rtl import sdram_exec_image as image
from tests.python.utils.checks import check
from tests.python.utils.sdram import read_word, start_platform

TIMEOUT_CYCLES = 600000
POLL_CYCLES = 200


@cocotb.test()
async def test_images_match_the_generator(_dut: Any) -> None:
    """Check that the simulated hex files are the generator's output."""
    boot, words, _, _ = image.build()
    data = image.Path(image.__file__).parent / "data"
    check(
        (data / "sdram_exec_boot.hex").read_text() == image.hex_text(boot),
        "sdram_exec_boot.hex differs from the generator",
    )
    check(
        (data / "sdram_exec.hex").read_text() == image.hex_text(words),
        "sdram_exec.hex differs from the generator",
    )


@cocotb.test()
async def test_program_runs_from_the_sdram(dut: Any) -> None:
    """Run the program and compare with the expected results."""
    _, _, expected, _ = image.build()
    await start_platform(dut)

    for _ in range(TIMEOUT_CYCLES // POLL_CYCLES):
        await ClockCycles(dut.CLK, POLL_CYCLES)
        if await read_word(dut, image.FINISHED) == 1:
            break
    else:
        message = "the program did not finish"
        raise AssertionError(message)

    for address, want in expected.items():
        got = await read_word(dut, address)
        check(got == want, f"[{address:#x}] = {got}, expected {want}")
