# Common tasks. `make check` is what CI runs.

.DEFAULT_GOAL := help
SWIFT ?= swift

.PHONY: help build test lint format sizes check app clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build everything
	$(SWIFT) build

test: ## Run the test suite
	$(SWIFT) test

lint: ## Fail on style or documentation violations
	@./scripts/lint.sh

format: ## Reformat sources in place
	@./scripts/format.sh

sizes: ## Fail if any source file has grown too large
	@./scripts/check-file-sizes.sh

check: lint sizes build test ## Everything CI checks

app: ## Build the menu bar app bundle into dist/
	@./scripts/build-app.sh

clean: ## Remove build products
	rm -rf .build dist
