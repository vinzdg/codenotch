#!/usr/bin/env bash
# Tauri's linuxdeploy AppImage bundles Ubuntu 22.04's WebKitWebProcess. On Fedora/Bazzite that
# helper aborts with EGL_BAD_PARAMETER, so Settings and the notch stay blank. This keeps the
# cargo binary (no RUNPATH) and the hook, and lets the host provide webkit2gtk-4.1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$ROOT/target/release/bundle/appimage/Codenotch.AppDir"
BIN="$ROOT/target/release/codenotch"
OUT="$ROOT/target/release/bundle/appimage/Codenotch_1.13.1_amd64.AppImage"
PLUGIN="${TAURI_LINUXDEPLOY_APPIMAGE:-$HOME/.cache/tauri/linuxdeploy-plugin-appimage.AppImage}"

if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN" >&2
  exit 1
fi
if [[ ! -d "$APPDIR" ]]; then
  echo "missing $APPDIR — run tauri build first" >&2
  exit 1
fi

cp -f "$BIN" "$APPDIR/usr/bin/codenotch"
chmod +x "$APPDIR/usr/bin/codenotch"

# Drop every bundled .so (Ubuntu GTK/WebKit/GLib). Keep the hook sidecar.
if [[ -d "$APPDIR/usr/lib" ]]; then
  find "$APPDIR/usr/lib" -mindepth 1 -maxdepth 1 ! -name Codenotch -exec rm -rf {} +
fi
rm -rf "$APPDIR/apprun-hooks"

cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export APPDIR="$HERE"
exec "$HERE/usr/bin/codenotch" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if [[ ! -x "$PLUGIN" ]]; then
  echo "missing linuxdeploy-plugin-appimage at $PLUGIN" >&2
  exit 1
fi

rm -f "$OUT" "$HOME/Codenotch-x86_64.AppImage" "$ROOT/target/release/bundle/appimage/Codenotch-x86_64.AppImage"
cd "$ROOT/target/release/bundle/appimage"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$PLUGIN" --appdir "$APPDIR"
# linuxdeploy-plugin-appimage writes Codenotch-x86_64.AppImage in the process cwd, which
# may be $HOME rather than this directory.
shopt -s nullglob
produced=(
  "$PWD/Codenotch-x86_64.AppImage"
  "$HOME/Codenotch-x86_64.AppImage"
  "$PWD"/Codenotch*.AppImage
)
src=""
for f in "${produced[@]}"; do
  if [[ -f "$f" ]]; then src="$f"; break; fi
done
if [[ -z "$src" ]]; then
  echo "appimage plugin produced no image" >&2
  ls -la "$PWD" "$HOME"/Codenotch*.AppImage 2>/dev/null || true
  exit 1
fi
cp -f "$src" "$OUT"
chmod +x "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
