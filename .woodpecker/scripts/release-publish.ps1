# Uploads the Windows packages into the draft Forgejo release of the tag; the Windows half of the
# create-release job of .github/workflows/release.yml.
#
# The release is created as a draft if it does not exist yet and reused otherwise, so a re-run
# works and release-upload.sh (Linux) can upload into the same release. Assets with the same name
# are replaced. release-finalize.ps1 writes the release notes and publishes the draft.

. "$PSScriptRoot\ci-common.ps1"

Invoke-Main {
    Assert-Prerequisites -Require git, curl, forgejo-token, forgejo-api

    $tag = $env:CI_COMMIT_TAG
    if ($env:CI_PIPELINE_EVENT -ne 'tag' -or -not $tag) {
        throw 'Releases are only published for tag events'
    }
    $version = (Get-ProjectInfo).Version

    $release = Get-OrCreateDraftRelease $tag $version

    $assets = @(
        Get-ChildItem -File 'out\packages\package-msvc-release-shared', 'out\packages\package-msvc-release-standalone'
        Get-Item 'out\release\product-identity.txt'
    )
    foreach ($asset in $assets) {
        Publish-ReleaseAsset $release $asset.FullName
    }
}
