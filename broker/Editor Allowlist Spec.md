# Editor Allowlist Specification

The broker sets `argv`, the `env -i` baseline, and which shipped config file runs. The allowlist lists absolute paths to editor binaries only. The wire supplies `EDITOR=` as a path; it never supplies flags or environment strings.

Normative behavior matches [broker/edit-broker.sh.in](./edit-broker.sh.in) (`_resolve_editor`) and [allowlist-parse.awk](./allowlist-parse.awk).

---

## Purpose and scope

1. *User input never becomes arbitrary argv.* The caller contributes only the path in `EDITOR=`; `path` stanzas match it. Flags, `$CONFIG` expansion, the `env -i` baseline, and `TERM` policy come from the broker registry (`_resolve_editor`, `_expand_config`).
2. *Grammar stays minimal:* stanzas contain only `path =` lines. The parser rejects `flags`, `env`, and `config`.
3. The allowlist is a *root-owned* file beside the broker. Admins change policy without rebuilding the shim; keep sensitive material out of the file.
4. Shipped configs under `_BROKER_CONFIG_DIR` carry per-file baked metadata (`vimrc` today).
5. The shim resolves `$SUDO_EDITOR`, `$VISUAL`, `$EDITOR`, and `vi` the same way in broker mode and legacy mode (`path` parity).

This document covers grammar, parser modes (`query`, `dump`, `validate`), broker use of `EXEC` and `PROFILE`, `argv` and environment, the *TTY lock*, and integrity checks.

---

## Wire and editor selection model

The shim sends `EDITOR=<absolute-path>` on the request body. The broker treats it as an opaque key, matches `path =` lines, and lets `PROFILE` pick the registry arm. The wire carries no stanza labels and no flag strings.

`PROFILE` names come from `[stanza]` headers after normalization (see Grammar). Match by path first; use `PROFILE` to separate `vim`-class routing.

Symbolic profile wire (`EDITOR_PROFILE=vim`) is *out of scope*; the path-based selector does not change.

---

## Allowlist grammar

The file is a series of `[stanza]` profiles. Ignore blank lines and `#` comments.

Within a stanza:

- `path = <absolute executable>` — required; repeat within one stanza for aliases (several `path` lines, one profile).

Disallowed (*hard parse error*):

- `flags`, `env`, or `config` keys. The broker owns templates and config paths.

Syntax sketch:

```text
[vim]
path = /usr/bin/vim
path = /usr/local/bin/vim

[nano]
path = /usr/bin/nano

[red]
path = /usr/bin/red
```

### Canonical names and `[vi]`

- Headers `[name]` must match `^\[(?:[a-z][a-z0-9_-]*)\]$`.
- `[vi]` becomes `vim` before resolution. Unknown headers parse if `path` appears; the broker rejects unsupported `PROFILE` values.

### Path rules

- Each `path =` value is absolute and unique in the file (*no ambiguous dispatch*).
- Each stanza needs at least one `path`.
- The first stanza whose `path` lists the wire `EDITOR` wins.

---

## Parser reference (`broker/allowlist-parse.awk`)

### Modes

- *Validate:* `awk -f allowlist-parse.awk FILE` — exit `0` if valid, `1` if not.
- *Dump:* `awk -v DUMP=1 [-v EDITOR=…] …` — canonical dump; optional `test -x` warnings on `stderr`.
- *Query:* `awk -v EDITOR=/absolute/path/to/editor -f … FILE`
  - exit `2` if the editor is absent, `1` on parse error, `0` on success. `stdout` empty on non-zero exit; `stderr` carries `allowlist-parse: <msg>` (parse failure or editor not listed).
  - Query mode skips `test -x` (install may lag).

### Query output (`stdout`, fixed order — contract with broker)

```text
EXEC /matched/binary
PROFILE <canonical>
```

`PROFILE` names the registry entry (`vim`, `nano`, `red`, …). The broker reads only these lines (*no FLAGS/ENV/CONFIG*).

### DUMP output (`DUMP=1`)

Emits `STANZA <name>` (canonical, post-alias normalization), `EXEC <path>`, optional `ALIAS <path>` lines for additional paths in the same stanza, and `ENDSTANZA` per stanza. Use DUMP for lint and debug. With `EDITOR=…`, query mode wins over stanza DUMP.

### Invalid keys

`flags`, `env`, `config` draw an explicit diagnostic (*e.g.* "only path allowed").

---

## Broker runtime (`edit-broker.sh.in` outline)

After the query:

1. Read `EXEC` and `PROFILE`. Fail closed if they disagree with the wire `EDITOR=` (`_editor_exec_path`).
2. `_resolve_editor "$_editor_profile"` sets `_editor_flags`, `_config_file` (basename or empty), `_runtime_tag`, and `_config_metadata` when a shipped file applies.
3. `_flags_template` starts as `$_editor_flags`. If `_config_file` is set: compute `_config_abs`, call `_check_file_meta` on `$_config_metadata`, then `_expand_config` substitutes `$CONFIG` in `_flags_template`.
4. Launch under `env -i` with baseline env, sanitized `TERM`, the `EXEC` path, and word-split `_flags_template` — see `edit-broker.sh.in`.

For `nano` and `red`, `_config_file` stays empty; skip the config `_check_file_meta` branch.

`vim` (`+eval`/`+autocmd`) gets a runtime check once per invocation (`_check_vim`).

`_check_allowlist_meta` checks `ALLOWLIST` and `EXEC` on disk (`root-owned`, *022 clean*).

---

## Integrity model

| Artifact | Mechanism |
|----------|-----------|
| `edit-broker.sh` | `EDIT_BROKER_METADATA` (`sha256:0:0:755`) shim gate |
| `shim-utils.sh` | `UTILS_METADATA` |
| *Allowlist* | root-owned (`0:0`; *not* group- or world-writable); checked each parse; no baked digest |
| *Shipped configs* (`vim`/`vimrc`) | `$(BROKER_CONFIG_DIR)/vimrc` vs `BROKER_CONFIG_VIMRC_METADATA`; add a row per new file |

---

## Editor environment

All editors are called with a stripped environment `env -i`, plus `SHELL=/bin/false`, `HOME=/nonexistent`, and a sanitized `$TERM`.
This are the argument passed depending on the editor.

### vim

Flags: `-u $CONFIG` with `-Z -N -i NONE -U NONE`. `$CONFIG` resolves to broker-owned `config/vimrc` under `BROKER_CONFIG_DIR`.

### nano

Flags: `--restricted --linenumbers --nowrap --smarthome`.

### red

Flags: `-p >`.

To add an editor: extend `_resolve_editor`, add a `BROKER_CONFIG_*_METADATA` line in the Makefile for new basenames, install the file under `$(BROKER_CONFIG_DIR)` (source lives in tree `config/`), and document the profile here.

---

## Out of scope

- User provided `flags`, `env`, or `config =` (the broker owns argv and config).
- Graphical editors.
