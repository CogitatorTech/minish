# ################################################################################
# # Configuration
# ################################################################################
ZIG    ?= $(shell which zig || echo ~/.local/share/zig/0.15.1/zig)
BUILD_TYPE    ?= Debug
BUILD_OPTS    ?= -Doptimize=$(BUILD_TYPE)
JOBS          ?= $(shell nproc || echo 2)

# Helper macro to ensure the Zig compiler exists
check_zig = \
    if [ ! -x "$(ZIG)" ]; then \
      echo "ERROR: Zig compiler not found at '$(ZIG)'."; \
      echo "       Install Zig 0.15.1 and/or set ZIG=/path/to/zig."; \
      echo "       See: https://ziglang.org/download/"; \
      exit 1; \
    fi

# Get all .zig files in the examples directory and extract their stem names
EXAMPLES      := $(patsubst %.zig,%,$(notdir $(wildcard examples/*.zig)))
EXAMPLE       ?= all # Default example to run

TEST_FLAGS := --summary all #--verbose
JUNK_FILES := *.o *.obj *.dSYM *.dll *.so *.dylib *.a *.lib *.pdb temp/

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

# ################################################################################
# # Main Targets
# ################################################################################
.PHONY: all help build rebuild run test release clean
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*## .*$$' Makefile | \
	awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: build test lint docs ## Build, test, lint, and generate documentation

build: ## Build the project (e.g., 'make build BUILD_TYPE=ReleaseSafe')
	@echo "Building project in $(BUILD_TYPE) mode..."
	@$(check_zig)
	@"$(ZIG)" build $(BUILD_OPTS)

rebuild: clean all ## Clean and then build, test, lint, and generate docs

run: ## Run an example (e.g., 'make run EXAMPLE=e1_simple_example')
	@echo "--> Running example: $(EXAMPLE)"
	@"$(ZIG)" build run-$(EXAMPLE) $(BUILD_OPTS)

test: ## Run all unit tests
	@echo "Running tests..."
	@$(check_zig)
	@"$(ZIG)" build test $(BUILD_OPTS) -j$(JOBS) $(TEST_FLAGS)

release: ## Create a release build
	@echo "Building in ReleaseSafe mode..."
	@$(MAKE) build BUILD_TYPE=ReleaseSafe

clean: ## Remove build artifacts and cache
	@echo "Removing build artifacts and cache..."
	@rm -rf zig-out .zig-cache $(JUNK_FILES) docs/api public

# ################################################################################
# # Development Workflow
# ################################################################################
.PHONY: lint format docs serve-docs install-deps setup-hooks

lint: ## Check Zig code formatting
	@echo "Checking code formatting..."
	@$(check_zig)
	@"$(ZIG)" fmt --check .

format: ## Format all Zig files
	@echo "Formatting Zig files..."
	@$(check_zig)
	@"$(ZIG)" fmt .

docs: ## Generate API documentation
	@echo "Generating API documentation..."
	@$(check_zig)
	@"$(ZIG)" build docs

serve-docs: docs ## Serve documentation locally
	@echo "Serving project documentation locally..."
	@cd docs/api && python3 -m http.server 8000

install-deps: ## Install Python development dependencies
	@echo "Installing Python dependencies for development..."
	@pip install -e ".[dev]"

setup-hooks: ## Install Git hooks
	@echo "Installing git hooks..."
	@pre-commit install

test-hooks: ## Run Git hooks on all files
	@echo "Running pre-commit hooks on all files..."
	@pre-commit run --all-files
