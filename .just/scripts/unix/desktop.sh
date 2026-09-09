#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
cd "$TEMPLATE_ROOT"

action="${1:-}"
case "$action" in
    build)
        info "Building the Rust/Tauri workspace in release mode…"
        cargo build --manifest-path windows/Cargo.toml --workspace --release --locked
        ok "Desktop release build completed."
        ;;
    run)
        exec bash "$SCRIPTS_DIR/unix/run.sh"
        ;;
    doctor)
        info "Running Codenotch diagnostics…"
        cargo run --manifest-path windows/Cargo.toml -p codenotch --locked -- doctor
        ok "Codenotch diagnostics completed."
        ;;
    *)
        die "Unknown desktop action: $action (use build|run|doctor)"
        ;;
esac
