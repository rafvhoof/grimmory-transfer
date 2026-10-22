#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null || die "Missing executable: $1"; }
if [[ -n "${TRANSFER_ENV_FILE:-}" ]]; then
  [[ -f "$TRANSFER_ENV_FILE" ]] || die "Configuration file not found: $TRANSFER_ENV_FILE"
elif [[ -f /etc/grimmory-transfer.env ]]; then
  TRANSFER_ENV_FILE=/etc/grimmory-transfer.env
else
  TRANSFER_ENV_FILE="$ROOT/.env"
fi
if [[ -f "$TRANSFER_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$TRANSFER_ENV_FILE"
fi
APP_CONTAINER="${APP_CONTAINER:-grimmory}"
DB_CONTAINER="${DB_CONTAINER:-mariadb}"
DB_NAME="${DB_NAME:-grimmory}"
DB_USER="${DB_USER:-grimmory}"
IMAGE="${UTILITY_IMAGE:-alpine:3.20}"
BACKUP_DIR="${GRIMMORY_TRANSFER_WORKDIR:-${BACKUP_DIR:-/var/tmp/grimmory-transfer}}"
ARTIFACTS=(database.sql app-data.tar.gz books.tar.gz bookdrop.tar.gz manifest.txt)
# Only short Docker operations use this limit; archives and SQL dumps can be large.
docker_check() {
  local rc
  if timeout --kill-after=5 "${DOCKER_TIMEOUT}s" docker "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$rc" == 124 || "$rc" == 137 ]]; then
    echo "ERROR: Docker $1 timed out after ${DOCKER_TIMEOUT}s; check the Docker daemon and its storage." >&2
  fi
  return "$rc"
}
preflight() {
  require docker; require sha256sum; require timeout
  DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-30}"
  [[ "$DOCKER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'DOCKER_TIMEOUT must be a positive integer (seconds)'
  echo "Checking Docker access to app container: $APP_CONTAINER (timeout ${DOCKER_TIMEOUT}s)..." >&2
  docker_check inspect "$APP_CONTAINER" >/dev/null || die "Cannot inspect app container: $APP_CONTAINER"
  echo "Checking database container: $DB_CONTAINER..." >&2
  docker_check inspect "$DB_CONTAINER" >/dev/null || die "Cannot inspect database container: $DB_CONTAINER"
  [[ -n "${DB_PASSWORD:-}" ]] || die "Set DB_PASSWORD in the private transfer configuration (chmod 600)"
}
state() { docker_check inspect --format '{{.State.Running}}' "$1"; }
mount_exists() {
  docker_check inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$APP_CONTAINER" | grep -Fxq "$1"
}
assert_mounts() {
  echo 'Checking required Docker mounts...' >&2
  for path in /app/data /books /bookdrop; do
    mount_exists "$path" || die "Missing separate Docker mount at $path in $APP_CONTAINER. Adjust your Compose mounts first."
  done
}
sha_check() {
  local line file
  local -A seen=()
  [[ -f "$1/SHA256SUMS" ]] || die 'Missing SHA256SUMS'
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[a-fA-F0-9]{64}[[:space:]][\ \*]([a-zA-Z0-9.-]+)$ ]] || die 'Invalid SHA256SUMS entry'
    file="${BASH_REMATCH[1]}"
    case "$file" in
      database.sql|app-data.tar.gz|books.tar.gz|bookdrop.tar.gz|manifest.txt) ;;
      *) die "Unexpected checksum path: $file" ;;
    esac
    [[ -z "${seen[$file]:-}" ]] || die "Duplicate checksum for $file"
    seen[$file]=1
  done < "$1/SHA256SUMS"
  for file in "${ARTIFACTS[@]}"; do
    [[ -n "${seen[$file]:-}" ]] || die "Missing checksum for $file"
  done
  (cd "$1" && sha256sum -c SHA256SUMS)
}
verify_bundle() {
  local file
  require sha256sum; require tar
  for file in "${ARTIFACTS[@]}" SHA256SUMS; do
    [[ -f "$1/$file" && ! -L "$1/$file" ]] || die "Missing or symlinked backup artifact: $file"
  done
  sha_check "$1"
  grep -Fxq 'format=grimmory-transfer-v1' "$1/manifest.txt" || die 'Unsupported backup format'
  for file in app-data.tar.gz books.tar.gz bookdrop.tar.gz; do
    tar -tzf "$1/$file" >/dev/null || die "Corrupt archive: $file"
  done
}
metadata_value() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$2="* ]]; then
      printf '%s' "${line#*=}"
      return
    fi
  done < "$1/manifest.txt"
}
