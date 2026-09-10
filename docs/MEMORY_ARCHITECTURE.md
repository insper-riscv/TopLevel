# Arquitetura de memória: BOOT_ROM + FLASH + RAM (Harvard modificado)

## Resumo

O core (`rv32im_pipeline_core`) modela a hierarquia de memória de uma SoC de
verdade com **3 papéis lógicos**, implementados em **4 instâncias físicas**
de memória:

| Papel     | Instância(s) física(s)      | Reescrita via JTAG?          | Quem acessa                    |
|-----------|------------------------------|-------------------------------|---------------------------------|
| BOOT_ROM  | `BOOT_ROM`                    | Não: só no compile inicial   | Só busca de instrução (IF)     |
| FLASH     | `FLASH` + `FLASH_MEM`         | Sim: a cada troca de teste   | `FLASH`: IF. `FLASH_MEM`: MEM  |
| RAM       | `RAM`                         | Não (JTAG só lê/escreve dado) | IF nunca. MEM sempre.          |

Isso é chamado de **"Harvard modificado"**: um Harvard "de verdade" teria
barramentos de instrução e dado totalmente independentes, sem nenhuma
sobreposição. Aqui, IF busca instrução de BOOT_ROM/FLASH (nunca de RAM), e o
estágio MEM (load/store) só toca RAM, **exceto** por uma abertura
deliberada: o estágio MEM também consegue ler `FLASH_MEM` (a segunda cópia
física da FLASH), só para o bootloader copiar `.data` de FLASH pra RAM no
boot. Essa é a única exceção à separação instrução/dado: ver
[FLASH precisa de uma segunda porta de leitura](#flash-precisa-de-uma-segunda-porta-de-leitura-o-limite-do-quartus-lite)
abaixo.

Antes desse redesign, o core era Harvard **estrito** (uma ROM, uma RAM, MEM
nunca tocava ROM), o que quebrava `.data` com valor inicial não-zero de
forma irrecuperável (ver [DATA_HARVARD_BUG.md](bugs/DATA_HARVARD_BUG.md), cujo
link "Correção definitiva" aponta pra este documento).

## Os três papéis, em detalhe

### BOOT_ROM: bootloader fixo

Programado **uma única vez**, como parte do compile completo inicial do
Quartus (`quartus_sh --flow compile` + `quartus_pgm`); nunca reescrito via
JTAG depois disso, diferente de FLASH. Contém `boot_rom.S`
(`tools/riscv_build/boot_rom.S`): o vetor de reset, o loop de cópia de
`.data` (FLASH → RAM), o loop de zerar `.bss`, a limpeza de
mailbox/go_flag/tohost/fromhost, e o loop de espera/restart
(`rv32_wait_restart`) que deixa `build_fpga.py` trocar de teste sem
reprogramar a FPGA inteira.

É genérico de propósito: não conhece o `.data`/`.bss` de teste nenhum. O
"handoff" de cada teste pra ele é **código, não dado**: o próprio
`crt0.S` de cada teste emite um trampolim (`.flash_entry`, primeira coisa em
FLASH) que carrega os limites de `.data`/`.bss`/`gp`/`main` em registradores
via `la` (busca de instrução pura, sem MEM) antes de saltar pra
`_boot_continue` em BOOT_ROM.

### FLASH: o "firmware" de cada teste

O programa de verdade de cada teste (`.flash_entry` + `.text`), reescrito
via JTAG (In-System Memory Content Editor) toda vez que um teste troca;
mesmo papel que a antiga `ROM` tinha antes do redesign. Fisicamente é uma
`altsyncram` do tipo RAM (não uma flash de verdade), mas architeturalmente
representa o armazenamento não-volátil: só é regravada explicitamente entre
execuções, nunca pela CPU em tempo de execução.

### RAM: dado de verdade

`.data`/`.rodata`/`.bss`/pilha. A única memória que o estágio MEM
(load/store) sempre alcança. Os últimos 24 bytes do espaço físico da IP são
reservados (fora do `LENGTH(RAM)` que `link.ld` dá ao teste) para:
mailbox + go_flag (2 palavras) e tohost/fromhost (4 palavras, convenção HTIF
usada só pelo Spike/ACT4).

## FLASH precisa de uma segunda porta de leitura: o limite do Quartus Lite

O estágio MEM precisa ler FLASH como dado especificamente para o loop de
cópia de `.data` em `boot_rom.S` (`lw a0, 0(t1)`, onde `t1` aponta pra
dentro de FLASH, o LMA de `.data`). Isso só foi descoberto num bug real em
hardware: `.bss`/computação funcionavam normalmente, mas globais com valor
inicial não-zero ficavam sempre zerados, porque o `lw` do copy-loop não
alcançava FLASH (só RAM) na primeira versão deste redesign.

A solução óbvia, dar à `FLASH` uma segunda porta de leitura (uma IP
`altsyncram` `DUAL_PORT`), **não compila no Quartus Prime Lite**: uma
`altsyncram` com `operation_mode => DUAL_PORT` **e**
`lpm_hint => "ENABLE_RUNTIME_MOD=YES"` ao mesmo tempo falha a compilar nessa
edição (confirmado empiricamente rodando `quartus_map` isolado nessa IP).
`ENABLE_RUNTIME_MOD` é obrigatório porque é o que permite ao JTAG In-System
Memory Content Editor reescrever a FLASH a cada teste.

**Fix**: em vez de uma FLASH dual-port, existem **duas instâncias físicas
idênticas**, single-port cada uma:

- `FLASH` (`ips/FLASH1PORT/flash1port.vhd`): porta de busca de instrução
  (IF), `INSTANCE_NAME=FLASH`.
- `FLASH_MEM` (`ips/FLASH_MEM1PORT/flash_mem1port.vhd`): porta de leitura
  de dado pro estágio MEM, `INSTANCE_NAME=FLASH_MEM`. Mesmo clock que a RAM
  (`pll_clk_idexmem`), já que é o estágio MEM que consome as duas.

O `INSTANCE_NAME` diferente é o que faz o JTAG In-System Memory Content
Editor tratá-las como dois taps independentes. O `riscv_tools` (mailbox/
rom_writer) escreve o **mesmo conteúdo** nas duas toda vez que troca de
teste; `config.yaml`: `quartus.rom_mem_instances: [1, 3]`, uma lista com
os dois índices JTAG, não um só.

Esse é exatamente o mesmo truque que o design antigo (pré-BOOT_ROM/FLASH
split) já usava para `ROM`/`ROM_MEM`, pela mesma limitação do Quartus Lite;
só que agora escopado apenas à FLASH (BOOT_ROM nunca precisa de segunda
porta, já que não tem `.data` próprio: `boot_rom.S` só usa imediatos
fixos).

## Mapa de memória (endereços atuais)

| Região                | Base         | Tamanho          | Words  | widthad |
|------------------------|--------------|------------------|--------|---------|
| BOOT_ROM               | `0x00000000` | 2K               | 512    | 9       |
| FLASH / FLASH_MEM      | `0x00000800` | 30K              | 7680   | 13      |
| RAM (espaço físico)    | `0x00008000` | 160K             | 40960  | 16      |
| RAM (útil, `link.ld`)  | `0x00008000` | 160K − 24 bytes  | N/A      | N/A       |
| mailbox_addr           | `0x0002FFFC` | 1 palavra        | N/A      | N/A       |
| go_flag_addr           | `0x0002FFF8` | 1 palavra        | N/A      | N/A       |
| fromhost               | `0x0002FFF0` | 2 palavras       | N/A      | N/A       |
| tohost                 | `0x0002FFE8` | 2 palavras       | N/A      | N/A       |
| `_stack_top` (sp)      | `0x0002FFE8` | N/A                | N/A      | N/A       |

FLASH ficou em **30K** (não 32K, que seria o número "redondo" óbvio) por um
motivo específico: o topo de RAM (`ram_base + ram_words*4 = 0x30000`)
precisa cair num endereço alinhado em 4096 bytes, porque toda escrita de
mailbox em `Tests/asm/*/src.S` usa `lui xN, 0x30` (sem `addi` depois) pra
montar esse endereço: `lui` só zera os 12 bits baixos, então só funciona se
esses 12 bits já forem zero no valor real. `0x800 (FLASH_BASE) + FLASH_SIZE`
só cai num múltiplo de 4096 se `FLASH_SIZE` for um múltiplo ímpar de 2048
(30K = 30720 = 15×2048 serve; 32K = 32768 = 16×2048 não).

### Por que esse mapa mudou (histórico)

A primeira versão deste redesign usava FLASH=66K/RAM=224K. Isso **compilava
e passava na simulação GHDL**, mas a compilação real (`quartus_sh --flow
compile`) falhava: `Error (170048): Selected device has 308 RAM location(s)
of type M10K block. However, the current design needs more than 308 to
successfully fit.` A Cyclone V 5CEBA4F23 tem exatamente 308 blocos M10K
(10Kbit cada); um limite de **quantidade de blocos**, não só de bits totais,
e duplicar FLASH pra dar à FLASH_MEM sua própria cópia empurrou o design
pra além desse teto. O mapa atual (30K/160K) usa cerca de 178 blocos (~58%
do teto), com folga real.

## Índices JTAG (`config.yaml: quartus:`)

Ordem de instanciação em `core_fpga_test.vhd` (que é a ordem que o In-System
Memory Content Editor usa pra numerar as instâncias):

0. `BOOT_ROM`: sem índice usável em `config.yaml` de propósito, nunca é
   reescrita em tempo real, só no compile inicial.
1. `FLASH`: `quartus.rom_mem_instances[0]`.
2. `RAM`: `quartus.ram_mem_instance` / `quartus.mailbox_mem_instance`
   (o mailbox mora dentro da RAM, então compartilha o índice dela).
3. `FLASH_MEM`: `quartus.rom_mem_instances[1]`. Instanciada **depois** de
   RAM de propósito, pra não deslocar o índice 2 que RAM já tem.

## LEDs (`core_fpga_test.vhd`)

| LED     | Sinal              | Significado                                                        |
|---------|--------------------|----------------------------------------------------------------------|
| LEDR(0) | `Blinky`           | Pisca direto do `CLOCK_50`, sem relação com o core, "placa viva".  |
| LEDR(1) | `pll_locked`       | Deveria ficar **sempre aceso** depois de configurar a FPGA. Apagado = PLL nunca travou (ver `bugs/PLL_LOCK_LOSS_BUG.md`). |
| LEDR(2) | `FPGA_RESET_N`     | Aceso = botão físico de reset **solto**. Apagado = botão pressionado. |
| LEDR(3) | `not core_reset`   | Aceso = core fora de reset, rodando. Apagado = core em reset (PLL sem lock, ou botão pressionado). |
| LEDR(4-9) | (não usados)     | Livres: usados como latches de debug temporários durante o bring-up da placa, removidos depois de servirem seu propósito. |

Como diagnóstico rápido sem precisar abrir uma sessão JTAG: se LEDR(1) ou
LEDR(3) estiverem apagados, o problema está **antes** do core (PLL/reset);
nenhum teste vai rodar. Se ambos estão acesos e mesmo assim um teste não
passa, o problema está no software/lógica do core, não na configuração da
placa.

## Bugs reais encontrados neste redesign (resumo)

Dois bugs só apareceram em hardware real, nunca na simulação GHDL; ambos
documentados com o diagnóstico completo no histórico do projeto:

1. **Endereçamento de RAM via JTAG**: o In-System Memory Content Editor
   endereça a RAM como índice relativo (`(addr - ram_base) / 4`), não o
   endereço bruto da CPU; `core_fpga_test.vhd` mandava o endereço bruto
   direto pra RAM, sem subtrair `ram_base`. Funcionava por coincidência
   enquanto `ram_base` era sempre potência de 2 alinhada à própria RAM;
   quebrou na primeira vez que isso deixou de ser verdade. Fix:
   `RAM_BASE_WORD`, subtração explícita antes de indexar a RAM.
2. **Cópia de `.data` de FLASH pra RAM**: descrito acima em
   [FLASH precisa de uma segunda porta de leitura](#flash-precisa-de-uma-segunda-porta-de-leitura-o-limite-do-quartus-lite).

Ambos só afetavam leitura/verificação (JTAG ou `.data`), nunca a lógica
pura do pipeline; por isso a simulação GHDL (que ou lê os sinais crus do
barramento, ou nunca tinha `.data` não-vazio pra exercitar) nunca os pegou.
