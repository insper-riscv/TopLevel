# Como um novo programa passa a rodar: rewrite de FLASH e handoff de boot

Trocar de teste na placa combina dois mecanismos distintos: um
genérico, do próprio `riscv-tools` (reescrever uma memória via JTAG
sem recompilar/reprogramar a FPGA inteira), e um específico deste
projeto (como o controle chega da BOOT_ROM fixa até o programa recém
escrito em FLASH). O segundo só existe na forma que existe por causa
de uma restrição concreta do "Harvard modificado" deste core: BOOT_ROM
e FLASH só têm caminho de busca de instrução (IF) garantido; RAM é a
única memória que o estágio MEM sempre alcança (ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)).

## A sequência completa

1. **Programação inicial (uma única vez)**: `quartus_sh --flow compile`
   + `quartus_pgm` carrega o bitstream inteiro, incluindo o conteúdo
   inicial de BOOT_ROM (`boot_rom.S`) e da primeira FLASH/RAM. BOOT_ROM
   nunca mais é tocada depois disso.
2. **Troca de teste (caminho rápido)**: `riscv-tools run` reescreve
   FLASH (as duas cópias físicas, `FLASH`/`FLASH_MEM`, ver
   `quartus.rom_mem_instances`) via JTAG (In-System Memory Content
   Editor), sem recompilar nem reprogramar a FPGA; depois escreve `1`
   em `go_flag_addr`.
3. **O core, do lado de dentro**: entre um teste e outro, o core fica
   parado em `boot_rom.S`'s `rv32_wait_restart` (endereço fixo `0x100`
   em BOOT_ROM), num loop que só faz `lw` de `go_flag_addr` até ler
   não-zero.
4. Ao ver o go-flag setado, `rv32_wait_restart` decide o valor HTIF de
   `tohost` (convenção Spike/ACT4, sem efeito em hardware real) a
   partir do mailbox que o teste anterior escreveu, depois salta pra
   `_reset` (endereço fixo `0x0`).
5. `_reset` inicializa `sp` (valor hardcoded, o mesmo que `link.ld`
   verifica via `ASSERT` contra `_stack_top`), zera mailbox/go-flag/
   tohost/fromhost (pra não vazar o resultado do teste anterior), e
   salta pra `0x00000800` (`FLASH_BASE`), um endereço fixo: BOOT_ROM
   não enxerga os símbolos de linker do teste que acabou de ser
   escrito em FLASH.
6. `FLASH_BASE` é sempre o início de `_flash_entry` (seção
   `.flash_entry`, forçada a vir primeiro em `link.ld`), o trampolim de
   boot **daquele teste específico**: carrega os limites de
   `.data`/`.bss` daquele teste, `gp` e o endereço de `main` em
   registradores, só com `la` (busca de instrução pura), e salta pra
   `_boot_continue` (endereço fixo `0x180`, de volta em BOOT_ROM).
7. `_boot_continue` copia `.data` de FLASH pra RAM e zera `.bss`,
   usando exatamente os registradores que `_flash_entry` acabou de
   carregar, depois salta (`jr`) pro `main` daquele teste.
8. Ao terminar, `main` chama `RV32_PASS()`/`RV32_FAIL()`
   (`rv32_test.h`), que escreve o mailbox e chama `rv32_wait_restart`
   de novo, voltando ao passo 3.

## Contrato de registradores entre `_flash_entry` e `_boot_continue`

| Registrador | Conteúdo |
|---|---|
| `t1` | `_data_load` (origem em FLASH, LMA de `.data`) |
| `t2` | `_data_start` (destino em RAM, VMA de `.data`) |
| `t3` | `_data_end` |
| `t4` | `_bss_start` |
| `t5` | `_bss_end` |
| `t6` | Endereço de `main` |
| `gp` | Valor de `__global_pointer$` |

Esse contrato é fixo entre as duas pontas: `boot_rom.S` (fixo,
compilado uma vez) espera exatamente esses seis registradores mais
`gp` já carregados quando `_boot_continue` é alcançado, e todo
`crt0.S` de todo teste precisa preenchê-los na mesma ordem antes de
saltar.

## Por que BOOT_ROM nunca é reescrita por teste

`_reset`, `rv32_wait_restart` e `_boot_continue` são endereços fixos
(`0x0`, `0x100`, `0x180`, ver `boot_rom_symbols.ld`), resolvidos no
link **único e separado** de `boot_rom.S` (`boot_rom.ld`), não no
`link.ld` de cada teste. Se BOOT_ROM fosse reescrita por teste como
FLASH é, cada nova compilação poderia mover esses offsets, e todo
teste que já tem esses mesmos endereços fixos embutidos no próprio
binário (via `INCLUDE boot_rom_symbols.ld`) ficaria chamando um
endereço errado sem nenhum erro de link avisando, já que os dois
lados são compilados e linkados completamente separados. Manter
BOOT_ROM congelada depois da programação inicial é isso: sem ela
fixa, não haveria endereço estável pro handoff funcionar.

## Por que o handoff usa registradores, não uma tabela de dados em FLASH

BOOT_ROM é compilada e linkada **antes** de qualquer teste existir:
o binário de `boot_rom.S` não pode conter `_data_start`/`_bss_end`/
`main` de um teste específico, porque esses símbolos só existem
quando aquele teste é compilado, depois. Alguma forma de passar esses
valores em tempo de execução é necessária de qualquer forma.

O estágio MEM deste core tem, de fato, um caminho de leitura até FLASH
(a segunda porta física, `FLASH_MEM`, ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md#flash-precisa-de-uma-segunda-porta-de-leitura-o-limite-do-quartus-lite)),
só que só de leitura (nunca escrita) e existente especificamente para
o próprio loop de cópia de `.data` de `_boot_continue`. Isso significa
que uma tabela de dados em FLASH que `_boot_continue` lesse com `lw`
seria fisicamente possível hoje. O que está implementado em vez disso
é código: `_flash_entry` carrega esses valores em registradores via
`la` (busca de instrução, sem nenhum `lw`), o que evita `_boot_continue`
precisar entender um formato de tabela específico, sempre exatamente
os mesmos seis registradores mais `gp`, não bytes numa posição de
memória combinada.

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
