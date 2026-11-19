#!/usr/bin/env bash
# Safe smoke test: no host configuration changes, no root required.
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo/scripts/host-inventory.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

bash -n "$script"
bash "$script" --help >/dev/null

out="$tmp/first-report"
bash "$script" --output-dir "$out" --agent-user "$(id -un)" >/dev/null
[[ -d "$out" ]] || { echo 'missing report directory' >&2; exit 1; }
[[ $(stat -c %a "$out") == 700 ]] || { echo 'report directory not private' >&2; exit 1; }
for file in README.txt host.txt storage.txt hardware.txt network.txt services.txt docker.txt software.txt agent.txt; do
    [[ -f "$out/$file" ]] || { echo "missing $file" >&2; exit 1; }
    [[ $(stat -c %a "$out/$file") == 600 ]] || { echo "$file not private" >&2; exit 1; }
done

# Never overwrite a pre-existing inventory or alter its content.
printf 'keep me\n' > "$out/marker"
if bash "$script" --output-dir "$out" >/dev/null 2>&1; then
    echo 'overwriting report was accepted' >&2; exit 1
fi
[[ $(cat "$out/marker") == 'keep me' ]] || { echo 'existing report changed' >&2; exit 1; }

# A common accident is placing a private report under a public Git checkout.
if command -v git >/dev/null; then
    mkdir "$tmp/checkout"
    git -C "$tmp/checkout" init -q
    if bash "$script" --output-dir "$tmp/checkout/report" >/dev/null 2>&1; then
        echo 'private report allowed inside Git worktree' >&2; exit 1
    fi
    [[ ! -e "$tmp/checkout/report" ]] || { echo 'report inside Git worktree' >&2; exit 1; }
fi

echo 'host-inventory smoke tests passed'