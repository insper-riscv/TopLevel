# Runtime C: picolibc, crt0 e linker script da toolchain

Este projeto não tem `crt0` nem linker script próprios. Um programa C (ou assembly) é compilado e linkado com o que a toolchain do Infra já traz, e o que é deste hardware fica num único arquivo de plataforma e em três arquivos de código. Este guia diz de onde vem cada peça, como usar e o que o runtime entrega.

## 1. De onde vêm o linker script e o crt0

Ambos estão na toolchain da imagem `ghcr.io/insper-riscv/infra-toolchain` (a mesma instalação de `GCC_SETUP.md` do Infra, em `/opt/riscv-foundation/riscv32-elf`, com a picolibc do `riscv-gnu-toolchain`; o commit fica no `.tag` da instalação):

| Peça | Arquivo na toolchain | Como chega ao link |
| :--- | :--- | :--- |
| Linker script | `riscv32-unknown-elf/lib/picolibc.ld` | o driver do GCC o acrescenta quando não vê `-T` |
| `crt0` | `riscv32-unknown-elf/lib/crt0-hosted.o` | escolhido em `rv32im-fpga.specs` |
| Biblioteca C | `riscv32-unknown-elf/lib/libc.a` | `--specs=picolibc.specs` |

Para ver os caminhos na máquina em uso:

```bash
riscv32-unknown-elf-gcc -print-file-name=picolibc.ld
riscv32-unknown-elf-gcc --specs=picolibc.specs -print-file-name=crt0-hosted.o
```

## 2. O arquivo de plataforma

`rv32im-fpga.specs`, na raiz do repositório, é um arquivo de especificação do GCC. Ele inclui o `picolibc.specs` e acrescenta só o que é deste hardware:

```
%include <picolibc.specs>
%rename link rv32imfpga_picolibc_link

*link:
%(rv32imfpga_picolibc_link) --defsym=__flash=0x800 --defsym=__flash_size=30K --defsym=__ram=0x8000 --defsym=__ram_size=160K-24-1032 %{!DRV32_SPIKE:--defsym=rv32_wait_restart=0x100}

*startfile:
crt0-hosted%O%s
```

| Parte | O que faz |
| :--- | :--- |
| `__flash`, `__flash_size` | Onde o `picolibc.ld` põe `.init`, `.text` e `.rodata` (a FLASH, de `0x800`, 30 KB) |
| `__ram`, `__ram_size` | Onde ele põe `.data`, `.bss`, o heap e a pilha (a RAM, de `0x8000`). Os 1056 bytes do topo ficam de fora: 24 do mailbox e dos HTIF, 1032 do `stdout` (seção 5) |
| `rv32_wait_restart=0x100` | O endereço fixo da rotina da BOOT_ROM em que todo teste termina. Sai do link quando se compila com `-DRV32_SPIKE` (seção 6) |
| `crt0-hosted` | O startup da picolibc: ajusta `sp` e `gp`, copia `.data` da FLASH, zera `.bss`, prepara o TLS, roda construtores, chama `main` e chama `exit` com o que `main` retornou |

Fora do `riscv-tools`, o mesmo arquivo serve a qualquer compilação:

```bash
riscv32-unknown-elf-gcc -march=rv32im -mabi=ilp32 -Os --specs=rv32im-fpga.specs \
    programa.c platform/_exit.c -o programa.elf
```

## 3. O que o runtime entrega

Um programa compilado assim é hospedado: `main` pode retornar (o retorno vira `exit`, e daí `_exit`), e a libc completa da picolibc está disponível (`string.h`, `stdlib.h`, `malloc`, `free`, `printf`, `errno`, variáveis globais com construtores e TLS). Medido num programa C comum:

| Seção | Endereço |
| :--- | :--- |
| `_start` (entrada), `.init` | `0x800` |
| `.text`, `.rodata` (inclui o `.srodata`) | na FLASH, depois do `.init` |
| `.data` (inclui o `.sdata`), `.tdata` | VMA `0x8000`, LMA na FLASH |
| `.bss` | depois do `.data` |
| heap | de `_end` até `__stack` menos 4 KB |
| `__stack` (valor inicial de `sp`) | `0x2FBE0` |

O `picolibc.ld` reserva 4 KB de pilha como uma região, e o linker para com `a seção .stack não vai caber na região "ram"` se a RAM não comportar dados, heap e pilha.

O `memcpy` desta build da picolibc é byte a byte (`lbu` da FLASH, `sb` na RAM), e é ele que copia o `.data`; a segunda porta de leitura da FLASH (`FLASH_MEM`) atende leituras de byte e de meia palavra como a RAM. Os testes que exercitam isso são `c/data-init-*`, `c/bss-zero` e `c/struct-init-heap`.

## 4. Os arquivos do projeto

Em `platform/`:

| Arquivo | Papel |
| :--- | :--- |
| `boot_rom.S`, `boot_rom.ld` | A BOOT_ROM, gravada uma vez: limpa as palavras compartilhadas, pula para `0x800` e guarda o `rv32_wait_restart` em `0x100` (ver [CRT0_BOOT_REFERENCE.md](CRT0_BOOT_REFERENCE.md)) |
| `_exit.c` | O `_exit` em que o `crt0` termina: código 0 é PASS (mailbox `1`), qualquer outro é FAIL (mailbox `2`); depois salta para o `rv32_wait_restart` |
| `stdio.c` | A função de escrita do `stdout` (seção 5) |
| `spike_exit.S` | O substituto do `rv32_wait_restart` para o ELF do Spike (seção 6) |

No `config.yaml`: `toolchain.specs` aponta para o `rv32im-fpga.specs`, `paths.sources` lista `_exit.c` e `stdio.c` (compilados em todo teste), `paths.boot_rom` e `paths.boot_rom_linker_script` apontam para a BOOT_ROM, e `emulator.sources` e `emulator.gcc_flags` montam o ELF do Spike.

## 5. Saída de dados (`stdout`)

O core não tem nenhuma saída externa. O `stdout` (e `stderr`) é um buffer de 1 KB na RAM, que o host lê por JTAG depois do teste. A região fica no topo da RAM, fora do espaço que o linker dá ao programa:

| Endereço | Conteúdo |
| :--- | :--- |
| `0x0002FBE0` | `length`: bytes escritos, no máximo 1024 |
| `0x0002FBE4` | `truncated`: 1 quando algum byte não coube |
| `0x0002FBE8` | `data`: 1024 bytes |

O buffer é linear: quando enche, a escrita para e `truncated` fica em 1. A BOOT_ROM zera o cabeçalho a cada início. Não há entrada: a leitura devolve fim de arquivo. `printf`, `puts` e `putchar` funcionam sem alteração no código C; o teste `c/stdout-printf` confere o conteúdo e o `c/stdout-truncate` confere o estouro. Ainda não existe um comando do `riscv-tools` para o host ler essa região (hoje se lê com o `dump-ram`, no endereço `0x27BE0` relativo ao início da RAM).

O `printf` completo (com suporte a `double`) custa cerca de 12 KB dos 30 KB da FLASH.

## 6. O Spike

O programa de um teste termina no `rv32_wait_restart`, que no hardware é código da BOOT_ROM, num endereço fixo, e a imagem do teste não tem nada lá. Para o Spike, o ELF é montado à parte, com `-DRV32_SPIKE` (que tira o endereço fixo do link) e com `platform/spike_exit.S`, que define o `rv32_wait_restart` como código comum (o mailbox traduzido para HTIF, onde o Spike para). `tohost` e `fromhost` são símbolos absolutos nas palavras reservadas do topo da RAM, então o arquivo não ocupa espaço e todo endereço do ELF do Spike, e portanto de um golden, é o da imagem que o hardware carrega.

## 7. Limites conhecidos

- O ISA é `rv32im`: sem ponto flutuante em hardware (`float` e `double` rodam por software, pela libgcc). Decidir isso com calma antes de portar código que use.
- O core não tem CSR nem trap: nada de `signal`, `ecall` nem semihosting. O `crt0` e a `libc.a` não têm instruções de CSR.
- **Multiplicação ou divisão seguidas:** até a correção do PR #33 do `RV32IM`, duas instruções da extensão M em sequência (`div` e `rem`, `rem` e `div`, `divu` e `remu`, dois `mul`) faziam a segunda devolver o resultado da primeira, e as conversões de inteiro do `printf` (`%d`, `%x`) saíam erradas. A correção (um pulso de `start` por instrução, em `rv32im_pipeline_core.vhd`) foi verificada **só em simulação**, nos dois perfis; não foi compilada no Quartus nem testada na placa. Os testes `asm/div-rem-back-to-back` e `c/stdout-printf-int` cobrem o caso.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
