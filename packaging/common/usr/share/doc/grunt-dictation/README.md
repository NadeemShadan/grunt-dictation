# grunt-dictation

Standalone OS-level dictation helper using `ffmpeg` + `whisper.cpp`.

## Quick start

1. Provide whisper binaries:
   - `/usr/lib/grunt-dictation/whisper-cli.amd64`
   - `/usr/lib/grunt-dictation/whisper-cli.arm64`
2. Run bootstrap:
   - `/usr/lib/grunt-dictation/install-whisper-cli.sh --source auto`
3. Configure `MODEL_PATH` in `/etc/grunt-dictation/default.env`.
4. Enable service per user:
   - `systemctl --user daemon-reload`
   - `systemctl --user enable --now grunt-dictationd.service`

## Basic usage

- Start recording: `grunt-dictationctl record-start`
- Stop + transcribe: `grunt-dictationctl record-stop`
- Print transcript: `grunt-dictationctl get-text`
- Type transcript at cursor: `grunt-dictationctl type-text`

## Optional tools for text insertion

- Wayland: `wtype` or `ydotool`
- X11: `xdotool`
