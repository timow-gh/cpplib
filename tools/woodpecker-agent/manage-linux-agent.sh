#!/usr/bin/env bash
# Starts, stops, shows or removes the Woodpecker agent that setup-linux-agent.sh set up. There is
# one agent per machine, so no command needs its name or directory.

set -Eeuo pipefail

# shellcheck source=linux-agent-common.sh
. "$(dirname "${BASH_SOURCE[0]}")/linux-agent-common.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [--yes]

  start      start the agent
  stop       stop the agent until the next start or boot; a running pipeline is aborted
  restart    stop and start, e.g. after changing run-agent.sh
  status     state of $SYSTEMD_UNIT and its last log lines
  log        follow the agent's log (Ctrl+C ends it)
  set-token  replace the stored agent token, then restart the agent
  uninstall  remove $SYSTEMD_UNIT and $AGENT_DIR; asks first (--yes skips that)
EOF
}

has_unit() {
    [[ -f /etc/systemd/system/$SYSTEMD_UNIT ]]
}

require_unit() {
    has_unit || fail "$SYSTEMD_UNIT is not installed; set the agent up with setup-linux-agent.sh"
}

set_token() {
    [[ -d $AGENT_DIR ]] || fail "$AGENT_DIR does not exist; set the agent up with setup-linux-agent.sh"
    local token
    token=$(read_agent_token)
    save_agent_token "$token"
    # The registration belongs to the old token.
    rm -f "$AGENT_CONFIG_FILE"
    if has_unit; then
        info "Restarting $SYSTEMD_UNIT (sudo)"
        sudo systemctl restart "$SYSTEMD_UNIT"
    fi
    printf -- '- If the old token belonged to another agent entry in Woodpecker, delete that entry under Settings -> Agents.\n'
}

uninstall() {
    local assume_yes=$1 answer
    if [[ $assume_yes != 1 ]]; then
        read -rp "Remove $SYSTEMD_UNIT and $AGENT_DIR (with its caches and coverage reports)? [y/N] " answer
        [[ $answer == [yY]* ]] || { printf 'Nothing removed.\n'; return; }
    fi
    if has_unit; then
        info "Removing $SYSTEMD_UNIT (sudo)"
        sudo systemctl disable --now "$SYSTEMD_UNIT"
        sudo rm -f "/etc/systemd/system/$SYSTEMD_UNIT"
        sudo systemctl daemon-reload
    fi
    local vcpkg_root=''
    if [[ -f $AGENT_DIR/run-agent.sh ]]; then
        vcpkg_root=$(sed -n 's/^export VCPKG_ROOT=//p' "$AGENT_DIR/run-agent.sh")
    fi
    info "Removing $AGENT_DIR"
    rm -rf -- "$AGENT_DIR"
    local wsl_task_left=0
    if is_wsl; then
        run_wsl_task remove || wsl_task_left=1
    fi
    info 'Done. Left to do:'
    if ((wsl_task_left)); then
        printf -- '- In a Windows PowerShell, remove the task that keeps WSL running:\n  %s\n' "$(wsl_task_command remove)"
    fi
    printf -- '- Delete the agent in Woodpecker (Settings -> Agents).\n'
    if [[ -n $vcpkg_root ]]; then
        printf -- '- The vcpkg checkout %s is left in place; delete it if nothing else uses it.\n' "$vcpkg_root"
    fi
    printf -- '- The apt packages and the ThreadSanitizer sysctl are left in place too: tools/woodpecker-agent/linux.md#remove\n'
}

main() {
    local command=${1:-} assume_yes=0
    [[ ${2:-} == --yes ]] && assume_yes=1
    if [[ $command == -h || $command == --help ]]; then
        usage
        return
    fi
    require_agent_user
    case $command in
        start | stop | restart)
            require_unit
            info "Running systemctl $command $SYSTEMD_UNIT (sudo)"
            sudo systemctl "$command" "$SYSTEMD_UNIT"
            ;;
        status)
            require_unit
            systemctl status --no-pager --lines 10 "$SYSTEMD_UNIT" || true
            ;;
        log)
            require_unit
            journalctl -u "$SYSTEMD_UNIT" -n 30 -f
            ;;
        set-token) set_token ;;
        uninstall) uninstall "$assume_yes" ;;
        *)
            usage >&2
            fail "unknown command: ${command:-<none>}"
            ;;
    esac
}

main "$@"
