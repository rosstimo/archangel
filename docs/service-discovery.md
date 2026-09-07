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

Quick discovery probes only hosts already present in the kernel neighbor table for
the approved route. It does not walk every address in the subnet. This is useful
on ordinary Ethernet/Wi-Fi networks, but tunnel interfaces such as WireGuard often
have no neighbor table.

### Full network discovery

Full discovery uses `nmap` to check the known service ports across the approved
CIDR, then performs a service-specific HTTP probe against hosts with open ports.
Archangel asks before installing `nmap` if it is missing.

A full scan is never started merely because a route exists. The user must approve
the route and choose `full` for that route.

## Known services

The initial discovery definitions are:

| Service | Typical port | Probe/integration |
| --- | ---: | --- |
| Ollama | 11434 | `/api/tags` or OpenAI-compatible `/v1/models`; may be selected as Hermes' custom model endpoint. |
| SearXNG | 8080 / 8089 | Identifies the SearXNG web service; configures `SEARXNG_URL` and `web.search_backend`. |
| Firecrawl | 3002 | Health endpoint; configures `FIRECRAWL_API_URL` and `web.extract_backend`. |
| Honcho | 8000 | `/health` or `/openapi.json`; records `HONCHO_BASE_URL` and can launch `hermes memory setup`. |
| ComfyUI | 8188 | `/system_stats`; endpoint is recorded but Archangel does not force a particular Hermes skill/MCP/provider integration. |
| OpenAI-compatible | user supplied | `/v1/models` or `/models`; recorded for manual/custom-provider setup. |

The service registry is deliberately small and identifiable. Archangel is not a
general-purpose port scanner.

## Stored state

Discovered services are recorded in:

```text
/var/lib/archangel/services.tsv
```

Each entry tracks:

- whether the user enabled it for Hermes;
- service type;
- URL;
- how it was found (`local`, `quick`, `full`, or `manual`);
- network interface when applicable;
- whether Archangel manages the service itself.

Currently discovered services are always `managed=no`.

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
- launch `hermes setup` for model-provider authentication, tools, messaging, and
  settings that Hermes should own itself.

This keeps OAuth credentials, API keys, provider behavior, and Hermes schema
migration inside Hermes while Archangel handles host/network discovery and the
Linux security boundary.

## Verification

After configuration, Archangel rechecks every enabled service **as the agent
account**, not merely as root. An HTTP response such as `401` still proves that
the agent can reach the endpoint; provider credentials remain Hermes' concern.

Hermes' own `hermes doctor` runs after those connectivity checks.
