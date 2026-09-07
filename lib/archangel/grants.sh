have_recovery_state() {
    local dir id
    for dir in "$GRANT_STATE_DIR"/g-*; do
        [[ -d "$dir" ]] || continue
        id=${dir##*/}
        if ! awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$GRANTS_FILE"; then
            return 0
        fi
    done
    return 1
}

record_grant() {
    local id=$1 mode=$2 path=$3
    printf '%s\t%s\t%s\n' "$id" "$mode" "$path" >> "$GRANTS_FILE"
}

update_grant_mode() {
    local id=$1 mode=$2 tmp
    tmp=$(mktemp "$STATE_DIR/.grants.XXXXXX")
    awk -F '\t' -v OFS='\t' -v id="$id" -v mode="$mode" '
        $1 == id {$2=mode}
        {print}
    ' "$GRANTS_FILE" > "$tmp"
    mv "$tmp" "$GRANTS_FILE"
}

remove_grant_record() {
    local id=$1 tmp
    tmp=$(mktemp "$STATE_DIR/.grants.XXXXXX")
    awk -F '\t' -v id="$id" '$1 != id' "$GRANTS_FILE" > "$tmp"
    mv "$tmp" "$GRANTS_FILE"
}

create_grant() {
    local mode=$1 path=$2 id grant_dir deps_file
    id="g-$(new_id)"
    grant_dir="$GRANT_STATE_DIR/$id"
    deps_file="$grant_dir/parents.tsv"
    install -d -m 0700 "$grant_dir"
    : > "$grant_dir/manifest.tsv"
    : > "$deps_file"
    chmod 0600 "$grant_dir/manifest.tsv" "$deps_file"

    if ! snapshot_tree_new_items "$grant_dir" "$path"; then
        rm -rf "$grant_dir"
        return 1
    fi

    if ! acquire_parent_traversal "$path" "$deps_file"; then
        warn "could not establish parent traversal; attempting rollback"
        if release_grant_parents "$deps_file"; then
            rm -rf "$grant_dir"
            return 1
        fi
        RECOVERY_DIR="$grant_dir"
        warn "rollback was incomplete; recovery state was retained at $grant_dir"
        return 2
    fi

    if ! apply_grant_manifest "$mode" "$grant_dir"; then
        local rollback_failed=0
        warn "grant failed; attempting to restore original ACL state"
        restore_grant_snapshots "$grant_dir" || rollback_failed=1
        release_grant_parents "$deps_file" || rollback_failed=1
        if (( rollback_failed != 0 )); then
            RECOVERY_DIR="$grant_dir"
            warn "rollback was incomplete; recovery state was retained at $grant_dir"
            return 2
        fi
        rm -rf "$grant_dir"
        return 1
    fi

    record_grant "$id" "$mode" "$path"
}

sync_grant_id() {
    local id=$1 new_mode=${2:-} path mode grant_dir
    path=$(grant_path_for_id "$id")
    mode=$(grant_mode_for_id "$id")
    [[ -n "$path" && -n "$mode" ]] || die "managed grant state is incomplete for $id"
    grant_dir="$GRANT_STATE_DIR/$id"
    [[ -d "$grant_dir" ]] || die "missing state directory for $path"

    snapshot_tree_new_items "$grant_dir" "$path"

    if [[ -n "$new_mode" && "$new_mode" != "$mode" ]]; then
        if apply_grant_manifest "$new_mode" "$grant_dir"; then
            update_grant_mode "$id" "$new_mode"
        else
            warn "mode change failed; attempting to restore the previous managed mode"
            apply_grant_manifest "$mode" "$grant_dir" || warn "could not fully restore previous managed mode; inspect this grant manually"
            return 1
        fi
    else
        apply_grant_manifest "$mode" "$grant_dir"
    fi
}

revoke_grant_id() {
    local id=$1 path grant_dir deps_file
    path=$(grant_path_for_id "$id")
    [[ -n "$path" ]] || die "unknown managed grant id $id"
    grant_dir="$GRANT_STATE_DIR/$id"
    deps_file="$grant_dir/parents.tsv"
    [[ -d "$grant_dir" ]] || die "missing state directory for $path"

    restore_grant_snapshots "$grant_dir" || return 1
    release_grant_parents "$deps_file" || return 1
    remove_grant_record "$id"
    rm -rf "$grant_dir"
}
