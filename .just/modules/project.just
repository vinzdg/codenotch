# project.just — core lifecycle recipes, imported at the template root.
#
# Recipes are tagged with [group(...)] so `just --list` shows clear blocks.
# OS-sensitive recipes use [unix] / [windows] (never the deprecated
# windows-shell). WHAT lives here; HOW lives in the scripts + OS adapters.

_unix := justfile_directory() / ".just" / "scripts" / "unix"
_win  := justfile_directory() / ".just" / "scripts" / "windows"

# ═══════════════════════════════ Lifecycle ═════════════════════════════════

# Run the project entry point.
[group('lifecycle')]
[unix]
run:
    @bash '{{_unix}}/run.sh'
[group('lifecycle')]
[windows]
run:
    @pwsh -NoProfile -File '{{_win}}/run.ps1'

# Install dependencies and prepare the project.
[group('lifecycle')]
[unix]
setup:
    @bash '{{_unix}}/setup.sh'
[group('lifecycle')]
[windows]
setup:
    @pwsh -NoProfile -File '{{_win}}/setup.ps1'

# Static checks: config + health.
[group('lifecycle')]
[unix]
check:
    @bash '{{_unix}}/check.sh'
[group('lifecycle')]
[windows]
check:
    @pwsh -NoProfile -File '{{_win}}/check.ps1'

# Full local pipeline: check + tests.
[group('lifecycle')]
[unix]
ci:
    @bash '{{_unix}}/ci.sh'
[group('lifecycle')]
[windows]
ci:
    @pwsh -NoProfile -File '{{_win}}/ci.ps1'

# Show project and platform status.
[group('lifecycle')]
status:
    @bash '{{_unix}}/status.sh'

# ═══════════════════════════════ Platform ══════════════════════════════════

# Detect the current platform.
[group('platform')]
[unix]
platform:
    @bash '{{_unix}}/detect-platform.sh'
[group('platform')]
[windows]
platform:
    @pwsh -NoProfile -File '{{_win}}/detect-platform.ps1'

# List every supported platform.
[group('platform')]
platforms:
    @bash '{{_unix}}/platforms.sh'

# ══════════════════════════════ Diagnostics ════════════════════════════════

# Check the required tools for this platform.
[group('diagnostics')]
[unix]
health:
    @bash '{{_unix}}/health.sh'
[group('diagnostics')]
[windows]
health:
    @pwsh -NoProfile -File '{{_win}}/health.ps1'

# Check tools across all platforms.
[group('diagnostics')]
[unix]
health-all:
    @bash '{{_unix}}/health.sh' --all
[group('diagnostics')]
[windows]
health-all:
    @pwsh -NoProfile -File '{{_win}}/health.ps1' -All

# Show what `cure` would install (dry-run).
[group('diagnostics')]
[unix]
cure-plan:
    @bash '{{_unix}}/cure.sh' --dry-run
[group('diagnostics')]
[windows]
cure-plan:
    @pwsh -NoProfile -File '{{_win}}/cure.ps1' -DryRun

# Install missing required tools (asks for confirmation).
[group('diagnostics')]
[confirm("Install missing required tools now?")]
[unix]
cure:
    @bash '{{_unix}}/cure.sh'
[group('diagnostics')]
[confirm("Install missing required tools now?")]
[windows]
cure:
    @pwsh -NoProfile -File '{{_win}}/cure.ps1'

# Full environment diagnostics.
[group('diagnostics')]
[unix]
doctor:
    @bash '{{_unix}}/doctor.sh'
[group('diagnostics')]
[windows]
doctor:
    @pwsh -NoProfile -File '{{_win}}/doctor.ps1'

# Show detected-but-unavailable commands parked in the background (pending.tsv).
[group('diagnostics')]
pending:
    @bash '{{_unix}}/pending.sh'

# Show the project/template version.
[group('diagnostics')]
version:
    @bash '{{_unix}}/version.sh'
