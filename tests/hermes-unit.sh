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

# Keep this test unprivileged: emulate the system lookup and runuser boundary
# while still executing the exact env/bash wrapper.
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

# Verify service endpoint variables are sent through Hermes' env writer rather
# than persisted as arbitrary config.yaml keys.
fake_python="$tmp/fake-python"
env_write_log="$tmp/env-write.log"
cat > "$fake_python" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$3" "$4" > "$ARCHANGEL_TEST_ENV_WRITE_LOG"
SH
chmod +x "$fake_python"
export ARCHANGEL_TEST_ENV_WRITE_LOG="$env_write_log"
archangel_hermes_python() { printf '%s' "$fake_python"; }

archangel_hermes_env_set SEARXNG_URL http://192.168.77.249:8089
IFS=$'\t' read -r written_key written_value < "$env_write_log"
[[ "$written_key" == SEARXNG_URL ]] || {
    printf 'FAIL: env writer received key %s\n' "$written_key" >&2
    exit 1
}
[[ "$written_value" == http://192.168.77.249:8089 ]] || {
    printf 'FAIL: env writer received value %s\n' "$written_value" >&2
    exit 1
}

printf 'PASS: Hermes agent wrapper isolates cwd/HOME and persists service env settings correctly\n'
