INSTALL_DIR := $(HOME)/.local/bin
VERSION := $(shell grep 'static let version' pippin/Version.swift | sed 's/.*"\(.*\)"/\1/')

.PHONY: build test lint ci ci-vm install completions version release tarball clean link-skills

build:
	xcrun --sdk macosx swift build -c release

# `xcrun --sdk macosx` routes through xcode-select's developer dir. On a host
# with Xcode installed it picks the Xcode SDK (XCTest present); on a CLT-only
# macOS 26 host the CLT SDK lacks XCTest.framework so `swift test` fails with
# "no such module XCTest". The preflight below detects that: if XCTest isn't in
# the selected SDK but Xcode is installed, it transparently runs under Xcode's
# DEVELOPER_DIR so `make test` just works; otherwise it prints an actionable
# error instead of the cryptic compiler message. See pippin-ncr.
test:
	@if xcrun --sdk macosx --find xctest >/dev/null 2>&1; then \
		xcrun --sdk macosx swift test; \
	elif [ -d /Applications/Xcode.app/Contents/Developer ]; then \
		echo "make: XCTest not in the selected SDK (Command Line Tools); using Xcode's toolchain."; \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx swift test; \
	else \
		echo "ERROR: XCTest.framework is unavailable — the Command Line Tools SDK on macOS 26 does not ship it."; \
		echo "Install Xcode, or set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer, then re-run 'make test'."; \
		echo "See pippin-ncr."; \
		exit 1; \
	fi

lint:
	swiftformat --lint pippin/ pippin-entry/ Tests/ 2>/dev/null || echo "swiftformat not installed — skipping lint"

# Full CI gate run NATIVELY on this host (fast, no VM). Mirrors ci.yml.
ci:
	xcrun --sdk macosx swift build -c release
	xcrun --sdk macosx swift test
	swiftformat --lint pippin/ pippin-entry/ Tests/
	python3 scripts/lint-detach-blocking.py --self-test
	python3 scripts/lint-detach-blocking.py

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

install: build completions
	@mkdir -p "$(INSTALL_DIR)"
	cp "$$(swift build -c release --show-bin-path)/pippin" "$(INSTALL_DIR)/pippin"
	@echo "Installed: $(INSTALL_DIR)/pippin ($(VERSION))"
	@echo "Run 'pippin init' to check permissions."

version:
	@echo $(VERSION)

release: build
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
