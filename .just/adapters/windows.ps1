# Windows adapter — package manager: winget. DOCUMENTED PLACEHOLDER.
#
# Unix-first template: the Arch/Debian/macOS adapters are complete; this one is
# a stub to be filled in and exercised by a Windows CI runner. Keep the function
# names identical to the Unix adapters so modules stay OS-agnostic.

function Get-PkgMgr { 'winget' }

# Return $true if the package id is installed.
function Test-Pkg {
    param([string]$Id)
    # TODO: winget list --id $Id -e  (parse exit code)
    Write-Host "[windows stub] Test-Pkg $Id"
    return $false
}

# Print the install command (used by cure -DryRun).
function Get-PkgInstallCmd {
    param([string[]]$Ids)
    return "winget install -e --id $($Ids -join ' ')"
}

# Install the given package ids.
function Install-Pkg {
    param([string[]]$Ids)
    # TODO: foreach ($id in $Ids) { winget install -e --id $id }
    Write-Host "[windows stub] Install-Pkg $($Ids -join ', ')"
}
