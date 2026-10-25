#!/usr/bin/env bash
# Sets up the Linux Woodpecker agent for this repository in a WSL Ubuntu 24.04 distribution: the
# steps of .woodpecker/README.md#linux-agent-setup-wsl in one run. Safe to run again, e.g. to
# update the agent to the version of the server.
#
# Run it as the user that will run the agent; it calls sudo where root is needed.

set -Eeuo pipefail

# The versions the presets and the agent check expect, see .woodpecker/README.md.
readonly GCC_VERSION=14
readonly CLANG_VERSION=20
readonly DEFAULT_PLUGIN_GIT_VERSION=2.11.0
readonly AGENT_DIR="$HOME/woodpecker-agent"
readonly VCPKG_DIR="$HOME/vcpkg"
# Not named woodpecker-agent.service, which the Woodpecker .deb package installs with its own
# environment file.
readonly SYSTEMD_UNIT=woodpecker-agent-wsl.service

usage() {
    cat <<EOF
Usage: $(basename "$0") --agent-version <x.y.z> [--server <host:port>] [options]

  --agent-version VERSION   woodpecker-agent release; use the version of the Woodpecker server
  --server HOST:PORT        gRPC address of the server (WOODPECKER_SERVER); required unless
                            $AGENT_DIR/run-agent.sh already exists
  --plugin-git-version VER  plugin-git release (default $DEFAULT_PLUGIN_GIT_VERSION)
  --hostname NAME           agent name shown in Woodpecker (default wsl-ubuntu)
  --max-workflows N         workflows the agent runs at once (default 1)
  --forgejo-url URL         only if CI_FORGE_URL is not reachable from WSL
  --systemd                 run the agent as the systemd service $SYSTEMD_UNIT
  --force                   regenerate an existing run-agent.sh

Register the agent first (Woodpecker UI: Settings -> Agents -> Add agent). The script asks for
its token, or reads it from WOODPECKER_AGENT_SECRET, unless $AGENT_DIR/agent.env exists.
EOF
}

info() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\n[error] %s\n' "$*" >&2
    exit 1
}

parse_arguments() {
    AGENT_VERSION=''
    SERVER=''
    PLUGIN_GIT_VERSION=$DEFAULT_PLUGIN_GIT_VERSION
    AGENT_HOSTNAME=wsl-ubuntu
    MAX_WORKFLOWS=1
    FORGEJO_URL=''
    USE_SYSTEMD=0
    FORCE=0
    while (($# > 0)); do
        case $1 in
            --agent-version) AGENT_VERSION=${2:?--agent-version needs a value}; shift 2 ;;
            --server) SERVER=${2:?--server needs a value}; shift 2 ;;
            --plugin-git-version) PLUGIN_GIT_VERSION=${2:?--plugin-git-version needs a value}; shift 2 ;;
            --hostname) AGENT_HOSTNAME=${2:?--hostname needs a value}; shift 2 ;;
            --max-workflows) MAX_WORKFLOWS=${2:?--max-workflows needs a value}; shift 2 ;;
            --forgejo-url) FORGEJO_URL=${2:?--forgejo-url needs a value}; shift 2 ;;
            --systemd) USE_SYSTEMD=1; shift ;;
            --force) FORCE=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; fail "unknown argument: $1" ;;
        esac
    done
    [[ -n $AGENT_VERSION ]] || { usage >&2; fail '--agent-version is required'; }
    [[ $MAX_WORKFLOWS =~ ^[1-9][0-9]*$ ]] || fail "--max-workflows must be a positive number"
    # The release tags carry a leading v, the version printed in the Woodpecker UI does not.
    AGENT_VERSION=${AGENT_VERSION#v}
    if [[ -z $SERVER && ( $FORCE == 1 || ! -f $AGENT_DIR/run-agent.sh ) ]]; then
        usage >&2
        fail '--server is required to write run-agent.sh'
    fi
}

check_system() {
    ((EUID != 0)) || fail 'run this as the agent user, not as root; it uses sudo where needed'
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ ${ID:-} != ubuntu ]] || ! dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04; then
        fail "${PRETTY_NAME:-this system} is not supported: the CI needs Ubuntu 24.04 or newer" \
            "(older releases lack gcc-$GCC_VERSION, CMake 3.28 and a git that plugin-git can use)." \
            'Install it with: wsl --install -d Ubuntu-24.04'
    fi
    case $(uname -m) in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) fail "unsupported architecture $(uname -m)" ;;
    esac
    if ((USE_SYSTEMD)) && [[ ! -d /run/systemd/system ]]; then
        fail 'systemd is not running in this distribution. Add "[boot]" and "systemd=true" to' \
            '/etc/wsl.conf, run "wsl --shutdown" in Windows, then start the distribution again.'
    fi
}

install_packages() {
    info "Installing the build tools (sudo)"
    sudo apt-get update
    # plugin-git runs "git lfs fetch" in every clone step, whether the repository uses LFS or not.
    sudo apt-get install -y git git-lfs cmake ninja-build build-essential dpkg-dev pkg-config \
        "gcc-$GCC_VERSION" "g++-$GCC_VERSION" lcov python3 curl jq zip unzip tar
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

write_agent_env() {
    local env_file="$AGENT_DIR/agent.env"
    if [[ -f $env_file ]]; then
        info "Keeping the agent token in $env_file"
        return
    fi
    local secret=${WOODPECKER_AGENT_SECRET:-}
    if [[ -z $secret ]]; then
        [[ -t 0 ]] || fail "no agent token: set WOODPECKER_AGENT_SECRET or create $env_file"
        read -rsp 'Agent token (Woodpecker UI: Settings -> Agents): ' secret
        printf '\n'
    fi
    [[ -n $secret ]] || fail 'the agent token is empty'
    info "Storing the agent token in $env_file"
    (umask 077 && printf 'WOODPECKER_AGENT_SECRET=%s\n' "$secret" > "$env_file")
}

write_run_agent_script() {
    local script="$AGENT_DIR/run-agent.sh"
    if [[ -f $script && $FORCE == 0 ]]; then
        info "Keeping $script (--force regenerates it)"
        return
    fi
    info "Writing $script"
    mkdir -p "$AGENT_DIR/cache/cpm" "$AGENT_DIR/coverage"
    {
        cat <<'EOF'
#!/usr/bin/env bash
# Generated by tools/woodpecker/setup-linux-agent.sh of the cpplib repository. Pipeline steps on
# the local backend inherit this environment, so restart the agent after changing it. See
# .woodpecker/README.md#linux-agent-setup-wsl.
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
# Coverage reports of every run, see "Coverage" in the README.
export COVERAGE_REPORT_DIR="$agent_dir/coverage"
# Lets the CI scripts name this file in their fix hints.
export WOODPECKER_AGENT_SCRIPT="$agent_dir/run-agent.sh"
EOF
        if [[ -n $FORGEJO_URL ]]; then
            printf '# CI_FORGE_URL is not reachable from WSL.\nexport FORGEJO_URL=%q\n' "$FORGEJO_URL"
        else
            printf '# Only if CI_FORGE_URL is not reachable from WSL:\n# export FORGEJO_URL="http://<host>:<port>"\n'
        fi
        cat <<'EOF'

set -a
. "$agent_dir/agent.env"
set +a
EOF
        printf 'export WOODPECKER_SERVER=%q\n' "$SERVER"
        printf 'export WOODPECKER_BACKEND=local\n'
        printf 'export WOODPECKER_HOSTNAME=%q\n' "$AGENT_HOSTNAME"
        printf 'export WOODPECKER_AGENT_LABELS="os=linux,env=wsl"\n'
        printf 'export WOODPECKER_MAX_WORKFLOWS=%q\n' "$MAX_WORKFLOWS"
        printf '\nexec "$agent_dir/woodpecker-agent"\n'
    } > "$script.new"
    chmod 755 "$script.new"
    mv -f "$script.new" "$script"
}

# Newer WSL kernels map memory with more ASLR entropy than ThreadSanitizer supports
# ("FATAL: ThreadSanitizer: unexpected memory mapping").
limit_aslr_entropy() {
    local current
    current=$(< /proc/sys/vm/mmap_rnd_bits)
    if ((current > 28)); then
        info "Lowering vm.mmap_rnd_bits from $current to 28 for ThreadSanitizer (sudo)"
        printf 'vm.mmap_rnd_bits = 28\n' | sudo tee /etc/sysctl.d/60-tsan-mmap-rnd-bits.conf > /dev/null
        sudo sysctl -q -w vm.mmap_rnd_bits=28
    fi
}

install_systemd_unit() {
    info "Installing and (re)starting $SYSTEMD_UNIT (sudo)"
    sudo tee "/etc/systemd/system/$SYSTEMD_UNIT" > /dev/null <<EOF
[Unit]
Description=Woodpecker agent (local backend, see cpplib .woodpecker/README.md)
Wants=network-online.target
After=network-online.target

[Service]
User=$(id -un)
ExecStart=$AGENT_DIR/run-agent.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$SYSTEMD_UNIT"
    # restart, not start: a rerun has to load the new binary and environment.
    sudo systemctl restart "$SYSTEMD_UNIT"
    if systemctl is-enabled --quiet woodpecker-agent.service 2> /dev/null ||
        systemctl is-active --quiet woodpecker-agent.service 2> /dev/null; then
        printf '\n[warning] woodpecker-agent.service (from the .deb package) is enabled or running as well.\n'
        printf '          Two agents would take the same jobs; stop it with:\n'
        printf '          sudo systemctl disable --now woodpecker-agent.service\n'
    fi
}

print_next_steps() {
    local distro=${WSL_DISTRO_NAME:-Ubuntu-24.04}
    info 'Done. Next steps:'
    if ((USE_SYSTEMD)); then
        cat <<EOF
- WSL still has to start the distribution at logon and keep it running. Windows Task Scheduler:
  trigger "At log on", action wsl.exe, arguments: -d $distro --exec sleep infinity
- Logs: journalctl -u $SYSTEMD_UNIT -f
EOF
    else
        cat <<EOF
- Start the agent at logon with a Windows scheduled task (Task Scheduler -> Create Task),
  trigger "At log on", action wsl.exe, arguments: -d $distro -- bash -lc $AGENT_DIR/run-agent.sh
  Or start it by hand now: $AGENT_DIR/run-agent.sh
  If an agent is already running, restart it so it loads the new binary and environment.
EOF
    fi
    cat <<EOF
- Optional: limit the WSL VM in %UserProfile%\\.wslconfig ([wsl2] memory=12GB, processors=8).
- Check the agent: run the linux-agent-check pipeline manually in Woodpecker; every line should
  read [prerequisite-ok].
EOF
}

main() {
    parse_arguments "$@"
    check_system
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    mkdir -p "$AGENT_DIR"
    install_packages
    pin_compilers
    install_vcpkg
    install_agent_binaries
    write_agent_env
    write_run_agent_script
    limit_aslr_entropy
    if ((USE_SYSTEMD)); then
        install_systemd_unit
    fi
    print_next_steps
}

main "$@"
