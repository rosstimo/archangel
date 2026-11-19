# Host inventory and recovery experiments

This work is **discovery first**, not unattended migration. It extends the
[development plan](plan.md). All machine inventory is private local data,
not repository content.

## Distinct machines

| Name | Hardware and current role | Policy |
| --- | --- | --- |
| Jimmy | Framework laptop running Arch Linux, existing Archangel-managed Hermes agent | Read-only inventory and safe experiments |
| New Jetson | Fresh Jetson Orin Nano installation, smaller-form-factor NVMe and user-reported additional tensor/AI accelerator | Read-only inventory, clean provisioning and later disposable restore tests |
| Jon | Original Jetson Orin Nano, standard NVMe, without the additional accelerator; existing independently configured Hermes agent | **Do not power up, reinstall, adopt, overwrite, or migrate as part of this phase** |

"Jon" means the **original agent-bearing Jetson**. The new Jetson is a separate
machine. The accelerator type, driver, bus, and capabilities on the new Jetson
are **unverified**. Do not assume an add-on accelerator or NVMe form factor is
interchangeable with the original machine.

The new Jetson may have Docker/JetPack tools preinstalled; that does not
establish that Hermes or Archangel has ever managed it.

## First pass: collect metadata safely

From a checkout of this branch, on Jimmy:

~~~bash
bash scripts/host-inventory.sh \
  --output-dir "$HOME/host-inventory-jimmy-$(date +%Y%m%d-%H%M%S)" \
  --agent-user jimmy
~~~

On the new Jetson, run the same script with a different new output directory,
omitting the agent-user flag until the desired agent account is known.
**Do not run install.sh to collect an inventory.**

The script writes a new mode-0700 directory with mode-0600 files and refuses
to write inside a Git worktree. It records identity, OS, storage, candidate
accelerator metadata, NetworkManager profile names, interface names, IPv4 routes,
systemd unit names, package names, Docker project/container/volume names, and
the agent home's top-level entry names. It does **not** open keyfiles, copy
credentials, inspect Docker environment variables, read unit bodies, or modify
the system.

The output is still **private**. Network names, hosts, routes, image names,
filesystem paths, and usernames can disclose infrastructure. Do not upload it
or copy it into Git without a separate review and redaction. This report is
only an inventory, not a backup.

An unprivileged run may omit root-owned NetworkManager profiles, container
metadata, and agent-home entries. Later, privileged inspection can use
narrowly scoped read-only helpers, with sensitive results staying local.
Do not grant the agent unrestricted root or Docker socket access to improve
inventory completeness.

Run the local smoke test before using the script on a real host:

~~~bash
bash tests/host-inventory-unit.sh
~~~

## What the agent must learn

Each host's living inventory should classify:

- **Unique data:** files, repositories with unpushed changes, local databases,
  Docker named volumes and bind mounts, agent memory and workspaces
- **Reproducible software:** OS/platform dependencies, package names, install
  origins, versions, Compose definitions, user and system services, custom scripts
- **Connections:** NetworkManager-managed VPN/Wi-Fi, allowed routes, DNS,
  systemd autoconnect, HQ gateway services and each connection's owning host
- **Secrets:** only a reference, owning service, required permission, and
  protected-backup status; never the secret value in an LLM-readable manifest
- **Hardware:** storage device size/model, bus and form factor if actually
  verified, GPU/accelerator identity, drivers/runtime, attached devices
- **Recovery status:** discovered, classified, protected, verified, test-restored

A system with an installed Docker image or working VPN today is **not**
automatically recoverable. Restoring a Compose definition without its volumes,
or an HQ endpoint without the WireGuard connection and remote peer authorization,
is insufficient.

## Recovery boundaries

1. Keep reusable code and secret-free procedures in Git. Keep even nonsecret
   host-specific topology in protected local inventory unless explicitly approved.
2. Store unique data, NetworkManager profiles/keys, credentials, and required
   private configuration in independently encrypted, off-host backups with a
   separately recoverable decryption key. Never print or commit those contents.
3. Use managed secret references in the inventory, not inline values. Preserve
   root-owned permissions on restoration. A future protected helper may back up
   keyfiles without giving Hermes their plaintext.
4. Recreate Archangel ACL grants against destination paths. **Never** import
   the old host's ACL rollback snapshots or assume UID/GID equality.
5. On replacement hardware, generate fresh device credentials and enroll the
   new WireGuard peer unless an authorized same-device restore specifically
   requires preserving identity. Remote Linode/HQ peer and firewall changes
   must be included in the recovery plan.
6. Do not activate restored agent schedules, outbound messaging, or privileged
   actions until the destination is verified and the old identity is retired.
7. Classify Docker application data by ownership and use application-consistent
   database backups. Merely archiving live Docker database files is inadequate.

## Testing order and exit criteria

1. **Jimmy:** run syntax/smoke test; capture private unprivileged inventory;
   compare it with live Archangel access/service status and Hermes state.
   Note discovered state not managed by Archangel, without modifying it.
2. **New Jetson:** capture a separate baseline and confirm OS/JetPack, NVMe
   model/form factor, accelerator model/bus/driver, installed Docker state,
   network connection names, and whether Hermes is absent or already present.
3. **Both:** classify VPN/HQ/Compose/service dependencies and propose exact
   protected-backup sources. Do not collect credential values in this phase.
4. **Disposable restore:** create an encrypted, verified backup of approved
   test data, restore into a separate destination, prove package and service
   reconstruction, and verify network access with a unique device identity.
5. **Jon:** no action until the previous steps prove safe migration,
   backup verification, and an independent rollback route.

The first pass passes when we can identify what is unique or missing and explain
how to recover it **without changing either tested host and without publishing
private inventory or credentials**.
