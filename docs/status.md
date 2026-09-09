# Live status overview

`archangel-status` rebuilds the useful post-install overview from current system
state. It is not a saved copy of the installer output.

Run:

```bash
archangel-status
```

The summary currently includes:

- the configured human owner and agent Unix account;
- the agent UID, home directory, journal access, and whether host sudoers policy
  grants the agent any sudo authority;
- current Archangel-managed filesystem grants;
- the currently discoverable Hermes executable and version, plus installation
  provenance when Archangel recorded it;
- the agent user-systemd manager and linger state;
- the Hermes dashboard unit, enablement, running state, and local URL;
- the current service registry;
- saved gateways and their current route/interface path state;
- useful follow-up commands based on the components that are present.

The default status view does not send HTTP probes to configured services. This
keeps the command quick and avoids waiting on unavailable endpoints.

For a deeper current check, run:

```bash
archangel-status --probe
```

That adds the same selected-service HTTP reachability checks Archangel uses at
the end of installation, executed from the configured agent account.

Related focused commands remain available when more detail is needed:

```bash
sudo archangel-access status
sudo archangel-services status
sudo archangel-services gateway status
archangel-dashboard status
archangel-hermes doctor
```

`archangel-status` is intended to answer the common question "what is Archangel
using and what can I do next right now?" without replacing those specialized
inspection commands.
