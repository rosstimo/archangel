usage() {
    cat <<'USAGE'
Usage:
  sudo archangel-access status
  sudo archangel-access grant <ro|rw> PATH
  sudo archangel-access sync [PATH]
  sudo archangel-access revoke PATH
  sudo archangel-access reset
  sudo archangel-access check PATH
  sudo archangel-access audit <read|write> [PATH]
  sudo archangel-access journal <enable|disable>

Archangel manages named POSIX ACL entries for the configured agent account.
Grant/revoke paths must already exist. Symlink arguments are resolved to their
target before access is changed.

Managed grants do not install default ACLs. If another user creates new files
inside a granted directory, run `archangel-access sync PATH` to include them.
Overlapping managed grant roots are rejected so every grant remains exactly
reversible.
USAGE
}

die() {
    printf 'archangel-access: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'archangel-access: warning: %s\n' "$*" >&2
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this command with sudo"
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE; run install.sh first"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    : "${ARCHANGEL_AGENT_USER:?ARCHANGEL_AGENT_USER is not set}"
    : "${ARCHANGEL_OWNER_USER:?ARCHANGEL_OWNER_USER is not set}"
    [[ "$ARCHANGEL_AGENT_USER" != root ]] || die "refusing to operate with root as the agent account"
    if [[ -r "$INSTALL_STATE" ]]; then
        local installed_agent
        installed_agent=$(awk -F "'" '/^ARCHANGEL_INSTALLED_AGENT_USER=/{print $2; exit}' "$INSTALL_STATE")
        if [[ -n "$installed_agent" && "$installed_agent" != "$ARCHANGEL_AGENT_USER" ]]; then
            die "configured agent account changed from '$installed_agent' to '$ARCHANGEL_AGENT_USER'; restore the original config and uninstall before changing accounts"
        fi
    fi
    getent passwd "$ARCHANGEL_AGENT_USER" >/dev/null || die "agent user '$ARCHANGEL_AGENT_USER' does not exist"
}

ensure_state() {
    install -d -m 0750 "$STATE_DIR" "$GRANT_STATE_DIR" "$TRAVERSAL_STATE_DIR"
    touch "$GRANTS_FILE" "$TRAVERSAL_FILE"
    chmod 0640 "$GRANTS_FILE" "$TRAVERSAL_FILE"
}

valid_path_text() {
    local path=$1
    [[ "$path" != *$'\n'* && "$path" != *$'\t'* ]]
}

validate_path_text() {
    valid_path_text "$1" || die "paths containing tabs or newlines are not supported"
}

resolve_existing_path() {
    local input=$1
    validate_path_text "$input"
    realpath -e -- "$input" 2>/dev/null || die "path does not exist: $input"
}

as_agent_test() {
    local flag=$1 path=$2
    runuser -u "$ARCHANGEL_AGENT_USER" -- test "$flag" "$path"
}

new_id() {
    printf '%s-%s-%s' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "$RANDOM"
}

grant_id_for_path() {
    local path=$1
    awk -F '\t' -v p="$path" '$3 == p {print $1; exit}' "$GRANTS_FILE"
}

grant_mode_for_id() {
    local id=$1
    awk -F '\t' -v id="$id" '$1 == id {print $2; exit}' "$GRANTS_FILE"
}

grant_path_for_id() {
    local id=$1
    awk -F '\t' -v id="$id" '$1 == id {print $3; exit}' "$GRANTS_FILE"
}

paths_overlap() {
    local a=$1 b=$2
    [[ "$a" == "$b" || "$a" == "$b/"* || "$b" == "$a/"* ]]
}

reject_overlapping_grant() {
    local path=$1 id mode existing
    while IFS=$'\t' read -r id mode existing; do
        [[ -n ${id:-} ]] || continue
        [[ "$existing" == "$path" ]] && continue
        if paths_overlap "$path" "$existing"; then
            die "grant root overlaps existing managed grant '$existing'; revoke it or choose a non-overlapping path"
        fi
    done < "$GRANTS_FILE"
}
