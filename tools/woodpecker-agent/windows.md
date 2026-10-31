# Windows agent

The Windows agent runs the workflows with the labels `os=windows`, `env=native`. In the commands
below, replace `3.19.0` with the version of your Woodpecker server, and `<host>:<grpc-port>` with
the address its `WOODPECKER_GRPC_ADDR` listens on.

## Set up

1. Register the agent in Woodpecker (*Settings → Agents → Add agent*) and keep its token. Use this
   agent's token, not the server's shared `WOODPECKER_AGENT_SECRET`: with the shared secret the
   agent registers itself as a second entry, and it can't be revoked on its own.
2. In an elevated PowerShell (*Run as administrator*), as the user that will run the agent, in the
   checkout of this repository:

   ```powershell
   .\tools\woodpecker-agent\setup-windows-agent.ps1 -AgentVersion 3.19.0 -Server <host>:<grpc-port> -ScheduledTask
   ```

   The script asks for the token once.

3. Start the agent and check it:

   ```powershell
   .\tools\woodpecker-agent\manage-windows-agent.ps1 start
   ```

   Then run the `windows-agent-check` pipeline manually in Woodpecker; every line should read
   `[prerequisite-ok]`.

From now on the agent starts at every logon. It lands in `~\woodpecker-agent` and vcpkg in
`~\vcpkg`; `-AgentDirectory` and `-VcpkgRoot` change that. On a machine other than the server's,
the agent needs access to the server's gRPC port and to Forgejo; if the Forgejo address the server
uses does not resolve there, add `-ForgejoUrl`. `Get-Help .\tools\woodpecker-agent\setup-windows-agent.ps1 -Detailed`
lists all options.

### Existing vcpkg

The script uses the git checkout at `-VcpkgRoot` as it is: it bootstraps it if `vcpkg.exe` is
missing, and never updates it. Pass `-VcpkgRoot` on every later run too, or the script clones a
second copy to `~\vcpkg`. The checkout must contain the commit named by `builtin-baseline` in
`vcpkg.json`; if the configure step complains about the baseline, run `git -C <dir> pull` once. A
folder that is not a git checkout (a zip download, the copy bundled with Visual Studio) is refused
before anything is installed. The agent sets `VCPKG_ROOT` and the vcpkg binary cache for its own
process only, so your own `VCPKG_ROOT` and vcpkg cache stay as they are.

## Start, stop, read the log

```powershell
.\tools\woodpecker-agent\manage-windows-agent.ps1 status    # task, process, last log lines
.\tools\woodpecker-agent\manage-windows-agent.ps1 stop      # a running pipeline is aborted
.\tools\woodpecker-agent\manage-windows-agent.ps1 start
.\tools\woodpecker-agent\manage-windows-agent.ps1 restart
.\tools\woodpecker-agent\manage-windows-agent.ps1 log       # follow the log; Ctrl+C ends it
```

There is one agent per machine, so no command needs its name; the script finds the agent through
its scheduled task. `Get-Help .\tools\woodpecker-agent\manage-windows-agent.ps1` lists the commands.
A pipeline that stays pending means no running agent has the labels of its workflow: start the
agent and check *Settings → Agents*.

## Update

```powershell
.\tools\woodpecker-agent\setup-windows-agent.ps1 -AgentVersion 3.19.0 -Server <host>:<grpc-port> -Force
.\tools\woodpecker-agent\manage-windows-agent.ps1 restart
```

`-Force` regenerates `run-agent.ps1`, which a change of this repository may need. If the setup used
a non-default `-AgentDirectory` or `-VcpkgRoot`, pass the same value again.

To replace the agent's token, e.g. after creating the agent anew in Woodpecker:

```powershell
.\tools\woodpecker-agent\manage-windows-agent.ps1 set-token
```

## Remove

Let running pipelines finish first; removing the agent aborts them. In an elevated PowerShell (the
task runs with highest privileges):

```powershell
.\tools\woodpecker-agent\manage-windows-agent.ps1 uninstall
```

It asks before it stops the agent and deletes its task and directory, then lists what is left to
do: delete the agent in Woodpecker (*Settings → Agents*), so that the server stops listing it.

The script leaves these in place, because other things on the machine may use them. Remove them by
hand if you want the machine back as it was:

| Left behind | Where | Remove with |
|---|---|---|
| vcpkg checkout | `-VcpkgRoot`, default `~\vcpkg` | delete the folder, if nothing else uses it |
| Build tools, with `-InstallTools` | winget packages `Git.Git`, `Kitware.CMake`, `orhun.git-cliff`, Visual Studio Build Tools; Chocolatey `wixtoolset` | `winget uninstall --id <id>`, `choco uninstall wixtoolset` |
| Execution policy | `RemoteSigned` for the current user, only set if scripts were blocked | `Set-ExecutionPolicy -Scope CurrentUser Undefined` |

## How it runs

The agent runs natively, with Woodpecker's local backend: pipeline steps run directly on the
machine, as the user that runs the agent. `setup-windows-agent.ps1` stores the agent token
encrypted for that user (DPAPI), which is why the scheduled task runs as the same user.

Elevation is needed for `-ScheduledTask`: the task runs the agent with highest privileges at every
logon, because release pipelines install the MSI per machine to verify it. Without `-ScheduledTask`
the script needs no elevation; start `run-agent.ps1` by hand then, elevated for release pipelines.
`-InstallTools` installs the build tools with winget (and WiX v3 with Chocolatey); without it, the
`windows-agent-check` pipeline reports what is missing.

## Move an agent that was set up by hand

Run the setup script with `-AgentDirectory <its folder>`, `-VcpkgRoot <its vcpkg checkout>` and
`-Force`. Then delete the old start script, which holds the token in plain text.
