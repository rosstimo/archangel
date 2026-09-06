# Archangel

Archangel is an early-stage collection of Linux host setup and management tools
for running a persistent AI system helper under a dedicated Unix account.

The project is intentionally small right now. The first goal is to make the
permission boundary understandable and reproducible before adding more agent
behavior.

## Current pieces

- interactive host bootstrap
- dedicated agent Unix account
- optional systemd journal access for diagnostics
- `archangel-access` for granting, revoking, checking, and auditing filesystem access
- `archangel-diagnostic` for a read-only first system check

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
default. The account name is not hard-coded into the management tools.

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

Archangel uses POSIX ACLs so the original owner/group model of the shared files
can remain intact. Parent directories receive traverse-only ACLs when required.
The wrapper records the grants it manages under `/var/lib/archangel`.

## Journal access

The installer can add the agent account to `systemd-journal`. It can also be
changed later:

```bash
sudo archangel-access journal enable
sudo archangel-access journal disable
```

Existing agent processes need to be restarted after group membership changes.

## First task

See [`docs/first-task.md`](docs/first-task.md) for a cautious first diagnostic
and an example prompt that asks the agent to inspect the machine without making
changes.

## License

MIT. See [`LICENSE`](LICENSE).
