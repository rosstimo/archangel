#!/usr/bin/env bash

# Service discovery helpers for Archangel.
# Callers provide: STATE_DIR, ARCHANGEL_AGENT_USER, say, ask, yes_no.

ARCHANGEL_SERVICES_FILE=${ARCHANGEL_SERVICES_FILE:-${STATE_DIR:-/var/lib/archangel}/services.tsv}
ARCHANGEL_KNOWN_PORTS=(11434 8080 8089 3002 8000 8188)

archangel_services_init() {
    install -d -m 0750 "${STATE_DIR:-/var/lib/archangel}"
    if [[ ! -e "$ARCHANGEL_SERVICES_FILE" ]]; then
        printf '# enabled\ttype\turl\tsource\tinterface\tmanaged\n' > "$ARCHANGEL_SERVICES_FILE"
    fi
    chmod 0640 "$ARCHANGEL_SERVICES_FILE"
}

archangel_normalize_url() {
    local url=$1
    [[ "$url" =~ ^https?:// ]] || url="http://$url"
    printf '%s' "${url%/}"
}

archangel_http_body() {
    local url=$1 timeout=${2:-2}
    curl -kfsS --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null || true
}

archangel_http_code() {
    local url=$1 timeout=${2:-2}
    curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null || true
}

archangel_probe_service() {
    local type=$1 base
    base=$(archangel_normalize_url "$2")
    local body code

    case "$type" in
        ollama)
            body=$(archangel_http_body "$base/api/tags")
            [[ "$body" == *'"models"'* ]] || {
                body=$(archangel_http_body "$base/v1/models")
                [[ "$body" == *'"data"'* ]]
            }
            ;;
        comfyui)
            body=$(archangel_http_body "$base/system_stats")
            [[ "$body" == *'"system"'* || "$body" == *'"devices"'* ]]
            ;;
        searxng)
            body=$(archangel_http_body "$base/")
            grep -qi 'searxng\|searx' <<<"$body"
            ;;
        firecrawl)
            code=$(archangel_http_code "$base/v0/health/readiness")
            [[ "$code" == 200 ]] || {
                code=$(archangel_http_code "$base/v0/health/liveness")
                [[ "$code" == 200 ]]
            }
            ;;
        honcho)
            code=$(archangel_http_code "$base/health")
            [[ "$code" == 200 ]] || {
                code=$(archangel_http_code "$base/openapi.json")
                [[ "$code" == 200 ]]
            }
            ;;
        openai-compatible)
            if [[ "$base" == */v1 ]]; then
                body=$(archangel_http_body "$base/models")
            else
                body=$(archangel_http_body "$base/v1/models")
                [[ "$body" == *'"data"'* || "$body" == *'"models"'* ]] || body=$(archangel_http_body "$base/models")
            fi
            [[ "$body" == *'"data"'* || "$body" == *'"models"'* ]]
            ;;
        *)
            code=$(archangel_http_code "$base/")
            [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != 000 ]]
            ;;
    esac
}

archangel_identify_url() {
    local base
    base=$(archangel_normalize_url "$1")
    local type
    for type in ollama comfyui searxng firecrawl honcho openai-compatible; do
        if archangel_probe_service "$type" "$base"; then
            printf '%s' "$type"
            return 0
        fi
    done
    return 1
}

archangel_record_service() {
    local type url source iface managed enabled
    type=$1
    url=$2
    source=${3:-manual}
    iface=${4:--}
    managed=${5:-no}
    enabled=${6:-yes}
    url=$(archangel_normalize_url "$url")
    archangel_services_init

    if awk -F '\t' -v t="$type" -v u="$url" '$1 !~ /^#/ && $2 == t && $3 == u {found=1} END {exit !found}' "$ARCHANGEL_SERVICES_FILE"; then
        return 0
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$enabled" "$type" "$url" "$source" "$iface" "$managed" >> "$ARCHANGEL_SERVICES_FILE"
}

archangel_probe_known_host() {
    local host=$1 source=${2:-network} iface=${3:--}
    local found=0
    local type port url
    while IFS=' ' read -r type port; do
        url="http://$host:$port"
        if archangel_probe_service "$type" "$url"; then
            archangel_record_service "$type" "$url" "$source" "$iface" no yes
            say "  found $type at $url"
            found=1
        fi
    done <<'SERVICES'
ollama 11434
searxng 8080
searxng 8089
firecrawl 3002
honcho 8000
comfyui 8188
SERVICES
    return $(( found == 1 ? 0 : 1 ))
}

archangel_discover_local() {
    say
    say "Local service discovery"
    say "-----------------------"
    archangel_probe_known_host 127.0.0.1 local lo || true

    if command -v ip >/dev/null 2>&1; then
        local addr iface
        while read -r addr iface; do
            [[ -n "$addr" && "$addr" != 127.* ]] || continue
            archangel_probe_known_host "$addr" local "$iface" || true
        done < <(ip -o -4 addr show up 2>/dev/null | awk '{split($4,a,"/"); print a[1],$2}' | sort -u)
    fi
}

archangel_route_kind() {
    local iface=$1
    case "$iface" in
        lo|docker*|br-*|veth*|virbr*|podman*|cni*) printf 'container/virtual' ;;
        wg*|tun*|tap*|tailscale*|zt*) printf 'vpn' ;;
        *) printf 'lan' ;;
    esac
}

archangel_list_routes() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -o -4 route show 2>/dev/null | awk '
        $1 != "default" && $1 ~ /\// {
            iface="-";
            for (i=1; i<=NF; i++) if ($i=="dev" && (i+1)<=NF) iface=$(i+1);
            print $1 "\t" iface
        }
    ' | sort -u
}

archangel_quick_hosts_for_route() {
    local cidr=$1 iface=$2
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 neigh show to "$cidr" dev "$iface" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ && $NF != "FAILED" {print $1}' | sort -u
}

archangel_route_default() {
    local cidr=$1 kind=$2
    [[ "$kind" == container/virtual ]] && { printf N; return; }
    case "$cidr" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) printf Y ;;
        *) printf N ;;
    esac
}

archangel_install_nmap() {
    command -v nmap >/dev/null 2>&1 && return 0
    say "Full network discovery uses nmap, which is not installed."
    yes_no "Install nmap now?" N || return 1
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed nmap
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y nmap
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nmap
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install nmap
    else
        say "No supported package manager found. Install nmap manually for full scans."
        return 1
    fi
}

archangel_full_scan_route() {
    local cidr=$1 iface=$2
    archangel_install_nmap || return 1
    local ports port_csv host
    port_csv=$(IFS=,; printf '%s' "${ARCHANGEL_KNOWN_PORTS[*]}")
    say "Scanning $cidr on $iface for known service ports..."
    while read -r host; do
        [[ -n "$host" ]] || continue
        archangel_probe_known_host "$host" full "$iface" || true
    done < <(nmap -n -Pn --open -T4 -p "$port_csv" -oG - "$cidr" 2>/dev/null | awk '/Ports:/{print $2}')
}

archangel_discover_networks() {
    if ! command -v ip >/dev/null 2>&1; then
        say "The ip command is unavailable; network route discovery was skipped."
        return 0
    fi

    local rows=() cidr iface kind default answer depth host
    while IFS=$'\t' read -r cidr iface; do
        [[ -n "$cidr" ]] || continue
        kind=$(archangel_route_kind "$iface")
        rows+=("$cidr|$iface|$kind")
    done < <(archangel_list_routes)

    if (( ${#rows[@]} == 0 )); then
        say "No scannable IPv4 routes were found."
        return 0
    fi

    say
    say "Reachable networks"
    say "------------------"
    local row
    for row in "${rows[@]}"; do
        IFS='|' read -r cidr iface kind <<<"$row"
        printf '  %-20s %-12s %s\n' "$cidr" "$iface" "$kind"
    done
    say
    say "Only networks you approve below will receive discovery probes."

    for row in "${rows[@]}"; do
        IFS='|' read -r cidr iface kind <<<"$row"
        default=$(archangel_route_default "$cidr" "$kind")
        yes_no "Discover services on $cidr via $iface ($kind)?" "$default" || continue

        depth=$(ask "Discovery depth for $cidr: quick or full" "quick")
        case "${depth,,}" in
            full|f)
                archangel_full_scan_route "$cidr" "$iface" || true
                ;;
            *)
                say "Checking known neighbor hosts on $iface within $cidr..."
                local quick_hosts=()
                mapfile -t quick_hosts < <(archangel_quick_hosts_for_route "$cidr" "$iface")
                if (( ${#quick_hosts[@]} == 0 )); then
                    say "  no known neighbor hosts found for this route"
                    [[ "$kind" == vpn ]] && say "  VPN routes often have no neighbor table; use a full scan or add a direct URL if needed."
                else
                    for host in "${quick_hosts[@]}"; do archangel_probe_known_host "$host" quick "$iface" || true; done
                fi
                ;;
        esac
    done
}

archangel_add_manual_service() {
    local url type detected
    url=$(ask "Service URL (host:port or http[s]://host:port)" "")
    [[ -n "$url" ]] || return 0
    url=$(archangel_normalize_url "$url")
    detected=$(archangel_identify_url "$url" || true)
    if [[ -n "$detected" ]]; then
        say "Detected: $detected"
        type=$(ask "Service type" "$detected")
    else
        say "The service type could not be identified automatically."
        say "Known types: ollama, openai-compatible, searxng, firecrawl, honcho, comfyui, other"
        type=$(ask "Service type" "other")
    fi
    archangel_record_service "$type" "$url" manual - no yes
}

archangel_review_services() {
    archangel_services_init
    local tmp enabled type url source iface managed
    tmp=$(mktemp)
    printf '# enabled\ttype\turl\tsource\tinterface\tmanaged\n' > "$tmp"

    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ -n "$enabled" && "$enabled" != \#* ]] || continue
        say
        say "$type"
        say "  URL:       $url"
        say "  source:    $source"
        [[ "$iface" != - ]] && say "  interface: $iface"
        if yes_no "Make this service available to Hermes?" Y; then
            enabled=yes
        else
            enabled=no
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$enabled" "$type" "$url" "$source" "$iface" "$managed" >> "$tmp"
    done < "$ARCHANGEL_SERVICES_FILE"

    install -m 0640 "$tmp" "$ARCHANGEL_SERVICES_FILE"
    rm -f "$tmp"
}

archangel_services_status() {
    archangel_services_init
    printf '%-8s %-20s %-40s %-10s %-12s\n' ENABLED TYPE URL SOURCE INTERFACE
    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ -n "$enabled" && "$enabled" != \#* ]] || continue
        printf '%-8s %-20s %-40s %-10s %-12s\n' "$enabled" "$type" "$url" "$source" "$iface"
    done < "$ARCHANGEL_SERVICES_FILE"
}

archangel_discovery_wizard() {
    archangel_services_init
    say
    say "Service discovery"
    say "================="
    say "Archangel can look for services that Hermes may use."
    say "Local discovery checks only this machine. Network discovery sends"
    say "connection probes to networks you explicitly approve. Everything can"
    say "be skipped now and added later with archangel-services."
    say

    yes_no "Discover services on this machine?" Y && archangel_discover_local
    yes_no "Discover services on LAN/VPN networks?" N && archangel_discover_networks

    while yes_no "Add a service by URL?" N; do
        archangel_add_manual_service
    done

    archangel_review_services
}
