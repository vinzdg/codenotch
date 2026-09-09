#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

rc=0
info "Config check"
bash "$SCRIPTS_DIR/unix/config.sh" check || rc=1
info "Health check"
bash "$SCRIPTS_DIR/unix/health.sh" || rc=1
command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
cd "$TEMPLATE_ROOT"
info "Checking shell syntax"
while IFS= read -r script; do
    bash -n "$script" || rc=1
done < <(find Scripts .just/scripts/unix -type f -name '*.sh' -print)
info "Running Rust Clippy"
cargo clippy --manifest-path windows/Cargo.toml --workspace --all-targets --locked || rc=1

if [ "$rc" -eq 0 ]; then ok "check passed"; else err "check failed"; fi
exit "$rc"
