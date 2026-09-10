# O estado de boot de referência deste RISC-V bare-metal

Boot neste core acontece across dois arquivos, ligados separadamente:
`boot_rom.S` (`tools/riscv_build/boot_rom.S`), fixo e compartilhado,
programado em BOOT_ROM uma única vez e nunca reescrito por teste, faz
o trabalho de verdade (inicializa `sp`, copia `.data`, zera `.bss`,
limpa a mailbox); e `crt0.S` (`tools/riscv_build/crt0.S`), específico
de cada teste, reduzido a um trampolim minúsculo (`_flash_entry`) que
só carrega os limites de `.data`/`.bss`/`gp`/`main` **daquele teste**
em registradores via busca de instrução pura (sem acesso a dado, ver
"Por que o handoff é código, não dado" abaixo) antes de saltar pro
código fixo de `boot_rom.S`.

Este documento descreve, registrador por registrador e seção por
seção, exatamente que estado existe no instante em que `main()` é
chamado, e, tão importante quanto, o que **não** é feito e por quê.
A base já deixa o hart num estado válido segundo a ABI oficial do
RISC-V
([riscv-elf-psabi-doc](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)),
não um atalho específico deste projeto.

## A sequência de boot

1. Reset entra em `boot_rom.S`'s `_reset` (endereço fixo `0x0`):
   inicializa `sp` com um valor hardcoded (`li sp, 0x0002FFE8`) e
   limpa mailbox/go-flag/tohost/fromhost, depois salta pro início de
   FLASH (`0x00000800`, endereço fixo: BOOT_ROM não enxerga os
   símbolos de linker do teste que está em FLASH).
2. Início de FLASH é sempre `crt0.S`'s `_flash_entry` (seção
   `.flash_entry`, forçada a vir primeiro em `link.ld`): carrega
   `_data_load`/`_data_start`/`_data_end`/`_bss_start`/`_bss_end`/
   `main` em `t1`-`t6` e `__global_pointer$` em `gp`, tudo via `la`
   (busca de instrução), depois salta pro endereço fixo
   `_boot_continue` (`0x180`) de volta em `boot_rom.S`.
3. `boot_rom.S`'s `_boot_continue` copia `.data` (`t1`→`t2` até
   `t3`), zera `.bss` (`t4` até `t5`), depois `jr t6` pra `main`.

## Registradores de propósito geral no momento em que `main()` roda

| Registrador | Nome ABI | Estado em `main()` | Por quê |
|---|---|---|---|
| `x0` | `zero` | `0`, sempre | Hardwired em silício: nenhuma instrução pode mudar isso, não precisa (nem pode) ser inicializado. |
| `x1` | `ra` | **Não definido por este handoff** | O salto final pra `main` é `jr t6` (um jump puro), não `jal`/`call main`; nada nesta sequência de boot escreve em `ra`. Fica com o que quer que o hardware tenha deixado no reset. |
| `x2` | `sp` | `0x0002FFE8` (topo de RAM, ver `link.ld`) | Hardcoded em `boot_rom.S`'s `_reset` (`li sp, ...`), o primeiro registrador "de verdade" definido na sequência de boot inteira, antes até de `gp`. `link.ld` tem um `ASSERT` amarrando `_stack_top` a esse mesmo valor, pra pegar os dois saindo de sincronia. |
| `x3` | `gp` | `__global_pointer$` (`.data`'s início + `0x800`, ver `link.ld`) | Carregado por `crt0.S`'s `_flash_entry` via `la gp, __global_pointer$`, dentro de `.option norelax` (sem isso, o assembler poderia reescrever esse mesmo `la` como um acesso `gp`-relative a si próprio, já que `gp` "pareceria" válido). Necessário pra qualquer acesso `gp`-relative a `.sdata`/`.srodata` funcionar; ver [SMALL_DATA_SECTION_BUG.md](bugs/SMALL_DATA_SECTION_BUG.md) pro bug real que motivou essa inicialização existir. |
| `x4` | `tp` | **Não inicializado** | `boot_rom.S` documenta isso como deliberado: nenhum teste deste projeto usa TLS hoje, e `link.ld` não declara `.tdata`/`.tbss` (removidas do mapa de memória). Se TLS algum dia for necessário, `tp` precisa voltar a ser inicializado (mesma convenção "Variant I" que `gp` segue pra `.sdata`) e as seções `.tdata`/`.tbss` precisam voltar ao `link.ld`. |
| `x5`–`x7` | `t0`–`t2` | **Não garantido** | Usados como scratch pela própria sequência de boot: `t1`/`t2` no loop de cópia de `.data`, `t0` no cálculo dos endereços de mailbox/tohost/fromhost (`_reset`, `rv32_wait_restart`). Chegam em `main()` com o que quer que tenham sobrado desse uso, não com um valor previsível. |
| `x8` | `s0`/`fp` | **Não inicializado**: o que o hardware deixou no reset | *Callee-saved* pela ABI: é responsabilidade de quem usa (tipicamente o prólogo de uma função com frame pointer) salvar/restaurar, não de quem inicializa o ambiente. |
| `x9`, `x18`–`x27` | `s1`, `s2`–`s11` | **Não inicializado** | Mesma razão que `s0`: *callee-saved*, sem garantia de valor inicial em nenhuma ABI RISC-V que conheço; nada na sequência de boot os toca. |
| `x10`–`x17` | `a0`–`a7` | **Não garantido** (nenhum argumento é passado pra `main()` aqui) | `a0` é usado como scratch pelo loop de cópia de `.data` em `boot_rom.S` (`lw a0, 0(t1)` / `sw a0, 0(t2)`); os demais nunca são tocados. Numa `libc` hospedada, `a0`/`a1` normalmente carregariam `argc`/`argv`, mas este bare-metal é `main(void)`, sem conceito de linha de comando. |
| `x28`–`x31` | `t3`–`t6` | **Usados pelo handoff, depois não garantidos** | Carregam o contrato de registradores entre `_flash_entry` e `_boot_continue` (`t3`=`_data_end`, `t4`=`_bss_start`, `t5`=`_bss_end`, `t6`=endereço de `main`) e são consumidos/sobrescritos pelos loops de cópia/zeragem antes de `main()` rodar; `t6` em particular é usado pelo `jr` final e não sobra com nenhum valor útil depois disso. |

**Resumo prático**: só `zero`, `sp` e `gp` têm uma garantia real de
estado antes de `main()`. Todo o resto, `tp` incluído, é território
comum de qualquer ABI RISC-V (ou, no caso de `t0`-`t6`/`a0`, lixo de
implementação da própria sequência de boot); um programa correto nunca
deveria depender do valor inicial de um registrador temporário/salvo
antes de defini-lo ele mesmo.

## CSRs (registradores de controle e status)

**Nenhum CSR é tocado** por `crt0.S` nem `boot_rom.S`: nem `mstatus`,
nem `mtvec`, nem `mepc`, nem `mie`/`mip`, nada. Isso é deliberado e
reflete o hardware real que este projeto testa: `rv32im_pipeline_core`
**não implementa Zicsr nem modo de exceção/trap**; não existe unidade
de CSR em nenhum dos arquivos VHDL do core (confirmado inspecionando
`RV32IM/src/`: não há `csr.vhd` nem equivalente). Rodar uma instrução
`csrw`/`csrr`/`ecall` neste core não tem definição conhecida de
comportamento; nenhum teste deste projeto faz isso.

## Por que o handoff é código, não dado

`boot_rom.S` é fixo e compartilhado entre todos os testes; ele não
enxerga os símbolos de linker de um teste específico (cada teste tem
seu próprio `.data`/`.bss`/`__global_pointer$`, todos em endereços
potencialmente diferentes). BOOT_ROM e FLASH são só de busca de
instrução (IF) neste core: nada dá ao estágio MEM um caminho de dado
até qualquer um dos dois, só até RAM (ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)). Por isso
`_flash_entry` não pode deixar uma tabela de dados em FLASH pra
`boot_rom.S` ler com `lw`, isso silenciosamente leria RAM em vez de
FLASH; precisa ser código (`la`, busca de instrução pura) que carrega
esses limites em registradores antes de saltar.

## Seções de memória: estado no boot

| Seção | O que é | Estado antes de `main()` |
|---|---|---|
| `.flash_entry` | Trampolim de boot do teste (`crt0.S`) | Primeira coisa em FLASH; código, executado uma vez por entrada em `_reset`. |
| `.text` | Código do teste (FLASH) | Já está lá, carregado via JTAG; nada a fazer em runtime. |
| `.data` | Globais inicializados, `.rodata` e globais pequenos (`.sdata`/`.srodata`), tudo numa única seção de saída (RAM, carga vem de FLASH) | Copiado byte a byte (4 em 4 bytes) de `_data_load` (endereço em FLASH) pra `[_data_start, _data_end)` em RAM, pelo loop de `boot_rom.S`. `.rodata` deixou de ficar retido em ROM/FLASH: BOOT_ROM/FLASH são só IF neste core, então toda constante somente-leitura também precisa estar em RAM pra qualquer `lw` alcançá-la. |
| `.bss`/`.sbss` | Globais não-inicializados (RAM) | Zerados, `[_bss_start, _bss_end)`; `_bss_start` marca o início de `.sbss`, não de `.bss`, pra manter as duas seções contíguas com um único loop. |
| Pilha | Cresce de `_stack_top` pra baixo | Só o ponteiro (`sp`) é definido, por `boot_rom.S`'s `_reset` (valor hardcoded, verificado por `ASSERT` contra `link.ld`'s `_stack_top`). Conteúdo é lixo até ser escrito. |
| Mailbox (`0x0002FFFC`) / go-flag (`0x0002FFF8`) | Protocolo deste projeto com o host (PASS/FAIL, restart) | Zerados a cada entrada em `_reset`, cold boot ou restart, pra nunca vazar o resultado do teste anterior. |
| `tohost`/`fromhost` | Convenção HTIF (Spike/`riscv-tests`) | Zerados a cada entrada em `_reset`, mesma razão do mailbox. Endereços fixos hardcoded em `boot_rom.S`, não símbolos de linker resolvíveis no `link.ld` de um teste individual; `golden_generator` ainda os resolve por nome via `nm` porque roda um ELF combinado boot_rom+teste sob o Spike. |

## O que essa sequência de boot deliberadamente NÃO faz

- **Vetor de exceção/trap (`mtvec`) e tratamento de `ecall`/interrupções.**
  Não existe porque o core não tem CSR/modo privilegiado (ver acima).
- **Suporte multi-hart.** Assume um único hart correndo, sem nenhum
  `csrr a0, mhartid; bnez a0, <park>` pra estacionar outros harts.
  Como o core é single-hart, isso nunca foi necessário.
- **TLS (`tp`, `.tdata`/`.tbss`).** `tp` não é tocado e essas seções
  não existem no `link.ld` atual; ver a linha de `tp` na tabela acima
  pro que precisaria voltar se isso mudar.
- **Heap / `brk`.** Não existe noção de heap nativa aqui; `malloc`/
  `free` deste projeto são implementação própria sobre `_bss_end`/
  `_stack_top`, ver [MALLOC_SUPPORT.md](MALLOC_SUPPORT.md).
- **Inicializadores globais C++ / `__libc_init_array`.** Como não há
  libc nem C++ aqui (`-nostdlib -ffreestanding`), não existe chamada
  pra rodar construtores globais (`.init_array`).
- **PMP (Physical Memory Protection) / isolamento.** Sem CSR, não tem
  como configurar PMP.
- **Limpeza de registradores temporários/salvos antes de `main()`.**
  `t0`-`t6`/`a0` saem de `main()` com lixo da própria sequência de
  boot (não do reset em si); `s0`-`s11`/`a1`-`a7` nunca são tocados.
  Um programa correto nunca deveria depender do valor inicial de
  nenhum deles.

## Por que a divisão entre `crt0.S` e `boot_rom.S` existe

O redesign de memória BOOT_ROM+FLASH+RAM (ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)) tornou BOOT_ROM
fixo e reprogramado só uma vez, enquanto FLASH é reescrita via JTAG a
cada troca de teste. Um bootloader fixo não pode conter lógica
específica de cada teste (seus próprios limites de `.data`/`.bss`,
seu próprio `gp`), então esse trabalho ficou em `crt0.S`
(recompilado e reescrito junto com cada teste), e só o trabalho
genérico (inicializar `sp`, copiar o que o trampolim indicou, limpar a
mailbox) ficou em `boot_rom.S`. Isso segue diretamente da restrição
de que BOOT_ROM/FLASH são só IF: qualquer coisa que dependesse de
`boot_rom.S` ler dado específico do teste em FLASH simplesmente não
funcionaria neste hardware (ver "Por que o handoff é código, não
dado" acima).

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
