# Bring-up da SDRAM da placa, sem o core

## 1. O que é

A plataforma `sdram-bringup` liga a SDRAM de 64 MB da DE0-CV (32M x 16, 143 MHz) a
um controlador e a um autoteste, sem o core. Serve para provar o que independe do
processador: os pinos, a fase do clock que vai ao chip, os tempos de entrada e
saída e o controlador. O core entra depois, com esta base já validada.

O projeto do Quartus fica em `platforms/sdram-bringup/quartus`. O controlador e o
autoteste vêm do repositório Memory, irmão deste.

## 2. Clocks

Um único PLL parte dos 50 MHz da placa e usa um VCO de 1000 MHz, de modo que a
mesma malha gera o clock da SDRAM e o clock de 50 MHz do core.

| Saída | Frequência | Fase | Uso |
| :--- | :--- | :--- | :--- |
| 0 | $1000/7 = 142{,}857$ MHz | 0 | controlador e autoteste |
| 1 | 142,857 MHz | 2750 ps | pino `DRAM_CLK` |
| 2 | 50 MHz | 0 | lado do core da ponte (não usado pelo autoteste) |

A fase da saída 1 é o único número que se ajusta na placa: ela decide em que
instante o chip vê o clock em relação aos comandos que o controlador lança e ao
dado que ele devolve.

## 3. Como usar

1. Compilar: `quartus_sh --flow compile sdram_bringup`, dentro de `platforms/sdram-bringup/quartus`.
2. Programar: `quartus_pgm -c "USB-Blaster [1-3]" -m JTAG -o "p;output_files/sdram_bringup.sof"`.
3. Rodar um teste pelo JTAG: `quartus_stp -t jtag/sdram_bist.tcl <modo> [<segundos>]`, de dentro de `platforms/sdram-bringup`.

Também dá para rodar pela placa: KEY0 inicia um teste e SW1:0 escolhem o modo.

| Modo | Teste | Palavras movidas |
| :--- | :--- | ---: |
| 0 | rápido: janela de $2^{16}$ palavras com dados que dependem do endereço e máscaras de byte | 458 752 |
| 1 | padrões: zeros, uns, `0xAAAAAAAA`, `0x55555555`, um e um zero andando, dado do endereço e seu complemento | 1 048 576 |
| 2 | varredura do chip inteiro ($2^{24}$ palavras), dado do endereço e seu complemento | 67 108 864 |
| 3 | endereços pseudo-aleatórios, $2^{20}$ palavras escritas e relidas | 2 097 152 |

O dado de cada palavra depende do endereço e nunca se repete dentro do chip, então
uma linha de endereço presa ou trocada leva o dado de uma palavra para outra e é
detectada. O modo 0 também confere que um byte mascarado mantém o valor antigo.

## 4. Leitura do resultado

| Sinal | Significado |
| :--- | :--- |
| LEDR0 | PLL travado |
| LEDR1 | SDRAM inicializada |
| LEDR2 | teste em andamento |
| LEDR3 | terminou sem palavra errada |
| LEDR4 | houve palavra errada |
| LEDR5 | o controlador não respondeu |
| LEDR9:6 | fase do teste |

A sonda JTAG (In-System Sources and Probes) traz o resultado completo: as flags,
as palavras movidas, as palavras erradas e, da primeira errada, o endereço, o
dado esperado e o dado lido.

## 5. Resultado na placa

| Modo | Palavras movidas | Palavras erradas |
| :--- | ---: | ---: |
| 0 | 458 752 | 0 |
| 1 | 1 048 576 | 0 |
| 2 | 67 108 864 (cerca de 6 s) | 0 |
| 3 | 2 097 152 | 0 |

Com a fase de 2750 ps, o chip enxerga o comando no mesmo número de borda em que o
controlador o lançou, e o dado volta um ciclo antes do que o modelo de simulação
supõe. Por isso, na placa, o dado lido nos pinos é amostrado sem o ciclo extra
que o modelo usa quando os pinos passam por um registrador. Com o ciclo extra, as
duas metades de cada palavra recebiam a segunda metade do burst (196 352 palavras
erradas de 196 608 lidas no modo 0).

## 6. Timing

Margens do Quartus com as restrições de entrada e saída do chip. Os tempos do chip
são **provisórios** (valores usuais de uma SDR de 143 MHz, ainda não conferidos com
o datasheet): setup de entrada 1,5 ns, hold de entrada 0,8 ns, acesso após o clock
de 5,4 ns e hold de saída de 2,5 ns.

| Verificação | Modelo lento (85 C) | Modelo rápido |
| :--- | ---: | ---: |
| Lógica interna a 143 MHz, setup | +1,01 ns | +4,25 ns |
| Comandos e dado de escrita, setup | -0,05 ns | +0,53 ns |
| Comandos e dado de escrita, hold | +2,97 ns | +3,02 ns |
| Dado de leitura, setup | -0,20 ns | +2,09 ns |

No modelo lento, o pior caso com os tempos provisórios fica 0,2 ns abaixo de zero;
no modelo rápido e na placa tudo fecha. Os tempos do datasheet fecham a conta.
