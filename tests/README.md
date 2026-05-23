# Tests

`make check-src` validates core logic and is the primary regression path. Run it during development for fast feedback via a mock `doas` harness (no root or passwords required).

`make check` (or `make`) extends `check-src` by post-validating the metadata of the `lib/shim-utils.sh` library against the compiled shim. `make shellcheck` provides static analysis.

Mock `PATH` fixtures for `tests/edit-mode_test.sh` and `broker/tests/broker-integration_test.sh` share `tests/mock-edit-mode.sh` (`_MOCKBIN_EDIT_SUITE=full` vs `broker`).

Use local integration tests (Docker/E2E) when modifying installation paths, distribution packages, or `doas.conf` logic. These cross real system boundaries and take longer than the core suite.

## Core Tests (`make check-src`)

The suite runs the scripts listed below in sequence. The `broker/tests/test-driver.sh` script executes only with root or passwordless `doas` access; otherwise, it is skipped. Each run finishes by recreating the `_SHIM_UTILS_METADATA` file and clearing temporary binaries.

To troubleshoot or view full output, prepend `VERBOSE=1`:

```sh
VERBOSE=1 make check-src
VERBOSE=1 sh tests/parser_test.sh
```

### Test Coverage Summary

- `tests/doas-flags-parity_test.sh`: Verifies flag parity between `_doas` and `_doas_exec`.
- `tests/parser_test.sh`: Validates argument parsing and early rejection of invalid edit requests.
- `tests/edit-mode_test.sh`: Evaluates the edit write-back path, mtime skips, PTY prompts, and SUDO_EDITOR header checks.
- `broker/tests/broker-contracts_test.sh`: Verifies the shim-broker IPC interface for consistency.
- `broker/tests/allowlist-parse_test.sh`: Tests the allowlist parser against golden fixtures.
- `broker/tests/vim-profile_test.sh`: Verifies vim features, and vim config hardening.
- `broker/tests/broker-integration_test.sh`: Shim baked with `SUDO_SHIM_EDIT_BROKER` and mock EDITBROKER responder (protocol + metadata edge cases).
- `broker/tests/test-driver.sh`: Exercises the broker binary request/response harness and per-TTY session locks.
- `tests/stale-metadata_test.sh`: Simulates stale shim compilation to verify the auto-repair process.

### Write-back and Broker Isolation

The test harness simulates an elevated `sh -c` call on user-owned files. This allows the suite to exercise the write-back path and Discretionary Access Control (DAC) logic without root intervention.

Broker tests validate the IPC contract and session management. `test-driver.sh` skips when the harness cannot satisfy root-owned allowlist stubs (see script header). Shim integration tests rely on mocked `sudo` + `EDITBROKER` and do not need the real broker daemon.

Run specific suites individually:

```sh
make check-edit-mode
make check-broker-contracts
```

## Full Validation (`make` or `make check`)

*Run `make` as a standard user before any installation.* The default `check` target executes `check-src` and verifies that the `lib/shim-utils.sh` metadata matches the compiled binary. This check confirms the shim can identify and load its internal library at runtime.

The `native-check` CI job uses this target to ensure the full suite passes across Linux and macOS environments.

## Lint (`make shellcheck`)

Run `make shellcheck` to catch quoting errors and POSIX compliance issues. This target analyzes the main shim, the utility library, and all test scripts.

```sh
make shellcheck
```

For a complete pre-commit check, use `make check-all`, which runs the linter, the core test suite, and a fresh build in a single pass:

```sh
make check-all
```

## Local Integration

### Docker

Verify the shim across diverse userlands. Docker provides a controlled environment to test portability beyond the host OS, ensuring the shim and broker handle variations in `make`, `doas`, and system utilities.

- Alpine (`tests/docker/Alpine.Dockerfile`): Tests against BusyBox utilities and standard `doas`.
- Chimera (`tests/docker/Chimera.Dockerfile`): Tests against a BSD-style userland using `opendoas` and `gmake`.

Each Dockerfile includes the reference broker to validate IPC and session locking in a fresh state. The harness uses a `wheel` account with a `nopass` rule; *do not use these configurations blindly in production.*

Run the integration suite for a specific userland:

```sh
# Replace 'Alpine' with 'Chimera' to test a BSD-style userland
docker build -f tests/docker/Alpine.Dockerfile -t doasudo-alpine .
docker run --rm -it doasudo-alpine
```

### AnyVM (BSD)

`tests/bsd/anyvm.sh` boots FreeBSD, OpenBSD, NetBSD or DragonFly BSD VMs via a thin wrapper around [AnyVM Docker](https://github.com/anyvm-org/docker) (see `tests/bsd/AnyVM.Dockerfile`). Calling `sh tests/bsd/anyvm.sh --test <os>` runs tests similarly to CI's (`ci-bsd.yml`). Drop the `--test` option to land into an interactive shell inside the VM.

### Host Broker E2E

These tests exercise the host's actual `doas` installation and real system files. Run this suite when modifying installation paths, allowlist parsing, or `doas.conf` merge logic.

```sh
# 1. Setup as root
# Set BROKER_E2E_APPEND_DOAS_CONF=1 to append required 'permit' rules to /etc/doas.conf
sudo make broker-e2e-setup BROKER_E2E_APPEND_DOAS_CONF=1 EDIT_BROKER_TTY=/dev/null

# 2. Run as a wheel user
make check-broker-e2e BROKER_E2E_RUN_USER=youruser
```

## CI & Automated Infrastructure

The CI pipeline validates the suite across various platforms to ensure portable `sh` compatibility and metadata integrity.

- Native Runners (`ci.yml`): Run the full test suite on Ubuntu and macOS.
- Virtualized BSD environments (`ci-bsd.yml`): Test FreeBSD, OpenBSD, NetBSD, DragonFly BSD via QEMU to verify portability against BSD-native system utilities and the local `doas`/`su` elevation harnesses.
