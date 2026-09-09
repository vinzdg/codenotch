#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

info "Setting up project…"
bash "$SCRIPTS_DIR/unix/config.sh" init || true
info "Checking tools…"
bash "$SCRIPTS_DIR/unix/health.sh" || warn "Some tools are missing — run: just cure-plan"
command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
cd "$TEMPLATE_ROOT"
info "Fetching locked Rust workspace dependencies…"
cargo fetch --manifest-path windows/Cargo.toml --locked
ok "Setup complete."
