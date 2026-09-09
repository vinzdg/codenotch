#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

info "Supported platforms (order: Arch, Debian, macOS, Windows):"
printf '%-9s %-30s %-9s %s\n' "ID" "DETECT" "MANAGER" "ADAPTER"
while IFS=$'\t' read -r id detect mgr install adapter; do
    printf '%-9s %-30s %-9s %s\n' "$id" "$detect" "$mgr" "$adapter"
done < <(tsv_rows "$MANIFESTS_DIR/platforms.tsv")
