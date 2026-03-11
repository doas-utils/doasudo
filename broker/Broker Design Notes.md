# Edit Broker Design Notes (Future Ideas)

The current design of the edit broker modes lives in:

- [broker/README.md](./README.md)
- [broker/Broker IPC Spec.md](./Broker%20IPC%20Spec.md)
- [broker/Editor Allowlist Spec.md](./Editor%20Allowlist%20Spec.md)

This is a collection of notes on possible future improvements.

## 1) Per-target-file lock

Optional lock keyed by canonical target file identity, not only TTY.

- Goal: reduce concurrent write races when two sessions edit same target file.
- Key shape: `dev:ino` from trusted `stat` of target (prefer this over path string).
- Keep current TTY lock as session guard; per-target lock is additional guard.
- Acquire order must be fixed to avoid deadlocks:
  - first TTY lock
  - then per-target lock
- Busy behavior should fail closed with clear diagnostic.
- Stale reclaim should match current lock policy (PID check + single retry).

Notes:

- Hard links intentionally collide on `dev:ino` (desired for same underlying file).
- Path-only locks are weaker (symlink/rename alias risk), so avoid as primary key.

## 2) Structured audit logging (minimal)

One-line broker audit events with stable keys.

- Fields: `profile`, `editor`, `tty`, `req_len`, `out_len`, `pre_digest_state`, `post_digest_state`, `exit_code`, `duration_ms`.
- Never log content bytes.
- Start with line logs (`stderr`/syslog-friendly).

## 3) Scratch-space anomaly canary

Detect unexpected extra files in broker scratch workspace.

- Snapshot before/after known files.
- Emit warning first phase.
- Optional env/config gate to escalate warning to hard failure.

## 4) Lock observability upgrade

Improve diagnostics and stale-lock clarity.

- Log lock owner PID and age on busy paths.

## 5) Editor profiles threat notes

Compact per-profile threat notes and usage guidance.

- Document what each profile blocks.
- Document residual risk per editor family.
