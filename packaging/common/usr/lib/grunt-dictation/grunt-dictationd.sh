#!/usr/bin/env bash
set -u -o pipefail

SYSTEM_CONFIG_FILE="${GRUNT_DICTATION_SYSTEM_CONFIG:-/etc/grunt-dictation/default.env}"
USER_CONFIG_FILE="${GRUNT_DICTATION_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/grunt-dictation/config.env}"

if [[ -n "${GRUNT_DICTATION_CONFIG:-}" ]]; then
  if [[ -f "$GRUNT_DICTATION_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$GRUNT_DICTATION_CONFIG"
  fi
else
  if [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SYSTEM_CONFIG_FILE"
  fi
  if [[ -f "$USER_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$USER_CONFIG_FILE"
  fi
fi

WHISPER_CLI="${WHISPER_CLI:-/usr/lib/grunt-dictation/whisper-cli}"
MODEL_PATH="${MODEL_PATH:-$HOME/.local/share/grunt-dictation/models/ggml-base.en.bin}"
AUDIO_DEVICE="${AUDIO_DEVICE:-default}"
AUDIO_FORMAT="${AUDIO_FORMAT:-auto}"
MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-300}"
WHISPER_THREADS="${WHISPER_THREADS:-2}"
WHISPER_NICE_LEVEL="${WHISPER_NICE_LEVEL:-10}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"
AUTO_PASTE="${AUTO_PASTE:-true}"
DICTATION_CONTROL="${DICTATION_CONTROL:-grunt-dictationctl}"
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
CONTROL_FD_OPEN=false

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
    if [[ -n "$timer_pid" ]]; then
      kill -TERM "$timer_pid" 2>/dev/null || true
      wait "$timer_pid" 2>/dev/null || true
    fi
    rm -f "$TIMER_PID_FILE"
  fi
}

start_recording_timer() {
  (
    local sleep_pid=""

    stop_timer_sleep() {
      if [[ -n "$sleep_pid" ]]; then
        kill -TERM "$sleep_pid" 2>/dev/null || true
        wait "$sleep_pid" 2>/dev/null || true
      fi
    }

    trap 'stop_timer_sleep; exit 0' INT TERM
    sleep "$MAX_RECORD_SECONDS" &
    sleep_pid="$!"
    wait "$sleep_pid" || exit 0
    sleep_pid=""

    touch "$RUNTIME_DIR/timed_out"
    printf 'record-stop\n' > "$CONTROL_FIFO" 2>/dev/null
  ) &

  printf '%s\n' "$!" > "$TIMER_PID_FILE"
  log "auto-stop timer set for ${MAX_RECORD_SECONDS}s"
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

  start_recording_timer
}

normalize_transcript_file() {
  local source_file="$1"
  local target_file="$2"

  awk '
    {
      gsub(/\r/, "")
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      if (length($0) > 0) {
        if (has_text) {
          printf " "
        }
        printf "%s", $0
        has_text = 1
      }
    }
    END {
      if (has_text) {
        printf "\n"
      }
    }
  ' "$source_file" > "$target_file"
}

remove_recording_files() {
  rm -f "$RAW_WAV" "${TRANSCRIPT_BASENAME}.txt"
}

paste_transcript() {
  if "$DICTATION_CONTROL" type-text >/dev/null 2>&1; then
    log "transcript pasted into focused application"
    return 0
  fi

  log "automatic paste failed; transcript remains available"
  return 1
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
    remove_recording_files
    notify_state "No speech captured" "The previous transcript was preserved"
    set_state "idle"
    return 0
  fi

  if [[ ! -x "$WHISPER_CLI" ]]; then
    log "whisper-cli not executable at $WHISPER_CLI"
    remove_recording_files
    set_state "idle"
    return 1
  fi

  if [[ ! -f "$MODEL_PATH" ]]; then
    log "model missing at $MODEL_PATH"
    remove_recording_files
    set_state "idle"
    return 1
  fi

  rm -f "${TRANSCRIPT_BASENAME}.txt"
  local transcript_updated=false
  local whisper_exit_code=0
  nice -n "$WHISPER_NICE_LEVEL" "$WHISPER_CLI" \
    -m "$MODEL_PATH" \
    -f "$RAW_WAV" \
    -t "$WHISPER_THREADS" \
    -l "$WHISPER_LANGUAGE" \
    --no-prints \
    --output-txt \
    --output-file "$TRANSCRIPT_BASENAME" \
    >/dev/null 2>>"$LOG_FILE" || whisper_exit_code="$?"

  if [[ "$whisper_exit_code" -eq 0 && -s "${TRANSCRIPT_BASENAME}.txt" ]]; then
    local transcript_candidate
    transcript_candidate="$(mktemp "$RUNTIME_DIR/transcript.candidate.XXXXXX")"
    normalize_transcript_file "${TRANSCRIPT_BASENAME}.txt" "$transcript_candidate"

    if [[ -s "$transcript_candidate" ]]; then
      mv "$transcript_candidate" "$TRANSCRIPT_FILE"
      transcript_updated=true
    else
      rm -f "$transcript_candidate"
    fi
  fi

  remove_recording_files

  if [[ "$whisper_exit_code" -ne 0 ]]; then
    log "transcription failed (exit=$whisper_exit_code); previous transcript preserved"
    notify_state "Transcription failed" "The previous transcript was preserved"
  elif [[ "$transcript_updated" == true ]]; then
    log "transcription completed"
    if [[ "$AUTO_PASTE" != "true" ]]; then
      notify_state "Transcript ready" "Available to copy or paste"
    elif paste_transcript; then
      notify_state "Transcript ready" "Pasted into the focused application"
    else
      notify_state "Transcript ready" "Automatic paste failed; use copy-text"
    fi
  else
    log "transcription produced no output; previous transcript preserved"
    notify_state "No speech detected" "The previous transcript was preserved"
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
  if [[ "$CONTROL_FD_OPEN" == true ]]; then
    exec 3>&-
    CONTROL_FD_OPEN=false
  fi
  remove_recording_files
  rm -f "$FFMPEG_PID_FILE" "$CONTROL_FIFO" "$RUNTIME_DIR/timed_out"
}

on_exit() {
  cleanup
  set_state "stopped"
  log "daemon stopped"
}

run_daemon() {
  mkdir -p "$RUNTIME_DIR"
  remove_recording_files
  : > "$LOG_FILE"
  touch "$TRANSCRIPT_FILE"

  trap on_exit EXIT
  trap 'exit 0' INT TERM

  rm -f "$CONTROL_FIFO"
  mkfifo "$CONTROL_FIFO"
  exec 3<> "$CONTROL_FIFO"
  CONTROL_FD_OPEN=true
  set_state "idle"
  log "daemon started"

  while true; do
    if ! IFS= read -r -t 0.5 command <&3; then
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_daemon
fi
