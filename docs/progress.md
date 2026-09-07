# Development progress

This document tracks implementation and validation. The [README](../README.md)
describes the project; [installation and usage](usage.md) documents its commands.

## Implementation status

As of 2026-09-07, `feature/hermes-service-discovery` extends the host bootstrap
through Hermes installation and user-controlled service discovery. It has not
yet been merged to `main`.

Implemented on the feature branch:

- Interactive host bootstrap with a configurable, dedicated non-root agent account.
- Optional systemd journal access, with the original membership recorded for uninstall.
- `archangel-access` commands for granting, revoking, synchronizing, checking,
  and auditing filesystem access, plus reset and recovery.
- ACL snapshots and shared parent-traversal tracking for restoring managed permissions.
- Optional Hermes Agent installation under the dedicated agent account, using the
  upstream Hermes installer and setup/doctor commands.
- Hermes installation provenance so a pre-existing runtime is not removed as an
  Archangel-owned installation.
- Optional service discovery with independent choices for local-machine discovery,
  LAN/VPN discovery, direct URL entry, or skipping discovery entirely.
- Per-route network approval. Private LAN/VPN routes receive convenient defaults;
  container/virtual and public-looking routes remain opt-in.
- Quick network discovery from the kernel neighbor table and separately authorized
  full CIDR scans using known service ports.
- Initial service probes for Ollama, SearXNG, Firecrawl, Honcho, ComfyUI, and
  OpenAI-compatible endpoints.
- `/var/lib/archangel/services.tsv` endpoint state recording enablement, service
  type, URL, discovery source, interface, and management provenance.
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

Scheduled checks, notification policy, service-gateway definitions, and richer
persistent-agent lifecycle management remain future work.

## Service-discovery design choices

Discovery is deliberately user-controlled. Merely having a route does not authorize
a scan. The installer asks whether to run discovery, asks separately about LAN/VPN
probing, and asks about each routed subnet before sending network probes. Full CIDR
scans require another explicit choice.

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
- [x] Real Hermes 0.21.0 installation under an isolated agent account after fixing
  inherited-working-directory leakage. `hermes doctor` executes successfully.
- [x] Regression test proving agent commands start in the agent home with matching
  `HOME` rather than inheriting the human user's source checkout.
- [x] Real quick-LAN discovery of SearXNG and ComfyUI on `192.168.77.249` as the
  isolated agent account.
- [x] Real agent-account HTTP reachability of the discovered SearXNG endpoint.
- [x] Reproduced Hermes gateway user-service failure when the agent lacked a user
  D-Bus/systemd session; branch now prepares the user manager and optionally enables
  tracked systemd linger before setup.
- [x] Reproduced SearXNG configuration mismatch when `SEARXNG_URL` was written as an
  arbitrary YAML key; branch now persists it through Hermes' `.env` writer.

### Live test observations, 2026-09-07

The first real-machine test exposed several useful distinctions:

- Hermes installation originally failed because the root installer invoked Hermes as
  the agent user while retaining the human user's working directory. `uv` encountered
  the human checkout's inaccessible `.venv`. Resetting the agent working directory to
  its own home fixed the install without weakening filesystem isolation.
- Quick LAN discovery uses the kernel neighbor table. SearXNG at
  `http://192.168.77.249:8089` was discoverable once the `hq` host was present in that
  table. This confirms service probing works while also identifying cold-start host
  discovery as an area for improvement.
- ComfyUI was also discovered at `http://192.168.77.249:8188` but deliberately left
  disabled during the review step.
- Ollama, Firecrawl, and Honcho on `hq` were correctly absent from LAN discovery. They
  are intentionally exposed through a restricted WireGuard service gateway at
  `10.68.0.1`, not directly on the home LAN.
- `hq` uses a `wireguard-agent` container with `wg0=10.68.0.1/32`; `agent-proxy`
  shares that container's network namespace and binds selected HAProxy frontends for
  Ollama, SearXNG, ComfyUI, Firecrawl, and Honcho. This motivates a future saved
  service-gateway abstraction rather than trying to infer those endpoints from an
  inactive VPN route.
- Hermes setup migrated config to v41 successfully, but gateway service installation
  failed under a plain `sudo -u` invocation because the service account had no user
  systemd D-Bus. The current branch now prepares that manager and can enable linger.

Still to verify on a disposable or test Linux setup:

- [ ] Real ACL grant, sync, revoke, and reset behavior.
- [ ] Preservation of existing ACL entries, masks, and unrelated effective access.
- [ ] Overlap rejection and restoration of shared parent-traversal permissions.
- [ ] Recovery after interrupted operations or failed ACL restoration.
- [ ] Fresh install, reuse of an existing account, root rejection, and account-change protection.
- [ ] Full installer-driven Hermes fresh install after the working-directory fix, including
  provenance recording rather than the manual recovery used in the first test.
- [ ] Hermes reuse of a pre-existing runtime and deliberate Hermes-install skip.
- [ ] Re-run service apply after the `.env` persistence fix and verify Hermes reports
  SearXNG as configured and usable.
- [ ] Hermes gateway service installation after user-systemd/linger preparation.
- [ ] Quick LAN discovery from a cold neighbor table without prior contact with the target host.
- [ ] VPN discovery where no neighbor table exists, including direct URL entry and
  an explicitly approved full scan.
- [ ] Saved service-gateway behavior for endpoints reachable only through a conditional VPN path.
- [ ] Hermes setup/configuration behavior with real provider credentials and a
  self-hosted Honcho instance.
- [ ] Uninstall behavior for journal membership, retained accounts, agent-owned files,
  Hermes provenance, systemd-linger provenance, package provenance, and reported residual state.

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

Keep implementation updates, validation results, and open issues here as work
continues. Update the README when the project's purpose or documentation entry
points change.
