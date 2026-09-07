#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
ARCHANGEL_SERVICES_FILE="$STATE_DIR/services.tsv"
ARCHANGEL_GATEWAYS_FILE="$STATE_DIR/gateways.tsv"
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

# Linux prints IPv4 host routes without an explicit /32. Normalize them so
# point-to-point VPN discovery can treat the route destination as a known host.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/ip" <<'MOCKIP'
#!/usr/bin/env bash
if [[ "$*" == "-o -4 route show" ]]; then
    cat <<'ROUTES'
10.68.0.1 dev wg-agent scope link
192.168.0.0/16 dev wlan0 proto kernel scope link src 192.168.77.77
default via 192.168.77.1 dev wlan0
ROUTES
fi
MOCKIP

chmod +x "$MOCK_BIN/ip"

ROUTE_PARSE_OUTPUT=$(PATH="$MOCK_BIN:$PATH" archangel_list_routes)

grep -qx $'10.68.0.1/32\twg-agent' <<<"$ROUTE_PARSE_OUTPUT"
grep -qx $'192.168.0.0/16\twlan0' <<<"$ROUTE_PARSE_OUTPUT"
! grep -q '^default' <<<"$ROUTE_PARSE_OUTPUT"

# A saved gateway must persist independently of current reachability. If a
# service was already found through transient quick discovery, explicitly
# assigning it to the gateway should adopt that record rather than duplicate it.
archangel_record_gateway hq 10.68.0.1 wg-agent wireguard
archangel_record_service searxng http://10.68.0.1:8089 quick wg-agent no yes
archangel_gateway_add_service hq search 8089 searxng
archangel_gateway_add_service hq ollama-4060ti 11431 ollama

[[ $(grep -vc '^#' "$ARCHANGEL_GATEWAYS_FILE") -eq 1 ]]
grep -qx $'hq\t10.68.0.1\twg-agent\twireguard' "$ARCHANGEL_GATEWAYS_FILE"
[[ $(awk -F '\t' '$2=="searxng" && $3=="http://10.68.0.1:8089" {n++} END{print n+0}' "$ARCHANGEL_SERVICES_FILE") -eq 1 ]]
grep -q $'^yes\tsearxng\thttp://10.68.0.1:8089\tgateway:hq/search\twg-agent\tno$' "$ARCHANGEL_SERVICES_FILE"
grep -q $'^yes\tollama\thttp://10.68.0.1:11431\tgateway:hq/ollama-4060ti\twg-agent\tno$' "$ARCHANGEL_SERVICES_FILE"
[[ $(archangel_gateway_service_counts hq) == 2/2 ]]

# Quick discovery on a point-to-point VPN cannot depend on ARP. A routed /32 is
# itself a known host and must be probed even when the neighbor table is empty.
VPN_PROBE_LOG="$TMP/vpn-probe.log"
archangel_list_routes() { printf '10.68.0.1/32\twg-agent\n'; }
archangel_quick_hosts_for_route() { :; }
archangel_probe_known_host() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$VPN_PROBE_LOG"; return 0; }
yes_no() { return 0; }
archangel_discover_networks
grep -qx $'10.68.0.1\tquick\twg-agent' "$VPN_PROBE_LOG"

# Restore non-interactive defaults for the remaining test.
yes_no() { return 1; }

{
    printf '# enabled\ttype\turl\tsource\tinterface\tmanaged\n'
    printf 'yes\tsearxng\thttp://10.0.0.2:8080\tmanual\twg0\tno\n'
    printf 'yes\tfirecrawl\thttp://10.0.0.3:3002\tmanual\twg0\tno\n'
    printf 'no\thoncho\thttp://10.0.0.4:8000\tmanual\twg0\tno\n'
} > "$ARCHANGEL_SERVICES_FILE"

ARCHANGEL_AGENT_USER=nobody
ARCHANGEL_HERMES_BIN=/fake/hermes
CONFIG_LOG="$TMP/hermes-config.log"

# shellcheck disable=SC1091
source "$ROOT/lib/archangel/hermes.sh"
archangel_hermes_env_set() { printf '%s=%s\n' "$1" "$2" >> "$CONFIG_LOG"; }
archangel_hermes_config_set() { printf '%s=%s\n' "$1" "$2" >> "$CONFIG_LOG"; }
archangel_hermes_config_unset() { :; }
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
