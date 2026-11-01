# Plataforma `sdram-flash`: a FLASH como chip atrás das caches

## 1. O que ela é

O núcleo guarda só a BOOT_ROM. A FLASH (programa e constantes) e a SDRAM (dados) ficam fora dele, como num SoC real, e o núcleo as alcança por uma cache de instruções e uma cache de dados. Cada falha de cache vira um pedido de linha de quatro palavras, que um roteador de região leva ao modelo de chip de FLASH, através de um árbitro, ou ao controlador da SDRAM.

```
            núcleo (só a BOOT_ROM)
              |                |
        cache de             cache de dados
        instruções           (write-through)
              |                |
        roteador I          roteador D
         |        \          /      |  \
         |         árbitro de FLASH   |  absorvedor de stores à FLASH
         |              |             |
         |         chip de FLASH      |
         |      (armazenamento)       |
         +------------+---------------+
                      |
              SDRAM (ponte, árbitro, controlador)
```

## 2. Mapa de memória

| Região | Base | Tamanho | Acesso |
| :--- | :--- | :--- | :--- |
| BOOT_ROM | `0x00000000` | 2 KB | Busca e leitura, direto, sem cache |
| FLASH | `0x20000000` | 1 MB de janela | Busca e leitura pelas caches, somente leitura |
| SDRAM | `0x40000000` | 64 MB | Busca, leitura e escrita pelas caches |
| Periféricos | `0x80000000` | janelas de 256 MB | Leitura e escrita, sem cache |

Os 4 KB do topo da SDRAM guardam as palavras que o hospedeiro escreve por trás das caches (`tohost`, `fromhost` e o buffer de `stdout`). A cache de dados as ignora: um load vai à memória como palavra, sem trazer linha, e um store só é repassado.

## 3. Comportamento

1. **Busca.** O PC alimenta só a cache de instruções e a BOOT_ROM. A tag da cache leva o bit 29 do endereço, que separa as linhas da FLASH das da SDRAM.
2. **Dados.** Loads e stores à FLASH e à SDRAM passam pela cache de dados, com linhas de 16 bytes e mapeamento direto de 4 KB. Um store à FLASH nunca altera a cache e é concluído pelo roteador sem efeito, como um chip protegido contra escrita.
3. **FLASH.** O chip atende pedidos de linha ou de palavra com dois parâmetros de latência: bordas até a primeira palavra e bordas entre as palavras seguintes. Fora da janela do chip a leitura devolve zero.
4. **Reinício.** O boot ROM executa `fence.i` antes de saltar para a FLASH. A instrução invalida a cache de instruções e a de dados, então o programa novo que o hospedeiro gravou não encontra linhas do anterior.
5. **Hospedeiro.** O hospedeiro grava a imagem da FLASH pela memória interna do Quartus (instância 1) e os dados pela porta de depuração da SDRAM, com o núcleo parado no laço de reinício do boot ROM. Ele reinicia o núcleo escrevendo um valor diferente de zero em `fromhost`.

## 4. Tamanhos e latências

| Item | Simulação | Placa |
| :--- | :--- | :--- |
| Janela do chip de FLASH | 1 MB (`window_bits` igual a 20) | 256 KB (`window_bits` igual a 18) |
| Armazenamento da FLASH | Vetor de 256 KB | 132 KB em blocos de RAM, regravável por JTAG |
| Latência do chip | 24 bordas até a primeira palavra e 4 entre as seguintes (padrão) | A mesma |

O armazenamento da placa tem 132 KB porque o maior teste do ACT4 (`I-jal-00`) ocupa 131 872 bytes. O vetor de simulação tem 256 KB porque um vetor de 1 MB não roda no GHDL.

## 5. Como rodar

| Objetivo | Comando |
| :--- | :--- |
| Simulação dos programas existentes | `riscv-tools --config tools/riscv_build/config.sdram-flash-regression.yaml compile --emit hex`, depois `sim --exclude uart-echo,uart-tx,uart-errors` (no repositório Tests) |
| Simulação dos programas da SDRAM e da FLASH | `riscv-tools --config tools/riscv_build/config.sdram-flash.yaml compile --emit hex`, depois `sim --exclude cpi-kernels,hex-id` |
| Latência do chip | As configurações `config.sdram-flash-lat2.yaml`, `-lat20.yaml` e `-lat60.yaml`, e as `-regression-lat*` |
| Compilar a placa | `quartus_sh --flow compile core_fpga_sdram_flash` em `platforms/sdram-flash/quartus` |
| Programas na placa | `riscv-tools --config tools/riscv_build/config.sdram-flash.yaml run --skip-reconfigure --skip-recompile` |
| ACT4 na placa | `certify-board --skip-build` com a configuração `config.flash-board-<perfil>.yaml` do repositório Certification |

O verificador de mapa (`check-memory-map`) confere o `platform.yaml` da plataforma contra o `config.yaml`, as flags de ligação, o boot ROM, o runtime, as constantes do núcleo e o cabeçalho dos programas.

## 6. ACT4

Os ELFs do ACT4 têm o código e as constantes na FLASH e os dados, a pilha e as palavras do HTIF na SDRAM. O teste `Zifencei-fence.i-00` reescreve o próprio código, e a FLASH ignora stores, então ele usa uma variante do alvo em que o corpo do teste fica na SDRAM e só a entrada, as macros do modelo e as constantes ficam na FLASH.
