# Development progress

This document tracks implementation and validation. The [README](../README.md)
describes the project; [installation and usage](usage.md) documents its commands.

## Implementation status

As of 2026-09-07, `feature/hermes-service-discovery` extends the host bootstrap
through Hermes installation, user-controlled service discovery, and persistent
service-gateway metadata. It has not yet been merged to `main`.

Implemented on the feature branch:

- Interactive host bootstrap with a configurable, dedicated non-root agent account.
- Installation-time detection of pre-existing sudo authority inherited from host
  sudoers policy, with an explicit acknowledgement required before proceeding.
- Optional systemd journal access, with the original membership recorded for uninstall.
- `archangel-access` commands for granting, revoking, synchronizing, checking,
  and auditing filesystem access, plus reset and recovery.
- ACL snapshots and shared parent-traversal tracking for restoring managed permissions.
- Optional Hermes Agent installation under the dedicated agent account, using the
  upstream Hermes installer and setup/doctor commands.
- Conservative Hermes defaults: browser/computer-use components and the full Hermes
  setup wizard are opt-in rather than part of the default Archangel baseline.
- Hermes installation provenance so a pre-existing runtime is not removed as an
  Archangel-owned installation.
- Optional service discovery with independent choices for local-machine discovery,
  LAN/VPN discovery, direct URL entry, or skipping discovery entirely.
- Per-route network approval. Private LAN/VPN routes receive convenient defaults;
  container/virtual and public-looking routes remain opt-in.
- Quick network discovery from the kernel neighbor table plus direct probing of
  explicitly routed IPv4 `/32` targets, with separately authorized full CIDR scans.
- Initial service probes for Ollama, SearXNG, Firecrawl, Honcho, ComfyUI, and
  OpenAI-compatible endpoints.
- `/var/lib/archangel/services.tsv` endpoint state recording enablement, service
  type, URL, discovery source, interface, and management provenance.
- Persistent named service gateways in `/var/lib/archangel/gateways.tsv`, with host,
  interface, and transport hints that survive temporary VPN/network unavailability.
- Gateway-owned service provenance such as `gateway:hq/honcho` without duplicating
  the endpoint model used by normal service discovery.
- `archangel-services gateway add`, `service`, `status`, and `probe` commands.
- Gateway path reporting without starting, editing, or owning the hinted VPN or
  network interface.
- `archangel-services status`, `discover`, `add`, and `apply`, allowing discovery
  and integration to be changed after initial installation.
- Supported Hermes handoff for SearXNG search, Firecrawl extraction, Honcho memory
  setup, and optional Ollama custom-model configuration.
- Hermes environment-style service values are persisted through Hermes' own `.env`
  writer while backend selections remain in `config.yaml`.
- ComfyUI endpoint discovery without forcing one Hermes integration mechanism.
- Selected-service reachability checks executed as the agent account, followed by
  Hermes diagnostics.
- Agent-command isolation resets both `HOME` and the working directory before
  invoking Hermes or other commands as the agent account.
- User-systemd preparation for Hermes gateway services, including optional systemd
  linger and provenance for uninstall.
- `archangel-diagnostic` and a first-task guide for a read-only system check.
- Uninstall with ACL restoration, account cleanup choices, package provenance,
  Hermes-runtime provenance, systemd-linger provenance, and a report of residual
  state and manual cleanup steps.

Scheduled checks, notification policy, and richer persistent-agent lifecycle
management remain future work.

## Service-discovery design choices

Discovery is deliberately user-controlled. Merely having a route does not authorize
a scan. The installer asks whether to run discovery, asks separately about LAN/VPN
probing, and asks about each routed subnet before sending network probes. Full CIDR
scans require another explicit choice.

Point-to-point VPNs need a different quick-discovery rule than Ethernet/Wi-Fi. A
WireGuard route such as `10.68.0.1/32 dev wg-agent` names exactly one remote host,
so Archangel can probe that host directly even though the interface has no ARP
neighbor table. Broader routes still require saved gateway metadata, explicit URL
entry, or a deliberately approved scan.

Saved gateways are metadata, not transport ownership. Archangel can remember that
`hq` is reached at `10.68.0.1` through `wg-agent`, but it does not create WireGuard
keys, edit `/etc/wireguard`, start/stop the tunnel, or alter the remote gateway.
When the route disappears, the gateway remains recorded and is reported as
unavailable rather than deleted.

Discovered services are references, not owned resources. Archangel does not add the
agent to the Docker group just because a containerized service was found, and it
does not remove remote/LAN/VPN services during uninstall.

See [`service-discovery.md`](service-discovery.md) for the current behavior and
Hermes configuration boundary.

## Review follow-up

The review of [`1c30286`](https://github.com/rosstimo/archangel/commit/1c30286)
identified five access-management issues. Subsequent hardening work added the
following responses. These are implementation changes, not a claim that the
current version has passed end-to-end validation.

| Review finding | Implementation response |
| --- | --- |
| Revocation could report success after ACL-removal failures. | Restore saved ACLs and retain recovery state when restoration fails. |
| Parent and child grants could overwrite or revoke each other's permissions. | Reject overlapping grant roots and track shared traversal access separately. |
| Original ACL entries and masks were not preserved for restoration. | Snapshot complete ACL state before changes and restore it during revoke or reset. |
| Reinstalling with another agent account could strand the old account's access. | Require uninstall before changing the configured agent identity. |
| The installer accepted a root agent account. | Reject root as the agent account. |

Directory grants do not add default ACLs. New or moved-in files are handled by
`sync`, which snapshots each newly managed object before applying access.

## Validation

Development checks completed for the service-discovery work:

- [x] Bash syntax/unit harness for discovery and Hermes configuration helpers.
- [x] Discovery registry creation, normalization, deduplication, and provenance checks.
- [x] Mock Hermes configuration calls for selected SearXNG and Firecrawl endpoints.
- [x] Review of the committed branch integration between `install.sh`,
  `archangel-services`, discovery helpers, Hermes helpers, and `uninstall.sh`.
- [x] Real-machine clean uninstall and feature-branch installation on Arch Linux.
- [x] Full installer-driven Hermes 0.21.0 fresh install under a newly created isolated
  agent account, without manual recovery or repair.
- [x] Installation provenance recorded Hermes, account creation, journal membership,
  and systemd linger accurately in `/var/lib/archangel/install.env`.
- [x] Regression test proving agent commands start in the agent home with matching
  `HOME` rather than inheriting the human user's source checkout.
- [x] Real quick-LAN discovery of SearXNG and ComfyUI on `192.168.77.249` as the
  isolated agent account.
- [x] Real agent-account HTTP reachability of the discovered SearXNG endpoint.
- [x] Real SearXNG handoff through Hermes' `.env` writer; Hermes doctor reports
  `web search (searxng)` available.
- [x] User-systemd manager and tracked linger preparation succeeded for the fresh
  agent account.
- [x] Docker CLI presence does not grant Docker authority; the isolated agent was
  denied access to `/var/run/docker.sock`.
- [x] Clean uninstall of an installer-created account removed the account, its home
  and Hermes installation, Archangel config/state, journal membership, and the
  systemd linger state that Archangel enabled.
- [x] Real WireGuard path from `fw` (`10.68.0.3`) through the Linode hub
  (`10.68.0.254`) to the HQ service gateway (`10.68.0.1`) established with no NAT.
- [x] Linode and HQ firewall policy verified to allow only approved service TCP ports
  from remote agent peers, with return traffic statefully limited.
- [x] End-to-end HTTP/API reachability from `fw` to all current HQ gateway services:
  Ollama 11431/11432/11433, SearXNG 8089, ComfyUI 8188, Firecrawl 3002, and Honcho 8000.

### Live test observations, 2026-09-07

The real-machine tests exposed several useful distinctions:

- Hermes installation originally failed because the root installer invoked Hermes as
  the agent user while retaining the human user's working directory. `uv` encountered
  the human checkout's inaccessible `.venv`. Resetting the agent working directory to
  its own home fixed the install without weakening filesystem isolation.
- A subsequent completely fresh run installed Hermes 0.21.0 through Archangel itself,
  proving the working-directory fix and installation provenance path end to end.
- Quick LAN discovery uses the kernel neighbor table. SearXNG at
  `http://192.168.77.249:8089` was discoverable once the `hq` host was present in that
  table. This confirms service probing works while also identifying cold-start LAN
  host discovery as an area for improvement.
- ComfyUI was also discovered at `http://192.168.77.249:8188` but deliberately left
  disabled during the review step.
- Ollama, Firecrawl, and Honcho on `hq` are intentionally exposed through a restricted
  WireGuard service gateway at `10.68.0.1`, not directly on the home LAN.
- The Linode `wg-agent-hub` is a real routed WireGuard hub, not a NAT relay. It owns
  `10.68.0.254/24`; HQ is `10.68.0.1/32`; the Jetson/Hermes peer is `10.68.0.2/32`;
  and the Framework test peer is `10.68.0.3/32`. Source addresses are preserved.
- Linode forwarding rules allow agent peers to initiate only to approved HQ API ports
  and allow HQ only established/related return traffic. HQ independently filters the
  same inbound service ports on its `wg0` interface.
- The VPN investigation found persistent/live firewall drift: Honcho port 8000 was
  present in live rules but missing from saved scripts/config. Both Linode and HQ
  persistent rules were corrected while adding the Framework peer.
- On `fw`, `wg-agent` routes only `10.68.0.1/32`; ordinary LAN and Internet traffic
  remain outside this tunnel. All seven gateway services responded successfully.
- This topology confirms why neighbor-only WireGuard discovery was inadequate. The
  branch now directly probes routed `/32` VPN targets and adds a saved gateway model
  for conditional paths that should remain known while the interface is down.
- The first Hermes setup attempt reproduced a user-service failure under a plain
  `sudo -u` invocation. The fresh installer-driven run then successfully enabled
  tracked linger and brought up the agent's user systemd manager before Hermes setup.
- SearXNG initially exposed a configuration-boundary bug when its URL was written as
  an arbitrary YAML key. The fresh run persisted the URL in `.env`, selected the
  SearXNG backend in `config.yaml`, and verified HTTP reachability as the agent.
- The fresh agent inherited `NOPASSWD: /usr/bin/asdcontrol` because the host contains
  the machine-wide sudoers rule `ALL ALL=(ALL) NOPASSWD: /usr/bin/asdcontrol`.
  Archangel did not create that authority, but it weakens the non-privileged boundary;
  the installer now detects pre-existing sudo command authority and requires explicit
  acknowledgement rather than silently proceeding.
- Browser automation defaulted on during the validated run, causing the upstream
  installer to attempt root-only Playwright package setup and fall back to downloaded
  browser binaries. Archangel now defaults browser/computer-use components off and
  also defaults the full Hermes setup wizard off, keeping the baseline installation
  deliberately narrow.
- A clean uninstall of the installer-created state disabled Archangel-enabled linger,
  terminated remaining agent processes when approved, removed the agent account/home,
  and removed `/etc/archangel.conf` and `/var/lib/archangel`.

Still to verify on a disposable or test Linux setup:

- [ ] Real ACL grant, sync, revoke, and reset behavior.
- [ ] Preservation of existing ACL entries, masks, and unrelated effective access.
- [ ] Overlap rejection and restoration of shared parent-traversal permissions.
- [ ] Recovery after interrupted operations or failed ACL restoration.
- [ ] Reuse of an existing account, root rejection, and account-change protection.
- [ ] Hermes reuse of a pre-existing runtime and deliberate Hermes-install skip.
- [ ] Installation-time inherited-sudo warning/acknowledgement on a host with a
  matching sudoers rule.
- [ ] Conservative browser/computer-use and full-Hermes-setup defaults on a fresh run.
- [ ] Quick LAN discovery from a cold neighbor table without prior contact with the target host.
- [ ] New routed-`/32` quick VPN discovery behavior on the real `wg-agent` interface.
- [ ] Saved gateway `status`/`probe` behavior on the real HQ route while WireGuard is
  active and again after the interface is intentionally brought down.
- [ ] Uninstall behavior when the agent account, Hermes runtime, or linger state existed
  before Archangel and therefore must be preserved.

One non-destructive wording/provenance refinement remains: the current install state
records whether Hermes was installed by Archangel, but `no` can mean either that
Hermes already existed or that installation was skipped. Removal behavior is safe in
both cases, but a future state field should distinguish those origins so uninstall can
report them precisely.

## Development record

- `a807963`: initialized the project.
- `1c30286`: added bootstrap, access management, diagnostics, and first-task documentation.
- `08d8e9d`: hardened ACL state handling and added clean uninstall.
- `627222c`: recorded ACL package provenance for uninstall.
- `b695fec`: added uninstall residual reporting and manual cleanup guidance.
- `70b4abf`: documented uninstall residuals and cleanup.
- `1e68b03`: added service discovery, Hermes integration helpers, the service command,
  and discovery unit coverage.
- `77a80aa`: integrated Hermes installation and service discovery into `install.sh`.
- `7d5be7d`: added Hermes-aware uninstall behavior and service-state cleanup.
- `d6f2607`: updated the project overview for Hermes/service integration.
- `5603424`: documented service discovery and the Hermes configuration boundary.
- `5b2325e`: documented installation, post-install service management, and Hermes
  uninstall provenance.
- `d29e8d2`: reset agent commands to the agent home before execution.
- `439eaa7`: added the agent working-directory regression test.
- `08d4e9f`: moved Hermes service environment settings to Hermes' `.env` writer and
  added user-systemd runtime support.
- `945e2ab`: prepared the agent user manager and tracked optional linger during install.
- `d31cabb`: added linger-aware uninstall behavior.
- `17c3727`: expanded Hermes helper regression coverage for `.env` persistence.
- `9c6830c`: added installation-time detection of pre-existing agent sudo authority.
- `ceff89f`: made browser/computer-use components and the full Hermes setup wizard
  opt-in defaults.
- `d4fff7a` / `eacf92c`: added persistent service gateways, routed `/32` VPN discovery,
  and gateway adoption of transiently discovered service records.
- `9faf8eb`: exposed gateway management through `archangel-services`.
- `48a0f3c`: added saved-gateway and point-to-point VPN discovery regression coverage.

Keep implementation updates, validation results, and open issues here as work
continues. Update the README when the project's purpose or documentation entry
points change.
