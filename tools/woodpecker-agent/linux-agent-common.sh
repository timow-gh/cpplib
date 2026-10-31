# What setup-linux-agent.sh and manage-linux-agent.sh share; both source it. The scripts handle the
# one agent on this machine, so its directory and unit name are fixed here instead of being passed
# around.

readonly AGENT_DIR="$HOME/woodpecker-agent"
# Not named woodpecker-agent.service, which the Woodpecker .deb package installs with its own
# environment file. The "wsl" is historical: renaming would orphan the unit of existing installs.
readonly SYSTEMD_UNIT=woodpecker-agent-wsl.service
readonly AGENT_ENV_FILE="$AGENT_DIR/agent.env"
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

is_wsl() {
    grep -qi microsoft /proc/version
}

# The Windows task that starts the distribution at logon; setup prints how to register it.
wsl_task_name() {
    printf 'Woodpecker agent (WSL %s)' "${WSL_DISTRO_NAME:-Ubuntu-24.04}"
}

# Reads the token from WOODPECKER_AGENT_SECRET or asks for it, and stores it readable only by the
# agent user.
save_agent_token() {
    local secret=${WOODPECKER_AGENT_SECRET:-}
    if [[ -z $secret ]]; then
        [[ -t 0 ]] || fail "no agent token: set WOODPECKER_AGENT_SECRET or create $AGENT_ENV_FILE"
        read -rsp "Agent token (Woodpecker UI: Settings -> Agents -> Add agent; not the server's shared secret): " secret
        printf '\n'
    fi
    [[ -n $secret ]] || fail 'the agent token is empty'
    info "Storing the agent token in $AGENT_ENV_FILE"
    (umask 077 && printf 'WOODPECKER_AGENT_SECRET=%s\n' "$secret" > "$AGENT_ENV_FILE")
}
