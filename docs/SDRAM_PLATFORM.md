# Plataforma com a SDRAM como RAM

## 1. O que é

A plataforma `sdram` usa os 64 MB de SDRAM da DE0-CV (32M x 16, 143 MHz) como **a RAM** do
core. Não existe RAM dentro da FPGA: `.data`, `.bss`, o heap, a pilha e as palavras que o host
compartilha com o programa (mailbox, `tohost`, `fromhost`, `go flag` e `stdout`) estão na
SDRAM. A BOOT_ROM e a FLASH continuam dentro da FPGA, porque o core busca instruções nelas.

A memória que a `internal-mem` usa como RAM (a IP `RAM1PORT`) fica reservada no repositório
Memory para uma cache L1 de dado futura, entre o core e a SDRAM.

O host alcança a SDRAM por uma porta de debug JTAG, um segundo mestre do controlador. Ela
funciona com o core rodando, parado ou travado.

## 2. Mapa de memória

| Região | Base | Tamanho | Uso |
| :--- | :--- | :--- | :--- |
| BOOT_ROM | `0x00000000` | 2 KB | bootloader |
| FLASH | `0x00000800` | 30 KB | programa |
| RAM (SDRAM) | `0x40000000` | 64 MB | dado, pilha, heap |

As palavras do host ficam no topo da RAM:

| Palavra | Endereço |
| :--- | :--- |
| `stdout` (1 KB mais 8 bytes) | `0x43FFFBE0` |
| `tohost` e `fromhost` | `0x43FFFFE8` e `0x43FFFFF0` |
| `go flag` | `0x43FFFFF8` |
| mailbox | `0x43FFFFFC` |

O `platform.yaml` é a fonte de verdade, e o `check-memory-map` confere contra ele cada cópia
desses números: a configuração, o runtime, o VHDL do core, o testbench e o header dos programas.

## 3. Indicadores da placa

### 3.1 LEDs vermelhos

Os LEDR9 a LEDR4 mostram o perfil do core gravado na FPGA, um LED por extensão, aceso quando a
extensão está presente. O LEDR0 indica falha na execução em curso. Os LEDR3 a LEDR1 ficam
apagados, porque os LEDs nativos da placa já indicam que a FPGA está configurada e que a SDRAM
responde.

| LED | Significado | Aceso quando |
| :--- | :--- | :--- |
| LEDR9 | Zicclsm | load e store desalinhados executados pelo hardware |
| LEDR8 | Zifencei | `fence.i` |
| LEDR7 | Zicsr | CSRs e traps do modo máquina |
| LEDR6 | Zmmul | só multiplicação; apagado com M, que já a inclui |
| LEDR5 | A | atômicas; o core não a implementa, então fica sempre apagado |
| LEDR4 | M | multiplicação e divisão |
| LEDR3 a LEDR1 | sem uso | nunca |
| LEDR0 | Falha | pelo menos um programa da execução em curso falhou |

Os níveis dos LEDR9 a LEDR4 vêm das constantes `HAS_*` do topo `core_fpga_sdram`, as mesmas que
configuram o core, de modo que o LED e o hardware não divergem.

O LEDR0 mostra uma bandeira que o hospedeiro grava no registrador do display por uma instrução
própria do Virtual JTAG (a instrução 2, um registrador de 2 bits: o bit 0 é o valor e o bit 1
habilita a gravação). O `riscv-tools run` e o `certify-board` apagam a bandeira ao começar uma
sessão e a acendem quando um programa ou um ELF falha ou esgota o tempo. A bandeira não é apagada
pelo reset do core nem pelo fim da execução; só uma nova sessão ou a reconfiguração da FPGA a
apaga. Os dois executores só a escrevem quando a configuração liga `board_display`.

### 3.2 Display de sete segmentos

O registrador do display (periférico 5, `0xD0000000`) guarda 24 bits que os seis dígitos HEX5 a
HEX0 mostram em hexadecimal. Os dois executores do hospedeiro escrevem nele o número do programa
em curso, contado em decimal a partir de 1.

| Executor | HEX5 a HEX4 | HEX3 a HEX0 | Exemplo |
| :--- | :--- | :--- | :--- |
| ACT4 (`certify-board`) | `AC` | número do ELF | `AC0001` a `AC0059` |
| Programas próprios (`run`) | número do programa, nos seis dígitos | | `000001` a `999999` |

O programa `hex-id`, que roda com `--only`, identifica os dígitos: acende um `A` por vez de HEX0 a
HEX5 e termina deixando `543210`, de modo que cada dígito mostra a própria posição.

## 4. Onde ler mais

O documento `SDRAM_RAM_FASE1.md` descreve a arquitetura, o protocolo da porta de debug, o
runtime, a simulação, os comandos de uso e os resultados medidos, e a pasta `docs/bugs` guarda
as falhas encontradas no caminho.
