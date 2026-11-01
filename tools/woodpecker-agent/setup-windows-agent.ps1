<#
.SYNOPSIS
Sets up the Windows Woodpecker agent for this repository in one run.

.DESCRIPTION
The counterpart of setup-linux-agent.sh; tools/woodpecker-agent/windows.md has the commands for
setting up, starting, updating and removing the agent. Safe to run again, e.g. to update the agent
to the version of the server.

Installs woodpecker-agent and plugin-git (checked against the release checksums) into the agent
directory, clones and bootstraps vcpkg if needed, stores the agent token encrypted for the current
user (DPAPI), and writes run-agent.ps1, which sets the environment the pipelines need, starts the
agent, restarts it whenever it exits and keeps its log below a size limit.

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

.PARAMETER Priority
CPU and I/O priority of the agent and every build it starts: Normal, BelowNormal (other programs,
e.g. games, come first) or Idle (only otherwise unused CPU time). Written into run-agent.ps1, so
changing it needs -Force.

.PARAMETER ScheduledTask
Registers a scheduled task that starts the agent with highest privileges: release pipelines
install the MSI per machine. Needs an elevated PowerShell.

.PARAMETER StartAt
With -ScheduledTask: Startup (default) starts the agent at boot, whether anyone logs on or not;
the task stores your Windows password for that. Logon starts it when you log on, without a
password.

.PARAMETER Credential
With -StartAt Startup: your Windows account and password (with a Microsoft account its password,
not the PIN). Asked for if not given.

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
    [ValidateSet('Normal', 'BelowNormal', 'Idle')]
    [string] $Priority = 'Normal',
    [string] $ForgejoUrl = '',
    [switch] $ScheduledTask,
    [ValidateSet('Startup', 'Logon')]
    [string] $StartAt = 'Startup',
    [PSCredential] $Credential,
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

# Checked and asked before anything is installed, so that the rest runs without the user.
function Get-TaskCredential {
    if (-not $ScheduledTask) {
        return $null
    }
    if (-not (Test-Elevated)) {
        throw '-ScheduledTask needs an elevated PowerShell (Run as administrator), to register a task with highest privileges'
    }
    if ($StartAt -ne 'Startup') {
        return $null
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $credential = if ($Credential) { $Credential } else {
        Get-Credential -UserName $user -Message 'Your Windows password, stored by Windows with the scheduled task, so that it can start the agent at boot'
    }
    if (-not $credential) {
        throw 'no password given; -StartAt Logon starts the agent at logon without one'
    }
    # The token is encrypted for this user, so the task has to run as this user.
    if ($credential.UserName -notin @($user, $env:USERNAME, ".\$env:USERNAME")) {
        throw "the task has to run as $user, who can decrypt the agent token, not as $($credential.UserName)"
    }
    return $credential
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
        @('Ccache.Ccache'),
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

# A running exe cannot be overwritten or deleted, but it can be renamed. Old copies are deleted on
# the next run; one that is still running (an agent started by hand) moves aside under a unique name.
function Install-Binary([string] $Source, [string] $Target) {
    Get-ChildItem "$Target.old*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path $Target) {
        $old = "$Target.old"
        if (Test-Path $old) {
            $old = "$Target.old-$([DateTime]::UtcNow.Ticks)"
        }
        Move-Item -Force $Target $old
    }
    Copy-Item $Source $Target
}

# Downloaded before the agent is stopped, so that it is down only while the files are swapped.
function Get-AgentBinaries([string] $WorkDirectory) {
    Write-Step "Downloading woodpecker-agent $AgentVersion and plugin-git $PluginGitVersion"
    $agentZip = Get-VerifiedDownload "https://github.com/woodpecker-ci/woodpecker/releases/download/v$AgentVersion" `
        'woodpecker-agent_windows_amd64.zip' (Join-Path $WorkDirectory 'agent')
    $pluginGit = Get-VerifiedDownload "https://github.com/woodpecker-ci/plugin-git/releases/download/$PluginGitVersion" `
        'windows-amd64_plugin-git.exe' (Join-Path $WorkDirectory 'plugin-git')
    $unpacked = Join-Path $WorkDirectory 'agent\unpacked'
    Expand-Archive -Force $agentZip -DestinationPath $unpacked
    return @{ Agent = (Join-Path $unpacked 'woodpecker-agent.exe'); PluginGit = $pluginGit }
}

function Install-AgentBinaries($Binaries) {
    Write-Step "Installing woodpecker-agent $AgentVersion and plugin-git $PluginGitVersion into $AgentDirectory"
    Install-Binary $Binaries.Agent (Join-Path $AgentDirectory 'woodpecker-agent.exe')
    # The agent looks for plugin-git on PATH under exactly this name.
    Install-Binary $Binaries.PluginGit (Join-Path $AgentDirectory 'plugin-git.exe')
}

function Save-AgentSecret {
    $path = Join-Path $AgentDirectory $script:AgentSecretFile
    if (Test-Path $path) {
        Write-Step "Keeping the agent token in $path (manage-windows-agent.ps1 set-token replaces it)"
        return
    }
    Save-AgentToken $AgentDirectory (Read-AgentToken)
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
    foreach ($cache in $script:AgentCacheDirectories) {
        New-Item -ItemType Directory -Force (Join-Path $AgentDirectory $cache) | Out-Null
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
# The agent and every build it starts inherit the priority class of this process.
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = '$Priority'

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
# The CI scripts compile through ccache when it is installed and CCACHE_DIR is set. One cache
# serves every repository's pipelines on this agent, hence more than ccache's default of 5 GB.
`$env:CCACHE_DIR = Join-Path `$agentDirectory 'cache\ccache'
`$env:CCACHE_MAXSIZE = '20G'
# Lets the CI scripts name this file in their fix hints.
`$env:WOODPECKER_AGENT_SCRIPT = `$PSCommandPath
$forgejo

# The agent unsets the variable at its start, so the pipeline steps, which inherit the agent's
# environment, never see the token.
`$credential = Import-Clixml (Join-Path `$agentDirectory '$($script:AgentSecretFile)')
`$env:WOODPECKER_AGENT_SECRET = `$credential.GetNetworkCredential().Password
`$env:WOODPECKER_AGENT_CONFIG_FILE = Join-Path `$agentDirectory '$($script:AgentConfigFile)'
`$env:WOODPECKER_SERVER = $(ConvertTo-Literal $Server)
`$env:WOODPECKER_BACKEND = 'local'
`$env:WOODPECKER_HOSTNAME = $(ConvertTo-Literal $Hostname)
`$env:WOODPECKER_AGENT_LABELS = 'os=windows,env=native'
`$env:WOODPECKER_MAX_WORKFLOWS = '$MaxWorkflows'

# The task has no window, so the agent's output goes to a file (manage-windows-agent.ps1 log). It
# rolls over to a single older file at 10 MB; the agent's own WOODPECKER_LOG_FILE never does.
`$log = Join-Path `$agentDirectory '$($script:AgentLogFile)'
`$logWriter = `$null
function Write-AgentLog([string] `$Line) {
    `$mode = 'Append'
    if (`$script:logWriter -and `$script:logWriter.BaseStream.Length -ge 10MB) {
        `$script:logWriter.Dispose()
        `$script:logWriter = `$null
        # A reader may hold the older file open; then start the log over instead.
        try { Move-Item -Force `$log "`$log.1" } catch { `$mode = 'Create' }
    }
    if (-not `$script:logWriter) {
        `$stream = [IO.File]::Open(`$log, `$mode, 'Write', 'ReadWrite, Delete')
        `$script:logWriter = New-Object IO.StreamWriter (`$stream)
        `$script:logWriter.AutoFlush = `$true
    }
    `$script:logWriter.WriteLine(`$Line)
}

# Restarts the agent whenever it exits: after a crash or a lost connection it is back within
# seconds, and a rejected token retries every 5 minutes instead of spinning. Stopping the task
# ends this loop along with the agent.
`$delay = 10
while (`$true) {
    `$started = Get-Date
    Write-AgentLog "[run-agent] `$(`$started.ToString('s')) starting woodpecker-agent"
    # Windows PowerShell 5.1 turns every stderr line of a native program into an error record,
    # which 'Stop' would make terminating, and the agent logs to stderr.
    `$ErrorActionPreference = 'Continue'
    & (Join-Path `$agentDirectory 'woodpecker-agent.exe') 2>&1 | ForEach-Object { Write-AgentLog "`$_" }
    `$exitCode = `$LASTEXITCODE
    `$ErrorActionPreference = 'Stop'
    if (((Get-Date) - `$started).TotalMinutes -ge 10) {
        `$delay = 10
    }
    Write-AgentLog "[run-agent] `$((Get-Date).ToString('s')) woodpecker-agent exited with `$exitCode; restarting in `$delay s"
    Start-Sleep -Seconds `$delay
    `$delay = [Math]::Min(`$delay * 2, 300)
}
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

function Register-AgentTask([PSCredential] $TaskCredential) {
    if (Get-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue) {
        Write-Step "Removing the scheduled task '$($script:LegacyAgentTaskName)', which '$($script:AgentTaskName)' replaces"
        Stop-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:LegacyAgentTaskName -Confirm:$false
    }
    Write-Step "Registering the scheduled task '$($script:AgentTaskName)' (starts at $StartAt, priority $Priority)"
    $runAgent = Join-Path $AgentDirectory 'run-agent.ps1'
    $powershellArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runAgent`""
    $user = "$env:USERDOMAIN\$env:USERNAME"
    # No time limit: the default of 72 hours would stop the agent. run-agent.ps1 restarts the agent
    # itself; the task's restart settings only cover a task that fails to launch.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -Priority $script:TaskPriority[$Priority]
    if ($StartAt -eq 'Startup') {
        # Runs without a logon, in session 0 without a window. Windows stores the password; with it
        # the task loads the user profile, so DPAPI can decrypt the token (an S4U task could not).
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $powershellArguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $script:AgentTaskName -Action $action -Trigger $trigger -Settings $settings `
            -User $user -Password $TaskCredential.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
    }
    else {
        # conhost --headless gives the agent no window, which could be closed by accident.
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $powershellArguments"
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $script:AgentTaskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Force | Out-Null
    }
}

function Write-NextSteps([bool] $HasTask) {
    Write-Step 'Done. Next steps:'
    if ($HasTask) {
        Write-Host '- The agent is running and starts again by itself. Status, log, stop, start, removal:'
        Write-Host '  .\tools\woodpecker-agent\manage-windows-agent.ps1 <command> (Get-Help lists them)'
        if ($ScheduledTask -and $StartAt -eq 'Startup') {
            Write-Host '- After you change your Windows password: manage-windows-agent.ps1 set-password'
        }
    }
    else {
        Write-Host "- Start the agent: $(Join-Path $AgentDirectory 'run-agent.ps1')"
        Write-Host '  Release pipelines need it elevated; -ScheduledTask starts it at boot with highest privileges.'
    }
    Write-Host '- Check the agent: run the windows-agent-check pipeline manually in Woodpecker; every line'
    Write-Host '  should read [prerequisite-ok].'
}

$taskCredential = Get-TaskCredential
New-Item -ItemType Directory -Force $AgentDirectory | Out-Null
$AgentDirectory = (Resolve-Path $AgentDirectory).Path
# run-agent.ps1 starts in another directory, so a relative path would point somewhere else there.
$VcpkgRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VcpkgRoot)
Test-VcpkgRoot
Save-AgentSecret
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ("woodpecker-setup-" + [Guid]::NewGuid())
try {
    if ($InstallTools) {
        Install-Tools
    }
    Install-Vcpkg
    $binaries = Get-AgentBinaries $workDirectory
    $hadTask = [bool] (Get-ScheduledTask -TaskName $script:AgentTaskName -ErrorAction SilentlyContinue)
    if ($hadTask) {
        Stop-Agent
    }
    Install-AgentBinaries $binaries
    Write-RunAgentScript
    Set-ScriptExecutionPolicy
    if ($ScheduledTask) {
        Register-AgentTask $taskCredential
    }
    # Like the Linux setup's systemctl restart: the agent runs the new binary and environment.
    $hasTask = $hadTask -or $ScheduledTask
    if ($hasTask) {
        Start-Agent
    }
    Write-NextSteps $hasTask
}
finally {
    Remove-Item -Recurse -Force $workDirectory -ErrorAction SilentlyContinue
}
