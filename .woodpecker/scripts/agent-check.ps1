# Checks everything the Woodpecker workflows of this repository need from the Windows agent, in
# one run. Run it after setting up or changing the agent; the individual workflows check only
# what they use.

. "$PSScriptRoot\ci-common.ps1"

Invoke-Main {
    Write-Host "Agent: $env:CI_MACHINE on $env:COMPUTERNAME, PowerShell $($PSVersionTable.PSVersion)"
    # forgejo-token is a Woodpecker secret of the repository, not part of the agent, so the
    # workflows that need it check it themselves. Elevation is only needed for release
    # verification and is reported as a warning.
    Assert-Prerequisites -Require git, cmake, vcpkg-root, msvc, sh, wix, git-cliff, curl, forgejo-api -Warn elevated
}
