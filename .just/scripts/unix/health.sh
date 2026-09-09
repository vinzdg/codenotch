#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ALL=no
[ "${1:-}" = "--all" ] && ALL=yes

plat="$(detect_platform)"
if [ "$ALL" = yes ]; then
    info "Health check — all tools, every platform"
else
    info "Health check — platform: $plat"
fi

missing_required=0
while IFS=$'\t' read -r cmd carch cdeb cmac cwin req plats desc; do
    if [ "$ALL" != yes ]; then
        case ",$plats," in *",$plat,"*) : ;; *) continue ;; esac
    fi
    present=no
    IFS='|' read -ra alts <<< "$cmd"
    for a in "${alts[@]}"; do
        command -v "$a" >/dev/null 2>&1 && { present=yes; break; }
    done
    if [ "$present" = yes ]; then
        ok "$cmd — $req ($plats)"
    elif [ "$req" = required ]; then
        err "$cmd — required, MISSING ($plats)"
        [ "$ALL" = yes ] || missing_required=$((missing_required + 1))
    else
        warn "$cmd — optional, missing ($plats)"
    fi
done < <(tsv_rows "$MANIFESTS_DIR/tools.tsv")

if [ "$ALL" != yes ] && [ -f "$MANIFESTS_DIR/runtime-packages.tsv" ]; then
    if load_adapter "$plat"; then
        case "$plat" in
            arch) package_column=1 ;;
            debian) package_column=2 ;;
            macos) package_column=3 ;;
            windows) package_column=4 ;;
            *) package_column=-1 ;;
        esac
        while IFS=$'\t' read -r -a fields; do
            id="${fields[0]}"
            required="${fields[5]}"
            platforms="${fields[6]}"
            case ",$platforms," in *",$plat,"*) : ;; *) continue ;; esac
            [ "$package_column" -ge 0 ] || continue
            candidates="${fields[$package_column]}"
            [ "$candidates" != "-" ] || continue
            installed=no
            IFS='|' read -ra packages <<< "$candidates"
            for package in "${packages[@]}"; do
                pkg_check "$package" && { installed=yes; break; }
            done
            if [ "$installed" = yes ]; then
                ok "$id runtime — $required ($plat)"
            elif [ "$required" = required ]; then
                err "$id runtime — required, MISSING ($plat: $candidates)"
                missing_required=$((missing_required + 1))
            else
                warn "$id runtime — optional, missing ($plat: $candidates)"
            fi
        done < <(tsv_rows "$MANIFESTS_DIR/runtime-packages.tsv")
    fi
fi

if [ "$missing_required" -gt 0 ]; then
    warn "$missing_required required tool(s) missing — run: just cure-plan"
    exit 1
fi
ok "All required tools present."
