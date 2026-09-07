# Hermes service discovery

Archangel can discover services that a Hermes agent may use without assuming that
those services run on the same computer. Discovery is optional at install time
and can be run again later.

```bash
sudo archangel-services discover
```

Nothing discovered by Archangel is treated as Archangel-owned. Discovery records
an endpoint and its origin; it does not give the agent Docker access, reconfigure
the remote service, or make uninstall remove that service.

## Discovery choices

The install wizard treats these as independent choices:

1. **Local machine**: probe known service endpoints on loopback and the machine's
   own IPv4 addresses.
2. **LAN/VPN networks**: inspect the routing table, show the reachable subnets and
   interfaces, and ask which routes may receive probes.
3. **Direct URL**: add an endpoint explicitly, with automatic service detection
   when possible.
4. **Skip**: save nothing and configure services later.

Network discovery is disabled by default. If enabled, Archangel still asks about
each route before sending probes. Private LAN/VPN routes are suggested; container,
virtual, or public-looking routes are not selected by default.

### Quick network discovery

Quick discovery probes hosts already present in the kernel neighbor table for the
approved route. For an explicitly routed IPv4 `/32`, Archangel also probes that
single address directly. This matters for point-to-point tunnels such as
WireGuard, where a route like `10.68.0.1/32 dev wg-agent` identifies the target
without any ARP/neighbor entry.

A broader VPN route may still have no neighbor table and no single target to infer.
Use a saved service gateway, a deliberately approved full scan, or direct endpoint
entry in that case.

### Full network discovery

Full discovery uses `nmap` to check the known service ports across the approved
CIDR, then performs a service-specific HTTP probe against hosts with open ports.
Archangel asks before installing `nmap` if it is missing.

A full scan is never started merely because a route exists. The user must approve
the route and choose `full` for that route.

## Saved service gateways

A service gateway is a persistent Archangel description of a host that exposes
multiple useful services, especially when the route to that host exists only while
an independently managed VPN is active.

A gateway records:

- a short name;
- host/IP address;
- optional interface hint;
- optional transport description such as `wireguard`.

Archangel does **not** create VPN keys, edit WireGuard/OpenVPN configuration, bring
the hinted interface up or down, or assume ownership of the remote gateway. The
interface and transport fields are hints used to report whether the expected path
currently exists.

For example, a restricted HQ service gateway reachable only through `wg-agent`
can be recorded as:

```bash
sudo archangel-services gateway add hq 10.68.0.1 wg-agent wireguard

sudo archangel-services gateway service hq ollama-4060ti 11431 ollama
sudo archangel-services gateway service hq ollama-2080    11432 ollama
sudo archangel-services gateway service hq ollama-cpu     11433 ollama
sudo archangel-services gateway service hq searxng        8089  searxng
sudo archangel-services gateway service hq comfyui        8188  comfyui
sudo archangel-services gateway service hq firecrawl      3002  firecrawl
sudo archangel-services gateway service hq honcho         8000  honcho
```

The service name is descriptive metadata. The service itself is still stored in
the normal service registry, with provenance such as `gateway:hq/honcho`, so the
existing Hermes integration code can use it without a second endpoint model.

If quick/full discovery already recorded the same type and URL, explicitly adding
it to a gateway adopts that record instead of creating a duplicate. Gateway
provenance is preferred because it remains meaningful when the transient route is
later absent.

Inspect saved gateways without sending probes:

```bash
sudo archangel-services gateway status
```

The `PATH` column reports conditions such as `up:wg-agent`, `interface-down`,
`no-route`, or a route through an unexpected interface. A gateway remains saved
when its path is unavailable.

Probe the services for one gateway, or all saved gateways:

```bash
sudo archangel-services gateway probe hq
sudo archangel-services gateway probe
```

If the expected interface/route is absent, no service probes are sent and the
saved definition is retained. Archangel does not automatically activate the VPN.

Gateway definitions are stored in:

```text
/var/lib/archangel/gateways.tsv
```

They are Archangel state and disappear with Archangel uninstall, but the VPN,
remote system, containers, models, and services described by them are untouched.

## Known services

The initial discovery definitions are:

| Service | Typical port | Probe/integration |
| --- | ---: | --- |
| Ollama | 11434, plus configured gateway ports such as 11431-11433 | `/api/tags` or OpenAI-compatible `/v1/models`; may be selected as Hermes' custom model endpoint. |
| SearXNG | 8080 / 8089 | Identifies the SearXNG web service; configures `SEARXNG_URL` and `web.search_backend`. |
| Firecrawl | 3002 | Health endpoint; configures `FIRECRAWL_API_URL` and `web.extract_backend`. |
| Honcho | 8000 | `/health` or `/openapi.json`; records `HONCHO_BASE_URL` and can launch `hermes memory setup`. |
| ComfyUI | 8188 | `/system_stats`; endpoint is recorded but Archangel does not force a particular Hermes skill/MCP/provider integration. |
| OpenAI-compatible | user supplied | `/v1/models` or `/models`; recorded for manual/custom-provider setup. |

The service registry is deliberately small and identifiable. Archangel is not a
general-purpose port scanner.

## Stored service state

Discovered services are recorded in:

```text
/var/lib/archangel/services.tsv
```

Each entry tracks:

- whether the user enabled it for Hermes;
- service type;
- URL;
- how it was found (`local`, `quick`, `full`, `manual`, or `gateway:NAME/SERVICE`);
- network interface when applicable;
- whether Archangel manages the service itself.

Currently discovered and gateway-referenced services are always `managed=no`.

View the current registry with:

```bash
sudo archangel-services status
```

Add a known endpoint without scanning:

```bash
sudo archangel-services add http://hq:11434 ollama
sudo archangel-services add http://10.68.0.1:8089 searxng
```

Then apply supported Hermes settings:

```bash
sudo archangel-services apply
```

The discovery wizard can also be rerun at any time. Existing endpoints are
deduplicated and reviewed again rather than silently replaced.

## Hermes configuration boundary

Archangel uses Hermes' own CLI for settings that Hermes exposes as stable
configuration interfaces. It does not generate an entire `config.yaml` on
Hermes' behalf.

During installation Archangel can:

- install Hermes with the upstream installer under the dedicated agent account;
- configure a discovered SearXNG search backend;
- configure a discovered Firecrawl extraction backend;
- hand a Honcho endpoint to Hermes and launch the Hermes memory wizard;
- configure a selected Ollama model as a custom endpoint, including an optional
  explicit served context length;
- optionally launch `hermes setup` for model-provider authentication, tools,
  messaging, and settings that Hermes should own itself.

This keeps OAuth credentials, API keys, provider behavior, and Hermes schema
migration inside Hermes while Archangel handles host/network discovery and the
Linux security boundary.

## Verification

After configuration, Archangel rechecks every enabled service **as the agent
account**, not merely as root. An HTTP response such as `401` still proves that
the agent can reach the endpoint; provider credentials remain Hermes' concern.

Hermes' own `hermes doctor` runs after those connectivity checks.
