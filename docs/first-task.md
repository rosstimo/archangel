# First task: inspect before changing anything

The first Archangel task should establish what the agent can see and what the
machine looks like before granting broad write access or privileged execution.

## 1. Inspect the configured boundary

```bash
sudo archangel-access status
sudo archangel-access check "$HOME/.ssh"
sudo archangel-access check "$HOME/.gnupg"
```

Those sensitive locations should normally report no access for the agent.

If you want the agent to work on a configuration tree, grant that path
explicitly:

```bash
sudo archangel-access grant rw "$HOME/.config/hypr"
sudo archangel-access grant rw "$HOME/.config/nvim"
```

Then verify the effective permissions:

```bash
sudo archangel-access check "$HOME/.config/hypr"
sudo archangel-access audit write "$HOME"
```

`audit` runs `find` as the configured agent user. It reports effective access,
not just ACL entries managed by Archangel.

If you add files to a granted tree later as your normal user, synchronize the
grant before expecting the agent to see them:

```bash
sudo archangel-access sync "$HOME/.config/hypr"
```

Archangel does not use default ACL inheritance. Every object it changes is
snapshotted first so revoke and uninstall can restore the original ACL exactly.

## 2. Run the read-only diagnostic as the agent

Find the configured agent account:

```bash
source /etc/archangel.conf
sudo -u "$ARCHANGEL_AGENT_USER" -H archangel-diagnostic
```

This checks basic identity, uptime, memory, filesystems, failed systemd units,
recent journal warnings/errors when available, and a small amount of package
state. It does not attempt repairs.

## 3. Start Hermes in the correct agent context

When Hermes is installed, use `archangel-hermes` from the human account rather
than invoking the agent account's Hermes executable directly. The launcher drops
into the configured agent identity, resets `HOME` and the working directory, and
then passes the remaining arguments through to Hermes.

Start an interactive terminal conversation:

```bash
archangel-hermes
```

Or send a single task without entering interactive chat:

```bash
archangel-hermes chat -q \
  "Evaluate this Linux system's health using read-only commands. Run archangel-diagnostic first. Do not make changes."
```

For the browser management/chat interface, start the dashboard without asking
the isolated account to open a graphical browser:

```bash
archangel-hermes dashboard --no-open
```

Then open `http://127.0.0.1:9119` in the human user's browser. Stop the foreground
dashboard with `Ctrl+C` when finished.

Setup that was skipped during Archangel installation can also be revisited later:

```bash
archangel-hermes setup
archangel-hermes model
archangel-hermes memory setup
archangel-hermes gateway install
```

## 4. Suggested first agent prompt

A useful first request is:

> Evaluate this Linux system's health using read-only commands. Start by running
> `archangel-diagnostic`. Inspect failed services, current-boot warnings and
> errors, disk usage, and package state. Do not modify files, packages, services,
> or configuration. Explain anything that looks actionable and propose the next
> diagnostic or repair step before changing anything.

The point of the first run is not to prove that the agent can fix the machine.
It is to verify that it has enough visibility to diagnose it without silently
crossing the permissions boundary.

## 5. Revoke a grant

```bash
sudo archangel-access revoke "$HOME/.config/nvim"
```

Archangel restores the ACL snapshot captured before it touched the path. Shared
parent traversal ACLs are reference-counted and restored when the last grant
that needs them is removed.

A failed restore is reported as an error and its recovery state is retained.
You can retry the revoke or restore all managed changes with:

```bash
sudo archangel-access reset
```
