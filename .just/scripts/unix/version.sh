#!/usr/bin/env bash
# version.sh — print versions from the project's authoritative manifests.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

macos_version="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$TEMPLATE_ROOT/project.yml")"
desktop_version="$(awk -F'"' '/^version = / { print $2; exit }' "$TEMPLATE_ROOT/windows/codenotch/Cargo.toml")"
printf 'Codenotch macOS:      %s\n' "${macos_version:-unknown}"
printf 'Codenotch Rust/Tauri: %s\n' "${desktop_version:-unknown}"
