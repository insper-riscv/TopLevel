# TopLevel

🌐 [Português](README.md) · [English](README.en.md)

Platforms of the RISC-V RV32 SoC: what wires the core, the memories, and the peripherals into something that runs, and everything that depends on that wiring. The repository describes and builds a platform. The core, the memories, the peripherals, the test programs, and the certification live in other repositories of the [insper-riscv](https://github.com/insper-riscv) organization.

## 1. Documentation

- [AUTHORS.en.md](AUTHORS.en.md): authors with commits in the repository, with name and GitHub account.
- [CONTRIBUTING.en.md](CONTRIBUTING.en.md): mandatory contribution rules, VHDL-2008, C23, and Python standards, documentation rules, and verification before opening a Pull Request.
- [CITATION.cff](CITATION.cff): software citation metadata.
- [docs/MEMORY_ARCHITECTURE.md](docs/MEMORY_ARCHITECTURE.md): BOOT_ROM, FLASH, and RAM memory architecture.
- [docs/CRT0_BOOT_REFERENCE.md](docs/CRT0_BOOT_REFERENCE.md): boot state, picolibc `crt0`, and `boot_rom.S`.
- [docs/PROGRAM_UPDATE_HANDOFF.md](docs/PROGRAM_UPDATE_HANDOFF.md): replacing one program with another and boot handoff between tests.
- [docs/RUNTIME.md](docs/RUNTIME.md): C runtime, platform file, `stdout`, and Spike.
- [docs/HARDWARE_PROGRAMMING.md](docs/HARDWARE_PROGRAMMING.md): board programming.
- [docs/SIMULACAO_TOPO_FPGA.md](docs/SIMULACAO_TOPO_FPGA.md): hardware-top simulation with the real Quartus memories.

## 2. Platform in `platforms/<name>/`

The existing platform is `internal-mem`: a Cyclone V 5CEBA4F23 with BOOT_ROM, FLASH, and RAM inside the FPGA.

| Path | Contents |
| :--- | :--- |
| `platform.yaml` | Memory map (regions, reserved words, boot entry points, and peripheral windows) and the list of every hand-written copy of it, checked by `riscv-tools check-memory-map` |
| `quartus/` | Quartus project of the board: `core_fpga_test.vhd` (hardware top), `.qpf`, `.qsf`, `.sdc`, and the initial `.mif` images |
| `pll/` | PLL IP (`pll.vhd`, `pll_0002.v`, 50 MHz in three phases) and `pll_sim.vhd`, the behavioral stand-in that simulates it |
| `rtl/` | Simulation top `rv32i3stage_core_sim_test` (plain VHDL arrays in place of the memory IPs), `clk_gen_3way`, and `Blinky` |
| `runtime/` | What the platform adds to the toolchain picolibc: `rv32im-fpga.specs` (GCC specs file with the memory map), `boot_rom.S`, `boot_rom.ld`, `_exit.c`, `stdio.c`, and `spike_exit.S` (Spike stand-in for the boot ROM `rv32_wait_restart`) |
| `testbench/` | `test_c_program.py`, the cocotb testbench that watches the RAM write bus for a program's PASS/FAIL |
| `../../tests/python/` | Per-entity cocotb tests of the platform RTL (`clk_gen_3way`) and the catalog (`tests.json`) that drives them |
| `config.yaml`, `config.fpga-sim.yaml` | `riscv-tools` configuration of the platform: toolchain, memory, Quartus, and simulation (of the simulation top and of the hardware top on Intel's `altera_mf` models) |

## 3. Use by a Project

A project that runs tests on this platform, today [Tests](https://github.com/insper-riscv/Tests), extends the platform configuration and adds only its own paths:

```yaml
# Tests/tools/riscv_build/config.yaml
extends: ../../../TopLevel/platforms/internal-mem/config.yaml
paths: {include_dir: ..., build_dir: build, c_dir: c, asm_dir: asm}
```

The paths inside the platform `config.yaml` are relative to the consuming project root, with the repositories side by side (`../Core`, `../Memory`, `../TopLevel`), the same layout as the `RV32IM` submodules. The `sim.python_path` field puts `testbench/` on the search path of the simulation test module.

## 4. Verification and Running

```bash
git clone --recurse-submodules https://github.com/insper-riscv/TopLevel.git
git clone https://github.com/insper-riscv/Core.git     # next to it
git clone https://github.com/insper-riscv/Memory.git   # next to it
cd TopLevel
uv sync

make paths        # Existence of every path listed in the configs and the .qsf
make memory-map   # Every copy of the memory map agrees with platform.yaml
make check        # GHDL builds the simulation top
make test         # Per-entity cocotb tests of the RTL (clk_gen_3way)
```

The tools (GHDL and uv) come from the `ci-vhdl` image of the [Infra](https://github.com/insper-riscv/Infra) repository, where continuous integration runs. The hardware-top simulation needs Quartus' `altera_mf` library and runs where Quartus is installed, as described in [docs/SIMULACAO_TOPO_FPGA.md](docs/SIMULACAO_TOPO_FPGA.md).

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](LICENSE).
