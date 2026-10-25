# Publishes the draft release of the tag once both release workflows have uploaded their
# packages; the last part of the create-release job of .github/workflows/release.yml.
#
# release-finalize.yaml depends on release.yaml (Windows) and release-linux.yaml, and Woodpecker
# skips it if either fails. A release with a missing or broken package therefore stays an
# unpublished draft, as GitHub never creates it.

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

# A re-run of one release workflow, or a package that is no longer built, would otherwise publish
# an incomplete release.
function Assert-ReleaseAssets($Release, [string] $PackageName) {
    $name = [regex]::Escape($PackageName)
    $expected = [ordered]@{
        'Windows MSI (shared)'     = "^$name-[0-9].*\.msi$"
        'Windows MSI (standalone)' = "^$name-standalone-[0-9].*\.msi$"
        'Windows ZIP (shared)'     = "^$name-[0-9].*\.zip$"
        'Windows ZIP (standalone)' = "^$name-standalone-[0-9].*\.zip$"
        'Linux TGZ (shared)'       = "^$name-[0-9].*\.tar\.gz$"
        'Linux TGZ (standalone)'   = "^$name-standalone-[0-9].*\.tar\.gz$"
        'DEB app (shared)'         = "^$name-app_.*\.deb$"
        'DEB runtime library'      = "^lib$name[0-9]+_.*\.deb$"
        'DEB SDK'                  = "^lib$name-dev_.*\.deb$"
        'DEB app (standalone)'     = "^$name-app-standalone_.*\.deb$"
        'product identity'         = '^product-identity\.txt$'
    }
    $names = @(@($Release.assets) | ForEach-Object { $_.name })
    $missing = @(foreach ($entry in $expected.GetEnumerator()) {
            if (-not ($names -match $entry.Value)) {
                "$($entry.Key) ($($entry.Value))"
            }
        })
    Write-Host "Assets of the release: $($names -join ', ')"
    if ($missing.Count -gt 0) {
        throw "The release is missing assets: $($missing -join '; '). Re-run the release workflow that should have uploaded them; the release stays a draft."
    }
}

Invoke-Main {
    Assert-Prerequisites -Require git, git-cliff, forgejo-token, forgejo-api

    $tag = $env:CI_COMMIT_TAG
    if ($env:CI_PIPELINE_EVENT -ne 'tag' -or -not $tag) {
        throw 'Releases are only published for tag events'
    }
    $project = Get-ProjectInfo

    $release = Find-Release $tag
    if (-not $release) {
        throw "No release for $tag exists; the publish steps of release.yaml and release-linux.yaml create it"
    }
    Assert-ReleaseAssets $release $project.Name.ToLowerInvariant()

    $notesFile = 'out\release\RELEASE_NOTES.md'
    New-ReleaseNotes $notesFile
    $notes = [IO.File]::ReadAllText((Resolve-Path $notesFile).Path, [Text.Encoding]::UTF8)

    $published = Invoke-ForgejoApi -Method Patch -Path "repos/$env:CI_REPO/releases/$($release.id)" -Body @{
        name  = "Release $($project.Version)"
        body  = $notes
        draft = $false
    }
    Write-Host "Published the release $($published.html_url)"
}
