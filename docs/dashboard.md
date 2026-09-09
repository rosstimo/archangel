# Hermes dashboard

Archangel can manage the local Hermes web dashboard without changing the
ownership boundary between the human account and the agent account.

The dashboard always runs as the configured Archangel agent account. The
human-facing `archangel-dashboard` command controls that user service and opens
the UI in the human user's browser.

By default the dashboard binds only to:

```text
http://127.0.0.1:9119
```

Archangel does not expose the dashboard on the LAN or Internet.

## Installation choice

When Hermes is installed and the agent's user-systemd manager is available, the
Archangel installer installs a `hermes-dashboard.service` user unit under the
agent account. It then asks whether the dashboard should run persistently.

If persistence is selected, the service is enabled and started. Persistent user
services require systemd linger for the agent account. Archangel tracks whether
it created the dashboard unit and whether it enabled a pre-existing unit so
uninstall can restore the previous state instead of deleting user-owned setup.

If persistence is declined, the same service remains installed but disabled.
That gives the user a consistent manual start/stop interface without leaving the
dashboard running all the time.

## Manual control

Start the dashboard and open it in the current human user's default browser:

```bash
archangel-dashboard
```

or explicitly:

```bash
archangel-dashboard start
```

The service runs as the configured agent account, but browser opening happens
in the human desktop session. This avoids launching a browser as root or as the
isolated agent user.

Stop it:

```bash
archangel-dashboard stop
```

Restart it and reopen the browser:

```bash
archangel-dashboard restart
```

Check the user service:

```bash
archangel-dashboard status
```

Print the local URL:

```bash
archangel-dashboard url
```

## Ownership boundary

Archangel owns a dashboard unit only when it created that unit. If the agent
account already had a `hermes-dashboard.service`, Archangel preserves the file.
If Archangel enables a pre-existing unit during installation, that enablement is
tracked separately so uninstall can disable it without deleting the user's unit.

The Hermes runtime, its `.env`, dashboard data, and any dashboard authentication
configuration remain Hermes-owned configuration. Archangel only provides the
localhost service wrapper and lifecycle controls.
