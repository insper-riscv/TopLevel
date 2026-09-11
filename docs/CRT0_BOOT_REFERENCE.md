# O estado de boot de referência deste RISC-V bare-metal

Boot neste core acontece em dois arquivos, ligados separadamente:
`boot_rom.S` (`tools/riscv_build/boot_rom.S`), fixo e compartilhado,
programado em BOOT_ROM uma única vez e nunca reescrito por teste, faz
todo o trabalho de boot (inicializa `sp`/`gp`, copia `.data`, zera
`.bss`, limpa a mailbox); e `crt0.S` (`tools/riscv_build/crt0.S`),
específico de cada teste, reduzido a uma única palavra de dado (o
endereço de `main`) que `boot_rom.S` lê com um `lw`. Ver
[PROGRAM_UPDATE_HANDOFF.md](PROGRAM_UPDATE_HANDOFF.md) pro porquê
dessa divisão e como o controle passa de um lado pro outro.

Este documento descreve, registrador por registrador e seção por
seção, exatamente que estado existe no instante em que `main()` é
chamado, e, tão importante quanto, o que **não** é feito e por quê.
A base já deixa o hart num estado válido segundo a ABI oficial do
RISC-V
([riscv-elf-psabi-doc](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)).

## A sequência de boot

`link.ld` dá a cada seção um endereço e um tamanho fixos, os mesmos
pra qualquer teste (ver [PROGRAM_UPDATE_HANDOFF.md](PROGRAM_UPDATE_HANDOFF.md)
pro porquê). Isso significa que `_data_start`/`_data_end`/
`_bss_start`/`_bss_end`/`gp` são a mesma constante numérica sempre;
`boot_rom.S` carrega todos eles direto, sem ler nada de FLASH. A
única coisa que ainda varia por teste é o endereço de `main`.

1. Reset entra em `boot_rom.S`'s `_reset` (endereço fixo `0x0`):
   inicializa `sp` (`li sp, 0x0002FFE8`) e limpa mailbox/go-flag/
   tohost/fromhost.
2. Carrega `_data_load`/`_data_start`/`_data_end`/`_bss_start`/
   `_bss_end`/`gp` como imediatos fixos (`li`), os mesmos pra
   qualquer teste.
3. Lê o endereço de `main` daquele teste com um `lw` de `FLASH_BASE`
   (`0x00000800`, onde `crt0.S`'s `.flash_header` fica).
4. Copia `.data`+`.sdata` (`_data_load` → `[_data_start, _data_end)`),
   zera `.sbss`+`.bss` (`[_bss_start, _bss_end)`), depois `jr` pro
   `main` daquele teste.

Nenhum passo aqui sai de BOOT_ROM antes do `jr` final: a sequência
inteira roda dentro de `_reset`, sem saltar pra FLASH e voltar no meio
do caminho.

## Registradores de propósito geral no momento em que `main()` roda

| Registrador | Nome ABI | Estado em `main()` | Por quê |
|---|---|---|---|
| `x0` | `zero` | `0`, sempre | Hardwired em silício: nenhuma instrução pode mudar isso, não precisa (nem pode) ser inicializado. |
| `x1` | `ra` | **Não definido por este handoff** | O salto final pra `main` é `jr t6` (um jump puro), não `jal`/`call main`; nada nesta sequência de boot escreve em `ra`. Fica com o que quer que o hardware tenha deixado no reset. |
| `x2` | `sp` | `0x0002FFE8` (topo de RAM, ver `link.ld`) | Hardcoded em `boot_rom.S`'s `_reset` (`li sp, ...`), o primeiro registrador "de verdade" definido na sequência de boot. `link.ld` tem um `ASSERT` amarrando `_stack_top` a esse mesmo valor, pra pegar os dois saindo de sincronia. |
| `x3` | `gp` | `0x00008C00` (`__global_pointer$`, fixo pra qualquer teste) | Carregado por `boot_rom.S` via `li gp, 0x00008C00`: um imediato absoluto puro, sem relocação de símbolo nenhuma (`link.ld` tem um `ASSERT` verificando que `__global_pointer$` calcula exatamente esse valor). Necessário pra qualquer acesso `gp`-relative a `.sdata`/`.srodata`/`.sbss` funcionar; ver [SMALL_DATA_SECTION_BUG.md](bugs/SMALL_DATA_SECTION_BUG.md) pro bug real que motivou essa inicialização existir. |
| `x4` | `tp` | **Não inicializado** | `boot_rom.S` documenta isso como deliberado: nenhum teste deste projeto usa TLS hoje, e `link.ld` não declara `.tdata`/`.tbss` (removidas do mapa de memória). Se TLS algum dia for necessário, `tp` precisa voltar a ser inicializado (mesma convenção "Variant I" que `gp` segue pra `.sdata`) e as seções `.tdata`/`.tbss` precisam voltar ao `link.ld`. |
| `x5`–`x7` | `t0`–`t2` | **Não garantido** | `t0` é reusado três vezes (endereço-base da mailbox, depois `FLASH_BASE` pra ler `main`); `t1`/`t2` carregam `_data_load`/`_data_start`, avançando a cada iteração do loop de cópia. Chegam em `main()` com o que quer que tenham sobrado desse uso, não com um valor previsível. |
| `x8` | `s0`/`fp` | **Não inicializado**: o que o hardware deixou no reset | *Callee-saved* pela ABI: é responsabilidade de quem usa (tipicamente o prólogo de uma função com frame pointer) salvar/restaurar, não de quem inicializa o ambiente. |
| `x9`, `x18`–`x27` | `s1`, `s2`–`s11` | **Não inicializado** | Mesma razão que `s0`: *callee-saved*, sem garantia de valor inicial em nenhuma ABI RISC-V que conheço; nada na sequência de boot os toca. |
| `x10`–`x17` | `a0`–`a7` | **Não garantido** (nenhum argumento é passado pra `main()` aqui) | `a0` é usado como scratch pelo loop de cópia de `.data` (`lw a0, 0(t1)` / `sw a0, 0(t2)`); os demais nunca são tocados. Numa `libc` hospedada, `a0`/`a1` normalmente carregariam `argc`/`argv`, mas este bare-metal é `main(void)`, sem conceito de linha de comando. |
| `x28`–`x31` | `t3`–`t6` | **Usados durante o boot, depois não garantidos** | `t3`=`_data_end` (limite do loop de cópia), `t4`=`_bss_start` (avança no loop de zeragem), `t5`=`_bss_end` (limite desse loop), `t6`=endereço de `main` (lido do header, usado pelo `jr` final). Todos carregam valores fixos ou lidos do header, mas nenhum sobra com nada útil depois de `main()` começar. |

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

## Seções de memória: endereço fixo, estado no boot

Todo endereço abaixo é fixo, o mesmo pra qualquer teste (ver
[PROGRAM_UPDATE_HANDOFF.md](PROGRAM_UPDATE_HANDOFF.md) pro porquê e
pra tabela completa de orçamento por seção):

| Seção | Endereço | Estado antes de `main()` |
|---|---|---|
| `.flash_header` | `0x00000800` (FLASH) | Só o endereço de `main` daquele teste (4 bytes); lido com `lw`, nunca buscado como instrução. |
| `.text` | `0x00000804` (FLASH) | Já está lá, carregado via JTAG; nada a fazer em runtime. |
| `.rodata` (constantes grandes) | `0x00001804` (FLASH) | FLASH-resident, `VMA == LMA`, nunca copiado: um `lw` alcança FLASH diretamente pela segunda porta de leitura do estágio MEM (ver [MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)). |
| `.data` (grande, precisa init) | `0x00008000` (RAM) | Copiado de `_data_load` (`0x00002004`, FLASH) pra `[0x8000, 0x8400)`, pelo loop de `boot_rom.S`. |
| `.sdata`+`.srodata` (pequeno, `gp`-relative) | `0x00008400` (RAM) | Copiado junto no mesmo loop, `[0x8400, 0x8800)`; `gp` (`0x8C00`) fica no meio deste intervalo + o de `.sbss` logo abaixo. |
| `.sbss` (pequeno, zero-init, `gp`-relative) | `0x00008800` (RAM) | Zerado, `[0x8800, 0x8A00)`, mesmo loop que `.bss`. |
| `.bss` (grande, zero-init) | `0x00008A00` (RAM) | Zerado, `[0x8A00, 0x8E00)`. |
| Pilha | Topo em `0x0002FFE8` | Só o ponteiro (`sp`) é definido. Conteúdo é lixo até ser escrito; cresce pra baixo a partir daqui, dividindo o espaço livre com o heap (ver [MALLOC_SUPPORT.md](MALLOC_SUPPORT.md)). |
| Mailbox (`0x0002FFFC`) / go-flag (`0x0002FFF8`) | Protocolo deste projeto com o host (PASS/FAIL, restart) | Zerados a cada entrada em `_reset`, cold boot ou restart, pra nunca vazar o resultado do teste anterior. |
| `tohost`/`fromhost` | `0x0002FFE8`/`0x0002FFF0` | Zerados a cada entrada em `_reset`, mesma razão do mailbox. Endereços fixos hardcoded em `boot_rom.S`, não símbolos de linker resolvíveis no `link.ld` de um teste individual; `golden_generator` ainda os resolve por nome via `nm` porque roda um ELF combinado boot_rom+teste sob o Spike. |

Um teste cujo `.text`/`.rodata`/`.data`/`.sdata`/`.sbss`/`.bss` real
usa menos que o orçamento reservado da seção simplesmente deixa o
resto sem uso; um teste que excede o orçamento falha o link,
imediatamente, em vez de colidir silenciosamente com a próxima seção
(ver os `ASSERT`s em `link.ld`).

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

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
