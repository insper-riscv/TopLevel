# Barramento de periférico e UART por JTAG (fase 2)

## 1. Visão geral

Na plataforma `sdram` a SDRAM é a RAM do core (64 MB a partir de `0x40000000`) e o host alcança a
memória por uma porta de debug JTAG. Este documento descreve o que se soma a isso: o core passa a
ter, na mesma porta de dado externa da SDRAM, uma **janela de periférico**, e o primeiro periférico
é uma **UART cuja outra ponta é o host, por JTAG**. Um programa imprime com `printf` e o PC mostra a
saída enquanto o programa roda, ou trava.

| O que | Antes | Agora |
| :--- | :--- | :--- |
| Porta externa de dado do core | só a SDRAM | a SDRAM e as janelas de periférico, decididas pelo endereço |
| Saída do programa | buffer de 1 KB na SDRAM, lido pelo host depois do fim | o mesmo buffer, mais um fluxo ao vivo pela UART |
| Entrada para o programa | nenhuma | bytes que o host escreve na UART |
| Instâncias de JTAG virtual | 1 (porta de debug) | 2 (porta de debug e UART) |

A saída em memória continua sendo a cópia que o teste confere. A UART é uma visão ao vivo, e é a que
mostra o que um programa escreveu antes de travar sem que o host precise esperar o fim.

## 2. O barramento de periférico

Todo acesso de dado do core a um endereço a partir de `0x40000000` sai pela porta externa, que tem
um sinal `ready`: com `ready` em 0 o pipeline para na etapa de memória. Atrás da porta há um
decodificador, o interconnect, que olha o endereço e escolhe quem responde.

```
  core --- porta externa (endereço, dado, ready) ---> interconnect
                                                         |
                       bit 31 = 0 -----------------------+---------------> ponte da SDRAM
                       bit 31 = 1, id = bits 30:28 ------+---> UART (id 4)
                                                         +---> demais janelas: sem resposta
```

| Faixa | Quem responde | `ready` |
| :--- | :--- | :--- |
| bit 31 = 0 (a partir de `0x40000000`) | ponte da SDRAM | o da ponte, de vários ciclos |
| bit 31 = 1, id 4 (`0xC0000000`) | UART | um ciclo, depois nível até o pipeline andar |
| bit 31 = 1, outro id | ninguém | um ciclo; a leitura devolve 0 e a escrita não tem efeito |

O id é o campo `addr(30:28)` e o deslocamento dentro da janela é a palavra `addr(9:2)`. Os ids
reservados são 1 (LEDs), 2 (GPIO), 3 (TIMER) e 4 (UART); só o 4 existe nesta plataforma.

### 2.1 O acesso de um ciclo

Um acesso a periférico gera um único pulso de leitura ou de escrita para o periférico, mesmo que o
pipeline fique parado depois por outro motivo (uma divisão em andamento, por exemplo). Sem isso uma
leitura que retira um byte da fila retiraria vários. O `ready` fica em 1 como nível até o sinal de
avanço do pipeline, como a SDRAM já exige.

### 2.2 O dado de um load

O dado lido é copiado quando o load avança, e a escolha de qual escravo o originou é registrada na
mesma borda. Enquanto o load está na última etapa o acesso seguinte já está na porta, e não pode
alterar o dado dele. Um teste cobre exatamente esse caso: um segundo acesso ao periférico, ainda em
andamento, não muda o valor que o load anterior vê.

## 3. A UART por JTAG

### 3.1 Registradores do core

O core vê três registradores de palavra a partir de `0xC0000000`.

| Endereço | Nome | Leitura | Escrita |
| :--- | :--- | :--- | :--- |
| `0xC0000000` | TXDATA | 0 | enfileira os bits 7:0 para o host; se a fila está cheia o byte é descartado e a falha é marcada |
| `0xC0000004` | RXDATA | bit 8 = havia um byte, bits 7:0 = o byte, que é retirado; 0 se vazia | ignorada |
| `0xC0000008` | STATUS | veja abaixo | ignorada |

| Bits do STATUS | Significado |
| :--- | :--- |
| 7:0 | lugares livres na fila de transmissão, de 0 a 64 |
| 15:8 | bytes esperando na fila de recepção, de 0 a 64 |
| 16 | um byte foi descartado desde a última leitura do STATUS (a leitura limpa o bit) |
| 17 | algum host já varreu a UART desde o reset |

As filas têm 64 bytes em cada sentido. Escrever numa fila cheia nunca trava o core.

### 3.2 O registrador do host

A UART é a segunda instância de JTAG virtual do projeto (a porta de debug da SDRAM é a primeira). O
registrador de instrução tem 2 bits, e a instrução 1 seleciona um registrador de dados de 48 bits.

| Sentido | Bits | Significado |
| :--- | :--- | :--- |
| entra | 8 | enviar: entregar ao core o byte abaixo |
| entra | 7:0 | o byte (só vale se o bit 8 for 1) |
| sai | 31:0 | até quatro bytes que o core enviou, o primeiro nos bits 7:0 |
| sai | 34:32 | quantos desses bytes são válidos |
| sai | 35 | o byte entregue pelo comando foi descartado (fila de recepção cheia) |
| sai | 36 | a varredura anterior foi descartada: o comando antes dela não tinha terminado |
| sai | 47:40 | bytes que ainda esperam na fila de transmissão |

Cada varredura aceita é um comando: ela retira até quatro bytes da fila de transmissão e, se o bit 8
estava em 1, coloca um byte na fila de recepção. O clock da cadeia JTAG só corre durante uma
varredura, então a resposta de um comando chega à lógica de varredura durante a varredura seguinte e
é mostrada pela que vem depois dela: **uma varredura mostra a resposta ao comando de duas
varreduras antes**. A resposta aparece uma vez só. Um host que quer a saída varre sem parar; um que quer enviar
um byte liga o bit 8 numa varredura.

A travessia entre o clock do JTAG e o do core usa um sinal que muda de valor a cada comando, passando
por dois flip-flops; o byte e a bandeira de envio ficam parados até o próximo comando aceito.

### 3.3 Quem escreve quando

| Situação | Comportamento do programa |
| :--- | :--- |
| nenhum host varreu a UART | não imprime na UART, e portanto nunca espera |
| um host está ouvindo | espera um lugar livre na fila, até 200 000 consultas do STATUS, e então descarta o byte |
| o programa imprime mais rápido que o host lê | os bytes que não cabem são descartados na UART; o buffer na SDRAM guarda todos até 1 KB |

## 4. O runtime

O `stdio` do programa escreve cada caractere no buffer de `stdout` na SDRAM, como na fase 1, e
também o entrega à UART pela regra da seção 3.3. O build para o Spike não tem a UART e pula essa
parte. O código de saída **não** vai pela UART: um byte de controle no meio do fluxo corromperia a
saída, e o resultado já chega ao host pelo mailbox, que a porta de debug lê mesmo com o programa
travado.

| Palavra do host | Onde está |
| :--- | :--- |
| `stdout`, `tohost`, `fromhost`, `go flag`, mailbox | na SDRAM, como na fase 1 |
| UART | janela `0xC0000000`, fora da RAM |

A fila de transmissão não é esvaziada quando um programa novo começa; ela só é zerada no reset. O
console consome a fila continuamente, então na prática o que sobra de um programa é descartado pelo
próprio host antes do seguinte.

## 5. Simulação e verificação

O topo de simulação da plataforma coloca o interconnect e a UART entre o core e a SDRAM, e expõe os
sinais da instância de JTAG virtual da UART. O testbench lê a UART **durante cada programa**, do jeito
que um console de verdade o faz: uma corrotina varre o registrador de 48 bits em sequência e
recolhe os bytes. No PASS, o que ela recolheu tem de ser o que o programa escreveu no buffer de
`stdout` na SDRAM: o fluxo da UART começa com todos os bytes do buffer e, se o buffer não estourou,
tem o mesmo tamanho.

| Verificação | Resultado |
| :--- | :--- |
| 89 programas existentes, SDRAM como RAM, UART conferida em cada um | 89 passam |
| controle negativo: o byte enviado à UART trocado por `c + 1` | `stdout-printf` e `stdout-truncate` falham |
| testes do interconnect e da UART no GHDL (Memory) | 11 passam; dois defeitos injetados no interconnect (pulso repetido e dado sobrescrito) falham os testes |
| teste do core com um acesso em `0xC0000000` | passa com latências de 0 a 9 ciclos |

O teste `stdout-truncate` escreve 1 025 bytes e é o que mais exercita o descarte e a espera.

## 6. Comandos

Ver a saída de um programa, com a placa programada:

```bash
riscv-tools --config <config> console --seconds 10
```

Sem `--seconds` o console escuta até Ctrl-C. `--send TEXTO` entrega bytes ao programa no início.
Como um programa só imprime na UART depois que um host a varreu, inicie o console antes de carregar
o programa, ou antes de acionar o `go flag` de um que já está carregado.

Exemplo medido na placa, com o `stdout-printf`: o console foi ligado por 4 s, o teste foi rodado com
`run --skip-reconfigure --manifest <só o teste>`, e um segundo console devolveu

```
hello riscv c
second line
x
```

que é a saída do programa. O resto do fluxo de teste (`run`, `dump-ram`, `zero-ram`, `mailbox`) não
mudou, porque usa a porta de debug da SDRAM.

## 7. Resultados medidos

| Item | Valor |
| :--- | :--- |
| Provas na simulação | 89 existentes e 6 da SDRAM passam |
| Provas na placa | 89 passam |
| Varreduras do console por segundo | cerca de 3 200 |
| Vazão do console, da placa para o host | cerca de 13 KB/s (4 bytes por varredura) |
| Vazão do host para a placa | 1 byte por varredura, cerca de 3 KB/s |
| Latência de um acesso ao periférico | 1 ciclo do core mais a espera pelo avanço do pipeline |
| Compilação do Quartus | sem erros |

### 7.1 Timing do Quartus

| Domínio | Folga de setup no modelo lento |
| :--- | :--- |
| clock do controlador | $-0{,}204$ ns |
| `DRAM_CLK` (entrada de dado do chip) | $-0{,}047$ ns |
| clocks do core | $+2{,}029$ ns |
| clock do JTAG | $+10{,}776$ ns |

As duas folgas negativas são as mesmas da fase 1: são os caminhos da interface com o chip, calculados
com tempos provisórios do chip, e mudam quando a tabela AC do datasheet entrar. A UART e o
interconnect não aparecem entre os caminhos críticos, e a travessia entre o clock do JTAG e o do core
tem a mesma restrição de atraso máximo e mínimo da porta de debug.

## 8. Limites

- A UART entrega quatro bytes por varredura e recebe um, e a varredura é limitada pelo cabo JTAG.
  Um programa que imprime em rajada além de 64 bytes e de 13 KB/s perde bytes na UART; o buffer na
  SDRAM continua com os primeiros 1 024.
- Uma resposta é mostrada duas varreduras depois do comando, então a saída de um programa que
  termina aparece com essa latência: o console varre algumas vezes depois do último byte.
- Só existe uma UART. Os ids 1 a 3 estão reservados e sem periférico.
- O mailbox, o `tohost` e o `go flag` seguem em memória; nada migrou para a UART.
- Uma cache L1 de dado entre o core e o interconnect deve deixar passar sem cache todo acesso com o
  bit 31 em 1: ler um registrador de periférico tem efeito colateral.

## 9. Leitura complementar

O documento da fase 1 (`SDRAM_RAM_FASE1.md`) descreve a SDRAM como RAM, a porta de debug e o mapa de
memória; este se entende sem ele, mas a fase 1 dá o resto do contexto. O `EXTERNAL_BUS.md` do Memory
tem o mesmo protocolo da UART do lado do repositório que o implementa, e a pasta `docs/bugs` do
Memory guarda o bug da resposta perdida, que nasce de o clock do JTAG só correr durante uma
varredura.
