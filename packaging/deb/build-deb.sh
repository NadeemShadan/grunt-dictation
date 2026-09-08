#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON_DIR="$ROOT_DIR/packaging/common"
WHISPER_VALIDATOR="$COMMON_DIR/validate-whisper-cli.sh"
DEB_DIR="$ROOT_DIR/packaging/deb"
OUT_DIR="$ROOT_DIR/dist/deb"

VERSION="${1:-0.1.1}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
PKG_ROOT="$OUT_DIR/grunt-dictation_${VERSION}_${ARCH}"
WHISPER_VENDOR_PATH=""
WHISPER_ARCH_KEY=""

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found. Install Debian packaging tools first." >&2
  echo "On Manjaro/Arch: sudo pacman -S dpkg" >&2
  exit 1
fi

case "$ARCH" in
  amd64)
    WHISPER_VENDOR_PATH="$COMMON_DIR/vendor/whisper-cli/linux-x86_64/whisper-cli"
    WHISPER_ARCH_KEY="amd64"
    ;;
  arm64)
    WHISPER_VENDOR_PATH="$COMMON_DIR/vendor/whisper-cli/linux-arm64/whisper-cli"
    WHISPER_ARCH_KEY="arm64"
    ;;
  *)
    echo "unsupported Debian architecture: $ARCH" >&2
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
    echo "    ${url_var}=https://... ./build-deb.sh" >&2
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
bash "$WHISPER_VALIDATOR" "$WHISPER_VENDOR_PATH"

rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/usr/lib/grunt-dictation"
mkdir -p "$PKG_ROOT/usr/lib/systemd/user"
mkdir -p "$PKG_ROOT/etc/grunt-dictation"
mkdir -p "$PKG_ROOT/usr/share/doc/grunt-dictation"

sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCH@/$ARCH/g" "$DEB_DIR/control.in" > "$PKG_ROOT/DEBIAN/control"
install -m755 "$DEB_DIR/postinst" "$PKG_ROOT/DEBIAN/postinst"
install -m755 "$DEB_DIR/prerm" "$PKG_ROOT/DEBIAN/prerm"

install -m755 "$COMMON_DIR/usr/bin/grunt-dictationctl" "$PKG_ROOT/usr/bin/grunt-dictationctl"
install -m755 "$COMMON_DIR/usr/lib/grunt-dictation/grunt-dictationd.sh" "$PKG_ROOT/usr/lib/grunt-dictation/grunt-dictationd.sh"
install -m755 "$COMMON_DIR/usr/lib/grunt-dictation/install-whisper-cli.sh" "$PKG_ROOT/usr/lib/grunt-dictation/install-whisper-cli.sh"
install -m755 "$WHISPER_VENDOR_PATH" "$PKG_ROOT/usr/lib/grunt-dictation/whisper-cli.$WHISPER_ARCH_KEY"
install -m755 "$WHISPER_VENDOR_PATH" "$PKG_ROOT/usr/lib/grunt-dictation/whisper-cli"
install -m755 "$COMMON_DIR/usr/lib/grunt-dictation/grunt-dictation-indicator" "$PKG_ROOT/usr/lib/grunt-dictation/grunt-dictation-indicator"
install -m644 "$COMMON_DIR/usr/lib/systemd/user/grunt-dictationd.service" "$PKG_ROOT/usr/lib/systemd/user/grunt-dictationd.service"
install -m644 "$COMMON_DIR/usr/lib/systemd/user/grunt-dictation-indicator.service" "$PKG_ROOT/usr/lib/systemd/user/grunt-dictation-indicator.service"
install -m644 "$COMMON_DIR/etc/grunt-dictation/default.env" "$PKG_ROOT/etc/grunt-dictation/default.env"
install -m644 "$ROOT_DIR/README.md" "$PKG_ROOT/usr/share/doc/grunt-dictation/README.md"
install -m644 "$ROOT_DIR/LICENSE" "$PKG_ROOT/usr/share/doc/grunt-dictation/LICENSE"

mkdir -p "$OUT_DIR"
dpkg-deb --build "$PKG_ROOT" "$OUT_DIR/"

echo "Built package: $OUT_DIR/grunt-dictation_${VERSION}_${ARCH}.deb"
