# TTS Player

> [Russian version](README-ru.md)

A standalone macOS menu bar app for text-to-speech using Microsoft Neural voices (edge-tts).
Select text in any app, press the global hotkey, and hear it read aloud.

## The Problem It Solves

macOS lacks a convenient built-in way to quickly read selected text aloud with a high-quality voice.
The system TTS sounds robotic, and third-party solutions require complex setup or a subscription.

TTS Player solves this: one hotkey — and any text is read aloud by a neural voice, no matter which app you're working in.

## Features

- **Global hotkey** — works in any app (default: `Ctrl+Cmd+S`)
- **Microsoft Neural voices** — natural-sounding speech via edge-tts
- **Auto language detection** — Russian and English detected automatically by Cyrillic character ratio
- **Playback controls** — play/pause, stop, seek ±10 sec, speed (1x–2x)
- **Now Playing** — integration with the Now Playing widget and media keys
- **Menu bar icon** — full control without extra windows
- **Customizable hotkey** — reassign directly from the menu
- **CLI playback** — read clipboard aloud from terminal (`tts_player play`)
- **Unix socket** — IPC for external control

## How It Works

1. You press the hotkey
2. The app simulates `Cmd+C` and grabs the selected text from the clipboard
3. The language is detected (Russian or English)
4. edge-tts generates an audio file via Microsoft Azure Neural TTS
5. AVPlayer plays the audio with media key support

## Requirements

- macOS 13+
- Python 3.9+
- Accessibility permission

## Installation & Usage

```bash
make setup      # Create Python venv and install edge-tts
make build      # Compile the Swift binary
make run        # Build and run
make install    # Build and install to /usr/local/bin/
```

Other commands:

```bash
make play       # Read clipboard text aloud via TTS
make kill       # Stop the running player
make uninstall  # Remove binary and data directory
make clean      # Remove local binary
```

## Architecture

A single-file Swift application (`tts_player.swift`, ~1100 lines), compiled directly with `swiftc` — no Xcode project needed.

## Voices

| Language | Voice |
|----------|-------|
| Russian | `ru-RU-DmitryNeural` |
| English | `en-US-BrianMultilingualNeural` |

---

> This project was entirely developed using [Claude Code](https://claude.ai/code) — not a single line of code was written by hand.
