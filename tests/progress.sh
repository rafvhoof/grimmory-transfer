#!/usr/bin/env bash
# Exercise progress around real foreground commands without Docker or Nextcloud.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grimmory-progress-test.XXXXXX")"
source "$ROOT/scripts/progress.sh"
cleanup() {
  progress_stop stopped || true
  [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}"/grimmory-progress-test.* ]] || exit 1
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

# A slow scan must emit an intermediate update even when stderr is redirected.
{
  progress_start 'Slow size scan'
  display_pid=$PROGRESS_PID
  scan_size="$(sleep 11; printf '1234\n')"
  progress_stop
} > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/progress.log"
[[ "$scan_size" == 1234 && ! -s "$TEST_ROOT/stdout" ]]
[[ "$(grep -c '\[working\] Slow size scan' "$TEST_ROOT/progress.log")" -ge 2 ]]
grep -q '\[done\] Slow size scan' "$TEST_ROOT/progress.log"
! grep -q $'\033\|\r' "$TEST_ROOT/progress.log"
! kill -0 "$display_pid" 2>/dev/null
printf 'PASS: slow scans report intermediate progress without contaminating stdout\n'

# Progress is separate from the output file; show the actual final size.
{
  progress_start 'Database dump' "$TEST_ROOT/database.sql"
  printf 'SELECT 1;\n' > "$TEST_ROOT/database.sql"
  progress_stop
} 2> "$TEST_ROOT/dump.log"
[[ "$(cat "$TEST_ROOT/database.sql")" == 'SELECT 1;' ]]
grep -q '\[done\] Database dump.*written 0.0 MiB' "$TEST_ROOT/dump.log"
printf 'PASS: output sizes are reported without changing backup data\n'

# Use the same foreground-command/EXIT-trap pattern as export; failure and
# termination must retain the exit status and reap the display process.
cat > "$TEST_ROOT/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$1/scripts/progress.sh"
cleanup() {
  local rc=$?
  trap - EXIT
  progress_stop stopped
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
progress_start 'Interrupted work'
printf '%s\n' "$PROGRESS_PID" > "$2"
case "$3" in
  failure) bash -c 'exit 42' ;;
  signal) kill -TERM "$BASHPID" ;;
esac
WORKER
for mode in failure signal; do
  rc=0
  bash "$TEST_ROOT/worker.sh" "$ROOT" "$TEST_ROOT/pid" "$mode" 2> "$TEST_ROOT/worker.log" || rc=$?
  if [[ "$mode" == failure ]]; then [[ "$rc" == 42 ]]; else [[ "$rc" == 143 ]]; fi
  ! kill -0 "$(cat "$TEST_ROOT/pid")" 2>/dev/null
  grep -q '\[stopped\] Interrupted work' "$TEST_ROOT/worker.log"
done
printf 'PASS: command failures and interrupts retain their status and stop progress\n'
