#!/bin/bash
# Add Codenotch's Team ID to the partition list of every Claude Code keychain
# item.
#
# Why this is needed at all: a keychain item carries two separate gates. The
# ACL says *which apps* may read it — that is the list "Always Allow" writes
# to. The partition list says which *code-signing partitions* may read it, and
# nothing in the GUI ever writes to that one. An app whose signing identity is
# outside the partition list is refused before the ACL is even consulted, so
# clicking Always Allow records an approval that is discarded on the next read.
# That is the prompt-every-60-seconds loop.
#
# Codenotch used to be ad-hoc signed, so its identity was a cdhash that changed
# on every build; now it is signed with a real Team ID and the identity is
# stable, but these items were written before that and only list "apple-tool:"
# (the /usr/bin/security CLI, which is how Claude Code writes them).
#
# Run once. The password is read silently and passed on stdin, never on argv,
# because argv is readable by any process via ps.
set -euo pipefail

TEAM_ID="$(codesign -dv /Applications/Codenotch.app 2>&1 | sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p')"
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "not" ]; then
  echo "Codenotch is not signed with a Team ID — rebuild with 'make install' first." >&2
  exit 1
fi

# apple-tool: and apple: are kept, not replaced: Claude Code and the token
# refresher both reach these items through /usr/bin/security, and dropping
# apple-tool: would lock *them* out to let Codenotch in.
PARTITIONS="apple-tool:,apple:,teamid:${TEAM_ID}"

# Claude Code's own naming rule: the bare service for ~/.claude, and a suffix
# of the first 8 hex of sha256(absolute path) for every other profile.
services() {
  echo "Claude Code-credentials"
  for dir in "$HOME"/.claude-*; do
    [ -d "$dir" ] || continue
    [ -e "$dir/.credentials.json" ] || [ -e "$dir/settings.json" ] || continue
    printf 'Claude Code-credentials-%s\n' \
      "$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
  done
}

printf 'Login keychain password: '
read -rs PASSWORD
printf '\n\n'

failed=0
while IFS= read -r service; do
  # Skip items that do not exist rather than reporting a failure for them.
  if ! /usr/bin/security find-generic-password -a "$USER" -s "$service" >/dev/null 2>&1; then
    echo "  skip  $service (no such item)"
    continue
  fi
  if printf '%s' "$PASSWORD" | /usr/bin/security set-generic-password-partition-list \
       -a "$USER" -s "$service" -S "$PARTITIONS" >/dev/null 2>&1; then
    echo "  ok    $service"
  else
    echo "  FAIL  $service"
    failed=1
  fi
done < <(services)

unset PASSWORD
echo
if [ "$failed" -eq 0 ]; then
  echo "Done. Partition list is now: $PARTITIONS"
  echo "Codenotch should stop asking for the password."
else
  echo "Some items could not be updated — check the password and re-run." >&2
  exit 1
fi
