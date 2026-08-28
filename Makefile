# Common tasks. `make check` is what CI runs.

.DEFAULT_GOAL := help
SWIFT ?= swift

.PHONY: help build test coverage lint format sizes check app clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build everything
	$(SWIFT) build

test: ## Run the test suite
	$(SWIFT) test

# `swift test --show-codecov-path` gives the exported JSON, not the profile
# llvm-cov wants, so the profdata path is spelled out.
coverage: ## Report test coverage per file
	@$(SWIFT) test --enable-code-coverage >/dev/null
	@BIN=$$($(SWIFT) build --show-bin-path); xcrun llvm-cov report \
		"$$BIN/SaplingPackageTests.xctest/Contents/MacOS/SaplingPackageTests" \
		-instr-profile "$$BIN/codecov/default.profdata" \
		-ignore-filename-regex='Tests|\.build'

lint: ## Fail on style or documentation violations
	@./scripts/lint.sh
	@./scripts/check-workflows.sh

format: ## Reformat sources in place
	@./scripts/format.sh

sizes: ## Fail if any source file has grown too large
	@./scripts/check-file-sizes.sh

check: lint sizes build test ## Everything CI checks

app: ## Build the menu bar app bundle into dist/
	@./scripts/build-app.sh

clean: ## Remove build products
	rm -rf .build dist
