#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON_DIR="$ROOT_DIR/packaging/common"

case "$(uname -m)" in
  x86_64)
    WHISPER_VENDOR_PATH="$COMMON_DIR/vendor/whisper-cli/linux-x86_64/whisper-cli"
    WHISPER_ARCH_KEY="amd64"
    ;;
  aarch64)
    WHISPER_VENDOR_PATH="$COMMON_DIR/vendor/whisper-cli/linux-arm64/whisper-cli"
    WHISPER_ARCH_KEY="arm64"
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

# If the vendor binary is a placeholder, try to download a real one.
# Set WHISPER_CLI_URL_AMD64 or WHISPER_CLI_URL_ARM64 before running this script.
ensure_real_whisper_cli() {
  local path="$1"
  local arch_key="$2"
  local url_var="WHISPER_CLI_URL_${arch_key^^}"
  local url="${!url_var:-}"

  local size
  size="$(wc -c < "$path" 2>/dev/null || echo 0)"
  if [[ "$size" -ge 102400 ]]; then
    return 0
  fi

  if [[ -z "$url" ]]; then
    echo "error: vendor whisper-cli at $path is a placeholder (${size} bytes)." >&2
    echo "  Provide a real build or set ${url_var} to a download URL:" >&2
    echo "    ${url_var}=https://... ./build-arch.sh" >&2
    exit 1
  fi

  echo "vendor whisper-cli is a placeholder; downloading from $url ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$path"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$path" "$url"
  else
    echo "error: neither curl nor wget found." >&2
    exit 1
  fi
  chmod +x "$path"
  echo "downloaded whisper-cli to $path"
}

ensure_real_whisper_cli "$WHISPER_VENDOR_PATH" "$WHISPER_ARCH_KEY"

cd "$(dirname "$0")"
makepkg -f
