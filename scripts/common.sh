#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
APP_CONTAINER="${APP_CONTAINER:-grimmory}"
DB_CONTAINER="${DB_CONTAINER:-mariadb}"
DB_NAME="${DB_NAME:-grimmory}"
DB_USER="${DB_USER:-grimmory}"
IMAGE="${UTILITY_IMAGE:-alpine:3.20}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups}"
die() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null || die "Missing executable: $1"; }
preflight() {
  require docker; require sha256sum
  docker inspect "$APP_CONTAINER" >/dev/null || die "App container not found: $APP_CONTAINER"
  docker inspect "$DB_CONTAINER" >/dev/null || die "Database container not found: $DB_CONTAINER"
  [[ -n "${DB_PASSWORD:-}" ]] || die "Set DB_PASSWORD in .env (chmod 600 .env)"
}
state() { docker inspect --format '{{.State.Running}}' "$1"; }
mount_exists() {
  docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$APP_CONTAINER" | grep -Fxq "$1"
}
assert_mounts() {
  for path in /app/data /books /bookdrop; do
    mount_exists "$path" || die "Missing separate Docker mount at $path in $APP_CONTAINER. Adjust your Compose mounts first."
  done
}
sha_check() { (cd "$1" && sha256sum -c SHA256SUMS); }
