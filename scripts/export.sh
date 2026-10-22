#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
source "$ROOT/scripts/nextcloud.sh"
APP_STOPPED=0
SUCCESS=0
# Preserve the existing restart behavior; final-cutover mode is explicitly opt-in.
LEAVE_GRIMMORY_STOPPED="${LEAVE_GRIMMORY_STOPPED:-0}"
cleanup() {
  local rc=$?
  nextcloud_cleanup
  if (( APP_STOPPED == 1 )) && { (( SUCCESS == 0 )) || [[ "$LEAVE_GRIMMORY_STOPPED" == 0 ]]; }; then
    echo 'Restoring source Grimmory container...'
    docker start "$APP_CONTAINER" >/dev/null || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
[[ $# -le 1 ]] || die 'Usage: scripts/export.sh [/path/to/new-backup-directory]'
[[ "$LEAVE_GRIMMORY_STOPPED" == 0 || "$LEAVE_GRIMMORY_STOPPED" == 1 ]] || die 'LEAVE_GRIMMORY_STOPPED must be 0 or 1'
preflight
assert_mounts
[[ "$(state "$DB_CONTAINER")" == true ]] || die 'Database must be running'
[[ "$(state "$APP_CONTAINER")" == true ]] || die 'Application must be running when starting export'
SOURCE_APP_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$APP_CONTAINER")"
SOURCE_APP_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$APP_CONTAINER")"
# Inspect the image actually used by the container, not a possibly repulled latest tag.
SOURCE_APP_REPO_DIGEST="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$SOURCE_APP_IMAGE_ID")"
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
MOUNT_KIB="$(docker run --rm --volumes-from "$APP_CONTAINER":ro "$IMAGE" du -sk /app/data /books /bookdrop | awk '{total += $1} END {printf "%.0f", total}')"
DB_BYTES="$(docker exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" mariadb --batch --skip-column-names \
  --user="$DB_USER" --database="$DB_NAME" --execute='SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE();')"
AVAILABLE_KIB="$(df -Pk "$(dirname "$OUTPUT")" | awk 'NR==2 {print $4}')"
[[ "$MOUNT_KIB" =~ ^[0-9]+$ && "$DB_BYTES" =~ ^[0-9]+$ && "$AVAILABLE_KIB" =~ ^[0-9]+$ ]] || die 'Cannot estimate staging space'
REQUIRED_BYTES=$(( (MOUNT_KIB * 1024 + DB_BYTES) * (100 + SPACE_MARGIN_PERCENT) / 100 + SPACE_MARGIN_BYTES ))
echo "Estimated staging requirement: $REQUIRED_BYTES bytes; available: $((AVAILABLE_KIB * 1024)) bytes"
(( AVAILABLE_KIB * 1024 >= REQUIRED_BYTES )) || die 'Not enough staging space; set GRIMMORY_TRANSFER_WORKDIR to a larger filesystem'

nextcloud_init
nextcloud_preflight
mkdir -m 700 -- "$OUTPUT"
create_remote_pending_marker "$MIGRATION_ID"
printf 'Stopping app to prevent writes during backup...\n'
APP_STOPPED=1
docker stop "$APP_CONTAINER" >/dev/null
printf 'Dumping MariaDB...\n'
docker exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_CONTAINER" mariadb-dump \
  --user="$DB_USER" --single-transaction --quick --routines --events --triggers \
  --hex-blob --no-tablespaces "$DB_NAME" > "$OUTPUT/database.sql"
[[ -s "$OUTPUT/database.sql" ]] || die 'Database dump is empty'
for entry in 'app-data:/app/data' 'books:/books' 'bookdrop:/bookdrop'; do
  name="${entry%%:*}" path="${entry#*:}"
  echo "Archiving $path"
  docker run --rm --volumes-from "$APP_CONTAINER":ro -v "$OUTPUT:/backup" "$IMAGE" \
    tar -C "$path" -czf "/backup/$name.tar.gz" .
done
cat > "$OUTPUT/manifest.txt" <<MANIFEST
format=grimmory-transfer-v1
created_utc=$(date -u +%FT%TZ)
source_app_image=$SOURCE_APP_IMAGE
source_app_image_id=$SOURCE_APP_IMAGE_ID
source_app_repo_digest=$SOURCE_APP_REPO_DIGEST
source_db_image=$(docker inspect --format '{{.Config.Image}}' "$DB_CONTAINER")
db_name=$DB_NAME
source_container=$APP_CONTAINER
mounts=/app/data,/books,/bookdrop
MANIFEST
(cd "$OUTPUT" && sha256sum "${ARTIFACTS[@]}" > SHA256SUMS)
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
