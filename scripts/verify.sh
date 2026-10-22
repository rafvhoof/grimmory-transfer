#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
[[ $# -eq 1 ]] || die 'Usage: scripts/verify.sh /path/to/backup-directory'
require sha256sum
DIR="$(cd "$1" && pwd)"
sha_check "$DIR"
for file in app-data.tar.gz books.tar.gz bookdrop.tar.gz; do
  tar -tzf "$DIR/$file" >/dev/null || die "Corrupt archive: $file"
done
echo 'Backup integrity checks passed.'
