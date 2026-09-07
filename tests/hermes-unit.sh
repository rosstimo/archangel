#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

agent_home="$tmp/agent-home"
outside="$tmp/human-checkout"
mkdir -p "$agent_home" "$outside"

ARCHANGEL_AGENT_USER=testagent
STATE_DIR="$tmp/state"

say() { :; }
ask() { printf '%s' "${2:-}"; }
yes_no() { return 1; }

# Keep this test unprivileged: emulate the two system lookups used by
# archangel_run_as_agent while still executing the exact env/bash wrapper.
getent() {
    if [[ ${1:-} == passwd && ${2:-} == "$ARCHANGEL_AGENT_USER" ]]; then
        printf '%s:x:1001:1001:Test Agent:%s:/bin/bash\n' "$ARCHANGEL_AGENT_USER" "$agent_home"
        return 0
    fi
    command getent "$@"
}

runuser() {
    local args=("$@")
    while (( ${#args[@]} > 0 )) && [[ ${args[0]} != -- ]]; do
        args=("${args[@]:1}")
    done
    (( ${#args[@]} > 0 )) || return 2
    args=("${args[@]:1}")
    "${args[@]}"
}

# shellcheck disable=SC1091
source "$ROOT/lib/archangel/hermes.sh"

cd "$outside"
actual_pwd=$(archangel_run_as_agent pwd)
actual_home=$(archangel_run_as_agent sh -c 'printf %s "$HOME"')

[[ "$actual_pwd" == "$agent_home" ]] || {
    printf 'FAIL: agent command ran from %s, expected %s\n' "$actual_pwd" "$agent_home" >&2
    exit 1
}

[[ "$actual_home" == "$agent_home" ]] || {
    printf 'FAIL: HOME was %s, expected %s\n' "$actual_home" "$agent_home" >&2
    exit 1
}

printf 'PASS: agent commands start in the agent home with matching HOME\n'
