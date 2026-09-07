# Archangel

Archangel is a Linux project for setting up and managing a persistent AI system
helper. The goal is a helper you can talk to locally, ask to inspect and maintain
your machine, and have alert you when scheduled checks find something that needs
attention.

The helper runs under its own Unix account. You choose its account name and
decide which files it may read or change. Archangel provides host setup and
access-management tools so those permissions can be inspected, adjusted, and
reversed.

Hermes is the initial agent runtime target. Archangel's role is to make the
surrounding Linux setup reproducible: the account, filesystem access, diagnostic
visibility, and cleanup when you want to remove it.

The project starts with practical system diagnostics and maintenance, with room
to evolve through use. Its intended scope includes Linux distributions beyond
Arch.

## Documentation

- [Installation and usage](docs/usage.md): setup, access commands, recovery, and uninstall.
- [First task](docs/first-task.md): inspect the system and verify the agent's access.
- [Development progress](docs/progress.md): implementation status, review follow-up, and pending validation.

## License

MIT. See [LICENSE](LICENSE).
