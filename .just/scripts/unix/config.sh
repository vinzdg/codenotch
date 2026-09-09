#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV_FILE="$TEMPLATE_ROOT/.env"
EXAMPLE="$TEMPLATE_ROOT/.env.example"
REQUIRED="$MANIFESTS_DIR/env.required"

env_keys()      { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed -E 's/[[:space:]]*=.*//; s/[[:space:]]//g' | sort -u; }
required_vars() { grep -vE '^[[:space:]]*(#|$)' "$REQUIRED"      | sed -E 's/[[:space:]]//g'                        | sort -u; }

action="${1:-check}"
case "$action" in
    init)
        if [ -f "$ENV_FILE" ]; then
            warn ".env already exists — not overwriting."
            exit 0
        fi
        cp "$EXAMPLE" "$ENV_FILE"
        ok "Created .env from .env.example — edit it to taste."
        ;;
    check)
        [ -f "$ENV_FILE" ] || die ".env not found. Run: just config init"
        missing=0
        while read -r v; do
            [ -n "$v" ] || continue
            if grep -qE "^[[:space:]]*$v=" "$ENV_FILE"; then
                val="$(grep -E "^[[:space:]]*$v=" "$ENV_FILE" | head -1 | sed -E 's/^[^=]*=//')"
                if [ -n "$val" ]; then ok "$v is set"; else warn "$v is present but empty"; fi
            else
                err "$v is missing"
                missing=$((missing + 1))
            fi
        done < <(required_vars)
        [ "$missing" -eq 0 ] || die "$missing required variable(s) missing in .env"
        ok "All required variables present."
        ;;
    diff)
        [ -f "$ENV_FILE" ] || die ".env not found. Run: just config init"
        info "In .env.example but not .env:"
        comm -23 <(env_keys "$EXAMPLE") <(env_keys "$ENV_FILE") | sed 's/^/  + /' || true
        info "In .env but not .env.example:"
        comm -13 <(env_keys "$EXAMPLE") <(env_keys "$ENV_FILE") | sed 's/^/  - /' || true
        ;;
    *)
        die "Unknown config action: $action (use init|check|diff)"
        ;;
esac
