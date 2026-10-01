import os
import sys
import json
import argparse
from pathlib import Path
# cocotb 2.0 split the Python test-runner API out of the main cocotb
# package into cocotb-tools, imported as cocotb_tools.runner — this
# repo's requirements.txt pulls unpinned cocotb, which now resolves to
# 2.x, so the old `cocotb.runner` import 404s. See insper-riscv/Tools'
# own sim_runner module for the same migration.
from cocotb_tools.runner import get_runner

def run_cocotb_test(toplevel: str, sources: list, test_module: str, parameters: dict = None):
    tests_root = Path(__file__).resolve().parents[1]
    repo_root  = Path(__file__).resolve().parents[2] 
    sys.path.append(str(repo_root))

    sim = os.getenv("SIM", "ghdl")
    vhdl_sources = [repo_root / src for src in sources]

    runner = get_runner(sim)

    if ".entities." in test_module:
        group = "entities"
    elif ".instructions." in test_module:
        group = "instructions"
    else:
        group = "misc"

    if group == "instructions":
        test_name = test_module.split(".")[-1]
        build_dir = tests_root / "python/sim_build" / group / test_name
    else:
        build_dir = tests_root / "python/sim_build" / group / toplevel
    build_dir.mkdir(parents=True, exist_ok=True)

    if parameters:
        abs_params = {}
        for k, v in parameters.items():
            if isinstance(v, bool):
                abs_params[k] = "true" if v else "false"
            else:
                # tenta resolver como caminho absoluto relativo ao ambiente atual
                vpath = Path(v)
                if vpath.exists():
                    abs_params[k] = str(vpath.resolve())
                else:
                    # se não existe no cwd atual, tente relative ao repo_root
                    candidate = repo_root / v
                    if candidate.exists():
                        abs_params[k] = str(candidate.resolve())
                    else:
                        # fallback: mantenha o original (para flags não-caminho)
                        abs_params[k] = str(v)
        parameters = abs_params

    runner.build(
        vhdl_sources=vhdl_sources,
        hdl_toplevel=toplevel,
        always=True,
        build_dir=build_dir,
        parameters=parameters or {}
    )

    wave_file = build_dir / "waves.ghw"
    plusargs = [f"--wave={wave_file}"]

    runner.test(
        hdl_toplevel=toplevel,
        hdl_toplevel_lang="vhdl",
        test_module=test_module,
        build_dir=build_dir,
        plusargs=plusargs,
    )

    print(f"Waves: {wave_file} (gerado)")

if __name__ == "__main__":
    tests_root = Path(__file__).resolve().parents[1]
    json_path  = tests_root / "python/tests.json"

    try:
        with open(json_path, "r") as f:
            TEST_CONFIGS = json.load(f)
    except FileNotFoundError:
        print(f"Erro: Arquivo de configuração '{json_path}' não encontrado.")
        sys.exit(1)
    except json.JSONDecodeError:
        print(f"Erro: O arquivo JSON '{json_path}' está mal formatado.")
        sys.exit(1)

    parser = argparse.ArgumentParser(description="Runner de Testes Cocotb para o projeto RV32I")
    parser.add_argument(
        "test_name",
        nargs="?",
        default="all",
        help=f"Nome do teste a ser executado. Opções: {list(TEST_CONFIGS.keys()) + ['all']}"
    )
    args = parser.parse_args()

    if args.test_name == "all":
        print("Executando TODOS os testes definidos em tests.json...")
        for name, config in TEST_CONFIGS.items():
            # "skip"/"skip_reason": a config-level opt-out (not a
            # removal) for a test that's currently known-broken for a
            # reason unrelated to whatever change is being tested right
            # now -- same spirit as the asm/c suite's own .off files,
            # adapted to this suite's single tests.json instead of one
            # file per test. Only skipped in the "all" sweep; running
            # it by name explicitly (`runner.py <name>`) still attempts
            # it, e.g. to check whether a fix actually resolved it.
            if config.get("skip"):
                reason = config.get("skip_reason", "no reason given")
                print(f"\n{'='*20} PULANDO TESTE: {name.upper()} {'='*20}")
                print(f"[SKIP] {reason}")
                continue
            print(f"\n{'='*20} INICIANDO TESTE: {name.upper()} {'='*20}")
            try:
                run_cocotb_test(**{k: v for k, v in config.items() if k not in ("skip", "skip_reason")})
                print(f"{'-'*20} TESTE {name.upper()} FINALIZADO COM SUCESSO {'-'*20}")
            except Exception as e:
                print(f"[ERRO] O teste '{name}' falhou: {e}")
        print("\nTodos os testes foram executados.")
    elif args.test_name in TEST_CONFIGS:
        print(f"Executando teste específico: {args.test_name}")
        config = TEST_CONFIGS[args.test_name]
        if config.get("skip"):
            print(f"[AVISO] '{args.test_name}' está marcado como skip ({config.get('skip_reason', 'no reason given')}) -- rodando mesmo assim, por ter sido pedido explicitamente.")
        run_cocotb_test(**{k: v for k, v in config.items() if k not in ("skip", "skip_reason")})
        print(f"\nTeste {args.test_name} finalizado.")
    else:
        print(f"Erro: Teste '{args.test_name}' não encontrado em tests.json.")
        print(f"Opções disponíveis: {list(TEST_CONFIGS.keys()) + ['all']}")
        sys.exit(1)
