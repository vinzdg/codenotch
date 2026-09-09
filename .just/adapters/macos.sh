#!/usr/bin/env bash
# macOS adapter — package manager: Homebrew.

pkg_mgr() { echo brew; }

pkg_check() { brew list --formula "$1" >/dev/null 2>&1 || brew list --cask "$1" >/dev/null 2>&1; }

pkg_install_cmd() { echo "brew install $*"; }

pkg_install() { brew install "$@"; }
