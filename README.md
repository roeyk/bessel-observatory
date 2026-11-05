# Bessel Observatory

The same numerical program in **30 languages**, with an offline, syntax-highlighted
source catalogue. Each edition reads observations, calculates Bessel J₀ in
separate operating-system processes, and writes ordered CSV results.

Open [index.html](index.html) from a local checkout for the alphabetical language
table, adjacent highlighted-code and raw-source links, build instructions,
memory and string examples, and validation status. GitHub's file viewer shows
HTML source; download or clone the repository to use the interactive catalogue.

## Run an edition

Python 3.10 or later needs no third-party packages:

```sh
python3 bessel.py examples/values.txt results.csv 2
python3 bessel.py - results.csv 4
```

The common command line is `PROGRAM [INPUT|- [OUTPUT [WORKERS]]]`. Defaults are
stdin, `results.csv`, and two workers. Enter one finite decimal value in
`[-1000,1000]` per line. A blank line or EOF finishes input; lines beginning with
`#` are comments. Invalid values produce diagnostics and are skipped. The
maximum is 4,096 accepted observations and 16 simultaneous numeric workers.

The output columns are `x,j0,worker_pid`. See [manifest.json](manifest.json) for
the description, goals, methodology, exact contract, dialects, and per-language
build/run commands. Build products belong under `build/`.

## Languages and adaptations

Ada, Bash, BASIC, C, C++, COBOL, Erlang, Fortran, Go, Haskell, Java, JavaScript,
Julia, Kotlin, Lingua::Romana::Perligata, Lisp, Lua, Oberon-2, Objective-C, OCaml,
Pascal, Perl, Prolog, Python, RPG, Ruby, Rust, Smalltalk, SQL, and Swift.

The editions use their language's idioms and comment conventions. Function
comments explain purpose, inputs, outputs, and callers. Pointer arithmetic is
demonstrated where supported; other editions describe their actual reference,
buffer-offset, or relational model. All editions manipulate input/output strings.

- Bash embeds an `awk` floating-point kernel because shell arithmetic is integer-only.
- Oberon-2 uses the supplied C adapter for checked POSIX and stdio interfaces;
  its quadrature and address traversal remain Oberon.
- Perligata uses Latin-root vocabulary and native file opening, writing and
  closing. [BesselPerligata.pm](BesselPerligata.pm) provides regex validation,
  unchanged line reads and checked OS/exception services; its highlighted view
  is linked beside the main listing. Native `perlege` converts Roman numerals,
  so the bridge preserves the shared decimal-input contract. Install
  `Lingua::Romana::Perligata` 0.605 from CPAN. Its
  [grammar](https://metacpan.org/dist/Lingua-Romana-Perligata/view/lib/Lingua/Romana/Perligata.pm)
  uses regularized Latin nouns and verbs within a restricted syntax.
- SQL targets PostgreSQL, `psql`, and `dblink`; setup is in the HTML catalogue.
- RPG targets IBM i. Read [rpg_setup.txt](rpg_setup.txt) before compiling or
  configuring its batch queue. Its CALL parameters and job-message errors are
  native IBM i interfaces.

Use `tools/build_basic.sh` for FreeBASIC: compiling `bessel.bas` directly can
create and remove a C intermediate named `bessel.c`, damaging the C edition.
Use `tools/build_oberon.sh` to isolate OBC's generated files.

## Mathematics and evidence

Every kernel uses 16,384 midpoint samples of the integral
`J₀(x) = (1/π) ∫₀^π cos(x sin θ) dθ`.
See the [NIST DLMF Bessel integral](https://dlmf.nist.gov/10.9#E1).
This is a special-function and language comparison, not a speed ranking or
certified numerical library.

The recorded baseline has **25 editions passing all 11 behavioral checks**.
Smalltalk, Julia, Swift, SQL, and RPG are explicitly untested in that baseline.
[tests/report.json](tests/report.json) ties the evidence to source hashes
(and the declared Perligata helper dependency);
[tests/validation.txt](tests/validation.txt) explains toolchains, test scope,
limitations, and independent 80-digit reference values.

## Development

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
make check
```

`make check` verifies the catalogue, lints Python tooling, and runs the C, C++,
Python, Bash, Perl, and Ruby editions. Install their toolchains first. It writes
fresh evidence under `build/` and preserves the committed 30-language baseline.
GitHub Actions runs the same checks and verifies reproducible generated HTML.

```sh
# Check a selected edition without replacing the committed baseline report.
python3 tests/verify.py --only python --require-all --report build/python-report.json
# Rebuild the offline catalogue after source or manifest edits.
make docs
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development and validation workflow,
[CHANGELOG.md](CHANGELOG.md) for user-visible changes, and Git history for exact
patches. Private discussion records, tickets, session logs, and handoffs are kept
in a separate support tree, outside the published source repository.

## License

Copyright © 2026 Bessel Observatory contributors.
Licensed under the **GNU General Public License, version 3 only**
(`GPL-3.0-only`). See [LICENSE](LICENSE). Compilers, runtimes, and dependencies
retain their own licenses and are not bundled in this repository.
