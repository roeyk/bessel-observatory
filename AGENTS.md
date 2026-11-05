# Bessel Observatory contributor instructions

Read README.md, CONTRIBUTING.md, manifest.json, and the relevant source before
editing. Inspect Git status, diffs, and recent history; preserve unrelated work.
Private maintainer tracking lives outside this checkout. If the session supplies
that support-tree location, read its handoff and applicable ticket as well.

The user's current instruction determines the authorized scope. Do not treat a
handoff's unfinished task as authorization for unrelated work. Keep substantial
changes tied to acceptance criteria and recorded validation.

Preserve idiomatic editions, real OS multiprocessing, honest memory-model
descriptions, and functional comments with purpose/input/output/caller contracts.
Use each language's native block comments when available; Python comments use #.

Never compile bessel.bas directly in this directory. Use tools/build_basic.sh;
FreeBASIC can otherwise overwrite and remove the C edition's bessel.c.
Use tools/build_oberon.sh to contain OBC build products.

Run checks appropriate to the change, as specified in CONTRIBUTING.md. Put
partial execution reports in build/, not tests/report.json. Regenerate HTML
through its tools, retain alphabetical order, and verify local links and hashes.

Keep local paths, private development records, toolchain overrides, credentials,
compiler output, and result files out of commits. Document platform limitations
and untested editions accurately. Update CHANGELOG.md for user-visible changes.
