SHELL := /bin/bash
GHDL  := ghdl
STD   := --std=08
WDIR  := build/ghdl
P     := platforms/internal-mem
PS    := platforms/sdram
PF    := platforms/sdram-flash

# The UART of Peripherals is part of the simulation top.
UART_VHDL := ../Peripherals/UART/vendor/opencores_uart2bus/uart2BusTop_pkg.vhd \
             ../Peripherals/UART/vendor/opencores_uart2bus/baudGen.vhd \
             ../Peripherals/UART/vendor/opencores_uart2bus/uartRx.vhd \
             ../Peripherals/UART/vendor/opencores_uart2bus/uartTx.vhd \
             ../Peripherals/UART/vendor/opencores_uart2bus/uartTop.vhd \
             ../Peripherals/UART/uart.vhd

# The simulation top (rv32i3stage_core_sim_test) with the core and the simulation
# memories/peripherals: Core, Common-Components, Memory and Peripherals are cloned next to this repository.
SIM_VHDL := $(shell find ../Common-Components/src ../Core/src ../Memory/sim -name '*.vhd' -not -path '../Core/src/common/*' | sort) \
            $(UART_VHDL) $(P)/rtl/clk_gen_3way.vhd $(P)/rtl/rv32i3stage_core_sim_test.vhd

# The SDRAM platform's simulation top adds the SDRAM (bridge, controller, chip model) of Memory.
SDRAM_VHDL := $(shell find ../Memory/external/sdram ../Memory/external/bus ../Memory/external/cache/icache.vhd -name '*.vhd' -not -path '*/hw/*' | sort) $(PS)/rtl/rv32im_sdram_sim_test.vhd

# The platform with the FLASH behind the caches adds the data cache, the FLASH chip, its arbiter and the region router.
FLASH_VHDL := ../Memory/external/cache/dcache.vhd ../Memory/external/cache/flash_chip.vhd ../Memory/external/cache/flash_arbiter.vhd ../Memory/external/cache/mem_region_router.vhd $(PF)/rtl/rv32im_sdram_flash_sim_test.vhd

.PHONY: check memory-map paths test all clean

all: paths memory-map check test

# GHDL analyzes and elaborates the simulation top. The ROM models open their image
# when they are elaborated (default.hex, from their generic), so a one-word one is
# put in the work directory.
check:
	@mkdir -p $(WDIR)
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(riscv-tools vhdl-sort $(SIM_VHDL))
	@printf '00000000\n' > $(WDIR)/default.hex
	@cd $(WDIR) && $(GHDL) -e $(STD) --workdir=. rv32i3stage_core_sim_test
	@echo "the simulation top builds"
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(riscv-tools vhdl-sort $(SIM_VHDL) $(SDRAM_VHDL))
	@cd $(WDIR) && $(GHDL) -e $(STD) --workdir=. rv32im_sdram_sim_test
	@echo "the SDRAM platform's simulation top builds"
	@$(GHDL) -a $(STD) --work=work --workdir=$(WDIR) $$(riscv-tools vhdl-sort $(SIM_VHDL) $(SDRAM_VHDL) $(FLASH_VHDL))
	@cd $(WDIR) && $(GHDL) -e $(STD) --workdir=. rv32im_sdram_flash_sim_test
	@echo "the simulation top of the platform with the FLASH behind the caches builds"

# Every copy of the memory map (config, linker flags, boot ROM, runtime, the core's
# VHDL, the Quartus IPs) agrees with platform.yaml.
memory-map:
	riscv-tools --root . check-memory-map --platform $(P)/platform.yaml
	riscv-tools --root . check-memory-map --platform $(PS)/platform.yaml
	riscv-tools --root . check-memory-map --platform $(PF)/platform.yaml

# Per-entity cocotb tests of the RTL of the platform (`make test TEST=clk_gen_3way`).
test:
	uv run python tests/python/runner.py $(TEST)

# Every path the configuration lists exists.
paths:
	riscv-tools --root . check-paths --manifest paths.yaml

clean:
	rm -rf build
