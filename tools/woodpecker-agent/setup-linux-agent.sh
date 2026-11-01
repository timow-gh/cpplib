#!/usr/bin/env bash
# Sets up the Linux Woodpecker agent for this repository on an Ubuntu 24.04 machine or in a WSL
# distribution of it, in one run. tools/woodpecker-agent/linux.md has the commands for setting up,
# starting, updating and removing the agent. Safe to run again, e.g. to update the agent to the
# version of the server.
#
# Run it as the user that will run the agent; it calls sudo where root is needed.

set -Eeuo pipefail

# shellcheck source=linux-agent-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-agent-common.sh"

# The versions the presets and the agent check expect.
readonly GCC_VERSION=14
readonly CLANG_VERSION=20
readonly DEFAULT_PLUGIN_GIT_VERSION=2.11.0
readonly DEFAULT_VCPKG_DIR="$HOME/vcpkg"

usage() {
    cat <<EOF
Usage: $(basename "$0") --agent-version <x.y.z> [--server <host:port>] [options]

  --agent-version VERSION   woodpecker-agent release; use the version of the Woodpecker server
  --server HOST:PORT        gRPC address of the server (WOODPECKER_SERVER); required unless
                            $AGENT_DIR/run-agent.sh already exists
  --plugin-git-version VER  plugin-git release (default $DEFAULT_PLUGIN_GIT_VERSION)
  --vcpkg-dir DIR           existing vcpkg git checkout to use, or where to clone it
                            (default $DEFAULT_VCPKG_DIR); pass it on every run
  --hostname NAME           agent name shown in Woodpecker (default linux-ubuntu)
  --max-workflows N         workflows the agent runs at once (default 1)
  --priority PRIORITY       CPU and I/O priority of the agent and its builds: normal (default),
                            below-normal or idle (only otherwise unused CPU time)
  --forgejo-url URL         only if CI_FORGE_URL is not reachable from this machine
  --force                   regenerate an existing run-agent.sh

The agent runs as the systemd service $SYSTEMD_UNIT, which restarts it whenever it exits.
Register the agent first (Woodpecker UI: Settings -> Agents -> Add agent). The script asks for
its token, or reads it from WOODPECKER_AGENT_SECRET, unless $AGENT_TOKEN_FILE exists.
manage-linux-agent.sh starts, stops, shows and removes the agent afterwards.
EOF
}

parse_arguments() {
    AGENT_VERSION=''
    SERVER=''
    PLUGIN_GIT_VERSION=$DEFAULT_PLUGIN_GIT_VERSION
    AGENT_HOSTNAME=linux-ubuntu
    VCPKG_DIR=$DEFAULT_VCPKG_DIR
    MAX_WORKFLOWS=1
    PRIORITY=normal
    FORGEJO_URL=''
    FORCE=0
    while (($# > 0)); do
        case $1 in
            --agent-version) AGENT_VERSION=${2:?--agent-version needs a value}; shift 2 ;;
            --server) SERVER=${2:?--server needs a value}; shift 2 ;;
            --plugin-git-version) PLUGIN_GIT_VERSION=${2:?--plugin-git-version needs a value}; shift 2 ;;
            --vcpkg-dir) VCPKG_DIR=${2:?--vcpkg-dir needs a value}; shift 2 ;;
            --hostname) AGENT_HOSTNAME=${2:?--hostname needs a value}; shift 2 ;;
            --max-workflows) MAX_WORKFLOWS=${2:?--max-workflows needs a value}; shift 2 ;;
            --priority) PRIORITY=${2:?--priority needs a value}; shift 2 ;;
            --forgejo-url) FORGEJO_URL=${2:?--forgejo-url needs a value}; shift 2 ;;
            --force) FORCE=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; fail "unknown argument: $1" ;;
        esac
    done
    [[ -n $AGENT_VERSION ]] || { usage >&2; fail '--agent-version is required'; }
    [[ $MAX_WORKFLOWS =~ ^[1-9][0-9]*$ ]] || fail "--max-workflows must be a positive number"
    [[ $PRIORITY =~ ^(normal|below-normal|idle)$ ]] || fail "--priority must be normal, below-normal or idle"
    # The release tags carry a leading v, the version printed in the Woodpecker UI does not.
    AGENT_VERSION=${AGENT_VERSION#v}
    # run-agent.sh starts in another directory, so a relative path would point somewhere else there.
    VCPKG_DIR=$(realpath -m -- "$VCPKG_DIR")
    if [[ -z $SERVER && ( $FORCE == 1 || ! -f $AGENT_DIR/run-agent.sh ) ]]; then
        usage >&2
        fail '--server is required to write run-agent.sh'
    fi
}

check_system() {
    require_agent_user
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ ${ID:-} != ubuntu ]] || ! dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04; then
        fail "${PRETTY_NAME:-this system} is not supported: the CI needs Ubuntu 24.04 or newer" \
            "(older releases lack gcc-$GCC_VERSION, CMake 3.28 and a git that plugin-git can use)." \
            'In WSL, install it with: wsl --install -d Ubuntu-24.04'
    fi
    case $(uname -m) in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) fail "unsupported architecture $(uname -m)" ;;
    esac
    # systemd restarts the agent, sets its priority and rotates its log; there is no other mode.
    if [[ ! -d /run/systemd/system ]]; then
        if is_wsl; then
            fail 'systemd is not running in this distribution. Add "[boot]" and "systemd=true" to' \
                '/etc/wsl.conf, run "wsl --shutdown" in Windows, then start the distribution again.'
        fi
        fail 'systemd is not running on this machine; the agent runs as a systemd service'
    fi
}

# Checked before anything is installed: vcpkg resolves the builtin-baseline of vcpkg.json from the
# git history of the checkout, so a copy without .git (a zip download, the one bundled with an IDE)
# cannot work, and git clone refuses a non-empty directory.
check_vcpkg_directory() {
    if [[ -d $VCPKG_DIR && ! -d $VCPKG_DIR/.git && -n $(ls -A "$VCPKG_DIR") ]]; then
        fail "$VCPKG_DIR exists but is not a git checkout of vcpkg." \
            "Clone it (git clone https://github.com/microsoft/vcpkg <dir>) and pass --vcpkg-dir <dir>," \
            'or move the existing folder away.'
    fi
}

install_packages() {
    info "Installing the build tools (sudo)"
    sudo apt-get update
    # plugin-git runs "git lfs fetch" in every clone step, whether the repository uses LFS or not.
    sudo apt-get install -y git git-lfs cmake ninja-build build-essential dpkg-dev pkg-config \
        "gcc-$GCC_VERSION" "g++-$GCC_VERSION" lcov ccache python3 curl jq zip unzip tar
    # Captured instead of piped into grep -q, whose early exit would fail the pipe (pipefail).
    local policy
    policy=$(apt-cache policy "clang-$CLANG_VERSION")
    if [[ $policy != *'Candidate: '[0-9]* ]]; then
        install_llvm_repository
    fi
    sudo apt-get install -y "clang-$CLANG_VERSION" "clang-tidy-$CLANG_VERSION" \
        "libclang-rt-$CLANG_VERSION-dev"
}

install_llvm_repository() {
    info "clang-$CLANG_VERSION is not in the Ubuntu archive; adding apt.llvm.org"
    sudo apt-get install -y lsb-release wget software-properties-common gnupg
    curl -fsSL --retry 3 -o "$WORK_DIR/llvm.sh" https://apt.llvm.org/llvm.sh
    sudo bash "$WORK_DIR/llvm.sh" "$CLANG_VERSION"
}

# The presets call plain gcc, g++, clang and clang++. Links first on the agent's PATH select the
# versions for the CI without changing the system defaults.
pin_compilers() {
    info "Pinning gcc-$GCC_VERSION and clang-$CLANG_VERSION in $AGENT_DIR/bin"
    mkdir -p "$AGENT_DIR/bin"
    local tool
    for tool in gcc g++; do
        ln -sfn "/usr/bin/$tool-$GCC_VERSION" "$AGENT_DIR/bin/$tool"
    done
    for tool in clang clang++; do
        ln -sfn "/usr/bin/$tool-$CLANG_VERSION" "$AGENT_DIR/bin/$tool"
    done
}

install_vcpkg() {
    if [[ ! -d $VCPKG_DIR/.git ]]; then
        info "Cloning vcpkg into $VCPKG_DIR"
        git clone https://github.com/microsoft/vcpkg "$VCPKG_DIR"
    fi
    if [[ ! -x $VCPKG_DIR/vcpkg ]]; then
        info 'Bootstrapping vcpkg'
        "$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics
    fi
}

# Checks every download against the release's checksums.txt, so that a build for another
# platform or an HTML error page never ends up as the binary ("exec format error").
download_verified() {
    local base_url=$1 asset=$2 target_dir=$3
    mkdir -p "$target_dir"
    curl -fsSL --retry 3 -o "$target_dir/checksums.txt" "$base_url/checksums.txt"
    curl -fsSL --retry 3 -o "$target_dir/$asset" "$base_url/$asset"
    (cd "$target_dir" && awk -v name="$asset" '$2 == name' checksums.txt | sha256sum --check --status) ||
        fail "checksum of $asset from $base_url does not match"
}

# Renames into place, which also works while the running agent holds the old binary open.
install_binary() {
    local source=$1 target=$2
    cp "$source" "$target.new"
    chmod 755 "$target.new"
    mv -f "$target.new" "$target"
}

install_agent_binaries() {
    info "Installing woodpecker-agent $AGENT_VERSION and plugin-git $PLUGIN_GIT_VERSION ($ARCH)"
    local agent_asset="woodpecker-agent_linux_$ARCH.tar.gz"
    local plugin_asset="linux-${ARCH}_plugin-git"
    download_verified "https://github.com/woodpecker-ci/woodpecker/releases/download/v$AGENT_VERSION" \
        "$agent_asset" "$WORK_DIR/agent"
    download_verified "https://github.com/woodpecker-ci/plugin-git/releases/download/$PLUGIN_GIT_VERSION" \
        "$plugin_asset" "$WORK_DIR/plugin-git"
    tar -xzf "$WORK_DIR/agent/$agent_asset" -C "$WORK_DIR/agent" woodpecker-agent
    install_binary "$WORK_DIR/agent/woodpecker-agent" "$AGENT_DIR/woodpecker-agent"
    install_binary "$WORK_DIR/plugin-git/$plugin_asset" "$AGENT_DIR/plugin-git"
}

# Earlier versions kept the token as a line of shell code in agent.env, which run-agent.sh
# sourced. Its value is taken over as text, never sourced; write_run_agent_script deletes the file
# once a run-agent.sh exists that no longer reads it.
write_agent_token() {
    local legacy_env_file="$AGENT_DIR/agent.env" token
    if [[ -f $AGENT_TOKEN_FILE ]]; then
        info "Keeping the agent token in $AGENT_TOKEN_FILE (manage-linux-agent.sh set-token replaces it)"
        return
    fi
    if [[ -f $legacy_env_file ]]; then
        info "Taking over the agent token from $legacy_env_file"
        token=$(clean_agent_token "$(sed -n 's/^WOODPECKER_AGENT_SECRET=//p' "$legacy_env_file")")
    else
        token=$(read_agent_token)
    fi
    save_agent_token "$token"
}

write_run_agent_script() {
    local script="$AGENT_DIR/run-agent.sh"
    if [[ -f $script && $FORCE == 0 ]]; then
        info "Keeping $script (--force regenerates it with what this version of the script writes)"
        return
    fi
    info "Writing $script"
    mkdir -p "$AGENT_DIR/cache/cpm" "$AGENT_DIR/cache/vcpkg" "$AGENT_DIR/cache/ccache" "$AGENT_DIR/coverage"
    {
        cat <<'EOF'
#!/usr/bin/env bash
# Generated by tools/woodpecker-agent/setup-linux-agent.sh. Pipeline steps on the local backend
# inherit this environment, so restart the agent after changing it. See
# tools/woodpecker-agent/linux.md.
set -euo pipefail
EOF
        printf 'agent_dir=%q\n' "$AGENT_DIR"
        cat <<'EOF'

# The pin directory selects the compiler versions; the agent directory provides plugin-git.
export PATH="$agent_dir/bin:$agent_dir:/usr/local/bin:/usr/bin:/bin"
EOF
        printf 'export VCPKG_ROOT=%q\n' "$VCPKG_DIR"
        cat <<'EOF'
# Every pipeline starts in a fresh workspace; this keeps CPM's GoogleTest download.
export CPM_SOURCE_CACHE="$agent_dir/cache/cpm"
# The local backend points HOME at the workflow directory, which is deleted after every run, so
# vcpkg's default binary cache below HOME would rebuild the dependencies every time.
export VCPKG_DEFAULT_BINARY_CACHE="$agent_dir/cache/vcpkg"
# For the same reason ccache's default directory below HOME would start empty in every run. The
# CI scripts compile through ccache when it is installed and CCACHE_DIR is set.
export CCACHE_DIR="$agent_dir/cache/ccache"
export CCACHE_MAXSIZE=20G
# Coverage reports of every run, kept by .woodpecker/scripts/linux-coverage.sh.
export COVERAGE_REPORT_DIR="$agent_dir/coverage"
# Lets the CI scripts name this file in their fix hints.
export WOODPECKER_AGENT_SCRIPT="$agent_dir/run-agent.sh"
EOF
        if [[ -n $FORGEJO_URL ]]; then
            printf '# CI_FORGE_URL is not reachable from this machine.\nexport FORGEJO_URL=%q\n' "$FORGEJO_URL"
        else
            printf '# Only if CI_FORGE_URL is not reachable from this machine:\n# export FORGEJO_URL="http://<host>:<port>"\n'
        fi
        cat <<'EOF'

# The agent reads the token from the file and unsets this variable, so the pipeline steps,
# which inherit the agent's environment, never see the token.
export WOODPECKER_AGENT_SECRET_FILE="$agent_dir/agent-token"
export WOODPECKER_AGENT_CONFIG_FILE="$agent_dir/agent.conf"
EOF
        printf 'export WOODPECKER_SERVER=%q\n' "$SERVER"
        printf 'export WOODPECKER_BACKEND=local\n'
        printf 'export WOODPECKER_HOSTNAME=%q\n' "$AGENT_HOSTNAME"
        printf 'export WOODPECKER_AGENT_LABELS="os=linux,env=linux"\n'
        printf 'export WOODPECKER_MAX_WORKFLOWS=%q\n' "$MAX_WORKFLOWS"
        printf '\nexec "$agent_dir/woodpecker-agent"\n'
    } > "$script.new"
    chmod 755 "$script.new"
    mv -f "$script.new" "$script"
    rm -f "$AGENT_DIR/agent.env"
}

# Newer kernels (WSL's among them) map memory with more ASLR entropy than ThreadSanitizer supports
# ("FATAL: ThreadSanitizer: unexpected memory mapping"). Only root can read the current value.
limit_aslr_entropy() {
    local current
    current=$(sudo sysctl -n vm.mmap_rnd_bits)
    if ((current > 28)); then
        info "Lowering vm.mmap_rnd_bits from $current to 28 for ThreadSanitizer (sudo)"
        printf 'vm.mmap_rnd_bits = 28\n' | sudo tee /etc/sysctl.d/60-tsan-mmap-rnd-bits.conf > /dev/null
        sudo sysctl -q -w vm.mmap_rnd_bits=28
    fi
}

# Unit lines for --priority. Every process the agent starts, the builds among them, inherits them.
priority_directives() {
    case $PRIORITY in
        below-normal) printf 'Nice=10\nIOSchedulingClass=best-effort\nIOSchedulingPriority=7\n' ;;
        idle) printf 'Nice=19\nCPUSchedulingPolicy=idle\nIOSchedulingClass=idle\n' ;;
        normal) ;;
    esac
}

install_systemd_unit() {
    info "Installing and (re)starting $SYSTEMD_UNIT, priority $PRIORITY (sudo)"
    sudo tee "/etc/systemd/system/$SYSTEMD_UNIT" > /dev/null <<EOF
[Unit]
Description=Woodpecker agent (local backend, see tools/woodpecker-agent/linux.md)
Wants=network-online.target
After=network-online.target
# The default gives up after 5 starts in 10 s; an agent that is down takes no jobs.
StartLimitIntervalSec=0

[Service]
User=$(id -un)
ExecStart=$AGENT_DIR/run-agent.sh
# Also after a clean exit, e.g. when the server closed the connection.
Restart=always
RestartSec=10
$(priority_directives)

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$SYSTEMD_UNIT"
    # restart, not start: a rerun has to load the new binary and environment.
    sudo systemctl restart "$SYSTEMD_UNIT"
}

# The Woodpecker .deb package installs its own woodpecker-agent.service. It runs as the user
# woodpecker, without the compiler pins, VCPKG_ROOT and the caches of run-agent.sh, and once
# started it takes jobs as a second agent.
warn_about_deb_package() {
    local status
    status=$(dpkg-query -W -f='${Status}' woodpecker-agent 2> /dev/null) || status=''
    if [[ $status == *'install ok installed'* ]]; then
        cat <<'EOF'

[warning] The Woodpecker .deb package is installed; this setup does not use it. Its
          woodpecker-agent.service would run a second, misconfigured agent. Remove it:
          sudo apt remove woodpecker-agent
EOF
    fi
}

register_wsl_task() {
    if ! run_wsl_task register; then
        printf '\n[warning] Could not register the Windows task that keeps WSL running through WSL interop.\n'
        printf '          In a Windows PowerShell, not elevated, run:\n\n%s\n' "$(wsl_task_command register)"
    fi
}

print_next_steps() {
    info 'Done. Next steps:'
    printf -- '- Status, log, stop, start, removal: bash %s/manage-linux-agent.sh <command> (--help lists them)\n' \
        "$(dirname "${BASH_SOURCE[0]}")"
    if is_wsl; then
        printf -- '- Optional: limit the WSL VM in %%UserProfile%%\\.wslconfig ([wsl2] memory=12GB, processors=8);\n'
        printf -- '  that, not --priority, keeps the builds from slowing down Windows.\n'
    fi
    cat <<EOF
- Check the agent: run the linux-agent-check pipeline manually in Woodpecker; every line should
  read [prerequisite-ok].
EOF
}

main() {
    parse_arguments "$@"
    check_system
    check_vcpkg_directory
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    mkdir -p "$AGENT_DIR"
    # Asked first, so that the rest runs without the user.
    write_agent_token
    install_packages
    pin_compilers
    install_vcpkg
    install_agent_binaries
    write_run_agent_script
    limit_aslr_entropy
    install_systemd_unit
    if is_wsl; then
        register_wsl_task
    fi
    warn_about_deb_package
    print_next_steps
}

main "$@"
