library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- The core on the board with the SDRAM as its RAM: BOOT_ROM, FLASH and FLASH_MEM (in internal-mem's order,
-- so the JTAG memory indices keep their meaning, minus the RAM that is gone) inside the FPGA, and the SDRAM at
-- 0x40000000 through the bridge, the arbiter and the controller of the Memory repository. The host reaches the
-- SDRAM through the debug master and its Virtual JTAG shell, as a second master of the controller. The core
-- clock is 50 MHz; the controller and the debug master run on the 142.857 MHz clock of the same PLL.
entity core_fpga_sdram is
	port (
		CLOCK_50 : in std_logic;
		FPGA_RESET_N : in std_logic := '1';
		LEDR : out std_logic_vector(9 downto 0) := (others => '0');
		HEX0 : out std_logic_vector(6 downto 0);
		HEX1 : out std_logic_vector(6 downto 0);
		HEX2 : out std_logic_vector(6 downto 0);
		HEX3 : out std_logic_vector(6 downto 0);
		HEX4 : out std_logic_vector(6 downto 0);
		HEX5 : out std_logic_vector(6 downto 0);

		DRAM_ADDR    : out   std_logic_vector(12 downto 0);
		DRAM_BA      : out   std_logic_vector(1 downto 0);
		DRAM_CAS_N   : out   std_logic;
		DRAM_CKE     : out   std_logic;
		DRAM_CLK     : out   std_logic;
		DRAM_CS_N    : out   std_logic;
		DRAM_DQ      : inout std_logic_vector(15 downto 0);
		DRAM_LDQM    : out   std_logic;
		DRAM_RAS_N   : out   std_logic;
		DRAM_UDQM    : out   std_logic;
		DRAM_WE_N    : out   std_logic
  	);
end entity;

architecture behaviour of core_fpga_sdram is

	component sdram_platform_pll is
		port (
			refclk   : in  std_logic;
			rst      : in  std_logic;
			outclk_0 : out std_logic;
			outclk_1 : out std_logic;
			outclk_2 : out std_logic;
			outclk_3 : out std_logic;
			locked   : out std_logic
		);
	end component;

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

	-- behind the interconnect: the SDRAM bridge, and the peripheral slots (4 is the JTAG UART, 5 the seven-segment display)
	signal m_addr    : std_logic_vector(31 downto 0);
	signal m_wdata   : std_logic_vector(31 downto 0);
	signal m_rdata   : std_logic_vector(31 downto 0);
	signal m_byteena : std_logic_vector(3 downto 0);
	signal m_rden    : std_logic;
	signal m_wren    : std_logic;
	signal m_ready   : std_logic;
	signal p_addr    : std_logic_vector(7 downto 0);
	signal p_wdata   : std_logic_vector(31 downto 0);
	signal p_byteena : std_logic_vector(3 downto 0);
	signal p_we, p_re : std_logic_vector(7 downto 0);
	signal p_rdata   : std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');
	-- the display register: the segments of the six digits, and the value for the result LEDs
	signal display_hex   : std_logic_vector(41 downto 0);
	signal display_value : std_logic_vector(23 downto 0);

	signal pll_clk_mem    : std_logic;
	signal pll_clk_dram   : std_logic;
	signal pll_clk_if     : std_logic;
	signal pll_clk_idexmem: std_logic;
	signal pll_locked     : std_logic;

	signal core_reset : std_logic;

	-- master A (the core's bridge) and master B (the debug master) of the arbiter, and the controller
	signal a_req, a_ack, a_we : std_logic;
	signal a_addr  : std_logic_vector(23 downto 0);
	signal a_wdata, a_rdata : std_logic_vector(31 downto 0);
	signal a_be    : std_logic_vector(3 downto 0);
	signal b_req, b_ack, b_we : std_logic;
	signal b_addr  : std_logic_vector(23 downto 0);
	signal b_wdata, b_rdata : std_logic_vector(31 downto 0);
	signal b_be    : std_logic_vector(3 downto 0);
	signal cmd_tog, done_tog : std_logic;
	signal d_op, d_be : std_logic_vector(3 downto 0);
	signal d_addr, r_addr : std_logic_vector(23 downto 0);
	signal d_data, r_data : std_logic_vector(31 downto 0);
	signal r_status : std_logic_vector(7 downto 0);

	-- SDRAM controller side
	-- Busca de instrucao em SDRAM: cache de instrucoes no clock do IF e a ponte do mestre I
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
	signal a_line    : std_logic;
	signal a_wdx, a_rdx : std_logic_vector(95 downto 0);
	signal a_bex     : std_logic_vector(11 downto 0);
	signal i_req, i_ack, i_we : std_logic;
	signal i_addr    : std_logic_vector(23 downto 0);
	signal i_wdata, i_rdata : std_logic_vector(31 downto 0);
	signal i_be      : std_logic_vector(3 downto 0);
	signal i_line    : std_logic;
	signal i_wdx, i_rdx : std_logic_vector(95 downto 0);
	signal i_bex     : std_logic_vector(11 downto 0);
	signal c_line    : std_logic;
	signal c_wdx, c_rdx : std_logic_vector(95 downto 0);
	signal c_bex     : std_logic_vector(11 downto 0);

	signal rst_async : std_logic;
	signal rst_sr    : std_logic_vector(1 downto 0) := "11";
	signal rst_mem   : std_logic;
	signal req_tog, ack_tog, init_done, c_we : std_logic;
	signal c_addr    : std_logic_vector(23 downto 0);
	signal c_wdata, c_rdata : std_logic_vector(31 downto 0);
	signal c_be      : std_logic_vector(3 downto 0);
	signal dq_out, dq_in : std_logic_vector(15 downto 0);
	signal dq_oe     : std_logic;
	signal dqm       : std_logic_vector(1 downto 0);
	signal init_cpu  : std_logic_vector(1 downto 0) := "00";

begin

	pll_inst : sdram_platform_pll
    port map (
      refclk   => CLOCK_50,
      rst      => not FPGA_RESET_N,
      outclk_0 => pll_clk_mem,
      outclk_1 => pll_clk_dram,
      outclk_2 => pll_clk_if,
      outclk_3 => pll_clk_idexmem,
      locked   => pll_locked
    );

	core_reset <= (not pll_locked) or (not FPGA_RESET_N);

	-- status LEDs: heartbeat, PLL, reset button, core running, SDRAM initialized
	LEDR(1) <= pll_locked;
	LEDR(2) <= FPGA_RESET_N;
	LEDR(3) <= not core_reset;
	LEDR(4) <= init_cpu(1);

	process (pll_clk_idexmem)
	begin
		if rising_edge(pll_clk_idexmem) then
			init_cpu <= init_cpu(0) & init_done;
		end if;
	end process;

	CORE : entity work.core
		generic map (has_m => true, has_zicsr => true, has_zifencei => true)
		port map (
			i_clk          => pll_clk_idexmem,
			i_rst        => core_reset,

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
			o_ic_inval => ic_inval
	);

	-- Instruction cache of the SDRAM: on the clock of the instruction memories, so that the
	-- instruction of the PC is there in the same cycle the core samples it, as for the ROMs
	ICACHE : entity work.icache
		port map (
			i_clk => pll_clk_if, i_rst => core_reset,
			i_addr => if_addr, i_sel => ic_sel, o_ready => ic_ready, o_data => ic_data,
			i_invalidate => ic_inval,
			o_d_addr => id_addr, o_d_rden => id_rden, o_d_advance => id_adv, i_d_ready => id_ready,
			i_d_rdata => id_rdata, o_d_line => id_line, i_d_rdata_x => id_rdx
		);

	IBRIDGE : entity work.sdram_cpu_bridge
		port map (
			i_clk_cpu => pll_clk_idexmem, i_rst_cpu => core_reset,
			i_addr => id_addr, i_wdata => (others => '0'), i_byteena => (others => '0'),
			i_rden => id_rden, i_wren => '0', i_mem_advance => id_adv,
			o_ready => id_ready, o_rdata => id_rdata,
			i_line => id_line, i_wdata_x => (others => '0'), i_byteena_x => (others => '0'), o_rdata_x => id_rdx,
			o_req_tog => i_req, i_ack_tog => i_ack, i_init_done => init_done,
			o_c_we => i_we, o_c_addr => i_addr, o_c_wdata => i_wdata, o_c_be => i_be, i_c_rdata => i_rdata,
			o_c_line => i_line, o_c_wdata_x => i_wdx, o_c_be_x => i_bex, i_c_rdata_x => i_rdx
		);

	BOOT_ROM : entity work.boot_rom1port
    port map (
      address => if_addr(10 downto 2),
      clock   => pll_clk_if,
      rden    => if_rden,
      wren    => '0',
      data    => (others => '0'),
      q       => boot_rom_data
    );

	FLASH : entity work.flash1port
    port map (
      address => if_addr(14 downto 2),
      clock   => pll_clk_if,
      rden    => if_rden,
      wren    => '0',
      data    => (others => '0'),
      q       => flash_data
    );

	-- FLASH's second copy, for data reads of the FLASH by the memory stage (the boot code copies .data from it)
	FLASH_MEM : entity work.flash_mem1port
    port map (
      address => flash_addr2(14 downto 2),
      clock   => pll_clk_idexmem,
      rden    => flash_rden2,
      wren    => '0',
      data    => (others => '0'),
      q       => flash_data2
    );

	-- SDRAM: the bridge (core clock), the arbiter and the controller (SDRAM clock), and the debug port
	-- the core's external port: bit 31 = 0 is the SDRAM, bit 31 = 1 a peripheral window
	INTERCONNECT : entity work.ext_interconnect
		port map (
			i_clk => pll_clk_idexmem, i_rst => core_reset,
			i_addr => sdram_addr, i_wdata => sdram_wdata, i_byteena => sdram_byteena,
			i_rden => sdram_rden, i_wren => sdram_wren, i_mem_advance => mem_advance,
			o_ready => sdram_ready, o_rdata => sdram_rdata,
			o_m_addr => m_addr, o_m_wdata => m_wdata, o_m_byteena => m_byteena,
			o_m_rden => m_rden, o_m_wren => m_wren, i_m_ready => m_ready, i_m_rdata => m_rdata,
			o_p_addr => p_addr, o_p_wdata => p_wdata, o_p_byteena => p_byteena,
			o_p_we => p_we, o_p_re => p_re, i_p_rdata => p_rdata
		);

	-- the UART whose other end is a host on JTAG (0xC0000000)
	JTAG_UART : entity work.jtag_uart_shell
		port map (
			i_clk => pll_clk_idexmem, i_rst => core_reset,
			i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(4), i_re => p_re(4),
			o_rdata => p_rdata(32 * 4 + 31 downto 32 * 4)
		);

	-- the seven-segment display and its host port (0xD0000000)
	DISPLAY : entity work.seg_display_shell
		port map (
			i_clk => pll_clk_idexmem, i_rst => core_reset,
			i_addr => p_addr, i_wdata => p_wdata, i_we => p_we(5), i_re => p_re(5),
			o_rdata => p_rdata(32 * 5 + 31 downto 32 * 5),
			o_hex => display_hex, o_value => display_value
		);

	HEX0 <= display_hex(6 downto 0);
	HEX1 <= display_hex(13 downto 7);
	HEX2 <= display_hex(20 downto 14);
	HEX3 <= display_hex(27 downto 21);
	HEX4 <= display_hex(34 downto 28);
	HEX5 <= display_hex(41 downto 35);

	-- the five left LEDs repeat the result: lit when the state is "passed" (0001), dark otherwise
	LEDR(9 downto 5) <= (others => '1') when display_value(15 downto 0) = x"0001" else (others => '0');

	SDRAM_BRIDGE : entity work.sdram_cpu_bridge
		port map (
			i_clk_cpu => pll_clk_idexmem, i_rst_cpu => core_reset,
			i_addr => m_addr, i_wdata => m_wdata, i_byteena => m_byteena,
			i_rden => m_rden, i_wren => m_wren, i_mem_advance => mem_advance,
			o_ready => m_ready, o_rdata => m_rdata,
			o_req_tog => a_req, i_ack_tog => a_ack, i_init_done => init_done,
			o_c_we => a_we, o_c_addr => a_addr, o_c_wdata => a_wdata, o_c_be => a_be, i_c_rdata => a_rdata,
			o_c_line => a_line, o_c_wdata_x => a_wdx, o_c_be_x => a_bex, i_c_rdata_x => a_rdx
		);

	SDRAM_ARBITER : entity work.sdram_arbiter
		port map (
			i_clk => pll_clk_mem, i_rst => rst_mem,
			i_a_req_tog => a_req, o_a_ack_tog => a_ack, i_a_we => a_we, i_a_addr => a_addr,
			i_a_wdata => a_wdata, i_a_be => a_be, o_a_rdata => a_rdata,
			i_a_line => a_line, i_a_wdata_x => a_wdx, i_a_be_x => a_bex, o_a_rdata_x => a_rdx,
			i_ins_req_tog => i_req, o_ins_ack_tog => i_ack, i_ins_we => i_we, i_ins_addr => i_addr,
			i_ins_wdata => i_wdata, i_ins_be => i_be, o_ins_rdata => i_rdata,
			i_ins_line => i_line, i_ins_wdata_x => i_wdx, i_ins_be_x => i_bex, o_ins_rdata_x => i_rdx,
			i_b_req_tog => b_req, o_b_ack_tog => b_ack, i_b_we => b_we, i_b_addr => b_addr,
			i_b_wdata => b_wdata, i_b_be => b_be, o_b_rdata => b_rdata,
			o_c_req_tog => req_tog, i_c_ack_tog => ack_tog, o_c_we => c_we, o_c_addr => c_addr,
			o_c_wdata => c_wdata, o_c_be => c_be, i_c_rdata => c_rdata,
			o_c_line => c_line, o_c_wdata_x => c_wdx, o_c_be_x => c_bex, i_c_rdata_x => c_rdx
		);

	SDRAM_DEBUG : entity work.sdram_dbg_master
		port map (
			i_clk => pll_clk_mem, i_rst => rst_mem,
			i_cmd_tog => cmd_tog, o_done_tog => done_tog, i_op => d_op, i_be => d_be, i_addr => d_addr, i_data => d_data,
			o_rsp_addr => r_addr, o_rsp_data => r_data, o_rsp_status => r_status,
			i_init_done => init_done,
			o_b_req_tog => b_req, i_b_ack_tog => b_ack, o_b_we => b_we, o_b_addr => b_addr,
			o_b_wdata => b_wdata, o_b_be => b_be, i_b_rdata => b_rdata
		);

	SDRAM_JTAG : entity work.sdram_jtag_shell
		port map (
			o_cmd_tog => cmd_tog, o_op => d_op, o_be => d_be, o_addr => d_addr, o_data => d_data,
			i_done_tog => done_tog, i_rsp_addr => r_addr, i_rsp_data => r_data, i_rsp_status => r_status
		);

	-- the controller is reset while the PLL is not locked or the button is pressed, released in
	-- step with its own clock
	rst_async <= (not pll_locked) or (not FPGA_RESET_N);
	process (pll_clk_mem, rst_async)
	begin
		if rst_async = '1' then
			rst_sr <= "11";
		elsif rising_edge(pll_clk_mem) then
			rst_sr <= rst_sr(0) & '0';
		end if;
	end process;
	rst_mem <= rst_sr(1);

	SDRAM_CTRL : entity work.sdram_ctrl
		-- the data pins go through one register in the IO cells (see the Quartus project); the clock
		-- phase of the pin DRAM_CLK makes the read data arrive in time for the register without the
		-- extra clock the simulation models for registered pins (found on the board, docs/SDRAM_BRINGUP.md)
		generic map (CAPTURE_EXTRA => 0, SYNC_REQ => false)
		port map (
			clk => pll_clk_mem, rst => rst_mem,
			req_tog => req_tog, ack_tog => ack_tog, init_done => init_done,
			we => c_we, addr => c_addr, wdata => c_wdata, be => c_be, rdata => c_rdata,
			line => c_line, wdata_x => c_wdx, be_x => c_bex, rdata_x => c_rdx,
			dram_cke => DRAM_CKE, dram_cs_n => DRAM_CS_N, dram_ras_n => DRAM_RAS_N,
			dram_cas_n => DRAM_CAS_N, dram_we_n => DRAM_WE_N, dram_ba => DRAM_BA,
			dram_addr => DRAM_ADDR, dram_dqm => dqm,
			dram_dq_out => dq_out, dram_dq_oe => dq_oe, dram_dq_in => dq_in
		);

	DRAM_CLK  <= pll_clk_dram;
	DRAM_LDQM <= dqm(0);
	DRAM_UDQM <= dqm(1);
	DRAM_DQ   <= dq_out when dq_oe = '1' else (others => 'Z');
	process (pll_clk_mem)
	begin
		if rising_edge(pll_clk_mem) then
			dq_in <= DRAM_DQ;
		end if;
	end process;

	blink : entity work.Blinky
	 port map (
		clk => CLOCK_50,
		led => LEDR(0)
	 );

end architecture;
