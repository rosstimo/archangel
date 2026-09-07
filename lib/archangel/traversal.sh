traversal_row_for_path() {
    local path=$1
    awk -F '\t' -v p="$path" '$3 == p {print; exit}' "$TRAVERSAL_FILE"
}

update_traversal_refs() {
    local id=$1 new_refs=$2 tmp
    tmp=$(mktemp "$STATE_DIR/.traversal.XXXXXX")
    awk -F '\t' -v OFS='\t' -v id="$id" -v refs="$new_refs" '
        $1 == id {$2=refs}
        {print}
    ' "$TRAVERSAL_FILE" > "$tmp"
    mv "$tmp" "$TRAVERSAL_FILE"
}

acquire_parent() {
    local parent=$1 deps_file=$2 row id refs path snapshot
    row=$(traversal_row_for_path "$parent")
    if [[ -n "$row" ]]; then
        IFS=$'\t' read -r id refs path <<< "$row"
        update_traversal_refs "$id" "$((refs + 1))"
        printf '%s\t%s\n' "$id" "$parent" >> "$deps_file"
        return 0
    fi

    if as_agent_test -x "$parent"; then
        return 0
    fi

    id="t-$(new_id)"
    snapshot="$TRAVERSAL_STATE_DIR/$id.acl"
    snapshot_acl "$parent" "$snapshot"
    if ! setfacl -m "u:${ARCHANGEL_AGENT_USER}:--x" -- "$parent"; then
        rm -f "$snapshot"
        return 1
    fi
    printf '%s\t1\t%s\n' "$id" "$parent" >> "$TRAVERSAL_FILE"
    printf '%s\t%s\n' "$id" "$parent" >> "$deps_file"
}

acquire_parent_traversal() {
    local root=$1 deps_file=$2 current i
    local -a parents=()
    current=$(dirname -- "$root")
    while [[ "$current" != / ]]; do
        parents+=("$current")
        current=$(dirname -- "$current")
    done
    for ((i=${#parents[@]} - 1; i>=0; i--)); do
        acquire_parent "${parents[$i]}" "$deps_file"
    done
}

release_grant_parents() {
    local deps_file=$1 id parent row refs row_path snapshot tmp current_refs
    [[ -s "$deps_file" ]] || return 0

    # Restore every parent whose reference count will reach zero before changing
    # the bookkeeping. This keeps a failed revoke retryable.
    while IFS=$'\t' read -r id parent; do
        [[ -n ${id:-} ]] || continue
        row=$(awk -F '\t' -v id="$id" '$1 == id {print; exit}' "$TRAVERSAL_FILE")
        [[ -n "$row" ]] || { warn "missing traversal state for $parent"; return 1; }
        IFS=$'\t' read -r _ refs row_path <<< "$row"
        [[ "$row_path" == "$parent" ]] || { warn "traversal state mismatch for $parent"; return 1; }
        if (( refs == 1 )) && [[ -e "$parent" ]]; then
            snapshot="$TRAVERSAL_STATE_DIR/$id.acl"
            if ! setfacl --restore="$snapshot"; then
                warn "failed restoring traversal ACL for $parent"
                return 1
            fi
        fi
    done < "$deps_file"

    tmp=$(mktemp "$STATE_DIR/.traversal.XXXXXX")
    cp "$TRAVERSAL_FILE" "$tmp"
    while IFS=$'\t' read -r id parent; do
        [[ -n ${id:-} ]] || continue
        row=$(awk -F '\t' -v id="$id" '$1 == id {print; exit}' "$tmp")
        IFS=$'\t' read -r _ current_refs row_path <<< "$row"
        if (( current_refs > 1 )); then
            awk -F '\t' -v OFS='\t' -v id="$id" -v refs="$((current_refs - 1))" '
                $1 == id {$2=refs}
                {print}
            ' "$tmp" > "$tmp.next"
        else
            awk -F '\t' -v id="$id" '$1 != id' "$tmp" > "$tmp.next"
            rm -f "$TRAVERSAL_STATE_DIR/$id.acl"
        fi
        mv "$tmp.next" "$tmp"
    done < "$deps_file"
    mv "$tmp" "$TRAVERSAL_FILE"
}
