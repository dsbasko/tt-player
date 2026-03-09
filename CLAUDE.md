# CLAUDE.md

## Overview

TTS Player — standalone macOS menu bar app for text-to-speech using Microsoft Neural voices (edge-tts).
Select text in any app, press the global hotkey, and hear it read aloud.

## Architecture

Single-file Swift app (`tts_player.swift`) compiled with `swiftc`. No Xcode project needed.

**Key components:**
- CGEvent tap — global keyboard hotkey (default: Ctrl+Cmd+S)
- edge-tts (Python) — generates speech via Microsoft Azure Neural TTS
- AVPlayer — audio playback
- MPNowPlayingInfoCenter — Now Playing widget + media keys
- NSStatusItem — menu bar UI (play/pause, stop, seek, speed, hotkey config)
- Unix domain socket — IPC for external commands

**Data directory:** `~/.local/share/tts-player/` (Python venv with edge-tts)

## Commands

```bash
make setup      # Create venv and install edge-tts
make build      # Compile Swift binary
make run        # Build and run
make install    # Build and copy to /usr/local/bin/
make uninstall  # Remove binary and data directory
make kill       # Stop running player
make clean      # Remove local binary
```

## Voices

- Russian: `ru-RU-DmitryNeural`
- English: `en-US-BrianMultilingualNeural`
- Language auto-detected by Cyrillic character ratio (>30% = Russian)

## Settings (UserDefaults)

- `tts_speed` — playback speed (Float, default 1.0)
- `hotkey_keyCode` / `hotkey_cmd` / `hotkey_ctrl` / `hotkey_shift` / `hotkey_alt` — global hotkey config

## Requirements

- macOS 13+
- Python 3.9+ (for edge-tts venv)
- Accessibility permission (for global hotkey and Cmd+C simulation)
