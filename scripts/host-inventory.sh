#!/usr/bin/env bash
# Read-only host discovery. Inventory names and metadata, never credential values.
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Usage: bash scripts/host-inventory.sh --output-dir DIRECTORY [--agent-user USER]

Create a private, read-only discovery report for an existing Linux host.
No packages, services, networks, or access rules are changed.
Output may contain private hostnames, routes, paths, and software names.
Choose a NEW directory outside all Git working trees. Do not commit the report.
Run unprivileged first; optional root inspection may reveal more metadata.
USAGE
}
die() { printf 'host-inventory: %s\n' "$*" >&2; exit 1; }

output=
agent_user=
while (( $# )); do
    case "$1" in
        --output-dir)
            (( $# >= 2 )) || die '--output-dir requires a path'
            output=$2
            shift 2 ;;
        --agent-user)
            (( $# >= 2 )) || die '--agent-user requires a username'
            agent_user=$2
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$output" ]] || { usage >&2; exit 2; }
[[ "$output" != *$'\n'* ]] || die 'output path cannot contain a newline'
[[ -z "$agent_user" || "$agent_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'invalid agent username'
if [[ "$output" != /* ]]; then output="$PWD/$output"; fi
parent=$(dirname -- "$output")
[[ -d "$parent" ]] || die "parent directory does not exist: $parent"
if command -v git >/dev/null && git -C "$parent" rev-parse --is-inside-work-tree 2>/dev/null | grep -qx true; then
    die 'refusing to save private inventory inside a Git working tree'
fi
[[ ! -e "$output" ]] || die "refusing to overwrite existing path: $output"
mkdir -m 0700 -- "$output" || die "cannot create output directory: $output"

record() {
    local file=$1
    shift
    if ! "$@" > "$output/$file" 2>/dev/null; then
        printf '[unavailable, failed, or insufficient permissions]\n' >> "$output/$file"
    fi
}
{
    printf 'Collected UTC: '
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    printf 'Host: '
    hostname
    printf 'Architecture: '
    uname -m
    printf 'Kernel: '
    uname -r
    printf 'Running as: '
    id -un
    printf '\nOS identification:\n'
    if [[ -r /etc/os-release ]]; then
        grep -E '^(ID|VERSION_ID|PRETTY_NAME)=' /etc/os-release || true
    fi
    printf '\nAgent account: %s\n' "$agent_user"
    printf '\nArchangel config present: '
    [[ -f /etc/archangel.conf ]] && printf 'yes\n' || printf 'no\n'
    printf 'Archangel state present: '
    [[ -d /var/lib/archangel ]] && printf 'yes\n' || printf 'no\n'
} > "$output/host.txt"

record storage.txt lsblk -o NAME,TYPE,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
{
    printf 'Jetson release metadata (if available):\n'
    if [[ -r /etc/nv_tegra_release ]]; then
        cat /etc/nv_tegra_release
    else
        printf '[not detected]\n'
    fi
    printf '\nPotential accelerator devices (not authoritative):\n'
    if command -v lspci >/dev/null; then
        lspci -nn 2>/dev/null | grep -Ei 'nvidia|google|coral|hailo|neural|tensor|tpu|accelerator' || true
    fi
    if command -v lsusb >/dev/null; then
        lsusb 2>/dev/null | grep -Ei 'nvidia|google|coral|hailo|neural|tensor|tpu|accelerator' || true
    fi
    find /dev -maxdepth 1 \( -name 'apex*' -o -name 'hailo*' -o -name 'nvhost*' \) -printf '%f\n' 2>/dev/null || true
    if command -v dpkg-query >/dev/null; then
        dpkg-query -W 'nvidia-l4t-*' 2>/dev/null || true
    fi
    printf '\nNo matches do not prove an accelerator is absent.\n'
} > "$output/hardware.txt"
{
    printf 'NetworkManager connection metadata (no secrets):\n'
    if command -v nmcli >/dev/null; then
        nmcli -f NAME,TYPE,DEVICE connection show 2>/dev/null || printf '[unavailable]\n'
    else
        printf '[nmcli not installed]\n'
    fi
    printf '\nWireGuard interface names only:\n'
    if command -v wg >/dev/null; then
        wg show interfaces 2>/dev/null || printf '[unavailable]\n'
    fi
    printf '\nIPv4 routes (private topology information):\n'
    if command -v ip >/dev/null; then
        ip -4 route show 2>/dev/null || printf '[unavailable]\n'
    fi
    printf '\nProtected VPN/profile filenames, never contents:\n'
    for dir in /etc/NetworkManager/system-connections /etc/wireguard; do
        printf '%s:\n' "$dir"
        if [[ -d "$dir" ]]; then
            find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true
        else
            printf '[not present]\n'
        fi
    done
} > "$output/network.txt"
{
    printf 'Custom systemd unit filenames:\n'
    if [[ -d /etc/systemd/system ]]; then
        find /etc/systemd/system -type f -printf '%p\n' 2>/dev/null || true
    fi
    printf '\nEnabled unit names:\n'
    if command -v systemctl >/dev/null; then
        systemctl list-unit-files --state=enabled --no-pager 2>/dev/null || printf '[unavailable]\n'
    fi
    printf '\nUser unit filenames:\n'
    target_user=$agent_user
    [[ -n "$target_user" ]] || target_user=$(id -un)
    target_home=$(getent passwd "$target_user" | cut -d: -f6 || true)
    if [[ -n "$target_home" && -d "$target_home/.config/systemd/user" ]]; then
        find "$target_home/.config/systemd/user" -type f -printf '%p\n' 2>/dev/null || true
    fi
} > "$output/services.txt"
{
    printf 'Docker project metadata:\n'
    if command -v docker >/dev/null; then
        docker compose ls --all 2>/dev/null || printf '[compose unavailable or no permission]\n'
        printf '\nContainers (name, image, state):\n'
        docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || printf '[docker unavailable or no permission]\n'
        printf '\nNamed volumes (names only):\n'
        docker volume ls --format '{{.Name}}' 2>/dev/null || printf '[docker unavailable or no permission]\n'
    else
        printf '[docker not installed]\n'
    fi
} > "$output/docker.txt"
{
    printf 'Explicitly installed packages:\n'
    if command -v pacman >/dev/null; then
        pacman -Qqe 2>/dev/null || printf '[pacman unavailable]\n'
    elif command -v apt-mark >/dev/null; then
        apt-mark showmanual 2>/dev/null || printf '[apt unavailable]\n'
    else
        printf '[package inventory not implemented for this manager]\n'
    fi
    printf '\nCustom executable filenames:\n'
    if [[ -d /usr/local/bin ]]; then
        find /usr/local/bin -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true
    fi
} > "$output/software.txt"
{
    printf 'Agent home location and top-level names (not contents):\n'
    if [[ -n "$agent_user" ]]; then
        agent_home=$(getent passwd "$agent_user" | cut -d: -f6 || true)
        if [[ -n "$agent_home" && -d "$agent_home" ]]; then
            printf 'Home: %s\n' "$agent_home"
            find "$agent_home" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true
        else
            printf '[account/home not available]\n'
        fi
    else
        printf '[use --agent-user USER to inspect an agent account]\n'
    fi
} > "$output/agent.txt"
cat > "$output/README.txt" <<'NOTICE'
PRIVATE HOST DISCOVERY REPORT

This is a first-pass metadata inventory, NOT a backup and NOT proof of recovery.
It never intentionally reads credential contents, Docker environments, or unit
bodies. Connection names, hostnames, routes, and paths remain private.
Some entries may be missing because commands are unavailable or permission denied.
All inventory outputs and recovery manifests must stay OUTSIDE Git.
Do not share this directory unreviewed. This script made no host config changes.
NOTICE

printf 'Created private inventory: %s\n' "$output"
printf 'Review files locally; do not upload or commit unreviewed inventory data.\n'