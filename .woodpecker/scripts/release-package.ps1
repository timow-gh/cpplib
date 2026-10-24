# Builds, tests and packages one Windows delivery mode (ZIP + MSI); the Windows half of the
# build-packages job of .github/workflows/release.yml.
#
# Signing follows the agent environment: cmake/windows_signing.cmake reads WINDOWS_SIGNTOOL_ARGS
# and WINDOWS_SIGNING_REQUIRED, so without them the packages stay unsigned, as on GitHub.
param(
    [Parameter(Mandatory)]
    [ValidateSet('shared', 'standalone')]
    [string] $DeliveryMode
)

. "$PSScriptRoot\ci-common.ps1"

Invoke-Main {
    Assert-Prerequisites -Require git, cmake, vcpkg-root, msvc, wix

    Invoke-Native 'package workflow' cmake @('--workflow', '--preset', "workflow-package-msvc-$DeliveryMode")

    $packageDirectory = "out\packages\package-msvc-release-$DeliveryMode"
    Write-Host "Packages in ${packageDirectory}:"
    Get-ChildItem -File $packageDirectory | ForEach-Object { Write-Host "  $($_.Name) ($($_.Length) bytes)" }
}
