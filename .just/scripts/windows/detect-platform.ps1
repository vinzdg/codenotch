# detect-platform.ps1 — Windows placeholder (Unix-first template).
#
# The authoritative implementation lives in .just/scripts/unix/detect-platform.sh.
# Fill this in and wire a Windows CI runner to make it real. Keep the behaviour
# and output shape aligned with the Unix version.

param([switch]$All, [switch]$DryRun)

Write-Host "[windows stub] 'detect-platform' is not implemented yet."
Write-Host "See .just/scripts/unix/detect-platform.sh for the reference behaviour."
exit 0
