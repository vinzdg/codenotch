#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

info "Running project (platform: $(detect_platform))"
command -v cargo >/dev/null 2>&1 || die "cargo missing — see: just pending"
if [ "$(detect_platform)" != macos ]; then
    command -v pkg-config >/dev/null 2>&1 || die "pkg-config missing — run: just cure-plan"
    if ! pkg-config --exists ayatana-appindicator3-0.1 \
        && ! pkg-config --exists appindicator3-0.1; then
        die "AppIndicator runtime missing — run: just cure-plan, then just cure"
    fi
fi
cd "$TEMPLATE_ROOT"
exec cargo run --manifest-path windows/Cargo.toml -p codenotch --locked
