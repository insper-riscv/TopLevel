library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

-- Bring-up of the board's SDRAM without the core: the controller of the Memory
-- repository and its self test on the 143 MHz clock.
--
--   KEY0     starts a run (also bit 0 of the JTAG source)
--   SW1:0    the mode: 00 quick, 01 patterns, 10 whole-chip sweep, 11 random addresses
--   LEDR0    PLL locked          LEDR1  SDRAM initialized      LEDR2  running
--   LEDR3    done, all words right   LEDR4  a word was wrong     LEDR5  the controller did not answer
--   LEDR9:6  phase of the run (low bits)
--
-- The JTAG probe (In-System Sources and Probes) gives the whole result: flags, words
-- moved, wrong words, and the address, expected and read data of the first wrong word.
entity sdram_bringup_top is
  port (
    CLOCK_50     : in    std_logic;
    FPGA_RESET_N : in    std_logic;
    KEY          : in    std_logic_vector(3 downto 0);
    SW           : in    std_logic_vector(9 downto 0);
    LEDR         : out   std_logic_vector(9 downto 0);

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
end entity sdram_bringup_top;

architecture rtl of sdram_bringup_top is

  component sdram_pll is
    port (
      refclk   : in  std_logic;
      rst      : in  std_logic;
      outclk_0 : out std_logic;
      outclk_1 : out std_logic;
      outclk_2 : out std_logic;
      locked   : out std_logic
    );
  end component;

  signal clk_mem, clk_dram, clk_cpu, locked : std_logic;

  signal rst_async : std_logic;
  signal rst_sr    : std_logic_vector(1 downto 0) := "11";
  signal rst_mem   : std_logic;

  signal key_s, sw_s : std_logic_vector(1 downto 0) := (others => '0');
  signal key0_q, key0_qq : std_logic := '1';
  signal key0_stable : std_logic := '1';
  signal debounce : unsigned(19 downto 0) := (others => '0');

  signal source    : std_logic_vector(7 downto 0);
  signal start, start_q : std_logic;
  signal mode      : std_logic_vector(1 downto 0);

  signal req_tog, ack_tog, init_done, c_we : std_logic;
  signal c_addr    : std_logic_vector(23 downto 0);
  signal c_wdata, c_rdata : std_logic_vector(31 downto 0);
  signal c_be      : std_logic_vector(3 downto 0);

  signal dq_out, dq_in : std_logic_vector(15 downto 0);
  signal dq_oe     : std_logic;
  signal dqm       : std_logic_vector(1 downto 0);

  signal busy, done, fail, timeout : std_logic;
  signal phase     : std_logic_vector(4 downto 0);
  signal err_count, ops_done, first_exp, first_got : std_logic_vector(31 downto 0);
  signal first_addr : std_logic_vector(23 downto 0);
  signal probe     : std_logic_vector(167 downto 0);

begin

  u_pll : sdram_pll
    port map (
      refclk => CLOCK_50, rst => not FPGA_RESET_N,
      outclk_0 => clk_mem, outclk_1 => clk_dram, outclk_2 => clk_cpu, locked => locked
    );

  DRAM_CLK <= clk_dram;

  -- reset: held while the PLL is not locked or the reset button is pressed; released
  -- in step with the controller clock
  rst_async <= (not locked) or (not FPGA_RESET_N);
  process (clk_mem, rst_async)
  begin
    if rst_async = '1' then
      rst_sr <= "11";
    elsif rising_edge(clk_mem) then
      rst_sr <= rst_sr(0) & '0';
    end if;
  end process;
  rst_mem <= rst_sr(1);

  -- buttons and switches into the controller clock; KEY0 is debounced (about 7 ms)
  process (clk_mem)
  begin
    if rising_edge(clk_mem) then
      sw_s    <= SW(1 downto 0);
      key0_q  <= KEY(0);
      key0_qq <= key0_q;
      if key0_qq /= key0_stable then
        debounce <= debounce + 1;
        if debounce(19) = '1' then
          key0_stable <= key0_qq;
          debounce    <= (others => '0');
        end if;
      else
        debounce <= (others => '0');
      end if;
    end if;
  end process;

  start <= (not key0_stable) or source(0);
  mode  <= source(2 downto 1) when source(7) = '1' else sw_s;

  u_ctrl : entity work.sdram_ctrl
    -- the data pins go through one register in the IO cells, so the read data is
    -- sampled one clock later than at the pin
    generic map (CAPTURE_EXTRA => 0)
    port map (
      clk => clk_mem, rst => rst_mem,
      req_tog => req_tog, ack_tog => ack_tog, init_done => init_done,
      we => c_we, addr => c_addr, wdata => c_wdata, be => c_be, rdata => c_rdata,
      dram_cke => DRAM_CKE, dram_cs_n => DRAM_CS_N, dram_ras_n => DRAM_RAS_N,
      dram_cas_n => DRAM_CAS_N, dram_we_n => DRAM_WE_N, dram_ba => DRAM_BA,
      dram_addr => DRAM_ADDR, dram_dqm => dqm,
      dram_dq_out => dq_out, dram_dq_oe => dq_oe, dram_dq_in => dq_in
    );

  DRAM_LDQM <= dqm(0);
  DRAM_UDQM <= dqm(1);

  DRAM_DQ <= dq_out when dq_oe = '1' else (others => 'Z');
  process (clk_mem)
  begin
    if rising_edge(clk_mem) then
      dq_in <= DRAM_DQ;
    end if;
  end process;

  u_bist : entity work.sdram_bist
    port map (
      clk => clk_mem, rst => rst_mem, start => start, mode => mode, init_done => init_done,
      busy => busy, done => done, fail => fail, timeout => timeout, phase => phase,
      err_count => err_count, first_addr => first_addr, first_exp => first_exp,
      first_got => first_got, ops_done => ops_done,
      c_req_tog => req_tog, c_ack_tog => ack_tog, c_we => c_we, c_addr => c_addr,
      c_wdata => c_wdata, c_be => c_be, c_rdata => c_rdata
    );

  LEDR(0)          <= locked;
  LEDR(1)          <= init_done;
  LEDR(2)          <= busy;
  LEDR(3)          <= done and (not fail);
  LEDR(4)          <= fail;
  LEDR(5)          <= timeout;
  LEDR(9 downto 6) <= phase(3 downto 0);

  probe <= "00000" & phase & timeout & fail & done & busy & init_done & locked  -- 16 bits
           & ops_done & err_count & first_addr & first_exp & first_got;

  u_probe : altsource_probe
    generic map (
      lpm_type => "altsource_probe",
      sld_auto_instance_index => "YES",
      sld_instance_index => 0,
      instance_id => "BIST",
      probe_width => 168,
      source_width => 8,
      source_initial_value => "0",
      enable_metastability => "NO"
    )
    port map (
      probe => probe, source => source, source_clk => clk_mem, source_ena => '1'
    );

  -- clk_cpu is generated for the next step (the core side of the bridge)
  -- and is not used here

end architecture rtl;
