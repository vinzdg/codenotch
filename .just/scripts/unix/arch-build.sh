#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

platform="$(detect_platform)"
[ "$platform" = "arch" ] || die "Arch build recipes require Arch Linux (detected: $platform)"
command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
cd "$TEMPLATE_ROOT"

profile="${1:-}"
case "$profile" in
    debug)
        info "Building Codenotch for Arch Linux (debug)…"
        cargo build --manifest-path windows/Cargo.toml --workspace --locked
        ok "Arch debug binaries: windows/target/debug/codenotch and codenotch-hook"
        ;;
    release)
        info "Building Codenotch for Arch Linux (release)…"
        cargo build --manifest-path windows/Cargo.toml --workspace --release --locked
        ok "Arch release binaries: windows/target/release/codenotch and codenotch-hook"
        ;;
    *)
        die "Unknown Arch build profile: $profile (use debug|release)"
        ;;
esac
