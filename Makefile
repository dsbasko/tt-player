DATA_DIR = $(HOME)/.local/share/tts-player
VENV_DIR = $(DATA_DIR)/.venv
BIN_DIR = /usr/local/bin
BINARY = tts_player

.PHONY: build setup install uninstall clean run kill status play

build:
	swiftc -O -o $(BINARY) tts_player.swift

setup:
	@mkdir -p $(DATA_DIR)
	@if [ ! -d "$(VENV_DIR)" ]; then \
		echo "Creating Python venv..."; \
		python3 -m venv $(VENV_DIR); \
	fi
	@echo "Installing edge-tts..."
	@$(VENV_DIR)/bin/pip install --quiet --upgrade edge-tts
	@echo "Setup complete. edge-tts installed at $(VENV_DIR)/bin/edge-tts"

install: build
	@mkdir -p $(BIN_DIR)
	cp $(BINARY) $(BIN_DIR)/$(BINARY)
	@echo "Installed to $(BIN_DIR)/$(BINARY)"

uninstall:
	rm -f $(BIN_DIR)/$(BINARY)
	rm -rf $(DATA_DIR)
	@echo "Uninstalled."

clean:
	rm -f $(BINARY)

run: build
	@./$(BINARY)

status:
	@$(BIN_DIR)/$(BINARY) status 2>/dev/null || ./$(BINARY) status 2>/dev/null || echo "Not running (binary not found)"

kill:
	@$(BIN_DIR)/$(BINARY) kill 2>/dev/null || ./$(BINARY) kill 2>/dev/null || echo "Not running (binary not found)"

play:
	@$(BIN_DIR)/$(BINARY) play 2>/dev/null || ./$(BINARY) play 2>/dev/null || echo "Binary not found. Run: make build"
