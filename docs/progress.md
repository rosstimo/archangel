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
- ComfyUI endpoint discovery without forcing one Hermes integration mechanism.
- Selected-service reachability checks executed as the agent account, followed by
  Hermes diagnostics.
- `archangel-diagnostic` and a first-task guide for a read-only system check.
- Uninstall with ACL restoration, account cleanup choices, package provenance,
  Hermes-runtime provenance, and a report of residual state and manual cleanup steps.

Persistent agent operation, scheduled checks, notification policy, and richer
service definitions remain future work.

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

The current execution environment cannot clone GitHub directly, so the feature
branch still needs real-machine end-to-end testing before merge.

Still to verify on a disposable or test Linux setup:

- [ ] Real ACL grant, sync, revoke, and reset behavior.
- [ ] Preservation of existing ACL entries, masks, and unrelated effective access.
- [ ] Overlap rejection and restoration of shared parent-traversal permissions.
- [ ] Recovery after interrupted operations or failed ACL restoration.
- [ ] Fresh install, reuse of an existing account, root rejection, and account-change protection.
- [ ] Hermes fresh install, reuse of a pre-existing Hermes runtime, and deliberate
  Hermes-install skip.
- [ ] Local service discovery against real Ollama/SearXNG/Firecrawl/Honcho/ComfyUI services.
- [ ] Quick LAN discovery on a normal Ethernet/Wi-Fi route.
- [ ] VPN discovery where no neighbor table exists, including direct URL entry and
  an explicitly approved full scan.
- [ ] Agent-account reachability of services found by root during discovery.
- [ ] Hermes setup/configuration behavior with real provider credentials and a
  self-hosted Honcho instance.
- [ ] Uninstall behavior for journal membership, retained accounts, agent-owned files,
  Hermes provenance, package provenance, and reported residual state.

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

Keep implementation updates, validation results, and open issues here as work
continues. Update the README when the project's purpose or documentation entry
points change.
