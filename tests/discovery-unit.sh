#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
ARCHANGEL_SERVICES_FILE="$STATE_DIR/services.tsv"
mkdir -p "$STATE_DIR"

say() { :; }
ask() { printf '%s' "${2:-}"; }
yes_no() { return 1; }

# shellcheck disable=SC1091
source "$ROOT/lib/archangel/discovery.sh"

archangel_services_init
archangel_record_service ollama http://127.0.0.1:11434 local lo no yes
archangel_record_service ollama http://127.0.0.1:11434 local lo no yes
archangel_record_service searxng http://10.0.0.2:8080 manual wg0 no no

[[ $(grep -vc '^#' "$ARCHANGEL_SERVICES_FILE") -eq 2 ]]
[[ $(archangel_route_default 192.168.1.0/24 lan) == Y ]]
[[ $(archangel_route_default 10.68.0.0/24 vpn) == Y ]]
[[ $(archangel_route_default 8.8.8.0/24 lan) == N ]]
[[ $(archangel_route_default 172.17.0.0/16 container/virtual) == N ]]

cat > "$ARCHANGEL_SERVICES_FILE" <<'SERVICES'
# enabled\ttype\turl\tsource\tinterface\tmanaged
yes\tsearxng\thttp://10.0.0.2:8080\tmanual\twg0\tno
yes\tfirecrawl\thttp://10.0.0.3:3002\tmanual\twg0\tno
no\thoncho\thttp://10.0.0.4:8000\tmanual\twg0\tno
SERVICES

ARCHANGEL_AGENT_USER=nobody
ARCHANGEL_HERMES_BIN=/fake/hermes
CONFIG_LOG="$TMP/hermes-config.log"

# shellcheck disable=SC1091
source "$ROOT/lib/archangel/hermes.sh"
archangel_hermes_config_set() { printf '%s=%s\n' "$1" "$2" >> "$CONFIG_LOG"; }
archangel_configure_ollama_model() { :; }
archangel_apply_service_config

grep -qx 'SEARXNG_URL=http://10.0.0.2:8080' "$CONFIG_LOG"
grep -qx 'web.search_backend=searxng' "$CONFIG_LOG"
grep -qx 'FIRECRAWL_API_URL=http://10.0.0.3:3002' "$CONFIG_LOG"
grep -qx 'web.extract_backend=firecrawl' "$CONFIG_LOG"

for script in \
    "$ROOT/install.sh" \
    "$ROOT/uninstall.sh" \
    "$ROOT/bin/archangel-services" \
    "$ROOT/lib/archangel/discovery.sh" \
    "$ROOT/lib/archangel/hermes.sh"; do
    bash -n "$script"
done

printf 'discovery-unit: PASS\n'
