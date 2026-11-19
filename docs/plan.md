# Development plan

Updated: 2026-11-19

This document tracks **what to build next**. The [development progress](progress.md)
document retains historical implementation and test evidence. The [README](../README.md)
describes the project rather than acting as a changelog.

## Verified repository baseline

Repository inspection on 2026-11-19, before this plan was committed:

- `main`: `96c1e01f9a` (2026-09-07).
- `feature/hermes-service-discovery`: `b98b338da4` (2026-09-09), 53 commits
  ahead of `main`, zero behind, with no open PRs or issues.
- The feature branch includes isolated agent accounts, reversible ACL grants,
  Hermes installation/reuse, local `archangel-hermes` and dashboard wrappers,
  service discovery, saved HQ/VPN gateways, status, diagnostics, and uninstall.
- `docs/progress.md` records successful real-machine Hermes/HQ/WireGuard tests
  on the Framework laptop in September. These are **historical results**, not
  fresh validation on Jon or against the current Hermes release.
- Existing automated coverage is limited to `tests/discovery-unit.sh` and
  `tests/hermes-unit.sh`. The documented ACL/recovery and existing-account
  cases still need live testing.

The installer remains interactive; it does not yet implement `--auto`,
device-independent provisioning, persistent assignments, cost-aware inference,
or repeatable migration. A dashboard user service exists, but a complete
unattended-agent lifecycle has not been demonstrated.

## Operating principles

1. **Keep Archangel small.** Archangel provisions a Linux host, permissions,
   services, recovery, and integration. Hermes owns reasoning, tools, memory,
   skills, goals, and scheduling. Use upstream interfaces instead of forks.
2. **Unknown host is the default.** Detect the OS, hardware, software, devices,
   and reachable services; let the agent build a living inventory. Device
   profiles are optional shortcuts, not installation prerequisites.
3. **Autonomous within provisioned authority.** Permit full Hermes tool
   autonomy when explicitly selected, without running the entire agent as
   root. Grant host maintenance actions separately. Enforce physical actuator
   limits outside the reasoning agent.
4. **Local-first communication.** Terminal chat and a local report inbox work
   without Telegram, cloud messaging, or VPN. External channels are optional.
5. **Use resources sensibly.** Prefer existing local and HQ capacity when it
   can finish the job; spend paid tokens when they materially improve the
   outcome. Account for retries and task success, not just price per token.
   Do not burn tokens benchmarking without a demonstrated need.
6. **Make solutions repeatable.** Reuse known fixes before reasoning again.
   Turn recurring work into tested scripts and skills. Retain useful failures,
   verify results programmatically, and avoid regressions.
7. **Keep secrets outside Git.** NetworkManager owns WireGuard keys and
   connections. Archangel records only the routes and services it needs.
   Credentials and backup material remain protected and independently managed.

## Implementation sequence

### 0. Stabilize the existing feature branch

- [ ] Reconcile the installer, launcher, configuration writes, dashboard, and
  updater with the current upstream Hermes CLI and install layout. Replace
  internal Python/`venv` assumptions with supported interfaces where possible.
- [ ] Run and extend shell tests; add real tests for ACL grant/sync/revoke/reset,
  interrupted recovery, existing account/runtime reuse, and uninstall provenance.
- [ ] Test local dashboard access and authorization on a multiuser Linux host.
- [ ] Repeat the existing install/status/chat/HQ discovery checks on the
  Framework and on Jon. Record actual Hermes, Ubuntu/JetPack, and Archangel
  versions in `docs/progress.md`.
- [ ] Merge the feature branch to `main` only after these checks pass.

**Exit test:** Existing Jimmy installation still works, a fresh installation
can be diagnosed and removed safely, and supported upstream Hermes commands
are used.

### 0A. Inventory existing systems before changing them

- [ ] Run the read-only private host inventory on Jimmy and on the **new**
  Jetson. Compare actual host state against historical Archangel records.
- [ ] Record unique files, active services, package origins, Docker/Compose
  data, NetworkManager/WireGuard dependencies, HQ gateways, and backup
  ownership. Do not read secret values into agent-visible output.
- [ ] Confirm the new Jetson's smaller-form-factor NVMe and the model, bus,
  driver, and capabilities of its additional tensor/AI accelerator. Do not
  assume it matches the original Jetson's hardware.
- [ ] Implement approved encrypted backup and verified disposable restore of
  data and host-specific settings, including recovery of remote-side VPN
  enrollment. Keep private inventory, keyfiles, and credentials out of Git.
- [ ] Leave the **original Jon** powered down and unchanged until restore,
  rollback, and unique agent identity have been validated on test machines.

See [host inventory and recovery experiments](recovery-inventory.md) for
machine identities, safe test commands, security boundaries, and exit criteria.

**Exit test:** Jimmy and the new Jetson have private, reviewed inventories,
known unique-state candidates, and a testable recovery plan. Original Jon
has not been touched.

### 1. Make first boot simple and autonomous

- [ ] Provide one `archangel` entry point for `chat`, `ask`, `status`,
  and `doctor`, forwarding to Hermes under the configured agent account.
- [ ] Add repeatable `archangel install --auto` provisioning for an unknown
  Linux host, with optional explicit settings for account identity, inference,
  service discovery, and autonomy. Preserve a readable interactive mode.
- [ ] Detect platform capabilities with ordinary system commands. Store a
  small, regenerable inventory rather than a hard-coded profile.
- [ ] Provide persistent agent/gateway startup using systemd, with reboot
  recovery, diagnostics, and a no-Telegram local communication path.
- [ ] Offer an explicit autonomous mode which configures Hermes approvals,
  without implicitly giving the agent unlimited sudo, secret access, or
  direct authority over hazardous actuators.

**Exit test:** On a newly installed Jon, Archangel installs natively, a human
can chat locally, the agent can inspect its hardware, and it resumes service
after reboot.

### 2. Support assignments that outlive a chat session

- [ ] Let a user give a goal, deadline, and reporting destination in natural
  language, such as "figure out this machine and report by Tuesday".
- [ ] Use Hermes goals/cron and systemd where appropriate instead of writing
  a second scheduler. Persist compact task state, evidence, and last progress.
- [ ] Provide a local report inbox and later optional desktop/remote
  notifications. Make missed runs, failures, and deadlines visible.

**Exit test:** An assignment survives a restart, does useful work without an
open terminal, and deposits a report by its configured deadline.

### 3. Improve efficiency through actual use

- [ ] Discover local and approved HQ inference endpoints; configure sensible
  fallbacks for outages and weak models, with paid providers as authorized.
- [ ] Track per-task outcome, retries, time, and token/cost use. Limit spending
  and optimization experiments; never open paid accounts or buy resources
  without separate authorization.
- [ ] Capture repeatable fixes as version-controlled Hermes skills with
  scripts, tests, and concise instructions. Prefer deterministic execution
  on later runs and only invoke reasoning for exceptions.
- [ ] Allow agents to share *verified, sanitized* reusable skills through HQ,
  not private host state or credentials.

**Exit test:** A recurring diagnostic or repair reuses a tested script, and
loss of HQ connectivity produces a controlled fallback rather than an
unbounded retry loop.

### 4. Restore or migrate agents between hosts

- [ ] Use upstream Hermes backup/import for agent state; separately capture
  Archangel's nonsecret host integration and capability inventory.
- [ ] Restore onto different hardware by re-detecting devices and reapplying
  only compatible permissions and services.
- [ ] Leave VPN credentials with NetworkManager or a separate protected
  enrollment/backup workflow; no WireGuard private keys in Git.
- [ ] Test a clean install, backup, restore, rollback, and non-destructive
  removal on at least two different Linux hosts.

**Exit test:** A replacement device can adopt an agent's useful state without
copying incompatible drivers, private host keys, or stale hardware paths.

## Immediate next change

Start with **phase 0**, then implement the smallest possible `archangel`
CLI and unattended setup for Jon. Do not introduce a profile registry,
custom message broker, inference orchestrator, or benchmarking service unless
a real use case demonstrates why Hermes and ordinary Linux tools are
insufficient.
