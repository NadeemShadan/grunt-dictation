# grunt-dictation

OS-level speech-to-text for Linux desktops. Records audio, transcribes with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and types or copies the result.

Runs as a per-user systemd service. No cloud, no background process eating resources — it only runs whisper when you tell it to.

---

## Requirements

- `ffmpeg`
- `systemd` (user services)
- `bash`

Text injection (install whichever matches your setup):

| Session | Package |
|---|---|
| X11 | `xdotool` |
| KDE Wayland | `wtype` |
| GNOME Wayland | `ydotool` + `ydotoold` (see [GNOME Wayland](#gnome-wayland)) |

Clipboard:

| Session | Package |
|---|---|
| Wayland | `wl-clipboard` |
| X11 | `xclip` |

---

## Install

### Ubuntu / Kubuntu (`.deb`)

```bash
sudo apt install ffmpeg xdotool wl-clipboard   # install dependencies first
sudo dpkg -i grunt-dictation_*.deb
```

### Manjaro / Arch

```bash
sudo pacman -S ffmpeg xdotool wl-clipboard
sudo pacman -U grunt-dictation-*.pkg.tar.zst
```

---

## First-time setup

Run this as your normal user (not root):

```bash
grunt-dictationctl setup
```

That's it. This enables the service and downloads the speech model (~142 MB) in one step.

---

## Keyboard shortcuts

Bind two global shortcuts — one to toggle recording, one to type the result:

| Action | Command | Suggested key |
|---|---|---|
| Start / stop recording | `grunt-dictationctl toggle` | `Super+D` |
| Type transcript | `grunt-dictationctl type-text` | `Super+T` |

Workflow: press `Super+D` to start speaking, press `Super+D` again to stop and transcribe, then press `Super+T` to type the result into whatever is focused.

### GNOME

Open **Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**, click **+** and add each command.

Or from the terminal:

```bash
# toggle
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
  "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/',
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/']"

gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ name 'Dictation toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ command 'grunt-dictationctl toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ binding '<Super>d'

# type-text
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ name 'Dictation type'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ command 'grunt-dictationctl type-text'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ binding '<Super>t'
```

### KDE Plasma

Open **System Settings → Shortcuts → Custom Shortcuts**, click **Edit → New → Global Shortcut → Command/URL**, and add each command with its key.

---

## Usage

```bash
grunt-dictationctl toggle         # start if idle, stop if recording
grunt-dictationctl record-start   # start recording
grunt-dictationctl record-stop    # stop and transcribe
grunt-dictationctl get-text       # print transcript
grunt-dictationctl type-text      # type transcript into focused window
grunt-dictationctl copy-text      # copy transcript to clipboard
grunt-dictationctl clear-text     # clear transcript
```

Service management:

```bash
grunt-dictationctl service-status
grunt-dictationctl service-start
grunt-dictationctl service-stop
grunt-dictationctl service-enable
grunt-dictationctl service-disable
```

Debug:

```bash
grunt-dictationctl show-runtime   # show paths and current state
```

---

## Tray indicator

A microphone icon sits in your system tray and changes colour with recording state:

| Icon colour | State |
|---|---|
| Grey | Idle |
| Orange | Recording |
| Amber | Transcribing |

The tray icon also has a right-click menu with toggle, type, and copy actions.

The indicator starts automatically with `grunt-dictationctl setup`. It requires an AppIndicator library:

```bash
# Ubuntu / Kubuntu
sudo apt install gir1.2-ayatanaappindicator3-0.1

# Arch / Manjaro
sudo pacman -S libayatana-appindicator
```

> **GNOME note:** GNOME does not show tray icons by default. Install the [AppIndicator and KStatusNotifierItem Support](https://extensions.gnome.org/extension/615/appindicator-support/) GNOME Shell extension to enable them. KDE shows the icon without any extension.

Transient notifications (recording started / transcribing / done) are shown via `notify-send` independently of the tray icon — these work on both GNOME and KDE without any extension.

---

## GNOME Wayland

`type-text` on GNOME Wayland requires `ydotool`, because GNOME does not implement the Wayland virtual keyboard protocol used by `wtype`.

One-time setup:

```bash
sudo apt install ydotool

# Grant your user access to /dev/uinput
sudo usermod -aG input $USER

# Log out and back in, then:
grunt-dictationctl setup   # enables ydotoold alongside the dictation service
```

After re-login, `type-text` will work. `copy-text` works on GNOME Wayland without any extra setup.

---

## Configuration

Edit `/etc/grunt-dictation/default.env`:

```bash
# Path to whisper-cli binary
WHISPER_CLI=/usr/lib/grunt-dictation/whisper-cli

# Path to ggml model file
MODEL_PATH=$HOME/.local/share/grunt-dictation/models/ggml-base.en.bin

# PulseAudio/PipeWire source (default works for most setups)
AUDIO_DEVICE=default

# Model download URL (used by grunt-dictationctl download-model)
WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

---

## Building packages

The build scripts embed a real `whisper-cli` binary into the package. You need to supply one — either by dropping it into the vendor path beforehand, or by pointing the script at a download URL.

**Option A — provide the binary directly:**

```bash
cp /path/to/whisper-cli packaging/common/vendor/whisper-cli/linux-x86_64/whisper-cli
cp /path/to/whisper-cli-arm packaging/common/vendor/whisper-cli/linux-arm64/whisper-cli
```

To build `whisper-cli` from source:
```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build && cmake --build build --target whisper-cli -j$(nproc)
# binary is at build/bin/whisper-cli
```

**Option B — download at build time:**

```bash
WHISPER_CLI_URL_AMD64=https://your-host/whisper-cli-amd64 ./build-deb.sh 0.1.0
WHISPER_CLI_URL_ARM64=https://your-host/whisper-cli-arm64 ./build-deb.sh 0.1.0
```

If the vendor binary is a placeholder and no URL is set, the build will fail with a clear error rather than silently producing a broken package.

### Debian / Ubuntu

```bash
cd packaging/deb
./build-deb.sh 0.1.0
# output: dist/deb/grunt-dictation_0.1.0_amd64.deb
```

### Arch / Manjaro

```bash
cd packaging/arch
./build-arch.sh
```
