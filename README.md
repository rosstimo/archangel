# Archangel

Archangel is an early-stage collection of Linux host setup and management tools
for running a persistent AI system helper under a dedicated Unix account.

The project is intentionally small right now. The first goal is to make the
permission boundary understandable and reversible before adding more agent
behavior.

## Current pieces

- interactive host bootstrap
- dedicated non-root agent Unix account
- optional systemd journal access for diagnostics
- `archangel-access` for granting, revoking, checking, synchronizing, and auditing filesystem access
- ACL snapshots so managed permission changes can be restored exactly
- `archangel-diagnostic` for a read-only first system check
- `archangel-uninstall` for restoring Archangel-managed state and removing the installation

Archangel does **not** currently automate installation of a particular AI agent
runtime. That can be added once the host boundary is working well in practice.

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

After installation:

```bash
sudo archangel-access status
sudo -u hermes -H archangel-diagnostic
```

If you chose a different agent username, use that username in the second
command.

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
dependent grant is removed.

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
Archangel binaries, configuration, and state directory. If Archangel created
the agent account, the uninstaller offers to remove that account and its home
directory. An account that existed before Archangel is never removed
implicitly.

If an Archangel-created agent owns files inside previously managed trees, the
uninstaller offers to reassign those files to the configured human owner before
deleting the account so it does not silently leave orphaned numeric ownership.

Shared system packages such as the distro's `acl` package are not removed by
uninstall.

## First task

See [`docs/first-task.md`](docs/first-task.md) for a cautious first diagnostic
and an example prompt that asks the agent to inspect the machine without making
changes.

## License

MIT. See [`LICENSE`](LICENSE).
