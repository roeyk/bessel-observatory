BESSEL OBSERVATORY — 30 languages

Project guide: README.md. Development workflow: CONTRIBUTING.md.
Change history: CHANGELOG.md and Git. License: GPL-3.0-only (see LICENSE).

Open index.html for source links, build/run instructions, the mathematical
definition, methodology, dialect choices and per-language verification status.
manifest.json is the machine-readable project description and specification.

Quick start (from this directory):
    python3 bessel.py examples/values.txt results.csv 2
    python3 bessel.py - results.csv 4

Common CLI:
    PROGRAM [INPUT|- [OUTPUT [WORKERS]]]
Default: stdin, results.csv, 2 workers. Use --help for usage.
Enter one finite x in [-1000,1000] per line; a blank line or EOF finishes.
The first blank line also terminates file input. # comments are ignored.
Invalid rows are reported and skipped. At most 4096 valid values are accepted.
The CSV contains x,j0,worker_pid in input order.

The PostgreSQL edition uses psql -v arguments and a comma-separated prompt;
its server-side file input and dblink setup are documented in index.html.

Verification:
    python3 tests/verify.py
    python3 tests/verify.py --only python,c,rust
    python3 tools/render_index.py

Each edition implements its own numerical kernel. Bash uses an embedded awk
loop for floating-point math. Oberon uses the included C adapter for checked
OS/stdio calls; Perligata exposes its Perl compatibility module as BesselPerligata.pm.
Some historical languages use POSIX bindings for processes. See the manifest for platform and
ABI requirements. Untested editions are explicitly marked; the presence of
source does not imply that an unavailable toolchain was tested.

MEMORY AND STRINGS

The source files now include pointers/references and pointer arithmetic where
the target supports them. Unsafe examples keep the owner alive and offsets
within bounds. Safe languages use documented buffer/view/reference equivalents;
SQL, Prolog and Erlang are not presented as having raw memory pointers.
Every edition also demonstrates input cleanup and output string construction.

The index has adjacent highlighted-HTML and raw-source columns. Regenerate
the offline code pages with python3 tools/render_sources.py (Pygments needed
only for regeneration, not browsing).

ADDITIONAL DIALECTS AND COMMENTS

RPG targets IBM i; rpg_setup.txt explains compilation, queue setup, native CALL
parameters, job-message errors, and the differences from the Unix interface.
Oberon-2 targets Oxford OBC 3; tools/build_oberon.sh isolates build products.
Install Perligata with cpanm Lingua::Romana::Perligata. Its Latin program uses
Latin roots, native file open/write/close, adnota and ecce comments. The linked
BesselPerligata.pm handles regexes, raw line reads and checked OS/exception
services; the native reader would convert Roman numerals in decimal input.

Functions have purpose/input/output/caller comments. Blocks explain their
functional effect. Native block-comment forms are used where supported;
Python uses # comments, and languages without block comments use line comments.

To regenerate the complete offline catalogue:
    python3 tools/render_sources.py
    python3 tools/render_index.py
    python3 tests/verify_catalog.py

The HTML needs no network or server. Build dependencies are not bundled;
locally unpacked toolchains used during validation are documented in tests.
