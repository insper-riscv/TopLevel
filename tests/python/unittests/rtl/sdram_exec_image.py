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
    assert -2048 <= imm < 2048, f"store offset {imm} does not fit"
    return _s(2, rs1, rs2, imm)


def slli(rd, rs1, shamt):
    return _i(0x13, rd, 1, rs1, shamt)


def beq(rs1, rs2, imm):
    return _b(0, rs1, rs2, imm)


def bne(rs1, rs2, imm):
    return _b(1, rs1, rs2, imm)


def fence_i(rd=0, rs1=0, imm=0):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x0F


def lw(rd, rs1, imm):
    return _i(0x03, rd, 2, rs1, imm)


def jalr(rd, rs1, imm):
    return _i(0x67, rd, 0, rs1, imm)


def csrrw(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73


def csrrs(rd, csr, rs1):
    return (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73


MTVEC, MEPC, MCAUSE, MTVAL = 0x305, 0x341, 0x342, 0x343
MRET = 0x30200073
HANDLER_OFFSET = 0x600
FENCE_I = 0x0000100F
NOP = addi(0, 0, 0)


def assemble(listing, base):
    """listing: words, ('label', name), or (fn, name) where fn(offset_to_name) gives the word."""
    labels, pc = {}, base
    for item in listing:
        if isinstance(item, tuple) and item[0] == "label":
            labels[item[1]] = pc
        elif isinstance(item, tuple) and item[0] == "org":
            assert item[1] >= pc, f"org {item[1]:#x} is behind {pc:#x}"
            pc = item[1]
        else:
            pc += 4
    words, pc = [], base
    for item in listing:
        if isinstance(item, tuple) and item[0] == "label":
            continue
        if isinstance(item, tuple) and item[0] == "org":
            words += [NOP] * ((item[1] - pc) // 4)
            pc = item[1]
            continue
        if isinstance(item, tuple):
            fn, name = item
            words.append(fn(labels[name] - pc, labels[name]))
        else:
            words.append(item)
        pc += 4
    return words, labels


FINISHED = DATA_BASE + 0x40


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

        # --- code in distant lines that map to the same cache line: a, b, a, b, a ---
        addi(20, 0, 0),
        (lambda off, _: _j(5, off), "conf_a"),
        add(20, 20, 4),
        (lambda off, _: _j(5, off), "conf_b"),
        add(20, 20, 4),
        (lambda off, _: _j(5, off), "conf_a"),
        add(20, 20, 4),
        (lambda off, _: _j(5, off), "conf_b"),
        add(20, 20, 4),
        (lambda off, _: _j(5, off), "conf_a"),
        add(20, 20, 4),
        sw(20, 7, 0x24),                        # [data + 0x24] = 3 + 5 + 3 + 5 + 3 = 19

        # --- the store right before FENCE.I, with nothing in between ---
        lui(10, patched >> 12),
        addi(10, 10, patched & 0xFFF),
        (lambda off, _: _j(5, off), "patch2"),  # x9 = 1, the line is cached
        (lambda off, addr: sw(10, 1, addr - SDRAM_BASE), "patch2"),
        FENCE_I,
        (lambda off, _: _j(5, off), "patch2"),
        sw(9, 7, 0x28),                         # [data + 0x28] = 2

        # --- two stores, then FENCE.I: two instructions of the same line change ---
        lui(10, addi(9, 0, 7) >> 12),
        addi(10, 10, addi(9, 0, 7) & 0xFFF),
        lui(11, addi(13, 0, 8) >> 12),
        addi(11, 11, addi(13, 0, 8) & 0xFFF),
        (lambda off, addr: sw(10, 1, addr - SDRAM_BASE), "patch3"),
        (lambda off, addr: sw(11, 1, addr - SDRAM_BASE + 4), "patch3"),
        fence_i(),
        (lambda off, _: _j(5, off), "patch3"),
        sw(9, 7, 0x2C),                         # [data + 0x2C] = 7
        sw(13, 7, 0x30),                        # [data + 0x30] = 8

        # --- FENCE.I in a loop: the target changes at every turn ---
        addi(14, 0, 1),
        addi(16, 0, 0),
        addi(17, 0, 0x493),                     # addi x9, x0, 0
        addi(18, 0, 4),
        ("label", "fl_loop"),
        slli(15, 14, 20),
        add(10, 17, 15),                        # addi x9, x0, <turn>
        (lambda off, addr: sw(10, 1, addr - SDRAM_BASE), "patch4"),
        FENCE_I,
        (lambda off, _: _j(5, off), "patch4"),
        add(16, 16, 9),
        addi(14, 14, 1),
        (lambda off, _: _b(1, 14, 18, off), "fl_loop"),
        sw(16, 7, 0x34),                        # [data + 0x34] = 1 + 2 + 3

        # --- FENCE.I with rd and rs1 other than zero (the encodings the compliance tests use) ---
        lui(10, patched >> 12),
        addi(10, 10, patched & 0xFFF),
        (lambda off, addr: sw(10, 1, addr - SDRAM_BASE), "patch5"),
        fence_i(rd=3, rs1=2),
        (lambda off, _: _j(5, off), "patch5"),
        sw(9, 7, 0x38),                         # [data + 0x38] = 2

        # --- a trap right behind a load of the SDRAM that is still in flight ---
        lui(30, SDRAM_BASE >> 12),
        addi(30, 30, HANDLER_OFFSET),
        csrrw(0, MTVEC, 30),                    # mtvec = the handler
        lw(20, 7, 0),                           # the SDRAM load keeps the pipeline waiting
        lw(21, 7, 1),                           # misaligned load right behind it: cause 4
        addi(25, 0, 5),                         # runs after the handler returns
        sw(20, 7, 0x4C),                        # [data + 0x4C] = 210: the first load finished
        sw(25, 7, 0x50),                        # [data + 0x50] = 5
        FENCE_I,                                # push the results out of a write-back data cache
        addi(12, 0, 1),
        sw(12, 7, 0x40),                        # [data + 0x40] = 1: finished
        FENCE_I,
        ("label", "end"),
        (lambda off, _: _j(0, off), "end"),
        ("org", SDRAM_BASE + 0x300),
        ("label", "far"),
        addi(4, 0, 77),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x380),
        ("label", "patch"),
        addi(9, 0, 1),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x400),
        ("label", "patch2"),
        addi(9, 0, 1),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x480),
        ("label", "patch3"),
        addi(9, 0, 1),
        addi(13, 0, 1),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x500),
        ("label", "patch4"),
        addi(9, 0, 0),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x580),
        ("label", "patch5"),
        addi(9, 0, 1),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + HANDLER_OFFSET),
        ("label", "handler"),
        csrrs(22, MCAUSE, 0),
        csrrs(23, MTVAL, 0),
        csrrs(24, MEPC, 0),
        sw(22, 7, 0x44),                        # [data + 0x44] = 4
        sw(23, 7, 0x48),                        # [data + 0x48] = data + 1
        addi(24, 24, 4),
        csrrw(0, MEPC, 24),
        MRET,
        # same index, different tag: 0x1000 apart
        ("org", SDRAM_BASE + 0x900),
        ("label", "conf_a"),
        addi(4, 0, 3),
        jalr(0, 5, 0),
        ("org", SDRAM_BASE + 0x1900),
        ("label", "conf_b"),
        addi(4, 0, 5),
        jalr(0, 5, 0),
    ]
    words, labels = assemble(listing, SDRAM_BASE)
    boot = [NOP, lui(1, SDRAM_BASE >> 12), jalr(0, 1, 0)]   # the first word after reset is not executed
    expected = {
        DATA_BASE: 210, DATA_BASE + 4: 77, DATA_BASE + 8: 1, DATA_BASE + 12: 2,
        DATA_BASE + 0x24: 19, DATA_BASE + 0x28: 2, DATA_BASE + 0x2C: 7, DATA_BASE + 0x30: 8,
        DATA_BASE + 0x34: 6, DATA_BASE + 0x38: 2, FINISHED: 1,
        DATA_BASE + 0x44: 4, DATA_BASE + 0x48: DATA_BASE + 1, DATA_BASE + 0x4C: 210, DATA_BASE + 0x50: 5,
    }
    return boot, words, expected, labels


def write(directory):
    boot, words, _, _ = build()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "sdram_exec_boot.hex").write_text("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in boot))
    (directory / "sdram_exec.hex").write_text("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))


if __name__ == "__main__":
    write(Path(__file__).parent / "data")
