# ICS-Access-SimLab
# Thin wrapper around ./ctl for CI and habitual `make`-typers.
# Day-to-day, use ./ctl directly.

CONFIG ?= orchestrator/ctf-config.yaml
export CONFIG

.PHONY: help generate up down clean purge test test-unit test-artifacts test-smoke

help:
	@echo "Usage: ./ctl <command>   (preferred for day-to-day use)"
	@echo ""
	@echo "Make targets (CI / muscle memory):"
	@echo "  make generate       Regenerate compose + clab files from \$$(CONFIG)"
	@echo "  make up             Build images, create bridges, start clab zones"
	@echo "  make down           Stop clab zones, remove containers"
	@echo "  make clean          down + remove generated files"
	@echo "  make purge          clean + remove all images"
	@echo "  make test           Unit + artifact tests (smoke needs a running lab)"
	@echo ""
	@echo "  CONFIG=path/to/config.yaml make <target>"

generate:
	./ctl generate

up:
	./ctl up

down:
	./ctl down

clean:
	./ctl clean

purge:
	./ctl purge

test-unit:
	pytest tests/unit/ -v

test-artifacts: generate
	pytest tests/integration/ -v

test-smoke:
	@for f in tests/smoke/test_*.sh; do bash "$$f" || true; done

test: test-unit test-artifacts
