#!/usr/bin/env bash
set -euo pipefail

SELF=$(readlink -f -- "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
CONFIG_FILE=/etc/archangel.conf
STATE_DIR=/var/lib/archangel
INSTALL_STATE="$STATE_DIR/install.env"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    caller=${USER:-$(id -un)}
    exec sudo env ARCHANGEL_CALLER="$caller" bash "$SELF" "$@"
fi

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
ask() {
    local prompt=$1 default=$2 value
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value </dev/tty
    else
        read -r -p "$prompt: " value </dev/tty
    fi
    printf '%s' "${value:-$default}"
}
yes_no() {
    local prompt=$1 default=${2:-Y} answer suffix
    [[ "$default" == Y ]] && suffix='Y/n' || suffix='y/N'
    read -r -p "$prompt [$suffix]: " answer </dev/tty
    answer=${answer:-$default}
    [[ "$answer" =~ ^[Yy]$ ]]
}
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; }
in_group() { id -nG "$1" | tr ' ' '\n' | grep -qx "$2"; }

check_agent_sudo_privileges() {
    local user=$1 listing
    command -v sudo >/dev/null 2>&1 || return 0
    listing=$(sudo -l -U "$user" 2>/dev/null || true)
    grep -Eq '^[[:space:]]*\([^)]*\)[[:space:]]+' <<<"$listing" || return 0

    say
    say "WARNING: '$user' already has sudo authority from this machine's existing sudoers policy:"
    printf '%s\n' "$listing" | sed -n '/may run the following commands/,$p'
    say
    say "Archangel did not create these privileges and will not remove them."
    say "They weaken the intended non-privileged agent boundary."
    if ! yes_no "Continue using '$user' despite these pre-existing sudo privileges?" N; then
        if [[ "${agent_created:-no}" == yes ]]; then
            say "Removing the newly created agent account before aborting."
            userdel -r "$user" >/dev/null 2>&1 || true
        fi
        die "adjust the host sudoers policy or explicitly accept the pre-existing agent privilege"
    fi
}

acl_installed_by_archangel=no
install_acl_package() {
    if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then return; fi
    say "The POSIX ACL tools are required but setfacl/getfacl were not found."
    yes_no "Install the ACL package now?" Y || die "ACL tools are required"
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed acl
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update; apt-get install -y acl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y acl
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install acl
    else
        die "could not identify a supported package manager; install the acl package manually and rerun"
    fi
    command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 \
        || die "ACL package installation completed but setfacl/getfacl are still unavailable"
    acl_installed_by_archangel=yes
}

[[ -r "$SCRIPT_DIR/lib/archangel/discovery.sh" ]] || die "missing lib/archangel/discovery.sh"
[[ -r "$SCRIPT_DIR/lib/archangel/hermes.sh" ]] || die "missing lib/archangel/hermes.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/archangel/discovery.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/archangel/hermes.sh"

install_dashboard_service() {
    local home group unit tmp was_enabled=no
    home=$(archangel_agent_home)
    group=$(id -gn "$ARCHANGEL_AGENT_USER")
    unit="$home/.config/systemd/user/hermes-dashboard.service"
    ARCHANGEL_DASHBOARD_UNIT_CREATED=no
    ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL=no
    ARCHANGEL_DASHBOARD_PERSISTENT=no

    install -d -o "$ARCHANGEL_AGENT_USER" -g "$group" -m 0755 "$home/.config/systemd/user"

    if [[ -e "$unit" ]]; then
        say "An existing Hermes dashboard user service is already present; preserving it."
    else
        tmp=$(mktemp)
        cat > "$tmp" <<UNIT
[Unit]
Description=Hermes Web Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$home
EnvironmentFile=-$home/.hermes/.env
ExecStart=$ARCHANGEL_HERMES_BIN dashboard --no-open --host 127.0.0.1 --port 9119
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
        install -o "$ARCHANGEL_AGENT_USER" -g "$group" -m 0644 "$tmp" "$unit"
        rm -f "$tmp"
        ARCHANGEL_DASHBOARD_UNIT_CREATED=yes
        say "Installed Hermes dashboard user service for '$ARCHANGEL_AGENT_USER'."
    fi

    archangel_run_as_agent systemctl --user daemon-reload || {
        say "Could not reload '$ARCHANGEL_AGENT_USER' user services; dashboard control may need to be retried later."
        return 0
    }

    if archangel_run_as_agent systemctl --user is-enabled hermes-dashboard.service >/dev/null 2>&1; then
        was_enabled=yes
    fi

    if yes_no "Run the Hermes web dashboard persistently on this machine?" N; then
        if ! loginctl show-user "$ARCHANGEL_AGENT_USER" -p Linger --value 2>/dev/null | grep -qx yes; then
            if yes_no "Persistent dashboard requires systemd linger. Enable linger for '$ARCHANGEL_AGENT_USER' now?" Y; then
                archangel_prepare_user_systemd yes || {
                    say "Could not prepare linger; leaving the dashboard installed for manual start/stop."
                    return 0
                }
            else
                say "Dashboard service installed but not enabled persistently."
                return 0
            fi
        fi

        archangel_run_as_agent systemctl --user enable --now hermes-dashboard.service
        [[ "$was_enabled" == no ]] && ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL=yes
        ARCHANGEL_DASHBOARD_PERSISTENT=yes
        say "Hermes dashboard is running persistently at http://127.0.0.1:9119"
    else
        say "Dashboard service installed but left disabled. Run 'archangel-dashboard' whenever you want it."
    fi
}

if [[ -e "$CONFIG_FILE" || -e "$INSTALL_STATE" ]]; then
    die "Archangel already appears to be installed. Run ./uninstall.sh before changing the configured agent account."
fi
if [[ -d "$STATE_DIR" ]] && find "$STATE_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    die "$STATE_DIR contains existing state without installation metadata; inspect or remove it before installing"
fi

say "Archangel bootstrap"
say "This creates an isolated Linux account, installs Hermes if requested, discovers"
say "services the agent may use, and installs local access-management tools."
say

caller=${ARCHANGEL_CALLER:-}
if [[ -z "$caller" || "$caller" == root ]] || ! getent passwd "$caller" >/dev/null; then caller=$(logname 2>/dev/null || true); fi
if [[ -z "$caller" || "$caller" == root ]] || ! getent passwd "$caller" >/dev/null; then caller=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd); fi
[[ -n "$caller" ]] || die "could not determine the human/owner account"

say "[1/6] Agent account"
owner_user=$(ask "Human account whose files may be shared with the agent" "$caller")
getent passwd "$owner_user" >/dev/null || die "user '$owner_user' does not exist"
[[ "$owner_user" != root ]] || die "root cannot be used as the human owner account"
agent_user=$(ask "Unix account to run the agent" "hermes")
valid_username "$agent_user" || die "'$agent_user' is not a valid simple Unix username"
[[ "$agent_user" != root ]] || die "root cannot be used as the Archangel agent account"
[[ "$agent_user" != "$owner_user" ]] || die "agent and owner accounts must be different"
agent_comment=$(ask "Account description" "Archangel agent")

install_acl_package
command -v runuser >/dev/null 2>&1 || die "runuser is required (normally provided by util-linux)"

agent_created=no
if getent passwd "$agent_user" >/dev/null; then
    say "User '$agent_user' already exists."
    yes_no "Use the existing account?" N || die "choose another agent username and rerun"
else
    say "Creating '$agent_user' with its own home directory..."
    useradd -m -s /bin/bash -c "$agent_comment" "$agent_user"
    agent_created=yes
fi

check_agent_sudo_privileges "$agent_user"

journal_was_member=no
journal_enabled=no
if getent group systemd-journal >/dev/null 2>&1; then
    if in_group "$agent_user" systemd-journal; then
        journal_was_member=yes; journal_enabled=yes
        say "'$agent_user' already has systemd journal access; preserving that pre-existing membership."
    elif yes_no "Allow '$agent_user' to read the systemd journal for diagnostics?" Y; then
        usermod -aG systemd-journal "$agent_user"; journal_enabled=yes
    fi
else
    say "No systemd-journal group found; skipping journal group setup."
fi

install -d -m 0750 "$STATE_DIR" "$STATE_DIR/grants" "$STATE_DIR/traversal"
: > "$STATE_DIR/grants.tsv"
: > "$STATE_DIR/traversal.tsv"
chmod 0640 "$STATE_DIR/grants.tsv" "$STATE_DIR/traversal.tsv"
ARCHANGEL_AGENT_USER="$agent_user"
ARCHANGEL_OWNER_USER="$owner_user"
ARCHANGEL_SERVICES_FILE="$STATE_DIR/services.tsv"
archangel_services_init

cat > "$CONFIG_FILE" <<CFG
# Generated by Archangel install.sh
ARCHANGEL_AGENT_USER='$agent_user'
ARCHANGEL_OWNER_USER='$owner_user'
CFG
chmod 0644 "$CONFIG_FILE"

say
say "[2/6] Archangel tools"
install -d -m 0755 /usr/local/lib/archangel
install -m 0644 "$SCRIPT_DIR/lib/archangel/"*.sh /usr/local/lib/archangel/
install -m 0755 "$SCRIPT_DIR/bin/archangel-access" /usr/local/bin/archangel-access
install -m 0755 "$SCRIPT_DIR/bin/archangel-dashboard" /usr/local/bin/archangel-dashboard
install -m 0755 "$SCRIPT_DIR/bin/archangel-diagnostic" /usr/local/bin/archangel-diagnostic
install -m 0755 "$SCRIPT_DIR/bin/archangel-hermes" /usr/local/bin/archangel-hermes
install -m 0755 "$SCRIPT_DIR/bin/archangel-services" /usr/local/bin/archangel-services
install -m 0755 "$SCRIPT_DIR/uninstall.sh" /usr/local/bin/archangel-uninstall

say
say "[3/6] Hermes Agent"
ARCHANGEL_HERMES_INSTALLED=no
ARCHANGEL_HERMES_BIN=
ARCHANGEL_HERMES_HOME="$(archangel_agent_home)/.hermes"
ARCHANGEL_LINGER_ENABLED_BY_ARCHANGEL=no
ARCHANGEL_DASHBOARD_UNIT_CREATED=no
ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL=no
ARCHANGEL_DASHBOARD_PERSISTENT=no
archangel_install_hermes || say "Hermes installation reported an error; Archangel setup can continue."

if [[ -n "${ARCHANGEL_HERMES_BIN:-}" && -d /run/systemd/system ]]; then
    linger_choice=no
    if yes_no "Allow Hermes user services for '$agent_user' to keep running while logged out?" Y; then
        linger_choice=yes
    fi
    if archangel_prepare_user_systemd "$linger_choice"; then
        install_dashboard_service
    else
        say "Hermes is installed, but its user systemd service manager is not ready yet."
        say "The dashboard can still be launched directly with 'archangel-hermes dashboard'."
    fi
fi

cat > "$INSTALL_STATE" <<CFG
# Generated by Archangel install.sh
ARCHANGEL_INSTALLED_AGENT_USER='$agent_user'
ARCHANGEL_INSTALLED_OWNER_USER='$owner_user'
ARCHANGEL_AGENT_CREATED='$agent_created'
ARCHANGEL_JOURNAL_WAS_MEMBER='$journal_was_member'
ARCHANGEL_ACL_INSTALLED_BY_ARCHANGEL='$acl_installed_by_archangel'
ARCHANGEL_HERMES_INSTALLED='${ARCHANGEL_HERMES_INSTALLED:-unknown}'
ARCHANGEL_HERMES_BIN='${ARCHANGEL_HERMES_BIN:-}'
ARCHANGEL_HERMES_HOME='${ARCHANGEL_HERMES_HOME:-}'
ARCHANGEL_LINGER_ENABLED_BY_ARCHANGEL='${ARCHANGEL_LINGER_ENABLED_BY_ARCHANGEL:-no}'
ARCHANGEL_DASHBOARD_UNIT_CREATED='${ARCHANGEL_DASHBOARD_UNIT_CREATED:-no}'
ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL='${ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL:-no}'
ARCHANGEL_DASHBOARD_PERSISTENT='${ARCHANGEL_DASHBOARD_PERSISTENT:-no}'
CFG
chmod 0640 "$INSTALL_STATE"

say
say "[4/6] Service discovery"
if yes_no "Run the Archangel service-discovery wizard now?" Y; then
    archangel_discovery_wizard
else
    say "Discovery skipped. Run 'sudo archangel-services discover' whenever you want."
fi

say
say "[5/6] Hermes service integration"
if [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]]; then
    archangel_apply_service_config
else
    say "Hermes is not currently installed. Service selections remain saved for later."
fi

say
say "[6/6] Hermes setup and diagnostics"
archangel_finish_hermes_setup

say
say "Installed:"
say "  /usr/local/bin/archangel-access"
say "  /usr/local/bin/archangel-dashboard"
say "  /usr/local/bin/archangel-diagnostic"
say "  /usr/local/bin/archangel-hermes"
say "  /usr/local/bin/archangel-services"
say "  /usr/local/bin/archangel-uninstall"
say "  /usr/local/lib/archangel"
say "  $CONFIG_FILE"
say "  $STATE_DIR"
say
say "Agent account: $agent_user"
say "Owner account: $owner_user"
say "Agent account created by Archangel: $agent_created"
say "Journal access: $journal_enabled"
say "Hermes installed by Archangel: ${ARCHANGEL_HERMES_INSTALLED:-unknown}"
say "Systemd linger enabled by Archangel: ${ARCHANGEL_LINGER_ENABLED_BY_ARCHANGEL:-no}"
if [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]]; then
    say "Hermes executable: $ARCHANGEL_HERMES_BIN"
    say "Hermes dashboard persistent: ${ARCHANGEL_DASHBOARD_PERSISTENT:-no}"
fi
say
say "What to do next"
say "---------------"
say "Archangel:"
say "  sudo archangel-access status"
say "      Review the agent's filesystem access."
say "  sudo archangel-services status"
say "      Review saved/discovered services."
say "  sudo archangel-services discover"
say "      Add or change services later."
say "  sudo -u $agent_user -H archangel-diagnostic"
say "      Run the read-only host diagnostic as the agent."
if [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]]; then
    say
    say "Hermes dashboard:"
    say "  archangel-dashboard"
say "      Start the local dashboard and open it in your default browser."
    say "  archangel-dashboard stop"
say "      Stop the dashboard."
    say "  archangel-dashboard status"
say "      Check whether the dashboard is running."
    [[ "${ARCHANGEL_DASHBOARD_PERSISTENT:-no}" == yes ]] && \
        say "  Persistent dashboard: http://127.0.0.1:9119"
    say
    say "Hermes (runs as '$agent_user' through Archangel):"
    say "  archangel-hermes"
    say "      Start an interactive terminal chat with the agent."
    say "  archangel-hermes chat -q \"Inspect this system and report anything actionable.\""
    say "      Run a single agent task without entering interactive chat."
    say "  archangel-hermes setup"
    say "      Continue or rerun the full Hermes setup wizard."
    say "  archangel-hermes model"
    say "      Choose or change the model/provider."
    say "  archangel-hermes memory setup"
say "      Configure Hermes memory, including Honcho when desired."
    say "  archangel-hermes gateway install"
say "      Install/configure the Hermes messaging and cron gateway service."
fi
say
say "To share a config tree later:"
say "  sudo archangel-access grant rw /home/$owner_user/.config/hypr"
say
say "To remove Archangel cleanly:"
say "  sudo archangel-uninstall"
say
say "See docs/first-task.md for a cautious first agent task."
