"""The program that sdram_display runs from the SDRAM.

It writes 1 to 15 to the display register (0xD0000000) with a pause
between the writes, then 0x123456, reads the register back into the
SDRAM and ends.

`python -m tests.python.unittests.rtl.display_image` writes
data/sdram_display.hex; the boot ROM is the one of sdram_exec.
"""

from pathlib import Path

from tests.python.unittests.rtl.sdram_exec_image import (
    DATA_BASE,
    FINISHED,
    SDRAM_BASE,
    addi,
    assemble,
    lui,
    lw,
    sw,
)

DISPLAY = 0xD0000000
FINAL = 0x123456
PAUSE = 40


def build():
    """Build the words of the program."""
    listing = [
        lui(5, DISPLAY >> 12),  # x5 = the display register
        lui(9, DATA_BASE >> 12),  # x9 = data base
        addi(6, 0, 0),
        addi(10, 0, 15),
        ("label", "next"),
        addi(6, 6, 1),
        sw(6, 5, 0),  # display = x6
        addi(7, 0, PAUSE),
        ("label", "pause"),
        addi(7, 7, -1),
        ("br", 1, 7, 0, "pause"),
        ("br", 1, 6, 10, "next"),
        lui(11, FINAL >> 12),
        addi(11, 11, FINAL & 0xFFF),
        sw(11, 5, 0),  # display = 0x123456
        lw(12, 5, 0),  # read it back
        sw(12, 9, 0),  # [data + 0] = what the register returned
        addi(13, 0, 1),
        sw(13, 9, FINISHED - DATA_BASE),  # finished
        ("label", "done"),
        ("br", 0, 0, 0, "done"),
    ]
    words, _ = assemble(listing, SDRAM_BASE)
    return words


def write(directory):
    """Write the hex image of the program into the directory."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "sdram_display.hex").write_text(
        "".join(f"{w & 0xFFFFFFFF:08x}\n" for w in build())
    )


if __name__ == "__main__":
    write(Path(__file__).parent / "data")
