# Woodpecker CI

These workflows run the CI of this repository on a self-hosted Forgejo + Woodpecker setup. They
mirror `.github/workflows/` and check every pull request, while GitHub runs its workflows only when
`main` or a tag is [published](../CONTRIBUTING.md#publishing-to-github). The header of each workflow
file names its GitHub counterpart and how it differs.

Two agents run them, both with the local backend: a native Windows agent (labels `os=windows`,
`env=native`) and a Linux agent (labels `os=linux`, `env=linux`) on an Ubuntu machine or in WSL.
They are independent: each connects to the server on its own, and the server sends a workflow to an
agent whose labels match, so they can run on one computer or on two. To set up, start, update or
remove one, see [windows.md](../tools/woodpecker-agent/windows.md) and
[linux.md](../tools/woodpecker-agent/linux.md).

## What runs when

| Event | Workflows |
|---|---|
| Pull request to `main` | every build, package, sanitizer and analysis workflow, `linux-coverage` (with a coverage comment on the pull request), `commit-messages` |
| Push to a `develop-*` branch | `linux-gcc-debug`, `windows-msvc-debug` |
| Push to `main` | `linux-coverage` only: it uploads the coverage baseline that pull requests compare with |
| `v*` tag | `release`, `release-linux`, `release-finalize` |
| Manual | the release workflows (without publishing), `linux-agent-check`, `windows-agent-check` |

Unlike GitHub, a push to `main` does not rebuild, because `main` gets the tree its pull request
already tested. That holds only if Forgejo blocks merging an outdated pull request (see
[Forgejo and Woodpecker settings](#forgejo-and-woodpecker-settings)): a pull request pipeline tests
the head of the pull request branch, not its merge with `main`.

## Rules for all workflow files

- All logic lives in `scripts/`: `*.ps1` for the Windows agent, `*.sh` for the Linux agent.
  Woodpecker substitutes variables in the raw text of a workflow file, comments included, before
  the shell sees it. That breaks PowerShell's `$env:X` and bash variables alike, so no workflow
  file contains a `$`.
- Bash scripts are called as `bash .woodpecker/scripts/x.sh`, so they need no executable bit.

## Order on the agents

Each agent runs one workflow at a time, so a pull request's workflows queue up. `depends_on` puts
the quick ones first, which gives feedback on most checks early:

| Agent | First | Then | Last |
|---|---|---|---|
| Windows | `commit-messages` | `windows-msvc-*` builds | `windows-package-*` |
| Linux | `linux-{gcc,clang}-{debug,release}`, `linux-gcc-release-standalone`, `linux-package-*` | `linux-clang-debug-{asan,tsan,ubsan}`, `linux-coverage` | `linux-static-analysis` (clang-tidy) |

The dependencies only order the queue:

- `optional: true`, because not every workflow runs for every event.
- `status: [success, failure]` in each `when` entry, so a failed dependency doesn't skip the
  workflows after it.
- None crosses agents, which would leave one agent idle while it waits for the other.

GitHub has no such order: there every job gets its own runner and all run at once.

## Forgejo and Woodpecker settings

Forgejo shows one status per workflow, and there are no `*-summary` jobs like on GitHub. Woodpecker
names them `ci/woodpecker/<event>/<workflow file name>`. A matrix entry would only get its number
appended (`/1`, `/2`), so every job has its own workflow file instead of a matrix. Set up the
branch protection rule of `main` with:

- *Block merge if pull request is outdated*, so that `main` only gets trees a pull request tested.
- The required status checks, one pattern per line:

  ```
  ci/woodpecker/pr/commit-messages
  ci/woodpecker/pr/linux-gcc-debug
  ci/woodpecker/pr/linux-gcc-release
  ci/woodpecker/pr/linux-clang-debug
  ci/woodpecker/pr/linux-clang-release
  ci/woodpecker/pr/linux-gcc-release-standalone
  ci/woodpecker/pr/linux-package-shared
  ci/woodpecker/pr/linux-package-standalone
  ci/woodpecker/pr/linux-clang-debug-asan
  ci/woodpecker/pr/linux-clang-debug-tsan
  ci/woodpecker/pr/linux-clang-debug-ubsan
  ci/woodpecker/pr/linux-static-analysis
  ci/woodpecker/pr/windows-msvc-debug
  ci/woodpecker/pr/windows-msvc-release
  ci/woodpecker/pr/windows-msvc-release-standalone
  ci/woodpecker/pr/windows-package-shared
  ci/woodpecker/pr/windows-package-standalone
  ```

  `ci/woodpecker/pr/linux-coverage` is left out: coverage is informational, and a refused comment
  attachment would otherwise block every merge. Forgejo only accepts patterns that match statuses
  it has seen on recent commits, so add a new name after its first pipeline has run.

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
| `forgejo_comment_token` | Token of the CI bot account with **only** `write:issue` | pull_request |

`forgejo_package_token` is available for `push`, where the coverage of `main` is uploaded.
Woodpecker filters secrets by event, not by branch, so a push to a `develop-*` branch, which has not
been reviewed yet either, could request it too. That is why it can only write packages, and why it
is not the release token.

`forgejo_comment_token` is the only secret of `pull_request` pipelines. They run the pull request's
code, which can read it, so it belongs to a dedicated bot account, not to a person, and can only
write issues and comments. The bot needs read access to the repository. A leaked token lets
someone comment as the bot. Keep *Require approval for* at least at pull requests from forks, and
before approving a fork's pipeline, check that its changes don't send the token anywhere.

### Coverage

Every coverage run of a pull request adds a comment to the pull request: the report, compared with
the last upload of `main`, plus the run's `coverage.json`, `coverage-summary.md` and
`coverage-html.tar.gz` attached to that comment. Each push gets its own comment, and older comments
stay, so every run's numbers and files remain downloadable. The comments start with the marker
`<!-- coverage-report -->`. Forgejo must accept `.md`, `.json` and `.gz` attachments of that
size (`[attachment]` in `app.ini`, `ALLOWED_TYPES` and `MAX_SIZE`).

Pull requests download the baseline of `main` without login. The owner of the repository must
therefore be public in Forgejo.

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
