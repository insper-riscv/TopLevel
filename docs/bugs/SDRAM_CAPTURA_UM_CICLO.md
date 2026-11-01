# A leitura da SDRAM na placa chegava um ciclo antes do que a simulação supunha

## 1. Resumo

O controlador passou em todas as simulações e, na primeira execução na placa, devolveu
palavras erradas: as duas metades de cada palavra vinham iguais à segunda metade.

| | |
| :--- | :--- |
| Sintoma | no modo rápido do autoteste, 196 352 das 196 608 palavras lidas vieram erradas; no endereço 0, esperado `0x00A5C35A`, lido `0x00A500A5` |
| Causa | com a fase escolhida para o clock do chip, o dado de leitura chega um ciclo mais cedo do que o modelo de simulação supõe |
| Correção | amostrar o dado de leitura um ciclo antes na placa (sem o ciclo extra que o modelo usa quando o pino passa por um registrador) |
| Resultado | os quatro modos do autoteste passam, inclusive a varredura de 67 108 864 palavras |

## 2. O mecanismo

Uma leitura de palavra é um burst de duas metades de 16 bits. O controlador as amostra em
dois ciclos consecutivos, um número fixo de ciclos depois do comando.

| Ambiente | O que o modelo supõe | O que acontece |
| :--- | :--- | :--- |
| simulação | o chip vê o comando na borda seguinte à que o controlador o lançou, e devolve o dado três ciclos depois | o dado de leitura fica nos pinos exatamente onde o controlador o amostra |
| placa, fase de 2750 ps | o clock que chega ao chip está defasado em relação ao do controlador, e o chip vê o comando na borda de mesmo número em que ele foi lançado | o dado chega um ciclo antes |

Com o dado um ciclo antes, a amostra do primeiro ciclo pegava a segunda metade do burst, e a
amostra do segundo ciclo pegava um valor que o barramento ainda segurava (a mesma segunda
metade). As duas metades da palavra ficavam iguais, que é o que o teste mostrou.

## 3. Por que a simulação não viu

O modelo do chip e o controlador compartilham a mesma convenção de tempo, e a defasagem do
clock que vai ao chip não existe na simulação: lá o clock é o mesmo. A única coisa que
distingue os dois casos é a fase real do clock na placa.

## 4. A correção

No topo da placa o controlador amostra o dado sem o ciclo extra de captura. O registrador
que o Quartus coloca na célula de I/O do pino de dado continua lá; só o número de ciclos de
espera antes de ler o resultado diminui. O valor certo depende da fase do clock do chip, que é
o único parâmetro que se ajusta na placa.

## 5. Como a prova aparece

| Captura | Palavras erradas, modo rápido |
| :--- | ---: |
| com o ciclo extra | 196 352 de 196 608 |
| sem o ciclo extra | 0 |

## 6. Como evitar

Um valor de latência que depende de fase de clock não se valida só em simulação. Na primeira
execução na placa de um controlador de memória externa, o autoteste deve ser o primeiro
passo, e a captura deve ser um parâmetro com o valor medido, não uma suposição.
