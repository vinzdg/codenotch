#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

rc=0
info "CI: check"
bash "$SCRIPTS_DIR/unix/check.sh" || rc=1
info "CI: tests"
bash "$SCRIPTS_DIR/unix/tests.sh" all || rc=1
command -v cargo >/dev/null 2>&1 || die "cargo missing — run: just cure-plan"
cd "$TEMPLATE_ROOT"
info "CI: release build"
cargo build --manifest-path windows/Cargo.toml --workspace --release --locked || rc=1

if [ "$rc" -eq 0 ]; then ok "ci passed"; else err "ci failed"; fi
exit "$rc"
