"""Runner dos testes cocotb do projeto RV32I (tests.json)."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# cocotb 2.0 split the Python test-runner API out of the main cocotb
# package into cocotb-tools, imported as cocotb_tools.runner. This
# repo's requirements.txt pulls unpinned cocotb, which now resolves to
# 2.x, so the old `cocotb.runner` import 404s. See insper-riscv/Tools'
# own sim_runner module for the same migration.
from cocotb_tools.runner import get_results, get_runner

TESTS_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[2]
SKIP_KEYS = ("skip", "skip_reason")


def _group_of(test_module: str) -> str:
    """Classify a test module as entities, instructions or misc."""
    if ".entities." in test_module:
        return "entities"
    if ".instructions." in test_module:
        return "instructions"
    return "misc"


def _build_dir(toplevel: str, test_module: str) -> Path:
    """Return (and create) the simulator build directory of a test."""
    group = _group_of(test_module)
    if group == "instructions":
        leaf = test_module.rsplit(".", maxsplit=1)[-1]
    else:
        leaf = toplevel
    build_dir = TESTS_ROOT / "python/sim_build" / group / leaf
    build_dir.mkdir(parents=True, exist_ok=True)
    return build_dir


def _resolve_parameter(value: object) -> str:
    """Convert a generic value into a simulator string."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    # Path relative to the current directory, then to the repository
    # root; anything that is not a path is kept as it is.
    for candidate in (Path(str(value)), REPO_ROOT / str(value)):
        if candidate.exists():
            return str(candidate.resolve())
    return str(value)


def run_cocotb_test(config: dict) -> None:
    """Build and run one cocotb test described by a tests.json entry.

    Parameters
    ----------
    config : dict
        Entry with ``toplevel``, ``sources`` and ``test_module`` and,
        optionally, ``parameters``, ``build_args`` and ``test_args``.

    Raises
    ------
    RuntimeError
        If any cocotb test of the module fails.
    """
    toplevel = config["toplevel"]
    test_module = config["test_module"]
    sys.path.append(str(REPO_ROOT))

    runner = get_runner(os.getenv("SIM", "ghdl"))
    build_dir = _build_dir(toplevel, test_module)
    parameters = {
        key: _resolve_parameter(value)
        for key, value in (config.get("parameters") or {}).items()
    }

    runner.build(
        vhdl_sources=[REPO_ROOT / src for src in config["sources"]],
        hdl_toplevel=toplevel,
        always=True,
        build_dir=build_dir,
        parameters=parameters,
        build_args=config.get("build_args") or [],
    )

    wave_file = build_dir / "waves.ghw"
    results_xml = runner.test(
        hdl_toplevel=toplevel,
        hdl_toplevel_lang="vhdl",
        test_module=test_module,
        build_dir=build_dir,
        plusargs=[f"--wave={wave_file}"],
        test_args=config.get("test_args") or [],
    )
    print(f"Waves: {wave_file} (gerado)")

    # runner.test() returns normally when a cocotb test fails; the
    # failures are only in results.xml.
    total, failed = get_results(results_xml)
    if failed:
        message = f"{failed} of {total} cocotb tests failed"
        raise RuntimeError(message)


def _run_entry(config: dict) -> None:
    """Run a tests.json entry without its skip bookkeeping keys."""
    run_cocotb_test({k: v for k, v in config.items() if k not in SKIP_KEYS})


def _load_configs() -> dict:
    """Read tests.json, exiting with a message when it is unusable."""
    json_path = TESTS_ROOT / "python/tests.json"
    try:
        with json_path.open() as handle:
            return json.load(handle)
    except FileNotFoundError:
        print(f"Erro: Arquivo de configuração '{json_path}' não encontrado.")
    except json.JSONDecodeError:
        print(f"Erro: O arquivo JSON '{json_path}' está mal formatado.")
    sys.exit(1)


def _run_all(configs: dict) -> None:
    """Run every non-skipped test and exit 1 when any of them fails.

    A ``skip``/``skip_reason`` entry is a config-level opt-out (not a
    removal) for a test that is currently known to be broken. It is
    only skipped in this sweep; running it by name still attempts it.
    """
    print("Executando TODOS os testes definidos em tests.json...")
    failures = []
    for name, config in configs.items():
        title = name.upper()
        if config.get("skip"):
            reason = config.get("skip_reason", "no reason given")
            print(f"\n{'=' * 20} PULANDO TESTE: {title} {'=' * 20}")
            print(f"[SKIP] {reason}")
            continue
        print(f"\n{'=' * 20} INICIANDO TESTE: {title} {'=' * 20}")
        try:
            _run_entry(config)
            print(
                f"{'-' * 20} TESTE {title} FINALIZADO COM SUCESSO {'-' * 20}"
            )
        except (
            RuntimeError,
            OSError,
            ValueError,
            subprocess.SubprocessError,
        ) as error:
            failures.append(name)
            print(f"[ERRO] O teste '{name}' falhou: {error}")
    print("\nTodos os testes foram executados.")
    if failures:
        print(
            f"[ERRO] {len(failures)} teste(s) falharam: {', '.join(failures)}"
        )
        sys.exit(1)


def _run_named(name: str, config: dict) -> None:
    """Run one test chosen by name, even when it is marked as skip."""
    print(f"Executando teste específico: {name}")
    if config.get("skip"):
        reason = config.get("skip_reason", "no reason given")
        print(
            f"[AVISO] '{name}' está marcado como skip ({reason}) "
            "-- rodando mesmo assim, por ter sido pedido explicitamente."
        )
    _run_entry(config)
    print(f"\nTeste {name} finalizado.")


def main() -> None:
    """Parse the command line and run the requested tests."""
    configs = _load_configs()
    options = [*configs, "all"]
    parser = argparse.ArgumentParser(
        description="Runner de Testes Cocotb para o projeto RV32I"
    )
    parser.add_argument(
        "test_name",
        nargs="?",
        default="all",
        help=f"Nome do teste a ser executado. Opções: {options}",
    )
    name = parser.parse_args().test_name

    if name == "all":
        _run_all(configs)
    elif name in configs:
        _run_named(name, configs[name])
    else:
        print(f"Erro: Teste '{name}' não encontrado em tests.json.")
        print(f"Opções disponíveis: {options}")
        sys.exit(1)


if __name__ == "__main__":
    main()
