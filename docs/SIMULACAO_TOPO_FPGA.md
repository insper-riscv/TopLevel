# Simulação do topo de hardware

O `riscv-tools sim` tem dois perfis. O padrão (`config.yaml`) simula um topo feito para simulação, com as memórias como arrays VHDL simples. O perfil `config.fpga-sim.yaml` simula o **topo de hardware de verdade** (`core_fpga_test`), com as quatro memórias reais do Quartus (BOOT_ROM, FLASH, FLASH_MEM e RAM) rodando nos modelos de simulação da própria Intel. Este guia explica o que o segundo perfil cobre a mais, como rodá-lo e o que continua só no hardware.

## 1. O que muda em relação ao sim padrão

| Peça | `config.yaml` (padrão) | `config.fpga-sim.yaml` |
| :--- | :--- | :--- |
| Topo | `rv32i3stage_core_sim_test` | `core_fpga_test`, o mesmo arquivo do projeto Quartus, sem alteração |
| Memórias | `ROM_simulation` e `RAM_simulation` (arrays VHDL) | `boot_rom1port`, `flash1port`, `flash_mem1port` e `ram1port`, os wrappers do Quartus sobre o modelo `altsyncram` |
| Imagem carregada | `.hex`, por um generic VHDL | `.mif`, pelo `init_file` da IP (`init.mif` e `boot_rom_init.mif`), as mesmas imagens do hardware |
| Endereço da RAM | Endereço absoluto do barramento | Endereço relativo a `ram_base`, como no hardware (veja `core_fpga_test.vhd`) |
| Clock | `clk_gen_3way`: pulsos de um clock base três vezes mais rápido | `pll_sim.vhd`: três clocks de 50 MHz, ciclo de trabalho de 50%, defasados 0, 6667 e 13333 ps, como o PLL real |
| Reset | Ativo em nível alto (`reset`) | `FPGA_RESET_N`, ativo em nível baixo, mais a espera pelo `locked` do PLL |

O núcleo (`rv32im_pipeline_core.vhd`) é o mesmo nos dois perfis.

O PLL real (`platforms/internal-mem/pll/pll.vhd`) envolve uma IP `altera_pll` cujo modelo de simulação é SystemVerilog, que o GHDL não roda. O arquivo `tests/FPGA/core/sim/pll_sim.vhd` do RV32IM tem a mesma entidade e as mesmas portas, com os parâmetros do `pll_0002.v`, e entra no lugar dele só na simulação: não faz parte do projeto Quartus.

## 2. Pré-requisitos

1. A biblioteca de simulação do Quartus: `altera_mf_components.vhd` e `altera_mf.vhd`, em `<Quartus>/eda/sim_lib/`. Ela vem com o Quartus, então este perfil roda onde o Quartus está instalado, e não em um runner hospedado do GitHub.
2. A variável `QUARTUS_ROOTDIR` apontando para o diretório `quartus` da instalação (por exemplo `/opt/altera_lite/25.1std/quartus`).
3. O GHDL, o GCC com picolibc e o Spike, como no sim padrão (a imagem `infra-toolchain` tem os três).
4. Os checkouts do Core, do Memory e do TopLevel ao lado do projeto de testes (`../Core`, `../Memory`, `../TopLevel`), como no `sim-fpga.yml`.

## 3. Como rodar

```bash
export QUARTUS_ROOTDIR=/opt/altera_lite/25.1std/quartus

uv run riscv-tools --config tools/riscv_build/config.yaml generate-header
uv run riscv-tools --config tools/riscv_build/config.yaml compile --emit mif
uv run riscv-tools --config tools/riscv_build/config.fpga-sim.yaml sim
```

O `compile --emit mif` gera as imagens e os goldens em `build/real/`, e o `sim` com o perfil novo lê essas imagens, gera o `.mif` da BOOT_ROM e roda os 85 testes. A biblioteca `altera_mf` é analisada uma vez por execução, em `build/sim/sim_work/libraries`.

O workflow `sim-fpga.yml` faz o mesmo no runner self-hosted, dentro da imagem `infra-toolchain`, com o Quartus montado somente para leitura. Só roda manualmente e pede a mesma confirmação (`FPGA_RUN_SECRET`) do `real.yml`.

## 4. O que a verificação faz

O módulo de teste (`platforms/internal-mem/testbench/test_c_program.py`) é o mesmo dos dois perfis. Ele observa o barramento de escrita da RAM (`ram_wren`, `ram_en`, `ram_addr`, `ram_wdata`, `ram_byteena`), procura a escrita de PASS ou FAIL no mailbox e, em testes de memória, compara o conteúdo reconstruído da RAM com o golden. O perfil do topo de hardware só muda o que ele dirige, por variáveis de ambiente (`sim.env`): nome do clock e do reset, período, clock de amostragem (`pll_clk_idexmem`, o da RAM) e limite de ciclos.

## 5. O que continua só no hardware

| Item | Por quê |
| :--- | :--- |
| Escrita de FLASH por JTAG (In-System Memory Content Editor) e a go flag vinda do host | Só existem na placa; na simulação a imagem é carregada do arquivo |
| Temporização e síntese | A simulação é funcional: não vê frequência máxima, violação de setup e hold nem otimização |
| Estado inicial real da FPGA | A simulação inicializa a memória e os registradores de forma previsível |
| Conteúdo da RAM lido de dentro da IP | O GHDL só expõe sinais, então o conteúdo é reconstruído do barramento, não lido da memória |
| PLL real | Substituído por `pll_sim.vhd`, sem jitter nem tempo de travamento real |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
