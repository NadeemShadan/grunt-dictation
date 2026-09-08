#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
BACKGROUND_PIDS=()

cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_file_content() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(cat "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected '$expected' in $file, got '$actual'"
}

start_fake_recording() {
  printf 'audio' > "$RAW_WAV"
  sleep 60 &
  local recording_pid="$!"
  BACKGROUND_PIDS+=("$recording_pid")
  printf '%s\n' "$recording_pid" > "$FFMPEG_PID_FILE"
}

export GRUNT_DICTATION_CONFIG=/dev/null
export RUNTIME_DIR="$TEST_ROOT/runtime"
export WHISPER_CLI="$TEST_ROOT/fake-whisper-cli"
export MODEL_PATH="$TEST_ROOT/model.bin"
export AUTO_PASTE=false
mkdir -p "$RUNTIME_DIR"

source "$ROOT_DIR/packaging/common/usr/lib/grunt-dictation/grunt-dictationd.sh"

touch "$MODEL_PATH" "$LOG_FILE"

notify_state() {
  :
}

cat > "$WHISPER_CLI" <<'FAKE_WHISPER'
#!/usr/bin/env bash
set -euo pipefail

output_basename=""
printf '%s\n' "$*" > "${FAKE_WHISPER_ARGS_CAPTURE:-/dev/null}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output-file" ]]; then
    output_basename="$2"
    shift 2
  else
    shift
  fi
done

printf '%s' "${FAKE_WHISPER_STDOUT:-}"
printf '%s' "${FAKE_WHISPER_STDERR:-}" >&2
printf '%s' "${FAKE_WHISPER_TEXT:-}" > "${output_basename}.txt"
exit "${FAKE_WHISPER_EXIT_CODE:-0}"
FAKE_WHISPER
chmod +x "$WHISPER_CLI"

printf '  What about this whole project?  \n\n Is it really useful?\r\nShould I try something else?\n' > "$TEST_ROOT/segments.txt"
normalize_transcript_file "$TEST_ROOT/segments.txt" "$TEST_ROOT/normalized.txt"
assert_file_content \
  'What about this whole project? Is it really useful? Should I try something else?' \
  "$TEST_ROOT/normalized.txt"

printf 'Keep the previous transcript.\n' > "$TRANSCRIPT_FILE"
export FAKE_WHISPER_TEXT=''
start_fake_recording
stop_recording
assert_file_content 'Keep the previous transcript.' "$TRANSCRIPT_FILE"
[[ ! -e "$RAW_WAV" ]] || fail "raw audio was not removed after an empty transcription"

export FAKE_WHISPER_TEXT=$'What about this whole project?\nIs it really useful?\n'
export FAKE_WHISPER_STDOUT='PRIVATE SPOKEN TEXT'
export FAKE_WHISPER_ARGS_CAPTURE="$TEST_ROOT/whisper-args.txt"
start_fake_recording
stop_recording
assert_file_content 'What about this whole project? Is it really useful?' "$TRANSCRIPT_FILE"
grep -q -- '-t 2' "$FAKE_WHISPER_ARGS_CAPTURE" || fail "whisper thread limit was not applied"
grep -q -- '-l en' "$FAKE_WHISPER_ARGS_CAPTURE" || fail "whisper language was not applied"
grep -q -- '--no-prints' "$FAKE_WHISPER_ARGS_CAPTURE" || fail "whisper output suppression was not applied"
[[ ! -e "$RAW_WAV" ]] || fail "raw audio was not removed after a successful transcription"
[[ ! -e "${TRANSCRIPT_BASENAME}.txt" ]] || fail "raw transcript segments were not removed"
if grep -q 'PRIVATE SPOKEN TEXT' "$LOG_FILE"; then
  fail "whisper stdout containing spoken text was written to the diagnostic log"
fi

export FAKE_WHISPER_EXIT_CODE=7
export FAKE_WHISPER_TEXT='Failed replacement.'
start_fake_recording
stop_recording
assert_file_content 'What about this whole project? Is it really useful?' "$TRANSCRIPT_FILE"
unset FAKE_WHISPER_EXIT_CODE

export AUTO_PASTE=true
export DICTATION_CONTROL="$TEST_ROOT/fake-dictation-control"
export CONTROL_CAPTURE="$TEST_ROOT/control-capture.txt"
cat > "$DICTATION_CONTROL" <<'FAKE_CONTROL'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CONTROL_CAPTURE"
FAKE_CONTROL
chmod +x "$DICTATION_CONTROL"
export FAKE_WHISPER_TEXT='Automatic paste works.'
start_fake_recording
stop_recording
assert_file_content 'type-text' "$CONTROL_CAPTURE"

export MAX_RECORD_SECONDS=30
mkfifo "$CONTROL_FIFO"
start_recording_timer
timer_pid="$(cat "$TIMER_PID_FILE")"
sleep 0.1
timer_sleep_pid="$(pgrep -P "$timer_pid" sleep || true)"
[[ -n "$timer_sleep_pid" ]] || fail "recording timer did not start its sleep process"
cancel_timer
if kill -0 "$timer_pid" 2>/dev/null || kill -0 "$timer_sleep_pid" 2>/dev/null; then
  fail "recording timer left a process behind"
fi
rm -f "$CONTROL_FIFO"

CONTROL_TEST_ROOT="$TEST_ROOT/control-runtime"
CONTROL_RUNTIME_DIR="$CONTROL_TEST_ROOT/grunt-dictation"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$CONTROL_RUNTIME_DIR" "$FAKE_BIN"
printf 'Clipboard paste preserves every character.\n' > "$CONTROL_RUNTIME_DIR/transcript.latest.txt"

export TEST_CLIPBOARD_CAPTURE="$TEST_ROOT/clipboard-capture.txt"
export TEST_KEY_CAPTURE="$TEST_ROOT/key-capture.txt"
cat > "$FAKE_BIN/xclip" <<'FAKE_XCLIP'
#!/usr/bin/env bash
cat > "$TEST_CLIPBOARD_CAPTURE"
FAKE_XCLIP
cat > "$FAKE_BIN/xdotool" <<'FAKE_XDOTOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_KEY_CAPTURE"
FAKE_XDOTOOL
chmod +x "$FAKE_BIN/xclip" "$FAKE_BIN/xdotool"

env -u RUNTIME_DIR \
  PATH="$FAKE_BIN:/usr/bin" \
  GRUNT_DICTATION_CONFIG=/dev/null \
  XDG_RUNTIME_DIR="$CONTROL_TEST_ROOT" \
  DISPLAY=:99 \
  PASTE_DELAY_SECONDS=0 \
  "$ROOT_DIR/packaging/common/usr/bin/grunt-dictationctl" type-text

assert_file_content 'Clipboard paste preserves every character.' "$TEST_CLIPBOARD_CAPTURE"
assert_file_content 'key --clearmodifiers ctrl+v' "$TEST_KEY_CAPTURE"

MODEL_TEST_HOME="$TEST_ROOT/model-home"
MODEL_TEST_CONFIG="$MODEL_TEST_HOME/config/grunt-dictation/config.env"
MODEL_TEST_DATA="$MODEL_TEST_HOME/data"
mkdir -p "$(dirname "$MODEL_TEST_CONFIG")" "$MODEL_TEST_DATA/grunt-dictation/models"
printf 'AUTO_PASTE=false\n' > "$MODEL_TEST_CONFIG"
touch "$MODEL_TEST_DATA/grunt-dictation/models/ggml-small.en.bin"

env -u GRUNT_DICTATION_CONFIG -u MODEL_PATH -u WHISPER_MODEL_URL -u WHISPER_LANGUAGE \
  HOME="$MODEL_TEST_HOME" \
  XDG_CONFIG_HOME="$MODEL_TEST_HOME/config" \
  XDG_DATA_HOME="$MODEL_TEST_DATA" \
  GRUNT_DICTATION_SYSTEM_CONFIG=/dev/null \
  PATH="$FAKE_BIN:/usr/bin" \
  "$ROOT_DIR/packaging/common/usr/bin/grunt-dictationctl" model use small.en \
  > "$TEST_ROOT/model-use-output.txt"

grep -q '^AUTO_PASTE=false$' "$MODEL_TEST_CONFIG" || \
  fail "model selection discarded an unrelated per-user setting"
grep -q "^MODEL_PATH=$MODEL_TEST_DATA/grunt-dictation/models/ggml-small.en.bin$" "$MODEL_TEST_CONFIG" || \
  fail "model selection did not save the selected model path"
grep -q '^WHISPER_LANGUAGE=en$' "$MODEL_TEST_CONFIG" || \
  fail "English model did not select English transcription"

MODEL_STATUS="$(
  env -u GRUNT_DICTATION_CONFIG -u MODEL_PATH -u WHISPER_MODEL_URL -u WHISPER_LANGUAGE \
    HOME="$MODEL_TEST_HOME" \
    XDG_CONFIG_HOME="$MODEL_TEST_HOME/config" \
    XDG_DATA_HOME="$MODEL_TEST_DATA" \
    GRUNT_DICTATION_SYSTEM_CONFIG=/dev/null \
    "$ROOT_DIR/packaging/common/usr/bin/grunt-dictationctl" model status
)"
grep -q '^active_model=small.en$' <<< "$MODEL_STATUS" || \
  fail "per-user model configuration was not loaded"

if env -u GRUNT_DICTATION_CONFIG -u MODEL_PATH -u WHISPER_MODEL_URL -u WHISPER_LANGUAGE \
    HOME="$MODEL_TEST_HOME" \
    XDG_CONFIG_HOME="$MODEL_TEST_HOME/config" \
    XDG_DATA_HOME="$MODEL_TEST_DATA" \
    GRUNT_DICTATION_SYSTEM_CONFIG=/dev/null \
    "$ROOT_DIR/packaging/common/usr/bin/grunt-dictationctl" model remove small.en \
    >/dev/null 2>&1; then
  fail "active model was allowed to be removed"
fi
[[ -f "$MODEL_TEST_DATA/grunt-dictation/models/ggml-small.en.bin" ]] || \
  fail "active model file was removed"

DAEMON_TEST_RUNTIME="$TEST_ROOT/daemon-runtime"
env \
  GRUNT_DICTATION_CONFIG=/dev/null \
  RUNTIME_DIR="$DAEMON_TEST_RUNTIME" \
  AUTO_PASTE=false \
  "$ROOT_DIR/packaging/common/usr/lib/grunt-dictation/grunt-dictationd.sh" &
daemon_pid="$!"
BACKGROUND_PIDS+=("$daemon_pid")

for _ in {1..20}; do
  [[ -p "$DAEMON_TEST_RUNTIME/control.fifo" ]] && break
  sleep 0.05
done
[[ -p "$DAEMON_TEST_RUNTIME/control.fifo" ]] || fail "daemon did not create its control FIFO"

kill -TERM "$daemon_pid"
for _ in {1..20}; do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$daemon_pid" 2>/dev/null; then
  fail "daemon did not stop promptly after SIGTERM"
fi
wait "$daemon_pid"
assert_file_content 'stopped' "$DAEMON_TEST_RUNTIME/state"
[[ ! -e "$DAEMON_TEST_RUNTIME/control.fifo" ]] || fail "daemon left its control FIFO after shutdown"

echo "All grunt-dictation tests passed."
