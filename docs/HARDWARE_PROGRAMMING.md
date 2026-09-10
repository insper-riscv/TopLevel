# Programando a placa real: leia antes de mexer no pipeline de hardware

> **Regra permanente:** `quartus_sh --flow compile` e `quartus_pgm` **nunca**
> podem ser lançados como dois `subprocess.run()` (ou dois processos-pai)
> separados em Python. Eles têm que rodar dentro do **mesmo processo de
> shell**, um encadeado no outro (`cmd1 && cmd2`). Ver motivo completo abaixo.
> Quebrar essa regra reintroduz um bug já diagnosticado e corrigido; não
> reverta [`tools/Tools/src/riscv_tools/quartus_program/core.py`](../tools/Tools/src/riscv_tools/quartus_program/core.py)
> para duas chamadas separadas sem reler este documento inteiro.

## Como compilar + programar a placa (forma correta)

Use sempre o pipeline padrão via `riscv-tools`, que já implementa a regra
acima internamente:

```bash
export PATH="/opt/riscv-foundation/riscv32-elf/bin:$PATH"
cd Tests   # ou o caminho até este repo, se vendorado como submódulo do RV32IM
uv run riscv-tools --config tools/riscv_build/config.yaml generate-header
uv run riscv-tools --config tools/riscv_build/config.yaml compile --emit mif
uv run riscv-tools --config tools/riscv_build/config.yaml run
```

Se precisar compilar e programar manualmente fora do `riscv-tools` (depuração
pontual), faça isso em **um único** comando de shell, nunca em dois `Bash`
separados:

```bash
cd tests/FPGA/core/quartus && \
  quartus_sh --flow compile core_fpga_test && \
  quartus_pgm -c "USB-Blaster [1-4]" -m JTAG -o "p;output_files/core_fpga_test.sof"
```

Toolchain RISC-V: use sempre `/opt/riscv-foundation/riscv32-elf/bin` (cache
já compilado, workstation-wide); não o `riscv64-unknown-elf-gcc` do sistema
nem o submódulo `Tools/vendor/riscv-gnu-toolchain` (fonte, precisaria de
build de dezenas de minutos).

## O bug descoberto: JTAG "chain broken" após compile

### Sintoma

Depois de um `quartus_sh --flow compile` bem-sucedido (0 errors), o
`quartus_pgm` imediatamente seguinte falhava com:

```
Error (213019): Can't scan JTAG chain. Error code 87.
```

E depois disso, `jtagconfig` também parava de enxergar a placa
(`Unable to read device chain - JTAG chain broken`) até um power-cycle físico
da placa (interruptor vermelho, ~10s desligado).

### O que foi descartado

Investigação extensiva nesta sessão eliminou, em ordem:

- **Físico**: placa, cabo USB-B e porta USB do host já haviam sido trocados
  antes desta investigação começar, sem mudança no sintoma. Nada toca a
  placa fisicamente durante o problema.
- **Contenção com CI**: o `gh-actions-runner` (self-hosted, dispara
  `real.yml`/`fpga-core-tests.yml` a cada push no `main` do RV32IM) chegou a
  rodar jobs `test-real` bem próximos no tempo das tentativas manuais, mas
  o problema **persistiu identicamente com o runner parado**, então não era
  isso.
- **Estado do `jtagd`**: tentativas de matar/reiniciar o `jtagd` antes do
  `quartus_pgm`, com delays de 3s e depois 10s, não mudaram nada; o erro se
  repetiu de forma idêntica.
- **Tempo de espera entre compile e pgm**: a duração do delay (0s, 3s, 10s)
  não teve efeito algum. Isso foi confirmado de forma definitiva depois: uma
  execução com só ~1s de intervalo **funcionou**, enquanto outra com 10s de
  intervalo proposital **falhou**. Duração do delay não é a variável causal.

### O padrão real (confirmado empiricamente)

O fator que realmente distingue sucesso de falha, reproduzido de forma
consistente:

| Como compile+pgm foram lançados | Resultado |
|---|---|
| Duas chamadas `subprocess.run()` separadas, dentro do mesmo processo Python (`riscv_tools.quartus_program.core.full_reconfigure`, via `uv run riscv-tools ... run`) | **4/4 falhas** |
| Dois comandos `Bash` top-level completamente separados (compile numa chamada, `quartus_pgm` noutra) | **2/2 sucessos** |
| Os dois comandos encadeados num único `bash -c "cmd1 && cmd2"` | **2/2 sucessos** (inclusive com só ~1s de intervalo real entre eles) |

Ou seja: **não é o processo pai ser único ou não** (o `bash -c` encadeado
também é "um processo só" e funcionou), e **não é o tempo de espera**. O que
falha de forma consistente é especificamente o padrão de duas chamadas
**`subprocess.run()` do Python** em sequência para esses dois comandos
específicos.

A causa mecanística exata não foi confirmada (não foi possível instrumentar
o firmware do USB-Blaster onboard nem capturar tráfego USB em baixo nível
nesta sessão). A pesquisa na comunidade Intel/Altera aponta um padrão
documentado e consistente com isso: ferramentas de linha de comando da
Quartus (`quartus_pgm`, `quartus_stp`) às vezes não inicializam o ambiente
JTAG da mesma forma que a GUI do Quartus Programmer, e a primeira tentativa
"fria" numa sessão pode falhar onde uma segunda (ou uma sessão de shell
diferente) funciona; ver fontes abaixo. É plausível que o `subprocess.run()`
do Python herde algo do ambiente/sessão do processo pai (variável de
ambiente, terminal/pty, ordem de finalização de descritores de arquivo) de
um jeito que interfere nessa inicialização, enquanto um `bash -c` encadeado
não.

Fontes consultadas (nenhuma documenta o caso exato, mas mostram o padrão
"CLI JTAG cold-start" é conhecido):

- [Error (213019): Can't scan JTAG chain. Error code 87 (Intel Community)](https://community.intel.com/t5/FPGA-SoC-And-CPLD-Boards-And/Error-213019-Can-t-scan-JTAG-chain-Error-code-87-while-uploading/m-p/198826)
- [Issue with quartus_pgm Command-Line .jic File Programming on DE0-Nano (Intel Community)](https://community.intel.com/t5/FPGA-SoC-And-CPLD-Boards-And/Issue-with-quartus-pgm-Command-Line-jic-File-Programming-on-DE0/td-p/1700547)
- [Chain description file (CDF) working in Quartus Programmer GUI but not in CMD tools (Intel Community)](https://community.intel.com/t5/Intel-Quartus-Prime-Software/Chain-description-file-CDF-working-in-Quartus-Programmer-GUI-but/td-p/210791)

### A correção aplicada

Em [`tools/Tools/src/riscv_tools/quartus_program/core.py`](../tools/Tools/src/riscv_tools/quartus_program/core.py),
`full_reconfigure()` monta `quartus_sh --flow compile ... && quartus_pgm ...`
como uma única string de shell e a executa com **uma** chamada
`subprocess.run(["bash", "-c", script], check=True)`, em vez de duas
chamadas `subprocess.run()` separadas. Confirmado: `uv run riscv-tools
--config tools/riscv_build/config.yaml run` (o mesmo comando que falhava
4/4 vezes) rodou de ponta a ponta sem quebrar a JTAG depois dessa mudança.

## Um bug relacionado, mas diferente: `jtagconfig` OK e mesmo assim trava

Se `jtagconfig` mostra a placa saudável mas leituras/escritas via
In-System Memory Content Editor (mailbox, ROM/RAM) continuam travando ou
nunca respondendo, e só power-cycle físico resolve (reprogramar sozinho
não): não é este bug. Ver
[bugs/PLL_LOCK_LOSS_BUG.md](bugs/PLL_LOCK_LOSS_BUG.md): o reset do PLL
estava amarrado em `'0'` permanentemente, então qualquer perda de lock
(ruído de alimentação, etc.) travava o core pra sempre, mesmo com o TAP
JTAG básico (o que `jtagconfig` escaneia) continuando saudável.

## Outros dois bugs reais encontrados (não são o bug de JTAG acima)

Só apareceram depois que o problema de JTAG foi contornado e a comunicação
via `quartus_stp`/In-System Memory Content Editor passou a funcionar de
fato pela primeira vez nesta sessão:

1. **`jtag/tcl/write_word.tcl`** formatava o valor de uma palavra de 32 bits
   sem zero-padding (`[format %x $VALUE]` em vez de `[format %08x $VALUE]`),
   o que fazia o `write_content_to_memory` do Quartus rejeitar a escrita
   ("Data specified in the string does not match the number of bits...").
   Afeta `mailbox.pulse_go_flag` (o pulso de restart de cada teste).

2. **`mem_validator/core.py`** interpretava o conteúdo do `.mif` de dump de
   RAM sempre como hexadecimal, mas `save_content_from_memory_to_file` do
   Quartus (usado por `dump_mem.tcl`) grava com `DATA_RADIX=BIN`. O parser
   agora lê o `DATA_RADIX` declarado no próprio `.mif` e usa a base correta.

Com os três problemas corrigidos, os 14 testes da suíte real (11 vindos da
divisão do antigo `full.S` + `example-add` + `example-integration-mem` +
`section6-loadstore`) passaram via `riscv-tools run` contra a placa
Cyclone V real.
