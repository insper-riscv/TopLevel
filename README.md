# TopLevel

🌐 [Português](README.md) · [English](README.en.md)

Plataformas do SoC RISC-V RV32: o que conecta o núcleo, as memórias e os periféricos em algo que executa, e tudo que depende dessa conexão. O repositório descreve e constrói uma plataforma. O núcleo, as memórias, os periféricos, os programas de teste e a certificação ficam em outros repositórios da organização [insper-riscv](https://github.com/insper-riscv).

## 1. Documentação

- [AUTHORS.md](AUTHORS.md): autores com commits no repositório, com nome e conta do GitHub.
- [CONTRIBUTING.md](CONTRIBUTING.md): regras obrigatórias de contribuição, normas VHDL-2008, C23 e Python, regras de documentação e verificação antes de abrir Pull Request.
- [CITATION.cff](CITATION.cff): metadados para citação do software.
- [docs/MEMORY_ARCHITECTURE.md](docs/MEMORY_ARCHITECTURE.md): arquitetura de memória BOOT_ROM, FLASH e RAM.
- [docs/CRT0_BOOT_REFERENCE.md](docs/CRT0_BOOT_REFERENCE.md): estado de boot, `crt0` da picolibc e `boot_rom.S`.
- [docs/PROGRAM_UPDATE_HANDOFF.md](docs/PROGRAM_UPDATE_HANDOFF.md): substituição de um programa por outro e passagem de boot entre testes.
- [docs/RUNTIME.md](docs/RUNTIME.md): runtime C, arquivo de plataforma, `stdout` e Spike.
- [docs/HARDWARE_PROGRAMMING.md](docs/HARDWARE_PROGRAMMING.md): programação da placa.
- [docs/SIMULACAO_TOPO_FPGA.md](docs/SIMULACAO_TOPO_FPGA.md): simulação do topo de hardware com as memórias reais do Quartus.

## 2. Plataforma em `platforms/<nome>/`

A plataforma existente é a `internal-mem`: uma Cyclone V 5CEBA4F23 com BOOT_ROM, FLASH e RAM dentro da FPGA.

| Caminho | Conteúdo |
| :--- | :--- |
| `platform.yaml` | Mapa de memória (regiões, palavras reservadas, pontos de entrada de boot e janelas dos periféricos) e a lista de cada cópia manuscrita dele, verificada por `riscv-tools check-memory-map` |
| `quartus/` | Projeto Quartus da placa: `core_fpga_test.vhd` (topo de hardware), `.qpf`, `.qsf`, `.sdc` e as imagens `.mif` iniciais |
| `pll/` | IP da PLL (`pll.vhd`, `pll_0002.v`, 50 MHz em três fases) e `pll_sim.vhd`, o substituto comportamental que a simula |
| `rtl/` | Topo de simulação `rv32i3stage_core_sim_test` (arrays VHDL puros no lugar dos IPs de memória), `clk_gen_3way` e `Blinky` |
| `runtime/` | O que a plataforma acrescenta à picolibc da toolchain: `rv32im-fpga.specs` (arquivo de specs do GCC com o mapa de memória), `boot_rom.S`, `boot_rom.ld`, `_exit.c`, `stdio.c` e `spike_exit.S` (substituto no Spike da `rv32_wait_restart` da boot ROM) |
| `testbench/` | `test_c_program.py`, testbench cocotb que observa o barramento de escrita da RAM para o PASS/FAIL de um programa |
| `../../tests/python/` | Testes por entidade em cocotb do RTL da plataforma (`clk_gen_3way`) e o catálogo (`tests.json`) que os conduz |
| `config.yaml`, `config.fpga-sim.yaml` | Configuração do `riscv-tools` para a plataforma: toolchain, memória, Quartus e simulação (do topo de simulação e do topo de hardware sobre os modelos `altera_mf` da Intel) |

## 3. Uso por um Projeto

Um projeto que executa testes nesta plataforma, hoje o [Tests](https://github.com/insper-riscv/Tests), estende a configuração da plataforma e acrescenta só os próprios caminhos:

```yaml
# Tests/tools/riscv_build/config.yaml
extends: ../../../TopLevel/platforms/internal-mem/config.yaml
paths: {include_dir: ..., build_dir: build, c_dir: c, asm_dir: asm}
```

Os caminhos dentro do `config.yaml` da plataforma são relativos à raiz do projeto consumidor, com os repositórios lado a lado (`../Core`, `../Memory`, `../TopLevel`), o mesmo arranjo dos submódulos do `RV32IM`. O campo `sim.python_path` coloca `testbench/` no caminho de busca do módulo de teste da simulação.

## 4. Verificação e Execução

```bash
git clone --recurse-submodules https://github.com/insper-riscv/TopLevel.git
git clone https://github.com/insper-riscv/Core.git     # ao lado
git clone https://github.com/insper-riscv/Memory.git   # ao lado
cd TopLevel
uv sync

make paths        # Existência de todos os caminhos listados nas configurações e no .qsf
make memory-map   # Concordância de cada cópia do mapa de memória com platform.yaml
make check        # Construção do topo de simulação no GHDL
make test         # Testes por entidade em cocotb do RTL (clk_gen_3way)
```

As ferramentas (GHDL e uv) vêm da imagem `ci-vhdl` do repositório [Infra](https://github.com/insper-riscv/Infra), onde a integração contínua executa. A simulação do topo de hardware exige a biblioteca `altera_mf` do Quartus e roda onde o Quartus está instalado, conforme [docs/SIMULACAO_TOPO_FPGA.md](docs/SIMULACAO_TOPO_FPGA.md).

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](LICENSE).
