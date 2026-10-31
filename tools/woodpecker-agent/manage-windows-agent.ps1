<#
.SYNOPSIS
Starts, stops, shows or removes the Woodpecker agent that setup-windows-agent.ps1 set up.

.DESCRIPTION
There is one agent per machine, run by the scheduled task 'Woodpecker agent', so no command needs
its name or directory; the script finds the directory through the task.

  start         start the agent
  stop          stop the agent until the next start, boot or logon; a running pipeline is aborted
  restart       stop and start, e.g. after changing run-agent.ps1
  status        start mode, priority, task state, agent process and the last lines of the log
  log           follow the agent's log (Ctrl+C ends it)
  set-token     replace the stored agent token, then restart the agent
  set-password  store your new Windows password in the task, after you changed it (a task that
                starts at boot only)
  uninstall     remove the agent's files and its task; asks first (-Confirm:$false skips that)

set-password and uninstall need an elevated PowerShell: the task was registered with highest
privileges.

.PARAMETER Command
One of the commands above.

.EXAMPLE
.\tools\woodpecker-agent\manage-windows-agent.ps1 stop
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'log', 'set-token', 'set-password', 'uninstall')]
    [string] $Command
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-agent-common.ps1')

function Get-AgentTask {
    $task = Get-ScheduledTask -TaskName $script:AgentTaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        throw "There is no scheduled task '$($script:AgentTaskName)' on this machine. Set the agent up with setup-windows-agent.ps1 -ScheduledTask (tools/woodpecker-agent/windows.md)."
    }
    return $task
}

# The task runs "powershell.exe ... -File <agent directory>\run-agent.ps1", directly or through conhost.
function Get-AgentDirectory($Task) {
    if ($Task.Actions[0].Arguments -notmatch '-File\s+"([^"]+)"') {
        throw "Cannot find run-agent.ps1 in the action of the task '$($script:AgentTaskName)': $($Task.Actions[0].Arguments)"
    }
    return Split-Path -Parent $Matches[1]
}

function Get-StartMode($Task) {
    if ($Task.Principal.LogonType -eq 'Password') { 'at boot (stored password)' } else { 'at logon' }
}

function Show-Status($Task, [string] $AgentDirectory) {
    $info = Get-ScheduledTaskInfo -TaskName $script:AgentTaskName
    Write-Host "Task:      '$($script:AgentTaskName)' is $($Task.State) (last run $($info.LastRunTime), result 0x$('{0:X8}' -f $info.LastTaskResult))"
    Write-Host "Starts:    $(Get-StartMode $Task), task priority $($Task.Settings.Priority)"
    Write-Host "Directory: $AgentDirectory"
    $processes = Get-AgentProcess
    $running = if ($processes.Count -gt 0) { "running (PID $($processes.Id -join ', '))" } else { 'not running' }
    Write-Host "Agent:     $running"
    $log = Join-Path $AgentDirectory $script:AgentLogFile
    if (Test-Path $log) {
        Write-Host "Log:       $log, last lines:"
        Get-Content $log -Tail 10 | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host 'Log:       none yet; the agent has not started since the setup'
    }
}

# Follows the log by its path, so that it goes on in the new file after run-agent.ps1 rolled it
# over; Get-Content -Wait would keep reading the renamed one.
function Show-Log([string] $AgentDirectory) {
    $log = Join-Path $AgentDirectory $script:AgentLogFile
    if (-not (Test-Path $log)) {
        throw "There is no $log yet: the agent has not started since the setup."
    }
    Get-Content $log -Tail 30
    $position = (Get-Item $log).Length
    while ($true) {
        Start-Sleep -Milliseconds 500
        try {
            $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
        }
        catch {
            continue  # between the rename and the first line of the new file
        }
        try {
            if ($stream.Length -lt $position) {
                $position = 0
            }
            $stream.Position = $position
            $text = (New-Object IO.StreamReader ($stream)).ReadToEnd()
            $position = $stream.Length
        }
        finally {
            $stream.Dispose()
        }
        if ($text) {
            Write-Host -NoNewline $text
        }
    }
}

function Set-AgentToken([string] $AgentDirectory) {
    # Asked before stopping, so that a cancelled or rejected entry leaves the agent running.
    $token = Read-AgentToken
    Stop-Agent
    Save-AgentToken $AgentDirectory $token
    # The registration belongs to the old token.
    Remove-Item -Force (Join-Path $AgentDirectory $script:AgentConfigFile) -ErrorAction SilentlyContinue
    Start-Agent
    Write-Host 'If the old token belonged to another agent entry in Woodpecker, delete that entry under Settings -> Agents.'
}

function Set-AgentPassword($Task) {
    if ($Task.Principal.LogonType -ne 'Password') {
        throw "The task starts the agent at logon and stores no password. setup-windows-agent.ps1 -ScheduledTask -StartAt Startup makes it start at boot."
    }
    $user = $Task.Principal.UserId
    $credential = Get-Credential -UserName $user -Message "The new Windows password of $user, which the task needs to start the agent at boot"
    if (-not $credential) {
        throw 'no password given; nothing changed'
    }
    Write-Step "Storing the new password in the task '$($script:AgentTaskName)'"
    Set-ScheduledTask -TaskName $script:AgentTaskName -User $user -Password $credential.GetNetworkCredential().Password | Out-Null
}

function Assert-Elevated {
    if (-not (Test-Elevated)) {
        throw "$Command needs an elevated PowerShell (Run as administrator): the task was registered with highest privileges."
    }
}

function Remove-EmptyDirectory([string] $Path) {
    if ((Test-Path $Path) -and -not (Get-ChildItem -Force $Path | Select-Object -First 1)) {
        Remove-Item -Force $Path
    }
}

# Deletes only what the setup created, then the task. A failure stops before the task is gone,
# so that a rerun still finds the directory through it.
function Uninstall-Agent([string] $AgentDirectory) {
    $runAgent = Join-Path $AgentDirectory 'run-agent.ps1'
    $vcpkgRoot = if ((Test-Path $runAgent) -and ((Get-Content -Raw $runAgent) -match "VCPKG_ROOT = '([^']+)'")) { $Matches[1] } else { $null }
    Stop-Agent
    Write-Step "Removing the agent's files from $AgentDirectory"
    foreach ($name in $script:AgentFiles) {
        Get-ChildItem -Force (Join-Path $AgentDirectory $name) -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    foreach ($cache in $script:AgentCacheDirectories) {
        $path = Join-Path $AgentDirectory $cache
        if (Test-Path $path) {
            Remove-Item -Recurse -Force $path
        }
    }
    Remove-EmptyDirectory (Join-Path $AgentDirectory 'cache')
    Remove-EmptyDirectory $AgentDirectory
    Write-Step "Removing the task '$($script:AgentTaskName)'"
    Unregister-ScheduledTask -TaskName $script:AgentTaskName -Confirm:$false
    if (Get-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:LegacyAgentTaskName -Confirm:$false
    }
    Write-Step 'Done. Left to do:'
    Write-Host '- Delete the agent in Woodpecker (Settings -> Agents).'
    if (Test-Path $AgentDirectory) {
        Write-Host "- $AgentDirectory is left in place: it holds files the setup did not create."
    }
    if ($vcpkgRoot) {
        Write-Host "- The vcpkg checkout $vcpkgRoot is left in place; delete it if nothing else uses it."
    }
    Write-Host '- The build tools and the execution policy are left in place too: tools/woodpecker-agent/windows.md#remove'
}

$task = Get-AgentTask
$agentDirectory = Get-AgentDirectory $task
switch ($Command) {
    'start' { Start-Agent }
    'stop' { Stop-Agent }
    'restart' { Stop-Agent; Start-Agent }
    'status' { Show-Status $task $agentDirectory }
    'log' { Show-Log $agentDirectory }
    'set-token' { Set-AgentToken $agentDirectory }
    'set-password' {
        Assert-Elevated
        Set-AgentPassword $task
    }
    'uninstall' {
        Assert-Elevated
        if ($PSCmdlet.ShouldProcess("the agent's files in $agentDirectory and the task '$($script:AgentTaskName)'", 'Remove the Woodpecker agent')) {
            Uninstall-Agent $agentDirectory
        }
    }
}
