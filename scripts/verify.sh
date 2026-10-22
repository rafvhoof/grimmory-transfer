#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
[[ $# -eq 1 ]] || die 'Usage: scripts/verify.sh /path/to/backup-directory'
DIR="$(cd "$1" && pwd)"
verify_bundle "$DIR"
echo 'Backup integrity checks passed.'
