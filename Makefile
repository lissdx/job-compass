# Single entry point for every command in this project.
# Nothing here needs an activated virtualenv: uv resolves the environment itself.

.DEFAULT_GOAL := help
.PHONY: help install lint format typecheck test check migrate clean

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

install:  ## Create/refresh the virtualenv from uv.lock
	uv sync

lint:  ## Lint (same check CI runs)
	uv run ruff check .

format:  ## Format the tree in place
	uv run ruff format .

typecheck:  ## Type-check in strict mode
	uv run mypy

test:  ## Run the unit tests
	uv run pytest tests/unit

check: lint typecheck test  ## Everything CI gates on, in CI order

migrate:  ## Apply every migration to the local database
	@mkdir -p db/sqlite
	@for f in db/sqlite/migrations/*.sql; do \
		echo "applying $$f"; \
		sqlite3 "$${JOB_COMPASS_DB:-db/sqlite/jobcompass.db}" < "$$f"; \
	done

clean:  ## Remove caches and build artifacts
	rm -rf .pytest_cache .mypy_cache .ruff_cache dist build *.egg-info
