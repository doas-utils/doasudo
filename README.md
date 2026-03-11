# doas-sudo-shim

A POSIX shell shim that translates `sudo(8)` invocations to `doas(1)`, with full option coverage, POSIX-safe argument parsing, and security hardening. Drop it in as `sudo` on systems where doas is the privilege escalation tool; scripts that call `sudo` (mostly) work without modification.

Inspired by [jirutka/doas-sudo-shim](https://github.com/jirutka/doas-sudo-shim).

Compatibility: Linux, FreeBSD, OpenBSD, NetBSD, DragonFly BSD, macOS

---

## Supported options

| sudo option | Notes |
|-------------|-------|
| `-u USER` | passed through to doas |
| `-n` | passed through to doas |
| `-H` | sets `HOME` to the target user's passwd entry |
| `-i` | login shell via target user's passwd entry |
| `-s` | shell via `$SHELL` or invoking user's passwd entry |
| `-e` / `sudoedit` / `editas` | edit mode for unprivileged invokers; see below |
| `-k` | clears doas auth (`doas -L`) when no command follows |
| `-K` | clears doas auth (`doas -L`); no command or other options permitted |
| `-l` | prints a "not supported" notice |
| `-v` | exits with an error; doas has no credential cache |
| `-E`, `-A`, `-S`, `-D`, `-R` | warned and ignored |
| `-b`, `-g` | fatal; see `sudo --help` for rationale |

`SUDO_UID`, `SUDO_GID`, `SUDO_USER`, `SUDO_HOME`, and `SUDO_TTY` are set for the target process. The shim provides no support for `SUDO_COMMAND`; programs in the shim call stack will see it unset.

### `doas.conf` requirement

The shim requires a broad, non-`cmd`-scoped doas rule. For example:

```
permit :wheel
```

Restrictive `cmd`-scoped rules are not supported. For instance, granting edit mode under one requires adding unrestricted shell access; use doas directly with a narrowly scoped editor rule instead.

---

## Edit mode

Invoked as `sudo -e`, `sudoedit`, or `editas`, the shim copies target files to a temporary directory owned by the invoking user, runs the editor unprivileged, then writes back any changed files as the privileged user.

Each file is processed in a separate editor session and written back independently, unlike real `sudoedit(8)`, which opens all files at once. For the common single-file case the behavior is identical.

The editor is taken from `$SUDO_EDITOR`, `$VISUAL`, `$EDITOR`, or `vi`. It must be a *single absolute path* (no spaces, tabs, or flags). To pass options to the editor (e.g. `vim -u NONE`), use a wrapper script:

```sh
# /usr/local/bin/vim-sudoedit
#!/bin/sh
exec /usr/bin/vim -u NONE "$@"
```

Then set `SUDO_EDITOR=/usr/local/bin/vim-sudoedit`. See `sudo --help`.

### `editas`

The shim installs `editas` alongside `sudoedit`. The name `doasedit` already exists in the wild, but `editas` mirrors doas naming better: *edit as [user]*.

### Restrictions

- Symbolic links may not be edited.
- Files in a user-writable directory may not be edited.
- Device files may not be edited.
- Edit mode may not be invoked by root.

### Security model

Two attack families in edit mode are in scope. *Symlink substitution:* an attacker replaces a path component or the target with a symlink, so the privileged write-back lands on the wrong file. *Temp-file substitution:* the unprivileged working copy is replaced or modified during the edit session so unexpected content reaches the real target during privileged write-back. A set of mitigations address these; the full security model is documented in the `SECURITY NOTE` at the top of `doas-sudo-shim.in`.

### Optional (paranoid) edit-mode broker

The default edit mode does not prevent same-UID exposure for the lifetime of the editor session. An optional broker keeps the working copy and editor policy outside the invoking user's tree, and returns edited bytes through a framed protocol; privileged write-back is unchanged. Enable with `SUDO_SHIM_EDIT_BROKER=1`; for installation and security details see: [broker/README.md](broker/README.md).

### Optional diffs before saving changes

Setting `SUDO_SHIM_CONFIRM_DIFF=1` in the environment will show a unified diff and require confirmation before each write-back. Without an interactive TTY (or with `-n`), edit mode exits.

---

## Installation

```sh
make                           # full test suite, then build shim (run as a normal user)
doas make install              # live prefix, default /usr/local
make install PREFIX=/usr       # custom PREFIX (still elevated if under system paths)
make install DESTDIR=/tmp/pkg  # staged install (no host post-install folded)
```

`make install` installs files only; it does not run the test suite (run `make` first). On a live install as root with empty `DESTDIR`, the Makefile tail-invokes `post-install` (broker user + staging `chown`). Otherwise run `make post-install` (or the shipped `post-install.sh`) after unpack / from `%post`, then merge `doas-snippet.conf` into `/etc/doas.conf`. See [packaging/README.md](packaging/README.md).

## Uninstall

```sh
make uninstall
```

See [packaging/README.md](packaging/README.md) for what is removed and how removal is validated.

---

## Testing

Main test entry points:

```sh
make check-src  # test shim and broker from source; skips the final rebuild step a full `make` does
make            # full test suite and shim build (run before privileged install)
```

For per-test details and docker images, see [tests/README.md](tests/README.md).

If the test suite cannot run in your environment, build with `make doas-sudo-shim` and install files to match a normal `make install` layout (the shim expects `shim-utils.sh` and `edit-broker-client.sh` under `$(PREFIX)/libexec/doas-sudo-shim/`, with the broker and contracts beside them). When using `DESTDIR` for a staged install, run `make` (or `make check-src`) on a host similar to the deployment target first. See [packaging/README.md](packaging/README.md).

---

## Development

Design and architecture by [p-zubieta](https://github.com/p-zubieta). Parts of the codebase were written with the help of AI coding assistants. All changes were reviewed and tested by the maintainers.

---

## License

MIT
