# Broker IPC Spec — EDITBROKER/1

This document specifies the wire protocol between the shim and the edit broker.

The shim starts the broker with `doas`:

```text
doas -u <editbroker_user> -- <path-to-broker>
```

The shim sends the request on `stdin`. The broker sends the response on `stdout`. `stderr` carries diagnostics only.

The file `config/edit-broker-contracts.env` holds all shared constants. The test `broker/tests/broker-contracts_test.sh` checks them. The shim and the broker both source `shim-utils.sh` (installed under `libexec/doasudo/`). Checksum tool paths do not go on the wire.

The shim sources `lib/edit-broker-client.sh` in broker mode only. The broker does not load that file.

---

## Transport

The shim runs the broker as a dedicated user (typically `editbroker`). This puts the broker in a separate security domain from the caller.

`doas` closes file descriptors above stderr. Only `fd 0` (`stdin`), `fd 1` (`stdout`), and `fd 2` (`stderr`) carry data between the shim and the broker.

The broker opens `EDIT_BROKER_TTY` (default `/dev/tty`) on fds 3 and 4 for the editor session. The path must start with `/dev/` and must not contain `..` segments.

Headers are ASCII lines that end with `\n`. Bodies are raw bytes of exact declared length. Bodies can contain NUL bytes.

---

## Request (shim → broker)

The request has exactly *five* header lines, then `REQ_LEN` body bytes.

The boundary between headers and body is the *line count*, not the content. The body can start with bytes that look like a header (for example `MAGIC=`).

The five lines must appear in this order:

| Order | Line | Description |
|------:|------|-------------|
| 1 | `MAGIC=EDITBROKER/1` | Protocol version. Must match exactly. |
| 2 | `UTILS_METADATA=<sha256hex>:<uid>:<gid>:<mode>` | Integrity string for `shim-utils.sh`. Must match the broker's baked value. |
| 3 | `EDITOR=<absolute-path>` | Absolute path to the editor. The shim resolves this path. The broker matches it against an allowlist. |
| 4 | `PRE_DIGEST=<64hex\|-`>` | SHA-256 hex digest of the staged input, or `-` if the digest is not available. The sender must send a bare 64-character hex token (no filename suffix). |
| 5 | `REQ_LEN=<decimal>` | Byte length of the body that follows. |
| — | *body* | Exactly `REQ_LEN` bytes. Can contain NULs. |

---

## Response (broker → shim)

### Error (`RESP_CODE` ≠ 0)

The broker sends one line:

```text
RESP_CODE=<decimal>
```

The value must be in the range `1–255`. The broker sends no other lines and no body. The broker must close stdout quickly so the shim does not wait until timeout.

### Success (`RESP_CODE=0`)

The response has exactly *three* header lines, then `OUT_LEN` body bytes. The same line-count boundary rule applies.

| Order | Line | Description |
|------:|------|-------------|
| 1 | `RESP_CODE=0` | Success. |
| 2 | `POST_DIGEST=<64hex\|-`>` | SHA-256 hex digest of the edited output. `-` means the broker could not compute the digest. |
| 3 | `OUT_LEN=<decimal>` | Byte length of the body that follows. |
| — | *body* | Exactly `OUT_LEN` bytes. |

When `POST_DIGEST=-`, the shim warns and skips the privileged write-back for that file. The shim does not treat `-` as a protocol error. A missing line, a wrong line order, or a bad format in `POST_DIGEST` is a protocol error. The shim fails closed.

---

## Framing rules

The header length is fixed: five lines for the request, three lines for a success response. The body length comes from the declared length field only.

All fields must appear once, in the specified order. A duplicate, missing, or reordered field is a protocol error.

The shim reads exactly `OUT_LEN` bytes for the success body. The shim rejects trailing bytes after the body.

`REQ_LEN`, `OUT_LEN`, and `RESP_CODE` must be decimal. `RESP_CODE` must be in the range `0–255`. `REQ_LEN` and `OUT_LEN` must not exceed `MAX_BROKER_BYTES` (set in `config/edit-broker-contracts.env`).

### Timeout

The shim enforces `BROKER_RESPONSE_TIMEOUT_S` (set in `config/edit-broker-contracts.env`, fixed at build time; example: `3600`). This is a wall-clock limit on the whole broker process, including the editor session. A timeout is a broker failure. The shim fails closed.

### Per-TTY lock

The broker allows one edit session per terminal device. Before it reads the request body, the broker derives a lock path from the real terminal:

```text
$(EDIT_BROKER_STAGING_DIR)/.edit-broker-lock-<tty-slug>
```

The broker creates the lock directory with `mkdir` and writes its PID to a file inside. If `mkdir` fails and the recorded PID is not alive, the broker removes the stale lock and retries once. PID reuse can cause a false "busy" result.

If the lock is held, the broker sends `RESP_CODE=1` and prints `TTY session lock busy` to stderr. The broker does not wait for the lock.

---

## Broker binary integrity

The shim checks the installed broker file against the baked `EDIT_BROKER_METADATA` string (`<sha256hex>:0:0:<mode>`). The Makefile computes the digest from `broker/edit-broker.sh` in the build tree. The mode matches `install -m` (typically `755`). A mismatch causes broker mode to fail closed.

See `packaging/README.md` for details.

---

## Broker client integrity

The shim checks the installed `lib/edit-broker-client.sh` against the baked `EDIT_BROKER_CLIENT_METADATA` string (`<sha256hex>:0:0:<mode>`) before sourcing it. The Makefile computes the digest from `lib/edit-broker-client.sh` in the build tree. The mode matches `install -m` (typically `644`). A mismatch causes broker mode to fail closed; the shim never sources an unverified client. This closes the path by which a tampered client could supply a fabricated `_digest_post_editor` and steer privileged write-back.

---

## Shared utils integrity

The shim and the broker both check the installed `shim-utils.sh` against the baked `UTILS_METADATA` string (`<sha256hex>:0:0:<mode>`). The Makefile computes the digest from `lib/shim-utils.sh` in the build tree. The mode matches `install -m` (typically `644`).

The request wire carries the same string as `UTILS_METADATA=`. The broker compares it to its own baked value.

See `packaging/README.md` for build knobs.

---

## Fail-closed default

When `SUDO_SHIM_EDIT_BROKER=1`, any broker, `doas`, or protocol failure is fatal for that invocation. Set `SUDO_SHIM_EDIT_BROKER=0` (default) to use the direct editor path.

---

## Reference files

| File | Role |
|------|------|
| `doasudo.in` | Shim: builds request, parses response, enforces timeout and metadata. |
| `lib/edit-broker-client.sh.in` | Client helpers for broker mode. Bakes `EDIT_BROKER_USER`, `MAGIC`, `MAX_BROKER_BYTES`, `BROKER_RESPONSE_TIMEOUT_S`. |
| `lib/shim-utils.sh.in` | Shared helpers: binary resolution, checksum, stat, metadata checks, byte I/O. |
| `broker/edit-broker.sh.in` | Broker source. Bakes staging dir, allowlist path, parser path, TTY path, `SHIM_PATH`, utils metadata, contract constants. |
| `broker/tests/fixtures/ipc/` | Golden header files for drift checks. |
| `broker/tests/broker-contracts_test.sh` | Checks constants against fixtures and this spec. |
| `broker/tests/broker-integration_test.sh` | Shim baked with `SUDO_SHIM_EDIT_BROKER` + mock EDITBROKER IPC (protocol + metadata). |

---

## Scope

This file is the wire spec for the doas-based broker. Design material beyond the current implementation (socket backend, broader policy) is in `Broker Design Notes.md`.
