#!/usr/bin/env bash
set -u -o pipefail

CONFIG_FILE="${GRUNT_DICTATION_CONFIG:-/etc/grunt-dictation/default.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

WHISPER_CLI="${WHISPER_CLI:-/usr/lib/grunt-dictation/whisper-cli}"
MODEL_PATH="${MODEL_PATH:-$HOME/.local/share/grunt-dictation/models/ggml-base.en.bin}"
AUDIO_DEVICE="${AUDIO_DEVICE:-default}"
AUDIO_FORMAT="${AUDIO_FORMAT:-auto}"
MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-300}"
RUNTIME_ROOT="${XDG_RUNTIME_DIR:-/tmp}"
RUNTIME_DIR="${RUNTIME_DIR:-$RUNTIME_ROOT/grunt-dictation}"

CONTROL_FIFO="$RUNTIME_DIR/control.fifo"
STATE_FILE="$RUNTIME_DIR/state"
RAW_WAV="$RUNTIME_DIR/input.wav"
TRANSCRIPT_BASENAME="$RUNTIME_DIR/transcript"
TRANSCRIPT_FILE="$RUNTIME_DIR/transcript.latest.txt"
FFMPEG_PID_FILE="$RUNTIME_DIR/ffmpeg.pid"
TIMER_PID_FILE="$RUNTIME_DIR/timer.pid"
LOG_FILE="$RUNTIME_DIR/dictationd.log"

NOTIF_ID_FILE="$RUNTIME_DIR/notif.id"

mkdir -p "$RUNTIME_DIR"
: > "$LOG_FILE"

log() {
  local message="$1"
  printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$message" >> "$LOG_FILE"
}

set_state() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

notify_state() {
  command -v notify-send >/dev/null 2>&1 || return 0
  local summary="$1" body="${2:-}"
  local args=(-u normal -i audio-input-microphone -t 4000)
  if [[ -f "$NOTIF_ID_FILE" ]]; then
    local prev
    prev="$(cat "$NOTIF_ID_FILE" 2>/dev/null || true)"
    [[ -n "$prev" ]] && args+=(-r "$prev")
  fi
  local id
  id="$(notify-send -p "${args[@]}" "$summary" "$body" 2>/dev/null || true)"
  [[ -n "$id" ]] && printf '%s\n' "$id" > "$NOTIF_ID_FILE"
}

resolve_audio_format() {
  if [[ "$AUDIO_FORMAT" != "auto" ]]; then
    echo "$AUDIO_FORMAT"
    return
  fi
  local pulse_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
  if [[ -S "$pulse_sock" ]]; then
    echo "pulse"
  elif command -v pw-cli >/dev/null 2>&1 && pw-cli info 0 >/dev/null 2>&1; then
    echo "pipewire"
  else
    echo "alsa"
  fi
}

cancel_timer() {
  if [[ -f "$TIMER_PID_FILE" ]]; then
    local timer_pid
    timer_pid="$(cat "$TIMER_PID_FILE" 2>/dev/null || true)"
    [[ -n "$timer_pid" ]] && kill "$timer_pid" 2>/dev/null || true
    rm -f "$TIMER_PID_FILE"
  fi
}

is_recording() {
  [[ -f "$FFMPEG_PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$FFMPEG_PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_recording() {
  if is_recording; then
    log "record-start ignored; already recording"
    return 0
  fi

  local fmt
  fmt="$(resolve_audio_format)"

  rm -f "$RAW_WAV"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f "$fmt" -i "$AUDIO_DEVICE" -ac 1 -ar 16000 -c:a pcm_s16le "$RAW_WAV" >>"$LOG_FILE" 2>&1 &

  printf '%s\n' "$!" > "$FFMPEG_PID_FILE"
  set_state "recording"
  log "recording started (pid=$!, format=$fmt)"
  notify_state "Recording" "Microphone is active"

  # Auto-stop after MAX_RECORD_SECONDS
  ( sleep "$MAX_RECORD_SECONDS" \
      && touch "$RUNTIME_DIR/timed_out" \
      && printf 'record-stop\n' > "$CONTROL_FIFO" 2>/dev/null ) &
  printf '%s\n' "$!" > "$TIMER_PID_FILE"
  log "auto-stop timer set for ${MAX_RECORD_SECONDS}s"
}

stop_recording() {
  if ! is_recording; then
    log "record-stop ignored; no active recording"
    set_state "idle"
    return 0
  fi

  local timed_out=false
  if [[ -f "$RUNTIME_DIR/timed_out" ]]; then
    timed_out=true
    rm -f "$RUNTIME_DIR/timed_out"
    log "recording stopped by auto-stop timer (${MAX_RECORD_SECONDS}s)"
  fi

  cancel_timer

  local pid
  pid="$(cat "$FFMPEG_PID_FILE")"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$FFMPEG_PID_FILE"
  set_state "transcribing"
  if [[ "$timed_out" == true ]]; then
    notify_state "Recording timed out" "Stopped after ${MAX_RECORD_SECONDS}s — transcribing..."
  else
    notify_state "Transcribing" "Processing audio..."
  fi

  if [[ ! -s "$RAW_WAV" ]]; then
    log "no audio captured"
    : > "$TRANSCRIPT_FILE"
    set_state "idle"
    return 0
  fi

  if [[ ! -x "$WHISPER_CLI" ]]; then
    log "whisper-cli not executable at $WHISPER_CLI"
    : > "$TRANSCRIPT_FILE"
    set_state "idle"
    return 1
  fi

  if [[ ! -f "$MODEL_PATH" ]]; then
    log "model missing at $MODEL_PATH"
    : > "$TRANSCRIPT_FILE"
    set_state "idle"
    return 1
  fi

  rm -f "${TRANSCRIPT_BASENAME}.txt"
  "$WHISPER_CLI" -m "$MODEL_PATH" -f "$RAW_WAV" --output-txt --output-file "$TRANSCRIPT_BASENAME" >>"$LOG_FILE" 2>&1

  if [[ -s "${TRANSCRIPT_BASENAME}.txt" ]]; then
    tr -d '\r' < "${TRANSCRIPT_BASENAME}.txt" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' > "$TRANSCRIPT_FILE"
    log "transcription completed"
    local preview
    preview="$(head -c 120 "$TRANSCRIPT_FILE")"
    [[ "${#preview}" -ge 120 ]] && preview="${preview}…"
    notify_state "Transcript ready" "$preview"
  else
    : > "$TRANSCRIPT_FILE"
    log "transcription produced no output"
    notify_state "Transcript empty" "No speech detected"
  fi

  set_state "idle"
}

clear_transcript() {
  : > "$TRANSCRIPT_FILE"
  log "transcript cleared"
}

cleanup() {
  cancel_timer
  if is_recording; then
    local pid
    pid="$(cat "$FFMPEG_PID_FILE")"
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$FFMPEG_PID_FILE" "$CONTROL_FIFO"
}

on_exit() {
  cleanup
  set_state "stopped"
  log "daemon stopped"
}

trap on_exit EXIT INT TERM

rm -f "$CONTROL_FIFO"
mkfifo "$CONTROL_FIFO"
: > "$TRANSCRIPT_FILE"
set_state "idle"
log "daemon started"

while true; do
  if ! IFS= read -r command < "$CONTROL_FIFO"; then
    sleep 0.1
    continue
  fi

  case "$command" in
    record-start)
      start_recording
      ;;
    record-stop)
      stop_recording
      ;;
    clear-text)
      clear_transcript
      ;;
    quit)
      log "quit requested"
      break
      ;;
    status)
      # state is always written to STATE_FILE; command kept for compatibility
      ;;
    *)
      log "unknown command: $command"
      ;;
  esac
done
