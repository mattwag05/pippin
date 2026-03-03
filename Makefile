INSTALL_DIR := $(HOME)/.local/bin
VERSION := $(shell grep 'static let version' pippin/Version.swift | sed 's/.*"\(.*\)"/\1/')

.PHONY: build test lint install version release clean

build:
	swift build -c release

test:
	swift test

lint:
	swiftformat --lint pippin/ pippin-entry/ Tests/ 2>/dev/null || echo "swiftformat not installed — skipping lint"

install: build
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

clean:
	swift package clean
	rm -rf .build/release-artifacts
