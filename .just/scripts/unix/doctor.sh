#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

plat="$(detect_platform)"
info "Platform:      $plat"
if load_adapter "$plat"; then
    info "Adapter:       $plat.sh (manager: $(pkg_mgr))"
else
    warn "Adapter:       none for '$plat'"
fi
info "Template root: $TEMPLATE_ROOT"
echo
info "Environment (.env):"
bash "$SCRIPTS_DIR/unix/config.sh" check || true
echo
info "Tools:"
bash "$SCRIPTS_DIR/unix/health.sh" || true
