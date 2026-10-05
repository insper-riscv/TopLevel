library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.rv32i_ctrl_consts.all;

-- Simulation top of the SDRAM platform: the core, the BOOT_ROM and FLASH of internal-mem (VHDL
-- arrays) and the SDRAM (bridge, arbiter, controller and chip model of the Memory repository) on
-- its own 143 MHz clock. The SDRAM is the RAM: there is no other data memory.
--
-- CLK is the base clock of the core (a clock generator divides it by three, as in internal-mem).
-- CLK_MEM is the SDRAM clock, driven by the testbench with no fixed relation to CLK, as on the
-- board. DBG_WORD_ADDR and DBG_WORD_DATA read a word straight out of the chip model, which is how
-- the testbench compares the content of the memory with a golden.
entity rv32im_sdram_sim_test is
	generic (
	  BOOT_ROM_FILE : string := "default.hex";
	  ROM_FILE : string := "default.hex";
	  boot_rom_addr_width : natural := 9;
	  rom_addr_width : natural := 9;
	  ram_addr_width : natural := 9
  	);
	port (
    	CLK     : in  std_logic;
    	CLK_MEM : in  std_logic;
		reset   : in  std_logic := '0';
		DBG_WORD_ADDR : in  std_logic_vector(23 downto 0) := (others => '0');
		DBG_WORD_DATA : out std_logic_vector(31 downto 0)
  	);
end entity;

architecture behaviour of rv32im_sdram_sim_test is

	signal if_addr : std_logic_vector(31 downto 0);
	signal if_rden : std_logic;
	signal boot_rom_data : std_logic_vector(31 downto 0);
	signal flash_data : std_logic_vector(31 downto 0);

	signal flash_addr2 : std_logic_vector(31 downto 0);
	signal flash_rden2 : std_logic;
	signal flash_data2 : std_logic_vector(31 downto 0);

	signal ram_addr : std_logic_vector(31 downto 0);
	signal ram_wdata : std_logic_vector(31 downto 0);
	signal ram_rdata : std_logic_vector(31 downto 0) := (others => '0');   -- no RAM inside the FPGA
	signal ram_en : std_logic;
	signal ram_wren : std_logic;
	signal ram_rden : std_logic;
	signal ram_byteena : std_logic_vector(3 downto 0);

	signal sdram_addr    : std_logic_vector(31 downto 0);
	signal sdram_wdata   : std_logic_vector(31 downto 0);
	signal sdram_rdata   : std_logic_vector(31 downto 0);
	signal sdram_byteena : std_logic_vector(3 downto 0);
	signal sdram_rden    : std_logic;
	signal sdram_wren    : std_logic;
	signal sdram_ready   : std_logic;
	signal mem_advance   : std_logic;

	signal pll_clk_if     : std_logic;
	signal pll_clk_idexmem: std_logic;
	signal pll_clk_wb     : std_logic;

	signal dbg_refreshes  : std_logic_vector(31 downto 0);
	signal dbg_init_ok    : std_logic;
	signal sdram_init     : std_logic;

begin

	pll_inst : entity work.clk_gen_3way
    port map (
      clk_in   => CLK,
      reset    => reset,
      clk0 => pll_clk_if,
      clk1 => pll_clk_idexmem,
      clk2 => pll_clk_wb
    );

	CORE : entity work.rv32im_pipeline_core
		port map (
			clk          => pll_clk_idexmem,
			reset 		=> reset,

			if_addr       => if_addr,
			if_rden       => if_rden,
			boot_rom_data => boot_rom_data,
			flash_data    => flash_data,

			flash_addr2 => flash_addr2,
			flash_rden2 => flash_rden2,
			flash_data2 => flash_data2,

			ram_addr    => ram_addr,
			ram_wdata   => ram_wdata,
			ram_rdata   => ram_rdata,
			ram_en      => ram_en,
			ram_wren    => ram_wren,
			ram_rden    => ram_rden,
			ram_byteena => ram_byteena,

			sdram_addr    => sdram_addr,
			sdram_wdata   => sdram_wdata,
			sdram_byteena => sdram_byteena,
			sdram_rden    => sdram_rden,
			sdram_wren    => sdram_wren,
			sdram_rdata   => sdram_rdata,
			sdram_ready   => sdram_ready,
			mem_advance   => mem_advance
	);

	-- the SDRAM and its chip model; the debug ports of the model stay unused here
	SDRAM : entity work.sdram_system
		port map (
			clk_mem => CLK_MEM, clk_cpu => pll_clk_idexmem,
			rst_mem => reset,   rst_cpu => reset,
			addr => sdram_addr, wdata => sdram_wdata, byteena => sdram_byteena,
			rden => sdram_rden, wren => sdram_wren, mem_advance => mem_advance,
			ready => sdram_ready, rdata => sdram_rdata,
			init_done => sdram_init,
			dbg_word_addr => DBG_WORD_ADDR, dbg_word_data => DBG_WORD_DATA,
			dbg_flip => '0', dbg_flip_addr => (others => '0'), dbg_flip_bit => (others => '0'),
			dbg_refreshes => dbg_refreshes, dbg_init_ok => dbg_init_ok
	);

	BOOT_ROM : entity work.ROM_simulation
		generic map (ROM_FILE => BOOT_ROM_FILE, memoryAddrWidth => boot_rom_addr_width)
		port map (
			addr 	=> if_addr(31 downto 2),
			clk 	=> pll_clk_if,
			re 		=> if_rden,
			data	=> boot_rom_data
	);

	FLASH : entity work.ROM_simulation
		generic map (ROM_FILE => ROM_FILE, memoryAddrWidth => rom_addr_width)
		port map (
			addr 	=> if_addr(31 downto 2),
			clk 	=> pll_clk_if,
			re 		=> if_rden,
			data	=> flash_data,

			addr2 	=> flash_addr2(31 downto 2),
			clk2 	=> pll_clk_idexmem,
			re2 	=> flash_rden2,
			data2	=> flash_data2
	);

end architecture;
