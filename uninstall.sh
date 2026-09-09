#!/usr/bin/env bash
set -euo pipefail

SELF=$(readlink -f -- "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
CONFIG_FILE=${ARCHANGEL_CONFIG:-/etc/archangel.conf}
STATE_DIR=${ARCHANGEL_STATE_DIR:-/var/lib/archangel}
INSTALL_STATE="$STATE_DIR/install.env"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo bash "$SELF" "$@"; fi

say() { printf '%s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }
yes_no() {
    local prompt=$1 default=${2:-Y} answer suffix
    [[ "$default" == Y ]] && suffix='Y/n' || suffix='y/N'
    read -r -p "$prompt [$suffix]: " answer </dev/tty
    answer=${answer:-$default}
    [[ "$answer" =~ ^[Yy]$ ]]
}
in_group() { id -nG "$1" | tr ' ' '\n' | grep -qx "$2"; }
print_acl_removal_hint() {
    if command -v pacman >/dev/null 2>&1; then say "    sudo pacman -Rns acl"
    elif command -v apt-get >/dev/null 2>&1; then say "    sudo apt-get remove acl"
    elif command -v dnf >/dev/null 2>&1; then say "    sudo dnf remove acl"
    elif command -v zypper >/dev/null 2>&1; then say "    sudo zypper remove acl"
    else say "    Remove the distro's 'acl' package with your package manager."
    fi
}

[[ -r "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE; cannot safely identify the configured agent account"
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${ARCHANGEL_AGENT_USER:?ARCHANGEL_AGENT_USER is not set}"
: "${ARCHANGEL_OWNER_USER:?ARCHANGEL_OWNER_USER is not set}"
[[ "$ARCHANGEL_AGENT_USER" != root ]] || die "refusing to uninstall with root configured as the agent account"

agent_created=unknown
journal_was_member=unknown
acl_installed_by_archangel=unknown
hermes_installed_by_archangel=unknown
linger_enabled_by_archangel=unknown
dashboard_unit_created=unknown
dashboard_enabled_by_archangel=unknown
hermes_bin=
hermes_home=
if [[ -r "$INSTALL_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$INSTALL_STATE"
    agent_created=${ARCHANGEL_AGENT_CREATED:-unknown}
    journal_was_member=${ARCHANGEL_JOURNAL_WAS_MEMBER:-unknown}
    acl_installed_by_archangel=${ARCHANGEL_ACL_INSTALLED_BY_ARCHANGEL:-unknown}
    hermes_installed_by_archangel=${ARCHANGEL_HERMES_INSTALLED:-unknown}
    linger_enabled_by_archangel=${ARCHANGEL_LINGER_ENABLED_BY_ARCHANGEL:-unknown}
    dashboard_unit_created=${ARCHANGEL_DASHBOARD_UNIT_CREATED:-unknown}
    dashboard_enabled_by_archangel=${ARCHANGEL_DASHBOARD_ENABLED_BY_ARCHANGEL:-unknown}
    hermes_bin=${ARCHANGEL_HERMES_BIN:-}
    hermes_home=${ARCHANGEL_HERMES_HOME:-}
fi

agent_uid=unknown
agent_home=
if getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    agent_uid=$(id -u "$ARCHANGEL_AGENT_USER")
    agent_home=$(getent passwd "$ARCHANGEL_AGENT_USER" | cut -d: -f6)
fi

agent_systemctl() {
    [[ "$agent_uid" != unknown && -n "$agent_home" ]] || return 1
    local runtime="/run/user/$agent_uid" i
    if [[ ! -S "$runtime/bus" ]]; then
        systemctl start "user@$agent_uid.service" >/dev/null 2>&1 || true
        for ((i=0; i<25; i++)); do
            [[ -S "$runtime/bus" ]] && break
            sleep 0.2
        done
    fi
    [[ -S "$runtime/bus" ]] || return 1
    runuser -u "$ARCHANGEL_AGENT_USER" -- env \
        HOME="$agent_home" USER="$ARCHANGEL_AGENT_USER" LOGNAME="$ARCHANGEL_AGENT_USER" \
        PATH="$agent_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
        systemctl --user "$@"
}

access_tool=/usr/local/bin/archangel-access
if [[ ! -x "$access_tool" && -x "$SCRIPT_DIR/bin/archangel-access" ]]; then access_tool="$SCRIPT_DIR/bin/archangel-access"; fi
[[ -x "$access_tool" ]] || die "archangel-access is missing; restore it before uninstalling so ACL state can be safely reverted"

managed_roots=$(mktemp)
trap 'rm -f "$managed_roots"' EXIT
if [[ -r "$STATE_DIR/grants.tsv" ]]; then awk -F '\t' 'NF >= 3 {print $3}' "$STATE_DIR/grants.tsv" > "$managed_roots"; fi

say "Archangel uninstall"
say "Configured agent: $ARCHANGEL_AGENT_USER"
say
say "Restoring all filesystem ACLs changed by Archangel..."
"$access_tool" reset

if getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null && getent group systemd-journal >/dev/null 2>&1; then
    case "$journal_was_member" in
        yes)
            if ! in_group "$ARCHANGEL_AGENT_USER" systemd-journal; then
                say "Restoring pre-install systemd-journal membership."
                usermod -aG systemd-journal "$ARCHANGEL_AGENT_USER"
            fi
            ;;
        no)
            if in_group "$ARCHANGEL_AGENT_USER" systemd-journal; then
                say "Removing systemd-journal membership added after Archangel installation."
                gpasswd -d "$ARCHANGEL_AGENT_USER" systemd-journal >/dev/null
            fi
            ;;
        *) say "Installation metadata does not record prior journal membership; leaving group membership unchanged." ;;
    esac
fi

remove_agent=no
if [[ "$agent_created" == yes ]] && getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    yes_no "Remove the agent account '$ARCHANGEL_AGENT_USER' and its home directory?" Y && remove_agent=yes
elif [[ "$agent_created" == no ]]; then
    say "The agent account existed before Archangel, so it will be preserved."
elif getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    say "Archangel cannot prove it created the agent account, so it will be preserved."
fi

if [[ "$remove_agent" == yes ]]; then
    owned_count=0
    while IFS= read -r root; do
        [[ -n "$root" && -e "$root" ]] || continue
        while IFS= read -r -d '' item; do ((owned_count += 1)); done < <(find "$root" -user "$ARCHANGEL_AGENT_USER" -print0 2>/dev/null)
    done < "$managed_roots"
    if (( owned_count > 0 )); then
        say "Found $owned_count item(s) owned by '$ARCHANGEL_AGENT_USER' in previously managed trees."
        if yes_no "Reassign those items to '$ARCHANGEL_OWNER_USER' before removing the agent account?" Y; then
            while IFS= read -r root; do
                [[ -n "$root" && -e "$root" ]] || continue
                find "$root" -user "$ARCHANGEL_AGENT_USER" -exec chown "$ARCHANGEL_OWNER_USER" -- {} +
            done < "$managed_roots"
        else
            say "Keeping '$ARCHANGEL_AGENT_USER' to avoid orphaning those files."
            remove_agent=no
        fi
    fi
fi

# Dashboard service provenance is independent of Hermes runtime provenance. If
# Archangel created the user unit, remove it. If the unit pre-existed but
# Archangel enabled it persistently, restore that enablement state by disabling
# it while leaving the user's unit file untouched.
if getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null && [[ -n "$agent_home" ]]; then
    dashboard_unit="$agent_home/.config/systemd/user/hermes-dashboard.service"
    if [[ "$dashboard_unit_created" == yes ]]; then
        say "Removing the Hermes dashboard user service created by Archangel."
        agent_systemctl disable --now hermes-dashboard.service >/dev/null 2>&1 || true
        rm -f "$dashboard_unit"
        agent_systemctl daemon-reload >/dev/null 2>&1 || true
    elif [[ "$dashboard_enabled_by_archangel" == yes ]]; then
        say "Disabling the pre-existing Hermes dashboard service that Archangel enabled."
        agent_systemctl disable --now hermes-dashboard.service >/dev/null 2>&1 || \
            say "Could not disable the dashboard service automatically; inspect it manually."
    fi
fi

# If Archangel installed Hermes and the account is being preserved, offer to
# remove only the Hermes runtime. Upstream `hermes uninstall --yes` keeps user
# configuration/data unless --full is requested, which Archangel never assumes.
if [[ "$remove_agent" == no && "$hermes_installed_by_archangel" == yes ]] && getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    if [[ -z "$hermes_bin" || ! -x "$hermes_bin" ]]; then
        [[ -x "$agent_home/.local/bin/hermes" ]] && hermes_bin="$agent_home/.local/bin/hermes"
        [[ -z "$hermes_bin" && -x "$agent_home/.hermes/hermes-agent/venv/bin/hermes" ]] && hermes_bin="$agent_home/.hermes/hermes-agent/venv/bin/hermes"
    fi
    if [[ -n "$hermes_bin" && -x "$hermes_bin" ]] && yes_no "Remove the Hermes runtime that Archangel installed?" Y; then
        runuser -u "$ARCHANGEL_AGENT_USER" -- env HOME="$agent_home" USER="$ARCHANGEL_AGENT_USER" LOGNAME="$ARCHANGEL_AGENT_USER" \
            PATH="$agent_home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$hermes_bin" uninstall --yes || \
            say "Hermes uninstaller reported an error; its files were left for manual review."
    fi
fi

linger_left_enabled=no
if [[ "$linger_enabled_by_archangel" == yes ]] && getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null && command -v loginctl >/dev/null 2>&1; then
    if [[ "$remove_agent" == yes ]]; then
        say "Disabling systemd linger that Archangel enabled for '$ARCHANGEL_AGENT_USER'."
        loginctl disable-linger "$ARCHANGEL_AGENT_USER" || \
            say "Could not disable systemd linger; inspect it manually after uninstall."
    elif [[ -e "/var/lib/systemd/linger/$ARCHANGEL_AGENT_USER" ]]; then
        if yes_no "Disable systemd linger that Archangel enabled for the preserved account '$ARCHANGEL_AGENT_USER'?" N; then
            loginctl disable-linger "$ARCHANGEL_AGENT_USER" || \
                say "Could not disable systemd linger; leaving it for manual review."
        else
            linger_left_enabled=yes
        fi
    fi
fi

if [[ "$remove_agent" == yes ]]; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$ARCHANGEL_AGENT_USER" >/dev/null 2>&1; then
        yes_no "Terminate processes still running as '$ARCHANGEL_AGENT_USER'?" Y || die "cannot remove an account while its processes are intentionally left running"
        pkill -TERM -u "$ARCHANGEL_AGENT_USER" 2>/dev/null || true
        sleep 1
        pkill -KILL -u "$ARCHANGEL_AGENT_USER" 2>/dev/null || true
    fi
    userdel -r "$ARCHANGEL_AGENT_USER"
fi

rm -f /usr/local/bin/archangel-access
rm -f /usr/local/bin/archangel-dashboard
rm -f /usr/local/bin/archangel-diagnostic
rm -f /usr/local/bin/archangel-hermes
rm -f /usr/local/bin/archangel-services
rm -f /usr/local/bin/archangel-status
rm -f /usr/local/bin/archangel-uninstall
rm -rf /usr/local/lib/archangel
rm -f "$CONFIG_FILE"
rm -rf "$STATE_DIR"

say
say "Archangel system files and managed ACL changes have been removed."
if [[ "$remove_agent" == yes ]]; then
    say "The Archangel-created agent account and home directory were also removed."
elif getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null 2>&1; then
    say "The agent account remains by design; it was pre-existing or you chose to keep it."
fi

say
say "What may remain"
say "---------------"
say "Archangel intentionally does not remove things it did not install or cannot prove it owns."
say

if getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null 2>&1; then
    say "- Agent account: '$ARCHANGEL_AGENT_USER' (UID $agent_uid) remains."
    say "  If you intentionally want to delete that account and its home directory:"
    say "    sudo userdel -r '$ARCHANGEL_AGENT_USER'"
    say
fi

if [[ "$linger_left_enabled" == yes ]]; then
    say "- systemd linger: remains enabled for '$ARCHANGEL_AGENT_USER' because you chose to preserve it."
    say "  To disable it later:"
    say "    sudo loginctl disable-linger '$ARCHANGEL_AGENT_USER'"
    say
fi

case "$acl_installed_by_archangel" in
    yes)
        say "- ACL package: Archangel installed the distro's 'acl' package and left it installed."
        say "  If nothing else on this machine needs POSIX ACL tools, you may remove it manually:"
        print_acl_removal_hint; say
        ;;
    no) say "- ACL package: it was already present before Archangel and was left unchanged."; say ;;
    *) say "- ACL package: installation metadata cannot prove its origin, so it was left untouched."; say ;;
esac

if [[ "$hermes_installed_by_archangel" == no ]]; then
    say "- Hermes: it was not installed by Archangel and was left untouched."
    say
elif [[ "$hermes_installed_by_archangel" == yes && "$remove_agent" == no && -n "$hermes_home" && -d "$hermes_home" ]]; then
    say "- Hermes data/configuration may remain at $hermes_home. The upstream runtime uninstaller keeps"
    say "  user data unless explicitly asked for a full removal."
    say
fi

say "- Source checkout: the Git clone or source directory used to install Archangel is not removed."
say "  Delete that directory manually if you no longer want the source tree."
say

if [[ "$agent_uid" != unknown ]]; then
    say "- Files outside Archangel-managed grant trees: uninstall does not perform a whole-system ownership scan."
    say "  To find files still owned by the agent UID ($agent_uid), you can run:"
    say "    sudo find / \\( -path /proc -o -path /sys -o -path /dev -o -path /run \\) -prune -o -uid $agent_uid -print 2>/dev/null"
    say
fi

say "- Discovered LAN/VPN services, containers, models, and software that Archangel did not install are untouched."
say "Nothing listed above is required for Archangel itself to remain uninstalled."
