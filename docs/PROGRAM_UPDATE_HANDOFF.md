# Como um novo programa passa a rodar: rewrite de FLASH e handoff de boot

Trocar de teste na placa combina dois mecanismos distintos: um
genérico, do próprio `riscv-tools` (reescrever uma memória via JTAG
sem recompilar/reprogramar a FPGA inteira), e um específico deste
projeto (como o controle chega da BOOT_ROM fixa até o programa recém
escrito em FLASH). O segundo é o mesmo problema que qualquer sistema
de atualização remota de firmware precisa resolver (ver "Por que cada
seção tem um endereço fixo" abaixo): quem recebe a atualização já
está rodando código compilado **antes** da atualização existir, então
os dois lados (o que atualiza e o que é atualizado) precisam
concordar de antemão sobre onde tudo mora.

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
5. `_reset` inicializa `sp`, zera mailbox/go-flag/tohost/fromhost (pra
   não vazar o resultado do teste anterior), e carrega `gp` e os
   limites de `.data`/`.bss` como imediatos fixos (`li`), os mesmos
   pra qualquer teste, ver [CRT0_BOOT_REFERENCE.md](CRT0_BOOT_REFERENCE.md).
6. `_reset` lê o endereço de `main` **daquele teste específico** com
   um `lw` de `FLASH_BASE` (`0x00000800`, onde `crt0.S`'s
   `.flash_header` fica): a única coisa que ainda varia por teste.
7. Copia `.data`+`.sdata` de FLASH pra RAM e zera `.sbss`+`.bss`, usando
   os limites fixos do passo 5, depois salta (`jr`) pro `main` que
   acabou de ler.
8. Ao terminar, `main` chama `RV32_PASS()`/`RV32_FAIL()`
   (`rv32_test.h`), que escreve o mailbox e chama `rv32_wait_restart`
   de novo, voltando ao passo 3.

Diferente de um handoff em duas pontas (BOOT_ROM ↔ FLASH), tudo isso
roda inteiramente dentro de `_reset`, em BOOT_ROM: o único contato com
FLASH é essa única leitura do endereço de `main` no passo 6.

## Por que BOOT_ROM nunca é reescrita por teste

`_reset` e `rv32_wait_restart` são endereços fixos (`0x0`, `0x100`,
ver `boot_rom_symbols.ld`), resolvidos no link **único e separado**
de `boot_rom.S` (`boot_rom.ld`), não no `link.ld` de cada teste. Se
BOOT_ROM fosse reescrita por teste como FLASH é, cada nova compilação
poderia mover esses offsets, e todo teste que já tem esses mesmos
endereços fixos embutidos no próprio binário (via
`INCLUDE boot_rom_symbols.ld`) ficaria chamando um endereço errado sem
nenhum erro de link avisando, já que os dois lados são compilados e
linkados completamente separados. Manter BOOT_ROM congelada depois da
programação inicial é isso: sem ela fixa, não haveria endereço estável
pro handoff funcionar.

## Por que cada seção tem um endereço fixo

`boot_rom.S` é compilado e linkado **antes** de qualquer teste
existir: seu binário não pode conter `_data_start`/`_bss_end`/`main`
de um teste específico, porque esses símbolos só existem quando aquele
teste é compilado, depois. Isso é exatamente o problema que qualquer
atualização remota de firmware enfrenta: um satélite recebendo uma
nova imagem por rádio, um dispositivo IoT recebendo uma OTA update,
este projeto recebendo um novo teste por JTAG, todos têm o mesmo
formato, um bootloader fixo que não pode ser re-flasheado remotamente
(o risco de travar o dispositivo pra sempre é alto demais) recebendo
uma imagem de aplicação que pode. O bootloader não pode simplesmente
"descobrir" onde `.data`/`.bss`/`main` estão numa imagem nova; ou a
imagem carrega essa informação junto (mais bytes pra transmitir, mais
lógica de parsing no bootloader, mais superfície pra um bug travar o
dispositivo), ou os dois lados já concordam de antemão sobre um layout
fixo, e a imagem não precisa dizer quase nada.

Esse projeto escolheu a segunda opção: `link.ld` dá a cada seção um
endereço e um orçamento de tamanho fixos (ver
[CRT0_BOOT_REFERENCE.md](CRT0_BOOT_REFERENCE.md), seção "Seções de
memória", pra tabela completa), então `_data_start`/`_data_end`/`_bss_start`/
`_bss_end`/`gp` são a mesma constante pra qualquer teste, e
`boot_rom.S` carrega todos eles direto (`li`), sem ler nada de FLASH.
Sobra só uma coisa que realmente varia teste a teste: o endereço de
`main`, já que cada teste compila pra um binário diferente dentro do
orçamento fixo de `.text`. É por isso que `crt0.S`'s `.flash_header`
encolheu pra uma palavra só, o mínimo que um handoff remoto desse tipo
poderia precisar transmitir.

O estágio MEM deste core tem, de fato, um caminho de leitura até FLASH
(a segunda porta física, `FLASH_MEM`, ver
[MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md#flash-precisa-de-uma-segunda-porta-de-leitura-o-limite-do-quartus-lite)),
existente originalmente para o loop de cópia de `.data` de `_reset`,
mas que qualquer `lw` reaproveita em tempo de execução também: é
assim que `.rodata` consegue ficar residente em FLASH (nunca copiado
pra RAM, ver [MEMORY_ARCHITECTURE.md](MEMORY_ARCHITECTURE.md)) e é
assim que `_reset` lê a única palavra do header sem precisar de
nenhum código especial de instrução.

Uma diferença real em relação a uma atualização remota de verdade
(por rádio, por exemplo): nada aqui verifica a integridade da imagem
antes de saltar pra `main` (checksum, assinatura). JTAG é um link
local, físico, confiável, então essa verificação nunca foi necessária
aqui; um sistema que recebesse atualizações por um link não-confiável
precisaria dela.

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
