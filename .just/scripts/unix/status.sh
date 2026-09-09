#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

info "Project:  $(basename "$TEMPLATE_ROOT")"
info "Platform: $(detect_platform)"
if command -v git >/dev/null 2>&1 && git -C "$TEMPLATE_ROOT" rev-parse >/dev/null 2>&1; then
    info "Git branch: $(git -C "$TEMPLATE_ROOT" branch --show-current 2>/dev/null || echo '(detached)')"
    changes="$(git -C "$TEMPLATE_ROOT" status --short 2>/dev/null || true)"
    if [ -n "$changes" ]; then
        info "Working tree:"
        printf '%s\n' "$changes"
    else
        ok "Working tree clean"
    fi
else
    warn "Not a git repository"
fi
if [ -f "$TEMPLATE_ROOT/.env" ]; then ok ".env present"; else warn ".env missing — run: just config init"; fi
