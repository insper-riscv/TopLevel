# Contribution Guide

🌐 [Português](CONTRIBUTING.md) · [English](CONTRIBUTING.en.md)

This document defines the mandatory coding, structural organization, documentation, and verification rules for any contribution to the `TopLevel` repository.

## 1. VHDL-2008 Standard and Synthesis Compatibility

All hardware code in the project is written and validated under the **IEEE 1076-2008 (VHDL-2008)** standard, compiled in GHDL with the `--std=08` flag, and synthesized in Quartus Prime.

| Rule | Specification |
| :--- | :--- |
| Language standard | VHDL-2008 (`--std=08`) across all `.vhd` files |
| Permitted IEEE packages | Only `ieee.std_logic_1164.all` and `ieee.numeric_std.all` |
| Prohibited packages | `std_logic_arith`, `std_logic_unsigned`, and `std_logic_signed` must never be used |
| Module instantiation | Use direct entity instantiation (`u_name : entity work.entity_name`), without redundant `component` declarations |
| Port mapping (`port map`) | Always associate by name (`i_port => signal`) and use intermediate signals for logical expressions or dynamic slices, because GHDL requires globally static expressions in port map actuals |
| Latch prevention | Every signal assigned in a combinational process or conditional assignment must receive an explicit default value across all branches (`else` / `when others =>`) |

The reference standard is [IEEE Std 1076-2008, IEEE Standard VHDL Language Reference Manual](https://standards.ieee.org/ieee/1076/3666/). In academic work, cite it with the BibTeX entry below:

```bibtex
@misc{ieee1076,
  title        = {IEEE Standard VHDL Language Reference Manual},
  author       = {{IEEE}},
  year         = {2008},
  note         = {IEEE Std 1076-2008},
  howpublished = {\url{https://standards.ieee.org/ieee/1076/3666/}}
}
```

The organization into reusable blocks with explicit interfaces and parameters follows [IEEE Std 1685, IEEE Standard for IP-XACT](https://standards.ieee.org/ieee/1685/10583/), whose BibTeX entry is:

```bibtex
@misc{ieee1685,
  title        = {IEEE Standard for IP-XACT, Standard Structure for Packaging, Integrating, and Reusing IP within Tool Flows},
  author       = {{IEEE}},
  year         = {2022},
  note         = {IEEE Std 1685-2022},
  howpublished = {\url{https://standards.ieee.org/ieee/1685/10583/}}
}
```

The design-for-reuse methodology for hardware blocks follows the book *Reuse Methodology Manual for System-on-a-Chip Designs* (3rd edition, Springer, 2002) by Keating and Bricaud, a copyrighted work available only by purchase or through an institutional library:

```bibtex
@book{keating2002rmm,
  title     = {Reuse Methodology Manual for System-on-a-Chip Designs},
  author    = {Keating, Michael and Bricaud, Pierre},
  edition   = {3},
  year      = {2002},
  publisher = {Springer},
  isbn      = {978-1402071416}
}
```

## 2. Mandatory VHDL Naming and Port Prefixes

All code identifiers must be written in **English**, whereas all comments and file headers must be written in **Portuguese**.

| VHDL Element | Convention | Examples |
| :--- | :--- | :--- |
| Entities, architectures, and packages | `snake_case` | `mux_2x1`, `generic_register`, `alu_consts`, `rtl` |
| Input ports (`in`) | Mandatory `i_` prefix + `snake_case` | `i_clk`, `i_rst`, `i_data`, `i_addr` |
| Output ports (`out`) | Mandatory `o_` prefix + `snake_case` | `o_data`, `o_irq`, `o_ready` |
| Generics | Descriptive `snake_case` | `data_width`, `addr_width` |
| Constants (`constant`) | `UPPER_SNAKE_CASE` | `WORD_WIDTH`, `REG_ZERO` |
| Types and subtypes (`type`, `subtype`) | `snake_case` with `_t` suffix | `word_t`, `reg_idx_t` |
| Internal signals and variables | `snake_case` | `rd_data`, `wr_en` |
| Instance labels | `u_` prefix + `snake_case` | `u_reg_file`, `u_mux` |

## 3. VHDL File Headers and Docstrings

### 3.1. Mandatory File Header

Every `.vhd` file must begin with a 72-column header block (`-- ====...====`) in Portuguese describing the architectural responsibility of the package or entity:

```vhdl
-- ============================================================================
-- <Título curto do pacote ou entidade>
-- ============================================================================
-- <Descrição clara em português da função do módulo, interfaces principais, invariantes de ciclo/latência ou parâmetros.>
-- ============================================================================
```

Internal sections within an architecture must use 72-column single-hyphen dividers (`-- ----...----`).

### 3.2. Individual Docstring Above Every Declaration

Every individual `generic`, `port`, `constant`, `subtype`, `type`, `signal`, `alias`, and `variable` declaration must have its own descriptive comment in Portuguese on the line immediately above it. End-of-line inline comments do not replace the docstring above the declaration:

```vhdl
entity mux_2x1 is
    generic(
        -- Largura em bits dos barramentos de entrada e saída
        data_width : natural := 32
    );
    port(
        -- Entrada selecionada quando i_sel vale '0'
        i_d0  : in  std_logic_vector(data_width - 1 downto 0);
        -- Entrada selecionada quando i_sel vale '1'
        i_d1  : in  std_logic_vector(data_width - 1 downto 0);
        -- Bit seletor entre i_d0 ('0') e i_d1 ('1')
        i_sel : in  std_logic;
        -- Saída multiplexada resultante
        o_out : out std_logic_vector(data_width - 1 downto 0)
    );
end entity mux_2x1;
```

## 4. Design for Reuse and Zero Duplication

The project follows the *Design for Reuse* practice described in the *Reuse Methodology Manual* (Keating and Bricaud), which is not an IEEE standard and is not equivalent to the SOLID principles of object-oriented programming. Each rule below translates into a criterion that can be checked in review:

| # | Rule | Review criterion |
| :--- | :--- | :--- |
| 1 | **Single-purpose blocks:** separate control, datapath, and protocol interface into distinct entities | An entity with more than one job must be split; a structural top level only connects instances |
| 2 | **Parameterization through `generic` and package constants:** no width, depth, or feature fixed inside the architecture | No magic literal in logic; codes, addresses, and selectors live in constant packages |
| 3 | **Standardized, interchangeable interfaces:** entities with the same port signature can be swapped without changing whoever instantiates them | Changing a block's architecture must not change its ports or its externally observable behavior |
| 4 | **Lean ports:** the entity exposes only the ports and generics it uses | Signals or generics "for future use" do not belong in an entity |
| 5 | **Dependence on ports only:** the upper level knows the entity declaration, never the internals of its architecture | The top level never carries fine-grained implementation logic |
| 6 | **Composition with already verified leaf blocks:** reuse existing primitives | Do not reimplement with ad-hoc processes or operators what a primitive or an already computed signal provides |

## 5. C Standard (C23)

All C code in the project (test programs, runtime, and fixtures) is written under the **ISO/IEC 9899:2024 (C23)** standard and compiled with `-std=c23`, never with `-std=gnu23` or compiler extensions that bypass the standard.

| Rule | Specification |
| :--- | :--- |
| Language standard | C23 (`-std=c23`) across all `.c` and `.h` files |
| Warnings | `-Wall -Wextra -Wpedantic -Werror`; no warning is accepted |
| Fixed-width types | `<stdint.h>` (`uint32_t`, `int32_t`) instead of `int`/`long` when width matters |
| C23 keywords | Use `bool`, `true`, `false`, `nullptr`, `constexpr`, `static_assert` without a message, and `typeof`; do not include `<stdbool.h>` or define a custom `NULL` |
| Attributes | Use the standard `[[nodiscard]]`, `[[maybe_unused]]`, and `[[noreturn]]` syntax instead of `__attribute__` |
| Constants | `constexpr` or `enum` instead of numeric `#define` macros; binary literals (`0b1010`) and digit separators (`1'000'000`) are allowed |
| Freestanding environment | Bare-metal code compiled with `-ffreestanding` depends only on the headers guaranteed by the standard and on the runtime libc |
| Naming | Identifiers in **English** with `snake_case`, constants and macros in `UPPER_SNAKE_CASE`, types with the `_t` suffix; comments in **Portuguese** |
| Comments | Every function and global variable has a descriptive comment in Portuguese immediately above its declaration |

The reference standard is [ISO/IEC 9899:2024](https://www.iso.org/standard/82075.html). In academic work, cite it with the BibTeX entry below:

```bibtex
@misc{iso9899,
  title        = {Information technology, Programming languages, C},
  author       = {{ISO/IEC}},
  year         = {2024},
  note         = {ISO/IEC 9899:2024 (C23)},
  howpublished = {\url{https://www.iso.org/standard/82075.html}}
}
```

## 6. Python Standards

| Rule | Specification |
| :--- | :--- |
| Package manager | `uv` (`uv add`, `uv sync`, `uv run`); `pip`, `pip install`, and `python -m pip` are prohibited |
| Tests | `pytest`; every new behavior comes with a test |
| Code documentation | NumPy-style docstrings on public modules, classes, and functions |
| Typing | Complete annotations, checked by Pyright in `strict` mode |
| Style and quality | `ruff` for lint and formatting; `deptry` for declared and used dependencies |
| Naming | Identifiers in **English** with `snake_case`; comments and docstrings in **Portuguese** |

## 7. Markdown Documentation Rules

Every `README`, `CONTRIBUTING`, and `AUTHORS` maintains mirrored versions in Portuguese (`*.md`) and English (`*.en.md`), following these rules:

1. **Language switcher and license footer:** every `README.md` and `README.en.md` includes the `🌐 [Português](...) · [English](...)` switcher at the top, and every `.md` file ends with the copyright footer linking to `LICENSE`.
2. **Numbered progressive sections:** all sections starting at `##` must be numbered (`## 1.`, `### 1.1.`, `## 2.`) in a logical reading order.
3. **Direct punctuation:**
   - **Em-dashes are prohibited** in prose and tables; use commas, parentheses, semicolons, or colons according to the actual syntactic relationship.
   - **Chained colons are prohibited** (more than one `:` in the same sentence or table cell).
4. **Behavior explanation:** never cite an internal file, module, or signal name as if the name itself explained what the system does; always describe the operation performed.
5. **Non-redundant tables and LaTeX:** structured data belongs in Markdown tables and mathematical/boolean equations in LaTeX blocks (`$$ ... $$` or `$ ... $`), without repeating in prose what the table or equation already states.
6. **No changelog or open TODOs in technical docs:** architecture and contract documents describe exclusively the current state, without historical bugfix notes or unimplemented work lists.
7. **Usage guides only instruct:** installation and run instructions say how to do it, without justifying the choice of method.

## 8. Mandatory Verification Before Opening a Pull Request

Any change to code, configuration, or documentation must pass all commands below without errors before submission:

```bash
make paths       # Verifies that every path listed in the configuration exists
make memory-map  # Validates the platform memory map
make check       # Analyzes and elaborates the simulation top in GHDL
make test        # Runs the per-entity tests of the platform RTL
```

When adding, renaming, or removing any versioned file, immediately update:
- `paths.yaml`
- `platforms/*/platform.yaml`
- `docs/`
- `README.md`, `README.en.md`, and the affected documentation

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](LICENSE).
