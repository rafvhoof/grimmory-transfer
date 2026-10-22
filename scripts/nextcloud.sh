#!/usr/bin/env bash
# Shared Nextcloud transport. Source common.sh first; callers own their EXIT trap.

validate_migration_id() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'Migration ID must start with a letter or digit and contain only letters, digits, dots, underscores or hyphens'
}
urlencode_user() {
  local LC_ALL=C character i
  for ((i=0; i<${#1}; i++)); do
    character="${1:i:1}"
    case "$character" in
      [a-zA-Z0-9.~_-]) printf '%s' "$character" ;;
      *) printf '%%%02X' "'$character" ;;
    esac
  done
}
install_rclone_if_requested() {
  command -v rclone >/dev/null 2>&1 && return
  [[ "${AUTO_INSTALL_RCLONE:-1}" == 1 ]] || die 'rclone is missing; install it or set AUTO_INSTALL_RCLONE=1'
  require apt-get
  if (( EUID == 0 )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y rclone
  else
    require sudo
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y rclone
  fi
}
nextcloud_init() {
  local value obscured
  [[ -n "${NC_URL:-}" && -n "${NC_USER:-}" && -n "${NC_APP_PASSWORD:-}" ]] || die 'Set NC_URL, NC_USER and NC_APP_PASSWORD in /etc/grimmory-transfer.env (or TRANSFER_ENV_FILE)'
  [[ "$NC_URL" == https://* && "$NC_URL" != *'/remote.php/'* ]] || die 'NC_URL must be the HTTPS Nextcloud base URL, without /remote.php/dav/...'
  for value in "$NC_URL" "$NC_USER" "$NC_APP_PASSWORD"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'Nextcloud settings must be single-line values'
  done
  NC_REMOTE_ROOT="${NC_REMOTE_ROOT:-GrimmoryMigration}"
  NC_REMOTE_ROOT="${NC_REMOTE_ROOT%/}"
  [[ -n "$NC_REMOTE_ROOT" && "$NC_REMOTE_ROOT" != /* && "$NC_REMOTE_ROOT" != *:* && \
     "/$NC_REMOTE_ROOT/" != *'/../'* && "/$NC_REMOTE_ROOT/" != *'/./'* ]] || die 'NC_REMOTE_ROOT must be a relative folder path without . or .. components'
  NC_CONNECT_TIMEOUT="${NC_CONNECT_TIMEOUT:-10}"
  NC_IO_TIMEOUT="${NC_IO_TIMEOUT:-30}"
  RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-4}"
  RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
  for value in "$NC_CONNECT_TIMEOUT" "$NC_IO_TIMEOUT" "$RCLONE_TRANSFERS" "$RCLONE_CHECKERS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die 'Nextcloud timeouts and rclone concurrency must be positive integers'
  done
  install_rclone_if_requested
  RCLONE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grimmory-rclone.XXXXXX")"
  RCLONE_CONFIG_FILE="$RCLONE_STATE_DIR/rclone.conf"
  obscured="$(printf '%s\n' "$NC_APP_PASSWORD" | rclone obscure -)"
  cat > "$RCLONE_CONFIG_FILE" <<CONFIG
[nc]
type = webdav
url = ${NC_URL%/}/remote.php/dav/files/$(urlencode_user "$NC_USER")/
vendor = nextcloud
user = $NC_USER
pass = $obscured
CONFIG
  chmod 600 "$RCLONE_CONFIG_FILE"
}
nextcloud_cleanup() {
  if [[ -n "${RCLONE_STATE_DIR:-}" ]]; then
    rm -f -- "$RCLONE_STATE_DIR/"{rclone.conf,probe.txt,readback.txt,UPLOAD-PENDING.txt}
    rmdir -- "$RCLONE_STATE_DIR" || true
  fi
}
nextcloud() {
  rclone --config "$RCLONE_CONFIG_FILE" --contimeout "${NC_CONNECT_TIMEOUT}s" --timeout "${NC_IO_TIMEOUT}s" "$@"
}
nextcloud_preflight() {
  local probe_remote="$NC_REMOTE_ROOT/.grimmory-transfer-preflight-${RCLONE_STATE_DIR##*.}"
  require timeout
  printf 'Testing Nextcloud authentication and upload/download access before stopping Grimmory...\n'
  printf 'grimmory-transfer preflight\n' > "$RCLONE_STATE_DIR/probe.txt"
  local -a probe=(timeout "$((NC_IO_TIMEOUT + NC_CONNECT_TIMEOUT + 5))" rclone --config "$RCLONE_CONFIG_FILE"
    --contimeout "${NC_CONNECT_TIMEOUT}s" --timeout "${NC_IO_TIMEOUT}s" --retries 1 --low-level-retries 1)
  "${probe[@]}" mkdir "nc:$NC_REMOTE_ROOT/" || die 'Cannot access the Nextcloud migration root; check DNS, TLS, URL and app password'
  "${probe[@]}" copyto "$RCLONE_STATE_DIR/probe.txt" "nc:$probe_remote/probe.txt" || die 'Nextcloud probe upload failed; check permissions and quota'
  "${probe[@]}" copyto "nc:$probe_remote/probe.txt" "$RCLONE_STATE_DIR/readback.txt" || die 'Nextcloud probe download failed'
  cmp -s "$RCLONE_STATE_DIR/probe.txt" "$RCLONE_STATE_DIR/readback.txt" || die 'Nextcloud probe contents do not match'
  "${probe[@]}" deletefile "nc:$probe_remote/probe.txt"
  "${probe[@]}" rmdir "nc:$probe_remote"
  echo 'Nextcloud WebDAV preflight succeeded.'
}
remote_files() { nextcloud lsf "nc:$NC_REMOTE_ROOT/$1/" --files-only --max-depth 1; }
create_remote_pending_marker() {
  local listing
  validate_migration_id "$1"
  nextcloud mkdir "nc:$NC_REMOTE_ROOT/$1/"
  listing="$(remote_files "$1")"
  # Retrying a completed upload must not hide or change the existing backup.
  if ! grep -Fxq SHA256SUMS <<< "$listing"; then
    printf 'Grimmory migration %s is being prepared or uploaded. Do not import yet.\n' "$1" > "$RCLONE_STATE_DIR/UPLOAD-PENDING.txt"
    nextcloud copyto "$RCLONE_STATE_DIR/UPLOAD-PENDING.txt" "nc:$NC_REMOTE_ROOT/$1/UPLOAD-PENDING.txt"
  fi
}
resolve_migration_id() {
  local directories candidate listing
  if [[ -n "${MIGRATION_ID:-}" ]]; then
    validate_migration_id "$MIGRATION_ID"
    printf '%s' "$MIGRATION_ID"
    return
  fi
  directories="$(nextcloud lsf "nc:$NC_REMOTE_ROOT/" --dirs-only)" || die 'Cannot list Nextcloud migration bundles'
  while IFS= read -r candidate; do
    [[ "$candidate" =~ ^grimmory-[0-9]{8}T[0-9]{6}Z/$ ]] || continue
    candidate="${candidate%/}"
    listing="$(remote_files "$candidate")" || die "Cannot inspect migration $candidate"
    if grep -Fxq SHA256SUMS <<< "$listing" && ! grep -Fxq UPLOAD-PENDING.txt <<< "$listing"; then
      printf '%s' "$candidate"
      return
    fi
  done < <(printf '%s\n' "$directories" | LC_ALL=C sort -r)
  die "No completed timestamped migration bundles found in $NC_REMOTE_ROOT; set MIGRATION_ID for a custom name"
}
copy_artifacts() {
  local file
  local -a filters=()
  for file in "${ARTIFACTS[@]}"; do filters+=(--include "/$file"); done
  nextcloud copy "$1" "$2" "${filters[@]}" --checksum --transfers "$RCLONE_TRANSFERS" \
    --checkers "$RCLONE_CHECKERS" --progress --stats 10s --stats-one-line "${@:3}"
}
upload_bundle() {
  local directory="$1" migration_id="$2" listing file
  validate_migration_id "$migration_id"
  verify_bundle "$directory"
  create_remote_pending_marker "$migration_id"
  copy_artifacts "$directory/" "nc:$NC_REMOTE_ROOT/$migration_id/" --immutable
  # Publish checksums only after the parallel copy completes successfully.
  nextcloud copyto "$directory/SHA256SUMS" "nc:$NC_REMOTE_ROOT/$migration_id/SHA256SUMS" --checksum --immutable
  listing="$(remote_files "$migration_id")"
  for file in "${ARTIFACTS[@]}" SHA256SUMS; do
    grep -Fxq "$file" <<< "$listing" || die "Remote verification failed: missing $file"
  done
  [[ "$(printf '%s\n' "$listing" | grep -Fvx UPLOAD-PENDING.txt | wc -l)" -eq 6 ]] || die 'Remote verification failed: unexpected file count'
  if grep -Fxq UPLOAD-PENDING.txt <<< "$listing"; then
    nextcloud deletefile "nc:$NC_REMOTE_ROOT/$migration_id/UPLOAD-PENDING.txt"
  fi
  echo "Upload completed: $NC_REMOTE_ROOT/$migration_id"
}
download_bundle() {
  local migration_id="$1" directory="$2" listing file
  validate_migration_id "$migration_id"
  listing="$(remote_files "$migration_id")"
  grep -Fxq SHA256SUMS <<< "$listing" || die 'Remote bundle has no SHA256SUMS; finish the upload first'
  ! grep -Fxq UPLOAD-PENDING.txt <<< "$listing" || die 'Remote bundle is still marked UPLOAD-PENDING; finish the upload first'
  [[ ! -L "$directory" ]] || die "Destination must not be a symlink: $directory"
  mkdir -p -m 700 -- "$directory"
  for file in "${ARTIFACTS[@]}" SHA256SUMS; do
    [[ ! -L "$directory/$file" ]] || die "Destination artifact must not be a symlink: $file"
  done
  nextcloud copyto "nc:$NC_REMOTE_ROOT/$migration_id/SHA256SUMS" "$directory/SHA256SUMS" --ignore-times
  copy_artifacts "nc:$NC_REMOTE_ROOT/$migration_id/" "$directory/"
  verify_bundle "$directory"
  echo "Download completed and verified: $directory"
}
