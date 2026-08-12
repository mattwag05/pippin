INSTALL_DIR := $(HOME)/.local/bin
VERSION := $(shell grep 'static let version' pippin/Version.swift | sed 's/.*"\(.*\)"/\1/')

.PHONY: build test lint e2e ci ci-vm install sign completions version release tarball clean link-skills

build:
	xcrun --sdk macosx swift build -c release

# `xcrun --sdk macosx` routes through xcode-select's developer dir. On a host
# with Xcode installed it picks the Xcode SDK (XCTest present); on a CLT-only
# macOS 26 host the CLT SDK lacks XCTest.framework so `swift test` fails with
# "no such module XCTest". The preflight below detects that: if XCTest isn't in
# the selected SDK but an Xcode (any name — Xcode.app, Xcode-beta.app) is
# installed, it transparently runs under that DEVELOPER_DIR so `make test` just
# works; otherwise it prints an actionable error instead of the cryptic
# compiler message. Probe checks the framework dir directly — `xcrun --find
# xctest` gives false results under CLT. See pippin-ncr, pippin-eby.
test:
	@platform="$$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)"; \
	if [ -d "$$platform/Developer/Library/Frameworks/XCTest.framework" ]; then \
		xcrun --sdk macosx swift test; \
	else \
		xcode_dev="$$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | sort | head -1)"; \
		if [ -n "$$xcode_dev" ]; then \
			echo "make: XCTest not in the selected SDK (Command Line Tools); using $$xcode_dev."; \
			DEVELOPER_DIR="$$xcode_dev" xcrun --sdk macosx swift test; \
		else \
			echo "ERROR: XCTest.framework is unavailable — the Command Line Tools SDK on macOS 26 does not ship it."; \
			echo "Install Xcode, or set DEVELOPER_DIR to an Xcode developer dir, then re-run 'make test'."; \
			echo "See pippin-ncr / pippin-eby."; \
			exit 1; \
		fi; \
	fi

lint:
	@command -v swiftformat >/dev/null 2>&1 || { echo "❌ swiftformat not installed — brew install swiftformat (lint gate cannot pass without it)"; exit 1; }
	swiftformat --lint pippin/ pippin-entry/ Tests/

# Autonomous E2E smoke against LIVE Apple apps via the TCC-granted binary
# (~/.local/bin/pippin). Read-only by default; E2E_RW=1 adds write round-trips.
# Exit 2 = permissions missing (run `pippin permissions` interactively once).
e2e:
	./scripts/e2e-smoke.sh $(if $(E2E_RW),--rw,)

# Full CI gate run NATIVELY on this host (fast, no VM). Mirrors ci.yml.
ci:
	xcrun --sdk macosx swift build -c release
	@$(MAKE) test
	@command -v swiftformat >/dev/null 2>&1 || { echo "❌ swiftformat not installed — brew install swiftformat (CI lint gate cannot pass without it)"; exit 1; }
	swiftformat --lint pippin/ pippin-entry/ Tests/
	python3 scripts/lint-detach-blocking.py --self-test
	python3 scripts/lint-detach-blocking.py
	python3 scripts/lint-paginated-emit.py --self-test
	python3 scripts/lint-paginated-emit.py

# Full CI gate run inside an isolated, ephemeral macOS VM (Tart + Cirrus Xcode
# image) — local parity with the macos-15 GitHub runner, zero hosted minutes,
# no listening runner exposed to public fork PRs. One-time setup:
#   brew install cirruslabs/cli/tart hudochenkov/sshpass/sshpass
#   tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest pippin-ci-base
ci-vm:
	@bash scripts/ci-vm.sh

completions: build
	@mkdir -p "$(HOME)/.zfunc"
	"$$(swift build -c release --show-bin-path)/pippin" completions zsh > "$(HOME)/.zfunc/_pippin"
	@echo "Installed: ~/.zfunc/_pippin"
	@echo "Add 'fpath=(~/.zfunc \$$fpath)' to ~/.zshrc, then 'autoload -Uz compinit && compinit'"

# Sign the release binary with a stable identity so macOS TCC permission grants
# persist across rebuilds/upgrades. Guarded — no-ops (ad-hoc fallback) when no
# Developer ID identity is present, so CI / the ci-vm / other machines still
# build. See scripts/sign.sh + docs/gotchas/permissions.md (pippin-xzu).
sign: build
	@bash scripts/sign.sh "$$(swift build -c release --show-bin-path)/pippin"

install: build completions sign
	@mkdir -p "$(INSTALL_DIR)"
	@# rm before cp: overwriting a signed binary in place reuses the inode, and
	@# AMFI's cached code signature for that vnode goes stale → the next launch is
	@# SIGKILLed ("Killed: 9") even though `codesign --verify` passes on disk.
	@# A fresh inode avoids the stale-cache kill.
	rm -f "$(INSTALL_DIR)/pippin"
	cp "$$(swift build -c release --show-bin-path)/pippin" "$(INSTALL_DIR)/pippin"
	@echo "Installed: $(INSTALL_DIR)/pippin ($(VERSION))"
	@echo "Run 'pippin permissions' once to grant access (grants now persist if signed)."

version:
	@echo $(VERSION)

release: build sign
	@mkdir -p .build/release-artifacts
	cp "$$(swift build -c release --show-bin-path)/pippin" ".build/release-artifacts/pippin-$(VERSION)-arm64-macos"
	@echo "Release binary: .build/release-artifacts/pippin-$(VERSION)-arm64-macos"

tarball: release
	cd .build/release-artifacts && tar czf pippin-$(VERSION)-arm64-macos.tar.gz pippin-$(VERSION)-arm64-macos
	@echo "Tarball: .build/release-artifacts/pippin-$(VERSION)-arm64-macos.tar.gz"

clean:
	swift package clean
	rm -rf .build/release-artifacts

link-skills:
	@mkdir -p .claude/skills
	@for skill in docs/skills/*/; do \
		[ -d "$$skill" ] || continue; \
		name=$$(basename "$$skill"); \
		target="../../docs/skills/$$name"; \
		ln -sfn "$$target" ".claude/skills/$$name" || exit 1; \
		echo "Linked: .claude/skills/$$name -> $$target"; \
	done
