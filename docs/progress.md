# Development progress

This document tracks implementation and validation. The [README](../README.md)
describes the project; [installation and usage](usage.md) documents its commands.

## Implementation status

As of 2026-09-07, based on code through commit
[`70b4abf`](https://github.com/rosstimo/archangel/commit/70b4abf).

Implemented:

- Interactive host bootstrap with a configurable, dedicated non-root agent account.
- Optional systemd journal access, with the original membership recorded for uninstall.
- `archangel-access` commands for granting, revoking, synchronizing, checking,
  and auditing filesystem access, plus reset and recovery.
- ACL snapshots and shared parent-traversal tracking for restoring managed permissions.
- `archangel-diagnostic` and a first-task guide for a read-only system check.
- Uninstall with ACL restoration, account cleanup choices, package provenance,
  and a report of residual state and manual cleanup steps.

Agent runtime installation is still manual. Automated Hermes setup, persistent
agent operation, and scheduled checks with notifications remain future work.

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

The initial review confirmed Bash syntax for the three scripts at `1c30286` and
reproduced the false-success revoke behavior using simulated ACL-removal
failures. Those results apply to the original version, not the later hardening.

Still to verify for the current implementation:

- [ ] Real ACL grant, sync, revoke, and reset behavior on a disposable Linux setup.
- [ ] Preservation of existing ACL entries, masks, and unrelated effective access.
- [ ] Overlap rejection and restoration of shared parent-traversal permissions.
- [ ] Recovery after interrupted operations or failed ACL restoration.
- [ ] Fresh install, reuse of an existing account, root rejection, and account-change protection.
- [ ] Uninstall behavior for journal membership, retained accounts, agent-owned files,
  package provenance, and reported residual state.

## Development record

- `a807963`: initialized the project.
- `1c30286`: added bootstrap, access management, diagnostics, and first-task documentation.
- `08d8e9d`: hardened ACL state handling and added clean uninstall.
- `627222c`: recorded ACL package provenance for uninstall.
- `b695fec`: added uninstall residual reporting and manual cleanup guidance.
- `70b4abf`: documented uninstall residuals and cleanup.

Keep implementation updates, validation results, and open issues here as work
continues. Update the README when the project's purpose or documentation entry
points change.
