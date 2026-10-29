library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Simulation top of the SDRAM platform: the core, the BOOT_ROM and FLASH of internal-mem (VHDL
-- arrays) and the SDRAM (bridge, arbiter, controller and chip model of the Memory repository) on
-- its own 143 MHz clock. The SDRAM is the RAM: there is no other data memory.
--
-- CLK is the base clock of the core (a clock generator divides it by three, as in internal-mem).
-- CLK_MEM is the SDRAM clock, driven by the testbench with no fixed relation to CLK, as on the
-- board. DBG_WORD_ADDR and DBG_WORD_DATA read a word straight out of the chip model, which is how
-- the testbench compares the content of the memory with a golden.
--
-- The core's external port goes through the AXI4 interconnect of the Memory repository (the data
-- cache and the router; docs/DCACHE_AXI.md there): bit 31 = 0 is the SDRAM, bit 31 = 1 a peripheral
-- window, with the JTAG UART at 0xC0000000 and the cache's control at 0xF0000000. UART_* stand for the
-- Virtual JTAG instance of the UART (see jtag_uart); the testbench drives them to read what the
-- program prints.
entity rv32im_sdram_axi_sim_test is
	generic (
	  BOOT_ROM_FILE : string := "default.hex";
	  ROM_FILE : string := "default.hex";
	  boot_rom_addr_width : natural := 9;
	  rom_addr_width : natural := 9;
	  ram_addr_width : natural := 9;
	  -- Zicsr no core (instrucoes CSR reais); false mantem o comportamento de NOP.
	  HAS_ZICSR : boolean := false;
	  -- Zifencei no core (FENCE.I invalida a cache de instrucoes); false mantem o NOP.
	  HAS_ZIFENCEI : boolean := false;
	  -- Acesso desalinhado a memoria principal executado em hardware (Zicclsm).
	  HAS_ZICCLSM : boolean := true;
	  -- cache de dados write-through (true) ou write-back (false); com write-back a FENCE.I pede o flush
	  WRITE_THROUGH : boolean := true;
	  -- Imagem de programa gravada na SDRAM no tempo zero (ver rv32im_sdram_sim_test)
	  SDRAM_FILE : string := ""
  	);
	port (
    	CLK     : in  std_logic;
    	CLK_MEM : in  std_logic;
		reset   : in  std_logic := '0';
		DBG_WORD_ADDR : in  std_logic_vector(23 downto 0) := (others => '0');
		DBG_WORD_DATA : out std_logic_vector(31 downto 0);
		UART_TCK       : in  std_logic := '0';
		UART_TDI       : in  std_logic := '0';
		UART_TDO       : out std_logic;
		UART_IR_IN     : in  std_logic_vector(1 downto 0) := "00";
		UART_STATE_CDR : in  std_logic := '0';
		UART_STATE_SDR : in  std_logic := '0';
		UART_STATE_UDR : in  std_logic := '0';
		UART_STATE_UIR : in  std_logic := '0'
  	);
end entity;

architecture behaviour of rv32im_sdram_axi_sim_test is

	-- Exceção sinalizada pelo core sem Zicsr (um ciclo em '1'); com Zicsr fica em '0'.
	signal core_trap       : std_logic;
	-- Causa da exceção sinalizada, no formato do mcause.
	signal core_trap_cause : std_logic_vector(31 downto 0);
	-- PC da instrução que gerou a exceção sinalizada.
	signal core_trap_pc    : std_logic_vector(31 downto 0);

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

	-- behind the interconnect: the SDRAM, and the peripheral slots
	signal m_addr    : std_logic_vector(31 downto 0);
	signal m_wdata   : std_logic_vector(31 downto 0);
	signal m_rdata   : std_logic_vector(31 downto 0);
	signal m_byteena : std_logic_vector(3 downto 0);
	signal m_rden    : std_logic;
	signal m_wren    : std_logic;
	signal m_ready   : std_logic;
	signal m_advance : std_logic;
	signal awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready, wlast, rlast : std_logic;
	signal awaddr, wdata_a, araddr, rdata_a : std_logic_vector(31 downto 0);
	signal awlen, arlen : std_logic_vector(7 downto 0);
	signal awsize, arsize : std_logic_vector(2 downto 0);
	signal awburst, arburst : std_logic_vector(1 downto 0);
	signal wstrb : std_logic_vector(3 downto 0);
	signal bresp, rresp : std_logic_vector(1 downto 0);
	signal m_line : std_logic;
	signal m_wdx, m_rdx : std_logic_vector(95 downto 0);
	signal m_bex : std_logic_vector(11 downto 0);
	signal p_addr    : std_logic_vector(7 downto 0);
	signal p_wdata   : std_logic_vector(31 downto 0);
	signal p_byteena : std_logic_vector(3 downto 0);
	signal p_we, p_re : std_logic_vector(7 downto 0);
	signal p_rdata   : std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');

	signal pll_clk_if     : std_logic;
	signal pll_clk_idexmem: std_logic;
	signal pll_clk_wb     : std_logic;

	signal dbg_refreshes  : std_logic_vector(31 downto 0);
	signal dbg_init_ok    : std_logic;
	signal sdram_init     : std_logic;

	-- Busca de instrucao em SDRAM: cache de instrucoes no clock do IF; flush da cache de dados
	signal ic_data   : std_logic_vector(31 downto 0);
	signal ic_ready  : std_logic;
	signal ic_sel    : std_logic;
	signal ic_inval  : std_logic;
	signal id_addr   : std_logic_vector(31 downto 0);
	signal id_rden   : std_logic;
	signal id_adv    : std_logic;
	signal id_ready  : std_logic;
	signal id_rdata  : std_logic_vector(31 downto 0);
	signal id_line   : std_logic;
	signal id_rdx    : std_logic_vector(95 downto 0);
	signal dc_flush  : std_logic;
	signal dc_done   : std_logic;
	signal dc_busy   : std_logic;

begin

	pll_inst : entity work.clk_gen_3way
    port map (
      clk_in   => CLK,
      reset    => reset,
      clk0 => pll_clk_if,
      clk1 => pll_clk_idexmem,
      clk2 => pll_clk_wb
    );

	CORE : entity work.core
		generic map (has_m => true, has_zicsr => HAS_ZICSR, has_zifencei => HAS_ZIFENCEI, has_zicclsm => HAS_ZICCLSM, has_dcache => not WRITE_THROUGH)
		port map (
			o_trap       => core_trap,
			o_trap_cause => core_trap_cause,
			o_trap_pc    => core_trap_pc,

			i_clk          => pll_clk_idexmem,
			i_rst 		=> reset,

			o_if_addr       => if_addr,
			o_if_rden       => if_rden,
			i_boot_rom_data => boot_rom_data,
			i_flash_data    => flash_data,

			o_flash_addr2 => flash_addr2,
			o_flash_rden2 => flash_rden2,
			i_flash_data2 => flash_data2,

			o_ram_addr    => ram_addr,
			o_ram_wdata   => ram_wdata,
			i_ram_rdata   => ram_rdata,
			o_ram_en      => ram_en,
			o_ram_wren    => ram_wren,
			o_ram_rden    => ram_rden,
			o_ram_byteena => ram_byteena,

			o_sdram_addr    => sdram_addr,
			o_sdram_wdata   => sdram_wdata,
			o_sdram_byteena => sdram_byteena,
			o_sdram_rden    => sdram_rden,
			o_sdram_wren    => sdram_wren,
			i_sdram_rdata   => sdram_rdata,
			i_sdram_ready   => sdram_ready,
			o_mem_advance   => mem_advance,

			i_ic_data  => ic_data,
			i_ic_ready => ic_ready,
			o_ic_sel   => ic_sel,
			o_ic_inval => ic_inval,
			o_dc_flush => dc_flush,
			i_dc_done  => dc_done
	);

	ICACHE : entity work.icache
		port map (
			i_clk => pll_clk_if, i_rst => reset,
			i_addr => if_addr, i_sel => ic_sel, o_ready => ic_ready, o_data => ic_data,
			i_invalidate => ic_inval,
			o_d_addr => id_addr, o_d_rden => id_rden, o_d_advance => id_adv, i_d_ready => id_ready,
			i_d_rdata => id_rdata, o_d_line => id_line, i_d_rdata_x => id_rdx
	);

	INTERCONNECT : entity work.ext_axi_interconnect
		generic map (write_through => WRITE_THROUGH)
		port map (
			i_clk => pll_clk_idexmem, i_rst => reset,
			i_addr => sdram_addr, i_wdata => sdram_wdata, i_byteena => sdram_byteena,
			i_rden => sdram_rden, i_wren => sdram_wren, i_mem_advance => mem_advance,
			o_ready => sdram_ready, o_rdata => sdram_rdata,
			i_flush => dc_flush, o_flush_done => dc_done, o_busy => dc_busy,
			o_m0_awvalid => awvalid, i_m0_awready => awready, o_m0_awaddr => awaddr, o_m0_awlen => awlen,
			o_m0_awsize => awsize, o_m0_awburst => awburst,
			o_m0_wvalid => wvalid, i_m0_wready => wready, o_m0_wdata => wdata_a, o_m0_wstrb => wstrb, o_m0_wlast => wlast,
			i_m0_bvalid => bvalid, o_m0_bready => bready, i_m0_bresp => bresp,
			o_m0_arvalid => arvalid, i_m0_arready => arready, o_m0_araddr => araddr, o_m0_arlen => arlen,
			o_m0_arsize => arsize, o_m0_arburst => arburst,
			i_m0_rvalid => rvalid, o_m0_rready => rready, i_m0_rdata => rdata_a, i_m0_rresp => rresp, i_m0_rlast => rlast,
			o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena,
			o_p_we => p_we, o_p_re => p_re, i_p_rdata => p_rdata
		);

	-- the SDRAM end of the AXI4 bus: a slave in front of the bridge of the SDRAM system
	SDRAM_SLAVE : entity work.axi_slave_word_bridge
		port map (
			i_clk => pll_clk_idexmem, i_rst => reset,
			i_s_awvalid => awvalid, o_s_awready => awready, i_s_awaddr => awaddr, i_s_awlen => awlen,
			i_s_awsize => awsize, i_s_awburst => awburst,
			i_s_wvalid => wvalid, o_s_wready => wready, i_s_wdata => wdata_a, i_s_wstrb => wstrb, i_s_wlast => wlast,
			o_s_bvalid => bvalid, i_s_bready => bready, o_s_bresp => bresp,
			i_s_arvalid => arvalid, o_s_arready => arready, i_s_araddr => araddr, i_s_arlen => arlen,
			i_s_arsize => arsize, i_s_arburst => arburst,
			o_s_rvalid => rvalid, i_s_rready => rready, o_s_rdata => rdata_a, o_s_rresp => rresp, o_s_rlast => rlast,
			o_addr => m_addr, o_wdata => m_wdata, o_byteena => m_byteena, o_rden => m_rden, o_wren => m_wren,
			o_mem_advance => m_advance, i_ready => m_ready, i_rdata => m_rdata,
			o_line => m_line, o_wdata_x => m_wdx, o_byteena_x => m_bex, i_rdata_x => m_rdx
		);

	UART : entity work.jtag_uart
		port map (
			i_clk => pll_clk_idexmem, i_rst => reset,
			i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
			o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4),
			i_tck => UART_TCK, i_tdi => UART_TDI, o_tdo => UART_TDO, i_ir_in => UART_IR_IN,
			i_state_cdr => UART_STATE_CDR, i_state_sdr => UART_STATE_SDR,
			i_state_udr => UART_STATE_UDR, i_state_uir => UART_STATE_UIR
		);

	-- the SDRAM and its chip model; the debug ports of the model stay unused here
	SDRAM : entity work.sdram_system
		generic map (init_file => SDRAM_FILE)
		port map (
			i_clk_mem => CLK_MEM, i_clk_cpu => pll_clk_idexmem,
			i_rst_mem => reset,   i_rst_cpu => reset,
			i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_byteena,
			i_rden => m_rden, i_wren => m_wren, i_mem_advance => m_advance,
			o_ready => m_ready, o_rdata => m_rdata,
			i_line => m_line, i_wdata_x => m_wdx, i_byteena_x => m_bex, o_rdata_x => m_rdx,
			i_ins_addr => id_addr, i_ins_rden => id_rden, i_ins_advance => id_adv, o_ins_ready => id_ready,
			o_ins_rdata => id_rdata, i_ins_line => id_line, o_ins_rdata_x => id_rdx,
			o_init_done => sdram_init,
			i_dbg_word_addr => DBG_WORD_ADDR, o_dbg_word_data => DBG_WORD_DATA,
			i_dbg_flip => '0', i_dbg_flip_addr => (others => '0'), i_dbg_flip_bit => (others => '0'),
			o_dbg_refreshes => dbg_refreshes, o_dbg_init_ok => dbg_init_ok
	);

	BOOT_ROM : entity work.ROM_simulation
		generic map (rom_file => BOOT_ROM_FILE, memory_addr_width => boot_rom_addr_width)
		port map (
			i_addr 	=> if_addr(31 downto 2),
			i_clk 	=> pll_clk_if,
			i_re 		=> if_rden,
			o_data	=> boot_rom_data
	);

	FLASH : entity work.ROM_simulation
		generic map (rom_file => ROM_FILE, memory_addr_width => rom_addr_width)
		port map (
			i_addr 	=> if_addr(31 downto 2),
			i_clk 	=> pll_clk_if,
			i_re 		=> if_rden,
			o_data	=> flash_data,

			i_addr2 	=> flash_addr2(31 downto 2),
			i_clk2 	=> pll_clk_idexmem,
			i_re2 	=> flash_rden2,
			o_data2	=> flash_data2
	);

end architecture;
