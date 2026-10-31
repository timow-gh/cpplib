<#
.SYNOPSIS
Sets up the Windows Woodpecker agent for this repository in one run.

.DESCRIPTION
The counterpart of setup-linux-agent.sh; tools/woodpecker-agent/windows.md has the commands for
setting up, starting, updating and removing the agent. Safe to run again, e.g. to update the agent
to the version of the server.

Installs woodpecker-agent and plugin-git (checked against the release checksums) into the agent
directory, clones and bootstraps vcpkg if needed, stores the agent token encrypted for the current
user (DPAPI), and writes run-agent.ps1, which sets the environment the pipelines need and starts
the agent.

Run it as the user that will run the agent. Windows PowerShell 5.1 is enough; the script is ASCII
because 5.1 reads BOM-less scripts in the ANSI code page.

.PARAMETER AgentVersion
woodpecker-agent release; use the version of the Woodpecker server.

.PARAMETER Server
gRPC address of the server (WOODPECKER_SERVER), e.g. <host>:<grpc-port>. Required unless
run-agent.ps1 already exists.

.PARAMETER AgentDirectory
Where the agent, plugin-git, the caches and run-agent.ps1 live.

.PARAMETER VcpkgRoot
The vcpkg git checkout the presets use as toolchain. An existing checkout is used as it is (bootstrapped
only if vcpkg.exe is missing, never updated); a missing one is cloned. Pass the same value on every run.

.PARAMETER ScheduledTask
Registers a scheduled task that starts the agent at logon, with highest privileges: release
pipelines install the MSI per machine. Needs an elevated PowerShell.

.PARAMETER InstallTools
Installs the build tools with winget (and WiX v3 with Chocolatey). Without it, the windows-agent-check
pipeline reports what is missing.

.PARAMETER Force
Regenerates an existing run-agent.ps1.

.EXAMPLE
.\tools\woodpecker-agent\setup-windows-agent.ps1 -AgentVersion 3.19.0 -Server <host>:<grpc-port> -ScheduledTask
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AgentVersion,
    [string] $Server = '',
    [string] $AgentDirectory = (Join-Path $HOME 'woodpecker-agent'),
    [string] $VcpkgRoot = (Join-Path $HOME 'vcpkg'),
    [string] $PluginGitVersion = '2.11.0',
    [string] $Hostname = 'windows-native',
    [ValidateRange(1, 64)]
    [int] $MaxWorkflows = 1,
    [string] $ForgejoUrl = '',
    [switch] $ScheduledTask,
    [switch] $InstallTools,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 still negotiates TLS 1.0 by default, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'windows-agent-common.ps1')

function Invoke-Checked([string] $FilePath, [string[]] $ArgumentList) {
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath $($ArgumentList -join ' ') exited with $LASTEXITCODE"
    }
}

# winget exits with a non-zero code when a package is already installed, so its result is only
# reported; the windows-agent-check pipeline is the real check.
function Install-Tools {
    Write-Step 'Installing the build tools (winget, Chocolatey)'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is missing; install the App Installer from the Microsoft Store'
    }
    $packages = @(
        @('Git.Git'),
        @('Kitware.CMake'),
        @('orhun.git-cliff'),
        @('Microsoft.VisualStudio.2022.BuildTools', '--override', '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --wait')
    )
    foreach ($package in $packages) {
        & winget.exe install --exact --id $package[0] --accept-package-agreements --accept-source-agreements @($package | Select-Object -Skip 1)
        Write-Host "winget install $($package[0]) exited with $LASTEXITCODE"
    }
    # CPack's WIX generator needs WiX v3 (candle, light); winget offers WiX v4+ only.
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        & choco.exe install wixtoolset -y
        Write-Host "choco install wixtoolset exited with $LASTEXITCODE"
    }
    else {
        Write-Host '[warning] Chocolatey is missing, so WiX v3 was not installed: install it from https://github.com/wixtoolset/wix3/releases'
    }
}

# Checked before anything is installed: vcpkg resolves the builtin-baseline of vcpkg.json from the
# git history of the checkout, so a copy without .git (a zip download, the one bundled with Visual
# Studio) cannot work, and git clone refuses a non-empty directory.
function Test-VcpkgRoot {
    if ((Test-Path $VcpkgRoot -PathType Container) -and -not (Test-Path (Join-Path $VcpkgRoot '.git')) `
            -and (Get-ChildItem -Force $VcpkgRoot | Select-Object -First 1)) {
        throw "$VcpkgRoot exists but is not a git checkout of vcpkg. Clone it (git clone https://github.com/microsoft/vcpkg <dir>) and pass -VcpkgRoot <dir>, or move the existing folder away."
    }
}

function Install-Vcpkg {
    if (-not (Test-Path (Join-Path $VcpkgRoot '.git'))) {
        Write-Step "Cloning vcpkg into $VcpkgRoot"
        Invoke-Checked git.exe @('clone', 'https://github.com/microsoft/vcpkg', $VcpkgRoot)
    }
    if (-not (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
        Write-Step 'Bootstrapping vcpkg'
        Invoke-Checked (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') @('-disableMetrics')
    }
}

# Checks every download against the release's checksums.txt, so that a build for another
# platform or an HTML error page never ends up as the binary.
function Get-VerifiedDownload([string] $BaseUrl, [string] $Asset, [string] $TargetDirectory) {
    New-Item -ItemType Directory -Force $TargetDirectory | Out-Null
    $checksums = Join-Path $TargetDirectory 'checksums.txt'
    $file = Join-Path $TargetDirectory $Asset
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/checksums.txt" -OutFile $checksums
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Asset" -OutFile $file
    $line = Get-Content $checksums | Where-Object { ($_ -split '\s+')[1] -eq $Asset } | Select-Object -First 1
    if (-not $line) {
        throw "$Asset is not listed in $BaseUrl/checksums.txt"
    }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash
    if ($actual -ne $expected) {
        throw "checksum of $Asset from $BaseUrl does not match"
    }
    return $file
}

# A running exe cannot be overwritten, but it can be renamed; the old copy is removed on the
# next run.
function Install-Binary([string] $Source, [string] $Target) {
    $old = "$Target.old"
    if (Test-Path $old) {
        Remove-Item -Force $old -ErrorAction SilentlyContinue
    }
    if (Test-Path $Target) {
        Move-Item -Force $Target $old
    }
    Copy-Item $Source $Target
}

function Install-AgentBinaries([string] $WorkDirectory) {
    Write-Step "Installing woodpecker-agent $AgentVersion and plugin-git $PluginGitVersion"
    $agentZip = Get-VerifiedDownload "https://github.com/woodpecker-ci/woodpecker/releases/download/v$AgentVersion" `
        'woodpecker-agent_windows_amd64.zip' (Join-Path $WorkDirectory 'agent')
    $pluginGit = Get-VerifiedDownload "https://github.com/woodpecker-ci/plugin-git/releases/download/$PluginGitVersion" `
        'windows-amd64_plugin-git.exe' (Join-Path $WorkDirectory 'plugin-git')
    $unpacked = Join-Path $WorkDirectory 'agent\unpacked'
    Expand-Archive -Force $agentZip -DestinationPath $unpacked
    Install-Binary (Join-Path $unpacked 'woodpecker-agent.exe') (Join-Path $AgentDirectory 'woodpecker-agent.exe')
    # The agent looks for plugin-git on PATH under exactly this name.
    Install-Binary $pluginGit (Join-Path $AgentDirectory 'plugin-git.exe')
}

function Save-AgentSecret {
    $path = Join-Path $AgentDirectory $script:AgentSecretFile
    if (Test-Path $path) {
        Write-Step "Keeping the agent token in $path (manage-windows-agent.ps1 set-token replaces it)"
        return
    }
    Save-AgentToken $AgentDirectory
}

function ConvertTo-Literal([string] $Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Write-RunAgentScript {
    $path = Join-Path $AgentDirectory 'run-agent.ps1'
    if ((Test-Path $path) -and -not $Force) {
        Write-Step "Keeping $path (-Force regenerates it with what this version of the script writes)"
        return
    }
    if (-not $Server) {
        throw '-Server is required to write run-agent.ps1'
    }
    Write-Step "Writing $path"
    foreach ($cache in 'cpm', 'vcpkg') {
        New-Item -ItemType Directory -Force (Join-Path $AgentDirectory "cache\$cache") | Out-Null
    }
    $forgejo = if ($ForgejoUrl) {
        "# CI_FORGE_URL is not reachable from this machine.`n`$env:FORGEJO_URL = $(ConvertTo-Literal $ForgejoUrl)"
    }
    else {
        "# Only if CI_FORGE_URL is not reachable from this machine:`n# `$env:FORGEJO_URL = 'http://<host>:<port>'"
    }
    $gitBin = Join-Path $env:ProgramFiles 'Git\bin'
    $content = @"
# Generated by tools/woodpecker-agent/setup-windows-agent.ps1. Pipeline steps on the local backend
# inherit this environment, so restart the agent after changing it. See
# tools/woodpecker-agent/windows.md.
`$ErrorActionPreference = 'Stop'
`$agentDirectory = $(ConvertTo-Literal $AgentDirectory)

# Start from the PATH stored in the registry, not the one inherited from the process that started
# this script: tools installed since then (e.g. by winget) are only in the registry. The agent
# directory provides plugin-git.exe; Git for Windows' bin directory provides sh.exe for the commit
# message check.
`$env:PATH = "`$agentDirectory;$gitBin;" + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
`$env:VCPKG_ROOT = $(ConvertTo-Literal $VcpkgRoot)
# Caches in the agent directory, independent of the profile variables the local backend sets for
# the steps; every pipeline starts in a fresh workspace.
`$env:VCPKG_DEFAULT_BINARY_CACHE = Join-Path `$agentDirectory 'cache\vcpkg'
`$env:CPM_SOURCE_CACHE = Join-Path `$agentDirectory 'cache\cpm'
# Lets the CI scripts name this file in their fix hints.
`$env:WOODPECKER_AGENT_SCRIPT = `$PSCommandPath
$forgejo

`$credential = Import-Clixml (Join-Path `$agentDirectory '$($script:AgentSecretFile)')
`$env:WOODPECKER_AGENT_SECRET = `$credential.GetNetworkCredential().Password
`$env:WOODPECKER_AGENT_CONFIG_FILE = Join-Path `$agentDirectory '$($script:AgentConfigFile)'
# The task runs hidden, so the agent logs to a file (manage-windows-agent.ps1 log); the log of the
# previous run is kept once.
`$log = Join-Path `$agentDirectory '$($script:AgentLogFile)'
Move-Item -Force `$log "`$log.1" -ErrorAction SilentlyContinue
`$env:WOODPECKER_LOG_FILE = `$log
`$env:WOODPECKER_SERVER = $(ConvertTo-Literal $Server)
`$env:WOODPECKER_BACKEND = 'local'
`$env:WOODPECKER_HOSTNAME = $(ConvertTo-Literal $Hostname)
`$env:WOODPECKER_AGENT_LABELS = 'os=windows,env=native'
`$env:WOODPECKER_MAX_WORKFLOWS = '$MaxWorkflows'

& (Join-Path `$agentDirectory 'woodpecker-agent.exe')
exit `$LASTEXITCODE
"@
    # With a BOM, Windows PowerShell 5.1 reads non-ASCII paths in the file correctly.
    [IO.File]::WriteAllText($path, $content.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding $true))
}

# The pipelines run the repository's .ps1 scripts in the agent user's PowerShell.
function Set-ScriptExecutionPolicy {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -eq 'Undefined' -and (Get-ExecutionPolicy) -in @('Restricted', 'AllSigned')) {
        Write-Step 'Allowing local scripts for this user (RemoteSigned)'
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    }
}

function Register-AgentTask {
    if (-not (Test-Elevated)) {
        throw '-ScheduledTask needs an elevated PowerShell (Run as administrator), to register a task with highest privileges'
    }
    if (Get-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue) {
        Write-Step "Removing the scheduled task '$($script:LegacyAgentTaskName)', which '$($script:AgentTaskName)' replaces"
        Stop-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:LegacyAgentTaskName -Confirm:$false
    }
    Write-Step "Registering the scheduled task '$($script:AgentTaskName)'"
    $runAgent = Join-Path $AgentDirectory 'run-agent.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runAgent`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    # No time limit: the default of 72 hours would stop the agent.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:AgentTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
}

function Write-NextSteps {
    Write-Step 'Done. Next steps:'
    $runAgent = Join-Path $AgentDirectory 'run-agent.ps1'
    if ($ScheduledTask) {
        Write-Host '- Start the agent now, or restart it after a rerun of this script:'
        Write-Host '  .\tools\woodpecker-agent\manage-windows-agent.ps1 restart'
        Write-Host '  It starts at every logon. The same script stops it, shows its status and log, and removes it.'
    }
    else {
        Write-Host "- Start the agent: $runAgent"
        Write-Host '  Release pipelines need it elevated; -ScheduledTask starts it at logon with highest privileges.'
    }
    Write-Host '- Check the agent: run the windows-agent-check pipeline manually in Woodpecker; every line'
    Write-Host '  should read [prerequisite-ok].'
}

New-Item -ItemType Directory -Force $AgentDirectory | Out-Null
$AgentDirectory = (Resolve-Path $AgentDirectory).Path
# run-agent.ps1 starts in another directory, so a relative path would point somewhere else there.
$VcpkgRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VcpkgRoot)
Test-VcpkgRoot
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ("woodpecker-setup-" + [Guid]::NewGuid())
try {
    if ($InstallTools) {
        Install-Tools
    }
    Install-Vcpkg
    Install-AgentBinaries $workDirectory
    Save-AgentSecret
    Write-RunAgentScript
    Set-ScriptExecutionPolicy
    if ($ScheduledTask) {
        Register-AgentTask
    }
    Write-NextSteps
}
finally {
    Remove-Item -Recurse -Force $workDirectory -ErrorAction SilentlyContinue
}
