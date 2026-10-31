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
# The scheduled task runs hidden, so the agent writes its log to this file.
$script:AgentLogFile = 'agent.log'

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message"
}

function Test-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# DPAPI: only this user on this machine can decrypt the file, which is why the scheduled task runs
# as this user.
function Save-AgentToken([string] $AgentDirectory) {
    if ($env:WOODPECKER_AGENT_SECRET) {
        $secret = ConvertTo-SecureString $env:WOODPECKER_AGENT_SECRET -AsPlainText -Force
    }
    else {
        $secret = Read-Host -AsSecureString 'Agent token (Woodpecker UI: Settings -> Agents -> Add agent; not the server''s shared secret)'
    }
    if ($secret.Length -eq 0) {
        throw 'the agent token is empty'
    }
    $path = Join-Path $AgentDirectory $script:AgentSecretFile
    Write-Step "Storing the agent token encrypted for $env:USERNAME in $path"
    New-Object Management.Automation.PSCredential ('woodpecker-agent', $secret) | Export-Clixml $path
}
