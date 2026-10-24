"""The program that sdram_exec runs from the SDRAM, and the boot ROM that jumps to it.

A small two-pass assembler turns the listing below into words. `python -m
tests.python.unittests.rtl.sdram_exec_image` writes data/sdram_exec_boot.hex and
data/sdram_exec.hex (one 32-bit word per line), the images the simulation loads: the boot ROM into
the BOOT_ROM and the program into the SDRAM chip model at time zero, the way the host loads the chip
through the debug port before the core is released.
"""

from pathlib import Path

SDRAM_BASE = 0x40000000
DATA_BASE = SDRAM_BASE + 0x1000


def _r(op, rd, f3, rs1, rs2, f7):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(f3, rs1, rs2, imm):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23


def _b(f3, rs1, rs2, imm):
    return ((((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15)
            | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63)


def _j(rd, imm):
    return ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20)
            | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F)


def lui(rd, imm20):
    return (imm20 << 12) | (rd << 7) | 0x37


def addi(rd, rs1, imm):
    return _i(0x13, rd, 0, rs1, imm)


def add(rd, rs1, rs2):
    return _r(0x33, rd, 0, rs1, rs2, 0)


def sw(rs2, rs1, imm):
    return _s(2, rs1, rs2, imm)


def lw(rd, rs1, imm):
    return _i(0x03, rd, 2, rs1, imm)


def jalr(rd, rs1, imm):
    return _i(0x67, rd, 0, rs1, imm)


FENCE_I = 0x0000100F
NOP = addi(0, 0, 0)


def assemble(listing, base):
    """listing: words, ('label', name), or (fn, name) where fn(offset_to_name) gives the word."""
    labels, pc = {}, base
    for item in listing:
        if isinstance(item, tuple) and item[0] == "label":
            labels[item[1]] = pc
        else:
            pc += 4
    words, pc = [], base
    for item in listing:
        if isinstance(item, tuple) and item[0] == "label":
            continue
        if isinstance(item, tuple):
            fn, name = item
            words.append(fn(labels[name] - pc, labels[name]))
        else:
            words.append(item)
        pc += 4
    return words, labels


def build():
    patched = addi(9, 0, 2)                     # the instruction that replaces `addi x9, x0, 1`
    listing = [
        lui(1, SDRAM_BASE >> 12),               # x1 = code base
        lui(7, DATA_BASE >> 12),                # x7 = data base
        addi(2, 0, 20),
        addi(3, 0, 0),
        ("label", "loop"),
        add(3, 3, 2),                           # x3 = 20 + 19 + ... + 1 = 210
        addi(2, 2, -1),
        (lambda off, _: _b(1, 2, 0, off), "loop"),
        sw(3, 7, 0),                            # [data + 0] = 210
        (lambda off, _: _j(5, off), "far"),     # call a function several cache lines away
        sw(4, 7, 4),                            # [data + 4] = 77
        (lambda off, _: _j(5, off), "patch"),   # first run of the instruction that is rewritten
        sw(9, 7, 8),                            # [data + 8] = 1
        lui(10, patched >> 12),
        addi(10, 10, patched & 0xFFF),
        (lambda off, addr: sw(10, 1, addr - SDRAM_BASE), "patch"),   # rewrite it through the data path
        FENCE_I,
        (lambda off, _: _j(5, off), "patch"),
        sw(9, 7, 12),                           # [data + 12] = 2
        addi(12, 0, 1),
        sw(12, 7, 0x20),                        # [data + 0x20] = 1: finished
        ("label", "end"),
        (lambda off, _: _j(0, off), "end"),
    ] + [NOP] * 24 + [
        ("label", "far"),
        addi(4, 0, 77),
        jalr(0, 5, 0),
    ] + [NOP] * 12 + [
        ("label", "patch"),
        addi(9, 0, 1),
        jalr(0, 5, 0),
    ]
    words, labels = assemble(listing, SDRAM_BASE)
    boot = [NOP, lui(1, SDRAM_BASE >> 12), jalr(0, 1, 0)]   # the first word after reset is not executed
    expected = {DATA_BASE: 210, DATA_BASE + 4: 77, DATA_BASE + 8: 1, DATA_BASE + 12: 2, DATA_BASE + 0x20: 1}
    return boot, words, expected, labels


def write(directory):
    boot, words, _, _ = build()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "sdram_exec_boot.hex").write_text("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in boot))
    (directory / "sdram_exec.hex").write_text("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))


if __name__ == "__main__":
    write(Path(__file__).parent / "data")
