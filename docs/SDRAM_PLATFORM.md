# Plataforma com a SDRAM

## 1. O que é

A plataforma `sdram` é a `internal-mem` com os 64 MB de SDRAM da DE0-CV (32M x 16,
143 MHz) ligados ao core como memória de dados. A BOOT_ROM, a FLASH e a RAM de
dentro da FPGA, o runtime e as flags do linker são os da `internal-mem`, sem mudança:
`.data`, `.bss`, o heap e a pilha dos programas continuam na RAM interna, e o
programa alcança a SDRAM num endereço fixo.

O core não busca instruções na SDRAM; ela é só dado.

## 2. Mapa de memória

| Região | Base | Tamanho | Uso |
| :--- | :--- | :--- | :--- |
| BOOT_ROM | `0x00000000` | 2 KB | bootloader |
| FLASH | `0x00000800` | 30 KB | programa |
| RAM | `0x00008000` | 160 KB | dado, pilha, heap |
| SDRAM | `0x40000000` | 64 MB | dado (`RV32_SDRAM_BASE` em `rv32_sdram.h` do Tests) |

O `platform.yaml` é a fonte de verdade, e o `check-memory-map` confere contra ele a
base e o tamanho da SDRAM na configuração e no VHDL do core.

## 3. Clocks

Um único PLL parte dos 50 MHz da placa e usa um VCO de 1000 MHz.

| Saída | Frequência | Fase | Uso |
| :--- | :--- | :--- | :--- |
| 0 | $1000/7 = 142{,}857$ MHz | 0 | controlador da SDRAM |
| 1 | 142,857 MHz | 2750 ps | pino `DRAM_CLK` |
| 2 | 50 MHz | 0 | memórias de instrução |
| 3 | 50 MHz | 6625 ps | core e memórias de dado |

O passo de fase de um VCO de 1000 MHz é de 125 ps, e por isso a saída 3 usa 6625 ps (cerca de 119 graus) no
lugar dos 6667 ps (120 graus) que o Quartus recusa.

O core e o controlador ficam em clocks sem relação fixa de fase. O cruzamento é
feito por uma ponte com dois flip-flops de sincronização em cada sentido.

## 4. Como o core espera a SDRAM

Quando o estágio de memória tem um acesso à SDRAM, o pipeline inteiro pára até a ponte
sinalizar que o acesso terminou; o sinal fica em nível até o pipeline andar. O dado
lido só muda na borda em que o pipeline anda. Com o core a 50 MHz, o acesso custa
cerca de 5 a 8 ciclos do core. Um desvio tomado que esteja em execução durante a
espera é mantido, e o flush e o redirecionamento acontecem quando o pipeline volta a
andar.

## 5. Como usar

Simulação (GHDL, na imagem de toolchain), a partir do projeto de testes:

1. Programas existentes na plataforma nova: `riscv-tools --config tools/riscv_build/config.sdram-regression.yaml compile --emit hex`, depois `sim`.
2. Programas que usam a SDRAM: o mesmo com `config.sdram.yaml`.

Placa:

1. Compilar o projeto: `quartus_sh --flow compile core_fpga_sdram`, dentro de `platforms/sdram/quartus`.
2. Gerar as imagens na imagem de toolchain (`compile --emit mif`) e rodar com `riscv-tools --config <config> run`.

A SDRAM só inicializa depois de cerca de 200 microssegundos de espera após o PLL
travar; um acesso feito antes disso espera a inicialização. O LEDR4 acende quando ela terminou.

## 6. Resultado

| Verificação | Resultado |
| :--- | :--- |
| Programas da SDRAM na simulação (6) | 6 passam |
| Programas existentes na simulação com a SDRAM (89) | 89 passam |
| Programas da SDRAM na placa (6) | 6 passam |
| Programas existentes na placa com a SDRAM (89) | 89 passam |

Os seis programas da SDRAM conferem a si mesmos: o barramento de dados e de endereço,
acessos de byte e de meia palavra, cópias entre RAM e SDRAM, laços que carregam da
SDRAM e voltam com um desvio, multiplicações e divisões com operandos da SDRAM, e a
retenção do dado depois de muitos períodos de refresh.

Dois defeitos injetados no core fazem esses programas falharem: ignorar o sinal de
espera derruba os seis, e perder o desvio tomado durante a espera derruba os de cópia
e de multiplicação e divisão.

## 7. Timing

Margens do Quartus. Os tempos do chip nas restrições são **provisórios** (valores
usuais de uma SDR de 143 MHz, ainda não conferidos com o datasheet).

| Verificação | Modelo lento (85 C) | Modelo rápido |
| :--- | ---: | ---: |
| Lógica do controlador, setup | +2,21 ns | +4,78 ns |
| Core a 50 MHz, setup | +3,67 ns | +12,15 ns |
| Ponte, controlador para core, setup | +7,52 ns | +8,61 ns |
| Ponte, core para controlador, setup | +5,01 ns | +7,31 ns |
| Dado de leitura entrando no controlador, setup | -0,19 ns | +2,09 ns |
| Comandos e dado de escrita, setup | -0,06 ns | +0,53 ns |
| Comandos e dado de escrita, hold | +2,99 ns | +3,03 ns |

No modelo lento, a interface com o chip fica até 0,2 ns abaixo de zero com os tempos
provisórios; no modelo rápido e na placa tudo fecha. O datasheet fecha a conta.
