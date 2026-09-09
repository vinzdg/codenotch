#!/usr/bin/env bash
# Arch Linux adapter — package manager: pacman.
# Defines the HOW for this OS. Modules/scripts only call these functions.

pkg_mgr() { echo pacman; }

# Return 0 if the package is installed.
pkg_check() { pacman -Qi "$1" >/dev/null 2>&1; }

# Print the install command for the given packages (used by cure --dry-run).
pkg_install_cmd() { echo "sudo pacman -S --needed --noconfirm $*"; }

# Install the given packages.
pkg_install() { sudo pacman -S --needed --noconfirm "$@"; }
