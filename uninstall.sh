#!/usr/bin/env bash
set -euo pipefail

SELF=$(readlink -f -- "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SELF")" && pwd)
CONFIG_FILE=${ARCHANGEL_CONFIG:-/etc/archangel.conf}
STATE_DIR=${ARCHANGEL_STATE_DIR:-/var/lib/archangel}
INSTALL_STATE="$STATE_DIR/install.env"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo bash "$SELF" "$@"
fi

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'uninstall.sh: %s\n' "$*" >&2
    exit 1
}

yes_no() {
    local prompt=$1 default=${2:-Y} answer suffix
    if [[ "$default" == Y ]]; then suffix='Y/n'; else suffix='y/N'; fi
    read -r -p "$prompt [$suffix]: " answer </dev/tty
    answer=${answer:-$default}
    [[ "$answer" =~ ^[Yy]$ ]]
}

in_group() {
    local user=$1 group=$2
    id -nG "$user" | tr ' ' '\n' | grep -qx "$group"
}

[[ -r "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE; cannot safely identify the configured agent account"
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${ARCHANGEL_AGENT_USER:?ARCHANGEL_AGENT_USER is not set}"
: "${ARCHANGEL_OWNER_USER:?ARCHANGEL_OWNER_USER is not set}"
[[ "$ARCHANGEL_AGENT_USER" != root ]] || die "refusing to uninstall with root configured as the agent account"

agent_created=unknown
journal_was_member=unknown
if [[ -r "$INSTALL_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$INSTALL_STATE"
    agent_created=${ARCHANGEL_AGENT_CREATED:-unknown}
    journal_was_member=${ARCHANGEL_JOURNAL_WAS_MEMBER:-unknown}
fi

access_tool=/usr/local/bin/archangel-access
if [[ ! -x "$access_tool" && -x "$SCRIPT_DIR/bin/archangel-access" ]]; then
    access_tool="$SCRIPT_DIR/bin/archangel-access"
fi
[[ -x "$access_tool" ]] || die "archangel-access is missing; restore it before uninstalling so ACL state can be safely reverted"

managed_roots=$(mktemp)
trap 'rm -f "$managed_roots"' EXIT
if [[ -r "$STATE_DIR/grants.tsv" ]]; then
    awk -F '\t' 'NF >= 3 {print $3}' "$STATE_DIR/grants.tsv" > "$managed_roots"
fi

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
        *)
            say "Installation metadata does not record prior journal membership; leaving group membership unchanged."
            ;;
    esac
fi

remove_agent=no
if [[ "$agent_created" == yes ]] && getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    if yes_no "Remove the agent account '$ARCHANGEL_AGENT_USER' and its home directory?" Y; then
        remove_agent=yes
    fi
elif [[ "$agent_created" == no ]]; then
    say "The agent account existed before Archangel, so it will be preserved."
elif getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null; then
    say "Archangel cannot prove it created the agent account, so it will be preserved."
fi

if [[ "$remove_agent" == yes ]]; then
    owned_count=0
    while IFS= read -r root; do
        [[ -n "$root" && -e "$root" ]] || continue
        while IFS= read -r -d '' item; do
            ((owned_count += 1))
        done < <(find "$root" -user "$ARCHANGEL_AGENT_USER" -print0 2>/dev/null)
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

if [[ "$remove_agent" == yes ]]; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$ARCHANGEL_AGENT_USER" >/dev/null 2>&1; then
        yes_no "Terminate processes still running as '$ARCHANGEL_AGENT_USER'?" Y \
            || die "cannot remove an account while its processes are intentionally left running"
        pkill -TERM -u "$ARCHANGEL_AGENT_USER" 2>/dev/null || true
        sleep 1
        pkill -KILL -u "$ARCHANGEL_AGENT_USER" 2>/dev/null || true
    fi
    userdel -r "$ARCHANGEL_AGENT_USER"
fi

rm -f /usr/local/bin/archangel-access
rm -f /usr/local/bin/archangel-diagnostic
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
