SHELL := /bin/bash
.DEFAULT_GOAL := help

PNPM ?= pnpm
CARGO ?= cargo
PYTHON ?= python3
CARGO_MANIFEST := src-tauri/Cargo.toml
PROFILE ?= release
APP_PATH = src-tauri/target/$(PROFILE)/bundle/macos/Mac Voice Mix.app

# Serialize aggregate targets so Cargo checks and builds do not contend for locks.
.NOTPARALLEL:
.PHONY: help install dev preview build build-debug build-web open check typecheck fmt fmt-check lint test test-web test-rust test-native test-native-write probe-signal verify clean

help: ## Show available commands (default).
	@awk 'BEGIN { FS = ":.*## "; print "Usage: make <target>\n" } /^[a-zA-Z0-9_-]+:.*## / { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nOptions: PNPM=pnpm CARGO=cargo PYTHON=python3 PROFILE=release|debug\n'

install: ## Install frontend dependencies using the lockfile.
	$(PNPM) install --frozen-lockfile

dev: ## Start the Tauri desktop app with live reload.
	$(PNPM) tauri dev

preview: ## Start browser UI preview with simulated audio devices.
	$(PNPM) dev

build: ## Build release macOS app and DMG.
	$(PNPM) build:mac

build-debug: ## Build debug macOS app and DMG.
	$(PNPM) tauri build --debug --bundles app,dmg

build-web: ## Typecheck and build frontend assets only.
	$(PNPM) build

open: ## Open an existing app bundle (PROFILE=release or debug).
	@test -d "$(APP_PATH)" || { printf 'App not found: %s\nRun make build or make build-debug first.\n' "$(APP_PATH)" >&2; exit 1; }
	open "$(APP_PATH)"

check: typecheck fmt-check lint ## Run TypeScript, Rust formatting and Clippy checks.

typecheck: ## Check TypeScript types.
	$(PNPM) typecheck

fmt: ## Format Rust source.
	$(CARGO) fmt --manifest-path $(CARGO_MANIFEST)

fmt-check: ## Check Rust formatting without editing files.
	$(CARGO) fmt --manifest-path $(CARGO_MANIFEST) --check

lint: ## Run Clippy and reject warnings.
	$(CARGO) clippy --manifest-path $(CARGO_MANIFEST) --all-targets -- -D warnings

test: test-web test-rust test-native ## Run frontend, Rust and native tests (device reads only).

test-web: ## Run frontend unit tests.
	$(PNPM) test

test-rust: ## Run Rust unit and documentation tests.
	$(CARGO) test --manifest-path $(CARGO_MANIFEST)

test-native: ## Test PCM processing and read-only macOS device enumeration.
	bash scripts/test-native.sh

test-native-write: ## Briefly change default device volumes, test and restore them.
	bash scripts/test-native.sh --write-device

probe-signal: ## Play a quiet tone and test app mixing using an existing app bundle.
	@test -x "$(APP_PATH)/Contents/MacOS/mac-voice-mix" || { printf 'Build the %s app before running probe-signal.\n' "$(PROFILE)" >&2; exit 1; }
	$(PYTHON) scripts/probe-signal.py "$(APP_PATH)/Contents/MacOS/mac-voice-mix"

verify: check test ## Run all checks and tests; excludes audio playback and device writes.

clean: ## Remove frontend and Cargo build artifacts; keep dependencies and settings.
	$(CARGO) clean --manifest-path $(CARGO_MANIFEST)
	rm -rf dist
