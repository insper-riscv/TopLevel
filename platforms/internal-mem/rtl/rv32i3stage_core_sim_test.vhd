library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rv32i3stage_core_sim_test is
	generic (
	  -- BOOT_ROM_FILE is built ONCE per test run (see
	  -- riscv_tools.boot_rom.build_boot_rom), not per test like
	  -- ROM_FILE (FLASH's own image) is -- see config.yaml's
	  -- sim.parameters. Both default to "default.hex" for existing
	  -- callers (e.g. tests/python/tests.json) that don't set them.
	  BOOT_ROM_FILE : string := "default.hex";
	  ROM_FILE : string := "default.hex";
	  -- Initial contents of the RAM, same format as ROM_FILE; empty: zero.
	  RAM_FILE : string := "";
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
	  ram_addr_width : natural := 9;
	  -- Zicsr no core (instrucoes CSR reais); false mantem o comportamento de NOP.
	  HAS_ZICSR : boolean := false;
	  -- Extensao M completa no core.
	  HAS_M : boolean := true;
	  -- Multiplicacao sem divisao (Zmmul) no core.
	  HAS_ZMMUL : boolean := false;
	  -- Acesso desalinhado a memoria principal executado em hardware (Zicclsm).
	  HAS_ZICCLSM : boolean := true
  	);
	port (
    	CLK  : in  std_logic;
		reset : in std_logic := '0'
  	);
end entity;

architecture behaviour of rv32i3stage_core_sim_test is

	-- Exceção sinalizada pelo core sem Zicsr (um ciclo em '1'); com Zicsr fica em '0'.
	signal core_trap       : std_logic;
	-- Causa da exceção sinalizada, no formato do mcause.
	signal core_trap_cause : std_logic_vector(31 downto 0);
	-- PC da instrução que gerou a exceção sinalizada.
	signal core_trap_pc    : std_logic_vector(31 downto 0);

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

begin

	-- Sinais intermediarios para port maps (VHDL-93 nao aceita expressoes em port maps)
	ram_re_gated <= ram_rden and ram_en;
	ram_we_gated <= ram_wren and ram_en;

	pll_inst : entity work.clk_gen_3way
    port map (
      clk_in   => CLK,
      reset      => reset, -- reset ativo alto no PLL
      clk0 => pll_clk_if,
      clk1 => pll_clk_idexmem,
      clk2 => pll_clk_wb
    );

	CORE : entity work.core
		generic map (has_m => HAS_M, has_zmmul => HAS_ZMMUL, has_zicsr => HAS_ZICSR, has_zicclsm => HAS_ZICCLSM)
		port map (
			o_trap       => core_trap,
			o_trap_cause => core_trap_cause,
			o_trap_pc    => core_trap_pc,

			i_clk          => pll_clk_idexmem,
			i_rst 		=> reset,

			----------------------------------------------------------------------
			-- Interface de busca de instrucao -- barramento unico
			-- compartilhado por BOOT_ROM e FLASH (ver
			-- rv32im_pipeline_core.vhd)
			----------------------------------------------------------------------
			o_if_addr       => if_addr,
			o_if_rden       => if_rden,
			i_boot_rom_data => boot_rom_data,
			i_flash_data    => flash_data,

			o_flash_addr2 => flash_addr2,
			o_flash_rden2 => flash_rden2,
			i_flash_data2 => flash_data2,

			----------------------------------------------------------------------
			-- Interface com a RAM (leitura e escrita)
			----------------------------------------------------------------------
			o_ram_addr    => ram_addr, 	-- endereço de palavra
			o_ram_wdata   => ram_wdata, 	-- dados a escrever (saida do store manager)
			i_ram_rdata   => ram_rdata, 	-- dados lidos
			o_ram_en      => ram_en, 		-- enable ram
			o_ram_wren    => ram_wren,    -- write enable
			o_ram_rden    => ram_rden,    -- read enable
			o_ram_byteena => ram_byteena 	-- máscara de bytes
	);

	-- BOOT_ROM e FLASH: duas instancias separadas da MESMA entidade
	-- ROM_simulation, cada uma com seu proprio arquivo/largura.
	-- BOOT_ROM: so' porta 1 (nunca tem .data proprio, addr2/clk2/re2
	-- ficam nos valores default). FLASH: porta 2 tambem usada, pelo
	-- estagio MEM (ver rv32im_pipeline_core.vhd flash_addr2 -- o
	-- copy-loop de .data em boot_rom.S le FLASH como dado).
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

	RAM : entity work.RAM_simulation
		generic map (memory_addr_width => ram_addr_width, ram_file => RAM_FILE)
		port map(
			i_addr 		=> ram_addr(31 downto 2), -- word addressable
			i_mask 		=> ram_byteena,
			i_clk		 	=> pll_clk_idexmem,
			i_data_in 	=> ram_wdata,
			i_re_ram 		=> ram_re_gated,
			i_we_ram 		=> ram_we_gated,
			i_en_ram 		=> ram_en,
			o_data_out 	=> ram_rdata
	);

end architecture;