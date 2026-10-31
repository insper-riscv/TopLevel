"""A program in the SDRAM drives the display register through the interconnect.

The program writes 0x000001 to 0x00000F to 0xD0000000 with a pause between the writes, then 0x123456,
and reads the register back into the SDRAM. The testbench follows the register value on the platform
port and the segments of the six digits, and reads the read-back from the chip model.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.python.unittests.rtl import display_image as image
from tests.python.unittests.rtl import sdram_exec_image as base

PATTERNS = [
    0b1000000, 0b1111001, 0b0100100, 0b0110000, 0b0011001, 0b0010010, 0b0000010, 0b1111000,
    0b0000000, 0b0010000, 0b0001000, 0b0000011, 0b1000110, 0b0100001, 0b0000110, 0b0001110,
]


def expected_hex(value):
    return sum(PATTERNS[(value >> (4 * n)) & 0xF] << (7 * n) for n in range(6))


async def read_word(dut, address):
    dut.DBG_WORD_ADDR.value = (address - base.SDRAM_BASE) // 4
    for _ in range(3):
        await RisingEdge(dut.CLK_MEM)
    await Timer(1, unit="ns")
    return int(dut.DBG_WORD_DATA.value)


@cocotb.test()
async def test_image_matches_the_generator(dut):
    data = base.Path(image.__file__).parent / "data"
    assert (data / "sdram_display.hex").read_text() == "".join(f"{w & 0xFFFFFFFF:08x}\n" for w in image.build())


@cocotb.test()
async def test_the_program_drives_the_display(dut):
    cocotb.start_soon(Clock(dut.CLK, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.CLK_MEM, 7, unit="ns").start())
    dut.reset.value = 1
    await ClockCycles(dut.CLK, 5)
    dut.reset.value = 0

    seen = []
    for _ in range(3000):
        await ClockCycles(dut.CLK, 20)
        value = int(dut.DISPLAY_VALUE.value)
        if not seen or seen[-1] != value:
            seen.append(value)
            assert int(dut.DISPLAY_HEX.value) == expected_hex(value), f"segments of {value:#x}"
        if value == image.FINAL and await read_word(dut, base.FINISHED) == 1:
            break
    else:
        raise AssertionError("the program did not finish")

    assert seen == [0] + list(range(1, 16)) + [image.FINAL], seen
    assert await read_word(dut, base.DATA_BASE) == image.FINAL, "a read of the register returns what was written"
