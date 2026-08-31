# `crt0.S`: o estado de boot de referência deste RISC-V bare-metal

`crt0.S` (`tools/riscv_build/crt0.S`) é o **ponto zero** de qualquer programa
que roda neste core: a primeira instrução executada depois do reset, sem SO,
sem runtime, sem nada além do que o próprio hardware garante. Este documento
descreve, registrador por registrador e seção por seção, exatamente que
estado existe no instante em que `main()` é chamado — e, tão importante
quanto, o que **não** é feito e por quê. A ideia é que este arquivo seja a
referência canônica: qualquer coisa mais sofisticada que se queira construir
depois (um SO minúsculo, um scheduler cooperativo, um runtime C++ completo)
**expande** esse estado inicial em vez de reconstruí-lo do zero — a base já
deixa o hart num estado válido segundo a ABI oficial do RISC-V
([riscv-elf-psabi-doc](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)),
não um atalho específico deste projeto.

## Registradores de propósito geral no momento em que `main()` roda

| Registrador | Nome ABI | Estado em `main()` | Por quê |
|---|---|---|---|
| `x0` | `zero` | `0`, sempre | Hardwired em silício — nenhuma instrução pode mudar isso, não precisa (nem pode) ser inicializado. |
| `x1` | `ra` | Endereço de retorno de `call main` (a instrução `jal` que chama `main`) | Convenção normal de chamada — `main` retornando usa esse `ra` pra voltar pro ponto logo depois do `call main` em `_start` (que cai direto no código de restart). |
| `x2` | `sp` | `_stack_top` (topo da RAM, ver `link.ld`) | Pilha cresce pra baixo a partir daqui. É o primeiro registrador "de verdade" que `_start` inicializa (depois de `gp`/`tp`, ver abaixo). |
| `x3` | `gp` | `__global_pointer$` (calculado via `auipc`+`addi`, `.option norelax`) | Necessário pra qualquer acesso `gp`-relative a `.sdata`/`.sbss` funcionar — ver [SMALL_DATA_SECTION_BUG.md](SMALL_DATA_SECTION_BUG.md) pro bug real que motivou isso: sem essa inicialização, um acesso gp-relative lê/escreve endereço arbitrário, não um valor errado. |
| `x4` | `tp` | `_tls_base` (= início de `.tdata`, ver `link.ld`) | Convenção RISC-V TLS "Variant I": `tp` aponta um byte além do fim do TCB (Thread Control Block). Este bare-metal não tem TCB real (sem linkagem dinâmica, sem DTV), então o tamanho do TCB é 0 e `tp` = início direto do bloco TLS. Nada usa TLS hoje (nenhum `.tdata`/`.tbss` não-vazio em nenhum teste), mas fica pronto — mesma classe de bug que `gp` teria se não fosse inicializado. |
| `x5`–`x7` | `t0`–`t2` | **Não garantido** — usados como scratch durante o boot (cópia de `.data`, zeragem de `.bss`, mailbox) | São *caller-saved*/temporários pela ABI — nenhuma convenção exige que estejam zerados na entrada de um programa, só que uma função que os usa não precisa preservá-los pro chamador. `main()` não deve assumir nada sobre o valor inicial deles. |
| `x8` | `s0`/`fp` | **Não inicializado** — o que o hardware deixou no reset | *Callee-saved* pela ABI: é responsabilidade de quem usa (tipicamente o prólogo de uma função com frame pointer) salvar/restaurar, não de quem inicializa o ambiente. Um SO completo tipicamente também não zera isso — só importa a partir do primeiro `push`/uso real. |
| `x9`, `x18`–`x27` | `s1`, `s2`–`s11` | **Não inicializado** | Mesma razão que `s0` — *callee-saved*, sem garantia de valor inicial em nenhuma ABI RISC-V que conheço. |
| `x10`–`x17` | `a0`–`a7` | **Não inicializado** (nenhum argumento é passado pra `main()` aqui) | Numa `libc` hospedada, `a0`/`a1` normalmente carregariam `argc`/`argv` antes de chamar `main`. Este bare-metal não tem conceito de linha de comando — `main(void)`, sem argumentos — então esses registradores simplesmente não são preenchidos por `_start`. |
| `x28`–`x31` | `t3`–`t6` | **Não garantido** | Mesma categoria que `t0`–`t2`. |

**Resumo prático**: só `zero`, `sp`, `gp` e `tp` têm uma garantia real de
estado antes de `main()`. Todo o resto (`ra` à parte, que tem um valor
específico mas não "limpo") é território comum de qualquer ABI RISC-V — um
programa correto nunca deveria depender do valor inicial de um registrador
temporário/salvo antes de defini-lo ele mesmo.

## CSRs (registradores de controle e status)

**Nenhum CSR é tocado por `crt0.S`** — nem `mstatus`, nem `mtvec`, nem
`mepc`, nem `mie`/`mip`, nada. Isso é deliberado e reflete o hardware real
que este projeto testa: `rv32im_pipeline_core` **não implementa Zicsr nem
modo de exceção/trap** — não existe unidade de CSR em nenhum dos arquivos
VHDL do core (confirmado inspecionando `RV32IM/src/` — não há `csr.vhd` nem
equivalente). Rodar uma instrução `csrw`/`csrr`/`ecall` neste core não tem
definição conhecida de comportamento; nenhum teste deste projeto faz isso.

Isso também é o motivo pelo qual o formato de teste padrão do
`riscv-tests` (que assume `mtvec`/PMP/`ecall` funcionando pra sinalizar
PASS/FAIL) não roda aqui sem adaptação — ver a investigação registrada na
conversa que motivou este documento.

## Seções de memória: estado no boot

| Seção | O que é | Estado antes de `main()` |
|---|---|---|
| `.text` | Código (ROM) | Já está lá — carregado via JTAG/`.mif`, nada a fazer em runtime. |
| `.rodata` | Constantes somente-leitura (ROM) | Idem — direto da ROM, nunca copiado pra RAM. |
| `.data` | Globais inicializados "grandes" (RAM, carga vem da ROM) | Copiado byte a byte (4 em 4 bytes) de `_data_load` (endereço na ROM) pra `[_data_start, _data_end)` na RAM. |
| `.sdata`/`.srodata` | Globais pequenos (RISC-V "small data", endereçados via `gp`) — parte do mesmo range `[_data_start, _data_end)` | Copiados junto com `.data` no mesmo loop — ver [SMALL_DATA_SECTION_BUG.md](SMALL_DATA_SECTION_BUG.md) pra história de como isso ficou de fora originalmente. |
| `.bss`/`.sbss` | Globais não-inicializados (RAM) | Zerados, `[_bss_start, _bss_end)` — `_bss_start` marca o início de `.sbss`, não de `.bss`, pra manter as duas seções contíguas com um único loop. |
| `.tdata`/`.tbss` | Dados thread-local (TLS) | Mesmo tratamento copy/zero que `.data`/`.bss` — hoje sempre vazio (nada usa `__thread`), loops rodam zero iterações. |
| Pilha | Cresce de `_stack_top` pra baixo | Nunca "inicializada" no sentido de conteúdo — só o ponteiro (`sp`) é definido. Conteúdo é lixo até ser escrito. |
| Mailbox (`0x3FFC`) / go-flag (`0x3FF8`) | Protocolo deste projeto com o host (PASS/FAIL, restart) | Zerados a cada entrada em `_start` — cold boot ou restart, pra nunca vazar o resultado do teste anterior. Endereço fixo (não símbolo de linker), ver `config.yaml`. |
| `tohost`/`fromhost` | Convenção HTIF (Spike/`riscv-tests`) | Zerados a cada entrada em `_start`, mesma razão do mailbox — um `tohost` não-zerado faria o Spike achar que o *próximo* teste já terminou instantaneamente. Sem efeito em hardware real (nada lê esse endereço lá). |

## O que este `crt0.S` deliberadamente NÃO faz (e o que um "RISC-V completo" precisaria adicionar em cima)

Esta lista é o mapa do que fica pra próxima camada — um SO, um runtime mais
rico, ou suporte a mais hardware — sem precisar re-fazer o que já está
pronto aqui:

- **Vetor de exceção/trap (`mtvec`) e tratamento de `ecall`/interrupções.**
  Não existe porque o core não tem CSR/modo privilegiado (ver acima). Um
  core mais completo (ou uma versão futura deste) precisaria de um
  `trap_vector` real, delegação de exceções (`medeleg`/`mideleg`), e só
  então `ecall`-based syscalls fariam sentido.
- **Suporte multi-hart.** `_start` assume um único hart correndo — não tem
  o `csrr a0, mhartid; bnez a0, <park>` que a maioria dos crt0 "de verdade"
  usa pra estacionar todos os harts exceto o 0. Como o core aqui é
  single-hart, isso nunca foi necessário — mas é o primeiro item a
  adicionar se um dia isso mudar.
- **TCB (Thread Control Block) real para TLS dinâmico.** `tp` está
  inicializado (ver tabela acima), mas assumindo TCB de tamanho 0 — válido
  só pro modelo *local-exec* (sem linkagem dinâmica, sem DTV). Um ambiente
  com múltiplas threads/dynamic linking precisaria de um TCB de verdade
  (ponteiro pro DTV, etc.) antes de apontar `tp` pra ele.
- **Heap / `brk`.** Não existe noção de heap — nenhum `malloc`/`sbrk` é
  suportado. Um ponteiro de heap (tipicamente logo depois de `_bss_end`,
  antes da pilha) seria o próximo passo.
- **Inicializadores globais C++ / `__libc_init_array`.** Como não há libc
  nem C++ aqui (`-nostdlib -ffreestanding`), não existe chamada pra rodar
  construtores globais (`.init_array`). Um ambiente C++ precisaria iterar
  `.init_array` antes de `call main`.
- **PMP (Physical Memory Protection) / isolamento.** Sem CSR, não tem como
  configurar PMP — irrelevante enquanto o core não implementar modo
  privilegiado, mas seria essencial pra rodar código não-confiável.
- **Limpeza de registradores temporários/salvos antes de `main()`.** Como
  documentado na tabela acima, `t0`–`t6`/`s0`–`s11`/`a0`–`a7` não são
  zerados — aceitável pra este ambiente de teste controlado, mas um
  ambiente com requisitos de segurança (evitar vazamento de estado entre
  execuções, por exemplo) precisaria zerar explicitamente tudo antes de
  `call main`.

## Por que isso importa: a lição do bug de `.sdata`

O motivo de este documento existir é justamente o bug documentado em
[SMALL_DATA_SECTION_BUG.md](SMALL_DATA_SECTION_BUG.md): um registrador
"especial" (`gp`) nunca foi inicializado porque, até então, nenhum teste
pequeno o suficiente exercitava o caminho que dependia dele — o bug ficou
invisível por todo o histórico do projeto até um teste minúsculo
(`data-init-byte`) tropeçar nele, e o sintoma foi um travamento completo, não
um erro claro. `tp` recebeu o mesmo tratamento preventivo por essa razão
específica: não esperar até algo realmente usar TLS pra descobrir que também
estava quebrado.
