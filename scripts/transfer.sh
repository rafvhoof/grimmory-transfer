#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
source "$ROOT/scripts/nextcloud.sh"
trap nextcloud_cleanup EXIT

usage() {
  die 'Usage: scripts/transfer.sh upload /path/to/backup [migration-id] | download [migration-id [local-directory]] | preflight'
}
[[ $# -ge 1 && $# -le 3 ]] || usage
ACTION="$1"
case "$ACTION" in
  upload)
    [[ $# -ge 2 && -d "$2" ]] || usage
    LOCAL_DIR="$(cd "$2" && pwd)"
    MIGRATION_ID="${3:-${LOCAL_DIR##*/}}"
    validate_migration_id "$MIGRATION_ID"
    ;;
  download) MIGRATION_ID="${2:-${MIGRATION_ID:-}}" ;;
  preflight) [[ $# -eq 1 ]] || usage ;;
  *) usage ;;
esac
nextcloud_init
case "$ACTION" in
  upload) upload_bundle "$LOCAL_DIR" "$MIGRATION_ID" ;;
  download)
    MIGRATION_ID="$(resolve_migration_id)"
    download_bundle "$MIGRATION_ID" "${3:-$BACKUP_DIR/$MIGRATION_ID}"
    ;;
  preflight) nextcloud_preflight ;;
esac
