#!/usr/bin/env bash

# Hermes installation/configuration helpers for Archangel.
# Callers provide: ARCHANGEL_AGENT_USER, STATE_DIR, say, ask, yes_no.

archangel_agent_home() {
    getent passwd "$ARCHANGEL_AGENT_USER" | cut -d: -f6
}

archangel_hermes_bin() {
    local home
    home=$(archangel_agent_home)
    local path
    for path in \
        "$home/.local/bin/hermes" \
        "$home/.hermes/hermes-agent/venv/bin/hermes" \
        /usr/local/bin/hermes; do
        [[ -x "$path" ]] && { printf '%s' "$path"; return 0; }
    done
    return 1
}

archangel_run_as_agent() {
    local home
    home=$(archangel_agent_home)
    runuser -u "$ARCHANGEL_AGENT_USER" -- env \
        HOME="$home" USER="$ARCHANGEL_AGENT_USER" LOGNAME="$ARCHANGEL_AGENT_USER" \
        PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

archangel_install_package_for_command() {
    local command_name=$1 arch_pkg=$2 deb_pkg=$3 rpm_pkg=$4
    command -v "$command_name" >/dev/null 2>&1 && return 0
    say "Hermes requires '$command_name', which is not installed."
    yes_no "Install the required package now?" Y || return 1
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed "$arch_pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y "$deb_pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$rpm_pkg"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "$rpm_pkg"
    else
        return 1
    fi
}

archangel_ensure_hermes_prereqs() {
    archangel_install_package_for_command curl curl curl curl || return 1
    archangel_install_package_for_command git git git git || return 1
    archangel_install_package_for_command xz xz xz-utils xz || return 1
}

archangel_install_hermes() {
    local home existing flags=(--skip-setup)
    home=$(archangel_agent_home)
    existing=$(archangel_hermes_bin || true)
    if [[ -n "$existing" ]]; then
        say "Hermes is already available to '$ARCHANGEL_AGENT_USER' at $existing."
        ARCHANGEL_HERMES_INSTALLED=no
        ARCHANGEL_HERMES_BIN="$existing"
        ARCHANGEL_HERMES_HOME="$home/.hermes"
        return 0
    fi

    yes_no "Install Hermes Agent for '$ARCHANGEL_AGENT_USER'?" Y || {
        ARCHANGEL_HERMES_INSTALLED=no
        ARCHANGEL_HERMES_BIN=
        ARCHANGEL_HERMES_HOME="$home/.hermes"
        return 0
    }

    archangel_ensure_hermes_prereqs || {
        say "Hermes prerequisites are incomplete; skipping Hermes installation."
        ARCHANGEL_HERMES_INSTALLED=no
        return 0
    }

    if ! yes_no "Include Hermes browser automation components?" Y; then
        flags+=(--skip-browser)
    fi

    say "Installing Hermes as '$ARCHANGEL_AGENT_USER' using the upstream installer..."
    local flag_string
    printf -v flag_string ' %q' "${flags[@]}"
    archangel_run_as_agent bash -c \
        "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s --$flag_string"

    ARCHANGEL_HERMES_BIN=$(archangel_hermes_bin || true)
    ARCHANGEL_HERMES_HOME="$home/.hermes"
    if [[ -z "$ARCHANGEL_HERMES_BIN" ]]; then
        say "Hermes installation finished but the executable could not be located."
        ARCHANGEL_HERMES_INSTALLED=unknown
        return 1
    fi
    ARCHANGEL_HERMES_INSTALLED=yes
    say "Hermes installed: $ARCHANGEL_HERMES_BIN"
}

archangel_hermes_config_set() {
    local key=$1 value=$2
    [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]] || return 1
    archangel_run_as_agent "$ARCHANGEL_HERMES_BIN" config set "$key" "$value"
}

archangel_first_enabled_service() {
    local wanted=$1 enabled type url source iface managed
    [[ -r "${ARCHANGEL_SERVICES_FILE:-}" ]] || return 1
    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ "$enabled" == yes && "$type" == "$wanted" ]] || continue
        printf '%s' "$url"
        return 0
    done < "$ARCHANGEL_SERVICES_FILE"
    return 1
}

archangel_list_enabled_urls() {
    local wanted=$1 enabled type url source iface managed
    [[ -r "${ARCHANGEL_SERVICES_FILE:-}" ]] || return 0
    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ "$enabled" == yes && "$type" == "$wanted" ]] || continue
        printf '%s\n' "$url"
    done < "$ARCHANGEL_SERVICES_FILE"
}

archangel_choose_enabled_service() {
    local wanted=$1 label=${2:-$1} urls=() selection
    mapfile -t urls < <(archangel_list_enabled_urls "$wanted")
    (( ${#urls[@]} > 0 )) || return 1
    if (( ${#urls[@]} == 1 )); then
        printf '%s' "${urls[0]}"
        return 0
    fi
    say "Multiple $label endpoints are enabled:" >&2
    local i
    for i in "${!urls[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${urls[$i]}" >&2; done
    selection=$(ask "Endpoint number" "1")
    [[ "$selection" =~ ^[0-9]+$ ]] || selection=1
    (( selection >= 1 && selection <= ${#urls[@]} )) || selection=1
    printf '%s' "${urls[$((selection-1))]}"
}

archangel_configure_ollama_model() {
    local endpoints=() endpoint model_body models=() selection context
    mapfile -t endpoints < <(archangel_list_enabled_urls ollama)
    (( ${#endpoints[@]} > 0 )) || return 0
    yes_no "Configure a discovered Ollama endpoint as Hermes' primary model provider?" N || return 0

    if (( ${#endpoints[@]} == 1 )); then
        endpoint=${endpoints[0]}
    else
        say "Available Ollama endpoints:"
        local i
        for i in "${!endpoints[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${endpoints[$i]}"; done
        selection=$(ask "Endpoint number" "1")
        [[ "$selection" =~ ^[0-9]+$ ]] || selection=1
        (( selection >= 1 && selection <= ${#endpoints[@]} )) || selection=1
        endpoint=${endpoints[$((selection-1))]}
    fi

    model_body=$(archangel_http_body "$endpoint/v1/models" 4)
    if command -v python3 >/dev/null 2>&1; then
        mapfile -t models < <(python3 -c 'import json,sys
try:
 d=json.load(sys.stdin)
 print("\\n".join(str(x.get("id","")) for x in d.get("data",[]) if x.get("id")))
except Exception: pass' <<<"$model_body")
    fi

    if (( ${#models[@]} > 0 )); then
        say "Models reported by $endpoint:"
        local i
        for i in "${!models[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${models[$i]}"; done
        selection=$(ask "Model number" "1")
        [[ "$selection" =~ ^[0-9]+$ ]] || selection=1
        (( selection >= 1 && selection <= ${#models[@]} )) || selection=1
        model=${models[$((selection-1))]}
    else
        model=$(ask "Model name" "")
    fi
    [[ -n "$model" ]] || return 0

    context=$(ask "Served context length in tokens (blank = let Hermes detect it)" "")
    archangel_hermes_config_set model.provider custom
    archangel_hermes_config_set model.base_url "${endpoint%/}/v1"
    archangel_hermes_config_set model.default "$model"
    [[ -n "$context" ]] && archangel_hermes_config_set model.context_length "$context"
}

archangel_apply_service_config() {
    [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]] || {
        say "Hermes is not installed, so service selections were saved but not applied."
        return 0
    }

    local url
    url=$(archangel_choose_enabled_service searxng SearXNG || true)
    if [[ -n "$url" ]]; then
        archangel_hermes_config_set SEARXNG_URL "$url"
        archangel_hermes_config_set web.search_backend searxng
    fi

    url=$(archangel_choose_enabled_service firecrawl Firecrawl || true)
    if [[ -n "$url" ]]; then
        archangel_hermes_config_set FIRECRAWL_API_URL "$url"
        archangel_hermes_config_set web.extract_backend firecrawl
    fi

    url=$(archangel_choose_enabled_service honcho Honcho || true)
    if [[ -n "$url" ]]; then
        archangel_hermes_config_set HONCHO_BASE_URL "$url"
        say "Honcho endpoint saved for Hermes: $url"
        if yes_no "Run Hermes memory setup now to enable/configure Honcho?" N; then
            archangel_run_as_agent "$ARCHANGEL_HERMES_BIN" memory setup
        fi
    fi

    if archangel_first_enabled_service comfyui >/dev/null 2>&1; then
        say "ComfyUI was recorded. Hermes/ComfyUI integration is left user-controlled because"
        say "the desired skill, MCP, or image-provider path can differ between installations."
    fi

    archangel_configure_ollama_model
}

archangel_verify_selected_services() {
    [[ -r "${ARCHANGEL_SERVICES_FILE:-}" ]] || return 0
    say
    say "Service reachability as '$ARCHANGEL_AGENT_USER'"
    say "-------------------------------------------"
    local enabled type url source iface managed target code
    while IFS=$'\t' read -r enabled type url source iface managed; do
        [[ "$enabled" == yes ]] || continue
        case "$type" in
            ollama) target="${url%/}/api/tags" ;;
            comfyui) target="${url%/}/system_stats" ;;
            firecrawl) target="${url%/}/v0/health/readiness" ;;
            honcho) target="${url%/}/health" ;;
            *) target="${url%/}/" ;;
        esac
        code=$(archangel_run_as_agent curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "$target" 2>/dev/null || true)
        if [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != 000 ]]; then
            printf '  ok   %-20s %s (HTTP %s)\n' "$type" "$url" "$code"
        else
            printf '  FAIL %-20s %s\n' "$type" "$url"
        fi
    done < "$ARCHANGEL_SERVICES_FILE"
}

archangel_finish_hermes_setup() {
    [[ -n "${ARCHANGEL_HERMES_BIN:-}" ]] || return 0
    say
    say "Hermes setup"
    say "------------"
    say "Archangel has applied service settings it can configure safely."
    if yes_no "Run the Hermes setup wizard now for providers, tools, and messaging?" Y; then
        archangel_run_as_agent "$ARCHANGEL_HERMES_BIN" setup
    fi
    archangel_verify_selected_services
    say
    say "Running Hermes diagnostics as '$ARCHANGEL_AGENT_USER'..."
    archangel_run_as_agent "$ARCHANGEL_HERMES_BIN" doctor || true
}
