# Installation and usage

See [development progress](progress.md) for implementation status, review
follow-up, and pending validation.

## Quick start

```bash
git clone https://github.com/rosstimo/archangel.git
cd archangel
./install.sh
```

The installer asks which human account owns the files the agent may eventually
work with and what Unix username should run the agent. `hermes` is only the
default. The account name is not hard-coded into the management tools. `root`
is explicitly rejected as an agent account.

An existing Archangel installation must be uninstalled before changing the
configured agent account. This prevents ACL state belonging to an old agent
identity from being stranded.

The installer can install Hermes Agent under the dedicated agent account, or
reuse a Hermes installation that is already present there. It then offers
optional service discovery. Local-machine discovery is suggested by default;
LAN/VPN probing, full network scans, and direct URL entry remain explicit user
choices and can all be skipped.

After installation:

```bash
sudo archangel-access status
sudo archangel-services status
sudo -u hermes -H archangel-diagnostic
```

If you chose a different agent username, use that username in the third command.

## Hermes and service discovery

Archangel treats Hermes as the agent runtime while keeping host integration,
service discovery, and Linux permissions under Archangel's control. It uses
Hermes' own setup/configuration interfaces where practical rather than creating
an entire Hermes configuration file itself.

During installation you may:

- install Hermes or keep an existing installation;
- discover supported services on the local machine;
- inspect reachable LAN and VPN routes and choose exactly which networks may be
  probed;
- choose quick discovery from known neighbors or explicitly request a full
  `nmap` scan for an approved CIDR;
- enter service URLs directly instead of scanning;
- enable or disable each discovered service for Hermes;
- run the Hermes setup wizard for provider authentication and other Hermes-owned
  settings;
- verify selected endpoints from the agent account and run `hermes doctor`.

The initial known-service set includes Ollama, SearXNG, Firecrawl, Honcho,
ComfyUI, and OpenAI-compatible endpoints. See
[`service-discovery.md`](service-discovery.md) for the current probes,
configuration boundary, and network-discovery behavior.

Discovery and configuration can be revisited after installation:

```bash
sudo archangel-services status
sudo archangel-services discover
sudo archangel-services add http://host:port [TYPE]
sudo archangel-services apply
```

`discover` reruns the interactive local/LAN/VPN/manual discovery wizard and asks
which recorded endpoints Hermes should use. `add` records a direct endpoint and
attempts to identify its type when `TYPE` is omitted. `apply` applies the
supported Hermes settings for enabled services.

Service records are stored in `/var/lib/archangel/services.tsv`, including how
the endpoint was found and whether Archangel manages it. A service merely found
on localhost, a LAN, or a VPN is not considered Archangel-owned and will not be
removed by uninstall.

## Filesystem access

Grant read/write access to a config tree:

```bash
sudo archangel-access grant rw "$HOME/.config/hypr"
```

Grant read-only access:

```bash
sudo archangel-access grant ro "$HOME/some/reference-material"
```

Before Archangel changes an ACL, it saves that object's complete ACL state.
Revocation restores the saved state rather than merely deleting the agent's ACL
entry. This also restores ACL masks that may have changed when the named user
entry was added.

Archangel intentionally does not install default ACL entries on managed
directories. That keeps rollback deterministic. If another user creates or
moves new files into an already granted tree, synchronize the grant before the
agent needs those files:

```bash
sudo archangel-access sync "$HOME/.config/hypr"
```

`sync` snapshots each new object before granting access to it. Running `sync`
without a path synchronizes all active grants.

Inspect effective access as the agent:

```bash
sudo archangel-access check "$HOME/.config/hypr"
sudo archangel-access audit write "$HOME"
sudo archangel-access audit read /
```

Revoke a managed grant:

```bash
sudo archangel-access revoke "$HOME/.config/hypr"
```

If ACL restoration fails, `revoke` exits with an error and retains its recovery
state for another attempt. It does not report a successful revoke until the
saved state has been restored.

### Overlapping grants

Managed grant roots may not overlap. For example, after granting
`$HOME/.config`, Archangel will reject a separate grant for
`$HOME/.config/hypr` until the parent grant is revoked.

This is deliberate. A parent and child grant with independent rollback
snapshots can otherwise overwrite one another during revocation. Non-overlapping
grants may share inaccessible parent directories; Archangel reference-counts
those traversal-only ACLs and restores the original parent ACL when the last
independent grant is removed.

## Journal access

The installer can add the agent account to `systemd-journal`. It can also be
changed later:

```bash
sudo archangel-access journal enable
sudo archangel-access journal disable
```

The installer records whether the account already had journal access before
Archangel. Uninstall restores that original membership state.

Existing agent processes need to be restarted after group membership changes.

## Recovery and reset

To restore every managed filesystem ACL change without uninstalling Archangel:

```bash
sudo archangel-access reset
```

`reset` also retries recovery state left by an interrupted or partially failed
grant. Archangel refuses to create new grants while incomplete recovery state
exists.

## Uninstall

A normal clean uninstall is:

```bash
sudo archangel-uninstall
```

The uninstaller first runs the same ACL restoration used by `reset`. If that
restoration fails, uninstall stops and keeps the state files needed for another
attempt rather than deleting evidence of what changed.

It then restores the agent's pre-install journal membership and removes the
Archangel binaries, configuration, libraries, and state directory. If
Archangel created the agent account, the uninstaller offers to remove that
account and its home directory. An account that existed before Archangel is
never removed implicitly.

If an Archangel-created agent owns files inside previously managed trees, the
uninstaller offers to reassign those files to the configured human owner before
deleting the account so it does not silently leave orphaned numeric ownership.

Hermes provenance is tracked separately. If Hermes existed before Archangel, it
is left untouched. If Archangel installed Hermes and the agent account is being
kept, uninstall offers to run Hermes' upstream runtime uninstaller. Archangel
does not assume permission to perform Hermes' full data/configuration removal.
If the entire Archangel-created agent account is removed, its home directory and
Hermes installation disappear with that account.

At the end, the uninstaller prints a **What may remain** report with the items
that Archangel intentionally does not remove and manual cleanup guidance.
Depending on how the machine was configured, those can include:

- **The agent account and home directory.** A pre-existing account is always
  preserved, and an Archangel-created account remains if the user chooses to
  keep it. If it is no longer needed, remove it manually with `userdel -r`
  after reviewing its files.
- **Hermes user data/configuration.** When Archangel installed Hermes but the
  account is retained, the upstream runtime uninstaller may intentionally leave
  Hermes configuration and user data in the agent home.
- **The distro `acl` package.** The installer records whether Archangel had
  to install this package. Uninstall leaves it installed because another
  program may depend on it. If Archangel installed it and the user wants it
  gone, the uninstall report prints the appropriate package-manager command.
- **The Git source checkout.** The directory from which `install.sh` was run is
  not part of the installed system state. Delete that clone manually if it is
  no longer wanted.
- **Files owned by the agent outside managed grant trees.** Archangel does not
  scan the entire machine during uninstall. The report preserves the numeric
  UID and prints a `find` command that can be used to locate remaining files
  before changing ownership or deleting them.
- **Discovered or separately installed services and data.** LAN/VPN services,
  containers, models, and software that Archangel did not install are untouched.

For example, after an uninstall the ownership audit shown by the script is
similar to:

```bash
sudo find / \
  \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
  -uid AGENT_UID -print 2>/dev/null
```

Review those results before changing ownership or deleting anything. The goal
is to make residual state visible without having an uninstall script guess that
a shared package, user account, runtime, or unrelated file is safe to remove.

## First task

See [`first-task.md`](first-task.md) for a cautious first diagnostic
and an example prompt that asks the agent to inspect the machine without making
changes.
