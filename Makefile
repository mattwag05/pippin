INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build install install-memos install-all clean

build:
	swift build -c release

install: build
	cp "$$(swift build -c release --show-bin-path)/pippin" "$(INSTALL_DIR)/pippin"
	@echo "Installed: $(INSTALL_DIR)/pippin"
	@echo "Run each subcommand once interactively to grant TCC permissions:"
	@echo "  $(INSTALL_DIR)/pippin mail list"
	@echo "  $(INSTALL_DIR)/pippin memos list"

install-memos:
	cd pippin-memos && pipx install --force .
	@echo "Installed: $(INSTALL_DIR)/pippin-memos"

install-all: install install-memos

clean:
	swift package clean
