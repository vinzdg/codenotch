#!/usr/bin/env bash
# Show the "background" list: commands detected during scaffolding but not
# currently available (missing tool, ambiguous mapping). They are parked in
# .just/manifests/pending.tsv instead of being wired as broken recipes.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

P="$MANIFESTS_DIR/pending.tsv"
rows="$(tsv_rows "$P")"

if [ -z "$rows" ]; then
    ok "No pending commands — everything detected is wired up."
    exit 0
fi

info "Pending commands (detected but not available here):"
printf '%-16s %-30s %s\n' "COMMAND" "REASON" "COMMAND LINE"
while IFS=$'\t' read -r cmd reason line; do
    [ -n "$cmd" ] || continue
    printf '%-16s %-30s %s\n' "$cmd" "$reason" "$line"
done <<< "$rows"
echo
info "Wire one up by installing its tool (just cure-plan) or editing .just/scripts/unix/."
