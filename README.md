# TopLevel

The platforms of the RV32 SoC: what wires the core, the memories and the
peripherals into something that runs, and everything that depends on that wiring.
One job: describe and build a platform. The core, the memories, the peripherals,
the test programs and the certification live in other repositories of
[insper-riscv](https://github.com/insper-riscv).

## A platform: `platforms/<name>/`

Today there is one, `internal-mem`: a Cyclone V 5CEBA4F23 with BOOT_ROM, FLASH and
RAM inside the FPGA.

| Path | What |
| :--- | :--- |
| `platform.yaml` | the memory map (regions, reserved words, boot entry points, peripheral windows) and the list of every hand-written copy of it, checked by `riscv-tools check-memory-map` |
| `quartus/` | the Quartus project of the board: `core_fpga_test.vhd` (the hardware top), `.qpf`, `.qsf`, `.sdc`, the initial `.mif` images |
| `pll/` | the PLL IP (`pll.vhd`, `pll_0002.v`, 50 MHz in three phases), and `pll_sim.vhd`, the behavioral stand-in that simulates it |
| `rtl/` | the simulation top `rv32i3stage_core_sim_test` (plain VHDL arrays for memory, in place of the IPs), `clk_gen_3way`, `Blinky` |
| `runtime/` | what the platform adds to the toolchain's picolibc: `rv32im-fpga.specs` (the GCC specs file with the memory map), `boot_rom.S` and `boot_rom.ld`, `_exit.c`, `stdio.c`, and `spike_exit.S` (the Spike stand-in for the boot ROM's `rv32_wait_restart`) |
| `testbench/` | `test_c_program.py`, the cocotb testbench that watches the RAM write bus for a program's PASS/FAIL |
| `../../tests/python/` | per-entity cocotb tests of the platform's RTL (`clk_gen_3way`) and the catalog (`tests.json`) that drives them |
| `config.yaml`, `config.fpga-sim.yaml` | the `riscv-tools` configuration of the platform: toolchain, memory, Quartus, simulation (the simulation top, and the hardware top on Intel's `altera_mf` models) |

`docs/` explains the memory architecture, the boot, how a new program replaces the
old one, the runtime, how to program the board and how the hardware top is
simulated.

## How a project uses it

A project that runs tests on this platform (today, [Tests](https://github.com/insper-riscv/Tests))
extends the platform's configuration and adds only its own paths:

```yaml
# Tests/tools/riscv_build/config.yaml
extends: ../../../TopLevel/platforms/internal-mem/config.yaml
paths: {include_dir: ..., build_dir: build, c_dir: c, asm_dir: asm}
```

The paths inside the platform's `config.yaml` are written relative to that
project's root, with the repositories as siblings (`../Core`, `../Memory`,
`../TopLevel`), the same layout `RV32IM`'s submodules have. `sim.python_path`
puts `testbench/` on the search path of the simulation's test module.

## Use

```bash
git clone --recurse-submodules https://github.com/insper-riscv/TopLevel.git
git clone https://github.com/insper-riscv/Core.git     # next to it
git clone https://github.com/insper-riscv/Memory.git   # next to it
cd TopLevel
uv sync
make paths        # every path the configs and the .qsf list exists
make memory-map   # every copy of the memory map agrees with platform.yaml
make check        # GHDL builds the simulation top
make test         # per-entity cocotb tests of the RTL (clk_gen_3way)
```

The tools (GHDL, uv) come from the `infra-toolchain` image of
[Infra](https://github.com/insper-riscv/Infra); CI runs there. The hardware-top
simulation needs Quartus' `altera_mf` library and runs where Quartus is
installed (see `docs/SIMULACAO_TOPO_FPGA.md`).

## Not yet

- **The top is not generated**: `core_fpga_test.vhd` and the simulation top are
  written by hand and *verified* against `platform.yaml` (`make memory-map`). A
  generator comes after this restructuring.
- **Names**: the simulation top is still `rv32i3stage_core_sim_test`, a name from
  the 3-stage core it was written for (it instantiates the pipeline).

## Where this came from

`quartus/`, `pll/` and `rtl/` moved from `insper-riscv/RV32` (`tests/FPGA/core`,
`src/PLL`, `src/Blinky.vhd`, `src/clk_gen_3way.vhd`,
`src/rv32i3stage_core_sim_test.vhd`); `runtime/`, `testbench/`, the configs,
`platform.yaml` and `docs/` from `insper-riscv/Tests`, with their history and
authorship (`git filter-repo`). The generated Quartus simulation output, the old
`.tcl` JTAG helpers and the other leftovers of `tests/FPGA/core` were archived as
tags of RV32. The pre-move state is the tag `pre-refactor` in each repository.

## License

Apache License 2.0, see [LICENSE](LICENSE).
