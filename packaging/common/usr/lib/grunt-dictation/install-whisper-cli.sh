#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${GRUNT_DICTATION_CONFIG:-/etc/grunt-dictation/default.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

TARGET_BIN="${WHISPER_CLI:-/usr/lib/grunt-dictation/whisper-cli}"
SOURCE_MODE="${WHISPER_CLI_SOURCE:-auto}"
URL_TEMPLATE="${WHISPER_CLI_URL_TEMPLATE:-}"
WHISPER_VERSION="${WHISPER_CLI_VERSION:-v1.0.0}"

print_usage() {
  cat <<'USAGE'
Usage:
  install-whisper-cli.sh [--source auto|bundled|download]

Behavior:
- Detects CPU architecture (amd64/arm64)
- Prefers bundled /usr/lib/grunt-dictation/whisper-cli.<arch>
- Optionally downloads from WHISPER_CLI_URL_TEMPLATE when configured
USAGE
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      echo "unsupported architecture: $machine" >&2
      return 1
      ;;
  esac
}

download_with_curl_or_wget() {
  local url="$1"
  local target="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$target"
    chmod +x "$target"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$target" "$url"
    chmod +x "$target"
    return 0
  fi

  echo "neither curl nor wget is installed; cannot download whisper-cli" >&2
  return 1
}

warn_if_placeholder() {
  local bin="$1"
  # A real whisper-cli ELF binary is several megabytes.
  # Placeholder scripts are tiny (< 1 KB).
  local size
  size="$(wc -c < "$bin" 2>/dev/null || echo 0)"
  if [[ "$size" -lt 102400 ]]; then
    echo "warning: $bin is only ${size} bytes — looks like a placeholder." >&2
    echo "  Replace it with a real whisper.cpp whisper-cli build." >&2
    echo "  Or set WHISPER_CLI_URL_TEMPLATE in /etc/grunt-dictation/default.env to enable download." >&2
    return 1
  fi

  if ! "$bin" --version >/dev/null 2>&1; then
    echo "warning: $bin could not run on this machine." >&2
    return 1
  fi

  local linkage
  linkage="$(ldd "$bin" 2>&1 || true)"
  if grep -Eq 'libwhisper|libggml|not found' <<< "$linkage"; then
    echo "warning: $bin depends on shared libraries that are not installed:" >&2
    grep -E 'libwhisper|libggml|not found' <<< "$linkage" >&2
    return 1
  fi
  return 0
}

install_bundled() {
  local arch="$1"
  local bundled="${TARGET_BIN}.${arch}"

  if [[ ! -x "$bundled" ]]; then
    return 1
  fi

  if [[ ! -x "$TARGET_BIN" ]] || ! cmp -s "$bundled" "$TARGET_BIN"; then
    install -m755 "$bundled" "$TARGET_BIN"
    echo "installed bundled whisper-cli for $arch at $TARGET_BIN"
  else
    echo "bundled whisper-cli for $arch is already installed at $TARGET_BIN"
  fi
  warn_if_placeholder "$TARGET_BIN"
}

install_downloaded() {
  local arch="$1"

  if [[ -z "$URL_TEMPLATE" ]]; then
    echo "WHISPER_CLI_URL_TEMPLATE is empty; cannot download whisper-cli" >&2
    return 1
  fi

  local url="$URL_TEMPLATE"
  url="${url//\{version\}/$WHISPER_VERSION}"
  url="${url//\{arch\}/$arch}"

  download_with_curl_or_wget "$url" "$TARGET_BIN"
  echo "downloaded whisper-cli for $arch from $url"
  warn_if_placeholder "$TARGET_BIN"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_MODE="${2:-}"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

ARCH="$(detect_arch)"

case "$SOURCE_MODE" in
  auto)
    install_bundled "$ARCH" || install_downloaded "$ARCH"
    ;;
  bundled)
    install_bundled "$ARCH"
    ;;
  download)
    install_downloaded "$ARCH"
    ;;
  *)
    echo "invalid WHISPER_CLI_SOURCE: $SOURCE_MODE" >&2
    exit 1
    ;;
esac
