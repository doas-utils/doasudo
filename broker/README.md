# Edit broker

The default edit mode in doasudo (`sudo -e`, `sudoedit`, `editas`) stages each file under the invoking user, then writes back as the privileged user. The shim hardens the pre- and post-editor windows; the working copy still lives on the invoker's side of the boundary until write-back. Same-UID exposure surface is acknowledged in the top-level README under [Optional edit-mode broker](../README.md#optional-paranoid-edit-mode-broker).

Edit broker is optional. When it is on, the shim runs a small editor wrapper as a *dedicated user* via `doas`; that user owns the staged bytes. The wrapper speaks `EDITBROKER/1` on stdin/stdout ([Broker IPC Spec.md](Broker%20IPC%20Spec.md)). It starts only binaries whose paths appear under `path =` in the allowlist; `argv`, the `env -i` baseline, and shipped config come from the broker registry ([Editor Allowlist Spec.md](Editor%20Allowlist%20Spec.md)). Write-back follows the legacy privileged path; content returns from broker staging. Broker mode stays off until `SUDO_SHIM_EDIT_BROKER=1`, a broker install path, and `doas.conf` rules all line up; otherwise the shim follows the legacy path in the top-level README.

---

## Opt-in

- Set `SUDO_SHIM_EDIT_BROKER=1` for invocations that should use the broker.
- Install `doas` rules that permit the caller to run the broker as `EDIT_BROKER_USER` (snippet from install; merge into `/etc/doas.conf`). Post-install and layout: [packaging/README.md](../packaging/README.md).

To ship the broker but never use it, omit those rules and leave `SUDO_SHIM_EDIT_BROKER` unset.

---

## Behavior

The shim starts the broker with `doas -u <EDIT_BROKER_USER> -- <edit-broker>`, sends a length-framed request on stdin, and reads a framed response on stdout. Layout, digests, limits, timeouts, and the per-terminal lock: [Broker IPC Spec.md](Broker%20IPC%20Spec.md) (`EDITBROKER/1`). If broker mode is active, any failure along the chain—`doas`, wire validation, metadata mismatch, broker logic, or editor exit—ends the edit; there is no fallback to a host tmpfile. Rationale and enforcement detail: `SECURITY NOTE` at the top of `edit-broker.sh.in`.

---

## Security model

The shipped broker (`edit-broker.sh` from `edit-broker.sh.in`) documents policy in the `SECURITY NOTE` at the top of `edit-broker.sh.in`, as `doasudo.in` does for default edit mode. This README does not cover site wrappers, alternate binaries, or extra OS hardening (pledge, Landlock, and the like).

[Optional edit-mode broker](../README.md#optional-paranoid-edit-mode-broker) explains the same-UID residual risk in default edit mode. Broker mode runs staging and the editor as a *dedicated user*. The wire carries `EDITOR=` as a path into a root-owned allowlist (`path =` lines). `argv`, environment, and shipped-config templates come from the broker registry, not from the client or from extra allowlist fields. See [Broker IPC Spec.md](Broker%20IPC%20Spec.md) and [Editor Allowlist Spec.md](Editor%20Allowlist%20Spec.md).

### Trust boundaries

- Invoking user — Chooses `SUDO_EDITOR`, `VISUAL`, or `EDITOR` (or `vi`); path must match the allowlist.
- Shim — Frames I/O, verifies broker and `shim-utils` metadata before `doas`, write-back.
- `doas` / OS — Who may run the broker and as which user.
- Broker — Dedicated UID; owns staging; the allowlist names the binary only; `argv`, environment, and shipped configs come from the registry and baked metadata.
- Allowlist — Root-owned policy; `root:root`, `mode & 022 == 0`, broker-readable; parent path root-controlled ([packaging/README.md](../packaging/README.md)).
- Editor child — `env -i` plus policy env; may use the session TTY.

### Enforced at runtime

Enforce wire shape and caps; compare `UTILS_METADATA` to `shim-utils.sh`; run `allowlist-parse.awk` (reject malformed files and absent editors); match `EXEC` and `PROFILE` to the wire; build `argv` from the registry; clear `PATH`; check shipped configs under `BROKER_CONFIG_DIR` against per-file metadata; hold the per-TTY lock; follow staging rules. Read `SECURITY NOTE`, the IPC spec, and the Allowlist spec.

### Out of scope

- Doas rule quality — Operator responsibility.
- TTY user — Hostile terminals remain a general problem; shipped `config/vimrc` and `TERM` policy only reduce surface.
- Editor logic — Allowlisted editor is still arbitrary code under policy.
- Kernel / filesystem races — Align with shim write-back assumptions; exotic setups may need review.
- Availability — `BROKER_RESPONSE_TIMEOUT_S` bounds client wait, not editor fairness.

### Integrity chain

Baked metadata uses `sha256:0:0:<mode>`; `stat(1)` at runtime must match (`755` broker, `644` `shim-utils.sh`, broker client, shipped `vimrc`). The shim checks `EDIT_BROKER_METADATA` on the broker script and `EDIT_BROKER_CLIENT_METADATA` on `lib/edit-broker-client.sh` before sourcing. `shim-utils.sh` gets a wire check and a source check. The allowlist undergoes parse-time checks without a content digest. Shipped configs use `_check_file_meta` against baked lines (for example `BROKER_CONFIG_VIMRC_METADATA` on `$(BROKER_CONFIG_DIR)/vimrc` when the Makefile supplies them). See [Editor Allowlist Spec.md](Editor%20Allowlist%20Spec.md) (Integrity model).

---

## References

1. [Broker IPC Spec.md](Broker%20IPC%20Spec.md) — Framing, digests, limits, timeouts, TTY lock (`EDITBROKER/1`).
2. [Editor Allowlist Spec.md](Editor%20Allowlist%20Spec.md) — Path-only stanzas, query `EXEC`/`PROFILE`, `env -i` baseline, shipped config integrity.
3. [packaging/README.md](../packaging/README.md) — `DESTDIR`, metadata bake, `post-install`, install layout.
4. [tests/README.md](../tests/README.md) — `check-src` order, broker tests, Docker / E2E.
5. [Broker Design Notes.md](Broker%20Design%20Notes.md) — Broader design (for example a socket backend).

---

## Source layout and integration

Security narrative: comment block at top of `edit-broker.sh.in` (installed `edit-broker.sh`).

The Makefile generates `edit-broker.sh` from `edit-broker.sh.in` (see the Makefile and comments there). `allowlist-parse.awk` parses the allowlist; `tests/` holds contract fixtures, `test-driver.sh`, and E2E helpers. Broker wiring lives in `doasudo.in` (broker branch); shared helpers in `lib/shim-utils.sh.in`; shim-side broker client in `lib/edit-broker-client.sh.in`.

Install layout, `config/`, and `post-install`: [packaging/README.md](../packaging/README.md). `check-src`, Docker, and host `broker-e2e`: [tests/README.md](../tests/README.md).
