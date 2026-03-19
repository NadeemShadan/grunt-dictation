# grunt-dictation

OS-level speech-to-text for Linux desktops. Records audio, transcribes with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and types or copies the result.

Runs as a per-user systemd service. No cloud, no background process eating resources — it only runs whisper when you tell it to.

---

## Install

### Ubuntu / Kubuntu

```bash
sudo apt install ffmpeg xdotool wl-clipboard
sudo dpkg -i grunt-dictation_*.deb
```

### Manjaro / Arch

```bash
sudo pacman -S ffmpeg xdotool wl-clipboard
sudo pacman -U grunt-dictation-*.pkg.tar.zst
```

---

## First-time setup

Run this once as your normal user (not root):

```bash
grunt-dictationctl setup
```

This enables the background service and downloads the speech model (~142 MB) in one step.

---

## Keyboard shortcuts

Bind two global shortcuts so you never need to open a terminal:

| Action | Command | Suggested key |
|---|---|---|
| Start / stop recording | `grunt-dictationctl toggle` | `Super+D` |
| Type transcript | `grunt-dictationctl type-text` | `Super+T` |

Workflow: press `Super+D` → speak → press `Super+D` again → wait a moment → press `Super+T` to type the result into whatever is focused.

### GNOME

Open **Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**, click **+** and add each command.

Or from the terminal:

```bash
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
  "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/',
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/']"

gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ name 'Dictation toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ command 'grunt-dictationctl toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ binding '<Super>d'

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
grunt-dictationctl list-devices   # list available microphones
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

| Colour | State |
|---|---|
| Grey | Idle |
| Orange | Recording |
| Amber | Transcribing |

Right-clicking the icon gives quick access to toggle, type, and copy.

The indicator starts automatically with `grunt-dictationctl setup`. It requires an AppIndicator library:

```bash
# Ubuntu / Kubuntu
sudo apt install gir1.2-ayatanaappindicator3-0.1

# Arch / Manjaro
sudo pacman -S libayatana-appindicator
```

> **GNOME note:** GNOME does not show tray icons by default. Install the [AppIndicator and KStatusNotifierItem Support](https://extensions.gnome.org/extension/615/appindicator-support/) GNOME Shell extension to enable them. KDE shows the icon without any extension.

---

## GNOME Wayland

`type-text` on GNOME Wayland requires `ydotool` because GNOME does not implement the Wayland virtual keyboard protocol used by `wtype`. `copy-text` works without any extra setup.

One-time setup:

```bash
sudo apt install ydotool
sudo usermod -aG input $USER
# log out and back in, then:
grunt-dictationctl setup
```

---

## Configuration

Edit `/etc/grunt-dictation/default.env` to override any setting:

```bash
# Audio input device — run `grunt-dictationctl list-devices` to see options
AUDIO_DEVICE=default

# Audio backend: auto | pulse | pipewire | alsa
AUDIO_FORMAT=auto

# Maximum recording duration in seconds (default: 5 minutes)
MAX_RECORD_SECONDS=300

# Path to ggml model file
MODEL_PATH=$HOME/.local/share/grunt-dictation/models/ggml-base.en.bin
```

---

## Building packages

The build scripts embed a real `whisper-cli` binary into the package. You need to supply one.

**Option A — build whisper-cli from source:**

```bash
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp
cmake -B build && cmake --build build --target whisper-cli -j$(nproc)
cp build/bin/whisper-cli /path/to/grunt-dictation-os/packaging/common/vendor/whisper-cli/linux-x86_64/whisper-cli
```

**Option B — download at build time:**

```bash
WHISPER_CLI_URL_AMD64=https://your-host/whisper-cli-amd64 ./build-deb.sh 0.1.0
```

If the vendor binary is still a placeholder and no URL is set, the build exits with an error rather than producing a broken package.

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
