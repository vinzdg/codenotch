#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

DRY=no
[ "${1:-}" = "--dry-run" ] && DRY=yes

plat="$(detect_platform)"
load_adapter "$plat" || die "No adapter for platform '$plat' (see .just/adapters/)."

# Map platform id -> package column in tools.tsv (0-based array index).
col_index() {
    case "$1" in
        arch) echo 1 ;; debian) echo 2 ;; macos) echo 3 ;; windows) echo 4 ;;
        *) echo -1 ;;
    esac
}
idx="$(col_index "$plat")"
[ "$idx" -ge 0 ] || die "Platform '$plat' has no package column in tools.tsv."

plan=()
while IFS=$'\t' read -r -a f; do
    cmd="${f[0]}"; req="${f[5]}"; plats="${f[6]}"
    case ",$plats," in *",$plat,"*) : ;; *) continue ;; esac
    [ "$req" = required ] || continue
    present=no
    IFS='|' read -ra alts <<< "$cmd"
    for a in "${alts[@]}"; do
        command -v "$a" >/dev/null 2>&1 && { present=yes; break; }
    done
    [ "$present" = yes ] && continue
    pkg="${f[$idx]}"
    [ "$pkg" = "-" ] && pkg="${alts[0]}"
    plan+=("$pkg")
done < <(tsv_rows "$MANIFESTS_DIR/tools.tsv")

if [ -f "$MANIFESTS_DIR/runtime-packages.tsv" ]; then
    while IFS=$'\t' read -r -a f; do
        req="${f[5]}"; plats="${f[6]}"
        case ",$plats," in *",$plat,"*) : ;; *) continue ;; esac
        [ "$req" = required ] || continue
        candidates="${f[$idx]}"
        [ "$candidates" != "-" ] || continue
        installed=no
        IFS='|' read -ra packages <<< "$candidates"
        for package in "${packages[@]}"; do
            pkg_check "$package" && { installed=yes; break; }
        done
        [ "$installed" = yes ] && continue
        plan+=("${packages[0]}")
    done < <(tsv_rows "$MANIFESTS_DIR/runtime-packages.tsv")
fi

declare -A package_seen=()
unique_plan=()
for package in "${plan[@]}"; do
    [ -n "${package_seen[$package]:-}" ] && continue
    package_seen[$package]=1
    unique_plan+=("$package")
done
plan=("${unique_plan[@]}")

if [ "${#plan[@]}" -eq 0 ]; then
    ok "Nothing to install — all required tools are present."
    exit 0
fi

info "Package manager: $(pkg_mgr)"
info "Packages: ${plan[*]}"
info "Command:  $(pkg_install_cmd "${plan[@]}")"
if [ "$DRY" = yes ]; then
    info "Dry-run — no changes made. Run 'just cure' to install."
    exit 0
fi
pkg_install "${plan[@]}"
ok "cure complete."
