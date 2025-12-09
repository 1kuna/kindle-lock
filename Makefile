.PHONY: install install-dev dev test lint login setup clean help
.PHONY: docker-build docker-setup docker-up docker-down docker-logs docker-shell

# Default Python interpreter
PYTHON ?= python3

help:
	@echo "Read-to-Unlock Development Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make install      Install production dependencies"
	@echo "  make install-dev  Install with development dependencies"
	@echo "  make setup        Full setup including Playwright browsers"
	@echo ""
	@echo "Development:"
	@echo "  make dev          Run development server with auto-reload"
	@echo "  make test         Run test suite"
	@echo "  make lint         Run linter (ruff)"
	@echo ""
	@echo "Kindle:"
	@echo "  make login        Run interactive Amazon login helper"
	@echo "  make scrape       Trigger a manual scrape"
	@echo ""
	@echo "Docker (for Raspberry Pi deployment):"
	@echo "  make docker-build   Build Docker images"
	@echo "  make docker-setup   Run initial Amazon login via VNC"
	@echo "  make docker-up      Start with Cloudflare tunnel"
	@echo "  make docker-down    Stop all containers"
	@echo "  make docker-logs    View container logs"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean        Remove generated files"

install:
	$(PYTHON) -m pip install -e .

install-dev:
	$(PYTHON) -m pip install -e ".[dev]"

setup: install-dev
	$(PYTHON) -m playwright install chromium
	$(PYTHON) -m playwright install-deps chromium
	@echo ""
	@echo "Setup complete! Next steps:"
	@echo "1. Copy .env.example to .env and fill in your credentials"
	@echo "2. Run 'make login' to authenticate with Amazon"
	@echo "3. Run 'make dev' to start the development server"

dev:
	$(PYTHON) -m uvicorn src.main:app --reload --host 0.0.0.0 --port 8080

test:
	$(PYTHON) -m pytest -v

lint:
	$(PYTHON) -m ruff check src/ tests/

lint-fix:
	$(PYTHON) -m ruff check --fix src/ tests/

login:
	BROWSER_HEADLESS=false $(PYTHON) scripts/login.py

scrape:
	@curl -X POST http://localhost:8080/refresh -H "Content-Type: application/json" | $(PYTHON) -m json.tool

clean:
	rm -rf data/reading.db
	rm -rf data/browser_profile
	rm -rf __pycache__ src/__pycache__ tests/__pycache__
	rm -rf .pytest_cache .ruff_cache
	rm -rf *.egg-info
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# ===========================================
# Docker Commands (for Raspberry Pi deployment)
# ===========================================

docker-build:
	docker compose build

docker-setup:
	@echo "Starting VNC setup for Amazon login..."
	@echo "Open http://localhost:6080 in your browser to complete login"
	KINDLE_SETUP_MODE=true docker compose --profile setup up

docker-up:
	docker compose --profile cloudflare up -d

docker-up-tailscale:
	docker compose --profile tailscale up -d

docker-up-expose:
	docker compose --profile expose up -d

docker-down:
	docker compose --profile cloudflare --profile tailscale --profile expose --profile setup down

docker-logs:
	docker compose logs -f kindle-lock

docker-shell:
	docker compose exec kindle-lock /bin/bash

docker-clean:
	docker compose --profile cloudflare --profile tailscale --profile expose --profile setup down -v
	docker rmi kindle-lock-kindle-lock kindle-lock-novnc 2>/dev/null || true
