# Como um novo programa passa a rodar: rewrite de FLASH e handoff de boot

Trocar de teste na placa combina dois mecanismos distintos: um
genérico, do próprio `riscv-tools` (reescrever uma memória via JTAG
sem recompilar/reprogramar a FPGA inteira), e um específico deste
projeto (como o controle chega da BOOT_ROM fixa até o programa recém
escrito em FLASH). O segundo é o mesmo problema que qualquer sistema
de atualização remota de firmware precisa resolver (ver "O que a
BOOT_ROM e o programa combinam" abaixo): quem recebe a atualização já
está rodando código compilado **antes** da atualização existir, então
os dois lados (o que atualiza e o que é atualizado) precisam
concordar de antemão sobre onde tudo mora.

## A sequência completa

1. **Programação inicial (uma única vez)**: `quartus_sh --flow compile`
   + `quartus_pgm` carrega o bitstream inteiro, incluindo o conteúdo
   inicial de BOOT_ROM (`platform/boot_rom.S`) e da primeira FLASH/RAM.
   BOOT_ROM nunca mais é tocada depois disso.
2. **Troca de teste (caminho rápido)**: `riscv-tools run` reescreve
   FLASH (as duas cópias físicas, `FLASH`/`FLASH_MEM`, ver
   `quartus.rom_mem_instances`) via JTAG (In-System Memory Content
   Editor), sem recompilar nem reprogramar a FPGA; depois escreve `1`
   em `go_flag_addr`.
3. **O core, do lado de dentro**: entre um teste e outro, o core fica
   parado em `rv32_wait_restart` (endereço fixo `0x100` em BOOT_ROM),
   num loop que só faz `lw` de `go_flag_addr` até ler não-zero.
4. Ao ver o go-flag setado, `rv32_wait_restart` salta pra `_reset`
   (endereço fixo `0x0`). Antes de esperar, ele traduziu o mailbox que o
   teste anterior escreveu para o valor HTIF de `tohost` (convenção
   Spike/ACT4, sem efeito em hardware real).
5. `_reset` zera mailbox, go-flag, `tohost`, `fromhost` e o cabeçalho do
   `stdout` (pra não vazar o resultado nem a saída do teste anterior) e
   salta pra `FLASH_BASE` (`0x00000800`).
6. Em `0x800` está o `_start` do `crt0` da picolibc, dentro da imagem do
   teste: ajusta `sp` e `gp`, copia `.data` de FLASH pra RAM, zera
   `.bss`, prepara o TLS e chama `main`, ver
   [CRT0_BOOT_REFERENCE.md](CRT0_BOOT_REFERENCE.md).
7. Ao terminar, o teste escreve o mailbox (`RV32_PASS()`/`RV32_FAIL()`
   em `rv32_test.h`, ou o retorno de `main` via `_exit`) e chama
   `rv32_wait_restart`, voltando ao passo 3.

O contato entre a BOOT_ROM e a FLASH é só o salto do passo 5 (BOOT_ROM
para a FLASH) e o salto do passo 7 (programa para `0x100`): a BOOT_ROM
não lê nada da FLASH.

## Por que BOOT_ROM nunca é reescrita por teste

`_reset` e `rv32_wait_restart` são endereços fixos (`0x0`, `0x100`,
ver `platform/boot_rom.ld`), resolvidos no link **único e separado** de
`platform/boot_rom.S`, não no link de cada teste. Se BOOT_ROM fosse
reescrita por teste como FLASH é, cada nova compilação poderia mover
esses offsets, e todo teste que já tem esses mesmos endereços fixos
embutidos no próprio binário (via `--defsym=rv32_wait_restart=0x100`
em `rv32im-fpga.specs`) ficaria chamando um endereço errado sem nenhum
erro de link avisando, já que os dois lados são compilados e
linkados completamente separados. Manter BOOT_ROM congelada depois da
programação inicial é isso: sem ela fixa, não haveria endereço estável
pro handoff funcionar.

`rv32_wait_restart` também não pode ficar em FLASH: é nele que o core
espera enquanto o host reescreve a FLASH, então ele precisa estar numa
memória que ninguém reescreve, senão o core executaria instruções de uma
memória em reescrita.

## O que a BOOT_ROM e o programa combinam

`platform/boot_rom.S` é compilado e linkado **antes** de qualquer teste
existir: seu binário não pode conter nada de um teste específico. Esse é o
problema que qualquer atualização remota de firmware enfrenta: um bootloader
fixo, que não pode ser regravado remotamente (o risco de travar o dispositivo
pra sempre é alto demais), recebendo uma imagem de aplicação que pode. Os
dois lados precisam concordar de antemão sobre o mínimo, e aqui esse
mínimo é:

| Combinado | Valor | Quem usa |
| :--- | :--- | :--- |
| Entrada do programa | `0x800`, o `_start` da picolibc (o `picolibc.ld` põe `.init` no começo da FLASH) | BOOT_ROM salta pra lá |
| `rv32_wait_restart` | `0x100` | o programa salta pra lá ao terminar |
| Palavras do topo da RAM | mailbox `0x2FFFC`, go flag `0x2FFF8`, `fromhost` `0x2FFF0`, `tohost` `0x2FFE8`, cabeçalho do `stdout` `0x2FBE0` | BOOT_ROM as zera, o programa e o host as usam |

Tudo o mais (onde ficam `.data`, `.bss`, heap e pilha, o tamanho de cada
seção) é decidido no link de cada teste pelo linker script da toolchain, a
partir dos endereços de `rv32im-fpga.specs`; a BOOT_ROM não sabe de nada
disso, porque quem copia o `.data` e zera o `.bss` é o `crt0` do próprio
programa. Por isso a imagem de um teste carrega tudo o que varia nela.

O estágio MEM deste core tem, de fato, um caminho de leitura até FLASH
(a segunda porta física, `FLASH_MEM`, ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md#flash-precisa-de-uma-segunda-porta-de-leitura-o-limite-do-quartus-lite)):
é assim que o `crt0` lê o `.data` inicial da FLASH pra copiá-lo pra RAM, e
é assim que `.rodata` consegue ficar residente em FLASH (nunca copiado pra
RAM, ver [MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)).

Uma diferença real em relação a uma atualização remota de verdade (por
rádio, por exemplo): nada aqui verifica a integridade da imagem antes de
saltar pra ela (checksum, assinatura). JTAG é um link local, físico,
confiável, então essa verificação nunca foi necessária aqui; um sistema que
recebesse atualizações por um link não-confiável precisaria dela.

## O caminho lento: recompilar e reprogramar

Se um teste não responder no timeout (`quartus.default_timeout_s`), o
`riscv-tools`' `orchestrator` recorre a tiers progressivamente mais
caros até um recompile+reprogram completo; ver
[orchestrator](../tools/Tools/docs/modules/orchestrator.md) pros
detalhes de quando cada tier dispara, e
[HARDWARE_PROGRAMMING.md](HARDWARE_PROGRAMMING.md) pra regra
permanente de como compilar+programar sem quebrar a sessão JTAG.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../LICENSE).
