<#
.SYNOPSIS
Registers or removes the Windows task that keeps the WSL distribution of the Linux agent running.

.DESCRIPTION
WSL stops a distribution once no wsl.exe process runs in it; systemd services, the agent's
included, don't count. The task starts a process that only waits, at every logon, through
conhost --headless: a window could be closed by accident and so stop the agent.

setup-linux-agent.sh and manage-linux-agent.sh run this script through WSL interop. Run it yourself
only when they print the command to, in a PowerShell that is not elevated.

  register  register the task anew and start it
  remove    stop and remove the task

A task registered from an elevated PowerShell grants you only read access, so a later run without
elevation could neither replace nor remove it. register refuses to run elevated for that reason;
to replace or remove such a task, the script asks for elevation (UAC) for the removal alone.

.PARAMETER Command
One of the commands above.

.PARAMETER Distribution
The WSL distribution the agent runs in.

.EXAMPLE
.\tools\woodpecker-agent\wsl-task.ps1 register -Distribution Ubuntu-24.04
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('register', 'remove')]
    [string] $Command,
    [string] $Distribution = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
# Run through WSL interop there is no console, and PowerShell would print its progress bars as CLIXML.
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'windows-agent-common.ps1')

$taskName = "Woodpecker agent (WSL $Distribution)"

function Remove-WslTask {
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        return
    }
    Write-Step "Removing the task '$taskName'"
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    catch {
        Write-Host "Not allowed without elevation (the task was registered from an elevated PowerShell); asking for it."
        $removal = "`$ErrorActionPreference = 'Stop'; Unregister-ScheduledTask -TaskName '$($taskName.Replace("'", "''"))' -Confirm:`$false"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($removal))
        $elevated = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList "-NoProfile -NonInteractive -EncodedCommand $encoded"
        if ($elevated.ExitCode -ne 0) {
            throw "the elevated removal of the task '$taskName' failed with exit code $($elevated.ExitCode)"
        }
    }
}

function Register-WslTask {
    if (Test-Elevated) {
        throw 'run register in a PowerShell that is not elevated: setup-linux-agent.sh and manage-linux-agent.sh could neither replace nor remove a task registered from an elevated one'
    }
    # Removed first, not replaced with -Force: only the removal of a task registered from an elevated
    # PowerShell needs elevation, and stopping it keeps its process from running beside the new one.
    Remove-WslTask
    Write-Step "Registering the task '$taskName', which keeps WSL running from logon on"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless wsl.exe -d $Distribution --exec sleep infinity"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    # No time limit: the default of 72 hours would let WSL stop the distribution.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

switch ($Command) {
    'register' { Register-WslTask }
    'remove' { Remove-WslTask }
}
