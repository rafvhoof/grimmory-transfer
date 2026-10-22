#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
preflight
assert_mounts
[[ "$(state "$DB_CONTAINER")" == true ]] || die "Database must be running"
[[ "$(state "$APP_CONTAINER")" == true ]] || die "Application must be running when starting export"
require tar
mkdir -p "$BACKUP_DIR"
OUTPUT="${1:-$BACKUP_DIR/grimmory-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ ! -e "$OUTPUT" ]] || die "Destination exists: $OUTPUT"
mkdir -m 700 "$OUTPUT"
resume() { if [[ "${APP_STOPPED:-0}" == 1 ]]; then docker start "$APP_CONTAINER" >/dev/null || true; fi; }
trap resume EXIT
printf 'Stopping app to prevent writes during backup...\n'
docker stop "$APP_CONTAINER" >/dev/null
APP_STOPPED=1
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
source_app_image=$(docker inspect --format '{{.Config.Image}}' "$APP_CONTAINER")
source_db_image=$(docker inspect --format '{{.Config.Image}}' "$DB_CONTAINER")
db_name=$DB_NAME
source_container=$APP_CONTAINER
mounts=/app/data,/books,/bookdrop
MANIFEST
(cd "$OUTPUT" && sha256sum database.sql app-data.tar.gz books.tar.gz bookdrop.tar.gz manifest.txt > SHA256SUMS)
sha_check "$OUTPUT"
echo "Export completed: $OUTPUT"
echo 'Keep this backup encrypted and off GitHub: it may contain books, account data, and credentials.'
