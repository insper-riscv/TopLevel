# O estado de boot de referência deste RISC-V bare-metal

O boot neste core passa por dois lados: a BOOT_ROM (`platform/boot_rom.S`), fixa e compartilhada, programada uma única vez e nunca reescrita por teste, e o `crt0` da picolibc, que vai dentro da imagem de cada teste na FLASH. Este projeto não tem `crt0` nem linker script próprios: ver [RUNTIME.md](RUNTIME.md) pra de onde vêm e como usar. Ver [PROGRAM_UPDATE_HANDOFF.md](PROGRAM_UPDATE_HANDOFF.md) pro como o controle passa de um lado pro outro a cada troca de teste.

Este documento descreve, registrador por registrador e seção por seção, exatamente que estado existe no instante em que `main()` é chamado, e, tão importante quanto, o que **não** é feito. O estado segue a ABI oficial do RISC-V
([riscv-elf-psabi-doc](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)).

## A sequência de boot

1. O reset entra em `_reset` (`0x0`, na BOOT_ROM): limpa mailbox, go flag, `tohost`, `fromhost` e o cabeçalho do `stdout`, e salta para `0x800`. Não inicializa `sp`, `gp` nem copia nada.
2. Em `0x800` está o `_start` do `crt0-hosted` da picolibc: ajusta `sp` (de `__stack`) e `gp` (de `__global_pointer$`) e chama o `_cstart`.
3. O `_cstart` copia `.data` e `.tdata` da FLASH para a RAM (com `memcpy`), zera `.bss` (com `memset`), prepara o TLS (`_set_tls`) e roda os construtores (`__libc_init_array`).
4. Chama `main(0, 0)` com `jal`, e o que `main` retornar vai para `exit`, que chama o `_exit` do projeto (`platform/_exit.c`). Um teste que termina por `RV32_PASS()` ou `RV32_FAIL()` escreve o mailbox e salta direto para o `rv32_wait_restart`, sem passar por `_exit`.

## Registradores de propósito geral no momento em que `main()` roda

| Registrador | Nome ABI | Estado em `main()` | Por quê |
|---|---|---|---|
| `x0` | `zero` | `0`, sempre | Fixo em silício. |
| `x1` | `ra` | Endereço de retorno para o `_cstart` | `main` é chamado com `jal`; o retorno cai no `exit` |
| `x2` | `sp` | `__stack` (`0x0002FBE0`) | Ajustado pelo `_start` a partir do linker script |
| `x3` | `gp` | `__global_pointer$` (depende do tamanho do `.data` normal, `0x8800` quando ele é vazio) | Ajustado pelo `_start` (`auipc` e `addi`, relativos ao PC). Necessário pra qualquer acesso `gp`-relativo a `.sdata`/`.sbss` |
| `x4` | `tp` | Bloco de TLS na RAM | Ajustado pelo `_set_tls` |
| `x10`, `x11` | `a0`, `a1` | `0`, `0` | `argc` e `argv` de `main`; sem linha de comando |
| demais `x5`–`x9`, `x12`–`x17`, `x18`–`x31` | `t`, `s`, `a` | **Não garantido** | Sobras do próprio startup; um programa correto nunca depende do valor inicial de um deles |

## CSRs (registradores de controle e status)

**Nenhum CSR é tocado** pelo `crt0-hosted` nem pela `libc.a`: nem `mstatus`, nem `mtvec`, nem `mepc`, nem `mie`/`mip`. Isso foi conferido no código objeto (nenhuma instrução `csr*`, `ecall`, `ebreak` ou `mret`), e reflete o hardware: `rv32im_pipeline_core` **não implementa Zicsr nem modo de exceção/trap**; não existe unidade de CSR em `RV32IM/src/`. Rodar uma instrução `csrw`/`csrr`/`ecall` neste core não tem definição conhecida de comportamento.

## Seções de memória

Os endereços vêm do `picolibc.ld` e de `rv32im-fpga.specs` (FLASH de `0x800`, 30 KB; RAM de `0x8000`, menos as regiões reservadas do topo). Não há orçamento fixo por seção: cada uma ocupa o que o programa precisa, e o linker recusa o que não cabe.

| Seção | Região | Estado antes de `main()` |
|---|---|---|
| `.init` | FLASH, `0x800` | O `_start` e o que a picolibc põe no começo |
| `.text`, `.rodata` (inclui o `.srodata`) | FLASH | Já estão lá, carregados via JTAG; `.rodata` nunca é copiado pra RAM: um `lw` o alcança pela segunda porta de leitura da FLASH (ver [MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)) |
| `.data` (inclui o `.sdata`), `.tdata` | RAM, a partir de `0x8000`; LMA na FLASH | Copiados da FLASH pelo `_cstart` |
| `.bss` (inclui o `.sbss`), `.tbss` | RAM, depois do `.data` | Zerados pelo `_cstart` |
| heap | RAM, de `_end` até `__heap_end` | Gerenciado pelo `malloc` da picolibc, via `sbrk` |
| Pilha | RAM, topo em `0x0002FBE0` | Só o ponteiro (`sp`) é definido; 4 KB reservados |
| `stdout` | RAM, `0x0002FBE0` a `0x0002FFE7` | Cabeçalho zerado pela BOOT_ROM (ver [RUNTIME.md](RUNTIME.md)) |
| Mailbox (`0x0002FFFC`) / go flag (`0x0002FFF8`) | RAM | Zerados a cada entrada em `_reset`, cold boot ou restart, pra nunca vazar o resultado do teste anterior |
| `fromhost` (`0x0002FFF0`) / `tohost` (`0x0002FFE8`) | RAM | Zerados a cada entrada em `_reset`; convenção HTIF, só o Spike e o ACT4 a usam |

## O que essa sequência de boot deliberadamente NÃO faz

- **Vetor de exceção/trap (`mtvec`) e tratamento de `ecall`/interrupções.** O core não tem CSR nem modo privilegiado.
- **Suporte multi-hart.** Assume um único hart, sem `mhartid`; o core é single-hart.
- **Entrada de dados.** Não há dispositivo de entrada: `stdin` devolve fim de arquivo.
- **PMP (Physical Memory Protection) / isolamento.** Sem CSR, não tem como configurar PMP.
- **Limpeza de registradores antes de `main()`.** Só os listados acima têm valor definido.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
