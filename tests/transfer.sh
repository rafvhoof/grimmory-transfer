#!/usr/bin/env bash
# Offline integration tests: real files/checksums; fake Docker and rclone transports.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grimmory-transfer-test.XXXXXX")"
cleanup() {
  [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}"/grimmory-transfer-test.* ]] || exit 1
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
report_failure() {
  echo "FAIL: integration test at line $1" >&2
  if [[ -f "$TEST_ROOT/failure.log" ]]; then
    cat "$TEST_ROOT/failure.log" >&2
  fi
}
trap 'report_failure "$LINENO"' ERR
mkdir -p "$TEST_ROOT/host/scripts" "$TEST_ROOT/bin" "$TEST_ROOT/remote" "$TEST_ROOT/source backup" "$TEST_ROOT/content"
cp "$ROOT/scripts/"*.sh "$TEST_ROOT/host/scripts/"
cp "$ROOT/tests/helpers/"* "$TEST_ROOT/bin/"
chmod +x "$TEST_ROOT/bin/"*
export MOCK_REAL_DF="$(command -v df)"
export PATH="$TEST_ROOT/bin:$PATH"
export MOCK_REMOTE="$TEST_ROOT/remote" MOCK_LOG="$TEST_ROOT/commands.log"
export MOCK_CONFIGS="$TEST_ROOT/configs.log" MOCK_WRITES="$TEST_ROOT/writes.log"
export MOCK_CONTENT="$TEST_ROOT/content" MOCK_APP_STATE="$TEST_ROOT/app-state"
export TRANSFER_ENV_FILE="$TEST_ROOT/transfer.env" BACKUP_DIR="$TEST_ROOT/downloads"
cat > "$TRANSFER_ENV_FILE" <<'CONFIG'
NC_URL='https://cloud.example.com/nextcloud'
NC_USER='user@example.com'
NC_APP_PASSWORD='app password $with!characters'
NC_REMOTE_ROOT='Migration backups/Grimmory'
AUTO_INSTALL_RCLONE=0
DB_PASSWORD='test-database-password'
CONFIG
REMOTE_ROOT="$MOCK_REMOTE/Migration backups/Grimmory"
printf 'true\n' > "$MOCK_APP_STATE"
printf 'Book content\n' > "$MOCK_CONTENT/book.txt"
ARTIFACTS=(database.sql app-data.tar.gz books.tar.gz bookdrop.tar.gz manifest.txt)
SOURCE="$TEST_ROOT/source backup"
printf 'SELECT 1;\n' > "$SOURCE/database.sql"
printf 'format=grimmory-transfer-v1\nsource_app_image=ghcr.io/grimmory/grimmory:1.0.0\nsource_app_image_id=sha256:test-image\ndb_name=grimmory\n' > "$SOURCE/manifest.txt"
for file in app-data.tar.gz books.tar.gz bookdrop.tar.gz; do
  tar -czf "$SOURCE/$file" -C "$MOCK_CONTENT" .
done
checksums() { (cd "$SOURCE" && sha256sum "${ARTIFACTS[@]}" > SHA256SUMS); }
checksums
printf 'private secret\n' > "$SOURCE/.env"
transfer() { bash "$TEST_ROOT/host/scripts/transfer.sh" "$@"; }
expect_failure() {
  if "$@" > "$TEST_ROOT/failure.log" 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
}
assert_no_writes() { [[ ! -s "$MOCK_WRITES" ]]; }
assert_configs_cleaned() {
  while IFS= read -r config; do [[ ! -e "$config" && ! -d "${config%/*}" ]]; done < "$MOCK_CONFIGS"
}

transfer preflight > /dev/null
[[ "$(cat "$MOCK_APP_STATE")" == true ]]
transfer upload "$SOURCE" grimmory-20261021T120000Z > /dev/null
REMOTE="$REMOTE_ROOT/grimmory-20261021T120000Z"
[[ ! -e "$REMOTE/.env" && ! -e "$REMOTE/UPLOAD-PENDING.txt" && -f "$REMOTE/SHA256SUMS" ]]
transfer download grimmory-20261021T120000Z "$TEST_ROOT/target backup" > /dev/null
for file in "${ARTIFACTS[@]}" SHA256SUMS; do cmp "$SOURCE/$file" "$TEST_ROOT/target backup/$file"; done
assert_configs_cleaned
printf 'PASS: preflight, round trip, private-file filtering and temporary credential cleanup\n'

transfer upload "$SOURCE" grimmory-20261021T120000Z > /dev/null
printf 'SELECT 2;\n' > "$SOURCE/database.sql"
checksums
expect_failure transfer upload "$SOURCE" grimmory-20261021T120000Z
printf 'SELECT 1;\n' > "$SOURCE/database.sql"
checksums
printf 'PASS: identical uploads can be retried; changed remote artifacts are rejected\n'

export MOCK_FAIL_FILE=books.tar.gz
expect_failure transfer upload "$SOURCE" grimmory-20261022T120000Z
[[ -f "$REMOTE_ROOT/grimmory-20261022T120000Z/UPLOAD-PENDING.txt" && ! -e "$REMOTE_ROOT/grimmory-20261022T120000Z/SHA256SUMS" ]]
unset MOCK_FAIL_FILE
expect_failure transfer download grimmory-20261022T120000Z
transfer download > /dev/null
[[ -f "$BACKUP_DIR/grimmory-20261021T120000Z/database.sql" ]]
transfer upload "$SOURCE" grimmory-20261022T120000Z > /dev/null
transfer download > /dev/null
[[ -f "$BACKUP_DIR/grimmory-20261022T120000Z/database.sql" ]]
printf 'PASS: pending uploads are blocked and latest selection chooses completed bundles\n'

export MOCK_CORRUPT_FILE=database.sql
expect_failure transfer download grimmory-20261021T120000Z "$TEST_ROOT/corrupt backup"
grep -q 'database.sql: FAILED' "$TEST_ROOT/failure.log"
unset MOCK_CORRUPT_FILE
transfer download grimmory-20261021T120000Z "$TEST_ROOT/corrupt backup" > /dev/null
printf 'PASS: downloaded corruption is detected and a retry repairs the backup\n'

printf 'broken backup\n' >> "$SOURCE/database.sql"
expect_failure transfer upload "$SOURCE" grimmory-corrupt
[[ ! -e "$REMOTE_ROOT/grimmory-corrupt" ]]
printf 'SELECT 1;\n' > "$SOURCE/database.sql"
sed '/database.sql$/d' "$SOURCE/SHA256SUMS" > "$TEST_ROOT/incomplete-sums"
cp "$TEST_ROOT/incomplete-sums" "$SOURCE/SHA256SUMS"
expect_failure transfer upload "$SOURCE" grimmory-missing-checksum
checksums
printf 'PASS: corrupt sources and incomplete checksum manifests cannot be uploaded\n'

expect_failure transfer download ../escape
sed 's#^NC_REMOTE_ROOT=.*#NC_REMOTE_ROOT=../escape#' "$TRANSFER_ENV_FILE" > "$TEST_ROOT/invalid.env"
expect_failure env TRANSFER_ENV_FILE="$TEST_ROOT/invalid.env" bash "$TEST_ROOT/host/scripts/transfer.sh" download grimmory-20261021T120000Z
sed 's#^NC_URL=.*#NC_URL=http://cloud.example.com#' "$TRANSFER_ENV_FILE" > "$TEST_ROOT/invalid.env"
expect_failure env TRANSFER_ENV_FILE="$TEST_ROOT/invalid.env" bash "$TEST_ROOT/host/scripts/transfer.sh" preflight
expect_failure env TRANSFER_ENV_FILE="$TEST_ROOT/nonexistent.env" bash "$TEST_ROOT/host/scripts/transfer.sh" preflight
expect_failure transfer invalid
assert_configs_cleaned
printf 'PASS: invalid migration paths, missing configuration and invalid commands fail safely\n'

# Export exercises source stop/restart and failures without contacting Docker.
export APP_CONTAINER=booklore MOCK_STREAM_MOUNTS=1
export MIGRATION_ID=grimmory-20261022T130000Z
bash "$TEST_ROOT/host/scripts/export.sh" > /dev/null
[[ "$(cat "$MOCK_APP_STATE")" == true && -f "$REMOTE_ROOT/$MIGRATION_ID/SHA256SUMS" ]]
grep -Fxq 'source_container=booklore' "$BACKUP_DIR/$MIGRATION_ID/manifest.txt"
grep -q '^source_app_repo_digest=ghcr.io/grimmory-tools/grimmory@sha256:' "$BACKUP_DIR/$MIGRATION_ID/manifest.txt"
grep -q 'docker image inspect.*sha256:test-image$' "$MOCK_LOG"
export MIGRATION_ID=grimmory-20261022T140000Z LEAVE_GRIMMORY_STOPPED=1
bash "$TEST_ROOT/host/scripts/export.sh" > /dev/null
[[ "$(cat "$MOCK_APP_STATE")" == false ]]
printf 'true\n' > "$MOCK_APP_STATE"
export MIGRATION_ID=grimmory-20261022T150000Z MOCK_FAIL_DUMP=1
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
[[ "$(cat "$MOCK_APP_STATE")" == true && -f "$REMOTE_ROOT/$MIGRATION_ID/UPLOAD-PENDING.txt" ]]
unset MOCK_FAIL_DUMP
export MIGRATION_ID=grimmory-20261022T160000Z MOCK_FAIL_FILE=books.tar.gz
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
[[ "$(cat "$MOCK_APP_STATE")" == true && ! -e "$REMOTE_ROOT/$MIGRATION_ID/SHA256SUMS" ]]
unset MOCK_FAIL_FILE LEAVE_GRIMMORY_STOPPED
export MIGRATION_ID=grimmory-20261022T170000Z MOCK_FAIL_COMMAND=mkdir
: > "$MOCK_LOG"
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
! grep -q 'docker stop' "$MOCK_LOG"
[[ "$(cat "$MOCK_APP_STATE")" == true ]]
unset MOCK_FAIL_COMMAND MIGRATION_ID
export MOCK_NO_SPACE=1
: > "$MOCK_LOG"
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
! grep -q 'docker stop' "$MOCK_LOG"
unset MOCK_NO_SPACE
unset APP_CONTAINER MOCK_STREAM_MOUNTS
assert_configs_cleaned
printf 'PASS: integrated export uploads, restarts by default, supports cutover and recovers from failures\n'

# Export failures before stopping the app must be visible and bounded.
export APP_CONTAINER=booklore DOCKER_TIMEOUT=1 MOCK_HANG_DOCKER=inspect
: > "$MOCK_LOG"
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
grep -q 'Checking Docker access to app container: booklore' "$TEST_ROOT/failure.log"
grep -q 'Docker inspect timed out after 1s' "$TEST_ROOT/failure.log"
! grep -q 'docker stop' "$MOCK_LOG"
[[ "$(cat "$MOCK_APP_STATE")" == true ]]
unset MOCK_HANG_DOCKER DOCKER_TIMEOUT
export SPACE_SCAN_TIMEOUT=1 MOCK_HANG_SCAN=1
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
grep -q 'Estimating /app/data size' "$TEST_ROOT/failure.log"
grep -q 'Size scan failed or timed out for /app/data' "$TEST_ROOT/failure.log"
[[ ! -e "$MOCK_LOG.helper-active" && "$(cat "$MOCK_APP_STATE")" == true ]]
! grep -q 'docker stop' "$MOCK_LOG"
unset MOCK_HANG_SCAN SPACE_SCAN_TIMEOUT
export MOCK_FAIL_SCAN=1
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
[[ ! -e "$MOCK_LOG.helper-active" ]]
unset MOCK_FAIL_SCAN
printf 'PASS: stalled Docker checks and mount scans fail visibly before stopping the source\n'

# A failed or interrupted archive must clean up its helper and restart the app,
# even in cutover mode. Cleanup failure must not skip the restart.
export LEAVE_GRIMMORY_STOPPED=1 MOCK_FAIL_ARCHIVE=1 MIGRATION_ID=grimmory-archive-failure
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
[[ ! -e "$MOCK_LOG.helper-active" && "$(cat "$MOCK_APP_STATE")" == true ]]
[[ ! -f "$REMOTE_ROOT/$MIGRATION_ID/SHA256SUMS" ]]
export MOCK_FAIL_HELPER_CLEANUP=1 MIGRATION_ID=grimmory-cleanup-failure
expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
[[ "$(cat "$MOCK_APP_STATE")" == true ]]
grep -q 'Could not remove backup helper' "$TEST_ROOT/failure.log"
rm -f -- "$MOCK_LOG.helper-active"
unset MOCK_FAIL_ARCHIVE MOCK_FAIL_HELPER_CLEANUP
for signal in INT TERM; do
  export MOCK_SIGNAL_EXPORT="$signal" MIGRATION_ID="grimmory-interrupted-$signal"
  expect_failure bash "$TEST_ROOT/host/scripts/export.sh"
  [[ ! -e "$MOCK_LOG.helper-active" && "$(cat "$MOCK_APP_STATE")" == true ]]
  [[ ! -f "$REMOTE_ROOT/$MIGRATION_ID/SHA256SUMS" ]]
  grep -q 'cleaning up' "$TEST_ROOT/failure.log"
done
unset MOCK_SIGNAL_EXPORT MIGRATION_ID LEAVE_GRIMMORY_STOPPED APP_CONTAINER
while IFS= read -r cidfile; do [[ ! -e "$cidfile" && ! -d "${cidfile%/*}" ]]; done < "$MOCK_LOG.cidfiles"
assert_configs_cleaned
printf 'PASS: archive errors and interrupts remove helpers and restore the source, including after cleanup failure\n'

# Import must block every failure before any destination restore operation.
printf 'false\n' > "$MOCK_APP_STATE"
export DB_CONTAINER=grimmory-db
expect_failure env -u CONFIRM_REPLACE bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
assert_no_writes
export CONFIRM_REPLACE=YES MOCK_IMAGE=ghcr.io/grimmory/grimmory:2.0.0 MOCK_IMAGE_ID=sha256:other-version
expect_failure bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
grep -q 'Image mismatch' "$TEST_ROOT/failure.log"
assert_no_writes
unset MOCK_IMAGE MOCK_IMAGE_ID
export MOCK_IMAGE_ID=sha256:different-image
expect_failure bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
assert_no_writes
unset MOCK_IMAGE_ID
expect_failure env DB_NAME=different-database bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
grep -q 'Database name mismatch' "$TEST_ROOT/failure.log"
assert_no_writes
export MOCK_TABLES=1
expect_failure bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
assert_no_writes
unset MOCK_TABLES
export MOCK_NONEMPTY_MOUNT=1
expect_failure bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE"
assert_no_writes
unset MOCK_NONEMPTY_MOUNT
export MOCK_CORRUPT_FILE=database.sql
expect_failure bash "$TEST_ROOT/host/scripts/import.sh"
assert_no_writes
unset MOCK_CORRUPT_FILE
bash "$TEST_ROOT/host/scripts/import.sh" > /dev/null
[[ "$(wc -l < "$MOCK_WRITES")" -eq 4 && "$(cat "$MOCK_APP_STATE")" == false ]]
assert_configs_cleaned
printf 'PASS: integrated import verifies images, checks empty targets and restores only verified data\n'
: > "$MOCK_LOG"
bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE" > /dev/null
! grep -q '^rclone ' "$MOCK_LOG"
printf 'PASS: importing an existing local bundle does not require Nextcloud\n'

# The source latest tag can be replaced by a digest pin without changing contents.
: > "$MOCK_WRITES"
export MOCK_IMAGE=ghcr.io/grimmory-tools/grimmory@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$TEST_ROOT/host/scripts/import.sh" "$SOURCE" > /dev/null
[[ "$(wc -l < "$MOCK_WRITES")" -eq 4 ]]
printf 'PASS: digest-pinned target accepts identical image contents across different references\n'

# Old manifests without an image ID must retain the stricter reference check.
LEGACY_SOURCE="$TEST_ROOT/legacy backup"
mkdir "$LEGACY_SOURCE"
for file in "${ARTIFACTS[@]}"; do cp "$SOURCE/$file" "$LEGACY_SOURCE/$file"; done
sed -i '/^source_app_image_id=/d' "$LEGACY_SOURCE/manifest.txt"
(cd "$LEGACY_SOURCE" && sha256sum "${ARTIFACTS[@]}" > SHA256SUMS)
: > "$MOCK_WRITES"
expect_failure bash "$TEST_ROOT/host/scripts/import.sh" "$LEGACY_SOURCE"
grep -q 'legacy bundle has no image ID' "$TEST_ROOT/failure.log"
assert_no_writes
unset MOCK_IMAGE
bash "$TEST_ROOT/host/scripts/import.sh" "$LEGACY_SOURCE" > /dev/null
[[ "$(wc -l < "$MOCK_WRITES")" -eq 4 ]]
printf 'PASS: legacy manifests require matching image references\n'
