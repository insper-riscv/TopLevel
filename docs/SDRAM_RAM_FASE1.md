# SDRAM como RAM, com porta de debug por JTAG (fase 1)

## 1. Visão geral

Na plataforma `sdram` a SDRAM da DE0-CV (32M x 16, 64 MB, 143 MHz) é **a RAM** do core. Não
existe RAM dentro da FPGA: `.data`, `.bss`, o heap, a pilha e as palavras que o host
compartilha com o programa ficam na SDRAM. A BOOT_ROM (2 KB) e a FLASH (30 KB) continuam
dentro da FPGA, porque o core busca instruções nelas e a busca de instrução não espera memória.

A memória que a plataforma `internal-mem` usa como RAM (160 KB, uma IP do Quartus) fica
reservada no repositório Memory para ser o armazenamento de uma **cache L1 de dado** no futuro,
entre o core e a SDRAM.

O host (o PC) alcança a SDRAM por uma **porta de debug JTAG**, um segundo mestre do controlador.
Ela lê e escreve qualquer palavra com o core rodando, parado ou travado, e é o que o dump, o
mailbox, o `go flag` e o `zero-ram` usam no lugar do editor de memória do Quartus, que só
enxerga memória interna.

## 2. Arquitetura

```
   core (50 MHz)                      clock do controlador (142,857 MHz)             pinos
  +------------+    ponte            +---------+    +-------------+    +---------+
  | estágio    |--- toggles, ready -->| árbitro |--->| controlador |--->|  SDRAM  |
  | de memória |<-- dado, ready ------|         |<---|  da SDRAM   |<---|  chip   |
  +------------+                      |    ^    |    +-------------+    +---------+
                                      |    |    |
  host --JTAG--> núcleo JTAG --toggles--> mestre de debug
  (TCK)                                    (controlador)
```

| Bloco | Clock | Função |
| :--- | :--- | :--- |
| ponte | core, 50 MHz | leva um acesso do core ao controlador por toggles com sincronizadores de dois flip-flops, segura o `ready` e confirma o dado lido |
| árbitro | controlador | serve o core e o mestre de debug, um pedido por vez, alternando quando os dois esperam |
| controlador | controlador | página fechada com auto-precharge, burst de 2 (uma palavra de 32 bits), CAS 3, refresh a 90 por cento do intervalo |
| mestre de debug | controlador | executa os comandos do host: ler, escrever, preencher |
| núcleo JTAG | TCK do JTAG | os registradores da porta e a entrega dos comandos ao mestre de debug |

O PLL parte dos 50 MHz da placa com um VCO de 1000 MHz:

| Saída | Frequência | Fase | Uso |
| :--- | :--- | :--- | :--- |
| 0 | $1000/7 = 142{,}857$ MHz | 0 | controlador, árbitro e mestre de debug |
| 1 | 142,857 MHz | 2750 ps | pino `DRAM_CLK` |
| 2 | 50 MHz | 0 | memórias de instrução |
| 3 | 50 MHz | 6625 ps | core |

O passo de fase de um VCO de 1000 MHz é de 125 ps, e por isso a saída 3 usa 6625 ps (cerca de
119 graus) no lugar de 6667 ps (120 graus), que o Quartus recusa.

## 3. Mapa de memória

| Região | Base | Tamanho | Uso |
| :--- | :--- | :--- | :--- |
| BOOT_ROM | `0x00000000` | 2 KB | bootloader |
| FLASH | `0x00000800` | 30 KB | programa |
| RAM (SDRAM) | `0x40000000` | 64 MB | dado, pilha, heap |

As palavras do host ficam no topo da RAM, fora do espaço que o linker dá ao programa:

| Palavra | Endereço |
| :--- | :--- |
| `stdout`: tamanho, truncado, 1 KB de dados | `0x43FFFBE0` |
| `tohost`, `fromhost` | `0x43FFFFE8`, `0x43FFFFF0` |
| `go flag` | `0x43FFFFF8` |
| mailbox (1 = PASS, 2 = FAIL) | `0x43FFFFFC` |

O linker coloca `.data`, `.bss` e o heap a partir de `0x40000000` e a pilha no topo, com
$64\,\text{MB} - 1056$ bytes de espaço (1056 bytes são das palavras do host). A pilha cresce para
baixo, o heap para cima.

O `platform.yaml` é a fonte de verdade e o `check-memory-map` confere contra ele cada cópia
desses números: a configuração, o runtime, o linker, o VHDL do core, o testbench e o header dos
programas de teste.

## 4. O caminho de um acesso

O core decodifica o endereço no estágio de memória. De `0x40000000` a `0x43FFFFFF` o acesso vai
pela porta externa de dado; abaixo de `0x8000` é a FLASH (leitura de dado); o resto não tem
memória.

1. O estágio de memória põe endereço, dado, máscara de bytes e o pedido de leitura ou escrita na
   porta externa e **para o pipeline inteiro** enquanto o sinal `ready` está em 0.
2. A ponte copia o acesso e inverte um toggle. O árbitro, no clock do controlador, vê o toggle
   depois de dois ciclos de sincronização.
3. O controlador ativa a linha, lê ou escreve a palavra em dois ciclos de 16 bits e inverte o
   toggle de resposta.
4. A ponte vê a resposta (dois ciclos do clock do core) e põe `ready` em 1. O `ready` **fica em
   1 como nível até o pipeline andar**, porque o muldiv também pode estar parando o pipeline e um
   pulso de um ciclo se perderia.
5. O dado lido só muda na borda em que o pipeline anda, porque o load anterior que ainda está em
   WB lê o valor antigo até então.

O custo medido de um acesso é de **5 a 6 ciclos do core** (a 56 ns de clock de core, no teste
de entidade), e no máximo 7 com o mestre de debug ocupando o controlador em um preenchimento
longo. Um desvio tomado que esteja em execução durante a espera é mantido, e o flush e o
redirecionamento do PC acontecem quando o pipeline volta a andar.

## 5. A porta de debug por JTAG

### 5.1 Registradores

A instância de JTAG virtual tem um registrador de instrução de 2 bits. A instrução 1 seleciona o
registrador de dados DEBUG, de 64 bits; qualquer outra instrução deixa um bypass de 1 bit.

Deslocado para dentro (do host para a placa), bit menos significativo primeiro:

| Bits | Campo | Significado |
| :--- | :--- | :--- |
| 63:60 | op | o comando |
| 59:56 | be | máscara de bytes de uma escrita: o bit $i$ habilita o byte $i$ |
| 55:32 | addr | endereço de palavra, contado em palavras de 32 bits a partir da base da SDRAM |
| 31:0 | data | o valor a escrever, ou a contagem de um preenchimento |

Deslocado para fora (da placa para o host):

| Bits | Campo | Significado |
| :--- | :--- | :--- |
| 63:56 | status | ver abaixo |
| 55:32 | word | a palavra acessada por último |
| 31:0 | data | o que a última leitura devolveu |

| Bit do status | Significado |
| :--- | :--- |
| 0 busy | o comando anterior não terminou: `word` e `data` ainda não valem |
| 1 error | o controlador não respondeu |
| 2 inicializada | a SDRAM terminou a sequência de partida |
| 3 overrun | um comando chegou com a porta ocupada e foi descartado |

O comando sai quando o deslocamento termina. O status de um comando só está em dia alguns
ciclos de TCK depois, então o primeiro deslocamento depois de um comando pode ainda mostrar
busy, e o seguinte não.

### 5.2 Comandos

| op | Nome | Efeito |
| ---: | :--- | :--- |
| 0 | status | não envia nada, só lê o status |
| 1 | ler | lê a palavra em `addr` |
| 2 | escrever | escreve `data` na palavra em `addr`, bytes por `be` |
| 3 | preencher | escreve `data` (todos os bytes) em `count` palavras a partir de `addr` |
| 4 | contagem | `count` $=$ `data[24:0]`, até $2^{24}$ palavras, a SDRAM inteira |
| 5 | ler a próxima | lê a palavra seguinte à acessada por último |
| 6 | escrever a próxima | escreve `data` na palavra seguinte, bytes por `be` |

O preenchimento roda sozinho no clock do controlador: não precisa de um deslocamento por palavra.

### 5.3 Uma leitura, passo a passo

Ler a palavra `0x123456`:

1. carregar a instrução 1 (uma vez);
2. deslocar `0x1000000000123456` + `00000000` no DEBUG: op 1, be `0` (ignorado), addr `0x123456`;
3. deslocar op 0 até o status mostrar busy igual a 0 (normalmente no segundo deslocamento);
4. o deslocamento que achou busy igual a 0 traz em `word` o endereço lido e em `data` o valor.

Medido na placa: cerca de **0,85 ms por leitura** dentro de uma sessão do `quartus_stp`; um
dump de 1024 palavras leva 1,5 s com a partida do processo.

## 6. Como o `riscv-tools` usa a porta

A chave `quartus.ram_backend: sdram_debug` na configuração da plataforma faz o `riscv-tools`
alcançar a RAM por essa porta no lugar do editor de memória. O padrão (`ismce`) é uma instância
de memória da FPGA, como na plataforma `internal-mem`.

| Operação | Como |
| :--- | :--- |
| iniciar um teste | zera o mailbox, grava a FLASH pelo editor de memória (instâncias 1 e 2), aciona o `go flag` |
| esperar o teste | lê o mailbox em intervalos até 1 (PASS) ou 2 (FAIL) |
| comparar o golden | lê só as palavras que o golden nomeia e grava um `.mif` esparso, que o validador lê como qualquer dump |
| `zero-ram` | preenche os 64 MB com zero pela placa: 2,4 s |
| `dump-ram` | `--start-word N --words M` lê um intervalo |

O editor de memória só enxerga o que está dentro da FPGA: instância 0 BOOT_ROM, 1 FLASH, 2 FLASH_MEM (a
segunda cópia da FLASH que o estágio de memória lê como dado, para o boot copiar `.data`). Não há
instância de RAM.

## 7. Runtime

| Peça | O que faz nesta plataforma |
| :--- | :--- |
| boot ROM | limpa as palavras do host no topo da SDRAM, salta para a FLASH em `0x800`, e fica parada em `rv32_wait_restart` (endereço fixo `0x100`) até o host acionar o `go flag` |
| `crt0` | põe `sp` e `gp`, copia `.data` da FLASH para a SDRAM, zera `.bss`, chama `main` |
| `_exit` | escreve 1 (PASS) ou 2 (FAIL) no mailbox e volta para a boot ROM |
| `stdout` | buffer linear de 1 KB no topo da SDRAM, lido pelo host |

A boot ROM é gravada uma única vez no bitstream. O comando de execução não a recompila: a imagem do
projeto é gerada pelo comando `riscv-tools program`, que monta o boot ROM, grava o arquivo no
projeto, compila e programa a placa. Ela deve ser regenerada sempre que a boot ROM ou o mapa de
memória mudar.

Um acesso à SDRAM antes de a inicialização terminar (cerca de 200 microssegundos depois do PLL
travar) espera pela inicialização.

## 8. Simulação

O topo de simulação tem o core, a BOOT_ROM e a FLASH como arrays de VHDL e a SDRAM com o modelo do
chip, que **falha a simulação** em qualquer violação de timing, de ordem de comandos ou de intervalo
de refresh. O clock do controlador (7 ns) não tem relação fixa com o do core.

O testbench acha o mailbox observando as escritas que terminam na porta de dado da SDRAM e, num
PASS, compara o golden com o **conteúdo do modelo do chip**, lido pela porta de leitura direta do
modelo. O golden não é reconstruído a partir das escritas vistas no barramento, então uma palavra
que nunca chegou ao chip, ou chegou ao endereço errado, é pega.

O tempo de um programa é contado em ticks do clock base de simulação (três por ciclo do core), a
mesma unidade da plataforma `internal-mem`.

## 9. Comandos

Simulação, na imagem de toolchain, a partir do projeto de testes:

```bash
uv run riscv-tools --config tools/riscv_build/config.sdram-regression.yaml compile --emit hex
uv run riscv-tools --config tools/riscv_build/config.sdram-regression.yaml sim
```

Placa:

1. compilar o projeto: `quartus_sh --flow compile core_fpga_sdram`, em `platforms/sdram/quartus`;
2. gerar as imagens na imagem de toolchain: `compile --emit mif`;
3. regravar o bitstream com a boot ROM: `riscv-tools --config <config> program <imagem>.mif`;
4. rodar a suíte: `riscv-tools --config <config> run --skip-reconfigure`.

Depurar um programa que não termina: carregue a FLASH e acione o `go flag` (o `run` faz isso), e leia a
memória pela porta (`dump-ram --start-word N --words M`). Um programa que incrementa um contador na
SDRAM sem nunca sinalizar, lido três vezes com 1 s de intervalo, devolveu 5 738 735, 10 064 582 e
14 386 268, com o mailbox em 0.

Zerar a RAM: `riscv-tools --config <config> zero-ram`. Depois de escrever o primeiro, um do meio e o
último endereço, o `zero-ram` deixou os três em 0.

## 10. Resultados medidos

| Verificação | Resultado |
| :--- | :--- |
| 89 programas existentes, simulação | 89 passam |
| 6 programas da SDRAM, simulação | 6 passam |
| 89 programas existentes, placa | 89 passam, 82 goldens conferidos, 0 divergências |
| 6 programas da SDRAM, placa | 6 passam |
| testes de entidade da SDRAM, GHDL | 11 do sistema, 10 do autoteste, 9 da porta de debug |

### 10.1 Custo da SDRAM como RAM

Ciclos em simulação, em ticks do clock base, contra a plataforma `internal-mem` (a espera de
inicialização da SDRAM, 20 000 ticks, descontada):

| Estatística sobre 89 programas | Razão |
| :--- | ---: |
| menor | 1,31 |
| mediana | 2,27 |
| média | 2,17 |
| maior | 2,47 |

| Programa | `internal-mem` | `sdram` | Razão |
| :--- | ---: | ---: | ---: |
| `add` | 503 | 1175 | 2,34 |
| `mul` | 1064 | 1598 | 1,50 |
| `store-word-roundtrip` | 362 | 851 | 2,35 |
| `stdout-printf-int` | 16 994 | 22 220 | 1,31 |
| `stdout-truncate` | 188 627 | 465 992 | 2,47 |

O custo é de cerca de 2,3 vezes na mediana, e não de 6 vezes: boa parte do tempo de um programa não é
acesso à memória. É o número que dimensiona a cache L1.

### 10.2 Porta de debug

| Medida | Valor |
| :--- | ---: |
| uma leitura, em sessão aberta | 0,85 ms |
| ler 1024 palavras, com a partida do processo | 1,5 s |
| zerar os 64 MB | 2,4 s |

### 10.3 Timing do Quartus

Os tempos do chip nas restrições são **provisórios** (valores usuais de uma SDR de 143 MHz, ainda
não conferidos com o datasheet).

| Verificação | Modelo lento (85 C) | Modelo rápido |
| :--- | ---: | ---: |
| lógica do controlador, setup | +1,84 ns | +4,65 ns |
| core a 50 MHz, setup | +4,64 ns | +12,43 ns |
| ponte, controlador para core | +7,43 ns | +8,61 ns |
| ponte, core para controlador | +5,46 ns | +7,57 ns |
| núcleo JTAG, setup | +8,55 ns | +13,02 ns |
| dado de leitura entrando no controlador, setup | -0,21 ns | +2,08 ns |
| comandos e dado de escrita, setup | -0,05 ns | +0,54 ns |
| comandos e dado de escrita, hold | +2,97 ns | +3,02 ns |

No modelo lento, a interface com o chip fica até 0,2 ns abaixo de zero com os tempos provisórios; no
modelo rápido e na placa tudo fecha. O datasheet fecha a conta.

Recursos: 15 por cento dos ALMs (2793 de 18 480), 3303 registradores, 51 pinos, 16 por cento dos bits
de memória de bloco (507 904).

## 11. Limites e o que a cache L1 precisa respeitar

- A busca de instrução não tem `ready`: o código continua na BOOT_ROM e na FLASH, e o limite de 30 KB
  da FLASH segue valendo.
- A vazão da porta de debug é a do cabo JTAG: uma palavra por comando. O dump lê só as palavras do
  golden, e um dump amplo de SDRAM é uma operação ocasional. O preenchimento é a exceção, porque a
  placa o executa.
- A porta de debug lê a SDRAM direto, sem passar por nenhuma cache. Uma cache entre o core e a ponte
  tem de escrever direto na SDRAM (ou ser descarregada no fim de cada teste) para o host ver o que o
  programa escreveu.
- A linha da cache deve casar com o burst do controlador, duas metades de 16 bits (uma palavra de 32
  bits), ou múltiplos dele.

## 12. Leitura complementar

A pasta `docs/bugs` guarda as falhas encontradas no caminho e as correções: o desvio apagado pelo
flush com o pipeline parado (Core), código que o GHDL aceita e o Quartus rejeita, o status da porta
de debug que disparava um comando, a contagem de preenchimento de 24 bits (Memory), a leitura da
SDRAM um ciclo antes na placa, o padrão do mapa de memória que lia a SDRAM como a RAM, o boot ROM de
outra plataforma (TopLevel), o mailbox obsoleto que dava PASS falso e a espera curta do preenchimento
(Tools). O protocolo da porta de debug também está descrito em `docs/SDRAM_DEBUG.md` do Memory.
