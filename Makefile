SHELL := /bin/bash
GHDL  := ghdl
STD   := --std=08
WDIR  := build/ghdl
P     := platforms/internal-mem

# The simulation top (rv32i3stage_core_sim_test) with the core and the simulation
# memories: Core and Memory are cloned next to this repository.
SIM_VHDL := $(shell find ../Core/common ../Core/I ../Core/M ../Core/cores ../Memory/sim -name '*.vhd' | sort) \
            $(P)/rtl/clk_gen_3way.vhd $(P)/rtl/rv32i3stage_core_sim_test.vhd

.PHONY: check memory-map paths test all clean

all: paths memory-map check test

# GHDL analyzes and elaborates the simulation top. The ROM models open their image
# when they are elaborated (default.hex, from their generic), so a one-word one is
# put in the work directory.
check:
	@mkdir -p $(WDIR)
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(uv run riscv-tools vhdl-sort $(SIM_VHDL))
	@printf '00000000\n' > $(WDIR)/default.hex
	@cd $(WDIR) && $(GHDL) -e $(STD) --workdir=. rv32i3stage_core_sim_test
	@echo "the simulation top builds"

# Every copy of the memory map (config, linker flags, boot ROM, runtime, the core's
# VHDL, the Quartus IPs) agrees with platform.yaml.
memory-map:
	uv run riscv-tools --root . check-memory-map --platform $(P)/platform.yaml

# Per-entity cocotb tests of the RTL of the platform (`make test TEST=clk_gen_3way`).
test:
	uv run python tests/python/runner.py $(TEST)

# Every path the configuration lists exists.
paths:
	uv run riscv-tools --root . check-paths --manifest paths.yaml

clean:
	rm -rf build
