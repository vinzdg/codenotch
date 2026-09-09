# health.ps1 — Windows placeholder (Unix-first template).
#
# The authoritative implementation lives in .just/scripts/unix/health.sh.
# Fill this in and wire a Windows CI runner to make it real. Keep the behaviour
# and output shape aligned with the Unix version.

param([switch]$All, [switch]$DryRun)

Write-Host "[windows stub] 'health' is not implemented yet."
Write-Host "See .just/scripts/unix/health.sh for the reference behaviour."
exit 0
