#!/usr/bin/env bash
# Build the thin AppImage (host webkit2gtk-4.1) the way the Linux Package workflow does.
# Run this on Ubuntu 22.04 or in the `codenotch-build` Distrobox — see README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

cargo build --release --locked -p codenotch-hook --target-dir target/hook
(
  cd "$ROOT/codenotch"
  npx --yes @tauri-apps/cli@2.11.4 build --config tauri.bundle.conf.json -- --locked
)
bash "$ROOT/pack-appimage-host-webkit.sh"

echo
echo "AppImage: $ROOT/target/release/bundle/appimage/Codenotch_1.13.1_amd64.AppImage"
echo "Run it on the host (not inside Distrobox): chmod +x, then double-click or"
echo "  ./target/release/bundle/appimage/Codenotch_1.13.1_amd64.AppImage"
