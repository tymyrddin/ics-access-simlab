# ICS-SimLab Extended
# Targets handle the generate → build → start lifecycle.
# Requires: docker, docker compose, python3, pyyaml

CONFIG ?= orchestrator/ctf-config.yaml
INTERNET_ZONE_COMPOSE = zones/internet/docker-compose.yml

.PHONY: help generate build up down stop start deploy firewall clean purge test test-unit test-artifacts test-smoke test-firewall

help:
	@echo "Usage: ./ctl <command>   (see ctl for day-to-day use)"
	@echo ""
	@echo "Make targets (CI / advanced use):"
	@echo "  make generate    Read \$(CONFIG), write all docker-compose.yml files"
	@echo "  make build       Build all zone images (runs generate first)"
	@echo "  make up          Start all zones (runs generate first)"
	@echo "  make down        Stop and remove all containers"
	@echo "  make firewall    Apply inter-zone iptables rules (sudo)"
	@echo "  make clean       down + remove all generated files"
	@echo "  make purge       clean + remove all images + prune build cache"
	@echo "  make test        Run unit + artifact tests"
	@echo ""
	@echo "  CONFIG=path/to/ctf-config.yaml make generate"

generate:
	python3 orchestrator/generate.py $(CONFIG)

build: generate
	docker compose -f infrastructure/networks/docker-compose.yml build
	docker compose -f $(INTERNET_ZONE_COMPOSE) build
	docker compose -f zones/enterprise/docker-compose.yml build
	docker compose -f zones/operational/docker-compose.yml build
	docker compose -f zones/control/docker-compose.yml build

up: generate
	bash start.sh
	@[ -f $(INTERNET_ZONE_COMPOSE) ] && docker compose -f $(INTERNET_ZONE_COMPOSE) up -d || true

down:
	@[ -f $(INTERNET_ZONE_COMPOSE) ] && docker compose -f $(INTERNET_ZONE_COMPOSE) down || true
	@[ -f stop.sh ] && bash stop.sh || true

stop:
	@[ -f stop.sh ] && bash stop.sh || echo "stop.sh not found — run 'make generate' first"

start:
	@[ -f start.sh ] && bash start.sh || echo "start.sh not found — run 'make generate' first"
	@[ -f $(INTERNET_ZONE_COMPOSE) ] && docker compose -f $(INTERNET_ZONE_COMPOSE) up -d || true

deploy: up

firewall:
	sudo bash infrastructure/firewall.sh

clean: down
	rm -f start.sh stop.sh
	rm -f infrastructure/networks/docker-compose.yml
	rm -f infrastructure/firewall.sh
	rm -f zones/internet/docker-compose.yml
	rm -f zones/enterprise/docker-compose.yml
	rm -f zones/operational/docker-compose.yml
	rm -f zones/control/docker-compose.yml
	rm -f zones/internet/components/attacker-machine/adversary-readme.txt

purge:
	@[ -f $(INTERNET_ZONE_COMPOSE) ]                                               && docker compose -f $(INTERNET_ZONE_COMPOSE) down --rmi all 2>/dev/null || true
	@[ -f zones/enterprise/docker-compose.yml ]        && docker compose -f zones/enterprise/docker-compose.yml down --rmi all 2>/dev/null || true
	@[ -f zones/operational/docker-compose.yml ]       && docker compose -f zones/operational/docker-compose.yml down --rmi all 2>/dev/null || true
	@[ -f zones/control/docker-compose.yml ]           && docker compose -f zones/control/docker-compose.yml down --rmi all 2>/dev/null || true
	@[ -f infrastructure/networks/docker-compose.yml ] && docker compose -f infrastructure/networks/docker-compose.yml down --rmi all 2>/dev/null || true
	docker builder prune -f
	rm -f start.sh stop.sh
	rm -f infrastructure/networks/docker-compose.yml
	rm -f infrastructure/firewall.sh
	rm -f zones/internet/docker-compose.yml
	rm -f zones/enterprise/docker-compose.yml
	rm -f zones/operational/docker-compose.yml
	rm -f zones/control/docker-compose.yml
	rm -f zones/internet/components/attacker-machine/adversary-readme.txt

test-unit:
	pytest tests/unit/ -v

test-artifacts: generate
	pytest tests/integration/ -v

test-smoke:
	@for f in tests/smoke/test_*.sh; do bash "$$f" || true; done

test-firewall:
	sudo bash tests/smoke/test_firewall.sh

test: test-unit test-artifacts test-smoke
