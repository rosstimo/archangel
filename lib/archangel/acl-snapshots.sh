snapshot_acl() {
    local path=$1 snapshot=$2
    getfacl -p -- "$path" \
        | sed -e '/^# owner:/d' -e '/^# group:/d' -e '/^# flags:/d' \
        > "$snapshot"
    chmod 0600 "$snapshot"
}

snapshot_item_if_new() {
    local grant_dir=$1 path=$2 manifest="$grant_dir/manifest.tsv" next snapshot
    if ! valid_path_text "$path"; then
        warn "cannot manage a path containing a tab or newline"
        return 1
    fi
    if awk -F '\t' -v p="$path" '$2 == p {found=1} END {exit !found}' "$manifest"; then
        return 0
    fi
    next=$(printf '%08d' "$(( $(wc -l < "$manifest") + 1 ))")
    snapshot="$grant_dir/$next.acl"
    snapshot_acl "$path" "$snapshot"
    printf '%s\t%s\n' "$next" "$path" >> "$manifest"
}

snapshot_tree_new_items() {
    local grant_dir=$1 root=$2 item
    if [[ -d "$root" ]]; then
        while IFS= read -r -d '' item; do
            snapshot_item_if_new "$grant_dir" "$item" || return 1
        done < <(find "$root" \( -type d -o -type f \) -print0)
    elif [[ -f "$root" ]]; then
        snapshot_item_if_new "$grant_dir" "$root" || return 1
    else
        die "only regular files and directories are supported"
    fi
}

restore_grant_snapshots() {
    local grant_dir=$1 num path snapshot failures=0
    while IFS=$'\t' read -r num path; do
        [[ -n ${num:-} ]] || continue
        [[ -e "$path" ]] || continue
        snapshot="$grant_dir/$num.acl"
        if ! setfacl --restore="$snapshot"; then
            warn "failed restoring ACL for $path"
            failures=1
        fi
    done < "$grant_dir/manifest.tsv"
    return "$failures"
}

apply_acl_to_item() {
    local mode=$1 item=$2 dir_perm file_perm exec_perm
    case "$mode" in
        ro)
            dir_perm='r-x'
            file_perm='r--'
            exec_perm='r-x'
            ;;
        rw)
            dir_perm='rwx'
            file_perm='rw-'
            exec_perm='rwx'
            ;;
        *) die "mode must be 'ro' or 'rw'" ;;
    esac

    if [[ -d "$item" ]]; then
        setfacl -m "u:${ARCHANGEL_AGENT_USER}:${dir_perm}" -- "$item"
    elif [[ -f "$item" ]]; then
        if [[ -x "$item" ]]; then
            setfacl -m "u:${ARCHANGEL_AGENT_USER}:${exec_perm}" -- "$item"
        else
            setfacl -m "u:${ARCHANGEL_AGENT_USER}:${file_perm}" -- "$item"
        fi
    fi
}

apply_grant_manifest() {
    local mode=$1 grant_dir=$2 num item
    while IFS=$'\t' read -r num item; do
        [[ -n ${num:-} ]] || continue
        [[ -e "$item" ]] || continue
        apply_acl_to_item "$mode" "$item" || return 1
    done < "$grant_dir/manifest.tsv"
}
