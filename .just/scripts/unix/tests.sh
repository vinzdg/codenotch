#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

action="${1:-all}"
case "$action" in
    all)
        command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
        cd "$TEMPLATE_ROOT"
        info "Testing macOS signing command generation without invoking Xcode…"
        bash Scripts/test-signing.sh
        info "Running Rust workspace tests…"
        cargo test --manifest-path windows/Cargo.toml --workspace --all-targets --locked
        ok "Rust workspace tests passed."
        ;;
    *)
        die "Unknown tests action: $action (use all)"
        ;;
esac
