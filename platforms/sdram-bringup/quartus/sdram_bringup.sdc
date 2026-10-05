# Clocks of the SDRAM bring-up.
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# DRAM_CLK is the PLL output that goes to the chip. The chip's setup and hold are checked
# against it: the commands, addresses, masks and write data the controller launches, and the
# read data the chip drives. PROVISIONAL numbers (a usual 143 MHz SDR part, not yet read from
# the chip's datasheet): input setup 1.5 ns, input hold 0.8 ns, access time after the clock
# 5.4 ns, output hold 2.5 ns.
create_generated_clock -name DRAM_CLK_pin -source [get_pins {u_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports DRAM_CLK]

set dram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_RAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE DRAM_LDQM DRAM_UDQM DRAM_DQ[*]}]
set_output_delay -clock DRAM_CLK_pin -max 1.5 $dram_out
set_output_delay -clock DRAM_CLK_pin -min -0.8 $dram_out
set_input_delay  -clock DRAM_CLK_pin -max 5.4 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock DRAM_CLK_pin -min 2.5 [get_ports {DRAM_DQ[*]}]

# buttons, switches and LEDs are slow and asynchronous
set_false_path -from [get_ports {KEY[*] SW[*] FPGA_RESET_N}]
set_false_path -to   [get_ports {LEDR[*]}]

# The read data is launched by an edge of DRAM_CLK and captured by the controller clock one
# cycle later than the closest edge: the chip answers a time tAC after its clock edge, which is
# longer than the gap between the two clocks. (The controller samples it CAS latency + 2 clocks
# after the command.) Setup is checked against the second edge, hold against the first.
set_multicycle_path -setup -end -from [get_clocks DRAM_CLK_pin] -to [get_clocks {u_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold  -end -from [get_clocks DRAM_CLK_pin] -to [get_clocks {u_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 1
