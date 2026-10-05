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

## 3. Onde ler mais

O documento `SDRAM_RAM_FASE1.md` descreve a arquitetura, o protocolo da porta de debug, o
runtime, a simulação, os comandos de uso e os resultados medidos, e a pasta `docs/bugs` guarda
as falhas encontradas no caminho.
