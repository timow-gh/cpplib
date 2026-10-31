# Linux agent

The Linux agent runs the workflows with the labels `os=linux`, `env=linux`, on an Ubuntu 24.04
machine or in WSL 2. In the commands below, replace `3.19.0` with the version of your Woodpecker
server, and `<host>:<grpc-port>` with the address its `WOODPECKER_GRPC_ADDR` listens on.

## Set up

Register the agent in Woodpecker first (*Settings → Agents → Add agent*) and keep its token. Use
this agent's token, not the server's shared `WOODPECKER_AGENT_SECRET`: with the shared secret the
agent registers itself as a second entry, and it can't be revoked on its own. The script asks for
the token once.

### Ubuntu machine

Ubuntu 24.04 or newer with systemd (the default), as the user that will run the agent, in the
checkout of this repository:

```sh
bash tools/woodpecker-agent/setup-linux-agent.sh --agent-version 3.19.0 \
    --server <host>:<grpc-port> --systemd
```

The agent starts at boot. Check it by running the `linux-agent-check` pipeline manually in
Woodpecker; every line should read `[prerequisite-ok]`.

### Linux in WSL

In a Windows PowerShell, install the distribution (Ubuntu 20.04 is too old):

```powershell
wsl --install -d Ubuntu-24.04
```

Inside the distribution, run the same command as above, with the path of the checkout below
`/mnt/c/`:

```sh
bash /mnt/c/<path to this repository>/tools/woodpecker-agent/setup-linux-agent.sh --agent-version 3.19.0 \
    --server <host>:<grpc-port> --systemd
```

If it says systemd is not running, it also says what to add to `/etc/wsl.conf`. At its end the
script prints a `Register-ScheduledTask` command: paste it into a Windows PowerShell. From then on
WSL and the agent start at every logon. Check the agent as above.

### Options

On a machine other than the server's, the agent needs access to the server's gRPC port and to
Forgejo; if the Forgejo address the server uses does not resolve there, add `--forgejo-url`. `--help`
lists all options.

### Existing vcpkg

The script uses the git checkout at `--vcpkg-dir` (default `~/vcpkg`) as it is: it bootstraps it if
`vcpkg` is missing, and never updates it. Pass `--vcpkg-dir` on every later run too, or the script
clones a second copy to `~/vcpkg`. The checkout must contain the commit named by `builtin-baseline`
in `vcpkg.json`; if the configure step complains about the baseline, run `git -C <dir> pull` once. A
folder that is not a git checkout (e.g. a zip download) is refused before anything is installed.
The agent sets `VCPKG_ROOT` and the vcpkg binary cache for its own process only, so your own
`VCPKG_ROOT` and vcpkg cache stay as they are.

## Start, stop, read the log

```sh
bash tools/woodpecker-agent/manage-linux-agent.sh status    # service state, last log lines
bash tools/woodpecker-agent/manage-linux-agent.sh stop      # a running pipeline is aborted
bash tools/woodpecker-agent/manage-linux-agent.sh start
bash tools/woodpecker-agent/manage-linux-agent.sh restart
bash tools/woodpecker-agent/manage-linux-agent.sh log       # follow the log; Ctrl+C ends it
```

There is one agent per machine, so no command needs its name. `--help` lists the commands. A
pipeline that stays pending means no running agent has the labels of its workflow: start the agent
and check *Settings → Agents*.

## Update

```sh
bash tools/woodpecker-agent/setup-linux-agent.sh --agent-version 3.19.0 \
    --server <host>:<grpc-port> --systemd --force
```

The script restarts the service itself. `--force` regenerates `run-agent.sh`, which a change of
this repository may need. If the setup used `--vcpkg-dir`, pass the same value again.

To replace the agent's token, e.g. after creating the agent anew in Woodpecker:

```sh
bash tools/woodpecker-agent/manage-linux-agent.sh set-token
```

## Remove

Let running pipelines finish first; removing the agent aborts them.

```sh
bash tools/woodpecker-agent/manage-linux-agent.sh uninstall
```

It asks before it stops the agent and deletes its service and `~/woodpecker-agent` (with the kept
coverage reports). In WSL it also removes the Windows task that starts WSL, or prints the command
when it can't. Then delete the agent in Woodpecker (*Settings → Agents*), so that the server stops
listing it.

The script leaves these in place, because other things on the machine may use them. Remove them by
hand if you want the machine back as it was:

| Left behind | Where | Remove with |
|---|---|---|
| vcpkg checkout | `--vcpkg-dir`, default `~/vcpkg` | delete the folder, if nothing else uses it |
| Build tools | apt packages gcc-14, clang-20, cmake, ninja-build, lcov, git-lfs and others | `sudo apt remove <package>` |
| ThreadSanitizer setting | `/etc/sysctl.d/60-tsan-mmap-rnd-bits.conf` (`vm.mmap_rnd_bits=28`) | delete the file, then reboot or `sudo sysctl -w vm.mmap_rnd_bits=<previous value>` |

## How it runs

The agent runs with Woodpecker's local backend: pipeline steps run directly on the machine, as the
agent user, without root rights and without Docker. `setup-linux-agent.sh` does everything on the
machine, and runs the agent as the systemd service `woodpecker-agent-wsl.service` (with `--systemd`).
The name is historical; it differs from `woodpecker-agent.service` on purpose.

Don't install the Woodpecker `.deb` package. Its `woodpecker-agent.service` runs as the user
`woodpecker`, without the compiler pins, `VCPKG_ROOT` and the caches that `run-agent.sh` sets up.
The script warns if it is installed.

Ubuntu 20.04 is too old: no gcc-14 and clang-20, and its git is too old for `plugin-git`. The
script checks this and says what to do.

### WSL

WSL stops a distribution once no process runs in it. That is why the scheduled task the script
prints starts the distribution at logon and keeps it running with a process that only waits, which
keeps the agent service alive.

Optional: limit the WSL VM in `%UserProfile%\.wslconfig`, so that Windows and Linux pipelines can
run side by side (`[wsl2]`, `memory=12GB`, `processors=8`).
