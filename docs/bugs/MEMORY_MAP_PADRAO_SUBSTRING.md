# A verificação do mapa de memória leu a SDRAM como se fosse a RAM

## 1. Resumo

A verificação do mapa de memória confere a base da RAM escrita no VHDL do core contra o
mapa da plataforma, procurando a constante por um padrão de texto. Quando o core ganhou a
constante da base da SDRAM, o padrão da RAM passou a casar com ela também.

| | |
| :--- | :--- |
| Sintoma | `check-memory-map` acusa "esperava a base da RAM (0x8000), achei 0x40000000" |
| Causa | o nome da constante da RAM está contido no nome da constante da SDRAM, e o padrão não marca o início da palavra |
| Correção | o padrão passa a começar numa fronteira de palavra |
| Impacto evitado | a verificação da plataforma `internal-mem` quebraria sozinha assim que o core com a SDRAM fosse integrado |

## 2. O mecanismo

O core declara uma constante para a base da RAM interna e, agora, outra para a base da SDRAM.
O nome da segunda termina exatamente com o nome da primeira:

| Constante | Valor | Nome |
| :--- | :--- | :--- |
| base da RAM interna | `0x8000` | termina em `RAM_BASE_BYTES` |
| base da SDRAM | `0x40000000` | termina em `RAM_BASE_BYTES`, com `SD` na frente |

O padrão que procurava a primeira não exigia que o nome começasse ali. A busca pegou a
primeira ocorrência do texto no arquivo; como a da SDRAM aparece antes, o valor lido foi
`0x40000000`.

## 3. Quando acontece

Só depois que o core declara as duas constantes. Antes disso o padrão casava uma única
vez e a verificação passava.

## 4. A correção

O padrão dos dois mapas (o da `internal-mem` e o da `sdram`) passou a exigir uma fronteira de
palavra antes do nome. Uma fronteira não existe entre `D` e `R` dentro de `SDRAM`, então só a
constante da RAM casa.

## 5. Como a prova aparece

| Situação | Resultado |
| :--- | :--- |
| padrão antigo, core com as duas constantes | 1 divergência |
| padrão novo, mesmo core | `internal-mem`: 43 verificações ok; `sdram`: 47 ok |

## 6. Como evitar

Um padrão que procura um nome em código-fonte deve marcar o início e o fim da palavra. Todo
nome novo que contém um nome antigo (ou é contido por ele) pode desviar uma busca por texto.
