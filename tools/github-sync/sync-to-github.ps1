$ErrorActionPreference = "Stop"

# Git for Windows ships sh but does not put it on the PATH of PowerShell. All logic stays in the
# shell script, so that the two entry points cannot differ.
$gitExecPath = & git --exec-path
if ($LASTEXITCODE -ne 0) {
    throw "git --exec-path failed with exit code $LASTEXITCODE"
}

$shell = Join-Path $gitExecPath "..\..\..\bin\sh.exe"
if (-not (Test-Path $shell)) {
    throw "sh.exe not found at $shell; run tools/github-sync/sync-to-github.sh from a shell that has sh"
}

& $shell (Join-Path $PSScriptRoot "sync-to-github.sh") @args
exit $LASTEXITCODE
