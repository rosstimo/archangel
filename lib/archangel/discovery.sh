#!/usr/bin/env bash

# Service discovery helpers for Archangel.
# Callers provide: STATE_DIR, ARCHANGEL_AGENT_USER, say, ask, yes_no.

ARCHANGEL_SERVICES_FILE=${ARCHANGEL_SERVICES_FILE:-${STATE_DIR:-/var/lib/archangel}/services.tsv}
ARCHANGEL_GATEWAYS_FILE=${ARCHANGEL_GATEWAYS_FILE:-${STATE_DIR:-/var/lib/archangel}/gateways.tsv}
ARCHANGEL_KNOWN_PORTS=(11431 11432 11433 11434 8080 8089 3002 8000 8188)

archangel_gateways_init() {
    install -d -m 0750 "${STATE_DIR:-/var/lib/archangel}"
    if [[ ! -e "$ARCHANGEL_GATEWAYS_FILE" ]]; then
        printf '# name\taddress\tinterface\ttransport\n' > "$ARCHANGEL_GATEWAYS_FILE"
    fi
    chmod 0640 "$ARCHANGEL_GATEWAYS_FILE"
}

archangel_services_init() {
    install -d -m 0750 "${STATE_DIR:-/var/lib/archangel}"
    if [[ ! -e "$ARCHANGEL_SERVICES_FILE" ]]; then
        printf '# enabled\ttype\turl\tsource\tinterface\tmanaged\n' > "$ARCHANGEL_SERVICES_FILE"
    fi
    chmod 0640 "$ARCHANGEL_SERVICES_FILE"
    archangel_gateways_init
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
    local type url source iface managed enabled tmp
    type=$1
    url=$2
    source=${3:-manual}
    iface=${4:--}
    managed=${5:-no}
    enabled=${6:-yes}
    url=$(archangel_normalize_url "$url")
    archangel_services_init

    if awk -F '\t' -v t="$type" -v u="$url" '$1 !~ /^#/ && $2 == t && $3 == u {found=1} END {exit !found}' "$ARCHANGEL_SERVICES_FILE"; then
        # A saved gateway is more durable provenance than transient quick/full
        # discovery. If the endpoint already exists, let the explicit gateway
        # definition adopt it rather than creating a duplicate.
        if [[ "$source" == gateway:* ]]; then
            tmp=$(mktemp)
            awk -F '\t' -v OFS='\t' \
                -v e="$enabled" -v t="$type" -v u="$url" -v s="$source" -v i="$iface" -v m="$managed" '
                $1 !~ /^#/ && $2 == t && $3 == u {print e,t,u,s,i,m; next}
                {print}
            ' "$ARCHANGEL_SERVICES_FILE" > "$tmp"
            install -m 0640 "$tmp" "$ARCHANGEL_SERVICES_FILE"
            rm -f "$tmp"
        fi
        return 0
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$enabled" "$type" "$url" "$source" "$iface" "$managed" >> "$ARCHANGEL_SERVICES_FILE"
}

archangel_valid_gateway_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

archangel_record_gateway() {
    local name=$1 address=$2 iface=${3:--} transport=${4:-auto} tmp
    archangel_valid_gateway_name "$name" || {
        say "Gateway name '$name' is invalid. Use letters, numbers, dot, underscore, or dash."
        return 2
    }
    [[ -n "$address" && "$address" != *$'\t'* && "$address" != *$'\n'* ]] || return 2
    [[ "$iface" != *$'\t'* && "$transport" != *$'\t'* ]] || return 2
    archangel_gateways_init

    tmp=$(mktemp)
    awk -F '\t' -v OFS='\t' -v n="$name" -v a="$address" -v i="$iface" -v t="$transport" '
        BEGIN {updated=0}
        /^#/ {print; next}
        $1 == n {print n,a,i,t; updated=1; next}
        {print}
        END {if (!updated) print n,a,i,t}
    ' "$ARCHANGEL_GATEWAYS_FILE" > "$tmp"
    install -m 0640 "$tmp" "$ARCHANGEL_GATEWAYS_FILE"
    rm -f "$tmp"
}

archangel_gateway_row() {
    local name=$1
    archangel_gateways_init
    awk -F '\t' -v n="$name" '$1 !~ /^#/ && $1 == n {print; exit}' "$ARCHANGEL_GATEWAYS_FILE"
}

archangel_gateway_resolve_ipv4() {
    local address=$1
    if [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$address"
        return 0
    fi
    getent ahostsv4 "$address" 2>/dev/null | awk 'NR==1 {print $1}'
}

archangel_gateway_route_iface() {
    local address=$1 ip
    command -v ip >/dev/null 2>&1 || return 1
    ip=$(archangel_gateway_resolve_ipv4 "$address" || true)
    [[ -n "$ip" ]] || return 1
    ip -o -4 route get "$ip" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev" && (i+1)<=NF) {print $(i+1); exit}}'
}

archangel_gateway_path_state() {
    local address=$1 expected=${2:--} actual
    if [[ "$expected" != - ]]; then
        ip link show dev "$expected" >/dev/null 2>&1 || {
            printf 'interface-down'
            return 0
        }
    fi
    actual=$(archangel_gateway_route_iface "$address" || true)
    [[ -n "$actual" ]] || {
        printf 'no-route'
        return 0
    }
    if [[ "$expected" != - && "$actual" != "$expected" ]]; then
        printf 'route-via:%s' "$actual"
    else
        printf 'up:%s' "$actual"
    fi
}

archangel_gateway_service_counts() {
    local name=$1 total=0 enabled=0 row_enabled type url source iface managed
    archangel_services_init
    while IFS=$'\t' read -r row_enabled type url source iface managed; do
        [[ -n "$row_enabled" && "$row_enabled" != \#* ]] || continue
        [[ "$source" == "gateway:$name/"* ]] || continue
        ((total+=1))
        [[ "$row_enabled" == yes ]] && ((enabled+=1))
    done < "$ARCHANGEL_SERVICES_FILE"
    printf '%s/%s' "$enabled" "$total"
}

archangel_gateways_status() {
    archangel_gateways_init
    printf '%-18s %-24s %-14s %-12s %-20s %-8s\n' NAME ADDRESS INTERFACE TRANSPORT PATH SERVICES
    local name address iface transport path counts
    while IFS=$'\t' read -r name address iface transport; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        path=$(archangel_gateway_path_state "$address" "$iface")
        counts=$(archangel_gateway_service_counts "$name")
        printf '%-18s %-24s %-14s %-12s %-20s %-8s\n' "$name" "$address" "$iface" "$transport" "$path" "$counts"
    done < "$ARCHANGEL_GATEWAYS_FILE"
}

archangel_gateway_add_service() {
    local gateway=$1 service_name=$2 port=$3 type=${4:-} scheme=${5:-http}
    local row name address iface transport url detected
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
        say "Invalid service port: $port"
        return 2
    }
    archangel_valid_gateway_name "$service_name" || {
        say "Service name '$service_name' is invalid."
        return 2
    }
    row=$(archangel_gateway_row "$gateway")
    [[ -n "$row" ]] || {
        say "Unknown gateway '$gateway'."
        return 2
    }
    IFS=$'\t' read -r name address iface transport <<<"$row"
    url="$scheme://$address:$port"
    if [[ -z "$type" ]]; then
        detected=$(archangel_identify_url "$url" || true)
        type=${detected:-other}
    fi
    archangel_record_service "$type" "$url" "gateway:$gateway/$service_name" "$iface" no yes
    say "Recorded $service_name ($type) at $url through gateway '$gateway'."
}

archangel_probe_gateway() {
    local wanted=${1:-} name address iface transport path
    local enabled type url source service_iface managed service_name found=0 failed=0 matched=0
    archangel_gateways_init
    archangel_services_init

    while IFS=$'\t' read -r name address iface transport; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        [[ -z "$wanted" || "$name" == "$wanted" ]] || continue
        matched=1
        path=$(archangel_gateway_path_state "$address" "$iface")
        say
        say "Gateway $name ($address): $path"
        if [[ "$path" != up:* ]]; then
            say "  saved definition retained; no probes sent"
            continue
        fi
        while IFS=$'\t' read -r enabled type url source service_iface managed; do
            [[ -n "$enabled" && "$enabled" != \#* ]] || continue
            [[ "$source" == "gateway:$name/"* ]] || continue
            service_name=${source#"gateway:$name/"}
            if archangel_probe_service "$type" "$url"; then
                printf '  ok   %-20s %-12s %s\n' "$service_name" "$type" "$url"
                ((found+=1))
            else
                printf '  FAIL %-20s %-12s %s\n' "$service_name" "$type" "$url"
                ((failed+=1))
            fi
        done < "$ARCHANGEL_SERVICES_FILE"
    done < "$ARCHANGEL_GATEWAYS_FILE"

    if [[ -n "$wanted" && "$matched" -eq 0 ]]; then
        say "Unknown gateway '$wanted'."
        return 2
    fi
    (( failed == 0 ))
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
ollama 11431
ollama 11432
ollama 11433
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
        $1 != "default" {
            route=$1;
            if (route ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                route=route "/32";
            if (route !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/)
                next;

            iface="-";
            for (i=1; i<=NF; i++)
                if ($i=="dev" && (i+1)<=NF)
                    iface=$(i+1);

            print route "\t" iface
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

    local rows=() cidr iface kind default depth host
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
                say "Checking directly routed and known neighbor hosts on $iface within $cidr..."
                local quick_hosts=()
                mapfile -t quick_hosts < <(
                    archangel_quick_hosts_for_route "$cidr" "$iface"
                    [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$ ]] && printf '%s\n' "${cidr%/32}"
                )
                if (( ${#quick_hosts[@]} == 0 )); then
                    say "  no directly routed or known neighbor hosts found for this route"
                    [[ "$kind" == vpn ]] && say "  VPN routes often have no neighbor table; use a saved gateway, full scan, or direct URL if needed."
                else
                    while read -r host; do
                        [[ -n "$host" ]] && archangel_probe_known_host "$host" quick "$iface" || true
                    done < <(printf '%s\n' "${quick_hosts[@]}" | sort -u)
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
    printf '%-8s %-20s %-40s %-24s %-12s\n' ENABLED TYPE URL SOURCE INTERFACE
    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ -n "$enabled" && "$enabled" != \#* ]] || continue
        printf '%-8s %-20s %-40s %-24s %-12s\n' "$enabled" "$type" "$url" "$source" "$iface"
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
