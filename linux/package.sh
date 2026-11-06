#!/usr/bin/env bash
# Build the Linux Mint / Ubuntu .deb the way the Linux Package workflow does.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/desktop"

# Own target dir: the bundler copies resources next to the app, so a hook built
# in target/release would be copied onto itself.
cargo build --release --locked -p codenotch-hook --target-dir target/hook

cd codenotch
npx --yes @tauri-apps/cli@2.11.4 build --bundles deb --config tauri.linux.bundle.conf.json -- --locked

shopt -s nullglob
debs=(../target/release/bundle/deb/*.deb)
if [[ ${#debs[@]} -ne 1 ]]; then
  echo "expected one .deb, found ${#debs[@]}" >&2
  exit 1
fi

mkdir -p "$root/linux/dist"
cp -f "${debs[0]}" "$root/linux/dist/Codenotch.deb"
echo "$root/linux/dist/Codenotch.deb"
