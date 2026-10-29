library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.rv32i_ctrl_consts.all;

entity rv32i3stage_core_sim_test is
	generic (
	  -- BOOT_ROM_FILE is built ONCE per test run (see
	  -- riscv_tools.boot_rom.build_boot_rom), not per test like
	  -- ROM_FILE (FLASH's own image) is -- see config.yaml's
	  -- sim.parameters. Both default to "default.hex" for existing
	  -- callers (e.g. tests/python/tests.json) that don't set them.
	  BOOT_ROM_FILE : string := "default.hex";
	  ROM_FILE : string := "default.hex";
	  -- Word-address width of ROM_simulation/RAM_simulation's internal
	  -- memory array (depth = 2**width words) — all three default to
	  -- 9 (512 words) inside ROM_simulation/RAM_simulation themselves,
	  -- too small for a program/mailbox address sized for the real
	  -- BOOT_ROM/FLASH/RAM1PORT hardware. Exposed here so a
	  -- full-pipeline testbench can size these to match whatever
	  -- memory map its own tests were compiled against, without
	  -- editing this file. Left at the same 9/9/9 default so existing
	  -- callers (e.g. tests/python/tests.json's instruction-level
	  -- tests) are unaffected.
	  boot_rom_addr_width : natural := 9;
	  rom_addr_width : natural := 9;
	  ram_addr_width : natural := 9
  	);
	port (
		CLK     : in  std_logic;
		reset   : in  std_logic := '0';
		UART_RX : in  std_logic := '1';
		UART_TX : out std_logic := '1'
  	);
end entity;

architecture behaviour of rv32i3stage_core_sim_test is

	-- IF stage: barramento UNICO compartilhado por BOOT_ROM e FLASH
	-- (ver rv32im_pipeline_core.vhd is_boot_rom_if/is_boot_rom_d) --
	-- ambas as ROM_simulation instancias abaixo recebem o MESMO
	-- if_addr/if_rden, cada uma devolvendo seu proprio dado.
	signal if_addr : std_logic_vector(31 downto 0);
	signal if_rden : std_logic;
	signal boot_rom_data : std_logic_vector(31 downto 0);
	signal flash_data : std_logic_vector(31 downto 0);

	-- Estagio MEM: segunda porta da FLASH, so' para o copy-loop de
	-- .data em boot_rom.S (ver rv32im_pipeline_core.vhd flash_addr2).
	signal flash_addr2 : std_logic_vector(31 downto 0);
	signal flash_rden2 : std_logic;
	signal flash_data2 : std_logic_vector(31 downto 0);

	signal ram_addr : std_logic_vector(31 downto 0);
	signal ram_wdata : std_logic_vector(31 downto 0);
	signal ram_rdata : std_logic_vector(31 downto 0);
	signal ram_memory_rdata : std_logic_vector(31 downto 0);
	signal ram_en : std_logic;
	signal ram_re_gated : std_logic;
	signal ram_we_gated : std_logic;
	signal ram_wren : std_logic;
	signal ram_rden : std_logic;
	signal ram_byteena : std_logic_vector(3 downto 0);

	signal pll_clk_if     : std_logic;
	signal pll_clk_idexmem: std_logic;
	signal pll_clk_wb     : std_logic;
	signal pll_locked     : std_logic;

	-- Mesma UART memory-mapped do topo de hardware, em 0xC0000000.
	signal uart_selected : std_logic;
	signal uart_write    : std_logic;
	signal uart_read     : std_logic;
	signal uart_rdata    : std_logic_vector(31 downto 0);
	signal uart_read_d   : std_logic;
	signal uart_rdata_d  : std_logic_vector(31 downto 0);

begin

	-- Separa a regiao da UART da RAM, exatamente como core_fpga_test.
	uart_selected <= '1'
		when ram_addr(31 downto 28) = x"C"
		else '0';
	uart_write <= ram_wren and ram_en and uart_selected;
	uart_read  <= ram_rden and ram_en and uart_selected;

	-- Sinais intermediarios para port maps (VHDL-93 nao aceita expressoes em port maps)
	ram_re_gated <= ram_rden and ram_en and not uart_selected;
	ram_we_gated <= ram_wren and ram_en and not uart_selected;

	pll_inst : entity work.clk_gen_3way
    port map (
      clk_in   => CLK,
      reset      => reset, -- reset ativo alto no PLL
      clk0 => pll_clk_if,
      clk1 => pll_clk_idexmem,
      clk2 => pll_clk_wb
    );

	CORE : entity work.rv32im_pipeline_core
		port map (
			clk          => pll_clk_idexmem,
			reset 		=> reset,

			----------------------------------------------------------------------
			-- Interface de busca de instrucao -- barramento unico
			-- compartilhado por BOOT_ROM e FLASH (ver
			-- rv32im_pipeline_core.vhd)
			----------------------------------------------------------------------
			if_addr       => if_addr,
			if_rden       => if_rden,
			boot_rom_data => boot_rom_data,
			flash_data    => flash_data,

			flash_addr2 => flash_addr2,
			flash_rden2 => flash_rden2,
			flash_data2 => flash_data2,

			----------------------------------------------------------------------
			-- Interface com a RAM (leitura e escrita)
			----------------------------------------------------------------------
			ram_addr    => ram_addr, 	-- endereço de palavra
			ram_wdata   => ram_wdata, 	-- dados a escrever (saida do store manager)
			ram_rdata   => ram_rdata, 	-- dados lidos
			ram_en      => ram_en, 		-- enable ram
			ram_wren    => ram_wren,    -- write enable
			ram_rden    => ram_rden,    -- read enable
			ram_byteena => ram_byteena 	-- máscara de bytes
		);

	UART_PERIPHERAL : entity work.UART
		generic map (
			DATA_WIDTH => 32,
			-- clk_gen_3way produz uma borda de pll_clk_idexmem a cada
			-- 30 ns com o CLK de 10 ns usado pelo perfil de simulacao.
			-- Mantem 115200 baud nesse clock de 33,333 MHz; o topo de
			-- hardware usa o valor default para seu PLL de 50 MHz.
			BAUD_FREQ  => 16#240#,
			BAUD_LIMIT => 16#2671#
		)
		port map (
			clock    => pll_clk_idexmem,
			clear    => reset,
			data_in  => ram_wdata,
			address  => ram_addr(3 downto 2),
			write    => uart_write,
			read     => uart_read,
			data_out => uart_rdata,
			irq      => open,
			uart_rx  => UART_RX,
			uart_tx  => UART_TX
		);

	UART_READ_PIPELINE : process (reset, pll_clk_idexmem)
	begin
		if reset = '1' then
			uart_read_d  <= '0';
			uart_rdata_d <= (others => '0');
		elsif rising_edge(pll_clk_idexmem) then
			uart_read_d <= uart_read;

			if uart_read = '1' then
				uart_rdata_d <= uart_rdata;
			end if;
		end if;
	end process;

	-- O core recebe a resposta do acesso realizado no ciclo anterior.
	ram_rdata <= uart_rdata_d
		when uart_read_d = '1'
		else ram_memory_rdata;

	-- BOOT_ROM e FLASH: duas instancias separadas da MESMA entidade
	-- ROM_simulation, cada uma com seu proprio arquivo/largura.
	-- BOOT_ROM: so' porta 1 (nunca tem .data proprio, addr2/clk2/re2
	-- ficam nos valores default). FLASH: porta 2 tambem usada, pelo
	-- estagio MEM (ver rv32im_pipeline_core.vhd flash_addr2 -- o
	-- copy-loop de .data em boot_rom.S le FLASH como dado).
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

	RAM : entity work.RAM_simulation
		generic map (memoryAddrWidth => ram_addr_width)
		port map(
			addr 		=> ram_addr(31 downto 2), -- word addressable
			mask 		=> ram_byteena,
			clk		 	=> pll_clk_idexmem,
			data_in 	=> ram_wdata,
			reRAM 		=> ram_re_gated,
			weRAM 		=> ram_we_gated,
			eRAM 		=> ram_en,
			data_out 	=> ram_memory_rdata
	);

end architecture;
