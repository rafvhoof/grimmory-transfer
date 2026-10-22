#!/usr/bin/env bash
# Activity reporting only: the actual command stays in the foreground so its
# status, stdout and signal handling are unchanged. Call progress_stop in cleanup.
PROGRESS_PID=''

progress_render() {
  local status="$1" elapsed=$((SECONDS - PROGRESS_STARTED)) bytes detail='' bar offset
  if [[ -n "$PROGRESS_FILE" && -f "$PROGRESS_FILE" ]]; then
    bytes="$(stat -c %s -- "$PROGRESS_FILE" 2>/dev/null)" || bytes=''
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
      printf -v detail ' | written %d.%d MiB' "$((bytes / 1048576))" "$((bytes % 1048576 * 10 / 1048576))"
    fi
  fi
  if (( PROGRESS_TTY == 1 )); then
    # Bounce across the bar; unknown totals must not look like a percentage.
    bar='....................'
    offset=$((elapsed % 34))
    (( offset <= 17 )) || offset=$((34 - offset))
    if [[ "$status" == working ]]; then
      status="${bar:0:offset}===${bar:offset+3}"
    fi
    printf '\r\033[2K[%s] %s | elapsed %02d:%02d:%02d%s' \
      "$status" "$PROGRESS_LABEL" "$((elapsed / 3600))" "$((elapsed / 60 % 60))" "$((elapsed % 60))" "$detail" >&2
    [[ "$status" != done && "$status" != stopped ]] || printf '\n' >&2
  else
    printf '[%s] %s | elapsed %02d:%02d:%02d%s\n' \
      "$status" "$PROGRESS_LABEL" "$((elapsed / 3600))" "$((elapsed / 60 % 60))" "$((elapsed % 60))" "$detail" >&2
  fi
}

progress_start() {
  # Optional third argument "lines" keeps verbose tool output on separate lines.
  local interval=10
  PROGRESS_LABEL="$1"
  PROGRESS_FILE="${2:-}"
  PROGRESS_STARTED=$SECONDS
  PROGRESS_TTY=0
  if [[ "${3:-}" != lines && -t 2 && "${TERM:-dumb}" != dumb ]]; then
    PROGRESS_TTY=1
    interval=1
  fi
  progress_render working
  (
    # Do not inherit the export's cleanup/error traps in this display process.
    trap - EXIT ERR
    sleeper=''
    trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' TERM
    while :; do
      sleep "$interval" &
      sleeper=$!
      wait "$sleeper" || exit 0
      sleeper=''
      progress_render working
    done
  ) </dev/null >/dev/null &
  PROGRESS_PID=$!
}

progress_stop() {
  [[ -n "${PROGRESS_PID:-}" ]] || return 0
  kill "$PROGRESS_PID" 2>/dev/null || true
  wait "$PROGRESS_PID" 2>/dev/null || true
  PROGRESS_PID=''
  progress_render "${1:-done}"
}
