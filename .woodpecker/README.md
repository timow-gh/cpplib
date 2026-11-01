# Woodpecker CI

These workflows run the CI of this repository on a self-hosted Forgejo + Woodpecker setup. They
mirror `.github/workflows/`, which stays the primary CI. The header of each workflow file names its
GitHub counterpart and how it differs.

Two agents run them, both with the local backend: a native Windows agent (labels `os=windows`,
`env=native`) and a Linux agent (labels `os=linux`, `env=linux`) on an Ubuntu machine or in WSL.
They are independent: each connects to the server on its own, and the server sends a workflow to an
agent whose labels match, so they can run on one computer or on two. To set up, start, update or
remove one, see [windows.md](../tools/woodpecker-agent/windows.md) and
[linux.md](../tools/woodpecker-agent/linux.md).

## Rules for all workflow files

- All logic lives in `scripts/`: `*.ps1` for the Windows agent, `*.sh` for the Linux agent.
  Woodpecker substitutes variables in the raw text of a workflow file, comments included, before
  the shell sees it. That breaks PowerShell's `$env:X` and bash variables alike, so the only `$` in
  a workflow file is an intended matrix variable such as `${PRESET_SUFFIX}`.
- Bash scripts are called as `bash .woodpecker/scripts/x.sh`, so they need no executable bit.

## Order on the agents

Each agent runs one workflow at a time, so a pull request's workflows queue up. `depends_on` puts
the quick ones first, which gives feedback on most checks early:

| Agent | First | Then | Last |
|---|---|---|---|
| Windows | `commit-messages` | `windows-build` | `windows-package` |
| Linux | `linux-build`, `linux-package` | `linux-sanitizers`, `linux-coverage` | `linux-static-analysis` (clang-tidy) |

The dependencies only order the queue:

- `optional: true`, because not every workflow runs for every event.
- `status: [success, failure]` in each `when` entry, so a failed dependency doesn't skip the
  workflows after it.
- None crosses agents, which would leave one agent idle while it waits for the other.

GitHub has no such order: there every job gets its own runner and all run at once.

## Forgejo and Woodpecker settings

Forgejo shows one status per workflow and matrix entry, and there are no `*-summary` jobs like on
GitHub. Set up the branch protection rules with these names.

Keep *Settings → Project → Require approval for* at least at pull requests from forks. A pull
request pipeline runs the code of the pull request branch on the agent machine, as the agent's
user.

### Secrets

Create these as repository secrets in Woodpecker. Woodpecker refuses to start a pipeline that
references a secret that does not exist.

| Secret | Value | Events |
|---|---|---|
| `forgejo_token` | Forgejo access token with `write:repository` | tag, manual |
| `allow_product_identity_change` | `false`; `true` only for a release that deliberately becomes a new product | tag, manual |
| `forgejo_package_token` | Forgejo access token with **only** `write:package` | push |

No secret is available for `pull_request`: the pull request's code could read it.
`forgejo_package_token` is the exception for `push`, where the coverage of `main` is uploaded.
Woodpecker filters secrets by event, not by branch, so a push to a `develop-*` branch, which has not
been reviewed yet either, could request it too. That is why it can only write packages, and why it
is not the release token.

Pull requests compare their coverage with the last upload of `main`, which they download without
login. The owner of the repository must therefore be public in Forgejo.

## Troubleshooting

Every script checks what it needs before doing any work, and prints each missing piece with the
problem, what was checked and a concrete fix:

```
[prerequisite-missing] id=vcpkg-root
  problem:  VCPKG_ROOT is not set in the agent environment
  checked:  $env:VCPKG_ROOT
  fix:      clone https://github.com/microsoft/vcpkg, run bootstrap-vcpkg.bat in it, ...
[prerequisites] 1 of 4 required checks failed - the agent 'windows-native' is not set up for this workflow
```

Other tagged lines: `[prerequisite-ok]`, `[prerequisite-warning]`, `[command-failed]`,
`[forgejo-api-failed]`, `[retry]`, `[verify-refused]`, `[cleanup-failed]`, `[warning]` and
`[error]`. Run `windows-agent-check` or `linux-agent-check` manually to check a whole agent at once.

### Reading pipeline logs (coding agents)

Logs are available through the Woodpecker CLI or REST API, both authenticated with a personal
token from the Woodpecker UI (user settings):

```sh
export WOODPECKER_SERVER=http://<woodpecker-host>:<port>
export WOODPECKER_TOKEN=<token>
woodpecker-cli pipeline ls <owner>/<repo>
woodpecker-cli pipeline log show <owner>/<repo> <pipeline-number>
```

The subcommands moved between CLI versions; `woodpecker-cli --help` shows the ones of the
installed version. Search the log for `[prerequisite-missing]`, `[command-failed]` and `[error]`.

### Failures before any script runs

| Symptom | Cause | Fix |
|---|---|---|
| Pipeline stays pending | No connected agent has the labels of the workflow | Start the agent ([Windows](../tools/woodpecker-agent/windows.md#start-stop-read-the-log), [Linux](../tools/woodpecker-agent/linux.md#start-stop-read-the-log)); check *Settings → Agents* |
| `secret "forgejo_token" not found` (or similar) | Secret missing or not allowed for the event | See [Secrets](#secrets) |
| `exec: "powershell"` / `exec: "bash": executable file not found` | The shell is not on the agent's PATH | Fix PATH in the agent's `run-agent.ps1` / `run-agent.sh` |
| Clone step fails | `plugin-git` missing from the agent's PATH | Rerun the setup script ([Windows](../tools/woodpecker-agent/windows.md#update), [Linux](../tools/woodpecker-agent/linux.md#update)) |
| `fork/exec .../plugin-git: exec format error` | `plugin-git` is a build for another platform, or a saved error page | Rerun the setup script; it checks the download against the release checksums |
| `git init`: `unknown option 'object-format'` | git older than 2.29 (Ubuntu 20.04) | Use Ubuntu 24.04 |
| `git: 'lfs' is not a git command` | `plugin-git` fetches LFS objects in every clone | `sudo apt-get install git-lfs` (Git for Windows ships it) |
| `... cannot be loaded because running scripts is disabled` | Execution policy of the agent user | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `$'\r': command not found` | A bash script has CRLF line endings | Check `.gitattributes` and check out again |
| `FATAL: ThreadSanitizer: unexpected memory mapping` | WSL kernel with high ASLR entropy | Rerun the Linux setup script, or `sudo sysctl vm.mmap_rnd_bits=28` |
