<#
.SYNOPSIS
Starts, stops, shows or removes the Woodpecker agent that setup-windows-agent.ps1 set up.

.DESCRIPTION
There is one agent per machine, run by the scheduled task 'Woodpecker agent', so no command needs
its name or directory; the script finds the directory through the task.

  start      start the agent
  stop       stop the agent; a running pipeline is aborted
  restart    stop and start, e.g. after a rerun of setup-windows-agent.ps1
  status     task state, agent process and the last lines of the log
  log        follow the agent's log (Ctrl+C ends it)
  set-token  replace the stored agent token, then restart the agent
  uninstall  remove the task and the agent directory; asks first (-Confirm:$false skips that)

uninstall needs an elevated PowerShell: the task was registered with highest privileges.

.PARAMETER Command
One of the commands above.

.EXAMPLE
.\tools\woodpecker-agent\manage-windows-agent.ps1 stop
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'log', 'set-token', 'uninstall')]
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

# The task runs "powershell.exe ... -File <agent directory>\run-agent.ps1".
function Get-AgentDirectory($Task) {
    if ($Task.Actions[0].Arguments -notmatch '-File\s+"([^"]+)"') {
        throw "Cannot find run-agent.ps1 in the action of the task '$($script:AgentTaskName)': $($Task.Actions[0].Arguments)"
    }
    return Split-Path -Parent $Matches[1]
}

function Get-AgentProcess {
    return @(Get-Process woodpecker-agent -ErrorAction SilentlyContinue)
}

function Stop-Agent {
    Write-Step "Stopping the task '$($script:AgentTaskName)'"
    Stop-ScheduledTask -TaskName $script:AgentTaskName
    # Stopping the task ends its process tree, but not at once.
    for ($i = 0; $i -lt 20 -and (Get-AgentProcess).Count -gt 0; $i++) {
        Start-Sleep -Milliseconds 500
    }
    $left = Get-AgentProcess
    if ($left.Count -gt 0) {
        Write-Host "[warning] woodpecker-agent is still running (PID $($left.Id -join ', ')); an agent started by hand, e.g. with run-agent.ps1, is not part of the task."
    }
}

function Start-Agent {
    Write-Step "Starting the task '$($script:AgentTaskName)'"
    Start-ScheduledTask -TaskName $script:AgentTaskName
    for ($i = 0; $i -lt 20 -and (Get-AgentProcess).Count -eq 0; $i++) {
        Start-Sleep -Milliseconds 500
    }
    if ((Get-AgentProcess).Count -eq 0) {
        Write-Host '[warning] woodpecker-agent did not start; see the log with: manage-windows-agent.ps1 status'
    }
}

function Show-Status($Task, [string] $AgentDirectory) {
    $info = Get-ScheduledTaskInfo -TaskName $script:AgentTaskName
    Write-Host "Task:      '$($script:AgentTaskName)' is $($Task.State) (last run $($info.LastRunTime), result 0x$('{0:X8}' -f $info.LastTaskResult))"
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
        Write-Host 'Log:       none; run-agent.ps1 predates the log file, rerun setup-windows-agent.ps1 with -Force'
    }
}

function Show-Log([string] $AgentDirectory) {
    $log = Join-Path $AgentDirectory $script:AgentLogFile
    if (-not (Test-Path $log)) {
        throw "There is no $log yet: run-agent.ps1 predates the log file. Rerun setup-windows-agent.ps1 with -Force, then restart the agent."
    }
    Get-Content $log -Tail 30 -Wait
}

function Set-AgentToken([string] $AgentDirectory) {
    Stop-Agent
    Save-AgentToken $AgentDirectory
    # The registration belongs to the old token.
    Remove-Item -Force (Join-Path $AgentDirectory $script:AgentConfigFile) -ErrorAction SilentlyContinue
    Start-Agent
    Write-Host 'If the old token belonged to another agent entry in Woodpecker, delete that entry under Settings -> Agents.'
}

function Assert-Elevated {
    if (-not (Test-Elevated)) {
        throw 'uninstall needs an elevated PowerShell (Run as administrator): the task was registered with highest privileges.'
    }
}

function Uninstall-Agent([string] $AgentDirectory) {
    $runAgent = Join-Path $AgentDirectory 'run-agent.ps1'
    $vcpkgRoot = if ((Test-Path $runAgent) -and ((Get-Content -Raw $runAgent) -match "VCPKG_ROOT = '([^']+)'")) { $Matches[1] } else { $null }
    Stop-Agent
    Write-Step "Removing the task '$($script:AgentTaskName)' and $AgentDirectory"
    Unregister-ScheduledTask -TaskName $script:AgentTaskName -Confirm:$false
    if (Get-ScheduledTask -TaskName $script:LegacyAgentTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:LegacyAgentTaskName -Confirm:$false
    }
    Remove-Item -Recurse -Force $AgentDirectory
    Write-Step 'Done. Left to do:'
    Write-Host '- Delete the agent in Woodpecker (Settings -> Agents).'
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
    'uninstall' {
        Assert-Elevated
        if ($PSCmdlet.ShouldProcess("the task '$($script:AgentTaskName)' and $agentDirectory", 'Remove the Woodpecker agent')) {
            Uninstall-Agent $agentDirectory
        }
    }
}
