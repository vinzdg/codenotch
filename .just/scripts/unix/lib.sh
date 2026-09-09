#!/usr/bin/env bash
# lib.sh — shared helpers for the template's Unix scripts. Source it; don't run it.

# Resolve the template root from this file's location (.just/scripts/unix/lib.sh).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"
MANIFESTS_DIR="$TEMPLATE_ROOT/.just/manifests"
ADAPTERS_DIR="$TEMPLATE_ROOT/.just/adapters"
SCRIPTS_DIR="$TEMPLATE_ROOT/.just/scripts"

# --- Logging ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_DIM=
fi
info() { printf '%s\n' "${C_BLU}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GRN}ok ${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YLW} ! ${C_RESET} $*" >&2; }
err()  { printf '%s\n' "${C_RED}xx ${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# --- Platform detection ----------------------------------------------------
detect_platform() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) echo macos ;;
        Linux)
            if [ -f /etc/arch-release ] || command -v pacman >/dev/null 2>&1; then
                echo arch
            elif [ -f /etc/debian_version ] || command -v apt-get >/dev/null 2>&1; then
                echo debian
            else
                echo linux
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        *) echo unknown ;;
    esac
}

# Source the adapter for the given (or current) platform.
# Defines pkg_mgr / pkg_check / pkg_install / pkg_install_cmd.
load_adapter() {
    local plat="${1:-$(detect_platform)}"
    local file="$ADAPTERS_DIR/$plat.sh"
    [ -f "$file" ] || return 1
    # shellcheck source=/dev/null
    . "$file"
}

# Emit the data rows of a TSV, skipping the header and comment/blank lines.
tsv_rows() {
    local file="$1"
    [ -f "$file" ] || return 0
    tail -n +2 "$file" | grep -vE '^[[:space:]]*(#|$)' || true
}
