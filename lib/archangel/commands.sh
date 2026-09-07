cmd_status() {
    local id mode path
    printf 'Archangel access status\n\n'
    printf 'Agent user: %s\n' "$ARCHANGEL_AGENT_USER"
    printf 'Owner user: %s\n' "$ARCHANGEL_OWNER_USER"
    printf 'Identity:   '
    id "$ARCHANGEL_AGENT_USER"
    printf 'Journal:    '
    if id -nG "$ARCHANGEL_AGENT_USER" | tr ' ' '\n' | grep -qx systemd-journal; then
        printf 'enabled\n'
    else
        printf 'not enabled\n'
    fi

    printf '\nManaged grants:\n'
    if [[ -s "$GRANTS_FILE" ]]; then
        while IFS=$'\t' read -r id mode path; do
            printf '  %-2s  %s\n' "${mode^^}" "$path"
        done < "$GRANTS_FILE"
    else
        printf '  (none)\n'
    fi

    printf '\nManaged traversal ACLs:\n'
    if [[ -s "$TRAVERSAL_FILE" ]]; then
        awk -F '\t' '{printf "  X   refs=%s  %s\n", $2, $3}' "$TRAVERSAL_FILE"
    else
        printf '  (none)\n'
    fi

    printf '\nRecovery state:\n'
    if have_recovery_state; then
        printf '  INCOMPLETE ACL rollback present. Run: sudo archangel-access reset\n'
    else
        printf '  (none)\n'
    fi

    printf '\nSudo policy for %s:\n' "$ARCHANGEL_AGENT_USER"
    sudo -l -U "$ARCHANGEL_AGENT_USER" 2>&1 | sed 's/^/  /' || true
}

cmd_grant() {
    [[ $# -eq 2 ]] || die "grant requires <ro|rw> PATH"
    local mode=$1 path id old_mode
    [[ "$mode" == ro || "$mode" == rw ]] || die "mode must be 'ro' or 'rw'"
    have_recovery_state && die "incomplete ACL recovery state exists; run 'sudo archangel-access reset' before creating or changing grants"
    path=$(resolve_existing_path "$2")
    [[ "$path" != / ]] || die "refusing to manage ACLs recursively on /"
    reject_overlapping_grant "$path"

    id=$(grant_id_for_path "$path")
    if [[ -n "$id" ]]; then
        old_mode=$(grant_mode_for_id "$id")
        if [[ "$old_mode" == "$mode" ]]; then
            printf 'Refreshing %s grant for %s\n' "$mode" "$path"
        else
            printf 'Changing managed grant for %s from %s to %s\n' "$path" "$old_mode" "$mode"
        fi
        sync_grant_id "$id" "$mode" || die "could not update grant for $path"
    else
        printf 'Granting %s access to %s for %s\n' "$mode" "$path" "$ARCHANGEL_AGENT_USER"
        if ! create_grant "$mode" "$path"; then
            if [[ -n "$RECOVERY_DIR" ]]; then
                die "grant failed and rollback was incomplete; run 'sudo archangel-access reset' before continuing"
            fi
            die "grant failed; original ACL state was restored"
        fi
    fi
    printf 'Done. Verify with: sudo archangel-access check %q\n' "$path"
}

cmd_sync() {
    [[ $# -le 1 ]] || die "sync takes zero arguments or one managed PATH"
    local path id mode grant_path
    if [[ $# -eq 1 ]]; then
        path=$(resolve_existing_path "$1")
        id=$(grant_id_for_path "$path")
        [[ -n "$id" ]] || die "$path is not a managed Archangel grant"
        sync_grant_id "$id" || die "sync failed for $path"
        printf 'Synchronized managed access for %s\n' "$path"
        return
    fi

    while IFS=$'\t' read -r id mode grant_path; do
        [[ -n ${id:-} ]] || continue
        sync_grant_id "$id" || die "sync failed for $grant_path"
    done < "$GRANTS_FILE"
    printf 'Synchronized all managed grants.\n'
}

cmd_revoke() {
    [[ $# -eq 1 ]] || die "revoke requires PATH"
    local path id
    path=$(resolve_existing_path "$1")
    id=$(grant_id_for_path "$path")
    [[ -n "$id" ]] || die "$path is not a managed Archangel grant"
    if revoke_grant_id "$id"; then
        printf 'Revoked managed access to %s and restored its saved ACL state.\n' "$path"
    else
        die "revoke could not completely restore ACL state for $path; state was retained for retry"
    fi
}

cmd_reset() {
    [[ $# -eq 0 ]] || die "reset takes no arguments"
    local id mode path failures=0
    local pending
    pending=$(mktemp "$STATE_DIR/.reset.XXXXXX")
    cp "$GRANTS_FILE" "$pending"
    while IFS=$'\t' read -r id mode path; do
        [[ -n ${id:-} ]] || continue
        if ! revoke_grant_id "$id"; then
            warn "could not restore managed grant $path"
            failures=1
        fi
    done < "$pending"
    rm -f "$pending"

    local dir orphan_id
    for dir in "$GRANT_STATE_DIR"/g-*; do
        [[ -d "$dir" ]] || continue
        orphan_id=${dir##*/}
        if awk -F '\t' -v id="$orphan_id" '$1 == id {found=1} END {exit !found}' "$GRANTS_FILE"; then
            continue
        fi
        warn "recovering incomplete grant state from $dir"
        if restore_grant_snapshots "$dir" && release_grant_parents "$dir/parents.tsv"; then
            rm -rf "$dir"
        else
            warn "could not completely recover $dir"
            failures=1
        fi
    done

    if (( failures != 0 )); then
        die "reset incomplete; unresolved state remains under $STATE_DIR"
    fi
    if [[ -s "$TRAVERSAL_FILE" ]]; then
        die "reset left traversal state behind; inspect $TRAVERSAL_FILE before uninstalling"
    fi
    printf 'All managed filesystem ACL changes have been restored.\n'
}

cmd_check() {
    [[ $# -eq 1 ]] || die "check requires PATH"
    local path
    path=$(resolve_existing_path "$1")
    printf '%s\n\n' "$path"
    printf 'read:       '; as_agent_test -r "$path" && printf 'YES\n' || printf 'NO\n'
    printf 'write:      '; as_agent_test -w "$path" && printf 'YES\n' || printf 'NO\n'
    if [[ -d "$path" ]]; then
        printf 'traverse:   '; as_agent_test -x "$path" && printf 'YES\n' || printf 'NO\n'
        printf 'list dir:   '
        if runuser -u "$ARCHANGEL_AGENT_USER" -- ls -A -- "$path" >/dev/null 2>&1; then
            printf 'YES\n'
        else
            printf 'NO\n'
        fi
    else
        printf 'execute:    '; as_agent_test -x "$path" && printf 'YES\n' || printf 'NO\n'
    fi
}

cmd_audit() {
    [[ $# -ge 1 && $# -le 2 ]] || die "audit requires <read|write> [PATH]"
    local mode=$1 root=${2:-/} predicate
    root=$(resolve_existing_path "$root")
    case "$mode" in
        read) predicate='-readable' ;;
        write) predicate='-writable' ;;
        *) die "audit mode must be 'read' or 'write'" ;;
    esac

    if [[ "$root" == / ]]; then
        printf 'Note: skipping /proc, /sys, /dev, and /run in the system-wide audit.\n' >&2
        runuser -u "$ARCHANGEL_AGENT_USER" -- find / \
            \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
            "$predicate" -print 2>/dev/null
    else
        runuser -u "$ARCHANGEL_AGENT_USER" -- find "$root" "$predicate" -print 2>/dev/null
    fi
}

cmd_journal() {
    [[ $# -eq 1 ]] || die "journal requires enable or disable"
    getent group systemd-journal >/dev/null || die "systemd-journal group does not exist on this system"
    case "$1" in
        enable)
            usermod -aG systemd-journal "$ARCHANGEL_AGENT_USER"
            printf 'Journal access enabled. Existing agent processes must be restarted to receive the new group membership.\n'
            ;;
        disable)
            if id -nG "$ARCHANGEL_AGENT_USER" | tr ' ' '\n' | grep -qx systemd-journal; then
                gpasswd -d "$ARCHANGEL_AGENT_USER" systemd-journal >/dev/null
            fi
            printf 'Journal access disabled. Existing agent processes must be restarted to drop the group membership.\n'
            ;;
        *) die "journal requires enable or disable" ;;
    esac
}

main() {
    require_root
    command -v setfacl >/dev/null 2>&1 || die "setfacl not found; install the acl package"
    command -v getfacl >/dev/null 2>&1 || die "getfacl not found; install the acl package"
    command -v runuser >/dev/null 2>&1 || die "runuser not found"
    load_config
    ensure_state

    local command=${1:-help}
    shift || true
    case "$command" in
        status) [[ $# -eq 0 ]] || die "status takes no arguments"; cmd_status ;;
        grant) cmd_grant "$@" ;;
        sync) cmd_sync "$@" ;;
        revoke) cmd_revoke "$@" ;;
        reset) cmd_reset "$@" ;;
        check) cmd_check "$@" ;;
        audit) cmd_audit "$@" ;;
        journal) cmd_journal "$@" ;;
        help|-h|--help) usage ;;
        *) usage; die "unknown command: $command" ;;
    esac
}
