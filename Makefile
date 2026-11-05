# Portable entry points for the catalogue and the routinely available editions.
PYTHON ?= python3
RUFF ?= ruff
EDITIONS ?= c,cpp,python,bash,perl,ruby

.PHONY: help docs check check-catalog lint test

help:
	@echo 'make docs           Regenerate all offline catalogue pages'
	@echo 'make check          Verify catalogue, lint tooling, run six editions'
	@echo 'make test EDITIONS=python,c   Run selected editions; none may be skipped'

docs:
	$(PYTHON) tools/render_sources.py
	$(PYTHON) tools/render_index.py

check-catalog:
	$(PYTHON) tests/verify_catalog.py

lint:
	$(RUFF) check .

test:
	$(PYTHON) tests/verify.py --only $(EDITIONS) --require-all --report build/check-report.json

check: check-catalog lint test
