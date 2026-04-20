INSTALL_DIR := $(HOME)/.local/bin
VERSION := $(shell grep 'static let version' pippin/Version.swift | sed 's/.*"\(.*\)"/\1/')

.PHONY: build test lint install completions version release tarball clean link-skills

build:
	swift build -c release

test:
	swift test

lint:
	swiftformat --lint pippin/ pippin-entry/ Tests/ 2>/dev/null || echo "swiftformat not installed — skipping lint"

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
		name=$$(basename $$skill); \
		ln -sfn "../../$$skill" ".claude/skills/$$name"; \
		echo "Linked: .claude/skills/$$name -> $$skill"; \
	done
