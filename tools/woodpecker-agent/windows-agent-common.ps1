<#
.SYNOPSIS
What setup-windows-agent.ps1 and manage-windows-agent.ps1 share; both dot-source it.

.DESCRIPTION
The scripts handle the one agent on this machine, so its task name and file names are fixed here
instead of being passed around. ASCII only, like the scripts that include it.
#>

$script:AgentTaskName = 'Woodpecker agent'
# Named after the repository before the setup became reusable; a task left over from that time would
# start a second agent with the same name at logon.
$script:LegacyAgentTaskName = 'Woodpecker agent (cpplib)'
$script:AgentSecretFile = 'agent-secret.xml'
# The agent's registration with the server. Kept in the agent directory instead of the agent's
# default /etc/woodpecker/agent.conf, so that removing the directory removes all of the agent.
$script:AgentConfigFile = 'agent.conf'
# The task has no window, so run-agent.ps1 writes the agent's output to this file and rolls it over
# to agent.log.1 at a size limit.
$script:AgentLogFile = 'agent.log'
# What setup-windows-agent.ps1 puts into the agent directory. uninstall deletes exactly these: the
# directory is the user's choice (-AgentDirectory) and may hold other files.
$script:AgentFiles = @(
    'woodpecker-agent.exe', 'woodpecker-agent.exe.old*', 'plugin-git.exe', 'plugin-git.exe.old*',
    'run-agent.ps1', $script:AgentSecretFile, $script:AgentConfigFile, $script:AgentLogFile, "$($script:AgentLogFile).1"
)
$script:AgentCacheDirectories = @('cache\cpm', 'cache\vcpkg')
# Task Scheduler priority per -Priority. The agent and every build it starts run in the matching
# priority class: 5 normal, 7 below normal, 9 idle (only otherwise unused CPU time).
$script:TaskPriority = @{ Normal = 5; BelowNormal = 7; Idle = 9 }

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message"
}

function Test-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Reads the token from WOODPECKER_AGENT_SECRET or asks for it. Drops surrounding whitespace (a
# pasted line end) and refuses anything outside the alphabet of Woodpecker tokens, so that a bad
# paste fails here and not as a rejected agent later.
function Read-AgentToken {
    if ($env:WOODPECKER_AGENT_SECRET) {
        $token = $env:WOODPECKER_AGENT_SECRET
    }
    else {
        $entered = Read-Host -AsSecureString 'Agent token (Woodpecker UI: Settings -> Agents -> Add agent; not the server''s shared secret)'
        $token = (New-Object Management.Automation.PSCredential ('woodpecker-agent', $entered)).GetNetworkCredential().Password
    }
    $token = $token.Trim()
    if (-not $token) {
        throw 'the agent token is empty'
    }
    if ($token -cnotmatch '^[A-Za-z0-9._~+/=-]+$') {
        throw 'the agent token contains characters a Woodpecker token never has; copy it again from Settings -> Agents'
    }
    return ConvertTo-SecureString $token -AsPlainText -Force
}

# DPAPI: only this user on this machine can decrypt the file, which is why the scheduled task runs
# as this user.
function Save-AgentToken([string] $AgentDirectory, [Security.SecureString] $Token) {
    $path = Join-Path $AgentDirectory $script:AgentSecretFile
    Write-Step "Storing the agent token encrypted for $env:USERNAME in $path"
    New-Object Management.Automation.PSCredential ('woodpecker-agent', $Token) | Export-Clixml $path
}

function Get-AgentProcess {
    return @(Get-Process woodpecker-agent -ErrorAction SilentlyContinue)
}

function Stop-Agent {
    Write-Step "Stopping the task '$($script:AgentTaskName)'"
    Stop-ScheduledTask -TaskName $script:AgentTaskName
    # Stopping the task ends its process tree, run-agent.ps1's restart loop included, but not at once.
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
