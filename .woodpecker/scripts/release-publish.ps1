# Publishes the Windows packages as a Forgejo release; the counterpart of the create-release job
# of .github/workflows/release.yml.
#
# The release is created if it does not exist yet and reused otherwise, so a re-run, or a later
# Linux workflow uploading its own packages into the same release, works. Assets with the same
# name are replaced.

. "$PSScriptRoot\ci-common.ps1"

function New-ReleaseNotes([string] $NotesFile) {
    # git-cliff needs the history back to the previous v* tag.
    $shallow = Invoke-NativeCapture 'detect shallow clone' git @('rev-parse', '--is-shallow-repository')
    if ($shallow -eq 'true') {
        Invoke-Native 'fetch full history' git @('fetch', '--unshallow', '--tags', '--force', 'origin')
    }
    else {
        Invoke-Native 'fetch tags' git @('fetch', '--tags', '--force', 'origin')
    }
    # Without a remote integration the template's commit.remote fields (PR number, author) stay
    # empty; cliff.toml skips them in that case.
    Invoke-Native 'generate release notes' git-cliff @('-vv', '--latest', '--strip', 'header', '--output', $NotesFile)
}

function Get-OrCreateRelease([string] $Tag, [string] $Version, [string] $NotesFile) {
    $release = Invoke-ForgejoApi -Path "repos/$env:CI_REPO/releases/tags/$Tag" -AllowNotFound
    if ($release) {
        Write-Host "Reusing the existing release $($release.html_url)"
        return $release
    }
    $notes = [IO.File]::ReadAllText((Resolve-Path $NotesFile).Path, [Text.Encoding]::UTF8)
    $release = Invoke-ForgejoApi -Method Post -Path "repos/$env:CI_REPO/releases" -Body @{
        tag_name   = $Tag
        name       = "Release $Version"
        body       = $notes
        draft      = $false
        prerelease = $false
    }
    Write-Host "Created the release $($release.html_url)"
    return $release
}

function Publish-ReleaseAsset($Release, [string] $Path) {
    $name = Split-Path -Leaf $Path
    $existing = @($Release.assets) | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($existing) {
        Invoke-ForgejoApi -Method Delete -Path "repos/$env:CI_REPO/releases/$($Release.id)/assets/$($existing.id)" | Out-Null
        Write-Host "Replacing $name"
    }

    # curl.exe instead of Invoke-RestMethod: Windows PowerShell 5.1 has no multipart -Form.
    $uploadUrl = "$(Get-ForgejoApiUrl)/repos/$env:CI_REPO/releases/$($Release.id)/assets?name=$([Uri]::EscapeDataString($name))"
    $responseFile = [IO.Path]::GetTempFileName()
    # curl reports errors on stderr; let the status check below decide instead of 'Stop'.
    $ErrorActionPreference = 'Continue'
    try {
        $status = & curl.exe -sS -o $responseFile -w '%{http_code}' -X POST `
            -H "Authorization: token $env:FORGEJO_TOKEN" -F "attachment=@$Path" $uploadUrl
        if ($LASTEXITCODE -ne 0 -or $status -ne '201') {
            $response = Get-Content -Raw $responseFile
            throw "[forgejo-api-failed] uploading $name returned HTTP $status (curl exit code $LASTEXITCODE): $response"
        }
    }
    finally {
        Remove-Item -Force $responseFile
    }
    Write-Host "Uploaded $name"
}

Invoke-Main {
    Assert-Prerequisites -Require git, git-cliff, curl, forgejo-token, forgejo-api

    $tag = $env:CI_COMMIT_TAG
    if ($env:CI_PIPELINE_EVENT -ne 'tag' -or -not $tag) {
        throw 'Releases are only published for tag events'
    }
    $version = (Get-ProjectInfo).Version

    $notesFile = 'out\release\RELEASE_NOTES.md'
    New-ReleaseNotes $notesFile
    $release = Get-OrCreateRelease $tag $version $notesFile

    $assets = @(
        Get-ChildItem -File 'out\packages\package-msvc-release-shared', 'out\packages\package-msvc-release-standalone'
        Get-Item 'out\release\product-identity.txt'
    )
    foreach ($asset in $assets) {
        Publish-ReleaseAsset $release $asset.FullName
    }
}
