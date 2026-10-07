library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.rv32i_ctrl_consts.all;

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

	-- behind the interconnect: the SDRAM bridge, and the peripheral slots (4 is the JTAG UART)
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

	CORE : entity work.rv32im_pipeline_core
		port map (
			clk          => pll_clk_idexmem,
			reset        => core_reset,

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
			clk => pll_clk_idexmem, rst => core_reset,
			addr => sdram_addr, wdata => sdram_wdata, byteena => sdram_byteena,
			rden => sdram_rden, wren => sdram_wren, mem_advance => mem_advance,
			ready => sdram_ready, rdata => sdram_rdata,
			m_addr => m_addr, m_wdata => m_wdata, m_byteena => m_byteena,
			m_rden => m_rden, m_wren => m_wren, m_ready => m_ready, m_rdata => m_rdata,
			p_addr => p_addr, p_wdata => p_wdata, p_byteena => p_byteena,
			p_we => p_we, p_re => p_re, p_rdata => p_rdata
		);

	-- the UART whose other end is a host on JTAG (0xC0000000)
	JTAG_UART : entity work.jtag_uart_shell
		port map (
			clk => pll_clk_idexmem, rst => core_reset,
			addr => p_addr, wdata => p_wdata, we => p_we(4), re => p_re(4),
			rdata => p_rdata(32 * 4 + 31 downto 32 * 4)
		);

	SDRAM_BRIDGE : entity work.sdram_cpu_bridge
		port map (
			clk_cpu => pll_clk_idexmem, rst_cpu => core_reset,
			addr => m_addr, wdata => m_wdata, byteena => m_byteena,
			rden => m_rden, wren => m_wren, mem_advance => mem_advance,
			ready => m_ready, rdata => m_rdata,
			req_tog => a_req, ack_tog => a_ack, init_done => init_done,
			c_we => a_we, c_addr => a_addr, c_wdata => a_wdata, c_be => a_be, c_rdata => a_rdata
		);

	SDRAM_ARBITER : entity work.sdram_arbiter
		port map (
			clk => pll_clk_mem, rst => rst_mem,
			a_req_tog => a_req, a_ack_tog => a_ack, a_we => a_we, a_addr => a_addr,
			a_wdata => a_wdata, a_be => a_be, a_rdata => a_rdata,
			b_req_tog => b_req, b_ack_tog => b_ack, b_we => b_we, b_addr => b_addr,
			b_wdata => b_wdata, b_be => b_be, b_rdata => b_rdata,
			c_req_tog => req_tog, c_ack_tog => ack_tog, c_we => c_we, c_addr => c_addr,
			c_wdata => c_wdata, c_be => c_be, c_rdata => c_rdata
		);

	SDRAM_DEBUG : entity work.sdram_dbg_master
		port map (
			clk => pll_clk_mem, rst => rst_mem,
			cmd_tog => cmd_tog, done_tog => done_tog, op => d_op, be => d_be, addr => d_addr, data => d_data,
			rsp_addr => r_addr, rsp_data => r_data, rsp_status => r_status,
			init_done => init_done,
			b_req_tog => b_req, b_ack_tog => b_ack, b_we => b_we, b_addr => b_addr,
			b_wdata => b_wdata, b_be => b_be, b_rdata => b_rdata
		);

	SDRAM_JTAG : entity work.sdram_jtag_shell
		port map (
			cmd_tog => cmd_tog, op => d_op, be => d_be, addr => d_addr, data => d_data,
			done_tog => done_tog, rsp_addr => r_addr, rsp_data => r_data, rsp_status => r_status
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
