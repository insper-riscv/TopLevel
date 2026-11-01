"""A program in the SDRAM drives the display register.

The program writes 0x000001 to 0x00000F to 0xD0000000 with a pause
between the writes, then 0x123456, and reads the register back into
the SDRAM. The testbench follows the register value on the platform
port and the segments of the six digits, and reads the read-back from
the chip model.
"""

from typing import Any

import cocotb
from cocotb.triggers import ClockCycles

from tests.python.unittests.rtl import display_image as image
from tests.python.unittests.rtl import sdram_exec_image as base
from tests.python.utils.checks import check
from tests.python.utils.sdram import read_word, start_platform

PATTERNS = [
    0b1000000,
    0b1111001,
    0b0100100,
    0b0110000,
    0b0011001,
    0b0010010,
    0b0000010,
    0b1111000,
    0b0000000,
    0b0010000,
    0b0001000,
    0b0000011,
    0b1000110,
    0b0100001,
    0b0000110,
    0b0001110,
]
POLL_CYCLES = 20
MAX_POLLS = 3000


def expected_hex(value: int) -> int:
    """Return the six 7-segment digits that display the value."""
    return sum(PATTERNS[(value >> (4 * n)) & 0xF] << (7 * n) for n in range(6))


@cocotb.test()
async def test_image_matches_the_generator(_dut: Any) -> None:
    """Check that the hex file is the one the generator produces."""
    data = base.Path(image.__file__).parent / "data"
    check(
        (data / "sdram_display.hex").read_text()
        == base.hex_text(image.build()),
        "sdram_display.hex differs from the generator",
    )


@cocotb.test()
async def test_the_program_drives_the_display(dut: Any) -> None:
    """Follow the display register until the program finishes."""
    await start_platform(dut)

    seen: list[int] = []
    for _ in range(MAX_POLLS):
        await ClockCycles(dut.CLK, POLL_CYCLES)
        value = int(dut.DISPLAY_VALUE.value)
        if not seen or seen[-1] != value:
            seen.append(value)
            check(
                int(dut.DISPLAY_HEX.value) == expected_hex(value),
                f"segments of {value:#x}",
            )
        if value == image.FINAL and await read_word(dut, base.FINISHED) == 1:
            break
    else:
        message = "the program did not finish"
        raise AssertionError(message)

    check(seen == [0, *range(1, 16), image.FINAL], str(seen))
    check(
        await read_word(dut, base.DATA_BASE) == image.FINAL,
        "a read of the register returns what was written",
    )
