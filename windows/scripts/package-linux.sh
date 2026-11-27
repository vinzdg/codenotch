#!/bin/sh
# Build Linux .deb, .rpm and AppImage the way linux-package.yml does.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

cargo build --release --locked -p codenotch-hook --target-dir target/hook

cd codenotch
npx --yes @tauri-apps/cli@2.11.4 build \
  --config tauri.linux.conf.json \
  --config tauri.linux.bundle.conf.json \
  -- --locked
