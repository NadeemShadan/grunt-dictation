#!/usr/bin/env bash
set -euo pipefail

whisper_cli="${1:?usage: validate-whisper-cli.sh /path/to/whisper-cli}"

if [[ ! -x "$whisper_cli" ]]; then
  echo "error: whisper-cli is not executable: $whisper_cli" >&2
  exit 1
fi

whisper_size="$(wc -c < "$whisper_cli")"
if [[ "$whisper_size" -lt 102400 ]]; then
  echo "error: whisper-cli is only ${whisper_size} bytes and appears to be a placeholder: $whisper_cli" >&2
  exit 1
fi

if ! "$whisper_cli" --version >/dev/null 2>&1; then
  echo "error: whisper-cli could not run on this machine: $whisper_cli" >&2
  exit 1
fi

linkage="$(ldd "$whisper_cli" 2>&1 || true)"
if grep -Eq 'libwhisper|libggml' <<< "$linkage"; then
  echo "error: whisper-cli depends on unpackaged whisper.cpp shared libraries:" >&2
  grep -E 'libwhisper|libggml' <<< "$linkage" >&2
  echo "rebuild whisper.cpp with -DBUILD_SHARED_LIBS=OFF" >&2
  exit 1
fi

if grep -q 'not found' <<< "$linkage"; then
  echo "error: whisper-cli has missing shared-library dependencies:" >&2
  grep 'not found' <<< "$linkage" >&2
  exit 1
fi

echo "validated whisper-cli: $whisper_cli"
