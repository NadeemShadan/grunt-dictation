# grunt-dictation

OS-level speech-to-text for Linux desktops. Records audio, transcribes with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and types or copies the result.

Runs as a per-user systemd service. Transcription stays on the machine, and the CPU-intensive `whisper-cli` process runs only when a recording is submitted.

---

## For end users

If you have downloaded a package from a published release, start here. The small `whisper-cli` files in the source tree are placeholders, not usable binaries. Do not install a package produced from them; follow the [developer instructions](#for-developers) to build from source.

### Install

**Ubuntu / Kubuntu:**

```bash
sudo apt install ffmpeg xdotool xclip wl-clipboard
sudo dpkg -i grunt-dictation_*.deb
```

**Manjaro / Arch:**

```bash
sudo pacman -S ffmpeg xdotool xclip wl-clipboard
sudo pacman -U grunt-dictation-*.pkg.tar.zst
```

### First-time setup

Run this once as your normal user (not root):

```bash
grunt-dictationctl setup
```

This enables the background service and downloads the speech model (~142 MB) in one step.

### Keyboard shortcuts

Bind the recording shortcut so you never need to open a terminal. The copy shortcut is optional and lets you recover the latest transcript if automatic paste fails.

| Action | Command | Suggested key |
|---|---|---|
| Start / stop recording | `grunt-dictationctl toggle` | `Super+D` |
| Copy latest transcript (optional) | `grunt-dictationctl copy-text` | `Super+T` |

Workflow: focus a text field → press `Super+D` → speak → press `Super+D` again → keep the destination focused while transcription runs. The completed transcript is copied and pasted automatically.

`type-text` remains available for manual retries. It copies the complete transcript and pastes it after a short delay; it no longer types individual characters or restores held modifier keys.

**GNOME:** Open **Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**, click **+** and add each command. Or paste this into a terminal:

```bash
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings \
  "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/',
    '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/']"

gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ name 'Dictation toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ command 'grunt-dictationctl toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt0/ binding '<Super>d'

gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ name 'Dictation copy'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ command 'grunt-dictationctl copy-text'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/grunt1/ binding '<Super>t'
```

**KDE Plasma:** Open **System Settings → Shortcuts → Custom Shortcuts**, click **Edit → New → Global Shortcut → Command/URL**, and add each command with its key.

**XFCE:** Open **Settings → Keyboard → Application Shortcuts** and add both commands, or run:

```bash
xfconf-query -c xfce4-keyboard-shortcuts \
  -p '/commands/custom/<Super>d' -n -t string \
  -s 'grunt-dictationctl toggle'

xfconf-query -c xfce4-keyboard-shortcuts \
  -p '/commands/custom/<Super>t' -n -t string \
  -s 'grunt-dictationctl copy-text'
```

### Tray indicator

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

### GNOME Wayland

`type-text` on GNOME Wayland requires `ydotool` because GNOME does not implement the Wayland virtual keyboard protocol used by `wtype`. `copy-text` works without any extra setup.

One-time setup:

```bash
sudo apt install ydotool
sudo usermod -aG input $USER
# log out and back in, then:
grunt-dictationctl setup
```

### Command reference

```bash
grunt-dictationctl toggle         # start if idle, stop if recording
grunt-dictationctl type-text      # paste transcript into focused window
grunt-dictationctl copy-text      # copy transcript to clipboard
grunt-dictationctl get-text       # print transcript
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
grunt-dictationctl show-runtime
```

### Configuration

Edit `/etc/grunt-dictation/default.env` to override any setting:

```bash
# Audio input device — run `grunt-dictationctl list-devices` to see options
AUDIO_DEVICE=default

# Audio backend: auto | pulse | pipewire | alsa
AUDIO_FORMAT=auto

# Maximum recording duration in seconds (default: 5 minutes)
MAX_RECORD_SECONDS=300

# Keep transcription responsive on smaller machines
WHISPER_THREADS=2
WHISPER_NICE_LEVEL=10

# Paste the completed transcript into the focused application
AUTO_PASTE=true
PASTE_DELAY_SECONDS=0.35

# Path to ggml model file
MODEL_PATH=$HOME/.local/share/grunt-dictation/models/ggml-base.en.bin
```

The default `base.en` model favors speed and may occasionally misrecognize a word, particularly a short word at the beginning of speech. `small.en` is usually more accurate, but it requires substantially more memory and CPU time. Pasting cannot correct recognition errors; `grunt-dictationctl get-text` shows exactly what Whisper produced.

---

## For developers

If you have cloned the repo and want to build and install from source, start here.

### Prerequisites

**Arch / Manjaro:**

```bash
sudo pacman -S base-devel cmake git ffmpeg
```

**Ubuntu / Kubuntu:**

```bash
sudo apt install build-essential cmake git ffmpeg dpkg-dev
```

### Step 1 — build whisper-cli

The package requires a real `whisper-cli` binary from [whisper.cpp](https://github.com/ggerganov/whisper.cpp). The package currently includes only the executable, not the `libwhisper` or `libggml` shared libraries, so build it with `BUILD_SHARED_LIBS=OFF`.

```bash
git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git
cmake -S whisper.cpp -B whisper.cpp/build \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=OFF
cmake --build whisper.cpp/build --target whisper-cli -j"$(nproc)"
```

### Step 2 — place the binary

```bash
# x86_64
cp whisper.cpp/build/bin/whisper-cli \
   packaging/common/vendor/whisper-cli/linux-x86_64/whisper-cli

# ARM64 (if cross-compiling)
cp whisper.cpp/build/bin/whisper-cli \
   packaging/common/vendor/whisper-cli/linux-arm64/whisper-cli
```

Verify the binary before packaging it:

```bash
packaging/common/vendor/whisper-cli/linux-x86_64/whisper-cli --version
ldd packaging/common/vendor/whisper-cli/linux-x86_64/whisper-cli
```

`ldd` must not report `libwhisper.so` or `libggml*.so`. If it does, rebuild with `BUILD_SHARED_LIBS=OFF`; those libraries will not be present after package installation.

Run the regression tests:

```bash
./tests/run-tests.sh
```

The package builders repeat the binary validation and stop before producing a package if the executable is still a placeholder, cannot run, or depends on unpackaged `whisper.cpp` libraries.

### Step 3 — build the package

**Arch / Manjaro:**

```bash
cd packaging/arch
./build-arch.sh
# output: grunt-dictation-*.pkg.tar.zst in the current directory
```

**Ubuntu / Kubuntu:**

```bash
cd packaging/deb
./build-deb.sh 0.1.1
# output: dist/deb/grunt-dictation_0.1.1_amd64.deb
```

### Step 4 — install

**Arch / Manjaro:**

```bash
sudo pacman -U grunt-dictation-*.pkg.tar.zst
```

**Ubuntu / Kubuntu:**

```bash
sudo dpkg -i ../../dist/deb/grunt-dictation_*.deb
```

### Step 5 — first-time setup

```bash
grunt-dictationctl setup
```

Verify the installation before adding keyboard shortcuts:

```bash
systemctl --user status grunt-dictationd.service
systemctl --user status grunt-dictation-indicator.service
grunt-dictationctl list-devices
```

Then follow the [keyboard shortcuts](#keyboard-shortcuts) and [tray indicator](#tray-indicator) sections above.
