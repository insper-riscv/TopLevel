# Clocks of the SDRAM platform.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# DRAM_CLK is the PLL output that goes to the chip: its setup and hold are checked against it. The chip's
# numbers are PROVISIONAL (a usual 143 MHz SDR part, not read from its datasheet yet): input setup 1.5 ns,
# input hold 0.8 ns, access time after the clock 5.4 ns, output hold 2.5 ns.
create_generated_clock -name DRAM_CLK_pin -source [get_pins {pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports DRAM_CLK]

set dram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_RAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
set_output_delay -clock DRAM_CLK_pin -max 1.5 $dram_out
set_output_delay -clock DRAM_CLK_pin -min -0.8 $dram_out
set_input_delay  -clock DRAM_CLK_pin -max 5.4 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock DRAM_CLK_pin -min 2.5 [get_ports {DRAM_DQ[*]}]

# The read data is launched by an edge of DRAM_CLK and captured by the controller clock one cycle later than
# the closest edge: the chip answers a time tAC after its clock edge, longer than the gap between the clocks.
set clk_mem {pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set_multicycle_path -setup -end -from [get_clocks DRAM_CLK_pin] -to [get_clocks $clk_mem] 2
set_multicycle_path -hold  -end -from [get_clocks DRAM_CLK_pin] -to [get_clocks $clk_mem] 1

# The core clocks and the controller clock meet only in the bridge: two flip-flop synchronizers for the toggles
# and the init flag, and request and read-data buses that hold from the edge a toggle flips until it is answered.
# Nothing between the two sets of clocks is timed as a synchronous path: every crossing is bounded by a delay
# shorter than the synchronizers' latency (no hold check).
set clk_if    {pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set clk_core  {pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
set mem_clocks  [get_clocks $clk_mem]
set core_clocks [get_clocks [list $clk_if $clk_core]]
set_max_delay -from $mem_clocks  -to $core_clocks 10
set_max_delay -from $core_clocks -to $mem_clocks  10
set_min_delay -from $mem_clocks  -to $core_clocks -10
set_min_delay -from $core_clocks -to $mem_clocks  -10

# the reset button and the LEDs are slow and asynchronous
set_false_path -from [get_ports {FPGA_RESET_N}]
set_false_path -to   [get_ports {LEDR[*]}]
