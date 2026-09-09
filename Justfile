# ══════════════════════════════════════════════════════════════════════════
#  Project Justfile — generated from the JustfileConfigurator template
#
#  Five-layer architecture:
#    Justfile → modules (WHAT) → scripts → OS adapters (HOW) → manifests (data)
#
#  Run `just` for the grouped recipe list, or `just --groups`.
# ══════════════════════════════════════════════════════════════════════════

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set dotenv-load := true
set dotenv-required := false

# ── Entry point ────────────────────────────────────────────────────────────

# Show every recipe, grouped.
default:
    @just --list

# ── Core recipes (imported) ────────────────────────────────────────────────
# Flat lifecycle / platform / diagnostics recipes, grouped for `just --list`.
import '.just/modules/project.just'

# ── Modules ─────────────────────────────────────────────────────────────────
# Namespaced: `just desktop build` or `just desktop::build`.

mod config  '.just/modules/config.just'
mod tests   '.just/modules/tests.just'

# ── Optional modules ────────────────────────────────────────────────────────
# Loaded with `mod?`; delete a file or its line freely.

mod? desktop '.just/modules/desktop.just'
mod? arch    '.just/modules/arch.just'
