"""Testes cocotb do gerador de clock de três vias (ClkGen3Way)."""

import cocotb
from cocotb.triggers import Timer

from tests.python.utils.checks import check

ZEROS = (0, 0, 0)


def outputs(dut) -> tuple:
    """Return the three clock outputs as a tuple of ints."""
    return (int(dut.clk0.value), int(dut.clk1.value), int(dut.clk2.value))


async def rise(dut, half=5):
    """Drive clk_in high and wait half a period."""
    dut.clk_in.value = 1
    await Timer(half, units="ns")


async def fall(dut, half=5):
    """Drive clk_in low and wait half a period."""
    dut.clk_in.value = 0
    await Timer(half, units="ns")


async def reset_pulse(dut, width):
    """Pulse reset for width ns, then release it and wait 1 ns."""
    dut.clk_in.value = 0
    dut.reset.value = 1
    await Timer(width, "ns")
    dut.reset.value = 0
    await Timer(1, "ns")


@cocotb.test()
async def one_hot_property(dut):
    """Check the one-hot outputs.

    Assegura que durante a fase alta exatamente UMA saída é '1'
    (one-hot), e que durante a fase baixa todas são '0'.
    """
    await reset_pulse(dut, 5)

    for i in range(30):
        # fase baixa: todas zero
        await fall(dut, half=3)
        low = outputs(dut)
        check(
            low == ZEROS, f"[one_hot] cycle {i} low: esperado 0, obteve {low}"
        )

        # fase alta: exatamente uma saída ativa
        await rise(dut, half=3)
        high = outputs(dut)
        check(
            sum(high) == 1,
            f"[one_hot] cycle {i} high: esperado 1 bit ativo, obteve {high}",
        )
    dut._log.info("one_hot_property: OK")


@cocotb.test()
async def async_reset_immediate_clear(dut):
    """Check the asynchronous reset.

    Verifica que reset assíncrono limpa as saídas imediatamente quando
    aplicado tanto na fase alta quanto na fase baixa.
    """
    # inicia e roda 2 ciclos para entrar em operação
    dut.clk_in.value = 0
    dut.reset.value = 0
    await Timer(1, "ns")
    await rise(dut, half=4)
    await fall(dut, half=4)

    # aplica reset durante a fase baixa
    dut.reset.value = 1
    await Timer(1, "ns")
    after_reset_low = outputs(dut)
    check(after_reset_low == ZEROS, f"[reset low] obteve {after_reset_low}")

    # libera reset e roda um ciclo para voltar à operação
    dut.reset.value = 0
    await rise(dut, half=4)
    await fall(dut, half=4)

    # aplica reset durante a fase alta
    await rise(dut, half=4)
    dut.reset.value = 1
    await Timer(1, "ns")
    after_reset_high = outputs(dut)
    check(after_reset_high == ZEROS, f"[reset high] obteve {after_reset_high}")

    dut.reset.value = 0
    await Timer(1, "ns")
    dut._log.info("async_reset_immediate_clear: OK")


@cocotb.test()
async def release_reset_alignment(dut):
    """Check the behaviour after releasing the reset.

    Depois de liberar reset, garante-se comportamento determinístico:
    se liberar antes de uma subida, no próximo rise espera-se que a
    saída consistente com cnt inicial ocorra. Dependendo da
    implementação, o primeiro high pode ser clk0 ou clk1.
    """
    # força reset, libera em low e aguarda uma subida
    dut.clk_in.value = 0
    dut.reset.value = 1
    await Timer(5, "ns")
    dut.reset.value = 0
    await Timer(1, "ns")

    await rise(dut, half=4)
    high1 = outputs(dut)
    check(sum(high1) == 1, f"[release align] primeiro high: obteve {high1}")

    # mais dois ciclos para verificar a rotação
    await fall(dut, half=4)
    await rise(dut, half=4)
    high2 = outputs(dut)
    await fall(dut, half=4)
    await rise(dut, half=4)
    high3 = outputs(dut)

    check(
        sum(high2) == 1 and sum(high3) == 1,
        "[release align] subsequentes devem ser one-hot",
    )
    dut._log.info(f"release alignment highs: {high1} -> {high2} -> {high3}")
    dut._log.info("release_reset_alignment: OK")


@cocotb.test()
async def output_changes_only_on_rising_edge(dut):
    """Check that the outputs change only on the rising edge.

    Garante que a mudança de saída acontece na borda de subida, já que
    as saídas são ativas quando clk_in='1' e cnt foi atualizado na
    descida. Amostramos antes, logo após e um pouco depois da subida.
    """
    dut.clk_in.value = 0
    dut.reset.value = 1
    await Timer(3, "ns")
    dut.reset.value = 0
    await Timer(1, "ns")

    # avança um ciclo para ter cnt não trivial
    await rise(dut, half=3)
    await fall(dut, half=3)

    # amostra pouco antes da subida
    await Timer(1, "ns")
    dut.clk_in.value = 0
    await Timer(1, "ns")
    before = outputs(dut)

    # na subida: amostra imediatamente após mudar clk_in para 1
    dut.clk_in.value = 1
    await Timer(1, "ns")
    on_rise = outputs(dut)

    # um pouco depois mantém o valor (não deveria flutuar)
    await Timer(2, "ns")
    later = outputs(dut)

    check(
        before == ZEROS, f"[edge] antes da subida esperado 0, obteve {before}"
    )
    check(sum(on_rise) == 1, f"[edge] após subida esperado one-hot: {on_rise}")
    check(later == on_rise, f"[edge] estabilidade: {on_rise} vs {later}")

    dut._log.info("output_changes_only_on_rising_edge: OK")


@cocotb.test()
async def long_run_no_glitches(dut):
    """Run many cycles looking for glitches.

    Executa muitos ciclos para detectar glitches intermitentes e
    verificar a repetição do padrão (período 3).
    """
    await reset_pulse(dut, 2)

    prev_high = None
    for i in range(120):
        await rise(dut, half=2)
        high = outputs(dut)
        check(sum(high) == 1, f"[long] high @i={i} expected one-hot: {high}")
        # garante que o padrão muda a cada ciclo
        check(high != prev_high, f"[long] stuck pattern @i={i}: {high}")
        prev_high = high
        await fall(dut, half=2)
        low = outputs(dut)
        check(low == ZEROS, f"[long] low @i={i} expected zeros, got {low}")

    dut._log.info("long_run_no_glitches: OK")
