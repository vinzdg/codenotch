#!/usr/bin/env bash
# System libraries the Linux Tauri build needs (Mint / Ubuntu).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sudo apt-get update
# One list for local installs and both Linux workflows.
xargs -a "$here/apt-packages.txt" sudo apt-get install -y
