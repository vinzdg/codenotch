#!/bin/sh
# Smoke-test packaged Linux builds (doctor). Run from windows/ after package-linux.sh.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

deb=$(find target/release/bundle/deb -name '*.deb' 2>/dev/null | head -1)
appimage=$(find target/release/bundle/appimage -name '*.AppImage' 2>/dev/null | head -1)

if [ -n "$deb" ]; then
  echo "=== smoke: $deb ==="
  sudo dpkg -i "$deb" || sudo apt-get install -f -y
  codenotch doctor || /usr/bin/codenotch doctor
fi

if [ -n "$appimage" ]; then
  echo "=== smoke: $appimage ==="
  chmod +x "$appimage"
  env GDK_BACKEND=x11 "$appimage" doctor
fi

if [ -z "$deb" ] && [ -z "$appimage" ]; then
  echo "No .deb or AppImage under target/release/bundle — run scripts/package-linux.sh first." >&2
  exit 1
fi
