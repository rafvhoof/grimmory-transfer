#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
source "$ROOT/scripts/nextcloud.sh"
APP_STOPPED=0
SUCCESS=0
EXPORT_STATE_DIR=''
# Preserve the existing restart behavior; final-cutover mode is explicitly opt-in.
LEAVE_GRIMMORY_STOPPED="${LEAVE_GRIMMORY_STOPPED:-0}"
cleanup() {
  local rc=$? container_id
  trap - EXIT
  # Repeated Ctrl+C must not abort the attempt to restore the source app.
  trap '' INT TERM
  if [[ -n "$EXPORT_STATE_DIR" ]]; then
    # The CID file also survives command substitutions used for size estimates.
    if [[ -s "$EXPORT_STATE_DIR/container.cid" ]]; then
      container_id="$(cat "$EXPORT_STATE_DIR/container.cid")"
      if [[ "$container_id" =~ ^[a-f0-9]{64}$ ]]; then
        echo "Removing backup helper container: $container_id" >&2
        docker_check rm -f "$container_id" >/dev/null || {
          echo "WARNING: Could not remove backup helper $container_id; check it with docker inspect." >&2
          rc=1
        }
      fi
    fi
    rm -f -- "$EXPORT_STATE_DIR/container.cid" || rc=1
    rmdir -- "$EXPORT_STATE_DIR" || rc=1
  fi
  nextcloud_cleanup || rc=1
  if (( APP_STOPPED == 1 )) && { (( SUCCESS == 0 )) || [[ "$LEAVE_GRIMMORY_STOPPED" == 0 ]]; }; then
    echo 'Restoring source Grimmory container...'
    docker_check start "$APP_CONTAINER" >/dev/null || {
      echo "ERROR: Could not restart source app; run: docker start $APP_CONTAINER" >&2
      rc=1
    }
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'echo "Export interrupted; cleaning up..." >&2; exit 130' INT
trap 'echo "Export terminated; cleaning up..." >&2; exit 143' TERM
[[ $# -le 1 ]] || die 'Usage: scripts/export.sh [/path/to/new-backup-directory]'
[[ "$LEAVE_GRIMMORY_STOPPED" == 0 || "$LEAVE_GRIMMORY_STOPPED" == 1 ]] || die 'LEAVE_GRIMMORY_STOPPED must be 0 or 1'
preflight
assert_mounts
[[ "$(state "$DB_CONTAINER")" == true ]] || die 'Database must be running'
[[ "$(state "$APP_CONTAINER")" == true ]] || die 'Application must be running when starting export'
echo 'Reading source image metadata...'
SOURCE_APP_IMAGE="$(docker_check inspect --format '{{.Config.Image}}' "$APP_CONTAINER")"
SOURCE_APP_IMAGE_ID="$(docker_check inspect --format '{{.Image}}' "$APP_CONTAINER")"
# Inspect the image actually used by the container, not a possibly repulled latest tag.
SOURCE_APP_REPO_DIGEST="$(docker_check image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$SOURCE_APP_IMAGE_ID")"
SOURCE_DB_IMAGE="$(docker_check inspect --format '{{.Config.Image}}' "$DB_CONTAINER")"
require tar; require awk; require df
MIGRATION_ID="${MIGRATION_ID:-grimmory-$(date -u +%Y%m%dT%H%M%SZ)}"
validate_migration_id "$MIGRATION_ID"
OUTPUT="${1:-$BACKUP_DIR/$MIGRATION_ID}"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || die "Destination exists: $OUTPUT"
mkdir -p -- "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

# Estimate an uncompressed staging copy plus DB size, margin and fixed overhead.
SPACE_MARGIN_PERCENT="${SPACE_MARGIN_PERCENT:-25}"
SPACE_MARGIN_BYTES="${SPACE_MARGIN_BYTES:-536870912}"
[[ "$SPACE_MARGIN_PERCENT" =~ ^[0-9]+$ && "$SPACE_MARGIN_BYTES" =~ ^[0-9]+$ ]] || die 'Space margins must be nonnegative integers'
SPACE_SCAN_TIMEOUT="${SPACE_SCAN_TIMEOUT:-1800}"
[[ "$SPACE_SCAN_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'SPACE_SCAN_TIMEOUT must be a positive integer (seconds)'
EXPORT_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grimmory-export.XXXXXX")"
MOUNT_KIB=0
for path in /app/data /books /bookdrop; do
  echo "Estimating $path size using $IMAGE (timeout ${SPACE_SCAN_TIMEOUT}s; large or network libraries can take time)..."
  # --init forwards interrupts to du; keep its ID in case Docker has to be killed.
  MOUNT_SIZE="$(timeout --kill-after=5 "${SPACE_SCAN_TIMEOUT}s" docker run --rm --init \
    --cidfile "$EXPORT_STATE_DIR/container.cid" --volumes-from "$APP_CONTAINER":ro "$IMAGE" du -sk "$path")" \
    || die "Size scan failed or timed out for $path; check Docker and the backing filesystem, or increase SPACE_SCAN_TIMEOUT for a slow library"
  rm -f -- "$EXPORT_STATE_DIR/container.cid"
  MOUNT_SIZE="$(awk '{print $1}' <<< "$MOUNT_SIZE")"
  [[ "$MOUNT_SIZE" =~ ^[0-9]+$ ]] || die "Cannot estimate size of $path"
  echo "Estimated $path: $MOUNT_SIZE KiB"
  MOUNT_KIB=$((MOUNT_KIB + MOUNT_SIZE))
done
echo 'Estimating database size...'
DB_BYTES="$(docker_check exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" mariadb --batch --skip-column-names \
  --user="$DB_USER" --database="$DB_NAME" --execute='SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE();')"
AVAILABLE_KIB="$(df -Pk "$(dirname "$OUTPUT")" | awk 'NR==2 {print $4}')"
[[ "$MOUNT_KIB" =~ ^[0-9]+$ && "$DB_BYTES" =~ ^[0-9]+$ && "$AVAILABLE_KIB" =~ ^[0-9]+$ ]] || die 'Cannot estimate staging space'
REQUIRED_BYTES=$(( (MOUNT_KIB * 1024 + DB_BYTES) * (100 + SPACE_MARGIN_PERCENT) / 100 + SPACE_MARGIN_BYTES ))
echo "Estimated staging requirement: $REQUIRED_BYTES bytes; available: $((AVAILABLE_KIB * 1024)) bytes"
(( AVAILABLE_KIB * 1024 >= REQUIRED_BYTES )) || die 'Not enough staging space; set GRIMMORY_TRANSFER_WORKDIR to a larger filesystem'

echo 'Preparing Nextcloud transport...'
nextcloud_init
nextcloud_preflight
mkdir -m 700 -- "$OUTPUT"
echo "Creating Nextcloud pending marker for $MIGRATION_ID..."
create_remote_pending_marker "$MIGRATION_ID"
printf 'Stopping app to prevent writes during backup...\n'
APP_STOPPED=1
docker_check stop "$APP_CONTAINER" >/dev/null
printf 'Dumping MariaDB...\n'
docker exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" mariadb-dump \
  --user="$DB_USER" --single-transaction --quick --routines --events --triggers \
  --hex-blob --no-tablespaces "$DB_NAME" > "$OUTPUT/database.sql"
[[ -s "$OUTPUT/database.sql" ]] || die 'Database dump is empty'
for entry in 'app-data:/app/data' 'books:/books' 'bookdrop:/bookdrop'; do
  name="${entry%%:*}" path="${entry#*:}"
  echo "Archiving $path"
  docker run --rm --init --cidfile "$EXPORT_STATE_DIR/container.cid" \
    --volumes-from "$APP_CONTAINER":ro -v "$OUTPUT:/backup" "$IMAGE" \
    tar -C "$path" -czf "/backup/$name.tar.gz" .
  rm -f -- "$EXPORT_STATE_DIR/container.cid"
done
cat > "$OUTPUT/manifest.txt" <<MANIFEST
format=grimmory-transfer-v1
created_utc=$(date -u +%FT%TZ)
source_app_image=$SOURCE_APP_IMAGE
source_app_image_id=$SOURCE_APP_IMAGE_ID
source_app_repo_digest=$SOURCE_APP_REPO_DIGEST
source_db_image=$SOURCE_DB_IMAGE
db_name=$DB_NAME
source_container=$APP_CONTAINER
mounts=/app/data,/books,/bookdrop
MANIFEST
echo 'Calculating backup checksums...'
(cd "$OUTPUT" && sha256sum "${ARTIFACTS[@]}" > SHA256SUMS)
echo 'Verifying and uploading backup...'
upload_bundle "$OUTPUT" "$MIGRATION_ID"
SUCCESS=1
echo "Export completed. Migration ID: $MIGRATION_ID"
echo "Local staging copy: $OUTPUT"
if [[ -n "$SOURCE_APP_REPO_DIGEST" ]]; then
  echo "Destination GRIMMORY_IMAGE: $SOURCE_APP_REPO_DIGEST"
fi
if [[ "$LEAVE_GRIMMORY_STOPPED" == 1 ]]; then
  echo 'Source Grimmory is left stopped to prevent changes after the final export.'
fi
echo 'Retain the source VM and private migration copies until the new VM is validated.'
