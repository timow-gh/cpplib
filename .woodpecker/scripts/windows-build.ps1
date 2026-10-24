# Configures, builds and tests one MSVC preset; the Woodpecker counterpart of
# .github/workflows/windows-build.yml.
param(
    [Parameter(Mandatory)]
    [ValidateSet('debug', 'release', 'release-standalone')]
    [string] $PresetSuffix
)

. "$PSScriptRoot\ci-common.ps1"

Invoke-Main {
    Assert-Prerequisites -Require git, cmake, vcpkg-root, msvc

    # vcpkg may download source archives while configuring. The download hosts occasionally
    # return transient errors, so retry the configure step with backoff.
    Invoke-WithRetry -Description 'configure' -Attempts 5 -BackoffSeconds 30 {
        Invoke-Native 'configure step' cmake @('--preset', "conf-msvc-$PresetSuffix")
    }
    Invoke-Native 'build step' cmake @('--build', '--preset', "build-msvc-$PresetSuffix")
    Invoke-Native 'test step' ctest @('--preset', "test-msvc-$PresetSuffix")
}
