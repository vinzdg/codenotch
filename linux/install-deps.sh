#!/usr/bin/env bash
# System libraries the Linux Tauri build needs (Mint / Ubuntu).
set -euo pipefail
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  curl \
  pkg-config \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libx11-dev \
  libssl-dev \
  patchelf
