# Checks that a release may be built: tag, CMakeLists.txt and vcpkg.json versions agree, and the
# product identity matches the last Forgejo release. Mirrors the validate_version job of
# .github/workflows/release.yml; keep the messages and rules of both in sync.

. "$PSScriptRoot\ci-common.ps1"

function Assert-ReleaseVersion($Project) {
    $manifestVersion = (Get-Content -Raw 'vcpkg.json' | ConvertFrom-Json).version
    if ($manifestVersion -ne $Project.Version) {
        throw "vcpkg.json version $manifestVersion does not match CMake version $($Project.Version)"
    }

    if ($env:CI_PIPELINE_EVENT -eq 'tag') {
        $tag = $env:CI_COMMIT_TAG
        if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
            throw "Release tags must use vMAJOR.MINOR.PATCH, got '$tag'"
        }
        $tagVersion = $tag.Substring(1)
        if ($tagVersion -ne $Project.Version) {
            throw "Tag version $tagVersion does not match CMake version $($Project.Version)"
        }
    }
    Write-Host "Release version $($Project.Version) of $($Project.Name)"
}

# Everything that tells installed copies of the product apart from other products: the project
# name (package names) and the MSI upgrade code. Each release publishes it; a release in which it
# changed is refused, because its packages could not upgrade the installations of the earlier
# releases.
function Assert-ProductIdentity($Project, [string] $IdentityFile) {
    $identity = "name=$($Project.Name)`nwix_upgrade_guid=$(Get-WixUpgradeGuid)`n"
    Write-Utf8File $IdentityFile $identity
    Write-Host $identity

    $lastRelease = Invoke-ForgejoApi -Path "repos/$env:CI_REPO/releases/latest" -AllowNotFound
    if (-not $lastRelease) {
        Write-Host 'No earlier release: this release records the product identity.'
        return
    }
    $lastTag = $lastRelease.tag_name
    $asset = @($lastRelease.assets) | Where-Object { $_.name -eq 'product-identity.txt' } | Select-Object -First 1
    if (-not $asset) {
        Write-Host "[notice] Release $lastTag has no product-identity.txt; this release records the product identity."
        return
    }
    # browser_download_url carries Forgejo's public ROOT_URL, which this agent may not reach;
    # build the same /attachments/<uuid> link on the URL the agent uses.
    $downloadUrl = "$(Get-ForgejoBaseUrl)/attachments/$($asset.uuid)"
    $download = Invoke-WebRequest -Uri $downloadUrl -Headers (Get-ForgejoHeaders) -UseBasicParsing -TimeoutSec 30
    $lastIdentity = [Text.Encoding]::UTF8.GetString($download.RawContentStream.ToArray()).Replace("`r`n", "`n")
    if ($lastIdentity -eq $identity) {
        Write-Host "Product identity unchanged since $lastTag."
        return
    }

    Write-Host "Product identity of $lastTag :"
    Write-Host $lastIdentity
    if ($env:ALLOW_PRODUCT_IDENTITY_CHANGE -eq 'true') {
        Write-Host "[warning] The product identity changed since $lastTag (allowed by the secret allow_product_identity_change)."
        return
    }
    throw "The product identity changed since $lastTag (compare the two blocks above). The packages of this release would not upgrade existing installations: restore the project name and PRODUCT_WIX_UPGRADE_GUID in cmake/product_identity.cmake. If this really is meant to become a new product, set the Woodpecker secret allow_product_identity_change=true for this release."
}

Invoke-Main {
    Assert-Prerequisites -Require git, forgejo-api -Warn forgejo-token

    $project = Get-ProjectInfo
    Assert-ReleaseVersion $project
    Assert-ProductIdentity $project 'out\release\product-identity.txt'
}
