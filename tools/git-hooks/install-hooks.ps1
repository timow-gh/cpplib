$ErrorActionPreference = "Stop"

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) {
        throw "git $args failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Invoke-Git rev-parse --show-toplevel
Set-Location $repoRoot

Invoke-Git config core.hooksPath .githooks

Write-Host "Configured Git hooks from .githooks"
