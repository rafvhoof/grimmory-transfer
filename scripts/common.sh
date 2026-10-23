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
BOOKS_MODE=copy
set_books_mode() {
  BOOKS_MODE="$1"
  case "$BOOKS_MODE" in
    copy) ARTIFACTS=(database.sql app-data.tar.gz books.tar.gz bookdrop.tar.gz manifest.txt) ;;
    shared) ARTIFACTS=(database.sql app-data.tar.gz bookdrop.tar.gz manifest.txt) ;;
    *) die "Unsupported books mode: $BOOKS_MODE" ;;
  esac
}
load_bundle_mode() {
  local format
  [[ -f "$1/manifest.txt" && ! -L "$1/manifest.txt" ]] || die 'Missing or symlinked backup manifest'
  format="$(metadata_value "$1" format)"
  case "$format" in
    grimmory-transfer-v1)
      [[ -z "$(metadata_value "$1" books_mode)" ]] || die 'Legacy bundle cannot declare a books mode'
      set_books_mode copy
      ;;
    grimmory-transfer-v2)
      [[ "$(metadata_value "$1" books_mode)" == shared ]] || die 'Unsupported books mode in v2 bundle'
      set_books_mode shared
      ;;
    *) die 'Unsupported backup format' ;;
  esac
}
reuse_books_setting() {
  REUSE_EXISTING_BOOKS="${REUSE_EXISTING_BOOKS:-0}"
  [[ "$REUSE_EXISTING_BOOKS" == 0 || "$REUSE_EXISTING_BOOKS" == 1 ]] || die 'REUSE_EXISTING_BOOKS must be 0 or 1'
}
check_shared_books() {
  local access="$1"
  # Check through the app's actual /books mount, without traversing the library.
  docker_check run --rm --volumes-from "$APP_CONTAINER":ro "$IMAGE" sh -c \
    'test -d /books && test -r /books && test -x /books && test -n "$(ls -A /books)"' \
    || die "Shared /books is empty or inaccessible on the $access; mount the same Synology library before continuing"
}
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
  # Drain Docker's output: grep -q can close the pipe early and cause SIGPIPE.
  docker_check inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$APP_CONTAINER" | grep -Fx "$1" >/dev/null
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
      database.sql|app-data.tar.gz|bookdrop.tar.gz|manifest.txt) ;;
      books.tar.gz) [[ "$BOOKS_MODE" == copy ]] || die 'Shared-books bundle must not contain a books archive checksum' ;;
      *) die "Unexpected checksum path: $file" ;;
    esac
    [[ -z "${seen[$file]:-}" ]] || die "Duplicate checksum for $file"
    seen[$file]=1
  done < "$1/SHA256SUMS"
  for file in "${ARTIFACTS[@]}"; do
    [[ -n "${seen[$file]:-}" ]] || die "Missing checksum for $file"
  done
  [[ "${#seen[@]}" -eq "${#ARTIFACTS[@]}" ]] || die 'Unexpected checksum entries'
  (cd "$1" && sha256sum -c SHA256SUMS)
}
verify_bundle() {
  local file
  require sha256sum; require tar
  load_bundle_mode "$1"
  for file in "${ARTIFACTS[@]}" SHA256SUMS; do
    [[ -f "$1/$file" && ! -L "$1/$file" ]] || die "Missing or symlinked backup artifact: $file"
  done
  if [[ "$BOOKS_MODE" == shared ]]; then
    [[ ! -e "$1/books.tar.gz" && ! -L "$1/books.tar.gz" ]] || die 'Shared-books bundle must not contain books.tar.gz'
  fi
  sha_check "$1"
  for file in app-data.tar.gz bookdrop.tar.gz; do
    tar -tzf "$1/$file" >/dev/null || die "Corrupt archive: $file"
  done
  if [[ "$BOOKS_MODE" == copy ]]; then
    tar -tzf "$1/books.tar.gz" >/dev/null || die 'Corrupt archive: books.tar.gz'
  fi
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
