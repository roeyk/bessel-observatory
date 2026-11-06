# Contributing

Keep the editions comparable while respecting each language's conventions.
The shared behavior is specified in [manifest.json](manifest.json); any intended
contract change needs an explicit rationale and updates to affected editions.

## Track a change

1. Record the problem, acceptance criteria, and proposed scope before substantial
   work. Maintainers keep private planning and discussion history outside this
   checkout; public contributions can use a GitHub issue or pull request.
2. Inspect the current branch, working tree, and relevant history. Preserve
   unrelated changes. Use a focused branch for a coherent change.
3. Implement and validate a small batch. Record the results with the change.
4. Update the changelog for user-visible behavior, the manifest for contract or
   toolchain changes, and the private ticket/action log when applicable.
5. Commit with a description of the resulting behavior. Do not invent historical
   commits or timestamps for work that predates this repository.

## Source and comment style

Keep each numerical kernel and orchestration idiomatic to its edition. Document
necessary bridges, dialect extensions, and interface differences. Do not replace
an edition's kernel with a call to another edition.

Comments explain what a statement or paragraph accomplishes. Put a contract
above each function or procedure stating its purpose, inputs, outputs, and who
uses it for what purpose. End-of-line comments are welcome when they clarify a
local effect. Use native multiline comments where available; use `#` for Python,
not triple-quoted strings as comments. Do not invent block-comment syntax in
languages that only have line comments.

Unsafe memory examples must state bounds and lifetime assumptions. Languages
without raw pointers should demonstrate and describe their native models.
Preserve genuine OS multiprocessing and the meaning of `worker_pid`.

## Validate the affected surface

| Change | Required evidence |
| --- | --- |
| Documentation | Check links and commands; review the rendered result when applicable. |
| Catalogue or generators | `make docs`, `make check-catalog`, `make lint`; inspect generated diffs. |
| An edition's behavior | Run its compiler/interpreter and all shared behavior checks with `--require-all`. |
| Shared contract or test harness | Run `make check` and the wider available language matrix; record unavailable toolchains. |
| Publication | Check the diff and staged contents for private data; keep support material and build outputs outside commits. |

The project uses a standard-library Python test harness. It does not need a
Python package layout or a separate pytest suite for equivalent checks.
Compilers perform their languages' syntax/type validation. Python tooling has a
small Ruff configuration focused on actual errors, rather than reformatting the
language examples.

Use `python3 tests/verify.py --only python --require-all --report build/check.json`
for selected runs. `--overrides FILE` accepts a JSON mapping from language IDs to
build, run, and environment settings for local toolchains. Keep machine-specific
overrides outside the repository. Without `--only`, the runner attempts every
edition; missing runtimes and integration services are reported as untested.

Do not overwrite `tests/report.json` with a partial run. When intentionally
updating the committed baseline, merge fresh evidence for changed editions,
retain evidence only for unchanged source hashes (including any manifest
`validation_dependencies`), and mark unavailable changed
editions untested. Then regenerate and verify the catalogue. A source review is
not execution evidence. CI reports belong in CI artifacts or ignored `build/`.

Pygments is pinned in `requirements-dev.txt` so generated pages are reproducible.
The HTML is committed for offline browsing; edit its generators or source files,
then run `make docs`. Keep the index alphabetized.

Maintain each language's `adaptations` in the manifest: objective, kind
(`workaround`, `platform`, or `native`), constraint, approach, tradeoff, and
source references. Each reference names a declared main/support source, a
unique single-line `match` substring, and a readable label. The generator
resolves highlighted line anchors on every rebuild and rejects stale or
ambiguous matches; text-only support files link to the raw document.
Describe actual implementation choices, without treating native error-handling
or memory models as missing features. Keep execution status tied to the report.

GitHub Pages publishes the root of `main` at
https://roeyk.github.io/bessel-observatory/. Keep `.nojekyll` and commit regenerated
HTML with source changes; the same relative links support online and offline use.

## Boundaries

Only source, portable docs, examples, reviewed validation records, and generated
offline catalogue assets belong in this repository. Exclude local machine
paths, personal input, credentials, session transcripts, private trackers,
temporary compiler installations, binaries, caches, and generated result CSVs.

Do not change repository visibility, licensing, remotes, releases, or publishing
destinations without an explicit maintainer instruction. The initial publication
was authorized as public under GPL-3.0-only; it does not authorize unrelated
future releases or destinations.
