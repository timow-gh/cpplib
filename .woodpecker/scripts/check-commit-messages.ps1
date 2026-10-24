# Validates the pull request title and all commits of a pull request against Conventional
# Commits; the Woodpecker counterpart of .github/workflows/commit-messages.yml. The rules live in
# tools/git-hooks/check-conventional-commit.sh, shared with the local commit-msg hook.

. "$PSScriptRoot\ci-common.ps1"

Invoke-Main {
    Assert-Prerequisites -Require git, sh

    $target = $env:CI_COMMIT_TARGET_BRANCH
    if (-not $target) {
        throw 'CI_COMMIT_TARGET_BRANCH is not set; this script only runs for pull request events'
    }

    # The clone may be shallow and contains only the pull request head, but the commit range
    # starts at the merge base with the target branch.
    $shallow = Invoke-NativeCapture 'detect shallow clone' git @('rev-parse', '--is-shallow-repository')
    if ($shallow -eq 'true') {
        Invoke-Native 'fetch full history' git @('fetch', '--unshallow', '--no-tags', 'origin')
    }
    Invoke-Native 'fetch target branch' git @('fetch', '--no-tags', 'origin', "+refs/heads/${target}:refs/remotes/origin/$target")
    $base = Invoke-NativeCapture 'find merge base' git @('merge-base', "origin/$target", 'HEAD')

    # For pull request events Woodpecker puts the pull request title into the commit message.
    # The title goes through a file because Windows PowerShell 5.1 mangles embedded quotes in
    # native command arguments.
    $title = ($env:CI_COMMIT_MESSAGE -split "`r?`n")[0]
    Write-Host "Pull request title (from CI_COMMIT_MESSAGE): $title"
    $titleFile = Join-Path 'out\ci' 'pull-request-title.txt'
    Write-Utf8File $titleFile "$title`n"
    Invoke-Native 'validate pull request title' sh @('tools/git-hooks/check-conventional-commit.sh', '--message-file', $titleFile.Replace('\', '/'))

    Invoke-Native 'validate commit messages' sh @('tools/git-hooks/check-conventional-commit.sh', '--range', "$base..HEAD")
}
