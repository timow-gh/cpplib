# What setup-linux-agent.sh and manage-linux-agent.sh share; both source it. The scripts handle the
# one agent on this machine, so its directory and unit name are fixed here instead of being passed
# around.

readonly AGENT_DIR="$HOME/woodpecker-agent"
# Not named woodpecker-agent.service, which the Woodpecker .deb package installs with its own
# environment file. The "wsl" is historical: renaming would orphan the unit of existing installs.
readonly SYSTEMD_UNIT=woodpecker-agent-wsl.service
# The raw token and nothing else. The agent reads it itself (WOODPECKER_AGENT_SECRET_FILE), so no
# shell ever parses it and it needs no quoting.
readonly AGENT_TOKEN_FILE="$AGENT_DIR/agent-token"
# The agent's registration with the server. Kept in the agent directory instead of the agent's
# default /etc/woodpecker/agent.conf, which the agent user cannot write, so that removing the
# directory removes all of the agent.
readonly AGENT_CONFIG_FILE="$AGENT_DIR/agent.conf"

info() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\n[error] %s\n' "$*" >&2
    exit 1
}

# AGENT_DIR depends on HOME, which sudo replaces with root's.
require_agent_user() {
    ((EUID != 0)) || fail 'run this as the agent user, not as root; it uses sudo where needed'
}

is_wsl() {
    grep -qi microsoft /proc/version
}

# The Windows task that keeps the distribution running after logon; setup registers it.
wsl_task_name() {
    printf 'Woodpecker agent (WSL %s)' "${WSL_DISTRO_NAME:-Ubuntu-24.04}"
}

# Runs a PowerShell script in Windows through WSL interop. The script travels base64-encoded
# (UTF-16LE, as -EncodedCommand expects), so nothing in it needs quoting for bash or Windows.
# Without a console, PowerShell would print its progress bars as CLIXML.
run_windows_powershell() {
    local script=$1 encoded
    command -v powershell.exe > /dev/null || return 1
    encoded=$(printf "\$ErrorActionPreference = 'Stop'\n\$ProgressPreference = 'SilentlyContinue'\n%s" "$script" |
        iconv -t UTF-16LE | base64 -w 0)
    powershell.exe -NoProfile -NonInteractive -EncodedCommand "$encoded"
}

# Drops surrounding whitespace (a pasted line end) and refuses anything outside the alphabet of
# Woodpecker tokens, so that a bad paste fails here and not as a rejected agent later.
clean_agent_token() {
    local token=$1
    token=${token#"${token%%[![:space:]]*}"}
    token=${token%"${token##*[![:space:]]}"}
    [[ -n $token ]] || fail 'the agent token is empty'
    [[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] ||
        fail 'the agent token contains characters a Woodpecker token never has; copy it again from Settings -> Agents'
    printf '%s' "$token"
}

# Prints the token from WOODPECKER_AGENT_SECRET, or asks for it.
read_agent_token() {
    local token=${WOODPECKER_AGENT_SECRET:-}
    if [[ -z $token ]]; then
        [[ -t 0 ]] || fail 'no agent token: set WOODPECKER_AGENT_SECRET or run this in a terminal'
        read -rsp "Agent token (Woodpecker UI: Settings -> Agents -> Add agent; not the server's shared secret): " token
        printf '\n' >&2
    fi
    clean_agent_token "$token"
}

# Stores the token readable only by the agent user, without a line end.
save_agent_token() {
    local token=$1
    info "Storing the agent token in $AGENT_TOKEN_FILE"
    (umask 077 && printf '%s' "$token" > "$AGENT_TOKEN_FILE.new")
    mv -f "$AGENT_TOKEN_FILE.new" "$AGENT_TOKEN_FILE"
}
