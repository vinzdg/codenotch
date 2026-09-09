#!/usr/bin/env bash
# Debian / Ubuntu adapter — package manager: apt-get.

pkg_mgr() { echo apt-get; }

pkg_check() { dpkg -s "$1" >/dev/null 2>&1; }

pkg_install_cmd() { echo "sudo apt-get install -y $*"; }

pkg_install() { sudo apt-get update && sudo apt-get install -y "$@"; }
