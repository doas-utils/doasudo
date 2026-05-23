# Packaging

## Installation

The installation method determines how host configurations (user creation, directory permissions) are handled. Always run `make` before `make install`, and maintain consistent variables (`PREFIX`, `DESTDIR`, `SHIM_PATH`) across all build and installation steps. Install target verifies shim matches the built binary.

*Staged Installation (Package Building)*

Use `DESTDIR` to safely install files into a temporary build path. The build system skips host mutations. You must trigger `make post-install` (or `post-install.sh`) manually or via your package manager's post-installation hooks (e.g., `%post` or `postinst`).

```sh
make install DESTDIR=/tmp/pkg PREFIX=/usr
```

*Direct Installation*

Running the install target as root without a `DESTDIR` writes directly to the host system and automatically executes the `post-install` routines.

```sh
doas make install PREFIX=/usr
```

## Post-Installation

The `post-install.sh` script configures the host environment. Executing as non-root safely skips broker user creation and `chown` operations. Running `make post-install` requires empty `DESTDIR`.

The script prints a reminder to merge the configuration snippet into `/etc/doas.conf` (and issues a warning if the source snippet is missing). Broker stays unused until `doas.conf` permits it and caller sets `SUDO_SHIM_EDIT_BROKER=1`. Omitting broker-related `doas` rules keeps direct-edit path only.

Set `DRY_RUN=1` to simulate operations without mutating the host.

## Installation Layout & Configuration

The Makefile builds and installs the following layout. Pass `OVERWRITE_SYMLINKS=1` to force the creation of `sudoedit` and `editas` if those files already exist.

| Path | Role |
| :--- | :--- |
| `$(BINDIR)/sudo` | Shim binary |
| `$(BINDIR)/sudoedit` | Symlink → `sudo` |
| `$(BINDIR)/editas` | Symlink → `sudo` |
| `$(SHIM_LIBEXEC_DIR)/shim-utils.sh` | Shared shell helpers |
| `$(SHIM_LIBEXEC_DIR)/edit-broker-client.sh` | Broker IPC client |
| `$(SHIM_LIBEXEC_DIR)/edit-broker` | Edit broker |
| `$(SHIM_LIBEXEC_DIR)/allowlist-parse.awk` | Allowlist parser |
| `$(SHIM_LIBEXEC_DIR)/edit-broker-contracts.env` | Wire-limit constants |
| `$(EDIT_BROKER_STAGING_DIR)` | Broker staging path (default: `/var/lib/doasudo/editbroker`) |
| `$(DOAS_SNIPPET_DIR)/doas-snippet.conf` | Policy snippet to merge into `/etc/doas.conf` |
| `$(BROKER_CONFIG_DIR)/` | Shipped configs directory (`vimrc` at `$(BROKER_CONFIG_DIR)/vimrc`) |
| `$(BROKER_ALLOWLIST_PATH)` | Live allowlist (seeded only if missing) |
| `$(PREFIX)/share/doasudo/` | Path for reference allowlist and `post-install.sh` |

*Security Requirement:* Root must own `$BINDIR`, `$SHIM_LIBEXEC_DIR`, `$BROKER_CONFIG_DIR`, and `$BROKER_ALLOWLIST_PATH` to prevent unprivileged users from replacing the shim or its supporting scripts and bypassing the security boundary. This is a core assumption of the security model that the installation process does not actively enforce at runtime.

### Tool Resolution (`SHIM_PATH`)

If required system utilities (`doas`, `stat`, `cat`, `awk`, etc.) reside outside the default search path (`$(BINDIR):$(SBINDIR):/usr/bin:/usr/sbin:/bin:/sbin`), define `SHIM_PATH` at build time. The shim hardcodes this value to securely resolve all internal commands, preventing caller `$PATH` manipulation at runtime. The Makefile will emit a warning during installation if `doas` is not found within this resolved path.

```sh
make install SHIM_PATH=/opt/local/bin:/usr/bin:/bin
```

## Build-Time Metadata

The build system embeds SHA-256 integrity hashes for internal components during build time. At runtime, the shim and broker execute `_check_file_meta` to verify that the installed files' ownership and hashes match the embedded lines.

Calling `_compute_metadata <file> <octal-mode> [stat-ug]` (from `utils/metadata-utils.sh`) generates these hashes. When passing `stat-ug`, `<octal-mode>` is ignored and live  `uid:gid:mode` is read from `stat(1)` on `<file>`.

| Component | Mode | Embedded Variable |
| :--- | :--- | :--- |
| `broker/edit-broker.sh` | `755` | `EDIT_BROKER_METADATA` |
| `lib/shim-utils.sh` | `644` | `UTILS_METADATA` |
| `config/vimrc` | `644` | `BROKER_CONFIG_VIMRC_METADATA` |

Build Rules:
- *Release and Cross-Builds:* The Makefile computes hashes using hardcoded root ownership (`0:0:<octal-mode>`). `EDIT_BROKER_METADATA` always hashes the source tree's `broker/edit-broker.sh`, even if `EDIT_BROKER_SRC` points elsewhere. You must keep the source tree file byte-identical to your shipped script, or the shim will reject it.
- *Test Harnesses:* Setting `UTILS_METADATA_PATH` and `UTILS_METADATA_COMPUTE_MODE=stat-ug` overrides the default behavior and reads live `uid:gid:mode` directly from the host file. This is reserved for local testing and is never triggered by standard installations.

## Uninstall

```sh
make uninstall  # use same DESTDIR and PREFIX as for install
```

Use the exact `PREFIX` and `DESTDIR` set during installation. The uninstall target verifies that `sudo`, `sudoedit`, and `editas` are the shim binaries before removing them.

Removed components:
- Shim symlinks and binaries.
- The `$(SHIM_LIBEXEC_DIR)` payload (utilities, client, broker, IPC contracts).
- The default staging tree and shipped `vimrc`.
- The `share/doasudo/` directory.

Preserved components:
- `$(BROKER_ALLOWLIST_PATH)` remains intact to preserve local site policy.

## Packager Checklist

1. *Build:* Run `make` on a representative host. Execute as a non-root user to ensure the full test suite runs.
2. *Stage:* Run `make install DESTDIR=<path> PREFIX=<path>`. Do not fold post-install hooks into this step.
3. *Post-Install:* Execute `post-install.sh` or `make post-install` on the target machine to initialize the broker user and set staging directory permissions.
4. *Configuration:* Merge `doas-snippet.conf` into `/etc/doas.conf`.

### OS-Specific Notes

- Linux: Standard `useradd` creates the broker account. Sandbox helpers are optional.
- BSD: Ensure package manifests handle broker user creation, staging directory initialization, and policy rollout.

## References

- Post-Install Script: `packaging/post-install.sh`
- Broker Overview: [`broker/README.md`](../broker/README.md)
- Policy Source: `config/edit-broker.doas.conf.in`
