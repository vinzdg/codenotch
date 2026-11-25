#!/bin/bash
#
# Build the code in this checkout as a Release app and put it in /Applications.
#
# Why this exists: `make install` already is that job end to end — generate the
# project, build Release, re-sign, quit the running copy, replace it, launch it
# — but it assumes it is run from the repository root, and the failure that
# matters on a machine without a signing certificate is silent at build time: a
# plain Release build is ad-hoc signed *with* the hardened runtime, dyld refuses
# the Sparkle framework beside it, and the app dies at launch. The checks below
# are the point of the wrapper, not the build.
#
# Usage:
#   Scripts/install-app.sh
#
# The copy installed here is ad-hoc signed whenever no Developer ID or Apple
# Development certificate is in the keychain, which is every contributor's
# machine. macOS ties a login-keychain "Always Allow" grant to that exact
# signature, so the prompt to read another tool's credential comes back once
# after each install — Scripts/sign-local.sh is the stable-identity answer to
# that. Unlike `make release` this does not notarize, so the copy is for this
# machine; if the bundle travels elsewhere, Gatekeeper wants a one-time
# right-click -> Open.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/Codenotch.app"
NAME="Codenotch"

cd "$REPO"

if [ ! -f Makefile ]; then
  echo "error: no Makefile in $REPO — run this from a Codenotch checkout." >&2
  exit 1
fi

# `make install` shells out to all three: xcodegen for `gen`, xcodebuild for
# the Release build, make for the target itself. Missing any one of them fails
# halfway through a build rather than before it.
for tool in make xcodegen xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH — see CONTRIBUTING.md for the setup." >&2
    exit 1
  fi
done

echo "Building Release from $REPO …"
make install

INFO="$APP/Contents/Info.plist"
if [ ! -f "$INFO" ]; then
  echo "error: $APP has no Contents/Info.plist — the copy is incomplete." >&2
  exit 1
fi

# Read the version back from what actually landed instead of from project.yml,
# so a stale copy cannot be reported as the build just made.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")

# Read the signature once, into a variable. Piping it into `grep -q` is what
# this used to do, and under `set -o pipefail` the `grep` exits on its first
# match, `codesign` takes SIGPIPE (141), and the pipeline counts as failed —
# so an ad-hoc build took the Developer ID branch and reported an empty
# authority. The same trap waits in `| head -1` below, which is why the
# first line is taken inside `sed` instead.
SIGNING=$(codesign -dv "$APP" 2>&1 || true)

if [[ "$SIGNING" == *"Signature=adhoc"* ]]; then
  SIGNATURE="ad-hoc (no certificate in the keychain)"
else
  SIGNATURE=$(sed -n '/^Authority=/{s/^Authority=//;p;q;}' <<<"$SIGNING")
fi

# `make install` launched the app, so a dyld rejection has already happened by
# now — it just looks like nothing opening. Waiting for the process is the one
# check that separates "installed" from "installed and able to start", which is
# exactly the difference an ad-hoc build gets wrong.
if ! pgrep -x "$NAME" >/dev/null 2>&1; then
  for _ in $(seq 1 30); do
    sleep 0.5
    pgrep -x "$NAME" >/dev/null 2>&1 && break
  done
fi

echo
echo "Installed $APP — version $VERSION ($BUILD), signed $SIGNATURE."

if ! pgrep -x "$NAME" >/dev/null 2>&1; then
  echo
  echo "warning: $NAME is not running after the install. Run the binary directly" >&2
  echo "         to see why:" >&2
  echo "           $APP/Contents/MacOS/$NAME" >&2
  exit 1
fi
